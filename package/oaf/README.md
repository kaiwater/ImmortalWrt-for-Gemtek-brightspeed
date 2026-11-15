# OAF (OpenAppFilter) 7.0.2 — vendored packages

这三个目录是从 [`kenzok8/small-package`](https://github.com/kenzok8/small-package)
同步过来的（与 `kaiwater/wrt_release` 取 OAF 的方式一致），因为
`immortalwrt/packages` feed 里的 `open-app-filter` 还是旧版：

| 包 | 来源目录 | 版本 |
|---|---|---|
| `appfilter`（用户态守护进程 `oafd`） | `open-app-filter/` | **7.0.2** |
| `kmod-oaf`（内核模块 `oaf.ko`） | `oaf/` | 跟随内核 |
| `luci-app-oaf`（LuCI 界面） | `luci-app-oaf/` | 7.0-r2 |

同步基准：

```
repo    https://github.com/kenzok8/small-package
commit  41ae244f30603368d739786f496e00700f55464f
date    2026-11-15
```

## 本地改动（与上游不同的地方）

1. **ACL 文件改名**：`appfilter` 和 `luci-app-oaf` 都会安装
   `/usr/share/rpcd/acl.d/luci-app-oaf.json`，apk 不允许两个包覆盖同一路径。
   `open-app-filter/Makefile` 里把 appfilter 的那份装成
   `acl.d/appfilter-oaf.json`（与 wrt_release 的 `fix_appfilter_acl_conflict` 相同）。
2. 删除上游误提交的 `luci-app-oaf/luasrc/view/oaf/.dashboard.htm.swp`。

## 为什么 vendored 而不是加 feed

- 只需要三个包，`kenzok8/small-package` 整个 feed 很大，里面很多包与我们现有的
  passwall / lucky / nikki 等重名；
- 固定 commit 才能复现，不跟着别人的 `main` 漂。

## 与 feed 旧版的去重

`immortalwrt/packages` 里仍有一份 `open-app-filter`，会定义同名的
`appfilter` / `kmod-oaf`。CI 在 `feeds install -a` 之后会执行
「Drop duplicate open-app-filter from feeds」，删掉 `package/feeds/*/open-app-filter`；
本地构建时同样要删一次，否则 metadata 扫描会看到两个同名包。

3. **固定翻译包版本**：`luci-app-oaf/Makefile` 里加 `PKG_PO_VERSION:=7.0.2`。
   vendored 目录没有 `po/` 的 git 历史，`luci.mk` 的 `findrev` 会得到 `0`，
   导致生成 `luci-i18n-oaf-zh-cn-0.apk`。
