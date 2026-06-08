# shellcheck shell=bash
# MVP: do not modify GOPROXY/GOSUMDB. Go uses HTTP_PROXY/HTTPS_PROXY from the shell for git-backed modules.

mpm_scope_go_metadata() {
  cat <<'EOF'
title=Go (shell env only)
description=No GOPROXY changes; relies on shell mpm exports for git-backed modules
requires_root=0
EOF
}

mpm_scope_go_requires_root() {
  echo 0
}

mpm_scope_go_resolve_gateway_ip() {
  mpm_resolve_default_ip
}

mpm_scope_go_rc() {
  echo "${HOME}/.bashrc"
}

mpm_scope_go__infer_from_bashrc() {
  local f=$1 pid hp want matched=""
  [[ -f "$f" ]] || {
    echo "direct"
    return 0
  }
  if ! grep -qF "# >>> mpm begin >>>" "$f" 2>/dev/null; then
    echo "direct"
    return 0
  fi
  local inner
  inner=$(awk '
    /# >>> mpm begin >>>/ {p=1; next}
    /# <<< mpm end <<</ {p=0; next}
    p {print}
  ' "$f")
  while IFS= read -r pid; do
    [[ -z "$pid" || "$pid" == "null" || "$pid" == "direct" ]] && continue
    want=$(mpm_preset_resolve_field go "$pid" '.http_proxy' 2>/dev/null) || continue
    [[ "$want" == "null" ]] && want=""
    hp=""
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" == export\ http_proxy=\"* ]] || continue
      hp=${line#export http_proxy=\"}
      hp=${hp%\"}
      break
    done <<<"$inner"
    if [[ "$hp" == "$want" && -n "$want" ]]; then
      matched="$pid"
      break
    fi
  done < <(yq -r 'keys | .[]' "${MPM_SHARE_PROFILES}/presets/go.yaml" 2>/dev/null)
  if [[ -n "$matched" ]]; then
    echo "$matched"
    return 0
  fi
  if grep -qE 'export[[:space:]]+http_proxy=' <<<"$inner" 2>/dev/null; then
    echo "?"
    return 0
  fi
  echo "direct"
}

mpm_scope_go_get_state() {
  local f inf
  f=$(mpm_scope_go_rc)
  inf=$(mpm_scope_go__infer_from_bashrc "$f")
  if [[ "$inf" == "direct" ]]; then
    if [[ ! -f "$f" ]] || ! grep -qF "# >>> mpm begin >>>" "$f" 2>/dev/null; then
      echo "state=off"
      echo "preset=direct"
      echo "detail=no mpm shell block (go uses shell HTTP_PROXY for git modules)"
      return 0
    fi
    local inner
    inner=$(awk '/# >>> mpm begin >>>/{p=1;next}/# <<< mpm end <<</{p=0;next}p' "$f")
    if [[ -z "${inner//[$'\t\r\n ']}" ]]; then
      echo "state=mixed"
      echo "preset="
      echo "detail=empty mpm shell block"
      return 0
    fi
    echo "state=unknown"
    echo "preset="
    echo "detail=shell block present but http_proxy does not match go presets"
    return 0
  fi
  if [[ "$inf" == "?" ]]; then
    echo "state=unknown"
    echo "preset="
    echo "detail=shell mpm block has http_proxy not matching built-in go presets"
    return 0
  fi
  echo "state=on"
  echo "preset=${inf}"
  echo "detail=~/.bashrc mpm exports match go/${inf} (no GOPROXY changes)"
}

mpm_scope_go_apply_preset() {
  local preset=$1 f
  mpm_require_yq || return 1
  mpm_preset_has go "$preset" || {
    echo "mpm(go): unknown preset: ${preset}" >&2
    return 1
  }
  if [[ "$preset" != "direct" ]]; then
    f=$(mpm_scope_go_rc)
    if [[ ! -f "$f" ]] || ! grep -qF "# >>> mpm begin >>>" "$f" 2>/dev/null; then
      echo "mpm(go): hint — apply shell scope for proxy exports, e.g. mpm use shell/proxy (go does not write rc files)" >&2
    fi
  fi
  return 0
}

mpm_scope_go_apply_bundle() {
  local bundle=$1 p
  p=$(mpm_group_preset "$bundle" "go") || return 1
  [[ -n "$p" && "$p" != "null" ]] || return 1
  mpm_scope_go_apply_preset "$p"
}

mpm_scope_go_list_presets() {
  mpm_preset_table_lines go
}

# stdout: sh exports matching inferred go preset (same proxy keys as shell; go does not set GOPROXY).
mpm_scope_go_emit_shell_env() {
  mpm_require_yq || return 1
  local pr="" st="" k v
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == preset ]] && pr="$v"
    [[ "$k" == state ]] && st="$v"
  done < <(mpm_scope_go_get_state 2>/dev/null)
  if [[ "$st" == "unknown" || "$st" == "mixed" ]]; then
    return 0
  fi
  if [[ "$st" == "off" || "$pr" == "direct" || -z "${pr:-}" ]]; then
    mpm_emit_proxy_unsets_sh
    return 0
  fi
  mpm_emit_proxy_exports_sh go "$pr"
}

mpm_scope_go__inferred_preset() {
  local k v pr=""
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == preset ]] && pr="$v"
  done < <(mpm_scope_go_get_state 2>/dev/null)
  printf '%s' "$pr"
}

# Git HTTPS over proxy (typical path for git-backed Go modules); needs git.
mpm_scope_go__git_ls_remote_smoke() {
  local url=${1:-https://github.com/git/git.git}
  local hp=$2 hs=$3 ap=$4 np=$5
  if ! command -v git >/dev/null 2>&1; then
    echo "mpm(go-test): git not found; falling back to curl with proxy env" >&2
    mpm_http_probe_with_proxy_env "$hp" "$hs" "$ap" "$np" "https://www.google.com/generate_204" "go/git-fallback" || return 1
    return 0
  fi
  echo "mpm(go-test): git ls-remote ${url} HEAD (HTTP_PROXY-style env from preset)" >&2
  local rc
  set +e
  if command -v timeout >/dev/null 2>&1; then
    env \
      http_proxy="${hp}" https_proxy="${hs}" all_proxy="${ap}" no_proxy="${np}" \
      HTTP_PROXY="${hp}" HTTPS_PROXY="${hs}" ALL_PROXY="${ap}" NO_PROXY="${np}" \
      GIT_TERMINAL_PROMPT=0 \
      timeout 90 git ls-remote "$url" HEAD >/dev/null 2>&1
    rc=$?
    [[ "$rc" -eq 124 ]] && {
      echo "mpm(go-test): FAIL git ls-remote timed out (90s)" >&2
      set -e
      return 1
    }
  else
    env \
      http_proxy="${hp}" https_proxy="${hs}" all_proxy="${ap}" no_proxy="${np}" \
      HTTP_PROXY="${hp}" HTTPS_PROXY="${hs}" ALL_PROXY="${ap}" NO_PROXY="${np}" \
      GIT_TERMINAL_PROMPT=0 \
      git ls-remote "$url" HEAD >/dev/null 2>&1
    rc=$?
  fi
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "mpm(go-test): FAIL git ls-remote (exit ${rc})" >&2
    return 1
  fi
  printf 'go/proxy: OK (git ls-remote %s)\n' "$url"
  return 0
}

mpm_scope_go__test_preset_live() {
  local preset=$1 hp hs ap np
  hp=$(mpm_preset_resolve_field go "$preset" '.http_proxy // ""')
  [[ "$hp" == "null" ]] && hp=""
  hs=$(mpm_preset_resolve_field go "$preset" '.https_proxy // ""')
  [[ "$hs" == "null" ]] && hs=""
  ap=$(mpm_preset_resolve_field go "$preset" '.all_proxy // ""')
  [[ "$ap" == "null" ]] && ap=""
  np=$(mpm_preset_resolve_field go "$preset" '.no_proxy // ""')
  [[ "$np" == "null" ]] && np=""
  echo "mpm(go-test): ${preset} matches inferred shell block → git ls-remote smoke" >&2
  mpm_scope_go__git_ls_remote_smoke "https://github.com/git/git.git" "$hp" "$hs" "$ap" "$np" || return 1
}

mpm_scope_go_test_preset() {
  local preset=$1 inferred hp probe target hs ap np
  mpm_require_yq || return 1
  hp=$(mpm_preset_resolve_field go "$preset" '.http_proxy // ""')
  [[ "$hp" == "null" ]] && hp=""
  hs=$(mpm_preset_resolve_field go "$preset" '.https_proxy // ""')
  [[ "$hs" == "null" ]] && hs=""
  ap=$(mpm_preset_resolve_field go "$preset" '.all_proxy // ""')
  [[ "$ap" == "null" ]] && ap=""
  np=$(mpm_preset_resolve_field go "$preset" '.no_proxy // ""')
  [[ "$np" == "null" ]] && np=""
  probe=$(mpm_preset_yq go "$preset" '.probe // ""')
  [[ "$probe" == "null" ]] && probe=""
  if [[ "$preset" == "direct" ]] || [[ -z "$hp" ]]; then
    echo "mpm(go-test): direct — skip proxy tunnel probe" >&2
    return 0
  fi
  target="$probe"
  [[ -z "$target" ]] && target="https://www.google.com/generate_204"
  inferred=$(mpm_scope_go__inferred_preset)
  if [[ -n "$inferred" && "$inferred" == "$preset" ]]; then
    mpm_scope_go__test_preset_live "$preset" || return 1
    return 0
  fi
  echo "mpm(go-test): ${preset} is not the inferred preset (${inferred:-none}) → HTTP probe only (curl --proxy)" >&2
  mpm_http_probe_via_proxy "$hp" "$target" "go/${preset}"
}
