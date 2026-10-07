#!/bin/sh
#
# XG2010G：维护 IPTV 上行（网桥 MAC + DHCP 租约 + 专网路由）
#
# ---------------------------------------------------------------------------
# 为什么需要这个
#
# 北京联通的 IPTV 专网对 ONU 做了 **IP 源地址校验**：只放行「当前 DHCP 租约
# 对应的 (MAC, IP)」。由此推出三条硬性要求，缺一不可：
#
#   1. 网桥 br-iptv 的 MAC 必须等于做 DHCP 的那个 MAC（光猫 MAC）。
#      否则运营商会静默丢弃我们的包 —— 表现是网关 ARP 永远解析不了。
#   2. IPTV 接口必须用 DHCP 拿到的地址（静态地址会被校验拦掉）。
#   3. 租约 1800 秒，到期后校验立刻失效，必须周期续约。
#
# 另外两个实测踩到的坑：
#   - 网桥 MAC 取的是「成员口里最小的 MAC」。lan_port=dummy0 时 dummy0 的随机 MAC
#     比光猫 MAC 小，网桥就会用 dummy0 的 MAC → 校验失败。
#     所以这里把 dummy0 的 MAC 钉成 fe:ff:ff:ff:ff:ff（大于光猫 MAC），
#     网桥就会稳定选到光猫 MAC，哪怕成员口变动也不会漂。
#   - `ip addr replace` 是「新增」不是「替换」，旧租约地址会以 secondary 形式
#     留在接口上并被优先选作源地址 → 必须先用 `ip addr flush` 清掉。
#
# DHCP 为什么不能直接在网桥上做：实测网桥对本机终结的 DHCP 应答不上送协议栈
# （应答的 L2 目的 MAC 是网桥自身 MAC），所以只能「借道」—— 把业务 VLAN 设备
# ct-iptv-svc 暂时移出网桥，在它上面做 DHCP，完成后再放回。
# 移出期间组播不受影响（组播走另一条 VLAN，仍在网桥里）。
#
# ---------------------------------------------------------------------------
# 用法
#
# 由 init.d 后台拉起，常驻循环：先做一次初始化，之后每 INTERVAL 秒续约一次。
# 手动跑一次可用： XG2010G_IPTV_ONCE=1 /etc/xg2010g-iptv-uplink.sh
#
# 环境变量：
#   XG2010G_IPTV_RENEW_INTERVAL  续约间隔秒数，默认 1200（租期 1800）
#   XG2010G_IPTV_ONCE            非空则只做一轮就退出（排障用）

set -u

BRIDGE=br-iptv
SVC=ct-iptv-svc
PON=pon0
DUMMY=dummy0
PREFIX=17
ROUTES="${XG2010G_IPTV_ROUTES:-210.13.0.0/16}"
INTERVAL="${XG2010G_IPTV_RENEW_INTERVAL:-1200}"
ONCE="${XG2010G_IPTV_ONCE:-}"

LOCK=/var/lock/xg2010g-iptv-uplink.pid
LEASEFILE=/tmp/xg2010g-iptv-lease.txt
LEASESCRIPT=/tmp/xg2010g-iptv-lease.sh
TAG=xg2010g-iptv-uplink

log() {
	logger -t "$TAG" "$*"
}

# dummy0 的 MAC 必须大于光猫 MAC，网桥才会选光猫 MAC
pin_dummy_mac() {
	[ -d "/sys/class/net/$DUMMY" ] || return 0
	read -r cur < "/sys/class/net/$DUMMY/address"
	[ "$cur" = "fe:ff:ff:ff:ff:ff" ] && return 0
	ip link set "$DUMMY" down 2>/dev/null
	ip link set "$DUMMY" address fe:ff:ff:ff:ff:ff 2>/dev/null
	ip link set "$DUMMY" up 2>/dev/null
	log "$DUMMY MAC $cur -> fe:ff:ff:ff:ff:ff"
}

# 网桥 MAC 必须等于光猫 MAC
pin_bridge_mac() {
	[ -d "/sys/class/net/$BRIDGE" ] || return 1
	read -r pon < "/sys/class/net/$PON/address"
	read -r cur < "/sys/class/net/$BRIDGE/address"
	[ "$cur" = "$pon" ] && return 0

	ip link set "$BRIDGE" down 2>/dev/null
	ip link set "$BRIDGE" address "$pon" 2>/dev/null
	ip link set "$BRIDGE" up 2>/dev/null
	sleep 2
	log "bridge MAC $cur -> $pon"
	return 0
}

# 借道续约：把租约地址挂到网桥上，并重加专网路由
renew_lease() {
	cat > "$LEASESCRIPT" <<'EOS'
#!/bin/sh
case "$1" in
	bound|renew) echo "$ip $mask $router" > /tmp/xg2010g-iptv-lease.txt ;;
esac
exit 0
EOS
	chmod +x "$LEASESCRIPT"
	rm -f "$LEASEFILE"

	# 借道：移出网桥 → DHCP → 放回
	ip link set "$SVC" nomaster 2>/dev/null
	sleep 2
	udhcpc -i "$SVC" -f -n -t 3 -T 3 -s "$LEASESCRIPT" -q >/dev/null 2>&1
	ip link set "$SVC" master "$BRIDGE" 2>/dev/null
	sleep 2

	ip=''; gw=''
	read -r ip mask gw < "$LEASEFILE" 2>/dev/null || true
	if [ -z "${ip:-}" ]; then
		log "renew failed: no lease"
		return 1
	fi

	# 必须先 flush，否则旧租约地址会以 secondary 残留并被选作源地址
	ip addr flush dev "$BRIDGE" scope global 2>/dev/null
	ip addr add "$ip/$PREFIX" dev "$BRIDGE" 2>/dev/null

	for r in $ROUTES; do
		ip route replace "$r" via "$gw" dev "$BRIDGE" 2>/dev/null
	done

	log "lease applied: $ip/$PREFIX gw=$gw"
	return 0
}

# 并发保护：PID 文件（mkdir 锁被 SIGKILL 后会残留，PID 文件能自愈）
# 注意 trap 写法：POSIX sh 执行完信号 trap 会回到中断处继续跑，
# 必须让 TERM 走 exit，由 EXIT trap 清理。
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
	trap 'rm -f "$LOCK" "$LEASESCRIPT"' EXIT
	trap 'exit 0' INT TERM
}

main() {
	[ -d "/sys/class/net/$BRIDGE" ] || { log "$BRIDGE does not exist, exit"; exit 0; }

	acquire_lock
	pin_dummy_mac
	sleep 5

	while :; do
		pin_bridge_mac
		renew_lease
		[ -n "$ONCE" ] && exit 0
		sleep "$INTERVAL"
	done
}

main
