#!/usr/bin/env bash
# 加固小内存 VPS（1 核 1G 级别），防止被 Ubuntu 的自动更新打爆。
#
# 背景：1G 内存、0 swap 的机器，一次 unattended-upgrades 就可能 OOM。
#       症状是延迟突然涨到秒级、丢包、中继消失，
#       而且 SSH「能建立 TCP 连接但握手超时」—— 网络栈应答 SYN，用户态进程饿死。
#
# 用法：sudo ./vps-harden.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行（sudo $0）" >&2
  exit 1
fi

echo "=== 当前状况 ==="
free -m | head -2
uptime

if [[ -z "$(swapon --show)" ]]; then
  echo
  echo "==> 没有 swap，创建 2G swapfile"
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -q '^/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
else
  echo
  echo "==> 已有 swap，跳过"
  swapon --show
fi

echo
echo "==> 降低 swappiness（默认 60 太激进，小机器上来就换页）"
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
sysctl -q -p /etc/sysctl.d/99-swappiness.conf

echo
echo "==> 关掉会突然吃内存的服务"
# unattended-upgrades 是 OOM 的常见元凶
systemctl disable --now unattended-upgrades 2>/dev/null || true
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask unattended-upgrades 2>/dev/null || true
# 这一堆在中继机上都没用
for svc in fwupd fwupd-refresh.timer snapd snapd.socket multipathd; do
  systemctl disable --now "$svc" 2>/dev/null || true
done

echo
echo "=== 之后 ==="
free -m | head -2
uptime
echo
echo "完成。"
echo
echo "⚠️  如果你在这台机器上也装了 Tailscale，注意它默认会插入："
echo "      -A ts-input -s 100.64.0.0/10 ! -i tailscale0 -j DROP"
echo "    这会误伤云厂商的内部服务网段（很多云用 100.100.0.0/16 做元数据和内网 DNS），"
echo "    导致「云助手」「文件备份」等服务报「实例网络环境异常」。"
echo
echo "    检查：iptables -L INPUT -n --line-numbers | head"
echo "    修复（插在 ts-input 之前；Tailscale 只用 -A 追加，所以 -I 插队有效）："
echo "      iptables -I INPUT 1 -s 100.100.0.0/16 -j ACCEPT"
echo "    验证：curl -s -m 5 http://100.100.100.200/latest/meta-data/instance-id"
echo
echo "    建议写一个开机自愈的 systemd oneshot 单元持久化这条规则。"
