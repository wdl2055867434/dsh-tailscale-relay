#!/usr/bin/env pwsh
<#
.SYNOPSIS
    在 Windows 上把 DSH 通过 tailscale serve 暴露到 tailnet 里。

.DESCRIPTION
    做两件事：
      1. 往 DSH 的 profile patch 里加 trustedHosts（DSH 会热重载）
      2. tailscale serve --bg --https=<port> http://127.0.0.1:<dshPort>

    然后自测栅栏：必须返回 401（403 说明 trustedHosts 没生效）。

.PARAMETER HostName
    tailnet 主机名，如 my-desktop.example.ts.net

.PARAMETER DshPort
    DSH 监听端口，默认 19387

.PARAMETER ServePort
    serve 对外端口，默认 8443

.PARAMETER Profile
    DSH profile 名，默认 desktop

.PARAMETER SkipServe
    只改配置，不执行 serve

.EXAMPLE
    .\serve-setup.ps1 -HostName my-desktop.example.ts.net
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $HostName,
    [int] $DshPort = 19387,
    [int] $ServePort = 8443,
    [string] $Profile = 'desktop',
    [switch] $SkipServe
)

$ErrorActionPreference = 'Stop'

$ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
if (-not (Test-Path -LiteralPath $ts)) { throw "找不到 tailscale.exe：$ts" }

$patch = Join-Path $env:USERPROFILE ".dsh\profiles\$Profile\cordis.patch.yml"
if (-not (Test-Path -LiteralPath $patch)) { throw "找不到 profile patch：$patch" }

$enc = New-Object System.Text.UTF8Encoding($false)     # UTF-8 无 BOM，保住中文注释
$text = [System.IO.File]::ReadAllText($patch, $enc)

# ---------- 1. trustedHosts ----------

$entryBlock = @"
- id: web-runtime
  name: "@deepseek-ai/dsh-web-app"
  inject: [webStartup]
  config:
    openBrowser: false
    printUrl: true
    surfaceContext: true
    trustedHosts:
      - $HostName
"@

if ($text -match '(?m)^\s*-\s*id:\s*web-runtime\s*$') {
    Write-Host "[1/3] patch 里已有 web-runtime 条目"

    if ($text -match [regex]::Escape($HostName)) {
        Write-Host "      trustedHosts 里已经有 $HostName，跳过"
    } elseif ($text -match '(?m)^(\s*)trustedHosts:\s*$') {
        # 在现有 trustedHosts 列表末尾追加一行，缩进对齐
        $listIndent = $Matches[1] + '  '
        $text = [regex]::Replace(
            $text,
            '(?m)^(\s*)trustedHosts:\s*$',
            "`${0}`n$listIndent- $HostName",
            1)
        Write-Host "      已在现有 trustedHosts 列表里追加 $HostName"
    } else {
        # web-runtime 存在但没有 trustedHosts，补一段
        $text = [regex]::Replace(
            $text,
            '(?m)^(\s*)config:\s*$',
            "`${0}`n`${1}  trustedHosts:`n`${1}    - $HostName",
            1)
        Write-Host "      已补上 trustedHosts"
    }
} else {
    Write-Host "[1/3] patch 里没有 web-runtime，追加新条目"
    $text = $text.TrimEnd() + "`n`n" + $entryBlock + "`n"
}

Copy-Item -LiteralPath $patch -Destination "$patch.bak" -Force
[System.IO.File]::WriteAllText($patch, $text, $enc)
Write-Host "      已写入（备份：$patch.bak）"

# ---------- 2. tailscale serve ----------

if (-not $SkipServe) {
    Write-Host "[2/3] 配置 tailscale serve"
    & $ts serve --bg "--https=$ServePort" "http://127.0.0.1:$DshPort"
    Write-Host
    & $ts serve status
} else {
    Write-Host "[2/3] 跳过 serve（-SkipServe）"
}

# ---------- 3. 自测 ----------

Write-Host "[3/3] 自测栅栏"
Start-Sleep -Seconds 2
$code = & curl.exe -sk -o NUL -w "%{http_code}" --max-time 20 "https://${HostName}:${ServePort}/" 2>$null
switch ($code) {
    '401' { Write-Host "  -> 401 ✅ 栅栏已通过，接着去生成登录 cookie（scripts/mint-cookie.ps1）" }
    '403' { Write-Warning "  -> 403 ❌ trustedHosts 没生效。DSH 通常热重载，但新条目有时要重启 DSH。" }
    '200' { Write-Host "  -> 200（已经带着会话 cookie？浏览器里试试）" }
    default { Write-Warning "  -> 意外返回 $code；确认设备在线、serve 已启动。" }
}
