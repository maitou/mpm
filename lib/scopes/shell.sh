# shellcheck shell=bash

mpm_scope_shell_metadata() {
  cat <<'EOF'
title=Interactive shell proxy exports
description=Writes mpm-marked exports in ~/.bashrc (http_proxy, https_proxy, all_proxy, no_proxy)
requires_root=0
EOF
}

mpm_scope_shell_requires_root() {
  echo 0
}

mpm_scope_shell_resolve_gateway_ip() {
  mpm_resolve_default_ip
}

mpm_scope_shell_rc() {
  echo "${HOME}/.bashrc"
}

mpm_scope_shell_marker_begin() { echo '# >>> mpm begin >>>'; }
mpm_scope_shell_marker_end() { echo '# <<< mpm end <<<'; }

mpm_scope_shell__strip_block() {
  local file=$1
  [[ -f "$file" ]] || return 0
  local tmp
  tmp=$(mktemp)
  awk '
    /# >>> mpm begin >>>/ {skip=1; next}
    /# <<< mpm end <<</ {skip=0; next}
    !skip {print}
  ' "$file" >"$tmp" && mv "$tmp" "$file"
}

mpm_scope_shell__block_body_from_preset() {
  local preset=$1
  mpm_require_yq || return 1
  local hp hs ap np
  hp=$(mpm_preset_resolve_field shell "$preset" '.http_proxy') || return 1
  hs=$(mpm_preset_resolve_field shell "$preset" '.https_proxy') || return 1
  ap=$(mpm_preset_resolve_field shell "$preset" '.all_proxy') || return 1
  np=$(mpm_preset_yq shell "$preset" '.no_proxy') || return 1
  [[ "$hp" == "null" ]] && hp=""
  [[ "$hs" == "null" ]] && hs=""
  [[ "$ap" == "null" ]] && ap=""
  [[ "$np" == "null" ]] && np=""
  printf 'export http_proxy="%s"\n' "$hp"
  printf 'export https_proxy="%s"\n' "$hs"
  printf 'export all_proxy="%s"\n' "$ap"
  printf 'export no_proxy="%s"\n' "$np"
  printf 'export HTTP_PROXY="%s"\n' "$hp"
  printf 'export HTTPS_PROXY="%s"\n' "$hs"
  printf 'export ALL_PROXY="%s"\n' "$ap"
  printf 'export NO_PROXY="%s"\n' "$np"
}

mpm_scope_shell__extract_block_inner() {
  local file=$1
  [[ -f "$file" ]] || return 0
  awk '
    /# >>> mpm begin >>>/ {p=1; next}
    /# <<< mpm end <<</ {p=0; next}
    p {print}
  ' "$file"
}

mpm_scope_shell__value_from_exports() {
  local inner=$1 var=$2 line val
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == export\ "${var}="* ]] || continue
    val=${line#export }
    val=${val#"${var}="}
    val=${val#\"}
    val=${val%\"}
    printf '%s' "$val"
    return 0
  done <<<"$inner"
  printf ''
}

mpm_scope_shell__infer_preset_from_file() {
  local file=$1
  local inner pid hp want matched=""
  [[ -f "$file" ]] || {
    echo "direct"
    return 0
  }
  grep -qF "$(mpm_scope_shell_marker_begin)" "$file" 2>/dev/null || {
    echo "direct"
    return 0
  }
  inner=$(mpm_scope_shell__extract_block_inner "$file")
  while IFS= read -r pid; do
    [[ -z "$pid" || "$pid" == "null" || "$pid" == "direct" ]] && continue
    want=$(mpm_preset_resolve_field shell "$pid" '.http_proxy' 2>/dev/null) || continue
    [[ "$want" == "null" ]] && want=""
    hp=$(mpm_scope_shell__value_from_exports "$inner" "http_proxy")
    if [[ "$hp" == "$want" && -n "$want" ]]; then
      matched="$pid"
      break
    fi
  done < <(yq -r 'keys | .[]' "${MPM_SHARE_PROFILES}/presets/shell.yaml" 2>/dev/null)
  if [[ -n "$matched" ]]; then
    echo "$matched"
    return 0
  fi
  if grep -qE '(^export[[:space:]]+http_proxy=|^export[[:space:]]+HTTP_PROXY=)' <<<"$inner" 2>/dev/null; then
    echo "?"
    return 0
  fi
  echo "direct"
}

mpm_scope_shell_get_state() {
  local f
  f=$(mpm_scope_shell_rc)
  if [[ ! -f "$f" ]]; then
    echo "state=off"
    echo "preset=direct"
    echo "detail=no ~/.bashrc"
    return 0
  fi
  if ! grep -qF "$(mpm_scope_shell_marker_begin)" "$f" 2>/dev/null; then
    echo "state=off"
    echo "preset=direct"
    echo "detail=no mpm-managed block in ~/.bashrc"
    return 0
  fi
  local inferred
  inferred=$(mpm_scope_shell__infer_preset_from_file "$f")
  if [[ "$inferred" == "?" ]]; then
    echo "state=unknown"
    echo "preset="
    echo "detail=mpm block present but http_proxy does not match a built-in preset"
    return 0
  fi
  if [[ "$inferred" == "direct" ]]; then
    # Markers exist but inner empty / unrecognized
    local inner
    inner=$(mpm_scope_shell__extract_block_inner "$f")
    if [[ -z "${inner//[$'\t\r\n ']}" ]]; then
      echo "state=mixed"
      echo "preset="
      echo "detail=empty mpm block"
      return 0
    fi
    echo "state=unknown"
    echo "preset="
    echo "detail=mpm block could not be mapped to a preset"
    return 0
  fi
  echo "state=on"
  echo "preset=${inferred}"
  echo "detail=mpm-managed block in ~/.bashrc matches ${inferred}"
}

mpm_scope_shell__file_has_desired_block() {
  local file=$1 preset=$2
  [[ -f "$file" ]] || return 1
  local want got
  want=$(mktemp)
  got=$(mktemp)
  {
    mpm_scope_shell_marker_begin
    mpm_scope_shell__block_body_from_preset "$preset"
    mpm_scope_shell_marker_end
  } >"$want" 2>/dev/null || {
    rm -f "$want" "$got"
    return 1
  }
  awk '
    /# >>> mpm begin >>>/ {p=1; print; next}
    /# <<< mpm end <<</ {print; p=0; next}
    p {print}
  ' "$file" >"$got"
  if cmp -s "$want" "$got" 2>/dev/null; then
    rm -f "$want" "$got"
    return 0
  fi
  rm -f "$want" "$got"
  return 1
}

mpm_scope_shell_apply_preset() {
  local preset=$1
  mpm_require_yq || return 1
  mpm_preset_has shell "$preset" || {
    echo "mpm(shell): unknown preset: ${preset}" >&2
    return 1
  }
  local f
  f=$(mpm_scope_shell_rc)
  if [[ "$preset" == "direct" ]]; then
    if [[ ! -f "$f" ]] || ! grep -qF "$(mpm_scope_shell_marker_begin)" "$f" 2>/dev/null; then
      echo "already using shell/direct (no mpm block)" >&2
      return 0
    fi
    mpm_scope_shell__strip_block "$f"
    echo "mpm(shell): removed mpm-managed block from ${f}" >&2
    return 0
  fi
  [[ ! -f "$f" ]] && touch "$f"
  if mpm_scope_shell__file_has_desired_block "$f" "$preset"; then
    echo "already using shell/${preset}" >&2
    return 0
  fi
  mpm_backup_file "$f" >/dev/null 2>&1 || true
  mpm_scope_shell__strip_block "$f"
  {
    echo ""
    mpm_scope_shell_marker_begin
    mpm_scope_shell__block_body_from_preset "$preset"
    mpm_scope_shell_marker_end
  } >>"$f"
  echo "mpm(shell): wrote shell/${preset} block to ${f}" >&2
  return 0
}

mpm_scope_shell_apply_bundle() {
  local bundle=$1 p
  p=$(mpm_group_preset "$bundle" "shell") || return 1
  [[ -n "$p" && "$p" != "null" ]] || return 1
  mpm_scope_shell_apply_preset "$p"
}

mpm_scope_shell_list_presets() {
  mpm_preset_table_lines shell
}

# stdout: sh exports for eval "$(mpm shell-env --scopes=shell)" (same vars as mpm ~/.bashrc block).
mpm_scope_shell_emit_shell_env() {
  mpm_require_yq || return 1
  local pr="" st="" k v
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == preset ]] && pr="$v"
    [[ "$k" == state ]] && st="$v"
  done < <(mpm_scope_shell_get_state 2>/dev/null)
  if [[ "$st" == "unknown" || "$st" == "mixed" ]]; then
    return 0
  fi
  if [[ "$st" == "off" || "$pr" == "direct" || -z "${pr:-}" ]]; then
    mpm_emit_proxy_unsets_sh
    return 0
  fi
  mpm_emit_proxy_exports_sh shell "$pr"
}

mpm_scope_shell__inferred_preset() {
  local k v pr=""
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == "preset" ]] && pr="$v"
  done < <(mpm_scope_shell_get_state 2>/dev/null)
  printf '%s' "$pr"
}

mpm_scope_shell_test_preset() {
  local preset=$1 inferred target probe hp hs ap np
  mpm_require_yq || return 1
  probe=$(mpm_preset_yq shell "$preset" '.probe // ""')
  [[ "$probe" == "null" ]] && probe=""
  hp=$(mpm_preset_resolve_field shell "$preset" '.http_proxy // ""')
  [[ "$hp" == "null" ]] && hp=""
  hs=$(mpm_preset_resolve_field shell "$preset" '.https_proxy // ""')
  [[ "$hs" == "null" ]] && hs=""
  ap=$(mpm_preset_resolve_field shell "$preset" '.all_proxy // ""')
  [[ "$ap" == "null" ]] && ap=""
  np=$(mpm_preset_yq shell "$preset" '.no_proxy // ""')
  [[ "$np" == "null" ]] && np=""
  if [[ "$preset" == "direct" ]] || [[ -z "$hp" ]]; then
    echo "mpm(shell-test): direct — skip proxy tunnel probe" >&2
    return 0
  fi
  target="$probe"
  [[ -z "$target" ]] && target="https://www.google.com/generate_204"
  inferred=$(mpm_scope_shell__inferred_preset)
  if [[ -n "$inferred" && "$inferred" == "$preset" ]]; then
    echo "mpm(shell-test): ${preset} matches inferred ~/.bashrc block → curl with http_proxy-style env" >&2
    mpm_http_probe_with_proxy_env "$hp" "$hs" "$ap" "$np" "$target" "shell/${preset}" || return 1
    return 0
  fi
  echo "mpm(shell-test): ${preset} is not the inferred preset (${inferred:-none}) → HTTP probe only (curl --proxy)" >&2
  mpm_http_probe_via_proxy "$hp" "$target" "shell/${preset}"
}
