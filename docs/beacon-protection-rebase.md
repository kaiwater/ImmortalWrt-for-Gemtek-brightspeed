# beacon protection 补丁在 mt76 0936617d 上的编译问题

> 对应上游 issue：naoki66 #93「编译时 9995-wifi-mt76-mt7996-advertise-beacon-protection.patch 出错」（已关闭）

## 现象

在 mt76 `2026.10.28~0936617d` 上应用 `9995` 时：

```
Applying .../9995-wifi-mt76-mt7996-advertise-beacon-protection.patch using plaintext:
patching file mt7996/init.c
Hunk #1 FAILED at 528.
1 out of 1 hunk FAILED -- saving rejects to file mt7996/init.c.rej
Patch failed!
```

## 原因

`9995` 是针对 mt76 `467ae2e3`（2026-10-08）写的，hunk 上下文是：

```c
	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_ACK_SIGNAL_SUPPORT);
	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_CAN_REPLACE_PTK0);
	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_MU_MIMO_AIR_SNIFFER);
+	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_BEACON_PROTECTION);
	(空行)
	if (mt7996_eeprom_has_background_radar(dev) && ...
```

而 `0936617d` 在 `MU_MIMO_AIR_SNIFFER` 之后新增了四行：

```c
	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_SET_SCAN_DWELL);
	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_PUNCT);
	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_SCS);
	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_MSCS);
```

上下文不再匹配，`patch` 的 fuzz 也救不回来。

## 结论

**功能仍然需要**：`0936617d` 的 `mt7996_init_wiphy()` 里并没有
`NL80211_EXT_FEATURE_BEACON_PROTECTION`（已核对源码），不补就没有 beacon protection。

所以不是“上游已支持、删掉补丁”，而是**补丁需要 rebase**。

## 修复（已验证）

把插入点改到 `MU_MIMO_AIR_SNIFFER` 之后、`SET_SCAN_DWELL` 之前：

```diff
@@ -525,6 +525,7 @@
 	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_ACK_SIGNAL_SUPPORT);
 	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_CAN_REPLACE_PTK0);
 	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_MU_MIMO_AIR_SNIFFER);
+	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_BEACON_PROTECTION);
 	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_SET_SCAN_DWELL);
 	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_PUNCT);
 	wiphy_ext_feature_set(wiphy, NL80211_EXT_FEATURE_SCS);
```

对 `0936617d` 的 `mt7996/init.c` 执行 `patch -p1 --dry-run`：**通过**。

## 备注

- 截至 2026-11-15，naoki66 仓库里的 `9995` 仍是旧上下文；如果那条线把 mt76 升到
  `0936617d`，同样会遇到这个编译失败
- 我们当前的 `naoki66-base` 仍用 mt76 `467ae2e3`，原补丁可正常应用，不受此问题影响
- 切到 pbodq2 线（mt76 `0936617d`）时，overlay 里应使用 **rebase 版** 的 9995
