#!/bin/sh
#
# XG2010G：10G 链路开机自检 + 自动重新协商
#
# ---------------------------------------------------------------------------
# 为什么需要这个
#
# 这台机器的两个 10G 口（lan1 / lan2）用 RTL8261BE PHY。开机建立链路时存在竞态：
# 双方 PHY 都会报 Link is Up / Link detected: yes，但 SerDes/PCS 的数据通路
# 可能没有真正同步 —— 结果 MAC 层一个字节都收不到。
#
# 2026-10-06 就发生过一次：11:09 重启后，lan1 的 rx_bytes 一直卡在 0，
# 持续了 1 小时 50 分钟；接在 lan1 上的 XR1710G（它自己 uptime 9 天，完全无辜）
# 以及它后面的全部设备 —— 无线和有线 —— 集体失联。手动
# `ip link set lan1 down; up` 立刻恢复。
#
# ---------------------------------------------------------------------------
# 判据
#
#   carrier=1（PHY 说链路是 up 的）  且  rx_bytes=0（MAC 层什么都没收到）
#
# 注意：`ethtool` 的 "Link detected: yes" 在 PHY 层是骗人的，不能作为判据；
# 判断链路是否真的通，只能看 rx_bytes 有没有增长。
#
# 正常端口哪怕对端很空闲，也会有广播包（ARP / DHCP / mDNS 之类），rx_bytes 不会是 0，
# 所以这个判据不会误伤正常端口。对端没接或没开机时 carrier=0，直接跳过。
#
# ---------------------------------------------------------------------------
# 行为
#
# 开机后等一会儿，对每个 10G 口做一次检查；只对「真死」的端口强制 down/up 重新协商，
# 然后复查。最多重试 3 轮，之后放弃并留一条日志。
# 只跑这一次，不会在正常运行期间反复动端口。

set -u

PORTS="${XG2010G_10G_PORTS:-lan1 lan2}"
RETRY_MAX=3
WAIT_BOOT=45      # 等网络和链路稳定
WAIT_FLAP=3       # down 后等多久再 up
WAIT_AFTER=8      # up 后等多久再看 rx_bytes
WAIT_ROUND=10     # 轮次之间

LOCK=/var/lock/xg2010g-10g-linkcheck.pid

TAG=xg2010g-10g

log() {
	logger -t "$TAG" "$*"
}

rx_of() {
	cat "/sys/class/net/$1/statistics/rx_bytes" 2>/dev/null
}

carrier_of() {
	cat "/sys/class/net/$1/carrier" 2>/dev/null
}

# 对单个端口做检查，必要时重新协商。
# 返回值：0 = 不需要再试；1 = 重新协商后仍然不通
check_port() {
	p="$1"
	round="$2"

	[ -d "/sys/class/net/$p" ] || return 0

	# 没有载波 = 对端没接 / 没开机，不是我们要处理的情况
	[ "$(carrier_of "$p")" = "1" ] || return 0

	rx="$(rx_of "$p")"
	[ -n "$rx" ] || return 0
	[ "$rx" -gt 0 ] && return 0

	# 到这里说明：PHY 说链路是 up 的，但一个字节都没收到 → 死链路
	log "round $round: $p carrier up but rx_bytes=0, forcing renegotiation"

	ip link set "$p" down 2>/dev/null
	sleep "$WAIT_FLAP"
	ip link set "$p" up 2>/dev/null
	sleep "$WAIT_AFTER"

	rx2="$(rx_of "$p")"
	if [ -n "$rx2" ] && [ "$rx2" -gt 0 ]; then
		log "round $round: $p recovered (rx_bytes=$rx2)"
		return 0
	fi

	log "round $round: $p still dead after renegotiation"
	return 1
}

main() {
	# 防止并发：init 拉起之后如果又被手动执行一次，两个实例同时协商同一个口会互相打架。
	#
	# 用 PID 文件而不是 mkdir 锁：mkdir 锁一旦因为进程被强杀（SIGKILL 不触发 trap）
	# 就会残留，之后永远挡住检查。PID 文件可以先探测持有者是否还活着，能自愈。
	if [ -f "$LOCK" ]; then
		old="$(cat "$LOCK" 2>/dev/null)"
		if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
			log "another instance (pid $old) is already running, exit"
			exit 0
		fi
		log "stale lock from pid ${old:-unknown}, taking over"
	fi
	echo $$ > "$LOCK"
	trap 'rm -f "$LOCK"' EXIT INT TERM

	sleep "$WAIT_BOOT"

	round=1
	while [ "$round" -le "$RETRY_MAX" ]; do
		need_more=0

		for p in $PORTS; do
			check_port "$p" "$round" || need_more=1
		done

		[ "$need_more" -eq 0 ] && break

		round=$((round + 1))
		[ "$round" -le "$RETRY_MAX" ] && sleep "$WAIT_ROUND"
	done

	[ "$round" -gt "$RETRY_MAX" ] && log "gave up after $RETRY_MAX rounds"
	exit 0
}

main
