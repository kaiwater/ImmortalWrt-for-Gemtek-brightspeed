#!/bin/sh
#
# XG2010G：开机后 5 分钟窗口内，确保 lan1 真正可用
#
# ---------------------------------------------------------------------------
# 为什么需要
#
# lan1 接 XR1710G。这台机器的 10G 口用 RTL8261BE PHY，建立链路时存在竞态：
# 双方 PHY 都报 Link is Up / Link detected: yes，但 SerDes/PCS 的数据通路
# 可能没有真正同步 —— 结果 MAC 层一个字节都收不到。
#
# 2026-10-06 11:09 重启后就是这样：lan1 的 rx_bytes 一直卡在 0，持续 1 小时 50 分，
# 接在 lan1 后面的 XR1710G 及其全部无线/有线客户端集体失联。
# 手动 `ip link set lan1 down; up` 立刻恢复。
#
# ---------------------------------------------------------------------------
# 思路（替代旧的 xg2010g-10g-linkcheck）
#
# 旧脚本只盯着开机后约 2 分钟，而且一度想加「常驻巡检 + rx 增量判据」，
# 结果在低流量端口上会误判（实测：安静时段 lan1 的 rx 均值只有约 190 B/s，
# 6 秒窗口零增长很正常，会把健康端口误伤成 down/up）。
#
# 现在换成最简单的做法：
#
#   开机后 5 分钟之内，反复检查 lan1 到底通不通；不通就 down/up 重新协商；
#   通了就立刻退出。5 分钟到点无论如何退出。
#   只在开机窗口内动作 —— 不常驻、不巡检、不碰运行中的端口。
#
# 「通不通」的判据还是 rx_bytes 有没有增长（`Link detected: yes` 在 PHY 层是骗人的）。
# 在开机窗口内用这个判据是安全的：如果端口报了 carrier=1 却连续 SAMPLE 秒
# 一个字节都收不到，那就是数据通路没起来，而不是「对端恰好安静」——
# 开机时对端会发 ARP / 组播 / 各种握手，正常端口不可能这么安静。
#
# 兜底：设 XG2010G_ALWAYS_FLAP=1 就完全不看判据，开机后直接无条件重新协商一次。
#
# ---------------------------------------------------------------------------
# 环境变量（便于排障与测试）
#
#   XG2010G_BOOT_PORT     目标端口         默认 lan1
#   XG2010G_BOOT_DEADLINE 窗口总时长       默认 300 秒（5 分钟）
#   XG2010G_BOOT_WAIT     开始前的等待     默认 45 秒（等网络与链路稳定）
#   XG2010G_BOOT_SAMPLE   判据采样窗口     默认 10 秒
#   XG2010G_BOOT_MAXFLAP  最多重新协商次数 默认 4
#   XG2010G_BOOT_POLL     轮次之间的间隔   默认 10 秒
#   XG2010G_ALWAYS_FLAP   非空则无条件先协商一次

set -u

PORT="${XG2010G_BOOT_PORT:-lan1}"
DEADLINE="${XG2010G_BOOT_DEADLINE:-300}"
WAIT_BOOT="${XG2010G_BOOT_WAIT:-45}"
SAMPLE="${XG2010G_BOOT_SAMPLE:-10}"
MAX_FLAP="${XG2010G_BOOT_MAXFLAP:-4}"
POLL="${XG2010G_BOOT_POLL:-10}"
ALWAYS_FLAP="${XG2010G_ALWAYS_FLAP:-}"

WAIT_FLAP=3       # down 之后等多久再 up
WAIT_AFTER=8      # up 之后等多久再判

LOCK=/var/lock/xg2010g-lan1-up.pid
TAG=xg2010g-lan1-up

log() {
	logger -t "$TAG" "$*"
}

# ---------------------------------------------------------------------------
# 零 fork 的 sysfs 读取（`read x < file` 是内建，0 次 fork）
# ---------------------------------------------------------------------------
RX=''
read_rx() {
	RX=''
	read -r RX < "/sys/class/net/$1/statistics/rx_bytes" 2>/dev/null || RX=''
	[ -n "$RX" ]
}

CARRIER=''
read_carrier() {
	CARRIER=''
	read -r CARRIER < "/sys/class/net/$1/carrier" 2>/dev/null || CARRIER=''
	[ -n "$CARRIER" ]
}

# ---------------------------------------------------------------------------
# 可中断的等待
#
# 为什么不能直接 `sleep N`：POSIX sh 收到信号时会**先等当前前台命令结束**
# 才去执行 trap，于是 TERM 要等整个 sleep 走完才生效（最长 45 秒），
# `init.d stop` / `timeout` 看起来就像卡住了。
# 改成 1 秒粒度轮询 STOP 标志，信号后最多 1 秒退出。代价是每秒 1 次 fork，
# 只在开机后这 5 分钟里有，可以忽略。
#
# 返回值：0 = 正常等完；1 = 被中断
# ---------------------------------------------------------------------------
STOP=0
elapsed=0

wait_for() {
	w="$1"
	i=0
	while [ "$i" -lt "$w" ]; do
		[ "$STOP" -eq 1 ] && return 1
		sleep 1
		i=$((i + 1))
		elapsed=$((elapsed + 1))
	done
	return 0
}

flap() {
	log "$PORT: forcing renegotiation (down/up)"
	ip link set "$PORT" down 2>/dev/null
	wait_for "$WAIT_FLAP" || return 1
	ip link set "$PORT" up 2>/dev/null
	wait_for "$WAIT_AFTER" || return 1
	return 0
}

# ---------------------------------------------------------------------------
# 并发保护
#
# 用 PID 文件而不是 mkdir 锁：mkdir 锁一旦因为进程被强杀（SIGKILL 不触发 trap）
# 就会残留，之后永远挡住检查。PID 文件可以先探测持有者是否还活着，能自愈。
#
# 注意 trap 的写法：不能写成 `trap 'rm -f "$LOCK"' INT TERM` —— POSIX sh 执行完
# 信号 trap 后会回到被中断的地方继续跑，TERM 只是删掉锁文件、进程仍活着。
# 必须让 TERM 只置标志、由 EXIT trap 负责清理。
# ---------------------------------------------------------------------------
acquire_lock() {
	if [ -f "$LOCK" ]; then
		old="$(cat "$LOCK" 2>/dev/null)"
		if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
			log "another instance (pid $old) is already running, exit"
			exit 0
		fi
		log "stale lock from pid ${old:-unknown}, taking over"
	fi
	echo $$ > "$LOCK"
	trap 'rm -f "$LOCK"' EXIT
	trap 'STOP=1' INT TERM
}

main() {
	[ -d "/sys/class/net/$PORT" ] || { log "$PORT does not exist, exit"; exit 0; }

	acquire_lock

	log "start: port=$PORT deadline=${DEADLINE}s wait=${WAIT_BOOT}s sample=${SAMPLE}s"

	wait_for "$WAIT_BOOT" || { log "interrupted during startup wait"; exit 0; }

	# 先把端口管理态拉起来（万一它根本没 up）
	ip link set "$PORT" up 2>/dev/null

	flaps=0
	if [ -n "$ALWAYS_FLAP" ]; then
		flaps=1
		flap || { log "interrupted while renegotiating"; exit 0; }
	fi

	result="timeout"

	while [ "$elapsed" -lt "$DEADLINE" ]; do
		[ "$STOP" -eq 1 ] && { log "interrupted"; exit 0; }

		# 对端没接 / 没开机 / 还没协商完 —— 等它，不动作
		if ! read_carrier "$PORT" || [ "$CARRIER" != "1" ]; then
			wait_for "$POLL" || { log "interrupted"; exit 0; }
			continue
		fi

		read_rx "$PORT" || { wait_for "$POLL" || exit 0; continue; }
		before="$RX"

		wait_for "$SAMPLE" || { log "interrupted"; exit 0; }

		read_rx "$PORT" || { wait_for "$POLL" || exit 0; continue; }
		after="$RX"

		if [ "$after" -gt "$before" ]; then
			result="up (rx_bytes $before -> $after)"
			break
		fi

		if [ "$flaps" -ge "$MAX_FLAP" ]; then
			wait_for "$POLL" || { log "interrupted"; exit 0; }
			continue
		fi

		flaps=$((flaps + 1))
		log "$PORT carrier=1 but rx_bytes frozen at $after, renegotiating ($flaps/$MAX_FLAP)"
		flap || { log "interrupted while renegotiating"; exit 0; }
	done

	if [ "$result" = "timeout" ]; then
		log "gave up after ${elapsed}s: $PORT is not carrying traffic"
	else
		log "done in ${elapsed}s: $PORT $result (renegotiations=$flaps)"
	fi

	exit 0
}

main
