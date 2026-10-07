#!/usr/bin/env bash
# 在你的 VPS 上把它变成 DSH 的 Tailscale peer relay。
#
# 用法：
#   sudo RELAY_HOSTNAME=my-relay RELAY_PUBLIC_IP=1.2.3.4 ./relay-setup.sh
#
# 之后还需要在 Tailscale 后台的 Access controls 里加一条 grant，见文件末尾。
set -euo pipefail

RELAY_HOSTNAME="${RELAY_HOSTNAME:-relay}"
RELAY_PUBLIC_IP="${RELAY_PUBLIC_IP:-}"
RELAY_PORT="${RELAY_PORT:-443}"

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行（sudo $0）" >&2
  exit 1
fi

if [[ -z "$RELAY_PUBLIC_IP" ]]; then
  echo "必须指定 RELAY_PUBLIC_IP（VPS 的公网 IP）" >&2
  echo "  sudo RELAY_PUBLIC_IP=1.2.3.4 $0" >&2
  exit 1
fi

echo "==> 1/4 安装 Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "    已安装：$(tailscale version | head -1)"
fi

echo "==> 2/4 加入 tailnet（--accept-dns=false 避免改这台机器的 DNS）"
tailscale up --hostname="$RELAY_HOSTNAME" --accept-dns=false || true

echo "==> 3/4 开启 peer relay"
# 关键：
#   1) 端口用 443 —— 非标准 UDP 端口会被运营商干扰（实测 40000 有 30% 丢包）
#   2) 必须显式声明公网端点 —— 云服务器多是 1:1 NAT，网卡上只有内网 IP，
#      Tailscale 自己探测不到公网地址
tailscale set \
  --relay-server-port="$RELAY_PORT" \
  --relay-server-static-endpoints="${RELAY_PUBLIC_IP}:${RELAY_PORT}"

echo "==> 4/4 状态"
tailscale status --json 2>/dev/null \
  | grep -o '"DNSName":"[^"]*"' | head -1 || true
echo
echo "当前设置："
tailscale debug prefs 2>/dev/null | grep -i relay || true

cat <<EOF

────────────────────────────────────────────────────────────
接下来去 Tailscale 后台：Access controls

加一条 grant（src 不接受主机名，只能用 Tailscale IP / CIDR / tag）：

  {
    "grants": [
      // ... 你原有的规则 ...
      {
        "src": ["<要使用中继的设备的 Tailscale IP>", "<中继自己的 Tailscale IP>"],
        "dst": ["<中继自己的 Tailscale IP>"],
        "app": {"tailscale.com/cap/relay": []}
      }
    ]
  }

改之前先把原文件备份出来。改完点 Preview changes，应该是纯新增、零删除。

验证（在任意一台要使用中继的机器上）：

  tailscale debug peer-relay-servers    # 应该列出中继的 Tailscale IP，而不是 []
  tailscale ping -c 20 <另一台设备>      # 应该出现 via peer-relay(...)

别忘了云厂商安全组要放行 UDP ${RELAY_PORT}。
────────────────────────────────────────────────────────────
EOF

echo
echo "完成。若 UDP ${RELAY_PORT} 仍不通，检查："
echo "  - 云安全组 / 防火墙是否放行 UDP ${RELAY_PORT}"
echo "  - tailscale netcheck 是否显示该端口可达"
