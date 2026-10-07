#!/usr/bin/env pwsh
<#
.SYNOPSIS
    为指定的 authority 生成一个 DSH 浏览器会话 cookie。

.DESCRIPTION
    DSH 的登录流程是「进程内 token 换 cookie」，而那个 token 每次启动随机、
    且只在回环地址可达 —— 所以没法在手机上正常登录。

    正确做法是用 DSH 自己的持久 secret（%USERPROFILE%\.dsh\.credentials.yaml
    里 records."client-connection/browser-session".payload.secret）直接签一个 cookie。

    算法（与 DSH 内部的 browser-auth 一致）：
        authority = "<host>:<port>"                     # 必须带端口、全小写
        name      = "dsh-auth-" + b64url(sha256(authority))
        body      = b64url(JSON({version,authority,issuedAt,expiresAt}))
        value     = "v1." + body + "." + b64url(hmac_sha256(secret, body))

    注意：HMAC 的输入是 body 这个 **字符串** 的 UTF-8 字节，不是原始 JSON。

.PARAMETER Authority
    形如 "my-host.example.ts.net:8443"（必须带端口）。

.PARAMETER Secret
    base64url 编码的 32 字节 secret。不给的话从 .credentials.yaml 读。

.PARAMETER CredentialsFile
    默认 $env:USERPROFILE\.dsh\.credentials.yaml

.PARAMETER Days
    cookie 有效期天数，默认 30。

.PARAMETER Target
    生成后要做本机自测的 URL，默认 http://127.0.0.1:19387/

.PARAMETER NoVerify
    跳过本机自测。

.EXAMPLE
    # 生成 + 自测
    .\mint-cookie.ps1 -Authority "my-host.example.ts.net:8443"

.EXAMPLE
    # 只看自测结果
    .\mint-cookie.ps1 -Authority "my-host.example.ts.net:8443" |
        Select-Object Authority, ExpiresAt, SelfTest

.NOTES
    必须在同一进程内调用（`& .\mint-cookie.ps1 ...`）才能拿到返回对象的属性；
    用 `pwsh -File` 抓回的是格式化文本。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Authority,
    [string] $Secret,
    [string] $CredentialsFile = "$env:USERPROFILE\.dsh\.credentials.yaml",
    [int]    $Days = 30,
    [string] $Target = 'http://127.0.0.1:19387/',
    [switch] $NoVerify
)

$ErrorActionPreference = 'Stop'

function ConvertTo-Base64Url([byte[]] $Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-SecretFromCredentials([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "找不到凭据文件：$Path"
    }
    $lines = [System.IO.File]::ReadAllLines($Path, (New-Object System.Text.UTF8Encoding($false)))
    $inSection = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*client-connection/browser-session:\s*$') { $inSection = $true; continue }
        if ($inSection -and $line -match '^\s{0,4}\S') { break }   # 缩进回退 = 离开了这一段
        if ($inSection -and $line -match '^\s+secret:\s*(\S+)\s*$') { return $Matches[1] }
    }
    throw "在 $Path 里没找到 client-connection/browser-session.payload.secret"
}

# ---------------------------------------------------------------------------

if (-not $Secret) { $Secret = Get-SecretFromCredentials $CredentialsFile }

$secretBytes = $null
try { $secretBytes = [Convert]::FromBase64String($Secret.Replace('-', '+').Replace('_', '/')) } catch {
    throw "secret 不是合法的 base64url：$Secret"
}
if ($secretBytes.Length -ne 32) {
    Write-Warning "secret 解码后是 $($secretBytes.Length) 字节，预期 32 字节 —— 可能不对，但仍会继续。"
}

$authority = $Authority.ToLowerInvariant()
if ($authority -notmatch ':\d+$') {
    Write-Warning "authority 没有带端口。DSH 的 authority 通常是 <host>:<port>，缺端口很可能签出无效 cookie。"
}

$sha   = [System.Security.Cryptography.SHA256]::Create()
$name  = 'dsh-auth-' + (ConvertTo-Base64Url $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($authority)))

$issuedAt  = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$expiresAt = $issuedAt + ([long]$Days * 86400000)

$payload = @{
    version   = 1
    authority = $authority
    issuedAt  = $issuedAt
    expiresAt = $expiresAt
} | ConvertTo-Json -Compress

# ConvertTo-Json 会把时间戳输出成数字，但保险起见用正则归一化：
$payload = [regex]::Replace($payload, '"(issuedAt|expiresAt)":"?(\d+)"?', '"$1":$2')

$body = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payload))

$hmac    = New-Object System.Security.Cryptography.HMACSHA256
$hmac.Key = $secretBytes
$sig     = ConvertTo-Base64Url ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($body)))

$value = "v1.$body.$sig"

# ---------------------------------------------------------------------------

$selfTest = 'skipped'
if (-not $NoVerify) {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        $selfTest = 'curl.exe 不可用，跳过'
    } else {
        $hostPart = ($authority -split ':')[0]
        $url = "$Target"
        $code = (& curl.exe -sk -o NUL -w "%{http_code}" --max-time 20 `
                    -H "Host: $authority" `
                    -H "Cookie: $name=$value" `
                    $url) 2>$null
        $selfTest = switch ($code) {
            '200' { '200 OK ✅' }
            '401' { '401 —— cookie 不对：authority 或 secret 有误' }
            '403' { '403 —— Host 被栅栏拒了，先配 trustedHosts' }
            default { "意外返回 $code" }
        }
        Write-Host "[自测] Host=$authority  Cookie=$name...  ->  $selfTest"
        if ($code -ne '200') {
            Write-Warning "自测没通过。可以换这些 authority 变体再试："
            @($hostPart, "$hostPart`:443", "127.0.0.1:19387", "localhost:19387") |
                ForEach-Object { Write-Warning "  - $_" }
        }
    }
}

[pscustomobject]@{
    Authority = $authority
    Name      = $name
    Value     = $value
    IssuedAt  = [DateTimeOffset]::FromUnixTimeMilliseconds($issuedAt).ToLocalTime()
    ExpiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds($expiresAt).ToLocalTime()
    Cookie    = "$name=$value"
    SelfTest  = $selfTest
}
