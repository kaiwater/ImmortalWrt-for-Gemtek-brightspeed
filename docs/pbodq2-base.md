# pbodq2-base：XR1710G 的第二条构建线（内核 6.18.60 + mt76 10-28）

> 状态：**已构建并实机验证**（2026-11-15），作为后续候选线；
> 发布线仍是 `naoki66-base`，等这条线连续通过再切换。

## 1. 基线

```
上游    pbodq2/OpenWRT-W1700K-XR1710G
tag     ubi2-20261108（8b28a83c，2026-11-09 发布）
内核    6.18.60
mt76    0936617d（2026-10-28）
设备    gemtek,xr1710g-ubi（compat 2.0）
```

相对 `naoki66-base`：内核 6.18.55 → 6.18.60，mt76 467ae2e3（10-08）→ 0936617d（10-28），
板名/compat 变化（切换需 `sysupgrade -F`）。

## 2. overlay 内容

| 文件 | 作用 |
|---|---|
| `feeds.conf.default` | 换成 immortalwrt packages/luci + routing/telephony（pbodq2 原生只有 openwrt 三个源，缺 passwall/lucky/chinaDNS 等） |
| `custom/config.fragment` | 应用层包（passwall、sing-box、xray、chinaDNS、OAF、smartdns-ui、lucky、工具集） |
| `custom/files/**` | apk 源、channel_analysis 等 |
| `1710-ubi.config` | 构建种子（`gemtek_xr1710g-ubi`，已对齐 apk-mbedtls/wpad-wolfssl） |
| `package/oaf/**` | appfilter 7.0.2 + luci-app-oaf（从 kenzok8/small-package vendored） |
| `package/lucky/**` | lucky + luci-app-lucky（从 naoki66-base 取，immortalwrt feeds 不含） |
| `target/linux/airoha/dts/an7581-xr1710g-ubi.dts` | XR1710G DTS（fanboy/pbodq2 都没有） |
| `target/linux/airoha/image/an7581.mk` | XR1710G 设备块 + `SUPPORTED_DEVICES += gemtek,xr1710g` |
| `package/boot/uboot-tools/uboot-envtools/files/airoha_an7581` | `gemtek,xr1710g-ubi` 走 `ubootenv_add_ubi_default` |
| `target/linux/airoha/patches-6.18/746-*.patch` | PON PCS 的 RX 校准门（E2 半边上游 745 已有） |
| `package/kernel/mt76/patches/9995-*.patch` | beacon protection 宣告（mt76 0936617d 仍缺） |
| `patches/feeds/**` | feed 补丁（见 §4） |
| `scripts/apply-feed-patches.sh`、`include/feed-patches.mk` | feed 补丁自动应用钩子（来自 naoki66-base） |
| `scripts/fix-arm64-host-node.sh` | arm64 构建机替换 x86-64 host node（见 §4） |

## 3. 构建

```sh
./scripts/feeds update -a
./scripts/feeds install -a
rm -rf package/feeds/*/open-app-filter        # 与 package/oaf 同名包冲突
sh scripts/fix-arm64-host-node.sh             # 仅 arm64 宿主需要
cp 1710-ubi.config .config
cat custom/config.fragment >> .config
mkdir -p files && cp -a custom/files/. files/  # 自定义 overlay（CI 也在做）
# 本地 arm64：Go 引导与 naive 关闭（见 §4）
make defconfig && make -j$(nproc) world
```

> 漏掉 `cp -a custom/files/. files/` 时，`/etc/uci-defaults`、apk 源脚本和自定义
> LuCI 页面都不会进镜像——2026-11-24 的本地重建就漏了这一步，和 20261108 那版
> 对比时会看到文件差异。

本地 arm64 还需要：

```sh
# .config 里
# CONFIG_GOLANG_BUILD_BOOTSTRAP is not set
CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="/opt/go-bootstrap"   # 官方 go1.24.13 linux-arm64
```

## 4. 本地构建的四个坑（已用 feed 补丁/脚本固化）

1. **git 归档哈希不一致**：`msd_lite`、`vlmcsd`、`simple-obfs` 在镜像源取不到原始
   tarball，会现场重新打包，`PKG_MIRROR_HASH` 对不上。补丁把这些包的 hash 检查
   改成 `skip`（commit 仍然固定）。
2. **sing-box 的 naive 默认开启**：`SING_BOX_BUILD_NAIVE_OUTBOUND` 是 `def_bool y`，
   `.config` 关不掉，必拉 `libcronet`，而它的 gn 工具链只支持 linux/amd64。
   补丁把默认改成 `n`。
3. **host node 架构**：`feeds/packages/lang/node/node` 写死 `linux-x64`，
   arm64 宿主上 runner 是 x86-64 二进制，`npm` 直接 `Trace/breakpoint trap`，
   smartdns-ui 的 webui 编不出来。`scripts/fix-arm64-host-node.sh` 换成官方 arm64 Node 22。
4. **open-app-filter 重名**：immortalwrt/packages 里有旧的 `open-app-filter`
   （appfilter 6.x），与 `package/oaf` 同名，必须删 `package/feeds/*/open-app-filter`。
5. **MLO 接口漏出 flowtable（PPE 不生效）**：`ap-mld0` 注册晚于 fw4 首次装载；
   nft 在 netdev 注销时会把它从 flowtable 摘掉，重新注册后不会自动加回。结果是
   MLO 客户端的流量永远不硬件 offload：`/sys/kernel/debug/ppe/{bind,entries}`
   一直是空，BND/UNB 显示 0，转发全走 CPU，实测吞吐明显偏低。
   `custom/files/etc/init.d/fw4-flowtable`（START=99）在无线接口稳定后检查一次，
   缺设备才 `fw4 reload`；运行中临时修复也是 `fw4 reload`。
   另：`ppe/bind_rate` 开机读到 0（补丁默认 8），可
   `echo 8 > /sys/kernel/debug/ppe/bind_rate` 现场恢复。

## 5. 验证记录（2026-11-15）

- 镜像：91,439,988 B，sha256 `9d68e323f3b8fdef6d14e8653453cd0329bd031541b9ffc20d3a0894b076d89b`
- 保留配置 `sysupgrade -F` 刷入成功，板名 `gemtek,xr1710g-ubi`，无需 U-Boot 救砖
- 热重启 ×3：SSH 回来 57/110/107s，服务就绪 73/126/128s
- **冷启动 ×1**：121s 回来，10G WAN 一次点亮（`carrier=1`），三频/MLO、OAF 7.0.2、
  CA 120、passwall、dmesg 无异常、风扇/板温正常
- 待补：冷启动 ×5、Wi-Fi 吞吐/MLO 客户端、OAF 运行态抓流

## 6. 已知差异

- 本地 arm64 构建，Go 引导用预编译、无 `libcronet`（sing-box 无 naive 出站）
- CI 工作流尚未适配（`.github/workflows` 仍是 pbodq2 原生；GitHub Actions 对仓库
  处于禁用状态）
