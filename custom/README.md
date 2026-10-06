# custom/ 定制目录说明

本仓库是 `naoki66/ImmortalWrt-for-Gemtek-brightspeed` 的 fork，所有“个性化修改”都放在这个目录，
上游（naoki66 + immortalwrt）更新时不会被覆盖。

**两条构建线相互独立**：`custom/config.fragment` 与 `custom/files/` 服务于 XR1710G；
`custom/config.fragment.2010`、`custom/feeds.conf.2010`、`custom/files-2010/` 只服务于 XG2010G。
改 XG2010G 的东西时，请只动 `.2010` 后缀的文件与 `build-2010.yml`，不要碰共享文件。

| 文件 | 作用 | 归属 |
| --- | --- | --- |
| `config.fragment` | 插件开关（编译前追加到 `.config`） | XR1710G |
| `config.fragment.2010` | 插件开关（只被 `build-2010.yml` 使用） | XG2010G |
| `feeds.conf.custom` | 额外 feed（daede、nikki） | XR1710G |
| `feeds.conf.2010` | 额外 feed（daede、nikki） | XG2010G |
| `files/` | 固件文件覆盖层（首次开机后台地址 `192.168.5.1`、DHCP 下发 `192.168.5.150-249`；以及「状态 → 信道分析」页面修复） | 共享 |
| `files-2010/` | 固件文件覆盖层（默认主题 Aurora、「系统」板块温度行显示全部温度、10G 链路开机自检） | XG2010G |

## 常用操作

- **改 XR1710G 插件**：改 `custom/config.fragment`，然后运行 `Build XR1710G Firmware`。
- **改 XG2010G 插件**：改 `custom/config.fragment.2010`，然后运行 `Build XG2010G Firmware`。
- **改后台地址 / DHCP 池**：改 `custom/files/etc/uci-defaults/99-custom-network.sh`
  （只在首次开机或刷机后首次启动生效，不会影响已刷好的设备）。
- **同步上游**：运行 `Sync Upstream (naoki66)`（另外每 3 天 19:00 UTC 自动跑一次）。
  它只跟随 naoki66 的树，**不会自动触发固件构建** —— 想构建时到 Actions 页手动运行
  `Build XR1710G Firmware` 或 `Build XG2010G Firmware`。
  合并冲突时工作流会**硬失败**并列出冲突文件（不自动兜底，避免悄悄丢掉一边的改动）。

## 注意事项

- `.github/workflows/build-firmware.yml` 的冲突保护**不在 `.gitattributes` 里**，而是由
  `sync-upstream.yml` 的 `Configure Git` 步骤在 CI 运行时写进 `.git/info/attributes`
  （标记 `merge=keep-ours`）。这样做是为了让 `.gitattributes` 始终跟随上游、本身不再冲突。
  ⚠️ 因此**本地手动合并上游时，要先自己把同样的两行写进 `.git/info/attributes`**，
  否则上游的同名文件会按普通合并处理，可能覆盖我们的定制版。
  上游 workflow 有大改动时，需要手动把新特性合并进来。
- `2010.config` / `1710.config` 不设保护，保持跟随 naoki66 上游更新；本仓库的插件开关一律写在
  `custom/config.fragment*`（编译时追加到 `.config`，不修改上游的原始选择）。
- **触发范围提醒**：两条构建线**都已加 `paths` 过滤**，互不干扰。
  - `build-firmware.yml`（XR1710G）：`1710.config`、`custom/config.fragment`、
    `custom/feeds.conf.custom`、`custom/files/**`、`.github/workflows/build-firmware.yml` 变化时触发。
  - `build-2010.yml`（XG2010G）：`2010.config`、`custom/config.fragment.2010`、
    `custom/feeds.conf.2010`、`custom/files-2010/**`、`custom/files/**`、
    `.github/workflows/build-2010.yml` 变化时触发。
  - `sync-upstream.yml` 不在任何一条的 `paths` 里，所以只改同步工作流不会触发构建。

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

**本节只涉及 XG2010G，不影响 XR1710G。** 用到的文件全部带 `.2010` 后缀或位于 `files-2010/`。

| 文件 | 作用 |
| --- | --- |
| `custom/config.fragment.2010` | XG2010G 的插件开关（只影响 2010 构建） |
| `custom/feeds.conf.2010` | XG2010G 专用 feed（daede、nikki） |
| `custom/files-2010/etc/uci-defaults/99-theme-aurora.sh` | 首次开机把默认界面设为 Aurora |
| `custom/files-2010/sbin/tempinfo` | 覆盖 autocore 原版：概览页「系统」板块的「温度」一行显示全部温度（CPU / lan1 / lan2 / PON） |
| `custom/files-2010/etc/xg2010g-10g-linkcheck.sh` | 开机自检两个 10G 口，见下 |
| `custom/files-2010/etc/init.d/xg2010g-10g-linkcheck` | 上面脚本的开机启动项（`START=99`，排在 rc.local 之后） |
| `.github/workflows/build-2010.yml` | XG2010G 专用构建 + 发布（tag 前缀 `xg2010g-`，与 XR1710G 分开） |

### 概览页温度显示（`files-2010/sbin/tempinfo`）

覆盖 autocore 装进去的同名脚本，让「系统」板块的「温度」一行显示全部可读温度源：

```
CPU 【60.6°C】 · lan1 【79.0°C】 · lan2 【79.0°C】 · PON 【55.0°C】
```

- 数据来源：thermal zone（CPU）、hwmon（两个万兆 RTL8261BE）、PON 光模块的 SFF-8472 DDM
  （即 BOSA 自己的温度传感器，A2h 字节 96-97，有符号 16 位 ÷ 256）。
- 传感器**按名字定位**，不按 `hwmonN` 序号 —— 序号不保证跨启动稳定。
- 覆盖能生效是因为 `include/image.mk` 的 `prepare_rootfs` 在所有包安装完之后才覆盖 `files/`。
- ⚠️ **性能敏感**：这条路径被 rpcd 的 `luci.getTempInfo` 在概览页**每 5 秒**调用一次。
  初版用 shell 循环 + `$(cat)`/`$(basename)`/`readlink`/`tr`/`sed` 逐项拼装，
  单次要 fork 约 130 次、耗时 0.225 s，把整机 fork 速率从 20/秒 拉到 80/秒、页面明显变卡。
  现在改用 shell 内建：读文件用 `read x < file`、取路径末段用 `${p##*/}`、
  判断 hwmon 属于哪个网口用内建 `test -ef`（比较同一 inode），只有最后的浮点格式化交给一次 awk。
  实测 **3 次 fork / 0.0125 s**。改这个脚本时务必保持这个量级。

### 10G 链路开机自检（`files-2010/etc/xg2010g-10g-linkcheck.sh`）

**背景**：两个 10G 口用 RTL8261BE PHY，开机建立链路时存在竞态 —— 双方 PHY 都报
`Link is Up` / `Link detected: yes`，但 SerDes/PCS 的数据通路没同步，MAC 层一个字节都收不到。
2026-10-06 发生过一次：lan1 的 `rx_bytes` 从开机起一直是 0，持续 1 小时 50 分钟，
接在它后面的 XR1710G（自身 uptime 9 天，完全无辜）及其全部下挂设备集体失联；
手动 `ip link set lan1 down; up` 立刻恢复。

**判据**：`carrier=1` 且 `rx_bytes=0`。
注意 `ethtool` 的 `Link detected: yes` 在 PHY 层是骗人的，**判断链路是否真通只能看 `rx_bytes`**。

**行为**：开机 45 秒后检查 lan1/lan2，只对真死的端口强制重新协商，最多 3 轮。
正常端口哪怕空闲也会有广播包，`rx_bytes` 不会是 0，所以不会误伤。
并发锁用 PID 文件（不用 `mkdir` 锁 —— 后者被 SIGKILL 后 trap 不执行会残留死锁、永远挡住检查）。

### 插件取舍（2026-10-06 修订）

> **读 `config.fragment*` 时不要过滤 `#` 行。**
> `.config` 片段里 `# CONFIG_PACKAGE_xxx is not set` 是**有意义的「关闭」指令**，
> 用 `grep -v '^#'` 之类的写法会把它们全部丢掉，看起来就像没关过任何东西。
> 想看「显式关闭了哪些包」用：
>
> ```sh
> grep -E '^# CONFIG_PACKAGE_.* is not set$' custom/config.fragment.2010 \
>   | sed 's/^# CONFIG_PACKAGE_//;s/ is not set$//' | sort
> ```
>
> 当前 fragment 规模：2010 显式开启 29 项 / 显式关闭 46 项；
> 1710 显式开启 26 项 / 显式关闭 51 项。想核对**实际编进镜像的结果**，
> 直接看 Release 里的 `.manifest`（比看配置可靠）：
>
> ```sh
> curl -sL <release 里 .manifest 的地址> | grep -c .          # 包总数
> curl -sL <同上> | grep -E '^(msd_lite|udpxy) '              # 应为空
> ```
> 上次 2010 构建实测 308 个包，上述关闭项与代理 `=m` 项全部核对通过。

- **IPTV**：只用 `rtp2httpd`（含 LuCI 与中文包）。它覆盖 `msd_lite` 的组播转单播能力，
  并额外支持 **RTSP → HTTP 时移/回看**、**FCC 快速换台**、EPG/`catchup-source`、udpxy URL 兼容、RS-FEC。
  因此关闭 `msd_lite` 与 `udpxy` 两组。
- **DDNS**：只用 `ddns-go`；关闭 `ddns-scripts` 全套与 `luci-app-ddns`。
- **透明代理**：
  - `daed`（eBPF，来自 `kenzok8/openwrt-daede` feed 的 `luci-app-daede` + `daed`；
    旧界面 `luci-app-daed` 不装）**已编入固件**（`=y`）。
  - `homeproxy`（sing-box）与 `Nikki`（mihomo）**只编译不编入**（`=m`）。
    `.apk` 在 artifact `xg2010g-proxy-packages` 里，拷到设备后
    `apk add --allow-untrusted` 装进 overlay 即可。
  - ⚠️ 三者会争抢 DNS 接管、TPROXY/nftables 规则与路由表，**同一时间只应启用一个**。
- **体积与镜像上限**：
  - XG2010G 的 `IMAGE_SIZE` 已由上游 `e46600c9cc` 从 **64 MiB 提高到 128 MiB**
    （`target/linux/airoha/image/an7581.mk`：`IMAGE_SIZE := 131072k`），本仓库已合并。
  - 当前实测 **48.87 MiB / 308 个包**，余量充足。
  - > 历史背景：64 MiB 时代（U-Boot 在 `0x90000000`/`0x94000000` 双缓冲间隙）是硬约束，
    > 三个代理全编入会到 75~82 MiB 直接超限，而 `check-size` 会**静默删掉 ITB**、
    > 构建仍显示"成功"。当时因此把 homeproxy/Nikki 改成 `=m`（仅 `daed`+BTF+Asterisk 为 48.42 MiB）。
    > **上限提高后理论上可以全部改回 `=y`**，但需要下次构建时验证 UBI fit 卷的放置确实正常。
  - `build-2010.yml` 的 `Report image size` 步骤会在超过 60 MiB 时告警、ITB 缺失时直接失败，
    不会再出现静默失败。
- **主题**：`luci-theme-aurora`（由 `build-2010.yml` 克隆到 `package/luci-theme-aurora`）；
  关闭 `luci-theme-glass`、`luci-theme-argon` 与 `luci-app-argon-config`。
- **语音**：保留运营商语音通话所需（`asterisk` + `asterisk-pjsip` + `asterisk-chan-en75xx` + ulaw/alaw + rtp + sln/wav + playtones + `airoha-voice-ctl`）；
  关闭本机电话主机功能（`app-record`/`app-stack`/`bridge-softmix`/`res-musiconhold`/`sounds` 及 gsm/a-mu/g722/pcm 格式）。
- **OpenClash**：**两台都不装**。
  - **XG2010G**：`build-2010.yml` 不引用 `feeds.conf.custom`，配置里显式
    `# CONFIG_PACKAGE_luci-app-openclash is not set`。
  - **XR1710G**：2026-10-06 移除。理由是**与 Nikki 完全重复** —— 两者用的都是
    mihomo 内核，只是界面不同；同时装会争抢 DNS 接管 / TPROXY / nftables 规则 / 路由表。
    Nikki 已覆盖全部功能，只保留 Nikki（另有 homeproxy、daed 共 3 个代理）。
    配套改动四处：`custom/config.fragment` 里加 `not set`、
    `custom/feeds.conf.custom` 去掉 openclash feed、
    `build-firmware.yml` 删掉 `Bundle latest OpenClash core` 步骤并去掉相关 .apk 收集、
    删除 `custom/scripts/fetch-openclash-core.sh`。
    > ⚠️ 刷入新固件后，设备上残留的 `/etc/config/openclash` 与 `/etc/openclash/`
    > 不会再被加载（init 脚本已随包一起消失），但也不会自动清理 —— 想干净就手动删掉。
- **Ruby 全家桶 + lyaml/libyaml**：**XR1710G 已移除**（12 个包，约 4.9 MiB）。
  依据：把 6 个 feed（immortalwrt/packages + luci + openwrt/routing + telephony +
  kenzok8/openwrt-daede + nikkinikki-org/OpenWrt-nikki）全部拉下来做 `DEPENDS` 反查，
  **整个仓库里唯一依赖 `ruby` 的包就是 `luci-app-openclash`**
  （它在 vernesong/OpenClash 和 `immortalwrt/luci` 两个 feed 里各有一份）。
  OpenClash 移除后 Ruby 就没有任何依赖方了；在设备上也搜不到除 OpenClash 外的 ruby 调用方。
  `lyaml` / `libyaml` 的唯一依赖者 `luci-app-passwall` 也不在 1710 清单里。
  实测体积：libruby 3838 KiB、ruby-bigdecimal 541、ruby-date 147、ruby-psych 132、
  ruby-digest 74、lyaml 53、ruby-enc 48、ruby-stringio 33、ruby-pstore 26、
  ruby-yaml 12、ruby 4（元包）、libyaml 104。
  > ⚠️ **以后若要往这台设备装 OpenClash，必须先把这套 Ruby 装回来**，否则它起不来。
  > Nikki 用 mihomo 内核（Go 写的），不需要 Ruby。
- **`gawk` / `coreutils*`：保留**（上游显式 `=y`，本仓库未动）。实测过它们同样没有依赖者，
  但属于「脚本可能按名字直接调用」的类型：设备上实测 busybox **不提供 `nohup` 和 `base64`**，
  且 `/usr/libexec/ssh-keygen-openssh` 会调用 `base64`，删了有运行时风险，收益（约 1.2 MiB）不值当。

> 注意：`daed` 会连带编译 BPF 工具链（llvm-bpf）；本仓库通过 `CONFIG_DEVEL=y` +
> `CONFIG_BPF_TOOLCHAIN_HOST=y` + `CONFIG_USE_LLVM_HOST=y` 改用宿主机 LLVM，
> 省去从源码编译 LLVM 的 30~60 分钟。若构建内存不足，把 `build-2010.yml` 里的
> `make -j$(nproc) world` 改成 `make -j2 world`。
