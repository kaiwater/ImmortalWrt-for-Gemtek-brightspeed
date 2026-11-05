# ca-certificates：黑名单移除 "emSign ECC Root CA - G3"

| 项 | 值 |
| --- | --- |
| 日期 | 2026-11-05 |
| 分支 | `naoki66-base` |
| 变更文件 | `package/system/ca-certificates/Makefile`、`package/system/ca-certificates/patches/0002-blacklist-certs.patch` |
| 类型 | 信任库安全加固（CA 黑名单） |
| 适用设备 | 全部（XR1710G / XG2010G 共用） |
| 状态 | 补丁已加入；已在运行设备上按第 8 节热修复并验证；**镜像待下次构建固化** |

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

### 4.1 静态校验（构建前）

**已做**：

- 对 `ca-certificates_20260816` 源码包执行 `patch -p1 --dry-run`，干净应用
- 源码 `mozilla/certdata.txt` 中确认存在 `CKA_LABEL UTF8 "emSign ECC Root CA - G3"`
- 源码包 sha256 与 Makefile 的 `PKG_HASH` 一致（`d939bcdd…`）

### 4.2 热修复后实机验证（2026-11-05）

在运行 `immortalwrt 20261102-87a4119c-2248ed75` 的 XR1710G 上，按第 8 节步骤
直接修改运行中的 bundle：

- bundle 证书数：**121 → 120**，重新扫描确认 emSign 已不存在
- `apk update` 正常（`10312 distinct packages available`）
- `uclient-fetch https://downloads.immortalwrt.org/` 正常下载
- `openssl s_client -CAfile /etc/ssl/certs/ca-certificates.crt` 对正常站点校验通过

**正向/反向用例**（测试域名 `dv-g3b-emudhra.we-have-a-problem.com`，其证书链到
`CN=EM DV TLS CA - G3B` → emSign 根）：

| 使用的 CA bundle | openssl 结果 | curl 结果 |
| --- | --- | --- |
| 当前（已拉黑） | `verify error:num=20:unable to get local issuer certificate` | `http=000`（TLS 失败） |
| 备份（未拉黑） | `Verify return code: 0 (ok)` | `http=200` |

说明拉黑行为精准生效，且没有误伤其它根证书。

### 4.3 尚未验证

- **未重新构建镜像**：本次是通过热修复在运行设备上验证的，squashfs 里仍是旧 bundle
- 未在 XG2010G 上验证
- 上述结论仅覆盖单一设备、单一固件版本与单一测试域名，其它环境可能不同

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

## 8. 热修复（可选，无需重新构建）

适用于已经在运行旧镜像、暂时不想重新构建的设备。原理是把运行系统中
`/etc/ssl/certs/ca-certificates.crt` 里对应的证书块删掉。

持久性：

- 改动写在 **overlay**，重启后仍然有效
- 下次 `sysupgrade` 会用新镜像的 rootfs 覆盖 `/etc/ssl/certs/`；新镜像已包含
  本补丁，因此升级后仍是拉黑状态

### 8.1 操作步骤（设备上 root 执行）

```sh
B=/etc/ssl/certs/ca-certificates.crt
cp -a "$B" /root/ca-certificates.crt.bak

rm -f /tmp/p*.pem /tmp/newbundle.crt
awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++; f=sprintf("/tmp/p%03d.pem", n)} {print > f} /END CERTIFICATE/{close(f)}' "$B"

for f in /tmp/p*.pem; do
    s=$(openssl x509 -in "$f" -noout -subject 2>/dev/null || true)
    case "$s" in
        *"emSign ECC Root CA - G3"*) echo "drop: $s" ;;
        *) cat "$f" >> /tmp/newbundle.crt ;;
    esac
done

chmod 644 /tmp/newbundle.crt
mv /tmp/newbundle.crt "$B"
rm -f /tmp/p*.pem
```

### 8.2 验证

```sh
# 证书数应减少 1（本机 121 → 120）
grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/ca-certificates.crt

# 基础连网能力
apk update
uclient-fetch -O /dev/null https://downloads.immortalwrt.org/

# 反向用例：应因证书链不可信而失败
curl -sS -o /dev/null https://dv-g3b-emudhra.we-have-a-problem.com/

# 正向对照：用备份 bundle 应成功（http=200）
curl -sS -o /dev/null --cacert /root/ca-certificates.crt.bak \
     https://dv-g3b-emudhra.we-have-a-problem.com/
```

### 8.3 回滚

```sh
cp /root/ca-certificates.crt.bak /etc/ssl/certs/ca-certificates.crt
```

> 说明：重建 bundle 时证书顺序可能与原文件不同，这不影响证书校验；
> 如果你需要与发行版完全一致的顺序，请用重新构建的镜像而不是热修复。

## 9. 参考

- 上游 OpenWrt 提交：<https://github.com/openwrt/openwrt/pull/26066>
- Debian 修复：<https://salsa.debian.org/debian/ca-certificates/-/commit/4a0203e5ce4ce1a064b97387f52ca6a00c97185c>
- 参考仓库提交：<https://github.com/chasey-dev/immortalwrt-mt798x-rebase/commit/4a686570eb6495635279273f034caa2a0f37f36e>
