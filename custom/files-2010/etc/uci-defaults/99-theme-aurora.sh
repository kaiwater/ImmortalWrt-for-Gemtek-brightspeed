#!/bin/sh
# XG2010G 定制层：把默认界面风格设为 Aurora（luci-theme-aurora）。
# 只在首次开机 / 刷机后首次启动时执行一次。
#
# 主题资源路径经实机确认：/www/luci-static/aurora/ ，对应
#   luci.main.mediaurlbase = /luci-static/aurora
# 主题自身也带 etc/uci-defaults/30_luci-theme-aurora，这里用 99 编号兜底覆盖，
# 保证无论主题包自身的默认值如何，最终都会落到 Aurora。
[ -f /etc/config/luci ] || exit 0

cur="$(uci -q get luci.main.mediaurlbase)"
case "$cur" in
	*/aurora)
		;;
	*)
		uci -q set luci.main.mediaurlbase='/luci-static/aurora'
		uci -q commit luci
		logger -t xg2010g-defaults "default LuCI theme set to aurora"
		;;
esac
exit 0
