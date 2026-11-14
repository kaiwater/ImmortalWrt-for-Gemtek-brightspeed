# pbodq2 作为上游：跟随模型

> 状态：已确认方向（2026-11-15），尚未开始移植。
> 现有发布线仍是 `naoki66-base`；本模型作为并行评估线。

## 1. 原则

1. **上游 = pbodq2 的 release tag**（`ubi2-YYYYMMDD`），冻结、只读
2. **本地只维护 thin overlay**，目标 ≤ 10 个文件
3. **每个新 release 重新基于 tag**，overlay 用 rebase / 复制方式带入
4. **不跟分支头**，只认 tag（与发行二进制一一对应）
5. **CI 用我们自己的**，不接 pbodq2 的 Actions

## 2. 当前参考点

```
tag        ubi2-20261108
commit     8b28a83c42  (wifi: mt76: npu: fix the rx descriptor ownership handshake)
内核       6.18.60
mt76       0936617d（2026-10-28）
patches    173 个（target/linux/airoha）
```

设备相关事实：

- 分区布局：`vendor 0x0–0x600000 / chainloader 0x600000–0x700000 / ubi 0x700000–0x1be00000 / reserved 0x1be00000`
  → **与 XR1710G 实机一致**，`-ubi` 只是命名差异
- DTS compatible：`gemtek,xr1710g-ubi`
- `DEVICE_COMPAT_VERSION = 2.0`
- `&i2c0` 没有 `airoha-i2c` 覆盖 → 板温/风扇正常
- 已有 ca-certificates 黑名单（`0002-blacklist-certs.patch`）

首次从 `naoki66-base`（板名 `gemtek,xr1710g`、compat 1.0）切到这条线，需要：

```sh
sysupgrade -F <ubi2-*.itb>     # 板名 + compat 都不匹配，必须强制
```

切换后板名变为 `gemtek,xr1710g-ubi`，之后同线升级不再需要 `-F`。
如要避免来回切换都要 `-F`，在 overlay 里加板名兼容（见 §3）。

## 3. Overlay 清单（必须显式维护）

| 文件 | 作用 | 必要性 |
|---|---|---|
| `custom/config.fragment` | 应用层软件包 | 必须 |
| `custom/files/**` | apk 源、channel_analysis 等覆盖 | 必须 |
| `1710.config`（或等价 seed） | 构建配置种子 | 必须 |
| `patches/local/630-net-pcs-airoha-extend-rx-calib-to-E2-and-PON.patch` | WAN/PCS RX 校准（pbodq2 tag 没有） | 建议 |
| `patches/local/9995-wifi-mt76-mt7996-advertise-beacon-protection.patch` | beacon protection（tag 没有） | 按需 |
| `target/linux/airoha/image/an7581.mk` 的板名兼容 | 同时接受 `gemtek,xr1710g` 与 `-ubi` | 建议 |
| `.github/workflows/build-firmware.yml` | 我们自己的构建流程（缓存、Release 摘要、paths） | 必须 |
| `docs/`、`changelog/`、`scripts/check-upstream.sh` | 文档与工具 | 可选 |
| `patches/local/*`（其它） | 仅在有实际症状时加入，一项一个补丁 | 按需 |

**约束**：overlay 超过 ~10 个文件就说明方向错了——要么推给上游，要么放弃。

## 4. 每次 pbodq2 发新 release 的操作

```sh
# 1. 拉新 tag
git fetch --filter=blob:none pbodq2 tag ubi2-YYYYMMDD

# 2. 从 tag 建新分支
git switch -c pbodq2-base-YYYYMMDD ubi2-YYYYMMDD

# 3. 带入 overlay（两种方式任选）
#    a) 从上一个 base 复制
git checkout pbodq2-base -- custom/ 1710.config patches/local/ .github/ docs/ changelog/ scripts/
#    b) 或 rebase overlay 提交
# git rebase --onto ubi2-YYYYMMDD <旧base> <overlay分支>

# 4. 提交 overlay
git commit -m "overlay: rebase onto ubi2-YYYYMMDD"

# 5. 构建（手动 dispatch，release_type=none 先验证）
gh workflow run build-firmware.yml --ref pbodq2-base-YYYYMMDD \
  -f config_seed=1710.config -f release_type=none
```

通过验证后再决定是否 `release_type=release`，以及是否把发布线切过来。

## 5. 验证清单（每个 tag 必跑）

### 构建期

- [ ] 镜像产出，文件名/tag 正确
- [ ] `manifest` 里关键包齐全（passwall/sing-box/chinadns-ng/工具集）
- [ ] `config.buildinfo` 里没有异常丢包

### 实机

- [ ] 冷启动 ×5：WAN 10G 起来、DHCP 完成
- [ ] 热重启 ×5：同上
- [ ] 风扇/板温：`nct7802` 存在，`temp1_input` 非 0，`fan1_input` 有转速
- [ ] WiFi：2.4G / 5G / 6G 起 SSID，客户端可关联
- [ ] MLO：至少验证现有配置（2.4+5 组合是否支持按现状记录，不阻塞）
- [ ] CA：`/etc/ssl/certs/ca-certificates.crt` 不含 `emSign ECC Root CA - G3`
- [ ] 包清单：`apk list --installed` 与预期一致
- [ ] dmesg：无 panic / Oops / NPU SER 反复

### 回退

- [ ] 保留上一个 tag 的镜像，失败可回退
- [ ] 记录 `-F` 需求（板名/compat 变化时）

## 6. 质量门与回退策略

- **连续两个 pbodq2 tag 通过验证**，才考虑把发布线从 `naoki66-base` 切过来
- 任一 tag 不通过 → 留在旧 tag，不跟
- `naoki66-base` 保留为应急回退线（切回需 `-F`）
- 每次切换/验证结果记录到 `changelog/`

## 7. 已知风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| 无社区反馈 | pbodq2 仓库 0 issue、release 下载量 2–15 | 用 §5 清单自证 |
| 仅二进制发布 | 无 manifest/config | 我们自己构建，产物可核对 |
| 补丁来源混杂 | 173 个补丁，含 NoTengoBattery/hurryman/fanboy 等 | 出问题按文件归因 |
| 板名/compat | `-ubi` + compat 2.0 | overlay 加兼容；首次 `-F` |
| 缺我们的修复 | PCS 630、beacon 9995 | overlay 显式保留 |
| 上游可能重写历史 | naoki66 已发生过 | 只认 tag，不认分支头 |

## 8. 与旧 fork 的关系

`kaiwater/OpenWRT-W1700K-XR1710G`（pbodq2 的 fork）里有 65 个提交的历史经验，
其中大部分已被新 tag 吸收或已被我们现在的实现取代。
筛选结果见 [`upstream-pbodq2-audit.md`](upstream-pbodq2-audit.md)。
