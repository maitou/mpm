#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export MPM_PREFIX="$ROOT"

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

if mpm_template_resolve_builtin WSL_HOST_IP shell 2>/dev/null; then
  if ! grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    fail "WSL_HOST_IP should fail on non-WSL"
  fi
  ip=$(mpm_resolve_wsl_host_ip)
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "WSL_HOST_IP format: $ip"
  pass "WSL_HOST_IP=$ip"
else
  if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    fail "WSL_HOST_IP should resolve on WSL"
  fi
  pass "WSL_HOST_IP rejected on non-WSL (expected)"
fi

csv=$(mpm_template_builtin_names_csv)
[[ "$csv" == *WSL_HOST_IP* ]] || fail "builtin csv missing WSL_HOST_IP"
pass builtin_csv

echo "All wsl_host_ip_test.sh checks passed"
