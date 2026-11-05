# MT799x 信标保护（Beacon Protection）实测记录

> 本文只描述测试环境与空口观测，不涉及任何特定产品或工程。目的是记录一组
> 可复现的实测数据，以及一个容易误判的协议细节。

> **免责声明**：本文结论**只保证在「1. 测试环境」所列的设备、驱动、hostapd 版本、
> 频段/带宽与客户端组合下成立**。不同硬件、驱动版本、固件配置或客户端型号都可能
> 得到不同结果；本文不构成对其它环境、其它组合或后续版本的保证。
> 复现与判断请以自建环境下的实测为准。

## 摘要

| 项 | 结论 |
| --- | --- |
| Beacon Protection 是否在工作 | **是**。Beacon 携带 MMIE，IPN 逐帧递增 |
| RSNE 里没有 Group Management Cipher Suite | **正常**。字段缺省等价于 BIP-CMAC-128 |
| 客户端能力差异 | 真实存在，空口与 AP 侧视图一致 |
| 是否属于实现缺陷 | **否**。最初的判断已被源码复核推翻 |

### English abstract

Beacon Protection was verified on two MT799x platforms (MT7996E with the upstream
mt76 driver, and MT7992 with a vendor `mt_wifi` driver), both running hostapd 2.12.
Beacons carry the MMIE (element 76) with a monotonically increasing IPN, proving
BIGTK is in use. The RSNE omits the Group Management Cipher Suite field; source
review shows this is the standard default encoding for BIP-CMAC-128 (hostapd
deliberately omits the field when the cipher is the default, and parsers pre-fill
the default before applying an explicit field). The omission is therefore **not a
defect**. Client support for BP varies by device and is visible via Extended
Capabilities bit 84.

---

## 1. 测试环境

| 项 | 设备 A | 设备 B |
| --- | --- | --- |
| 芯片 | MT7996E | MT7992 |
| 驱动 | 上游 mt76（mac80211） | 厂商闭源 `mt_wifi` |
| hostapd | 2.12 | 2.12-devel |
| 频段 / 带宽 | 5GHz，160MHz，含 MLO | 5GHz，160MHz |
| 加密 | SAE，`ieee80211w=2` | SAE / sae-mixed |
| `beacon_prot` | 1 | 1 |
| `group_mgmt_cipher` | `AES-128-CMAC` | `AES-128-CMAC` |

观测设备为一块只收不发的 802.11n 监听网卡（单频，20MHz），锁定目标 AP 的
主信道后解析 Beacon 与关联响应。

## 2. 观测结果

### 2.1 Beacon 携带 MMIE，IPN 递增

元素 76（MMIE）长度 16 字节，结构为 `KeyID(2) + IPN(6) + MIC(8)`。
连续观察 IPN 单调递增（约 10 次/秒），说明 AP 每一帧都在用 BIGTK 重算 MIC，
而不是填入静态内容。

同时 Beacon 的 Extended Capabilities（元素 127）bit 84 置位，表示 AP 声明支持
Beacon Protection。

### 2.2 RSNE 中没有 GMCS

实测 RSNE（元素 48），长度 **20 字节**：

```
01 00                 RSN version 1
00 0F AC 04           group cipher: CCMP
01 00                 pairwise count = 1
00 0F AC 04           pairwise: CCMP
01 00                 AKM count = 1
00 0F AC 08           AKM: SAE (8)
CC 00                 RSN capabilities = 0x00CC (MFPC | MFPR)
-- 结束 --
```

字段到 capabilities 为止：没有 PMKID Count，也没有 Group Management Cipher Suite。

同环境中另一台 AP 的 RSNE 长度为 **30 字节**，尾部多出：

```
00 00                 PMKID Count = 0
00 0F AC 06           Group Management Cipher Suite: BIP-CMAC-128
```

两种写法在空口上都合法，客户端都能正确解析（见第 4 节）。

### 2.3 关联响应不含 RSNE

对 (Re)Association Response 做逐元素遍历（legacy 速率，可解码）：

```
walk = 01:8 46:5 2D:26 3D:22 DD:30 DD:26 5A:3 BF:12 C0:5
       FF:39 FF:7 FF:2 FF:14 DD:6 7F:11 F0:2 F4:1
       FF:18 FF:6 DD:17 DD:10 DD:33 DD:24    end = 373/373
```

遍历完整走到末尾，**没有元素 48**。也就是说这两个实现的关联响应都不携带 RSNE，
客户端从 Beacon 获取 AP 的 RSNE 即可。这不构成问题。

### 2.4 客户端 BP 能力

通过被动抓取 Association Request 的 Extended Capabilities，并与 AP 侧
hostapd 的每 STA `ext_capab` 逐字节比对（两套独立观测口径）：

| 客户端 | AKM | pairwise | Ext Cap 长度 | bit 84 |
| --- | --- | --- | --- | --- |
| Wi-Fi 7 手机（较新） | 24（SAE-EXT-KEY） | GCMP-256 | 11 字节 | **有** |
| Wi-Fi 7 手机（较早） | 24 | GCMP-256 | 11 字节 | 无（置 bit 85） |
| 802.11ac 笔记本 | 8（SAE） | CCMP | 8 字节 | 无 |
| Apple silicon 笔记本（11ax） | 8 | CCMP | 8 字节 | 无 |

第二台值得注意：它的 `ext_capab` 是**完整的 11 字节**，只是置的是 bit 85 而非
bit 84。这排除了"元素被截断导致读不到"的解释——元素在，位不在。

## 3. 为什么 GMCS 可以缺省

### 3.1 协议语义

Group Management Cipher Suite 在 RSNE 中是**可选字段**。字段缺省时，
按 **BIP-CMAC-128** 处理。这个默认值是协议为向后兼容定义的，因此：

```
不写该字段  ≡  显式写 00-0F-AC-06
```

### 3.2 生成端（hostapd）

```c
/* src/ap/wpa_auth_ie.c — wpa_write_rsn_ie() */
if (conf->ieee80211w != NO_MGMT_FRAME_PROTECTION &&
    conf->group_mgmt_cipher != WPA_CIPHER_AES_128_CMAC) {
        /* PMKID Count */
        ...
        switch (conf->group_mgmt_cipher) {
        case WPA_CIPHER_AES_128_CMAC: RSN_SELECTOR_PUT(pos, ...);  break;
        case WPA_CIPHER_BIP_GMAC_128: ... break;
        case WPA_CIPHER_BIP_GMAC_256: ... break;
        case WPA_CIPHER_BIP_CMAC_256: ... break;
        }
        pos += RSN_SELECTOR_LEN;
}
```

注意条件里的 `!= WPA_CIPHER_AES_128_CMAC`：**当配置是默认值时不写该字段**。
只有 GMAC-128 / GMAC-256 / CMAC-256 这类无法从默认值推断的套件才会被显式写出。

hostapd 2.10 与 2.11 均有此行为；更早版本会显式写出，两者互操作没有问题。

### 3.3 解析端

```c
/* src/common/wpa_common.c — wpa_parse_wpa_ie_rsn() */
data->mgmt_group_cipher = WPA_CIPHER_AES_128_CMAC;   /* 先填默认值 */
...
if (/* GMCS 字段存在 */)
        data->mgmt_group_cipher = rsn_selector_to_bitfield(pos);
```

客户端先赋默认值，再用显式字段覆盖。因此缺省与显式两种编码等价。

## 4. 一个容易犯的判断错误

最初看到 20 字节的 RSNE 时，结论是"AP 在发 MMIE 却没告诉客户端用哪个 BIP 算法，
因此 BP 形同虚设"。这个推断是错的，原因是没有先确认该字段是必填还是可选。

正确的判断顺序应当是：

1. 这个字段在协议里是必填还是可选？
2. 若可选，缺省值是什么？
3. 生成端为什么省略（优化 / 版本 / 配置）？
4. 最后才考虑是否为缺陷。

只看空口有没有某个字段，无法判断实现是否有问题。

## 5. 观测边界

| 层 | 内容 | 空口可观测 |
| --- | --- | --- |
| L1 | AP 配置了 BP（bit 84 / BIGTK 下发） | 部分 |
| L2 | AP 在用（Beacon 携带 MMIE、IPN 递增） | 完全 |
| L3 | 客户端是否在验签 | 不可观测 |

补充限制：

- **M3 中的 BIGTK KDE 无法验证**：EHT 客户端的 EAPOL 是数据帧，按 HE/EHT PPDU
  发送，802.11n 监听网卡无法解调。
- SAE 网络的 PMK 由 PAKE 产生，被动方无法通过已知口令解密 M3。
- MLO 是逐 link 的：一条 link 上有 MMIE，不能反推其他 link 的状态。

## 6. 参考

- IEEE 802.11-2020 §12.5.3（Beacon protection）、§9.4.2.241（MMIE）
- hostapd `src/ap/wpa_auth_ie.c`（RSNE 生成）、`src/ap/ieee802_11_shared.c`（Ext Cap bit 84）
- wpa_supplicant `src/common/wpa_common.c`（RSNE 解析）
- Linux `net/mac80211/wpa.c`（BIP / MMIE）
