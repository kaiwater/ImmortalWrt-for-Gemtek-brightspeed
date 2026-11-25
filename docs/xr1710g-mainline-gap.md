# XR1710G：OpenWrt 主线支持 vs 我们 overlay 的差异清单

对照时间：2026-11-25
官方合并：`openwrt/openwrt` commit `980a7404`（2026-11-24）
官方基线：kernel 6.18.64，mt76 `0936617d`（2026-10-28，与当前一致）
ImmortalWrt master：**尚未同步**该设备（有 watcher 盯着）

## 1. 官方已经覆盖的部分（我们可逐步移除）

- `target/linux/airoha/image/an7581.mk`：`Device/gemtek_xr1710g-ubi`
- DTS：`an7581-gemtek_xr1710g-ubi.dts` + `an7581-gemtek-common.dtsi`
  （LED、NCT7802 风扇、PCIe0/1/2 及 reset pins、NPU dtsi、MDIO、PON PCS）
- `an7581/base-files/etc/board.d/01_leds`、`02_network`、`airoha_fan`
  —— 均含 gemtek/xr1710g 分支
- `an7581/base-files/lib/upgrade/platform.sh` —— 含 gemtek/xr1710g 升级逻辑
- `uboot-envtools/files/airoha_an7581` —— `gemtek,xr1710g-ubi` 走
  `ubootenv_add_ubi_default`，与我们的条目完全一致
- 设备基础包：`airoha-en7581-mt7996-npu-firmware`、`fitblk`、
  `kmod-hwmon-nct7802`、`kmod-mt7996-firmware`、`rtl826x-firmware`、
  `wpad-basic-mbedtls`

## 2. 差异与仍需我们维护的部分

| 项目 | 官方 | 我们（pbodq2） | 迁移动作 |
|---|---|---|---|
| DTS | `an7581-gemtek-common.dtsi` + `an7581-gemtek_xr1710g-ubi.dts` | 单文件 `an7581-xr1710g-ubi.dts` | 以官方为准，逐节点对比本地改动（LED/PHY/PCIe/PON/GPIO） |
| 设备 compat | 设备块**没有** `DEVICE_COMPAT_VERSION`；`05_compat-version` 只对 `gemtek,w1700k-ubi` 设 2.0 | `DEVICE_COMPAT_VERSION := 2.0` + `SUPPORTED_DEVICES += gemtek,xr1710g` + 提示文本 | **注意**：官方镜像按 1.0 生成，刷到我们 2.0 设备需 `-F`；建议给上游提 issue |
| 设备额外包 | 无 LuCI/应用包 | luci、luci-app-airoha-flowsense、luci-app-airoha-npu、luci-app-w1700k-fancontrol、luci-app-usteer、wpad-wolfssl、dnsmasq-full、tailscale、wireguard、nft kmods、mtd-rw、apk-mbedtls | 留在我们的设备块 / `custom/config.fragment` |
| 内核补丁 | 无 XR1710G 专属补丁 | `746-net-pcs-airoha-extend-rx-calib-to-pon`、`YYH-203/204` pinctrl、`YYH-220` USB2 SerDes、`YYH-914/914b` PCIe PERST、`746-net-dsa-mt7530-...` | 逐项确认是否仍需要（官方 PCIe/PHY 支持可能已覆盖） |
| mt76 | `0936617d` | `0936617d` + `9994/9996/9997/129` 等回填 | 继续按钉提交 + 回填，等 pin 前进后删除 |
| 风扇/LED | `airoha_fan` + `01_leds` 已含 gemtek | 相同，另有 w1700k 风扇 LuCI | 验证即可 |
| 其他 overlay | 无 | `custom/files`（apk 源、channel_analysis）、`package/oaf`、`package/lucky`、`fw4-mlo-offload` 服务 | 继续保留 |

## 3. 迁移前必须确认

1. **compat 版本**：官方 XR1710G 镜像没有 2.0 标签，和我们当前设备/镜像的
   `r0+…` 2.0 不一致。双向刷机都可能需要 `sysupgrade -F`，需实测确认，并考虑
   给上游补 `DEVICE_COMPAT_VERSION := 2.0`。
2. **DTS 本地项**：我们单文件 DTS 417 行，官方拆成 87 + 363 行；需要逐节点确认
   746 PON 校准、PCIe PERST 时序、pinctrl GPIO、USB2 SerDes 是否已在官方覆盖。
3. **包集合**：官方是 `wpad-basic-mbedtls` + 无 LuCI；我们的 passwall/OAF/lucky/
   smartdns-ui/haproxy 等仍要自带。
4. **mt76**：官方 pin 未前进，L1 修复仍靠 9996/9997。

## 4. 建议路线

1. 等 **ImmortalWrt master** 同步该设备（watcher `immortalwrt mainline XR1710G watch`），
   再把 custom 层 rebase 到 ImmortalWrt master —— 设备支持来自官方、包体系不变。
2. 迁移时以官方 DTS 为基准做节点级 diff，保留仍需要的本地补丁。
3. 保留 `custom/files`、`package/oaf`、`package/lucky`、`custom/config.fragment`、
   mt76 回填与 `fw4-mlo-offload`。
4. 刷机前按约定备份 iCloud；先做一次 `-F` 刷入 + 冷启动验证，再决定是否切换发布线。
