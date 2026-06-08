# shellcheck shell=bash

mpm_scope_apt_metadata() {
  cat <<'EOF'
title=APT outbound HTTP(S) proxy
description=Writes /etc/apt/apt.conf.d/mpm-proxy.conf (Acquire::http::Proxy); no apt restart needed
requires_root=1
EOF
}

mpm_scope_apt_requires_root() {
  echo 1
}

mpm_scope_apt_resolve_gateway_ip() {
  mpm_resolve_default_ip
}

mpm_scope_apt_conf_path() {
  echo "${MPM_APT_PROXY_CONF:-/etc/apt/apt.conf.d/mpm-proxy.conf}"
}

# apt Acquire::Proxy URLs should end with /
mpm_scope_apt__proxy_url_for_apt() {
  local url=$1
  [[ -n "$url" ]] || return 0
  url="${url%/}/"
  printf '%s' "$url"
}

mpm_scope_apt__read_proxy_fields() {
  local preset=$1
  mpm_require_yq || return 1
  MPM_APT_HP=$(mpm_preset_resolve_field apt "$preset" '.http_proxy') || return 1
  MPM_APT_HS=$(mpm_preset_resolve_field apt "$preset" '.https_proxy') || return 1
  MPM_APT_NP=$(mpm_preset_resolve_field apt "$preset" '.no_proxy') || return 1
  [[ "$MPM_APT_HP" == "null" ]] && MPM_APT_HP=""
  [[ "$MPM_APT_HS" == "null" ]] && MPM_APT_HS=""
  [[ "$MPM_APT_NP" == "null" ]] && MPM_APT_NP=""
  return 0
}

mpm_scope_apt__render_conf_body() {
  local hp=$1 hs=$2 np=$3 hp_apt hs_apt
  hp_apt=$(mpm_scope_apt__proxy_url_for_apt "$hp")
  hs_apt=$(mpm_scope_apt__proxy_url_for_apt "$hs")
  [[ -n "$hp_apt" || -n "$hs_apt" ]] || return 0
  cat <<EOF
# mpm-managed; remove with: mpm use direct-group --scopes=apt
Acquire::http::Proxy "${hp_apt:-$hs_apt}";
Acquire::https::Proxy "${hs_apt:-$hp_apt}";
EOF
  if [[ -n "$np" ]]; then
    cat <<EOF
Acquire::http::Proxy::NoProxy "${np}";
Acquire::https::Proxy::NoProxy "${np}";
EOF
  fi
}

mpm_scope_apt__expected_body_for_preset() {
  local preset=$1
  if [[ "$preset" == "direct" ]]; then
    printf ''
    return 0
  fi
  mpm_scope_apt__read_proxy_fields "$preset" || return 1
  if [[ -z "$MPM_APT_HP" && -z "$MPM_APT_HS" ]]; then
    printf ''
    return 0
  fi
  mpm_scope_apt__render_conf_body "$MPM_APT_HP" "$MPM_APT_HS" "$MPM_APT_NP"
}

mpm_scope_apt_get_state() {
  local path cur want
  path=$(mpm_scope_apt_conf_path)
  if [[ ! -f "$path" ]]; then
    echo "state=off"
    echo "preset=direct"
    echo "detail=no mpm apt proxy config (${path})"
    return 0
  fi
  cur=$(cat "$path" 2>/dev/null || true)
  if ! grep -q 'mpm-managed' <<<"$cur" 2>/dev/null; then
    echo "state=unknown"
    echo "preset="
    echo "detail=${path} exists but is not mpm-managed"
    return 0
  fi
  want=$(mpm_scope_apt__expected_body_for_preset proxy) || {
    echo "state=unknown"
    echo "preset="
    echo "detail=cannot read apt proxy preset"
    return 0
  }
  if [[ -n "$want" && "$cur" == "$want" ]]; then
    echo "state=on"
    echo "preset=proxy"
    echo "detail=mpm-managed apt proxy config matches built-in proxy preset"
    return 0
  fi
  if [[ -z "$want" ]]; then
    echo "state=mixed"
    echo "preset="
    echo "detail=mpm apt file present but proxy preset resolved empty"
    return 0
  fi
  echo "state=mixed"
  echo "preset="
  echo "detail=mpm apt proxy config differs from built-in proxy preset"
}

mpm_scope_apt_apply_preset() {
  local preset=$1
  mpm_require_yq || return 1
  mpm_preset_has apt "$preset" || {
    echo "mpm(apt): unknown preset: ${preset}" >&2
    return 1
  }
  local path body tmp parent
  path=$(mpm_scope_apt_conf_path)

  if [[ "$preset" == "direct" ]]; then
    if [[ ! -f "$path" ]]; then
      echo "already using apt/direct" >&2
      return 0
    fi
    if ! grep -q 'mpm-managed' "$path" 2>/dev/null; then
      echo "mpm(apt): ${path} exists and is not mpm-managed; leaving in place" >&2
      return 1
    fi
    mpm_backup_file "$path" >/dev/null
    if mpm_needs_sudo_for_path "$path"; then
      mpm_sudo rm -f "$path"
    else
      rm -f "$path"
    fi
    echo "mpm(apt): removed ${path}" >&2
    return 0
  fi

  body=$(mpm_scope_apt__expected_body_for_preset "$preset") || {
    echo "mpm(apt): cannot build config body for ${preset}" >&2
    return 1
  }
  [[ -n "$body" ]] || {
    echo "mpm(apt): preset ${preset} produced empty apt proxy config" >&2
    return 1
  }

  tmp=$(mktemp)
  printf '%s' "$body" >"$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    echo "already using apt/${preset}" >&2
    return 0
  fi

  parent=$(dirname "$path")
  if [[ -e "$parent" && ! -d "$parent" ]]; then
    rm -f "$tmp"
    echo "mpm(apt): ${parent} exists but is not a directory" >&2
    return 1
  fi
  if mpm_needs_sudo_for_path "$path"; then
    mpm_sudo mkdir -p "$parent" || {
      rm -f "$tmp"
      echo "mpm(apt): mkdir -p ${parent} failed" >&2
      return 1
    }
  else
    mkdir -p "$parent" || {
      rm -f "$tmp"
      echo "mpm(apt): mkdir -p ${parent} failed" >&2
      return 1
    }
  fi

  [[ -f "$path" ]] && mpm_backup_file "$path" >/dev/null
  if mpm_needs_sudo_for_path "$path"; then
    mpm_sudo mv "$tmp" "$path"
    mpm_sudo chmod 0644 "$path"
  else
    mv "$tmp" "$path"
    chmod 0644 "$path"
  fi
  echo "mpm(apt): wrote apt/${preset} -> ${path}" >&2
  return 0
}

mpm_scope_apt_apply_bundle() {
  local bundle=$1 p
  p=$(mpm_group_preset "$bundle" "apt") || {
    echo "mpm(apt): yq failed reading group preset (group=${bundle}, scope=apt)" >&2
    return 1
  }
  if [[ -z "$p" || "$p" == "null" ]]; then
    echo "mpm(apt): group ${bundle} has no apt mapping" >&2
    return 1
  fi
  mpm_scope_apt_apply_preset "$p"
}

mpm_scope_apt_list_presets() {
  mpm_preset_table_lines apt
}

mpm_scope_apt__os_id() {
  [[ -f /etc/os-release ]] || return 1
  # shellcheck source=/dev/null
  source /etc/os-release
  echo "${ID:-}"
}

mpm_scope_apt__probe_url_for_preset() {
  local preset=$1 probe
  probe=$(mpm_preset_yq apt "$preset" '.probe // ""' 2>/dev/null || true)
  [[ "$probe" == "null" ]] && probe=""
  if [[ -n "$probe" ]]; then
    printf '%s' "$probe"
    return 0
  fi
  case "$(mpm_scope_apt__os_id 2>/dev/null || true)" in
    debian) printf '%s' 'http://deb.debian.org/debian/' ;;
    *) printf '%s' 'http://archive.ubuntu.com/ubuntu/' ;;
  esac
}

mpm_scope_apt__inferred_preset() {
  local k v pr=""
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == preset ]] && pr="$v"
  done < <(mpm_scope_apt_get_state 2>/dev/null)
  printf '%s' "$pr"
}

mpm_scope_apt__run_live_apt_get_update() {
  local -a cmd=()
  if command -v timeout >/dev/null 2>&1; then
    cmd=(timeout 120 apt-get -qq -o Debug::NoLocking=true update)
  else
    cmd=(apt-get -qq -o Debug::NoLocking=true update)
  fi
  if mpm_is_root; then
    echo "mpm(apt-test): running: $(printf '%q ' "${cmd[@]}")" >&2
    "${cmd[@]}" >/dev/null 2>&1
    return $?
  fi
  echo "mpm(apt-test): running: $(printf '%q ' sudo "${cmd[@]}")" >&2
  mpm_sudo "${cmd[@]}" >/dev/null 2>&1
  return $?
}

mpm_scope_apt__test_preset_live() {
  local preset=$1 rc
  echo "mpm(apt-test): ${preset} matches inferred → apt-get update" >&2
  if [[ -n "${MPM_APT_SKIP_LIVE_TEST:-}" ]]; then
    echo "mpm(apt-test): MPM_APT_SKIP_LIVE_TEST set — skip live apt-get" >&2
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "mpm(apt-test): apt-get not found" >&2
    return 1
  fi
  mpm_is_root || mpm_sudo_cache_credentials || {
    echo "mpm(apt-test): sudo required for live apt-get update" >&2
    return 1
  }
  set +e
  mpm_scope_apt__run_live_apt_get_update
  rc=$?
  set -e
  if [[ "$rc" -eq 124 ]]; then
    echo "mpm(apt-test): FAIL apt-get update timed out (120s)" >&2
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "mpm(apt-test): FAIL apt-get update (exit ${rc}); check proxy and apt sources" >&2
    return 1
  fi
  printf 'apt/%s: OK (apt-get update)\n' "$preset"
  return 0
}

mpm_scope_apt_test_preset() {
  local preset=$1 inferred hp target
  mpm_require_yq || return 1
  case "$preset" in
    proxy|direct) ;;
    *)
      echo "mpm(apt): unknown preset: ${preset}" >&2
      return 1
      ;;
  esac
  hp=$(mpm_preset_resolve_field apt "$preset" '.http_proxy // ""')
  [[ "$hp" == "null" ]] && hp=""
  if [[ "$preset" == "direct" ]] || [[ -z "$hp" ]]; then
    local path
    path=$(mpm_scope_apt_conf_path)
    if [[ -f "$path" ]] && grep -q 'mpm-managed' "$path" 2>/dev/null; then
      echo "mpm(apt-test): direct — mpm apt proxy file still present at ${path}" >&2
      return 1
    fi
    echo "mpm(apt-test): direct — no mpm apt proxy config" >&2
    return 0
  fi
  target=$(mpm_scope_apt__probe_url_for_preset "$preset")
  inferred=$(mpm_scope_apt__inferred_preset)
  if [[ -n "$inferred" && "$inferred" == "$preset" ]]; then
    mpm_scope_apt__test_preset_live "$preset" || return 1
    return 0
  fi
  echo "mpm(apt-test): ${preset} is not inferred (${inferred:-none}) → HTTP probe only (curl --proxy)" >&2
  echo "mpm(apt-test): running: curl -sS -g -o /dev/null -w '%{http_code} %{time_total}' --proxy $(printf '%q' "$hp") --connect-timeout 5 -m 25 -L $(printf '%q' "$target")" >&2
  mpm_http_probe_via_proxy "$hp" "$target" "apt/${preset}"
}
