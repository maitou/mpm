#!/usr/bin/env bash
# Unit tests for preset template expansion (no root / no systemd).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export MPM_PREFIX="$ROOT"

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/scopes/shell.sh
source "$ROOT/lib/scopes/shell.sh"
# shellcheck source=../lib/scopes/docker.sh
source "$ROOT/lib/scopes/docker.sh"
# shellcheck source=../lib/scopes/k3s.sh
source "$ROOT/lib/scopes/k3s.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

mpm_require_yq || fail "yq required for template tests"

out=$(mpm_template_expand 'http://127.0.0.1:7890' shell proxy)
[[ "$out" == 'http://127.0.0.1:7890' ]] || fail "literal: got $out"
pass literal

out=$(mpm_template_expand 'http://${DEFAULT_IP}:7890' shell proxy)
[[ "$out" == 'http://127.0.0.1:7890' ]] || fail "DEFAULT_IP: got $out"
pass default_ip

if mpm_template_expand 'http://${UNKNOWN_VAR}:7890' shell proxy 2>/dev/null; then
  fail "unknown var should fail"
fi
pass unknown_var

if mpm_template_expand 'http://${DEFAULT_IP}:${PROXY_PORT}' shell direct 2>/dev/null; then
  fail "missing PROXY_PORT param should fail"
fi
pass missing_param

out=$(mpm_preset_resolve_field shell testparams '.http_proxy')
[[ "$out" == 'http://127.0.0.1:9999' ]] || fail "params expand: got $out"
pass preset_params

out=$(mpm_preset_resolve_field shell proxy '.http_proxy')
[[ "$out" == 'http://127.0.0.1:7890' ]] || fail "shell proxy migrated: got $out"
pass shell_proxy_migrated

out=$(mpm_preset_resolve_field shell testhostref '.http_proxy')
[[ "$out" == 'http://127.0.0.1:7890' ]] || fail "PROXY_HOST builtin ref: got $out"
pass proxy_host_builtin_ref

if gw=$(mpm_scope_docker_resolve_gateway_ip 2>/dev/null); then
  [[ "$gw" =~ ^[0-9.]+$ ]] || fail "docker gateway format: $gw"
  out=$(mpm_preset_resolve_field docker proxy '.http_proxy')
  [[ "$out" == "http://${gw}:7890" ]] || fail "docker proxy migrated: got $out"
  pass "docker GATEWAY_IP=$gw"
else
  echo "SKIP: docker GATEWAY_IP (no docker0/bridge)"
fi

if gw=$(mpm_scope_k3s_resolve_gateway_ip 2>/dev/null); then
  [[ "$gw" =~ ^[0-9.]+$ ]] || fail "k3s gateway format: $gw"
  pass "k3s GATEWAY_IP=$gw"
else
  echo "SKIP: k3s GATEWAY_IP (no cni0)"
fi

while IFS= read -r line; do
  pid=${line%%$'\t'*}
  [[ "$pid" == testparams || "$pid" == testhostref ]] && fail "ls must not list internal preset: $pid"
done < <(mpm_preset_table_lines shell)
pass ls_hides_internal_presets

echo "All template_test.sh checks passed"
