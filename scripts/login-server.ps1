#!/usr/bin/env pwsh
<#
.SYNOPSIS
    一小段静态服务器，用来托管 DSH 的登录页。

.DESCRIPTION
    用 TcpListener 手写 HTTP，**故意不用 System.Net.HttpListener** ——
    后者在 Windows 上非管理员会被 http.sys 的 URL ACL 拒绝。

    只监听回环地址，外面靠 tailscale serve 转发进来：

        tailscale serve --bg --https=8444 http://127.0.0.1:8799

.PARAMETER Root
    托管目录，默认 $env:USERPROFILE\.dsh\remote-login

.PARAMETER Port
    监听端口，默认 8799

.PARAMETER Once
    只服务一个请求就退出（调试用）

.EXAMPLE
    .\login-server.ps1
#>
[CmdletBinding()]
param(
    [string] $Root = "$env:USERPROFILE\.dsh\remote-login",
    [int]    $Port = 8799,
    [switch] $Once
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Root)) {
    throw "托管目录不存在：$Root"
}

$index = Join-Path $Root 'index.html'
if (-not (Test-Path -LiteralPath $index)) {
    throw "找不到 $index —— 先把 login-page.html 改好、替换占位符，另存为 $index"
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "登录页服务已启动：http://127.0.0.1:$Port/  (root=$Root)"
Write-Host "按 Ctrl+C 停止。"

$contentTypeMap = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
    '.txt'  = 'text/plain; charset=utf-8'
}

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 5000
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)

            $requestLine = $reader.ReadLine()
            while (($line = $reader.ReadLine()) -ne $null -and $line -ne '') { }

            if (-not $requestLine -or $requestLine -notmatch '^(GET|HEAD)\s+(\S+)') {
                $client.Close(); continue
            }
            $method = $Matches[1]
            $rawPath = $Matches[2].Split('?')[0]
            if ($rawPath -eq '/' -or $rawPath -eq '') { $rawPath = '/index.html' }

            $rel = [Uri]::UnescapeDataString($rawPath).TrimStart('/')
            $full = [System.IO.Path]::GetFullPath((Join-Path $Root $rel))
            $rootFull = [System.IO.Path]::GetFullPath($Root)

            # 目录穿越防护
            if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
                $body = [Text.Encoding]::UTF8.GetBytes('403 forbidden')
                $header = "HTTP/1.1 403 Forbidden`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
                $stream.Write([Text.Encoding]::ASCII.GetBytes($header)); $stream.Write($body)
                $client.Close(); continue
            }

            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $body = [System.IO.File]::ReadAllBytes($full)
                $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
                $ct = if ($contentTypeMap.ContainsKey($ext)) { $contentTypeMap[$ext] } else { 'application/octet-stream' }
                $status = 'HTTP/1.1 200 OK'
            } else {
                $body = [Text.Encoding]::UTF8.GetBytes("404 not found: $rel")
                $ct = 'text/plain; charset=utf-8'
                $status = 'HTTP/1.1 404 Not Found'
            }

            $header = "$status`r`nContent-Type: $ct`r`nContent-Length: $($body.Length)`r`n" +
                      "Cache-Control: no-store`r`nConnection: close`r`n`r`n"
            $stream.Write([Text.Encoding]::ASCII.GetBytes($header))
            if ($method -eq 'GET') { $stream.Write($body) }
            $stream.Flush()

            Write-Host "$(Get-Date -Format 'HH:mm:ss')  $method $rawPath  -> $($status.Split(' ')[1])"
        } catch {
            Write-Warning "请求处理失败：$($_.Exception.Message)"
        } finally {
            $client.Close()
        }

        if ($Once) { break }
    }
} finally {
    $listener.Stop()
    Write-Host "登录页服务已停止。"
}
