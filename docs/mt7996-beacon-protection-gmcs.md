# MT7996 信标保护：Beacon 带 MMIE，但 RSNE 缺 Group Management Cipher Suite

| 项 | 值 |
| --- | --- |
| 日期 | 2026-11-04 |
| 分支 | `naoki66-base` |
| 类型 | 现场缺陷报告（无代码改动） |
| 适用设备 | `airoha-an7581-mt7996-board`（MT7996E，EHT160 + MLO） |
| 状态 | 被动空口观测已确认现象；根因未定位到代码行 |

---

## 1. 背景

[`changelog/2026-11-01-mt7996-beacon-protection.md`](../changelog/2026-11-01-mt7996-beacon-protection.md)
给 mt7996 补上了 `NL80211_EXT_FEATURE_BEACON_PROTECTION` 之后，`beacon_prot=1`
不再被 hostapd 静默清零。

本次用第三方被动监听设备（802.11n 单频监听网卡，只收不发）做端到端核验，目的是确认
"AP 真的在保护 beacon，客户端也真的能验证"。前半句成立，后半句不成立。

## 2. 现象

| 观测点 | 结果 |
| --- | --- |
| Beacon 的 Extended Capabilities bit 84 | 已置位（AP 声明支持） |
| Beacon 携带 MMIE（元素 76） | 有，长度 16 字节 |
| MMIE 的 IPN | 逐帧递增（约 10 次/秒，持续增长） |
| RSNE 的 Group Management Cipher Suite | **缺失** |
| hostapd 运行配置 | `group_mgmt_cipher=AES-128-CMAC`、`beacon_prot=1`、`ieee80211w=2` |

也就是说：AP 侧确实在用 BIGTK 每帧重算 MIC，但空口上没有告诉客户端该用哪个 BIP
算法，客户端拿到 MMIE 也无法验证。

## 3. 证据

### 3.1 受影响的 RSNE（元素 48）

MLO 的 5G link（EHT160，SAE）实测 beacon RSNE，长度 **20 字节**：

```
01 00                        RSN version 1
00 0F AC 04                  group cipher: CCMP
01 00                        pairwise count = 1
00 0F AC 04                  pairwise: CCMP
01 00                        AKM count = 1
00 0F AC 08                  AKM: SAE (8)
CC 00                        RSN capabilities = 0x00CC (MFPC | MFPR)
-- 结束 --                   没有 PMKID Count，没有 Group Management Cipher Suite
```

同一设备上的普通 5G VAP 也是 20 字节，只有 capabilities 不同（`CC 40`），
同样没有 GMCS。**说明不是 MLO 专属问题，整机都缺。**

### 3.2 同环境里一个正常实现的对照

同一信道上另一台 AP（非本仓库设备）的 RSNE，长度 **30 字节**：

```
01 00
00 0F AC 04
01 00
00 0F AC 04
02 00                        pairwise count = 2
00 0F AC 02                   pairwise: TKIP
00 0F AC 08                   pairwise: SAE
80 00                        RSN capabilities = 0x0080 (MFPC)
00 00                        PMKID Count = 0
00 0F AC 06                  Group Management Cipher Suite: BIP-CMAC-128
```

多出来的正是 `PMKID Count` 和 `GMCS` 两段。解析器在 30 字节的样本上能正确读出
`GMCS = 6`，说明不是解析问题。

### 3.3 元素序列

受影响 BSS 的 beacon 元素 ID 序列（节选）：

```
00,01,05,07,30,0B,46,3B,2D,3D,7F,BF,C0,C3,F4,FF,FF,FF,FF,FF,FF,FF,DD,DD,DD,4C
                                                        ^^              ^^
                                                      0x30=RSNE      0x4C=MMIE
```

只有一条 RSNE，没有第二条 RSN 类元素；MMIE 是最后一个元素。

### 3.4 hostapd 运行配置（`/var/run/hostapd-phy*.conf`）

```
wpa=2
wpa_pairwise=CCMP
ieee80211w=2
group_mgmt_cipher=AES-128-CMAC
beacon_prot=1
wpa_key_mgmt=SAE
rsn_override_key_mgmt_2=SAE-EXT-KEY
rsn_override_pairwise_2=GCMP-256
```

配置项齐全，但空口 RSNE 里没有对应字段。

### 3.5 客户端能力（用于排除"客户端不支持"这一解释）

各客户端的 Ext Capabilities bit 84 做了双通道交叉验证：空口抓 Assoc Request
与 AP 侧 hostapd 的 `ext_capab` 逐字节比对，两者一致。

| 客户端 | AKM | pairwise | Ext Cap bit 84 |
| --- | --- | --- | --- |
| A（新一代 Wi-Fi 7 手机） | 24（SAE-EXT-KEY） | GCMP-256 | 有 |
| B（上一代 Wi-Fi 7 手机） | 24 | GCMP-256 | 无 |
| C（802.11ac 笔记本） | 8（SAE） | CCMP | 无 |
| D（Apple silicon 笔记本，11ax） | 8 | CCMP | 无 |

也就是说客户端侧确实存在支持 BP 的设备（A），AP 也把 bit 84 置了，但 RSNE 缺 GMCS
这一环仍然让 BP 不可验证。

## 4. 分析

1. **GMCS 是客户端选择 BIP 算法的唯一来源。** MMIE 里只有 KeyID、IPN 和 MIC，
   没有算法标识；客户端必须先知道套件（BIP-CMAC-128 / GMAC-128 / GMAC-256 /
   CMAC-256），才能重算 MIC。
2. 缺 GMCS 时：
   - 严格按规范的实现会认为"该 AP 不支持管理帧保护套件"，直接忽略 MMIE；
   - 个别实现可能默认按 BIP-CMAC-128 处理（MMIE 长度 16 恰好吻合），此时"碰巧能用"，
     但不可依赖，也不能作为合规依据。
3. **客户端是否真的在验签，空口不可观测。** 所以本报告只能证明到"AP 在发、但契约缺失"，
   不能证明"客户端没验"或"验失败"。
4. 附带观察：当所有关联 STA 都不支持 BP 时，该 AP 仍然在发 MMIE。常见 hostapd
   行为是等至少一个声明支持的 STA 关联后才启用 beacon protection；本设备似乎是无条件
   启用。这一点与 GMCS 缺失可能同源（都指向 RSNE/BP 状态未按协商结果更新）。

## 5. 候选根因（待定位）

按可能性排序，需要用代码或对照实验排除：

1. **hostapd 的 RSNE 生成路径**：本构建启用了 `rsn_override_*`（RSN Override）。
   该补丁会改写 `wpa_write_rsn_ie()` 的输出，怀疑在 override 生效时漏写了 GMCS。
2. **`group_mgmt_cipher` 未真正传入 BSS 上下文**：conf 文件里有，但 BSS 结构体里为 0。
3. **驱动/固件重建 RSNE**：mt76 把 beacon 模板下发给固件后，固件若重写 RSN IE 也会丢字段。

**判定方法**：在同一台设备上对比不同配置的 VAP。

- 关掉 `rsn_override_*`（或建一个不带 override 的测试 VAP）后 GMCS 是否出现？
  - 出现 → 问题在 RSN Override 路径；
  - 仍不出现 → 问题在 hostapd 基础路径或驱动。
- 当前已确认普通 5G VAP 与 MLO link **都缺**，所以不是 MLD 专属路径的问题。

## 6. 影响范围

- 所有 `beacon_prot=1` 的 VAP（2.4G / 5G / 6G / MLO link）。
- 客户端侧：不支持 BP 的客户端（多数）完全无感；支持 BP 的客户端拿不到可验证的 MMIE，
  等于 BP 没有实际防护效果。
- 空口开销：每帧 beacon 多 18 字节（MMIE 2+16）。
- 不影响关联、SAE、4-way 和数据面。

## 7. 复现方式（纯被动，不需要连入网络）

1. 用支持 monitor 模式的网卡锁定目标 AP 的主 20MHz 信道（5G 的 beacon 走 legacy 速率，
   802.11n 网卡即可解码）。
2. 抓取若干 Beacon，解析元素 48（RSNE）：
   - 长度 20 字节且以 RSN capabilities 结尾 → 缺 GMCS；
   - 长度 30 字节且尾部为 `00 0F AC 06` → 正常。
3. 同时解析元素 76（MMIE）确认长度 16，并比较相邻 beacon 的 IPN 是否递增。

## 8. 修复后如何确认

- RSNE 长度从 20 变为 30（或至少出现 PMKID Count + GMCS 两段）；
- 尾部出现 `00 0F AC 06`（BIP-CMAC-128）；
- 客户端侧若能抓到 4-way 的 M3，可进一步确认 BIGTK KDE（`00 0F AC 14`）存在。

## 9. 未验证 / 限制

- **M3 里的 BIGTK KDE 未验证**：EHT 客户端的 EAPOL 是数据帧，按 HE/EHT PPDU 发送，
  802.11n 监听网卡无法解调。因此"BIGTK 确实下发给了客户端"这一步没有直接证据，
  只能由 AP 侧配置和 MMIE 的存在间接推断。
- 客户端是否验签、验签是否成功，属于客户端本地行为，空口无任何信号。
- 未做 hostapd 源码级定位。

## 10. 参考

- 前置报告：[`changelog/2026-11-01-mt7996-beacon-protection.md`](../changelog/2026-11-01-mt7996-beacon-protection.md)
- IEEE 802.11-2020 §12.5.3（Beacon protection）、§9.4.2.241（MMIE）
- hostapd：`src/ap/wpa_auth_ie.c`（RSNE 生成）、`src/ap/ieee802_11_shared.c`（Ext Cap bit 84）
- mac80211：`net/mac80211/wpa.c`（BIP/MMIE）
