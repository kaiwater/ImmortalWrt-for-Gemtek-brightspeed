# MT799x 信标保护：Beacon 带 MMIE，但 RSNE 缺 Group Management Cipher Suite

| 项 | 值 |
| --- | --- |
| 日期 | 2026-11-04 |
| 分支 | `naoki66-base` |
| 类型 | 现场缺陷报告（无代码改动） |
| 适用设备 | `airoha-an7581-mt7996-board`（MT7996E，mt76）；另在 MT7992 + 闭源 `mt_wifi` 上复现 |
| 状态 | 现象已确认；根因收敛到 hostapd 2.12，未定位到代码行；M3 路径未决 |

> **结论摘要**
>
> - 两台设备（开源 mt76 / 闭源 mt_wifi）的 Beacon 都携带 MMIE，IPN 逐帧递增 →
>   **AP 侧确实在用 BIGTK 计算 MIC**。
> - 但 **Beacon 的 RSNE 里没有 Group Management Cipher Suite**，关联响应里干脆
>   连 RSNE 都不带 → **明文路径没有告诉客户端该用哪个 BIP 算法**。
> - M3 的 Key Data 里还有一份 AP 的 RSNE，它是加密的、无法观测；若该处补上了
>   GMCS，客户端仍可能完成验证。因此本报告确认的是「明文通告缺失」，不是
>   「客户端一定无法验证」。
> - 两套驱动、两种加密配置、有无 MLO、有无 `rsn_override` 都复现 → 共同点收敛到
>   **hostapd 2.12**。

---

## 1. 背景

[`changelog/2026-11-01-mt7996-beacon-protection.md`](../changelog/2026-11-01-mt7996-beacon-protection.md)
给 mt7996 补上了 `NL80211_EXT_FEATURE_BEACON_PROTECTION` 之后，`beacon_prot=1`
不再被 hostapd 静默清零。

本次用第三方被动监听设备（802.11n 单频监听网卡，只收不发）做端到端核验，目的是确认
"AP 真的在保护 beacon，客户端也真的能验证"。前半句成立；后半句在明文路径上不成立，
加密路径（M3）无法观测。

## 2. 现象

| 观测点 | 结果 |
| --- | --- |
| Beacon 的 Extended Capabilities bit 84 | 已置位（AP 声明支持） |
| Beacon 携带 MMIE（元素 76） | 有，长度 16 字节 |
| MMIE 的 IPN | 逐帧递增（约 10 次/秒，持续增长） |
| RSNE 的 Group Management Cipher Suite | **缺失** |
| hostapd 运行配置 | `group_mgmt_cipher=AES-128-CMAC`、`beacon_prot=1`、`ieee80211w=2` |

也就是说：AP 侧确实在用 BIGTK 每帧重算 MIC，但**明文空口上没有告诉客户端该用哪个
BIP 算法**。客户端是否仍能通过 M3 的加密 Key Data 拿到该字段，本报告无法判定。

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

### 3.6 交叉验证：闭源 `mt_wifi` 栈同样缺 GMCS

同一局域网内另一台设备（MT7992 + MTK 闭源 `mt_wifi` 驱动，hostapd v2.12-devel）
提供了独立对照：

- 12 个 BSS 全部配置了 `group_mgmt_cipher=AES-128-CMAC` 与 `beacon_prot=1`；
- **完全没有启用** `rsn_override_*`；
- Beacon 同样携带 MMIE（16 字节），IPN 递增；
- RSNE 同样只有 20 字节（纯 SAE）或 28 字节（`sae-mixed`），结尾没有 GMCS。

这排除了「RSN Override 路径导致 GMCS 丢失」的假设，把共同点收敛到 **hostapd 2.12 本身**
（两套驱动、两种加密配置、有无 override、有无 MLO，都出现同一现象）。

同一台设备上还能读到每个 STA 的 `ext_capab`。该 BSS 当时有 3 台客户端在线：

| 客户端 | `ext_capab` 长度 | 第 11 字节 | bit 84 |
| --- | --- | --- | --- |
| 新一代 Wi-Fi 7 手机 | 11 字节 | `0x10` | 有 |
| 上一代 Wi-Fi 7 手机 | 11 字节 | `0x20`（bit 85） | 无 |
| 平板（长期在线） | 8 字节 | — | 无 |

三台里恰好一台支持，与被动监听侧统计到的 `1/3` 完全一致。

其中第二台值得单独说明：它的 `ext_capab` 是**完整的 11 字节**，只是置的是 bit 85 而不是
bit 84。这排除了"元素被截断导致读不到 bit 84"的解释——元素在，位不在。

### 3.7 关联响应里没有 RSNE

对 Association Response 做逐元素遍历（同样是纯被动、legacy 速率可解）：

```
walk=01:8 46:5 2D:26 3D:22 DD:30 DD:26 5A:3 BF:12 C0:5 FF:39 FF:7 FF:2 FF:14
     DD:6 7F:11 F0:2 F4:1 FF:18 FF:6 DD:17 DD:10 DD:33 DD:24   end=373/373
```

遍历完整走到 `end == left`，没有提前中断，但**元素序列里没有 `30`（RSNE）**。
多个不同客户端收到的关联响应都是同样的结构。

因此客户端能拿到 AP 的 RSNE 只剩两条路：

| 来源 | 可观测 | 是否含 GMCS |
| --- | --- | --- |
| Beacon / Probe Response | 是 | 否（见 3.1） |
| (Re)Association Response | 是 | 整个 RSNE 都没有 |
| 4-way msg3 的加密 Key Data | 否 | **未知** |

## 4. 分析

1. **GMCS 是客户端选择 BIP 算法的唯一来源。** MMIE 里只有 KeyID、IPN 和 MIC，
   没有算法标识；客户端必须先知道套件（BIP-CMAC-128 / GMAC-128 / GMAC-256 /
   CMAC-256），才能重算 MIC。

   需要注意：M3 的 Key Data 里也会带一份 AP 的 RSNE，而 M3 是加密的、无法观测。
   如果某个实现在 M3 里补上了 GMCS，客户端仍可能完成验证。因此本节结论应表述为
   **「明文路径（Beacon）上没有提供算法」**，而不是「客户端一定无法验证」。
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

交叉验证后，候选范围已收窄：

1. **hostapd 2.12 的 RSNE 生成路径**（最可能）。两套驱动共用同一 hostapd 版本，
   且与 `rsn_override` 无关；`group_mgmt_cipher` 在 conf 中被正确解析，但没有写进 RSNE。
2. `group_mgmt_cipher` 未进入 BSS 上下文：conf 文件有，BSS 结构体里可能为 0。
3. 驱动/固件重写 RSNE：两套完全不同的驱动都重写同一字段的可能性较低，但不能排除。

**下一步判定**：在同一硬件上换用未经 MTK 修改的上游 hostapd 2.12 构建，观察 GMCS 是否
出现。若出现，问题在 hostapd 补丁集；若仍缺失，再考虑驱动侧。

## 6. 影响范围

- 所有 `beacon_prot=1` 的 VAP（2.4G / 5G / 6G / MLO link）。
- 客户端侧：不支持 BP 的客户端（多数）完全无感；支持 BP 的客户端在明文路径上拿不到
  BIP 算法，能否验证取决于 M3 是否补发该字段（未观测）。
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
- **关联响应不含 RSNE**（见 3.7），所以也无法用它来判断 GMCS 是否存在。
- M3 里那份 RSNE 是否带 GMCS 未知；这是当前结论最大的不确定点。
- 未做 hostapd 源码级定位。

## 10. 参考

- 前置报告：[`changelog/2026-11-01-mt7996-beacon-protection.md`](../changelog/2026-11-01-mt7996-beacon-protection.md)
- IEEE 802.11-2020 §12.5.3（Beacon protection）、§9.4.2.241（MMIE）
- hostapd：`src/ap/wpa_auth_ie.c`（RSNE 生成）、`src/ap/ieee802_11_shared.c`（Ext Cap bit 84）
- mac80211：`net/mac80211/wpa.c`（BIP/MMIE）
