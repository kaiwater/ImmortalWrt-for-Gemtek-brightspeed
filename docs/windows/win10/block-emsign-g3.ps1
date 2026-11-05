<#
.SYNOPSIS
    在 Windows 10 上阻断 emSign ECC Root CA - G3 签发的问题中间证书，根证书保持受信。

.DESCRIPTION
    微软信任根计划目前仍把 eMudhra 的根证书列为受信（Included）。如果只想阻止
    “通过问题中间证书建立的证书链”，可以在本机把对应中间证书加入「不信任」存储
    （Disallowed），效果是：

      - 根证书继续受信，其它正常中间证书不受影响
      - 命中黑名单的中间证书不能再参与证书链构建

    注意：证书的“吊销（revoke）”只能由 CA 执行，本脚本做的是**本机不信任**，
    不是吊销。Windows 10 已于 2025-10-14 结束支持（消费者 ESU 到 2026-10-13），
    收不到微软后续的 CTL/根证书更新，因此需要手动处理。

    浏览器差异：
      - Chrome（105+）使用 Chrome Root Store，本来就不包含该根，天然不受影响
      - Edge、IE、360、猎豹、搜狗等使用 Windows 系统根库，受本脚本影响

.PARAMETER Apply
    执行阻断。不加此参数时只扫描并列出候选证书。

.PARAMETER WeakOnly
    只阻断 RSA 公钥长度小于 -MinRsaBits 的中间证书（启发式，默认 1024）。

.PARAMETER Thumbprints
    指定要阻断的证书指纹（SHA-1），多个用逗号分隔。

.PARAMETER CertFile
    指定证书文件（.cer/.crt），用于阻断本机尚未缓存的问题中间证书。

.PARAMETER AllFromRoot
    阻断该根签发的所有中间证书（激进，可能影响正常站点）。

.PARAMETER Rollback
    按上次的备份清单撤销阻断。

.PARAMETER MinRsaBits
    -WeakOnly 使用的 RSA 位数阈值，Windows 10 默认 2048。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1
    只扫描，列出本机缓存中由该根签发的中间证书。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1 -Apply -WeakOnly
    阻断公钥长度异常小的中间证书。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1 -Apply -Thumbprints 0123...,4567...
    按指纹精确阻断。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1 -Rollback
    撤销本脚本此前做的阻断。
#>

param(
    [switch]$Apply,
    [switch]$WeakOnly,
    [string]$Thumbprints = "",
    [string]$CertFile = "",
    [switch]$AllFromRoot,
    [switch]$Rollback,
    [int]$MinRsaBits = 2048,
    [string]$WorkDir = "$env:ProgramData\emsign-g3-block"
)

$ErrorActionPreference = "Stop"
$RootName = "emSign ECC Root CA - G3"

function Test-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Open-CertStore([string]$Name, [string]$Location, [string]$Mode) {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($Name, $Location)
    $store.Open($Mode)
    return $store
}

function Get-KeyInfo($cert) {
    $alg = $cert.PublicKey.Oid.FriendlyName
    $bits = 0
    try { $bits = $cert.PublicKey.Key.KeySize } catch { $bits = 0 }
    return ("{0} / {1} bit" -f $alg, $bits)
}

function Get-IntermediateCandidates {
    $result = @()
    foreach ($loc in @("LocalMachine", "CurrentUser")) {
        $store = Open-CertStore "CA" $loc "ReadOnly"
        try {
            foreach ($c in $store.Certificates) {
                if ($c.Issuer -match [regex]::Escape($RootName)) { $result += $c }
            }
        } finally { $store.Close() }
    }
    $seen = @{}
    $unique = @()
    foreach ($c in $result) {
        if (-not $seen.ContainsKey($c.Thumbprint)) {
            $seen[$c.Thumbprint] = $true
            $unique += $c
        }
    }
    return $unique
}

function Show-RootStatus {
    $found = $false
    foreach ($loc in @("LocalMachine", "CurrentUser")) {
        $store = Open-CertStore "Root" $loc "ReadOnly"
        try {
            foreach ($c in $store.Certificates) {
                if ($c.Subject -match [regex]::Escape($RootName)) {
                    $found = $true
                    Write-Host ("  [{0}] {1}" -f $loc, $c.Subject)
                    Write-Host ("        指纹: {0}" -f $c.Thumbprint)
                }
            }
        } finally { $store.Close() }
    }
    if (-not $found) {
        Write-Host "  未在受信任根存储中找到该根证书（可能已被移除或从未安装）。"
    }
}

function Block-Cert($cert) {
    $store = Open-CertStore "Disallowed" "LocalMachine" "ReadWrite"
    try { $store.Add($cert) } finally { $store.Close() }
}

function Unblock-Cert($cert) {
    $store = Open-CertStore "Disallowed" "LocalMachine" "ReadWrite"
    try { $store.Remove($cert) } finally { $store.Close() }
}

function Find-Disallowed([string]$thumbprint) {
    $store = Open-CertStore "Disallowed" "LocalMachine" "ReadOnly"
    try {
        foreach ($c in $store.Certificates) {
            if ($c.Thumbprint -eq $thumbprint) { return $c }
        }
    } finally { $store.Close() }
    return $null
}

# ---------------------------------------------------------------------------

if (-not (Test-Admin)) {
    Write-Host "请以管理员身份运行（右键 PowerShell 或 run.cmd -> 以管理员身份运行）。" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }
$manifest = Join-Path $WorkDir "blocked.csv"

Write-Host "==== emSign ECC Root CA - G3 中间证书处理（Windows 10） ===="
Write-Host ""

if ($Rollback) {
    if (-not (Test-Path $manifest)) {
        Write-Host "没有找到备份清单：$manifest" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "== 回滚 =="
    $count = 0
    foreach ($line in (Get-Content $manifest)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $thumb = ($line -split ",")[0]
        $cert = Find-Disallowed $thumb
        if ($cert -ne $null) {
            Unblock-Cert $cert
            Write-Host ("  已恢复信任: {0}" -f $thumb)
            $count++
        } else {
            Write-Host ("  未在不信任存储中: {0}" -f $thumb)
        }
    }
    Remove-Item $manifest -Force
    Write-Host ""
    Write-Host ("回滚完成，共撤销 {0} 张证书。" -f $count)
    exit 0
}

Write-Host "== 1. 根证书状态（不会被修改） =="
Show-RootStatus
Write-Host ""

Write-Host "== 2. 本机缓存中由该根签发的中间证书 =="
$candidates = Get-IntermediateCandidates
if ($candidates.Count -eq 0) {
    Write-Host "  未找到。若已知具体证书，可用 -Thumbprints 或 -CertFile 指定。"
} else {
    $i = 0
    foreach ($c in $candidates) {
        $i++
        Write-Host ("  [{0}] {1}" -f $i, $c.Subject)
        Write-Host ("      指纹 : {0}" -f $c.Thumbprint)
        Write-Host ("      密钥 : {0}" -f (Get-KeyInfo $c))
        Write-Host ("      有效期: {0} ~ {1}" -f $c.NotBefore, $c.NotAfter)
    }
}
Write-Host ""

$selected = @()
if ($Thumbprints -ne "") {
    $wanted = $Thumbprints -split "," | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ -ne "" }
    foreach ($c in $candidates) {
        if ($wanted -contains $c.Thumbprint.ToUpper()) { $selected += $c }
    }
    if ($CertFile -ne "") {
        Write-Host "同时指定了 -CertFile，将在下方一并处理。"
    }
} elseif ($CertFile -ne "") {
    $fileCerts = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $fileCerts.Import($CertFile)
    foreach ($c in $fileCerts) { $selected += $c }
} elseif ($AllFromRoot) {
    $selected = $candidates
} elseif ($WeakOnly) {
    foreach ($c in $candidates) {
        try { $bits = $c.PublicKey.Key.KeySize } catch { $bits = 0 }
        if ($bits -gt 0 -and $bits -lt $MinRsaBits) { $selected += $c }
    }
}

if (-not $Apply) {
    if ($selected.Count -gt 0) {
        Write-Host ("== 将阻断 {0} 张证书（预览，未执行） ==" -f $selected.Count)
        foreach ($c in $selected) { Write-Host ("  " + $c.Thumbprint + "  " + $c.Subject) }
        Write-Host ""
        Write-Host "确认无误后加 -Apply 执行。"
    } else {
        Write-Host "没有选中任何证书。可选参数：-Apply -WeakOnly / -Thumbprints / -CertFile / -AllFromRoot"
    }
    exit 0
}

if ($selected.Count -eq 0) {
    Write-Host "没有选中任何证书，未做修改。" -ForegroundColor Yellow
    exit 0
}

Write-Host ("== 3. 执行阻断（{0} 张） ==" -f $selected.Count)
foreach ($c in $selected) {
    $backup = Join-Path $WorkDir ($c.Thumbprint + ".cer")
    [System.IO.File]::WriteAllBytes($backup, $c.RawData)

    $already = Find-Disallowed $c.Thumbprint
    if ($already -eq $null) {
        Block-Cert $c
        $subject = $c.Subject -replace ",", ";"
        Add-Content $manifest ("{0},{1},{2}" -f $c.Thumbprint, $subject, (Get-Date -Format "s"))
        Write-Host ("  已加入不信任: {0}  {1}" -f $c.Thumbprint, $c.Subject)
    } else {
        Write-Host ("  已存在于不信任存储: {0}" -f $c.Thumbprint)
    }
}

Write-Host ""
Write-Host "完成。备份与清单：$WorkDir"
Write-Host "回滚命令：powershell -ExecutionPolicy Bypass -File .\block-emsign-g3.ps1 -Rollback"
Write-Host ""
Write-Host "提示：根证书未被修改，仍处于受信状态；只有被阻断的中间证书不再可用。"
