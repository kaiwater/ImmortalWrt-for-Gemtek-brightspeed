# Windows 端：阻断 emSign ECC Root CA - G3 的问题中间证书

本目录提供 Windows 7 / Windows 10 两套脚本，用于在本机阻断
`emSign ECC Root CA - G3` 签发的问题中间证书，**根证书保持受信**。

## 背景（简述）

- `emSign ECC Root CA - G3`（eMudhra）曾签发私钥只有 8 位（0–255）的中间 CA，
  密钥空间可穷举，能伪造任意站点证书。
- Debian（#1151413）、OpenWrt（PR #26066）已把该根列入黑名单。
- 微软截至 2026-11-05 仍把 eMudhra 的根列为 `Included`；其 Disallowed 列表
  通过 Windows Update 下发。
- Windows 7 已 EOL（2020-01，ESU 2023-01 结束）、Windows 10 已 EOL
  （2025-10-14，消费者 ESU 2026-10-13 结束），**收不到后续根证书更新**。
- Chrome 105+ 使用 Chrome Root Store（不含该根，天然不受影响）；
  Edge、IE、360、猎豹、搜狗等使用 Windows 系统根库，受本方案影响。

完整来龙去脉、参数说明与风险提示见各目录下的 `README.txt`。

## 选择目录

| 系统 | 目录 | 运行方式 |
| --- | --- | --- |
| Windows 7 | [`win7/`](win7/README.txt) | 右键 `run.cmd` → 以管理员身份运行 |
| Windows 10 | [`win10/`](win10/README.txt) | 右键 `run.cmd` → 以管理员身份运行 |

两个目录内容一致，仅默认阈值不同（Win7 用 1024 位、Win10 用 2048 位启发式）。

## 快速开始

1. 把对应目录整个拷到目标机器（保留同目录结构）。
2. 右键 `run.cmd` → **以管理员身份运行**，先看扫描结果（不加参数只预览）。
3. 按需执行阻断：

```bat
:: 启发式：只阻断密钥长度异常小的中间证书
powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1 -Apply -WeakOnly

:: 精确：按扫描结果里的指纹阻断
powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1 -Apply -Thumbprints 指纹1,指纹2

:: 本机未缓存时：指定证书文件
powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1 -Apply -CertFile bad-intermediate.cer
```

4. 回滚：

```bat
powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1 -Rollback
```

## 验证

- 证书存储：`certutil -store Disallowed` 应能看到被阻断的中间证书
- 在线用例：浏览器打开 <https://dv-g3b-emudhra.we-have-a-problem.com/>
  - 出现证书错误/拦截页 → 阻断生效
  - 正常打开 → 仍受信，检查是否选对了中间证书

## 备份位置

```
%ProgramData%\emsign-g3-block\<指纹>.cer     每张被阻断证书的原始导出
%ProgramData%\emsign-g3-block\blocked.csv    阻断清单（供 -Rollback 使用）
```

## 免责声明

脚本与说明仅针对上述场景；验证结果只保证在文档列明的系统版本、补丁级别与
浏览器组合下成立，不构成对其它环境或后续版本的保证。批量部署前请先在测试机
验证并做好备份。
