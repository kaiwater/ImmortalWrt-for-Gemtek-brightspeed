# ca-certificates：黑名单移除 "emSign ECC Root CA - G3"

| 项 | 值 |
| --- | --- |
| 日期 | 2026-11-05 |
| 分支 | `naoki66-base` |
| 变更文件 | `package/system/ca-certificates/Makefile`、`package/system/ca-certificates/patches/0002-blacklist-certs.patch` |
| 类型 | 信任库安全加固（CA 黑名单） |
| 适用设备 | 全部（XR1710G / XG2010G 共用） |
| 状态 | 补丁已加入，**尚未重新构建验证** |

---

## 1. 背景

`emSign ECC Root CA - G3` 曾为 eMudhra 签发过私钥强度只有 0–255（8 位）的中间 CA。
这种密钥空间可以被穷举，签发链不再具备可信性。Debian 与 OpenWrt 已分别将其列入
不信任名单，本次把该修复带进本仓库，减少被投毒 / 中间人劫持的机会
（尤其是构建期与运行期通过 HTTPS 拉取内容时的证书校验）。

## 2. 依据

- Debian bug #1151413，Debian `ca-certificates` 提交 `4a0203e5ce4c`
- OpenWrt PR <https://github.com/openwrt/openwrt/pull/26066>，上游提交 `63f702f1c0ce`
- 参考实现：`chasey-dev/immortalwrt-mt798x-rebase` 提交 `4a686570eb64`

## 3. 变更内容

- 新增 `patches/0002-blacklist-certs.patch`：在源码 `mozilla/blacklist.txt` 中加入
  `"emSign ECC Root CA - G3"` 与 `"Comodo AAA Services root"` 两条黑名单项
  （后者在新版 certdata 中已被移除，补丁保留是为了与 Debian 上游一致）。
- `PKG_RELEASE` 从 `1` 提升到 `2`，确保构建系统重新打包该包。

## 4. 验证方式

**已做（静态）**：

- 对 `ca-certificates_20260816` 源码包执行 `patch -p1 --dry-run`，干净应用
- 源码 `mozilla/certdata.txt` 中确认存在 `CKA_LABEL UTF8 "emSign ECC Root CA - G3"`
- 源码包 sha256 与 Makefile 的 `PKG_HASH` 一致（`d939bcdd…`）

**未做（需要下一次构建）**：

- 未重新编译，设备上仍是旧 CA bundle
- 未验证生成后的 `ca-certificates.crt` 中该证书确实消失

构建后应检查：

```sh
# 命中数应为 0
grep -c "emSign ECC Root CA - G3" /etc/ssl/certs/ca-certificates.crt

# ca-certificates 包版本应为 -r2
apk list --installed | grep ca-certificates
```

## 5. 影响范围

- 所有依赖 `ca-bundle` / `ca-certificates` 做 TLS 校验的组件（curl、wget、opkg/apk、
  LuCI 下载、passwall/sing-box 的 TLS 出站等）
- 若有内部服务证书链依赖该根 CA，将开始校验失败——这是预期的安全行为

## 6. 如何确认生效

见第 4 节的命令；另外可在设备上执行：

```sh
awk '/BEGIN CERTIFICATE/{n++} /emSign ECC Root CA - G3/{print "still present"}' \
  /etc/ssl/certs/ca-certificates.crt
```

## 7. 风险与回滚

- 风险：极少数仍在使用该根 CA 的站点/服务会连接失败
- 回滚：删除 `0002-blacklist-certs.patch` 并把 `PKG_RELEASE` 改回 `1`，重新构建

## 8. 参考

- 上游 OpenWrt 提交：<https://github.com/openwrt/openwrt/pull/26066>
- Debian 修复：<https://salsa.debian.org/debian/ca-certificates/-/commit/4a0203e5ce4ce1a064b97387f52ca6a00c97185c>
- 参考仓库提交：<https://github.com/chasey-dev/immortalwrt-mt798x-rebase/commit/4a686570eb6495635279273f034caa2a0f37f36e>
