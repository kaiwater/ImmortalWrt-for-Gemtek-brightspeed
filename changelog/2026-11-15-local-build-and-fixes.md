# 2026-11-15 本地构建（arm64 Docker）与两个编译修复

本次构建是 GitHub Actions 被禁用后的本地替代方案，产物已就绪，等待实机测试。

## 产物

```
immortalwrt-naoki66-xr1710g-snapshot-airoha-an7581-gemtek_xr1710g-squashfs-sysupgrade.itb
大小    76,128,551 字节（73 MiB）
SHA256  9352c45bd3272abb2c76345b37996b045cfd0a8c5b1c22663bcb9fc0b699b6a1
内核    6.18.55~002c188fb7
包数    406
```

与上一个 release（`20261104-acbd046c`，408 包）相比，**只少了 `libcronet` 和
`smartdns-ui` 两个包**，没有别的增删；其余变化都是包版本更新（luci 26.302 → 26.315、
dawn 2026.06.10 → 2026.11.11、xray-core、luci-app-passwall 等）。

内容与本轮计划的发布一致：CA 黑名单（bundle 120 条，无 `emSign ECC Root CA - G3`）、
PCS 630（`pcs-airoha-common.c` 的校准门同时匹配 `airoha,an7581-pcs-eth` 与
`airoha,an7581-pcs-pon`）、i2c/nct7802 风扇修复、openssh-client。

## 构建中修掉的三个真实故障

### 0. 本地构建顺序错误导致两个 LuCI 应用被静默丢弃（仅本地，不是仓库问题）

第一版本地产物只有 402 个包，比上一个 release 少了 `luci-app-lucky` 和
`luci-app-mlo`。原因不在包本身，而在本地的构建顺序：

```sh
# 我最初的 build2.sh
make defconfig      # ← 此时 feeds 还没 update/install
./scripts/feeds update -a
./scripts/feeds install -a
```

`package/lucky/luci-app-lucky` 和 `package/emortal/luci-app-mlo` 的 Makefile 都
`include $(TOPDIR)/feeds/luci/luci.mk`。第一次 `defconfig` 时 `feeds/luci` 还不存在，
元数据扫描只写出一个空的 `tmp/info/.packageinfo-*`（只剩 `Source-Makefile:` 一行），
Kconfig 里因此没有这两个符号，`CONFIG_PACKAGE_luci-app-lucky=y` 被当成未知符号丢掉。
之后即使 feeds 装好了，`tmp/info` 是缓存，`make defconfig` 也不会重扫。

修法：删掉 `tmp/info` 和 `tmp/.config-package.in` 强制重扫。重扫后两个包回到
`.config`，产物 406 包。

> **CI 不受影响**：`build-firmware.yml` 先装 feeds 再生成配置，顺序是对的。
> 这条记在这里，是为了以后本地复现时不要重蹈覆辙：**feeds 必须在 defconfig 之前**。

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

### 2. smartdns-ui 在 arm64 宿主上构建失败（已修正结论，2026-11-15 晚）

smartdns `48.4` 新增了 Rust 面板 `smartdns-ui`，其 `Build/Compile` 里执行：

```sh
pushd smartdns-webui ; npm install ; npm run build ; popd
```

当时看到 buildroot 里没有 `npm`，判断为上游打包缺陷。**这个结论是错的**，实际原因有两个：

1. `feeds/packages/lang/node/node/Makefile` 把宿主二进制写死成 x64：

   ```make
   NODEJS_BIN:=node-v$(PKG_VERSION)-linux-x64.tar.gz
   ```

   x86_64 构建机上没问题；**arm64 构建机上装进去的是 x86-64 的 node**，
   执行时只会得到 `rosetta error: failed to open elf at /lib64/ld-linux-x86-64.so.2`
   和 `Trace/breakpoint trap`（子 shell 没有 `set -e`，报错被吞掉，
   最后只在 `cp smartdns-webui/out` 处暴露）。

2. 该 makefile 的 `Host/Install` 虽然删了 `bin/npm`，但 `staging_dir/hostpkg/`
   里仍留有 `lib/node_modules/npm`（tar 解包进来的），所以 x86 构建机上
   npm 是可用的——**CI 一直是能编 smartdns-ui 的**，1104 的 manifest 里就有它。

修正后的处理：

- `1710.config` 恢复 `CONFIG_PACKAGE_smartdns-ui=y`；
- `.github/workflows/build-firmware.yml` 增加 `actions/setup-node@v4`（Node 22），
  把 webui 需要的 Node/npm 显式装好，不再依赖 system 里碰巧存在的 npm；
- 本地 arm64 验证时，把 `staging_dir/hostpkg/bin/node` 换成官方 arm64 的
  Node 22.11（仅本地，不入库），`npm install` + `next build` 通过
  （`✓ Compiled successfully`），产出 `smartdns-ui-48.4-r1.apk`（6.5 MB）。

> Next.js 16 / React 19 要求 Node >= 20.9，Node 22 是验证过的版本。

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
