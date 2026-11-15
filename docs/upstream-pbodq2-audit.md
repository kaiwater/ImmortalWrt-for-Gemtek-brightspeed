# 旧 fork（kaiwater/OpenWRT-W1700K-XR1710G）工作审计

> 对比对象：
> - 旧 fork：`kaiwater/OpenWRT-W1700K-XR1710G`，默认分支 `ubi2`，最后推送 2026-11-01
> - 新上游：`pbodq2/OpenWRT-W1700K-XR1710G` tag `ubi2-20261108`（`8b28a83c`）
> - 共同祖先：`7d0bf92bee`（2026-10-26）
>
> 结论：旧 fork 的 **65 个提交**中，**41 个已在新 tag 中**（内容相同、SHA 不同），
> **24 个是旧 fork 独有**，其中真正需要保留的只有 4～5 项。

## 1. 已在新 tag 中（41 个，无需搬）

按主题归纳（同名提交存在于 `ubi2-20261108` 历史里，内容相同、SHA 不同）：

| 主题 | 代表提交 |
|---|---|
| mt76 NPU / 6GHz | npu rx descriptor ownership、6 GHz EHT320、mt7996 truncated txfree |
| PHY / PCIe | RTL8261NBE 冷启动、EN7581 PCIe reset sequencing、PCIe topology |
| XR1710G 设备支持 | add support for Gemtek XR1710G、identify as Gemtek、WLAN NPU mailbox |
| 稳定性补丁 | cmonroe 稳定性补丁、Reliability and compatibility patches、Lorenzo airoha patches |
| 流卸载 | flowtable 系列、bridge flowtable、cross-ingress L2 keys、TTL |
| 其他 | EIP93、HSUART、cpufreq/PM、W25N04LV、ramoops、iperf3 性能、txpower |

**处理：丢弃（上游已有）。** 不要按 SHA 重复搬运。

## 2. 旧 fork 独有（24 个）与处理决定

### 2.1 建议保留到 overlay（4 项）

| 提交 | 内容 | 理由 |
|---|---|---|
| `9f45f0a2f4` | label XR1710G layout and **accept `gemtek,xr1710g`** | 新 tag 只有 `-ubi` 板名；同时接受两个名字可避免来回切换都要 `-F` |
| `0800e97850` | uboot-envtools 使用 **0x4000 env size** | 需在新 tag 上确认是否仍有此问题 |
| `d87432995e` | XR1710G 使用 **airoha fancontrol** | 新 tag 的设备包里未见 fancontrol，需确认 |
| `81742af0dc` | 去掉与 device profile 冲突的 fancontrol 配置 | 与上一条配套 |

> 第 2、3 项先在 `pbodq2-base` 上核对，确认缺失再搬。

### 2.2 已被我们现有实现取代（6 项，不搬）

| 提交 | 我们现有等价物 |
|---|---|
| `63da24e772` ci: ccache + dl 缓存 | `.github/workflows/build-firmware.yml` 已有 |
| `4fbe066ef1` ci: retry + 日志 | 现有失败诊断已覆盖 |
| `32c741d551` ci: diagnose + drop per-device rootfs | 我们的构建方式不同 |
| `eb0bafe3be` manifest 路径修正 | 同上 |
| `ccf1edd4e0` passwall/app feeds + config seed | `custom/config.fragment` + `1710.config` |
| `Add project description` | README 已有 |

### 2.3 过时（3 项，丢弃）

| 提交 | 原因 |
|---|---|
| `620e865b58` mt76 换 lowaka NPU 补丁 | 新 tag 已是 mt76 0936617d + 自带 NPU 补丁 |
| `10-08-26 mt76 plus 20260721 firmware` | 同上，版本已旧 |
| `docs: record pbodq2 base with naoki66/lowaka mt76` | 结论已过时 |

### 2.4 需评估（2 项）

| 提交 | 说明 |
|---|---|
| `WIFI regDB revise - US and HK` | 无线监管域；如果使用地区不是 US/HK 则不需要 |
| `docs: analyze fanboy upstream and pbodq2 mt76 divergence` | 文档，可归档不进基线 |

### 2.5 纯文档（9 项，归档不搬）

`docs: record release 26.11.01_xr1710g`、`successful XR1710G flash`、
`successful layout/compat build`、`successful XR1710G build`、
`index changelog and record all design decisions`、`document XR1710G partition layouts`、
`record MLO/2.4G fix and client interop findings`、`note incomplete images from failed package install`、
`add changelog for upstream resync`。

处理：合并成一份经验摘要（本文件 + `upstream-pbodq2.md`），不进入代码树。

## 3. 汇总

```
65 个旧提交
├─ 41 已在新 tag            → 丢弃
├─ 24 旧 fork 独有
│   ├─ 4 保留（设备兼容/fancontrol/env size）
│   ├─ 6 已由我们实现取代    → 丢弃
│   ├─ 3 过时               → 丢弃
│   ├─ 2 需评估（regDB 等）
│   └─ 9 纯文档             → 归档
```

## 4. 对 overlay 的最终建议

按上面结论，`pbodq2-base` 的 overlay 应当是：

```
custom/config.fragment
custom/files/**
1710.config（新 seed）
patches/local/630-pcs-e2-pon.patch         # 上游缺，保留
patches/local/9995-beacon-protection.patch # 按需
target/linux/airoha/image/an7581.mk        # 加 gemtek,xr1710g 兼容（来自 9f45f0a2f4）
package/boot/uboot-envtools/...            # 0x4000 env（确认后）
（fancontrol 相关，确认后）
.github/workflows/build-firmware.yml       # 我们自己的
docs/ changelog/ scripts/
```

其余一律不搬。

## 5. 在 tag `ubi2-20261108` 上的核对结果（2026-11-15）

对 §2.1 里"建议保留"的 4 项逐项只读核对（不构建）：

| 旧 fork 项 | tag 现状 | 结论 |
|---|---|---|
| `9f45f0a2f4` 接受 `gemtek,xr1710g` | 设备块只有 `gemtek_xr1710g-ubi`，`DEVICE_DTS := an7581-xr1710g-ubi`，`DEVICE_COMPAT_VERSION := 2.0`，没有 `SUPPORTED_DEVICES` 别名 | **仍需 overlay**：首次刷写要 `-F`；若想双向免 `-F`，在设备块加 `SUPPORTED_DEVICES += gemtek,xr1710g` |
| `0800e97850` uboot-envtools 0x4000 env | `package/boot/uboot-tools/uboot-envtools/files/airoha_an7581` 里 `gemtek,xr1710g-ubi` 走 `ubootenv_add_ubi_default`；`0x4000` 只用于 `nokia,xg-040g-md` 的 mtd 布局 | **不需要**，我们那项是给 mtd 变体用的 |
| `d87432995e` XR1710G 用 airoha fancontrol | 设备块里是 `luci-app-w1700k-fancontrol`，DTS 里 `&i2c0 { hwmon@2e { compatible = "nuvoton,nct7802"; } }`，没有 `airoha-i2c` 覆盖 | **已被 tag 自己的方案取代**，不需要搬 |
| `81742af0dc` 去掉冲突的 fancontrol 配置 | 同上，tag 没有 airoha fancontrol 包 | **不需要** |

DTS 侧顺带确认：`&i2c0` 是 `status = "okay"` 且直接挂 `nct7802@0x2e`，
没有 naoki66 线里那个导致板温/风扇失效的 `airoha-i2c` 覆盖。

结论：overlay 可以比 §4 更薄——

```
custom/config.fragment
custom/files/**
1710.config（新 seed）
target/linux/airoha/image/an7581.mk      ← 只加 SUPPORTED_DEVICES 别名
patches/local/630-pcs-e2-pon.patch       ← 上游没有
patches/local/9995-beacon-protection.patch（rebase 版，按需）
.github/workflows/build-firmware.yml
docs/ changelog/ scripts/
```
