# shellcheck shell=bash

mpm_scope_k3s_metadata() {
  cat <<'EOF'
title=K3s systemd outbound HTTP(S) proxy
description=systemd drop-in + EnvironmentFile for k3s.service / k3s-agent.service when units exist
requires_root=1
EOF
}

mpm_scope_k3s_requires_root() {
  echo 1
}

mpm_scope_k3s__unit_fragment_dir() {
  local unit=$1
  echo "/etc/systemd/system/${unit}.d"
}

mpm_scope_k3s__dropin_conf() {
  local unit=$1
  echo "$(mpm_scope_k3s__unit_fragment_dir "$unit")/mpm-proxy.conf"
}

mpm_scope_k3s__envfile() {
  local unit=$1
  echo "$(mpm_scope_k3s__unit_fragment_dir "$unit")/mpm-proxy.env"
}

mpm_scope_k3s__unit_exists() {
  local unit=$1
  systemctl cat "${unit}" >/dev/null 2>&1
}

mpm_scope_k3s__read_proxy_fields() {
  local preset=$1
  mpm_require_yq || return 1
  MPM_K3S_HP=$(mpm_preset_yq k3s "$preset" '.http_proxy') || return 1
  MPM_K3S_HS=$(mpm_preset_yq k3s "$preset" '.https_proxy') || return 1
  MPM_K3S_AP=$(mpm_preset_yq k3s "$preset" '.all_proxy') || return 1
  MPM_K3S_NP=$(mpm_preset_yq k3s "$preset" '.no_proxy') || return 1
  [[ "$MPM_K3S_HP" == "null" ]] && MPM_K3S_HP=""
  [[ "$MPM_K3S_HS" == "null" ]] && MPM_K3S_HS=""
  [[ "$MPM_K3S_AP" == "null" ]] && MPM_K3S_AP=""
  [[ "$MPM_K3S_NP" == "null" ]] && MPM_K3S_NP=""
  return 0
}

mpm_scope_k3s__render_envfile_body() {
  local hp=$1 hs=$2 ap=$3 np=$4
  cat <<EOF
# mpm-managed; remove with: mpm use direct-group --scopes=k3s
HTTP_PROXY=${hp}
HTTPS_PROXY=${hs}
http_proxy=${hp}
https_proxy=${hs}
ALL_PROXY=${ap}
all_proxy=${ap}
NO_PROXY=${np}
no_proxy=${np}
EOF
}

mpm_scope_k3s__render_dropin_conf() {
  local unit=$1 envpath=$2
  cat <<EOF
# mpm-managed drop-in for ${unit}; safe to remove with: mpm use direct-group --scopes=k3s
[Service]
EnvironmentFile=${envpath}
EOF
}

mpm_scope_k3s__expected_env_body_for_preset() {
  local preset=$1
  mpm_scope_k3s__read_proxy_fields "$preset" || return 1
  if [[ "$preset" == "direct" ]] || [[ -z "$MPM_K3S_HP" && -z "$MPM_K3S_HS" ]]; then
    printf ''
    return 0
  fi
  mpm_scope_k3s__render_envfile_body "$MPM_K3S_HP" "$MPM_K3S_HS" "$MPM_K3S_AP" "$MPM_K3S_NP"
}

mpm_scope_k3s__expected_conf_for_unit_preset() {
  local unit=$1 preset=$2
  mpm_scope_k3s__read_proxy_fields "$preset" || return 1
  if [[ "$preset" == "direct" ]] || [[ -z "$MPM_K3S_HP" && -z "$MPM_K3S_HS" ]]; then
    printf ''
    return 0
  fi
  mpm_scope_k3s__render_dropin_conf "$unit" "$(mpm_scope_k3s__envfile "$unit")"
}

mpm_scope_k3s__iter_managed_units() {
  local u
  for u in k3s.service k3s-agent.service; do
    mpm_scope_k3s__unit_exists "$u" && echo "$u"
  done
}

mpm_scope_k3s_get_state() {
  local units u d ef want_env want_conf cur_env cur_conf on=0 off=0 mix=0 unk=0
  mapfile -t units < <(mpm_scope_k3s__iter_managed_units)
  if [[ ${#units[@]} -eq 0 ]]; then
    echo "state=off"
    echo "preset=direct"
    echo "detail=no k3s.service or k3s-agent.service on systemd"
    return 0
  fi
  want_env=$(mpm_scope_k3s__expected_env_body_for_preset proxy) || want_env=""
  for u in "${units[@]}"; do
    d=$(mpm_scope_k3s__dropin_conf "$u")
    ef=$(mpm_scope_k3s__envfile "$u")
    want_conf=$(mpm_scope_k3s__expected_conf_for_unit_preset "$u" proxy) || want_conf=""
    if [[ ! -f "$d" && ! -f "$ef" ]]; then
      off=$((off + 1))
      continue
    fi
    if [[ -f "$d" ]] && ! grep -q "mpm-managed drop-in" "$d" 2>/dev/null; then
      unk=$((unk + 1))
      continue
    fi
    if [[ -f "$ef" ]] && ! grep -q "mpm-managed" "$ef" 2>/dev/null; then
      unk=$((unk + 1))
      continue
    fi
    cur_env=$(cat "$ef" 2>/dev/null || true)
    cur_conf=$(cat "$d" 2>/dev/null || true)
    if [[ -n "$want_env" && "$cur_env" == "$want_env" && "$cur_conf" == "$want_conf" ]]; then
      on=$((on + 1))
    elif { [[ -f "$ef" ]] && grep -qE '^(HTTP_PROXY|http_proxy)=' "$ef" 2>/dev/null; } ||
      { [[ -f "$d" ]] && grep -qE 'Environment(File)?=' "$d" 2>/dev/null; }; then
      mix=$((mix + 1))
    else
      unk=$((unk + 1))
    fi
  done
  local n=${#units[@]}
  if [[ "$on" -eq "$n" ]]; then
    echo "state=on"
    echo "preset=proxy"
    echo "detail=all present units have matching mpm drop-in + env"
    return 0
  fi
  if [[ "$off" -eq "$n" ]]; then
    echo "state=off"
    echo "preset=direct"
    echo "detail=no mpm k3s proxy files"
    return 0
  fi
  if [[ "$mix" -gt 0 || "$unk" -gt 0 ]]; then
    echo "state=mixed"
    echo "preset="
    echo "detail=some units differ or are non-mpm (${on} on / ${off} off / ${mix} mixed / ${unk} unknown across ${n} units)"
    return 0
  fi
  if [[ "$on" -gt 0 ]]; then
    echo "state=mixed"
    echo "preset="
    echo "detail=only ${on}/${n} units match proxy preset; others have no mpm files"
    return 0
  fi
  echo "state=unknown"
  echo "preset="
  echo "detail=cannot classify k3s proxy files"
}

mpm_scope_k3s_restart_for_preset() {
  local preset=$1
  mpm_require_yq || return 0
  local unit
  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    if mpm_scope_k3s__unit_exists "$unit" && systemctl is-active --quiet "${unit}" 2>/dev/null; then
      echo "mpm(k3s): restarting ${unit}…" >&2
      systemctl restart "${unit}" || return 1
    fi
  done < <(yq -r ".[\"${preset}\"].restart_units[]?" "${MPM_SHARE_PROFILES}/presets/k3s.yaml" 2>/dev/null)
  systemctl daemon-reload 2>/dev/null || true
}

mpm_scope_k3s__ensure_fragment_parent() {
  local path=$1
  local parent
  parent=$(dirname "$path")
  if [[ -e "$parent" && ! -d "$parent" ]]; then
    echo "mpm(k3s): ${parent} exists but is not a directory; fix systemd layout" >&2
    return 1
  fi
  mkdir -p "$parent" || {
    echo "mpm(k3s): mkdir -p ${parent} failed (errno $?)" >&2
    return 1
  }
  return 0
}

mpm_scope_k3s_apply_preset() {
  local preset=$1
  mpm_is_root || {
    echo "mpm(k3s): root required" >&2
    return 2
  }
  mpm_require_yq || return 1
  mpm_preset_has k3s "$preset" || {
    echo "mpm(k3s): unknown preset: ${preset}" >&2
    return 1
  }
  local units u d ef env_body conf_body wrote=0
  mapfile -t units < <(mpm_scope_k3s__iter_managed_units)
  if [[ ${#units[@]} -eq 0 ]]; then
    echo "mpm(k3s): no k3s.service or k3s-agent.service found; nothing to do" >&2
    return 0
  fi

  if [[ "$preset" == "direct" ]]; then
    for u in "${units[@]}"; do
      d=$(mpm_scope_k3s__dropin_conf "$u")
      ef=$(mpm_scope_k3s__envfile "$u")
      if [[ -f "$ef" ]] && ! grep -q "mpm-managed" "$ef" 2>/dev/null; then
        echo "mpm(k3s): ${ef} is not mpm-managed; skipping" >&2
        continue
      fi
      if [[ -f "$d" ]] && ! grep -q "mpm-managed drop-in" "$d" 2>/dev/null; then
        echo "mpm(k3s): ${d} is not mpm-managed; skipping" >&2
        continue
      fi
      [[ -f "$ef" ]] && mpm_backup_file "$ef" >/dev/null
      [[ -f "$d" ]] && mpm_backup_file "$d" >/dev/null
      rm -f "$ef" "$d"
      wrote=1
    done
    [[ "$wrote" -eq 0 ]] && echo "already using k3s/direct" >&2
    systemctl daemon-reload 2>/dev/null || true
    mpm_scope_k3s_restart_for_preset "$preset" || true
    return 0
  fi

  env_body=$(mpm_scope_k3s__expected_env_body_for_preset "$preset") || {
    echo "mpm(k3s): cannot build env body for ${preset} (check stderr above; expected preset file: ${MPM_SHARE_PROFILES}/presets/k3s.yaml)" >&2
    return 1
  }
  [[ -n "$env_body" ]] || {
    echo "mpm(k3s): preset ${preset} produced empty env body" >&2
    return 1
  }

  for u in "${units[@]}"; do
    d=$(mpm_scope_k3s__dropin_conf "$u")
    ef=$(mpm_scope_k3s__envfile "$u")
    conf_body=$(mpm_scope_k3s__expected_conf_for_unit_preset "$u" "$preset") || {
      echo "mpm(k3s): cannot build drop-in for ${u}" >&2
      return 1
    }
    [[ -n "$conf_body" ]] || {
      echo "mpm(k3s): empty drop-in for ${u}" >&2
      return 1
    }
    mpm_scope_k3s__ensure_fragment_parent "$d" || return 1
    if [[ -f "$ef" && -f "$d" ]]; then
      local tmp_e tmp_c
      tmp_e=$(mktemp)
      tmp_c=$(mktemp)
      printf '%s\n' "$env_body" >"$tmp_e"
      printf '%s\n' "$conf_body" >"$tmp_c"
      if cmp -s "$ef" "$tmp_e" 2>/dev/null && cmp -s "$d" "$tmp_c" 2>/dev/null; then
        rm -f "$tmp_e" "$tmp_c"
        continue
      fi
      rm -f "$tmp_e" "$tmp_c"
    fi
    [[ -f "$ef" ]] && mpm_backup_file "$ef" >/dev/null
    [[ -f "$d" ]] && mpm_backup_file "$d" >/dev/null
    if ! printf '%s\n' "$env_body" >"${ef}.tmp"; then
      echo "mpm(k3s): cannot write ${ef}.tmp" >&2
      rm -f "${ef}.tmp"
      return 1
    fi
    if ! mv "${ef}.tmp" "$ef"; then
      echo "mpm(k3s): cannot mv ${ef}.tmp -> ${ef}" >&2
      rm -f "${ef}.tmp"
      return 1
    fi
    chmod 0644 "$ef" || true
    if ! printf '%s\n' "$conf_body" >"${d}.tmp"; then
      echo "mpm(k3s): cannot write ${d}.tmp" >&2
      rm -f "${d}.tmp"
      return 1
    fi
    if ! mv "${d}.tmp" "$d"; then
      echo "mpm(k3s): cannot mv ${d}.tmp -> ${d}" >&2
      rm -f "${d}.tmp"
      return 1
    fi
    chmod 0644 "$d" || true
    wrote=1
  done
  if [[ "$wrote" -eq 0 ]]; then
    echo "already using k3s/${preset}" >&2
  fi
  systemctl daemon-reload 2>/dev/null || true
  mpm_scope_k3s_restart_for_preset "$preset" || true
  return 0
}

mpm_scope_k3s_apply_bundle() {
  local bundle=$1 p
  p=$(mpm_group_preset "$bundle" "k3s") || {
    echo "mpm(k3s): yq failed reading group preset (group=${bundle}, scope=k3s); check ${MPM_SHARE_PROFILES}/groups.yaml" >&2
    return 1
  }
  if [[ -z "$p" || "$p" == "null" ]]; then
    echo "mpm(k3s): group ${bundle} has no k3s mapping (empty or null). Fix groups.yaml." >&2
    return 1
  fi
  mpm_scope_k3s_apply_preset "$p"
}

mpm_scope_k3s_list_presets() {
  mpm_preset_table_lines k3s
}

mpm_scope_k3s__inferred_preset() {
  local k v pr=""
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == preset ]] && pr="$v"
  done < <(mpm_scope_k3s_get_state 2>/dev/null)
  printf '%s' "$pr"
}

# Pull a tiny Hub image; prefer k3s crictl (CRI), then containerd ctr namespaces.
mpm_scope_k3s__live_pull_smoke() {
  local ref=$1 log rc
  log=$(mktemp)
  : >"$log"
  if command -v k3s >/dev/null 2>&1 && k3s crictl info >/dev/null 2>&1; then
    echo "mpm(k3s-test): trying k3s crictl pull ${ref}" >&2
    set +e
    if command -v timeout >/dev/null 2>&1; then
      timeout 180 k3s crictl pull "$ref" >>"$log" 2>&1
    else
      k3s crictl pull "$ref" >>"$log" 2>&1
    fi
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      rm -f "$log"
      return 0
    fi
    if [[ "$rc" -eq 124 ]]; then
      echo "mpm(k3s-test): FAIL crictl pull timed out (180s) for ${ref}" >&2
      tail -n 25 "$log" >&2 || true
      rm -f "$log"
      return 1
    fi
    echo "mpm(k3s-test): crictl pull failed (exit ${rc}); falling back to ctr" >&2
    tail -n 8 "$log" >&2 || true
    : >"$log"
  fi
  if ! command -v k3s >/dev/null 2>&1; then
    echo "mpm(k3s-test): k3s not on PATH; install K3s or add it to PATH for live pull test" >&2
    rm -f "$log"
    return 1
  fi
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout 180 k3s ctr -n k8s.io images pull "$ref" >>"$log" 2>&1
  else
    k3s ctr -n k8s.io images pull "$ref" >>"$log" 2>&1
  fi
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    rm -f "$log"
    return 0
  fi
  if [[ "$rc" -eq 124 ]]; then
    echo "mpm(k3s-test): FAIL ctr pull timed out (180s) for ${ref}" >&2
    tail -n 20 "$log" >&2 || true
    rm -f "$log"
    return 1
  fi
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout 180 k3s ctr images pull "$ref" >>"$log" 2>&1
  else
    k3s ctr images pull "$ref" >>"$log" 2>&1
  fi
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    rm -f "$log"
    return 0
  fi
  if [[ "$rc" -eq 124 ]]; then
    echo "mpm(k3s-test): FAIL k3s ctr images pull timed out (180s) for ${ref}" >&2
  else
    echo "mpm(k3s-test): FAIL k3s ctr images pull ${ref} (exit ${rc})" >&2
  fi
  tail -n 25 "$log" >&2 || true
  rm -f "$log"
  return 1
}

mpm_scope_k3s__test_preset_live() {
  local preset=$1 img
  img="docker.io/library/alpine:3.19"
  echo "mpm(k3s-test): ${preset} matches inferred → live pull ${img} (crictl then ctr; uses k3s systemd proxy env)" >&2
  if ! command -v k3s >/dev/null 2>&1; then
    echo "mpm(k3s-test): k3s not on PATH; install K3s or add it to PATH for live pull test" >&2
    return 1
  fi
  mpm_scope_k3s__live_pull_smoke "$img" || return 1
  printf 'k3s/%s: OK (live pull %s)\n' "$preset" "$img"
}

mpm_scope_k3s_test_preset() {
  local preset=$1 inferred hp probe target
  mpm_require_yq || return 1
  hp=$(mpm_preset_yq k3s "$preset" '.http_proxy // ""')
  [[ "$hp" == "null" ]] && hp=""
  probe=$(mpm_preset_yq k3s "$preset" '.probe // ""')
  [[ "$probe" == "null" ]] && probe=""
  if [[ "$preset" == "direct" ]] || [[ -z "$hp" ]]; then
    echo "mpm(k3s-test): direct — skip proxy tunnel probe" >&2
    return 0
  fi
  target="$probe"
  [[ -z "$target" ]] && target="https://hub.docker.com"
  inferred=$(mpm_scope_k3s__inferred_preset)
  if [[ -n "$inferred" && "$inferred" == "$preset" ]]; then
    mpm_scope_k3s__test_preset_live "$preset" || return 1
    return 0
  fi
  echo "mpm(k3s-test): ${preset} is not the inferred preset (${inferred:-none}) → HTTP probe only (curl --proxy)" >&2
  mpm_http_probe_via_proxy "$hp" "$target" "k3s/${preset}"
}
