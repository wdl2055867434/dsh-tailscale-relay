# dsh-tailscale-relay

**用手机随时随地访问家里电脑上的 DeepSeek Harness（DSH）** —— 不需要公网 IP、不需要路由器端口映射、不受 CGNAT / 运营商 NAT 影响。

在家走局域网直连（1ms），出门走**自建香港中继**（约 60ms），不依赖 Tailscale 的公共 DERP 节点。

```
手机 ──┐
       ├── Tailscale (WireGuard) ──►  PC 上的 DSH (127.0.0.1:19387)
PC  ──┘             │
                    └── 打不通直连时，改走自建 peer relay（VPS:UDP 443）
```

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [为什么值得自己搭](#为什么值得自己搭)
- [快速开始](#快速开始)
  - [第 0 步：前置](#第-0-步前置)
  - [第 1 步：让 DSH 接受 tailnet 主机名](#第-1-步让-dsh-接受-tailnet-主机名)
  - [第 2 步：用 tailscale serve 暴露 DSH](#第-2-步用-tailscale-serve-暴露-dsh)
  - [第 3 步：给手机造一个长期有效的登录 cookie](#第-3-步给手机造一个长期有效的登录-cookie)
  - [第 4 步（可选）：出门也要快 —— 自建 peer relay](#第-4-步可选出门也要快--自建-peer-relay)
  - [第 5 步（可选）：小内存 VPS 加固](#第-5-步可选小内存-vps-加固)
- [三个反直觉的坑](#三个反直觉的坑)
- [排查速查表](#排查速查表)
- [安全说明](#安全说明)
- [License](#license)

---

## 它解决什么问题

DSH 的 Web 界面默认只监听 `127.0.0.1`，这是对的 —— 但它意味着**你人不在电脑前就用不了**。

常见的替代方案都有硬伤：

| 方案 | 问题 |
|---|---|
| 端口映射 / 公网 IP | 家里大多是 CGNAT，根本没有公网 IP；即使有，把 DSH 暴露到公网风险太高 |
| Cloudflare Tunnel / frp | 需要域名、需要第三方中转，延迟和稳定性不可控 |
| Tailscale 直连 | 可用，但**手机侧常年打不通直连**（运营商对称 NAT），会一直退回公共 DERP，延迟 400–600ms 且丢包 |
| 在 VPS 上做反向代理 | 流量绕一大圈，且 DSH 的 Host 栅栏会把请求拒掉 |

本方案 = **Tailscale 组网 + tailscale serve + 自建 peer relay**，三件事各解决一个问题：

1. **Tailscale** 解决「怎么找到对方的机器」，不用公网 IP
2. **`tailscale serve`** 解决「怎么安全地暴露 HTTPS」，证书自动签发，不占公网端口
3. **自建 peer relay** 解决「两边都连不上直连怎么办」—— 双方各自主动连到公网固定端点，绕开对称 NAT

---

## 为什么值得自己搭

Tailscale 官方的 peer relay 文档只讲了怎么做中继，但**几乎所有教程都漏掉了这条**：

> **中继端口必须用 443。**

实测数据（同一台机器、同一个中继，只改端口）：

| 中继端口 | 结果 |
|---|---|
| UDP **40000** | 20 次里 6 次超时（**30% 丢包**），成功的那 14 次也退回公共 DERP，469–3035ms |
| UDP **443** | **20/20 全部走 peer relay**，59–164ms，0 超时 |

原因是运营商对非标准 UDP 端口会做 QoS / 干扰，而 UDP 443 和 HTTPS/QUIC 混在一起，很难被区别对待。

另外还有几个只有自己踩过才知道的坑，都写在下面的[三个反直觉的坑](#三个反直觉的坑)。

---

## 快速开始

> 约定：下文用 `<HOST>` 表示你电脑在 tailnet 里的主机名（如 `my-desktop`），
> `<TAILNET>` 表示你的 tailnet 名（如 `example.ts.net`），
> `<RELAY_PUBLIC_IP>` 表示你 VPS 的公网 IP。
> **替换成你自己的值再用。**

### 第 0 步：前置

1. 电脑和手机都装好 Tailscale 并登录**同一个 tailnet**
2. 电脑上 DSH 正常运行，记录它监听的端口（默认 `19387`）：

```powershell
Get-NetTCPConnection -State Listen -LocalPort 19387 |
  ForEach-Object { Get-Process -Id $_.OwningProcess }
```

3. 确认 MagicDNS 开启，电脑的 tailnet 域名能解析：

```powershell
& "$env:ProgramFiles\Tailscale\tailscale.exe" status --json |
  ConvertFrom-Json | Select-Object -ExpandProperty Self |
  Select-Object -ExpandProperty DNSName
# 应输出 <HOST>.<TAILNET>.
```

### 第 1 步：让 DSH 接受 tailnet 主机名

DSH 有一个 **Host 栅栏**：只接受来自回环地址的请求，其它 Host 一律 **403**。
必须显式把你的 tailnet 主机名加进白名单。

编辑 `%USERPROFILE%\.dsh\profiles\<你的 profile>\cordis.patch.yml`（profile 通常是 `desktop`），**追加**：

```yaml
- id: web-runtime
  name: "@deepseek-ai/dsh-web-app"
  inject: [webStartup]
  config:
    openBrowser: false
    printUrl: true
    surfaceContext: true
    trustedHosts:
      - <HOST>.<TAILNET>
```

> **DSH 会热重载这个文件**，改完不用重启。

> ⚠️ **两个坑**
> 1. 这个文件里可能有中文注释，**必须用 UTF-8 无 BOM 写回**。PowerShell 5.1 的
>    `Set-Content -Encoding utf8NoBOM` 会报枚举错误（那是 PS7 才有的），
>    `Get-Content` 默认还会按 ANSI 读，把中文读成乱码。用 .NET：
>    ```powershell
>    $p = "$env:USERPROFILE\.dsh\profiles\desktop\cordis.patch.yml"
>    $enc = New-Object System.Text.UTF8Encoding($false)
>    $text = [System.IO.File]::ReadAllText($p, $enc)
>    [System.IO.File]::WriteAllText($p, $text, $enc)
>    ```
> 2. 如果这个 `- id: web-runtime` 条目**已经存在**，不要追加第二个，
>    直接改现有条目里的 `trustedHosts` 列表。

### 第 2 步：用 `tailscale serve` 暴露 DSH

```powershell
$ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
& $ts serve --bg --https=8443 http://127.0.0.1:19387
& $ts serve status
```

期望输出：

```
https://<HOST>.<TAILNET>:8443 (tailnet only)
|-- / proxy http://127.0.0.1:19387
```

`(tailnet only)` 表示**只有 tailnet 内的设备能访问**，不会暴露到公网。

**验证栅栏是否放行**（这是关键的一步）：

```powershell
curl.exe -sk -o NUL -w "%{http_code}`n" https://<HOST>.<TAILNET>:8443/
```

> **必须返回 `401`。**
> - `401` = 栅栏通过，只是没登录 ✅
> - `403` = Host 被拒，**第 1 步没生效** ❌

### 第 3 步：给手机造一个长期有效的登录 cookie

DSH 的登录机制是「进程 token 换 cookie」，而那个 token **每次启动随机、且只在回环可达** ——
所以你没法在手机上登录。正确做法是**用 DSH 自己的持久 secret 直接签一个 cookie**。

**secret 位置**：`%USERPROFILE%\.dsh\.credentials.yaml`

```yaml
version: 1
records:
  client-connection/browser-session:
    kind: grant
    payload:
      version: 1
      secret: <43 字符 base64url，解码后 32 字节>
```

**签名算法**（与 DSH 内部的 `browser-auth` 一致）：

```
authority = "<HOST>.<TAILNET>:8443"      # 必须带端口、全小写
name      = "dsh-auth-" + base64url( sha256(authority) )
body      = base64url( JSON({"version":1,"authority":authority,
                             "issuedAt":<ms>,"expiresAt":<ms>}) )
value     = "v1." + body + "." + base64url( hmac_sha256(secret, body) )
```

- `base64url`：标准 base64 去掉末尾 `=`，`+`→`-`，`/`→`_`
- **HMAC 的输入是 `body` 这个字符串的 UTF-8 字节**，不是原始 JSON
- `issuedAt` / `expiresAt` 是**毫秒**时间戳

仓库里的 [`scripts/mint-cookie.ps1`](scripts/mint-cookie.ps1) 已经实现了这个算法：

```powershell
# 生成 cookie
& .\scripts\mint-cookie.ps1 -Authority "<HOST>.<TAILNET>:8443" -Days 30

# 立刻自测（必须 200）
curl.exe -sk -o NUL -w "%{http_code}`n" `
  -H "Host: <HOST>.<TAILNET>:8443" `
  -H "Cookie: <name>=<value>" `
  http://127.0.0.1:19387/
```

> **这一步不通过就别往下做。** 401 说明 authority 或 secret 不对，
> 换几个 authority 变体试试（不带端口、`127.0.0.1:19387`、tailnet IP 等）。

**然后把 cookie 送到手机上。** 最简单可靠的做法：起一个登录页，
让手机浏览器访问一次，由 JS 写入 cookie。

见 [`scripts/login-page.html`](scripts/login-page.html) —— 把里面的占位符替换掉，
用任意静态服务器托管在 `127.0.0.1:8799`，再：

```powershell
& $ts serve --bg --https=8444 http://127.0.0.1:8799
```

> 💡 **登录页里的 cookie 必须带 `domain=<TAILNET>`**，这样手机从 `:8444` 拿到的 cookie
> 才会被带到 `:8443`。（同一个登录页也因此可以顺便给 tailnet 里**其它**机器用。）

> ⚠️ 起静态服务器时在 Windows 上**不要用 `System.Net.HttpListener`** ——
> 非管理员会被 http.sys 的 URL ACL 拒绝。用 `TcpListener` 自己写，不需要管理员权限。

**手机上的使用方式：**

```
先开一次（写入 cookie）：https://<HOST>.<TAILNET>:8444/
以后直接用：            https://<HOST>.<TAILNET>:8443/
```

cookie 有效期按你生成时指定（建议 30 天），到期后**再开一次登录页**即可。

### 第 4 步（可选）：出门也要快 —— 自建 peer relay

如果你只在家里用，**可以跳过这一步**。但手机在移动网络下通常**打不通直连**，
会一直退回公共 DERP（400–600ms）。

准备一台有公网 IP 的 VPS（1 核 1G 足够，香港/新加坡延迟更低）。

```bash
# 在 VPS 上
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --hostname=<RELAY_HOSTNAME> --accept-dns=false

# 关键：显式声明公网端点。云服务器大多是 1:1 NAT，网卡上只有内网 IP，
# Tailscale 自己探测不到公网地址。
tailscale set --relay-server-port=443 \
               --relay-server-static-endpoints=<RELAY_PUBLIC_IP>:443
```

然后在 Tailscale 后台的 **Access controls** 里加一条 grant：

```jsonc
{
  "grants": [
    // ... 你原有的规则 ...
    {
      // ⚠️ src 不接受主机名！只能用 Tailscale IP / CIDR / tag
      "src": ["<TAILSCALE_IP_1>", "<TAILSCALE_IP_2>", "<RELAY_TAILSCALE_IP>"],
      "dst": ["<RELAY_TAILSCALE_IP>"],
      "app": {"tailscale.com/cap/relay": []}
    }
  ]
}
```

> 改之前**先把原文件备份出来**。Tailscale 后台的编辑器支持 `Preview changes`，
> 改动应该是**纯新增、零删除**。

验证：

```powershell
# 应该列出你的中继 Tailscale IP，而不是 []
& $ts debug peer-relay-servers

# 应该看到 via peer-relay(...)
& $ts ping -c 20 <手机或另一台的 Tailscale IP>
```

完整脚本见 [`scripts/relay-setup.sh`](scripts/relay-setup.sh)。

### 第 5 步（可选）：小内存 VPS 加固

**1 核 1G 的机器跑 relay 够用，但会被 Ubuntu 的自动更新打爆。**
典型症状：延迟突然涨到秒级、丢包、中继整个消失退回 DERP、
**SSH 能建 TCP 连接但握手超时**（网络栈应答 SYN，用户态进程饿死）。

排查：

```bash
free -m            # 看有没有 swap
uptime             # 看 load average
dmesg | grep -i oom
```

如果看到 `Out of memory: Killed process ... (unattended-upgr)`，`scripts/vps-harden.sh` 一条命令搞定：

- 建 2G swapfile 并写进 `/etc/fstab`
- `vm.swappiness=10`
- 关掉 `unattended-upgrades` / `apt-daily.timer` / `fwupd` / `snapd` / `multipathd`

实测效果：内存占用 380MB → 213MB，负载 37.9 → 1.73，链路恢复到 30/30 中继、0 超时。

> ⚠️ 如果你也在 VPS 上装了 Tailscale，注意它默认会插入一条规则：
> `-A ts-input -s 100.64.0.0/10 ! -i tailscale0 -j DROP`
> 这会**误伤云厂商的内部服务网段**（很多云用 `100.100.0.0/16` 做元数据和内网 DNS），
> 导致「云助手」「文件备份」之类的服务报「实例网络环境异常」。
> 修法是在它**之前**插一条放行（Tailscale 只用 `-A` 追加，所以 `-I` 插队有效）：
> ```bash
> iptables -I INPUT 1 -s 100.100.0.0/16 -j ACCEPT
> ```
> 并写一个开机自愈的 systemd oneshot 单元持久化。

---

## 三个反直觉的坑

### 1. `tailscale serve` 保留原始 Host，DSH 会 403

`tailscale serve` **不会**把 Host 改写成 `127.0.0.1`，而是原样转发
`<HOST>.<TAILNET>:8443`，并附带 `X-Forwarded-Proto: https`。

而 DSH 的 Host 栅栏只认回环 —— 所以**必须**配 `trustedHosts`（第 1 步）。

**记住这个判定口诀：**

| 返回码 | 含义 |
|---|---|
| **403** | Host 被栅栏拒了 → `trustedHosts` 没生效 |
| **401** | 栅栏通过，只是没认证 → 配置正确，去搞 cookie |

这条口诀能帮你在一秒内区分「配置问题」和「认证问题」，排查时极其省事。

### 2. ACL 的 `src` 不接受主机名

Tailscale 的 peer relay 文档说 `dst` 可以用主机名、tag、IP，但**没说 `src` 不行**。
实际写 `"src": ["my-desktop"]` 会得到：

```
Error: src="my-desktop": invalid address
```

`src` 只接受用户 / 组 / `autogroup` / tag / **IP 或 CIDR**。
所以老老实实用 Tailscale IP。

### 3. 中继端口必须用 443

见上文[为什么值得自己搭](#为什么值得自己搭)。
一句话：**非标准 UDP 端口会被运营商干扰，30% 丢包；换成 UDP 443 后 0 丢包。**

---

## 排查速查表

| 症状 | 大概率原因 | 怎么查 |
|---|---|---|
| 浏览器打不开，`ERR_CONNECTION_TIMED_OUT` | 设备不在线 / 不在同一 tailnet | `tailscale status` |
| **403** | `trustedHosts` 没配或没生效 | 检查 `cordis.patch.yml`；DSH 会热重载，但新条目有时要重启 |
| **401** | 正常，只是没 cookie | 走第 3 步 |
| 带 cookie 仍 **401** | authority 字符串不对 / secret 不对 | 见第 3 步，换 authority 变体；确认 `.credentials.yaml` 里只有一个文件 |
| `tailscale debug peer-relay-servers` 返回 `[]` | ACL grant 没配 / 没生效 | 检查 grant 的 `src`/`dst`/`app` |
| ping 一直 `via DERP(...)` 几百毫秒 | 中继没生效，或用了非 443 端口 | 换 443；检查安全组放行 UDP 443 |
| 延迟突然变秒级 + 丢包 + SSH 握手超时 | VPS 内存打爆 | 第 5 步 |
| 手机「文字发得出去、图片传不完」 | 链路丢包，上传是 100KB–3MB 的整块 POST | 换 443 修链路；大图比文字对丢包敏感得多 |

---

## 安全说明

- **DSH 始终只监听 `127.0.0.1`**。本方案没有把它暴露到公网。
- `tailscale serve` 用的是 `(tailnet only)`，只有你 tailnet 内的设备能访问。
- 登录 cookie 是 HMAC 签名的，**它的安全性完全取决于 `.credentials.yaml` 里的 secret**
  —— 不要把这个文件提交到任何仓库。
- cookie 建议设 30 天，并**用 `domain=<TAILNET>` 限制作用域**（不要用 `domain=` 留空）。
- 如果担心手机丢失：Tailscale 后台可以随时移除该设备，cookie 也就一起失效了。
- `.gitignore` 里已包含 `.credentials.yaml`、`*.key`、`id_*` 等。

---

## License

MIT
