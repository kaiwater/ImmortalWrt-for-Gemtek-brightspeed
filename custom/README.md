# custom/ 定制目录说明

本仓库是 `naoki66/ImmortalWrt-for-Gemtek-brightspeed` 的 fork，所有“个性化修改”都放在这个目录，
上游（naoki66 + immortalwrt）更新时不会被覆盖。

| 文件 | 作用 |
| --- | --- |
| `config.fragment` | XR1710G 插件开关（编译前追加到 `.config`，可增删要编译的插件） |
| `config.fragment.2010` | XG2010G 插件开关（只影响 `build-2010.yml`） |
| `feeds.conf.2010` | XG2010G 额外 feed（kenzok8/openwrt-daede、nikkinikki-org/OpenWrt-nikki） |
| `files/` | 固件文件覆盖层（首次开机后台地址 `192.168.5.1`、DHCP 下发 `192.168.5.100-249`；以及「状态 → 信道分析」页面修复） |
| `files-2010/` | XG2010G 专用文件覆盖层（默认主题设为 Aurora） |

> OpenClash 相关文件（`feeds.conf.custom`、`scripts/fetch-openclash-core.sh`）已于 2026-10-04 移除。

## 常用操作

- **增/减插件**：改 `custom/config.fragment`（XR1710G）或 `custom/config.fragment.2010`（XG2010G），
  然后手动运行对应的构建工作流。
- **改后台地址**：改 `custom/files/etc/uci-defaults/99-custom-network.sh`（只在首次开机或刷机后首次启动生效）。
- **同步上游**：运行 `Sync Upstream (naoki66 + ImmortalWrt)`，会自动合并并触发一次构建 + 发布 Release。

## 注意事项

- `.gitattributes` 里把 `.github/workflows/build-firmware.yml` 标记为 `merge=keep-ours`：
  同步上游时如果该文件冲突，会保留本仓库版本（因为里面含定制 hook）。上游 workflow 有大改动时，
  需要手动把新特性合并进来。
- `config.seed` 不设保护，保持跟随 naoki66 上游更新；本仓库的插件开关一律写在 `custom/config.fragment*`。

## 信道分析页面修复

`files/www/luci-static/resources/view/status/channel_analysis.js` 覆盖了 luci-mod-status 安装的同名文件，
修掉 ImmortalWrt 自带「状态 → 信道分析」在这台机器上的三个问题：

| 现象 | 原因 | 修法 |
| --- | --- | --- |
| 2.4G/5G/6G 的信道柱状图全部挤在左边重叠 | 非激活标签页宽度为 0，`create_channel_graph()` 用 `offsetWidth` 算出的列宽为负 | 等面板真正有宽度后再绘制，切换标签时补绘 |
| 5GHz 只扫到低段（149/153 等 80MHz 热点不见） | 页面用 UCI 名（`radio1`）调 iwinfo，iwinfo 把它解析成该 phy 的**第一个**接口，返回的是另一个频段的结果 | 先解析真实接口名（`phy0.1-ap0`）再扫描 |
| 6GHz 一直停在 “Starting wireless scan...” | 整颗 phy 的完整扫描要 20 秒以上，超过 rpcd 的 30 秒 ubus 超时，而页面没有失败处理 | 先渲染缓存结果，再用完整扫描刷新；失败时给出提示并停止轮询 |

维护说明：

- 这是文件覆盖，不依赖 `patches/feeds/` 补丁，所以上游改动不会导致编译失败；代价是上游对同一文件的更新不会自动跟进来。
- 需要跟进上游时：`git -C feeds/luci log --oneline -- modules/luci-mod-status/htdocs/luci-static/resources/view/status/channel_analysis.js`，把上游改动手工合进本文件。
- 同样的修复已按 naoki66 的 `patches/feeds/` 约定提交 PR；若上游合并，可以直接删除这个覆盖文件。
- 覆盖文件当前为 20215 字节，md5 `e040c901f50e451e7a4c77275b997f7b`。
- 改完这个文件后**必须**做一次运行时验证：`tabs.firstElementChild.appendChild(tab)` 这一行原文没有行尾分号，如果在它后面追加以 `(` 开头的语句，会被 JS 解析成 `appendChild(tab)( ... )`，浏览器直接抛 `TypeError: ... is not a function`；`node --check` 只会做语法检查，查不出这个问题。可在 Node 里用桩对象真正执行一遍 `render()`，或至少刷一次页面确认无红色报错。

## XG2010G（2010.config）专用定制

| 文件 | 作用 |
| --- | --- |
| `custom/config.fragment.2010` | XG2010G 的插件开关（只影响 2010 构建） |
| `custom/feeds.conf.2010` | XG2010G 专用 feed（daede、nikki） |
| `custom/files-2010/etc/uci-defaults/99-theme-aurora.sh` | 首次开机把默认界面设为 Aurora |
| `.github/workflows/build-2010.yml` | XG2010G 专用构建 + 发布（tag 前缀 `xg2010g-`，与 XR1710G 分开） |

### 插件取舍（2026-10-04 修订）

- **IPTV**：只用 `rtp2httpd`（含 LuCI 与中文包）。它覆盖 `msd_lite` 的组播转单播能力，
  并额外支持 **RTSP → HTTP 时移/回看**、**FCC 快速换台**、EPG/`catchup-source`、udpxy URL 兼容、RS-FEC。
  因此关闭 `msd_lite` 与 `udpxy` 两组。
- **DDNS**：只用 `ddns-go`；关闭 `ddns-scripts` 全套与 `luci-app-ddns`。
- **透明代理**：**三个全部编入固件** —— `homeproxy`（sing-box）、`Nikki`（mihomo）、`daed`（eBPF）。
  - `daed` 来自 `kenzok8/openwrt-daede` feed（`luci-app-daede` + `daed`），旧界面 `luci-app-daed` 不装。
  - ⚠️ 三者会争抢 DNS 接管、TPROXY/nftables 规则与路由表，**同一时间只应启用一个**。
  - ⚠️ **体积风险**：镜像上限 64 MiB（硬约束）。已知仅 `daed` + BTF + Asterisk 时为 48.42 MiB；
    再叠加 `sing-box` + `mihomo` 后预估 75~82 MiB，**很可能超限**。若超限，
    把 `config.fragment.2010` 里 homeproxy / Nikki 两组改成 `=m`（只编译不编入），
    从 artifact `xg2010g-proxy-packages` 取 `.apk` 装进 overlay 即可。
- **主题**：`luci-theme-aurora`（由 `build-2010.yml` 克隆到 `package/luci-theme-aurora`）；
  关闭 `luci-theme-glass`、`luci-theme-argon` 与 `luci-app-argon-config`。
- **语音**：保留运营商语音通话所需（`asterisk` + `asterisk-pjsip` + `asterisk-chan-en75xx` + ulaw/alaw + rtp + sln/wav + playtones + `airoha-voice-ctl`）；
  关闭本机电话主机功能（`app-record`/`app-stack`/`bridge-softmix`/`res-musiconhold`/`sounds` 及 gsm/a-mu/g722/pcm 格式）。
- **OpenClash**：不使用，已移除全部残留（feed、内核下载脚本、workflow hook、配置开关）。

> 注意：`daed` 会连带编译 BPF 工具链（llvm-bpf）；本仓库通过 `CONFIG_DEVEL=y` +
> `CONFIG_BPF_TOOLCHAIN_HOST=y` + `CONFIG_USE_LLVM_HOST=y` 改用宿主机 LLVM，
> 省去从源码编译 LLVM 的 30~60 分钟。若构建内存不足，把 `build-2010.yml` 里的
> `make -j$(nproc) world` 改成 `make -j2 world`。
