# mt7996 宣告 802.11 信标保护（Beacon Protection）能力

| 项 | 值 |
| --- | --- |
| 日期 | 2026-11-01 |
| 分支 | `naoki66-base` |
| 提交 | `58fdc69a749b5b00d44c86078fa5830412595fb4` |
| 变更文件 | `package/kernel/mt76/patches/9995-wifi-mt76-mt7996-advertise-beacon-protection.patch` |
| 类型 | 内核驱动能力广告（1 行代码） |
| 适用设备 | `airoha-an7581-mt7996-board`（Gemtek XR1710G / W1700K，MT7996） |
| 状态 | 补丁已合入、静态校验通过；**实机验证待构建** |

---

## 1. 背景

IEEE 802.11 的信标保护（Beacon Protection）用 BIGTK 给 Beacon 帧加 MMIE，
防止攻击者伪造 deauth/信道切换之类的管理帧把客户端踢下线或引到别的信道。

我们的 `airoha-an7581-mt7996-board`（AN7581 + MT7996）跑的是标准 OpenWrt
hostapd + 上游 mt76，一直没能开启 beacon protection：hostapd 配置里写了
`beacon_prot=1` 也无效，4-way 握手里根本不协商 BIGTK。

为了确认这是**驱动缺能力位**而不是 MT799x 硬件不支持，用 Tenda BE12 Pro
（MT7987A + MT7992，MTK 闭源 `mt_wifi7` 驱动）做了端到端对照实验，结论见第 4 节。

## 2. 根因

hostapd 在 `src/ap/wpa_auth_glue.c` 里有一条静默降级：

```c
if (!(drv_flags & WPA_DRIVER_FLAGS_BEACON_PROTECTION))
        _conf->beacon_prot = 0;
```

`WPA_DRIVER_FLAGS_BEACON_PROTECTION` 来自 cfg80211 的
`NL80211_EXT_FEATURE_BEACON_PROTECTION`，而 `mt7996_init_wiphy()` 从未调用过
`wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_BEACON_PROTECTION)`。

因此即使 hostapd 配置了 `beacon_prot=1`：

1. hostapd 判定驱动不支持，把 `beacon_prot` 清零；
2. `ieee80211w_kde_add()` 不再往 4-way msg3 里塞 BIGTK KDE（selector `00-0f-ac-14`）；
3. 客户端拿不到 BIGTK，驱动自然也不会安装 BIGTK 密钥；
4. Beacon 里永远没有 MMIE，Extended Capabilities bit 84 也不会置位。

关键在于：**mt7996 缺的只是这一个能力位，实现早就在了。**

| 环节 | 上游 mt76 位置 | 状态 |
| --- | --- | --- |
| BIGTK keyidx 6/7 → 第二个硬件 key slot（`hw_key_idx2`） | `mt7996/main.c:228-236` | 已有 |
| `IEEE80211_KEY_FLAG_GENERATE_MMIE` | `mt7996/main.c`（`mt7996_set_hw_key()`） | 已有 |
| BIP cipher 映射与固件 key TLV | `mt76_connac_mcu.c:2785`、`mt7996/mcu.c:3236+` | 已有 |
| BIGTK 安装后 beacon remove/re-add，让固件重新接管 | `mt7996/main.c:262-273` | 已有 |
| 能力广告 `NL80211_EXT_FEATURE_BEACON_PROTECTION` | `mt7996/init.c` | **缺失 ← 本补丁** |

mac80211 侧的行为也已确认：BIGTK 上传到硬件且带 `GENERATE_MMIE` 时，
`ieee80211_crypto_aes_cmac_encrypt()` 只负责把 MMIE 结构（element id、长度、
key id、PN 自增）拼进去，MIC 交给硬件算（`net/mac80211/wpa.c:869-908`）。

## 3. 变更内容

新增 `package/kernel/mt76/patches/9995-wifi-mt76-mt7996-advertise-beacon-protection.patch`：

```diff
--- a/mt7996/init.c
+++ b/mt7996/init.c
@@ -528,6 +528,7 @@ mt7996_init_wiphy(struct ieee80211_hw *hw, struct mtk_wed_device *wed)
 	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_ACK_SIGNAL_SUPPORT);
 	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_CAN_REPLACE_PTK0);
 	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_MU_MIMO_AIR_SNIFFER);
+	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_BEACON_PROTECTION);
```

编号 `9995` 排在现有 `9993` / `9994` 之后，仅新增文件，没有改动任何已有补丁。

### 为什么只开 AP 侧

没有同时设置 `NL80211_EXT_FEATURE_BEACON_PROTECTION_CLIENT`：

- 我们只用这两台设备做 AP，STA 侧的 BIGTK/MFP 处理没有验证过；
- 乱开会在驱动“号称支持但没实现”的状态下引入 RX 侧 MMIE 校验路径，属于无收益的风险。

上游 iwlwifi 是 AP+client 都开，ath12k 只开 AP 侧；我们跟 ath12k 一致。

## 4. 验证

### 4.1 补丁可应用性（已完成）

在仓库锁定的 mt76 源码 `467ae2e3f190baf737e15e318906da0dc7d0ab91`（`PKG_SOURCE_VERSION`）
上按仓库 `patches/` 的实际顺序应用：

```
0003 → 100 → 110 → 9993 → 9994 → 9995
```

结果：

- `patch -p1 --batch --forward` 干净通过：无 offset、无 fuzz、无 reject；
- `git apply --check -v` 同样通过；
- 应用后 `mt7996/init.c:531` 出现 `wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_BEACON_PROTECTION);`。

### 4.2 参考设备端到端验证（已完成，BE12 Pro）

Tenda BE12 Pro（MT7987A + MT7992，MTK 闭源 `mt_wifi7`，hostapd `2025.08.26~ca266cc2-r6`）
上同样只需能力位即可完整生效，说明 MT799x 硬件路径支持这套流程：

```
# hostapd_cli -i rai0 driver_flags
BEACON_PROTECTION

# grep -E "^beacon_prot|^ieee80211w|^group_mgmt_cipher" /var/run/hostapd-phy1.conf
ieee80211w=2
group_mgmt_cipher=AES-128-CMAC
beacon_prot=1

# 驱动内部状态（mwctl dev rai0 show BcnProtDbgInfo=0，输出在 kernel log）
BCN PROT mode = 2 (1 - SW mode, 2 - HW mode)
BIGTK Cipher = 0x220 (BIP-CMAC128)
BIGTK in bcn_prot_cfg of wdev: ..., len = 32
WiFi@NOTICE.SEC,UniCmdBssInfoBcnProt() 1492: Install BIGTK,
    BandIdx (1), BssIndex (5), ucBcnProtEnabled (3),
    ucBcnProtCipherId(12), ucBcnProtKeyId(7)

# hostapd_cli -i rai0 sta 12:25:0d:7e:aa:db
flags=[AUTH][ASSOC][AUTHORIZED][MFP]
ext_capab=0000000000400040000010      # 第 10 字节 0x10 → bit 84 = 1
```

即：能力位在位 → hostapd 不清 `beacon_prot` → 下发 BIGTK KDE → 驱动以 **HW 模式**
（`BCN PROT mode = 2`）用 **BIP-CMAC-128** 安装 BIGTK（key id 7）→ 客户端宣告
Extended Capabilities bit 84。

### 4.3 实机验证（未完成）

`airoha-an7581-mt7996-board` 上尚未验证。需要等一次包含本补丁的构建完成后，按
第 6 节步骤确认。在此之前请把本变更视为“补丁正确、效果预期、待实测”。

## 5. 影响范围

- **只有 MT7996 系**（`mt7996` 驱动，覆盖 MT7996/MT7992）受影响；mt7915/mt7615 等
  其他 mt76 驱动完全不受影响，因为它们没被改。
- 只有**驱动支持且 hostapd 判定可以开启**的 BSS 才会启用；客户端不支持
  （bit 84 = 0）时，按 802.11 规范会忽略 BIGTK KDE，连接行为不变。
- 新增的是能力位，不改变任何已有的密钥安装路径；`beacon_prot` 未开启时不产生
  任何新的运行时行为。
- 构建侧无变化：`1710.config` 里 `kmod-mt76-core` / `kmod-mt76-connac` /
  `kmod-mt7996-firmware` 原本就开；本补丁只改驱动源码。

### 配置要求

- **5G / 6G**：默认 `sae` / `sae-mixed` + EHT，`ieee80211w` 已开。本仓库 hostapd
  为 `2026-08-07`（`831364bf`），含“11be + PMF 自动开 `beacon_prot`”的逻辑
  （`src/ap/ap_config.c:1560`），因此这些频段会自动启用。
- **2G**：默认 `psk2` 且未开 PMF，**不会**自动启用。需要显式设置：

  ```
  option ieee80211w '2'
  option beacon_prot '1'
  ```

  注意 `sae-mixed` 在 2G 上同样需要 `ieee80211w=2` 才会走 PMF。

## 6. 如何确认生效

刷入包含本补丁的固件后：

```sh
# 1. 驱动能力（最关键的一条）
iw phy | grep -i BEACON_PROTECTION

# 2. hostapd 看到的驱动 flag
hostapd_cli -i phy0-ap0 driver_flags | grep BEACON_PROTECTION

# 3. hostapd 实际运行时配置（不是 /etc/config/wireless）
grep -E '^beacon_prot|^ieee80211w|^group_mgmt_cipher' /var/run/hostapd-phy*.conf

# 4. 客户端能力
hostapd_cli -i phy0-ap0 sta <client-mac> | grep ext_capab
#    第 10 字节 & 0x10 != 0  → bit 84 = 1，客户端支持

# 5. 密钥确实装了（BIGTK 在 keyidx 6/7）
iw dev phy0-ap0 station dump
```

第 1 条有输出、第 3 条里 `beacon_prot=1` 没被清掉、第 4 条 bit 84 = 1，三条同时
满足即可认为生效。抓包确认 MMIE 需要 monitor mode，本机型没有该能力，不做要求。

## 7. 风险与回滚

- **风险**：能力位一旦宣称，hostapd 会对所有启用 PMF 的 BSS 下发 BIGTK，驱动
  走 `hw_key_idx2` + beacon remove/re-add 路径。若固件对第二条 key slot 处理有
  问题，表现为**该 BSS 的 beacon 发送异常（客户端看不到 SSID）**。这是本变更唯一
  的现实失败模式，且只影响开 PMF 的 BSS。
- **回滚**：删除
  `package/kernel/mt76/patches/9995-wifi-mt76-mt7996-advertise-beacon-protection.patch`
  重新构建即可，无需其它改动（补丁是纯新增文件，不依赖也不被其它补丁依赖）。
- **临时缓解**（不重新构建）：把受影响 BSS 的 `beacon_prot` 显式设为 `0`。

## 8. 参考

- 补丁：`package/kernel/mt76/patches/9995-wifi-mt76-mt7996-advertise-beacon-protection.patch`
- 提交：`58fdc69a749b5b00d44c86078fa5830412595fb4`（父 `6f844cd5`）
- mt76 锁定版本：`467ae2e3f190baf737e15e318906da0dc7d0ab91`（`PKG_SOURCE_DATE:=2026-10-08`）
- hostapd：`2026-08-07` / `831364bf02710ad09c2f27d3efa92abeeb5634c0`
  - `src/drivers/driver_nl80211_capa.c:675` 能力映射
  - `src/ap/wpa_auth_glue.c:68` 无 flag 时清 `beacon_prot`
  - `src/ap/ieee802_11_shared.c:470` 设置 Ext Capab bit 84
  - `src/ap/ap_config.c:1560` 11be + PMF 自动启用
- mac80211：`net/mac80211/wpa.c:869`（`ieee80211_crypto_aes_cmac_encrypt`）、
  `net/mac80211/tx.c:5532`（`ieee80211_beacon_protect`）

## 9. 后续

- **2026-11-01**：本补丁合入前启动的构建 `41289580224`（基于 `6f844cd5`，**不含**本
  补丁）在 `Build Firmware` 步骤失败，与 mt76 无关：卡在 `python3` 编译，
  `Python-3.14.7` 的 `profile-opt` 阶段报
  `Modules/_ctypes/_ctypes.c:119:10: fatal error: ffi.h: No such file or directory`，
  整份日志里没有任何 libffi 编译记录。也就是说 `_ctypes` 在编译时找不到 libffi 头文件。
  需要先解决该构建问题（或让 `libffi` / `CONFIG_PACKAGE_libffi` 进入 staging），
  才能跑包含本补丁的构建并做实机验证。
- **2026-11-04**：实机核验确认 `beacon_prot=1` 已生效——Beacon 里出现 MMIE（长度 16），
  IPN 逐帧递增，说明 BIGTK 确实在参与每帧 MIC 计算。但 **Beacon 的 RSNE 里没有**
  Group Management Cipher Suite，关联响应里更是连 RSNE 都不带——**明文路径没有告诉
  客户端该用哪个 BIP 算法**。同设备的普通 5G VAP 与 MLO link 都是如此，配置里的
  `group_mgmt_cipher=AES-128-CMAC` 没有体现到空口。M3 的加密 Key Data 是否补发该字段
  无法观测，因此结论限定为「明文通告缺失」。详见
  [`docs/mt7996-beacon-protection-gmcs.md`](../docs/mt7996-beacon-protection-gmcs.md)。
