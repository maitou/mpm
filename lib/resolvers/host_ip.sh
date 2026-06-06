# shellcheck shell=bash

mpm_resolve_host_ip() {
  local ip
  if ! command -v ip >/dev/null 2>&1; then
    echo "mpm: ip(8) required to resolve HOST_IP" >&2
    return 1
  fi
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')
  if [[ -z "$ip" ]]; then
    echo "mpm: cannot resolve HOST_IP (ip route get 1.1.1.1)" >&2
    return 1
  fi
  printf '%s' "$ip"
}
