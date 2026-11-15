# 2026-11-15 应用层调整：恢复 OAF、恢复 smartdns-ui

## 1. OAF（OpenAppFilter）回到包里

OAF 在当前 feed 里叫 `open-app-filter`，由三个包组成：

| 包 | 作用 |
|---|---|
| `kmod-oaf` | netfilter 内核模块（`oaf.ko`） |
| `appfilter` | 用户态守护进程，依赖 `kmod-oaf` |
| `luci-app-appfilter` | LuCI 界面（`LUCI_DEPENDS := +appfilter +luci-compat`） |
| `luci-i18n-appfilter-zh-cn` | 中文翻译 |

`custom/config.fragment` 里加了：

```
CONFIG_PACKAGE_luci-app-appfilter=y
CONFIG_PACKAGE_luci-i18n-appfilter-zh-cn=y
CONFIG_PACKAGE_appfilter=y
CONFIG_PACKAGE_kmod-oaf=y
```

> 文件头写着"不要在这里放 kmod-*"，`kmod-oaf` 是应用层 netfilter 模块
> （不是平台/板级包），所以按例外处理并加了注释。

## 2. smartdns-ui 恢复

见 `2026-11-15-local-build-and-fixes.md` §2 的勘误：之前判断"上游构建不了"
是错的，真实原因是 `node/host` 把宿主 Node 写死成 `linux-x64`，在 arm64
构建机上装了个 x86-64 的 node。CI（x86_64）一直能编。

处理：

- `1710.config`：`CONFIG_PACKAGE_smartdns-ui=y`
- `.github/workflows/build-firmware.yml`：`Build Firmware` 之前插入
  `actions/setup-node@v4`（`node-version: '22'`）+ 打印版本，显式满足
  Next.js 16 / React 19 的 Node ≥ 20.9 要求

## 3. 本地验证（只编包，不出镜像）

在 arm64 容器里把 `staging_dir/hostpkg/bin/node` 临时指向官方
Node 22.11 后：

```
CONFIG_PACKAGE_kmod-oaf=y
CONFIG_PACKAGE_appfilter=y
CONFIG_PACKAGE_luci-app-appfilter=y
CONFIG_PACKAGE_luci-i18n-appfilter-zh-cn=y
CONFIG_PACKAGE_smartdns-ui=y
```

产物：

```
bin/targets/airoha/an7581/packages/kmod-oaf-6.18.55.2026.04.20~569f93bf-r1.apk
bin/packages/aarch64_cortex-a53/packages/appfilter-2026.04.20~569f93bf-r1.apk
bin/packages/aarch64_cortex-a53/luci/luci-app-appfilter-6.1.4-r1.apk
bin/packages/aarch64_cortex-a53/luci/luci-i18n-appfilter-zh-cn-26.315.10273~ad75cde.apk
bin/packages/aarch64_cortex-a53/packages/smartdns-48.4-r1.apk
bin/packages/aarch64_cortex-a53/packages/smartdns-ui-48.4-r1.apk   (6.5 MB)
```

`oaf.ko` 已针对 6.18.55 编译通过；webui 的 `next build` 输出
`✓ Compiled successfully`，`wwwroot` 正常打进 `smartdns-ui`。

## 4. 待观察

- OAF 依赖 `kmod-ipt-conntrack`（iptables 系），与本机 nftables/fw4 并存；
  实机上要确认 `appfilter` 能正常抓流、且不影响硬件 flowtable。
- OAF 与 flow offload 历史上会互相干扰，属运行时问题，编译期看不出来。
