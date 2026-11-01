# XR1710G custom layer (naoki66-base)

本目录是 `naoki66-base` 分支的定制层，基于 `naoki66/ImmortalWrt-for-Gemtek-brightspeed`。
`lowaka` 分支和 `master` 均未修改。

## 范围

- 只针对 **XR1710G**，只构建 **0x700000** 布局（`gemtek_xr1710g`）
- 不再构建 `gemtek_xr1710g-ubi`（0x20000，需要 bl2/fip 新 bootloader）
- 不再包含 XG2010G / 2010 相关配置和 workflow
- `custom/config.fragment` 只放应用层
- 硬件/platform 相关包由 naoki66 的 `target/linux/airoha/image/an7581.mk` / `DEVICE_PACKAGES` 决定

## 软件构成

参考 `kaiwater/wrt_release` 的 AP8220 `compile_base` + `proxy`：

- 透明代理：**passwall + sing-box**
- 应用：lucky、smartdns、ttyd、upnp、wol、filemanager、commands、oaf、zerotier、autoreboot、vlmcsd、ddns-go、rtp2httpd、btop、htop
- 工具：chinadns-ng、coreutils、socat、screen、tcpdump、nano、iperf3、xz-utils、bc、hostapd-utils、umdns、dmesg、bind-dig、bash、at、openssl-util、zram

明确移除：

- istorex / pbr / adguardhome
- OpenClash / argon-config / daed
- samba_ksmbd（没有 USB 存储需求）
- 2010 专用内容
- `custom/files/etc/uci-defaults/99-custom-network.sh`（不再强制 192.168.5.1）

## 文件

```text
custom/config.fragment                         应用层
custom/files/etc/uci-defaults/99-apk-mirror-official.sh
custom/files/www/luci-static/resources/view/status/channel_analysis.js
custom/upstream/build-firmware.yml.sha         上游 workflow 同步提示
```

没有 `custom/feeds.conf.custom`，因此不会引入 daede / 其他额外 feed。

## 构建

`.github/workflows/build-firmware.yml`：

- 只保留 `1710.config` 选项
- 不再接受 `2010.config`
- 只构建 `gemtek_xr1710g`（0x700000）

手动触发：

```sh
gh workflow run build-firmware.yml --ref naoki66-base
```
