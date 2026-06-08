# shellcheck shell=bash

mpm_resolve_wsl_host_ip() {
  if ! grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    echo "mpm: WSL_HOST_IP requires WSL (see /proc/version)" >&2
    return 1
  fi
  local ip
  ip=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
  if [[ -z "$ip" || ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip=$(awk '/^nameserver / { print $2; exit }' /etc/resolv.conf 2>/dev/null)
  fi
  if [[ -z "$ip" || "$ip" == "127.0.0.1" || ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "mpm: cannot resolve WSL_HOST_IP (try: ip -4 route show default)" >&2
    return 1
  fi
  printf '%s' "$ip"
}
