#!/bin/sh
# XR1710G defaults layer: force the apk binary feed mirror to the official host.
#
# Why this file exists
# --------------------
# The package emortal/default-settings ships files/99-default-settings-chinese,
# which does:
#
#     apk_mirror="$(uci -q get system.@imm_init[0].apk_mirror)"
#     [ -z "$apk_mirror" ] && apk_mirror="https://mirrors.vsean.net/openwrt"
#     uci -q set system.@imm_init[0].apk_mirror="$apk_mirror"
#     sed -i.bak "s,https://downloads.immortalwrt.org,$apk_mirror,g" \
#         /etc/apk/repositories.d/distfeeds.list
#
# Two problems with that behaviour:
#
#   1. It hardcodes a third-party mirror. mirrors.vsean.net merely issues a
#      302 redirect to mirrors.pku.edu.cn, so the router silently depends on
#      a proxy host we do not control. We want the official source only.
#
#   2. The host substitution is applied blindly to a file that also lists
#      third-party *source* feeds (daede, plus whatever else
#      custom/feeds.conf.custom adds). Those feeds have no published binary
#      index anywhere, so the rewrite yields URLs that 404 under every
#      mirror. Their packages are compiled into the image at build time, so
#      they need no runtime feed entry at all.
#
# Running order: files in /etc/uci-defaults are sourced in name order, and
# this one sorts after 99-default-settings-chinese, so the value set here wins
# over the upstream default while the directory still exists.
#
# Effect on an already flashed device: none. /etc/uci-defaults runs only on
# the first boot after flashing.
#
# Note for XG2010G: custom/files-2010/etc/uci-defaults/99-apk-mirror-official.sh
# carries the same logic. Both run on that machine and agree, so the order
# between them does not matter.

OFFICIAL='https://downloads.immortalwrt.org'

[ -f /etc/config/system ] || exit 0

uci -q get system.@imm_init[0] >/dev/null 2>&1 || uci -q add system imm_init

cur="$(uci -q get system.@imm_init[0].apk_mirror)"

if [ "$cur" = "$OFFICIAL" ]; then
	exit 0
fi

uci -q set system.@imm_init[0].apk_mirror="$OFFICIAL"
uci -q commit system
logger -t xr1710g-defaults "apk_mirror set to $OFFICIAL (was: ${cur:-unset})"

exit 0
