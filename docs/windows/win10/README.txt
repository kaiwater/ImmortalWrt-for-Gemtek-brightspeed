============================================================
 emSign ECC Root CA - G3 问题中间证书处理（Windows 10）
============================================================

【来龙去脉】

1. CA 问题
   eMudhra Technologies Limited 的根证书 "emSign ECC Root CA - G3"
   （SHA-1 3043FA4FF257DCA0C380EE2E58EA78B23FE6BBC1）曾为 eMudhra
   签发过一批中间 CA 证书，其私钥只有 8 位（取值 0-255）。这种密钥空间
   可以被穷举，任何人都能伪造该中间 CA 的签名，进而伪造任意站点证书。

2. 各方处置
   - Debian：bug #1151413，ca-certificates 已把该根列入黑名单
   - OpenWrt：PR #26066，同样加入 blacklist
   - 微软：截至 2026-11-05 抓取的微软信任根计划（CCADB）清单，
     eMudhra 名下 16 张根证书仍全部是 "Included"（受信）；
     微软的“不信任列表”(Disallowed CTL) 通过 Windows Update 下发
   - Chrome：Chrome Root Store v44 只收录了 emSign Root CA - G1，
     不包含 G3，所以 Chrome 105+ 天然不信任该根
   - Edge / IE / 360 / 猎豹 / 搜狗等：使用 Windows 系统根库，
     因此是否受影响取决于本机 Windows 的根证书状态

3. Windows 10 的问题
   Windows 10 已于 2025-10-14 结束支持，消费者 ESU 到 2026-10-13 结束，
   之后不再接收微软的 CTL / 根证书更新。即使微软以后把该根移入
   Disallowed，也不会自动生效，需要手动处理。

【处理思路】

不删除根证书（根仍为大量正常站点签发证书，整根拉黑会误伤），
而是把“由该根签发的问题中间证书”加入本机的「不信任」存储
(Disallowed)。效果：

  - 根证书继续受信
  - 正常中间证书不受影响
  - 被加入黑名单的中间证书无法再用于构建证书链

说明：证书的“吊销(revoke)”只能由 CA 执行；本脚本做的是本机不信任，
不是吊销。

【适用与前提】

  - 系统：Windows 10（1809 及以上均可），PowerShell 5.1
  - 权限：管理员（脚本会检查，非管理员会退出）
  - 网络：无需联网（脚本只操作本机证书存储）
  - 建议：先在一台机器上验证，再批量部署

【目录内容】

  README.txt             本说明
  block-emsign-g3.ps1    主脚本
  run.cmd                启动器（右键“以管理员身份运行”）

【使用方法】

第 1 步：以管理员身份运行 run.cmd
        右键 run.cmd -> “以管理员身份运行”
        （或手动：powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1）

第 2 步：先扫描（不加参数）
        脚本会列出：
          - 本机是否存在该根证书（只显示，不修改）
          - 本机缓存中由该根签发的中间证书：主题、指纹、密钥长度、有效期

第 3 步：执行阻断，三种方式任选
        a) 只阻断密钥长度异常小的中间证书（启发式）：
           powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1 -Apply -WeakOnly
        b) 按指纹精确阻断（推荐，先在上一步输出里抄指纹）：
           powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1 -Apply -Thumbprints 指纹1,指纹2
        c) 指定证书文件阻断（本机尚未缓存该中间证书时）：
           powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1 -Apply -CertFile bad-intermediate.cer

第 4 步：验证
        查看不信任存储：
          certutil -store Disallowed
        浏览器验证（需要能访问外网）：
          https://dv-g3b-emudhra.we-have-a-problem.com/
        该站点证书链为 emSign G3 根 -> 问题中间证书：
          - Edge / IE / 360 / 猎豹 / 搜狗：出现证书错误 = 已生效
          - Chrome：本来就不信任该根，出现证书错误属正常
          - 能正常打开页面且没有警告 = 仍受信，需要检查是否选对了中间证书

第 5 步：回滚（如有问题）
        powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1 -Rollback

【参数说明】

  -Apply              执行阻断（不加则只扫描预览）
  -WeakOnly           只阻断 RSA 公钥长度 < -MinRsaBits 的中间证书
  -MinRsaBits N       阈值，Windows 10 默认 2048
  -Thumbprints a,b    按 SHA-1 指纹阻断（逗号分隔）
  -CertFile x.cer     按证书文件阻断
  -AllFromRoot        阻断该根签发的全部中间证书（激进，可能误伤）
  -Rollback           按上次备份清单撤销阻断
  -WorkDir 路径       备份与清单目录，默认 %ProgramData%\emsign-g3-block

【备份与恢复】

  - 每张被阻断的证书都会导出为 .cer 保存到：
      %ProgramData%\emsign-g3-block\<指纹>.cer
  - 阻断清单：%ProgramData%\emsign-g3-block\blocked.csv
  - 恢复：直接运行 -Rollback，或手动从上述目录导入证书后
    certutil -delstore Disallowed <指纹>

【风险与注意】

  - 阻断某张中间证书后，仍依赖该中间证书的站点会出现证书错误，
    这是预期行为
  - -AllFromRoot 会阻断该根签发的所有中间证书，可能影响大量正常站点，
    不建议在未验证的情况下使用
  - 本脚本只修改“本机”证书存储；域环境可用组策略统一推送
    （计算机配置 -> Windows 设置 -> 安全设置 -> 公钥策略 -> 不信任的证书）
  - 浏览器可能有独立根库：Firefox 使用 NSS，需单独确认
  - 若扫描结果为空：说明本机尚未缓存该根签发的中间证书。
    此时需要从 CA 或安全公告取得具体的中间证书文件，再用 -CertFile 处理

【免责声明】

  本脚本与其说明仅针对上述场景，验证结果只保证在“Windows 10 + 所列浏览器
  与补丁级别”的有限测试条件下成立。不同系统版本、补丁级别、浏览器内核版本
  可能得到不同结果；本资料不构成对其它环境或后续版本的保证。
  在生产环境批量部署前，请先在测试机验证并做好备份。
