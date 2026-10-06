#!/bin/sh
# 首次开机执行：把 LAN 管理地址固定为 192.168.5.1，
# DHCP 下发 192.168.5.150-192.168.5.249（掩码 255.255.255.0）。
#
# 池起点取 150 而不是 100：静态绑定里有 192.168.5.101/102/103/104/111，
# 落在 .150-.249 之外，和动态池完全错开。dnsmasq 虽然会把静态绑定从动态池里
# 排除掉（不会直接冲突），但没有必要把静态地址放在池子里面。
#
# 注意：本脚本只在「首次开机 / 刷机后首次启动」执行一次（/etc/init.d/boot 会
# source 一遍然后删除）。所以改这里不会影响已经刷好的设备，只影响之后新刷的。
uci -q set network.lan.ipaddr='192.168.5.1'
uci -q set network.lan.netmask='255.255.255.0'
uci -q set dhcp.lan.start='150'
uci -q set dhcp.lan.limit='100'
uci -q set dhcp.lan.leasetime='12h'
uci -q commit network
uci -q commit dhcp
exit 0
