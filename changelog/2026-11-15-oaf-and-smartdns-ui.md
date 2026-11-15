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

## 5. 整机镜像与实机验证（2026-11-15 17:22 刷入）

```
大小    83,128,615 字节（79.3 MiB，比上一版 +7 MB）
SHA256  965e36e3e4271d7fe6f409d748cf4c41eb00ba0375bb752a372acdc6466b9bc3
包数    412（上一版 406；新增 6 = kmod-oaf/appfilter/luci-app-appfilter/中文翻译/smartdns-ui，
        其中 smartdns 本来就在）
```

刷机：保留配置 `sysupgrade`，`sysupgrade -T` 预检 rc=0，重启约 170 s 回来。
配置继承完好（hostname / LAN 192.168.1.1/24 / passwall 188 段）。

实机结果：

| 项 | 结果 |
|---|---|
| `kmod-oaf` | 已加载，`oaf: Driver ver. 5.3.3`；`oaf.ko` 722 KB |
| `appfilter` | 服务 enabled + running，`/usr/bin/oafd` 已起 |
| OAF 开关 | `appfilter.global.enable='0'`（默认关闭，未接管流量） |
| OAF LuCI | `/cgi-bin/luci/admin/services/appfilter` → 403（未登录，路由存在） |
| oafd 启动日志 | 2 条 `ash: write error` / `uci: Entry not found`，仅启动时一次 |
| `smartdns-ui` | `/usr/lib/smartdns_ui.so` 5.0 MB + `wwwroot` 6.9 MB |
| smartdns 服务 | enabled / stopped（与刷机前一致，未启用） |
| 回归项 | WAN 10000 Mb/s carrier=1、ping 6.7 ms、三频 SSID 正常、nct7802 37.9℃/2332 rpm、CA 120 条、passwall 3 进程、dmesg 0 panic/oops |

结论：OAF 与 smartdns-ui 都已进镜像并可运行；OAF 默认不启用，
需要在 LuCI 打开（或 `uci set appfilter.global.enable=1`
+ `/etc/init.d/appfilter restart`）才会接管流量。启用后的
flowtable/HNAT 影响仍需单独测。

## 6. 发布

```
tag     20261115-46f98e0（基于 46f98e0a48）
title   ImmortalWrt for XR1710G 20261115-46f98e0
资产    itb 83,128,615 B / manifest / version / config / feeds / profiles / sha256sums
镜像    e5179cabc35c051c229a52122b47280d6370b07069c59eb4cccf57f9dd2d3cef
```

刷机后的运行版本与发布资产一致（`2026-11-15-46f98e0`，412 包）。
