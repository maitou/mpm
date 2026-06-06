#!/usr/bin/env bash
# Fix k3s crash loop: inotify_init / too many open files (common with k3s + docker + kind).
# Usage: sudo bash scripts/fix-k3s-too-many-open-files.sh
set -euo pipefail

if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 2
fi

echo "==> Current limits"
sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches fs.inotify.max_queued_events 2>/dev/null || true
systemctl show k3s -p LimitNOFILE --value 2>/dev/null || true

echo "==> Persist higher inotify limits"
cat >/etc/sysctl.d/99-mpm-k3s-inotify.conf <<'EOF'
# k3s/kubelet/docker use many fsnotify watchers; default max_user_instances=128 is too low.
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
fs.inotify.max_queued_events = 32768
EOF
sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-mpm-k3s-inotify.conf

echo "==> k3s systemd LimitNOFILE (separate from mpm-proxy drop-in)"
mkdir -p /etc/systemd/system/k3s.service.d
cat >/etc/systemd/system/k3s.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
if systemctl list-unit-files k3s-agent.service &>/dev/null; then
  mkdir -p /etc/systemd/system/k3s-agent.service.d
  cat >/etc/systemd/system/k3s-agent.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
fi
systemctl daemon-reload

echo "==> Stop k3s and clean stale containerd shims"
systemctl stop k3s 2>/dev/null || true
if [[ -x /usr/local/bin/k3s-killall.sh ]]; then
  /usr/local/bin/k3s-killall.sh || true
elif command -v k3s-killall.sh >/dev/null 2>&1; then
  k3s-killall.sh || true
fi
sleep 2

echo "==> Start k3s"
systemctl start k3s
sleep 5
systemctl status k3s --no-pager -l | head -25

if systemctl is-active --quiet k3s; then
  echo "OK: k3s is active"
  exit 0
fi
echo "FAIL: k3s still not active; check: journalctl -u k3s -n 60 --no-pager" >&2
exit 1
