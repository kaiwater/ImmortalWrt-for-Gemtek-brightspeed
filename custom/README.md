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
- 应用：lucky、smartdns、ttyd、upnp、wol、filemanager、commands、zerotier、autoreboot、vlmcsd、ddns-go、rtp2httpd、btop、htop
- 工具：chinadns-ng、coreutils、socat、screen、tcpdump、nano、iperf3、xz-utils、bc、hostapd-utils、umdns、dmesg、bind-dig、bash、at、openssl-util、openssh-client、zram
- `libffi`：仅为构建期修复（python3 以 `--with-system-ffi` 编译但 feed 未声明 target libffi 依赖），不是用户功能

### libffi 来源

ImmortalWrt 已把 `libffi` 从 `packages` feed 移到核心树 `package/libs/libffi`
（openwrt/packages 同样移除）。`naoki66` 基线尚未同步这一步，导致：

```text
WARNING: No feed for package 'libffi' found
Modules/_ctypes/_ctypes.c:119:10: fatal error: ffi.h: No such file or directory
```

因此本分支直接回填 `package/libs/libffi/`（取自 `immortalwrt/immortalwrt` master，
libffi 3.8.0），行为与上游一致，后续同步上游时该目录内容相同、不会冲突。


明确移除：

- istorex / pbr / adguardhome
- luci-app-oaf：naoki66 的 feeds 里没有 OpenAppFilter，需要额外第三方 feed 才能编入，故不启用
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

### 缓存布局

所有 cache 的 **restore 都在 Install feeds 之前**，save 用 `always()` 放在 job 末尾：

| 缓存 | 路径 | key | 作用 |
|---|---|---|---|
| `dl` | `dl/` | `feeds.conf.default` + `1710.config` + `config.fragment` 的 hash | 复用 `make download` 的源码包，不再重复下载 |
| `ccache` | `.ccache`（`CONFIG_CCACHE=y`） | 同上 hash + `run_id`，restore-keys 逐级回退 | 复用已编译对象：工具链、内核、包 |

这样 feeds / download / 工具链 / 包编译任何一步失败，下一次运行都能直接接着上次的进度，
而不是从零重来。ccache 用 `CCACHE_COMPRESS=1`、`CCACHE_MAXSIZE=2G`，两份缓存合计控制在
仓库 10 GiB 配额内。

手动触发：

```sh
gh workflow run build-firmware.yml --ref naoki66-base
```
