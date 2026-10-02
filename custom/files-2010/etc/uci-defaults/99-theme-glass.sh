#!/bin/sh
# XG2010G 定制层：把默认界面风格设为 glass（luci-theme-glass）。
# 只在首次开机 / 刷机后首次启动时执行一次。
[ -f /etc/config/luci ] || exit 0

cur="$(uci -q get luci.main.mediaurlbase)"
case "$cur" in
	*/glass)
		;;
	*)
		uci -q set luci.main.mediaurlbase='/luci-static/glass'
		uci -q commit luci
		logger -t xg2010g-defaults "default LuCI theme set to glass"
		;;
esac
exit 0