#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export MPM_PREFIX="$ROOT"

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/scopes/apt.sh
source "$ROOT/lib/scopes/apt.sh"

# apply_preset requires root; stub for unit tests (writes only to MPM_APT_PROXY_CONF under TMP).
mpm_is_root() { return 0; }

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

mpm_require_yq || fail "yq required"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export MPM_APT_PROXY_CONF="$TMP/mpm-proxy.conf"

# --- render ---
body=$(mpm_scope_apt__expected_body_for_preset proxy) || fail "expected body"
[[ "$body" == *'Acquire::http::Proxy "http://127.0.0.1:7890/"'* ]] || fail "http proxy line: $body"
[[ "$body" == *'Acquire::https::Proxy "http://127.0.0.1:7890/"'* ]] || fail "https proxy line"
[[ "$body" == *'mpm-managed'* ]] || fail "marker missing"
pass render_proxy_body

# --- get_state off ---
st=$(mpm_scope_apt_get_state | awk -F= '/^state=/{print $2}')
[[ "$st" == "off" ]] || fail "state off: $st"
pass get_state_off

# --- get_state on ---
printf '%s' "$body" >"$MPM_APT_PROXY_CONF"
st=$(mpm_scope_apt_get_state | awk -F= '/^state=/{print $2}')
pr=$(mpm_scope_apt_get_state | awk -F= '/^preset=/{print $2}')
[[ "$st" == "on" ]] || fail "state on: $st"
[[ "$pr" == "proxy" ]] || fail "preset proxy: $pr"
pass get_state_on

# --- get_state mixed ---
printf '%s\n' "# mpm-managed" "Acquire::http::Proxy \"http://1.2.3.4:9/\";" >"$MPM_APT_PROXY_CONF"
st=$(mpm_scope_apt_get_state | awk -F= '/^state=/{print $2}')
[[ "$st" == "mixed" ]] || fail "state mixed: $st"
pass get_state_mixed

# --- apply direct (fake root via EUID) ---
printf '%s' "$body" >"$MPM_APT_PROXY_CONF"
mpm_scope_apt_apply_preset direct 2>/dev/null || fail "apply direct"
[[ ! -f "$MPM_APT_PROXY_CONF" ]] || fail "file should be removed"
pass apply_direct

# --- apply proxy idempotent ---
mpm_scope_apt_apply_preset proxy 2>/dev/null || fail "apply proxy first"
out=$(mpm_scope_apt_apply_preset proxy 2>&1) || fail "apply proxy second"
[[ "$out" == *'already using apt/proxy'* ]] || fail "idempotent: $out"
pass apply_proxy_idempotent

# --- proxy url trailing slash ---
slash=$(mpm_scope_apt__proxy_url_for_apt "http://127.0.0.1:7890")
[[ "$slash" == "http://127.0.0.1:7890/" ]] || fail "trailing slash: $slash"
pass proxy_url_trailing_slash

echo "All apt_scope_test checks passed."
