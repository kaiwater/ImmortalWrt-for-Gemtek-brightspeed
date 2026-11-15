# 2026-11-15 本地构建（arm64 Docker）与两个编译修复

本次构建是 GitHub Actions 被禁用后的本地替代方案，产物已就绪，等待实机测试。

## 产物

```
immortalwrt-naoki66-xr1710g-snapshot-airoha-an7581-gemtek_xr1710g-squashfs-sysupgrade.itb
大小   76,128,551 字节（73 MiB）
SHA256 19d9963e77bad62e0a5136ed8459dadb5a4dc64f1d95b6cf6c4cf40199bb91a8
版本   2026-11-15-3447fbe（基于提交 3447fbe07b）
内核   6.18.55~002c188fb7
```

内容与本轮计划的发布一致：CA 黑名单（bundle 120 条，无 `emSign ECC Root CA - G3`）、
PCS 630（`pcs-airoha-common.c` 的校准门同时匹配 `airoha,an7581-pcs-eth` 与
`airoha,an7581-pcs-pon`）、i2c/nct7802 风扇修复、openssh-client。

## 构建中修掉的两个真实故障

### 1. dawn 的 6 GHz feed 补丁已过时

`patches/feeds/packages/net/dawn/100-dawn-6ghz-band.patch` 是针对 dawn
`2026.10.x` 写的，向 `datastorage.h` / `datastorage.c` / `dawn_uci.c` 加
`DAWN_BAND_80211A_6G` 和三元数组。

dawn 升级到 `2026.11.11~cf43b0f1` 后，上游已经自己实现了 6 GHz：

```c
enum dawn_bands {
    DAWN_BAND_80211G,
    DAWN_BAND_80211A,
    DAWN_BAND_80211AX,   /* 6 GHz，配置名 802_11ax */
    __DAWN_BAND_MAX
};
```

配置名、`max_band_freq`（2500/5925/7125）和 `dawn_uci.c` 的三元数组都已在上游，
feed 自带的 `files/dawn.config` 也有 `config metric '802_11a_6g'`。
我们的补丁因此三处 hunk 全部 FAILED。

**处理：删除补丁**（`git rm patches/feeds/packages/net/dawn/100-dawn-6ghz-band.patch`）。
不是 rebase——上游的实现比我们的更完整（含 7125 MHz 上界和注释）。

### 2. smartdns-ui 无法构建（上游打包问题）

smartdns `48.4` 新增了 Rust 面板 `smartdns-ui`，其 `Build/Compile` 里执行：

```sh
pushd smartdns-webui ; npm install ; npm run build ; popd
```

但 OpenWrt 的 `feeds/packages/lang/node/node/Makefile` 在 `Host/Install` 里显式删除 npm：

```make
rm -f $(1)/bin/npm
rm -f $(1)/bin/npx
rm -rf $(1)/lib/node_modules/npm
```

也就是说 **buildroot 里根本没有 npm**，`npm install` 失败（子 shell 未 `set -e`，
错误被吞掉），随后 `cp smartdns-webui/out` 找不到目录而报错。
这与宿主机架构无关，x86 CI 上同样会失败。

**处理：`1710.config` 里 `CONFIG_PACKAGE_smartdns-ui` 改为 not set。**
smartdns 本体保留；`luci-app-smartdns` 的 `INCLUDE_WebUI` 本来就没开。

> 如果以后需要这个面板，正确做法是给 `node/host` 加 npm，或给 smartdns-ui 打补丁
> 把 webui 步骤做成可选，而不是在 config 里打开它。

## 本地构建与 CI 的差异（仅本地，不入库）

| 项 | CI（x86_64） | 本次本地（arm64 Docker） |
|---|---|---|
| Go 工具链引导 | 从源码构建 `golang-bootstrap` | `CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="/opt/go-bootstrap"`，用官方 go1.24.13 linux-arm64 |
| `libcronet` / sing-box naive 出站 | 会构建 | 关闭（`init_env.sh` 只支持 Linux x86_64） |
| `smartdns-ui` | 关闭（见上，CI 同样构建不了） | 关闭 |

宿主机是 arm64，`golang-bootstrap` 的自举链从 go1.4.3 开始，其
`BOOTSTRAP_GO_VALID_OS_ARCH` 不含 `linux/arm64`，因此必须换预编译引导。
这两项差异只影响本地复现方式，不影响镜像里的应用层内容（naive 出站本就没启用）。

## 构建环境

```
Docker Desktop  8 vCPU / 16 GiB，磁盘 68 GiB
容器            ubuntu:24.04 (linux/arm64)，/build/openwrt 在容器盘上（大小写敏感）
源码            naoki66-base @ 3447fbe07b
```

注意：宿主机 APFS 大小写不敏感，直接在 `/Users` 下构建会触发
`OpenWrt can only be built on a case-sensitive filesystem`，所以源码放在容器内。
另外 Docker Desktop 的磁盘只能小步扩容（61 GiB → 68 GiB 成功，直接设 100 GiB 会启动失败）。

## 待做

- 实机刷写与验证（等用户醒来一起做）：冷/热启动、WAN 10G、风扇板温、Wi-Fi/MLO、CA、包清单
- 若要发布：等 Actions 恢复后由 CI 复现同一提交，或手工把本地产物发 Release
