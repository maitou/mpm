# shellcheck shell=bash
# Paths, backups, YAML reads, state.json, HTTP/proxy probes.

: "${MPM_PREFIX:?MPM_PREFIX is not set}"

# Canonical absolute prefix (subshell cd — do not change caller cwd when sourced).
if [[ -d "${MPM_PREFIX}/share/profiles" ]]; then
  MPM_PREFIX=$(cd "$MPM_PREFIX" && pwd -P) || true
  export MPM_PREFIX
fi
MPM_SHARE_PROFILES="${MPM_PREFIX}/share/profiles"
MPM_JSON_SCHEMA_VERSION=4

mpm_config_dir() {
  echo "${XDG_CONFIG_HOME:-$HOME/.config}/mpm"
}

mpm_state_json_path() {
  echo "$(mpm_config_dir)/state.json"
}

# Resolve yq when not on PATH (e.g. sudo drops ~/.local/bin; SUDO_USER still has ~/.local/bin/yq).
# Same order as mrm, plus id -unr when SUDO_USER is unset (some sudo/secure_path setups).
mpm_find_yq_executable() {
  local cand h u
  for cand in /usr/local/bin/yq /usr/bin/yq /snap/bin/yq; do
    [[ -x "$cand" ]] && {
      printf '%s\n' "$cand"
      return 0
    }
  done
  for u in "${SUDO_USER:-}" "$(id -unr 2>/dev/null)"; do
    [[ -n "$u" && "$u" != "root" ]] || continue
    if h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6); then
      cand="${h}/.local/bin/yq"
      [[ -x "$cand" ]] && {
        printf '%s\n' "$cand"
        return 0
      }
    fi
  done
  cand="${HOME}/.local/bin/yq"
  [[ -x "$cand" ]] && {
    printf '%s\n' "$cand"
    return 0
  }
  return 1
}

# Prepend PATH so `yq` resolves (sudo often omits ~/.local/bin; use SUDO_USER's tree when set).
mpm_ensure_yq_on_path() {
  command -v yq >/dev/null 2>&1 && return 0
  local yq_path
  yq_path=$(mpm_find_yq_executable) || return 0
  export PATH="$(dirname "$yq_path"):${PATH}"
}

mpm_require_yq() {
  mpm_ensure_yq_on_path
  if command -v yq >/dev/null 2>&1; then
    return 0
  fi
  echo "mpm: install yq (https://github.com/mikefarah/yq) to read groups.yaml and presets/*.yaml." >&2
  echo "mpm: hint: with sudo, put yq on root's PATH or install to /usr/local/bin; mrm-style lookup uses SUDO_USER then id -unr home ~/.local/bin, then HOME/.local/bin." >&2
  return 1
}

# shellcheck source=resolvers/default_ip.sh
source "${MPM_PREFIX}/lib/resolvers/default_ip.sh"
# shellcheck source=resolvers/host_ip.sh
source "${MPM_PREFIX}/lib/resolvers/host_ip.sh"
# shellcheck source=resolvers/wsl_host_ip.sh
source "${MPM_PREFIX}/lib/resolvers/wsl_host_ip.sh"
# shellcheck source=template.sh
source "${MPM_PREFIX}/lib/template.sh"
# shellcheck source=runtime_override.sh
source "${MPM_PREFIX}/lib/runtime_override.sh"

mpm_groups_yaml() {
  printf '%s' "${MPM_SHARE_PROFILES}/groups.yaml"
}

mpm_group_exists() {
  local g=$1 gf
  mpm_require_yq || return 1
  gf=$(mpm_groups_yaml)
  if [[ ! -f "$gf" || ! -r "$gf" ]]; then
    echo "mpm: groups.yaml missing or not readable: ${gf} (MPM_PREFIX=${MPM_PREFIX})" >&2
    return 1
  fi
  yq -e "has(\"${g}\")" "$gf" >/dev/null 2>&1
}

mpm_group_preset() {
  local group=$1 scope=$2 gf
  mpm_require_yq || return 1
  gf=$(mpm_groups_yaml)
  if [[ ! -f "$gf" || ! -r "$gf" ]]; then
    echo "mpm: groups.yaml missing or not readable: ${gf} (MPM_PREFIX=${MPM_PREFIX})" >&2
    return 1
  fi
  yq -r ".[\"${group}\"][\"${scope}\"] // \"\"" "$gf"
}

mpm_preset_file() {
  printf '%s' "${MPM_SHARE_PROFILES}/presets/${1}.yaml"
}

mpm_preset_yq() {
  local scope=$1 preset=$2 yqpath=$3
  mpm_require_yq || return 1
  local f
  f=$(mpm_preset_file "$scope")
  if [[ ! -e "$f" ]]; then
    echo "mpm: preset file not found: ${f} (MPM_PREFIX=${MPM_PREFIX})" >&2
    return 1
  fi
  if [[ ! -f "$f" ]]; then
    echo "mpm: preset path is not a regular file: ${f}" >&2
    return 1
  fi
  if [[ ! -r "$f" ]]; then
    echo "mpm: preset file not readable under this user (e.g. sudo root cannot read the repo path): ${f}" >&2
    return 1
  fi
  yq -r ".[\"${preset}\"]${yqpath}" "$f" || {
    echo "mpm: yq failed on ${f} for preset ${preset} path ${yqpath}" >&2
    return 1
  }
}

mpm_preset_has() {
  local scope=$1 preset=$2
  mpm_require_yq || return 1
  local f
  f=$(mpm_preset_file "$scope")
  if [[ ! -e "$f" ]]; then
    echo "mpm: preset file not found: ${f} (MPM_PREFIX=${MPM_PREFIX})" >&2
    return 1
  fi
  if [[ ! -f "$f" || ! -r "$f" ]]; then
    echo "mpm: preset file missing or not readable: ${f}" >&2
    return 1
  fi
  yq -e "has(\"${preset}\")" "$f" >/dev/null 2>&1
}

# Resolve preset field; expand ${VAR} for proxy fields; apply overrides.yaml when loaded.
mpm_preset_resolve_field() {
  local scope=$1 preset=$2 yqpath=$3 raw basepath expanded
  raw=$(mpm_preset_yq "$scope" "$preset" "$yqpath") || return 1
  [[ "$raw" == "null" ]] && raw=""
  basepath=${yqpath%% *}
  case "$basepath" in
    .http_proxy | .https_proxy | .all_proxy)
      expanded=$(mpm_template_expand "$raw" "$scope" "$preset") || return 1
      mpm_runtime_override_apply_proxy_url "$scope" "$preset" "$basepath" "$expanded"
      ;;
    .no_proxy)
      expanded=$raw
      if [[ "$raw" == *'${'* ]]; then
        expanded=$(mpm_template_expand "$raw" "$scope" "$preset") || return 1
      fi
      mpm_runtime_override_apply_no_proxy "$scope" "$preset" "$expanded"
      ;;
    *)
      printf '%s' "$raw"
      ;;
  esac
}

# Backup before write; prints backup path on stdout when created.
mpm_backup_file() {
  local f=$1
  [[ -e "$f" ]] || return 0
  local bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
  if mpm_needs_sudo_for_path "$f"; then
    mpm_sudo cp -a "$f" "$bak"
  else
    cp -a "$f" "$bak"
  fi
  echo "$bak"
}

# Write content to dest (mktemp in $TMPDIR, then mv; sudo when dest is under /etc etc.).
mpm_write_file() {
  local dest=$1 content=$2
  local tmp parent
  tmp=$(mktemp)
  printf '%s' "$content" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  parent=$(dirname "$dest")
  if mpm_needs_sudo_for_path "$dest"; then
    mpm_sudo mkdir -p "$parent" || {
      rm -f "$tmp"
      return 1
    }
    mpm_sudo mv "$tmp" "$dest" || {
      rm -f "$tmp"
      return 1
    }
    mpm_sudo chmod 0644 "$dest"
  else
    mkdir -p "$parent" || {
      rm -f "$tmp"
      return 1
    }
    mv "$tmp" "$dest" || {
      rm -f "$tmp"
      return 1
    }
    chmod 0644 "$dest"
  fi
  return 0
}

mpm_is_root() {
  [[ "${EUID:-0}" -eq 0 ]]
}

# True when path is under system trees and the current user is not root.
mpm_needs_sudo_for_path() {
  local path=$1
  mpm_is_root && return 1
  case "$path" in
    /etc/* | /usr/local/* | /usr/* | /var/lib/*) return 0 ;;
  esac
  return 1
}

# Cache sudo credentials once before batch privileged operations (sudo -v).
mpm_sudo_cache_credentials() {
  mpm_is_root && return 0
  if sudo -n -v 2>/dev/null; then
    return 0
  fi
  if [[ -t 0 ]]; then
    sudo -v
    return $?
  fi
  echo "mpm: sudo credentials required (run: sudo -v, or configure NOPASSWD for unattended use)" >&2
  return 1
}

# Run command via sudo when not root; no-op as root.
mpm_sudo() {
  if mpm_is_root; then
    "$@"
    return $?
  fi
  mpm_sudo_cache_credentials || return 1
  sudo "$@"
}

# apt/docker/k3s scopes invoke internal sudo when not root.
mpm_scope_needs_sudo() {
  local id=$1
  case "$id" in
    apt | docker | k3s)
      mpm_is_root && return 1
      return 0
      ;;
  esac
  return 1
}

mpm_use_needs_sudo() {
  local id
  for id in "$@"; do
    mpm_scope_needs_sudo "$id" && return 0
  done
  return 1
}

mpm_require_jq_optional() {
  command -v jq >/dev/null 2>&1
}

mpm_state_touch_scope() {
  local scope=$1 preset=$2 target=$3
  mpm_require_jq_optional || return 0
  local f
  f=$(mpm_state_json_path)
  mkdir -p "$(dirname "$f")"
  [[ -f "$f" ]] || echo '{"version":1,"scopes":{},"last_op":{}}' >"$f"
  local tmp
  tmp=$(mktemp)
  if jq --arg s "$scope" --arg p "$preset" --arg t "$target" \
    '.scopes[$s] = {"preset": $p} | .last_op = {"verb":"use","target": $t}' "$f" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}

# False when preset must not appear in mpm ls (internal fixtures, test* ids).
mpm_preset_is_public() {
  local scope=$1 pid=$2
  local f="${MPM_SHARE_PROFILES}/presets/${scope}.yaml"
  [[ -f "$f" ]] || return 1
  [[ "$pid" == test* ]] && return 1
  yq -e ".[\"${pid}\"].internal == true" "$f" >/dev/null 2>&1 && return 1
  return 0
}

mpm_preset_table_lines() {
  local scope=$1
  mpm_require_yq || return 1
  local f="${MPM_SHARE_PROFILES}/presets/${scope}.yaml"
  [[ -f "$f" ]] || return 0
  local pid summ hint
  while IFS= read -r pid; do
    [[ -z "$pid" || "$pid" == "null" ]] && continue
    mpm_preset_is_public "$scope" "$pid" || continue
    summ=$(yq -r ".[\"${pid}\"].summary // \"\"" "$f")
    hint=$(yq -r ".[\"${pid}\"].probe // .[\"${pid}\"].http_proxy // \"\"" "$f")
    printf '%s\t%s\t%s\n' "$pid" "$summ" "$hint"
  done < <(yq -r 'keys | .[]' "$f")
}

# Direct HTTP(S) reachability (no proxy). 2xx/3xx success; needs curl.
mpm_http_probe() {
  local url=$1 label=$2
  local _mpm_probe_saved_e=0
  [[ $- == *e* ]] && _mpm_probe_saved_e=1
  trap 'if [[ "${_mpm_probe_saved_e}" == "1" ]]; then set -e; else set +e; fi; trap - RETURN' RETURN

  if [[ -z "$url" || "$url" == "null" ]]; then
    printf '%s: (no probe URL — skip)\n' "$label"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "mpm: ${label}: curl is required for test" >&2
    return 1
  fi
  local out code sec
  set +e
  out=$(curl -sS -g -o /dev/null -w "%{http_code} %{time_total}" --connect-timeout 3 -m 20 -L "$url" 2>/dev/null)
  local cr=$?
  if [[ "$cr" -ne 0 || -z "$out" ]]; then
    printf '%s: FAIL (curl err=%s) %s\n' "$label" "${cr:-?}" "$url"
    return 1
  fi
  code=${out%% *}
  sec=${out#* }
  if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
    printf '%s: OK http=%s time=%ss\n' "$label" "$code" "$sec"
    return 0
  fi
  printf '%s: FAIL http=%s time=%ss %s\n' "$label" "$code" "$sec" "$url"
  return 1
}

# Use HTTP proxy for a GET to target_url (CONNECT tunnel for HTTPS). needs curl.
mpm_http_probe_via_proxy() {
  local proxy_url=$1 target_url=$2 label=$3
  local _mpm_probe_saved_e=0
  [[ $- == *e* ]] && _mpm_probe_saved_e=1
  trap 'if [[ "${_mpm_probe_saved_e}" == "1" ]]; then set -e; else set +e; fi; trap - RETURN' RETURN

  if [[ -z "$proxy_url" || "$proxy_url" == "null" ]]; then
    printf '%s: (no proxy URL — skip)\n' "$label"
    return 0
  fi
  if [[ -z "$target_url" || "$target_url" == "null" ]]; then
    printf '%s: (no target URL — skip)\n' "$label"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "mpm: ${label}: curl is required for test" >&2
    return 1
  fi
  local out code sec
  set +e
  out=$(curl -sS -g -o /dev/null -w "%{http_code} %{time_total}" --proxy "$proxy_url" --connect-timeout 5 -m 25 -L "$target_url" 2>/dev/null)
  local cr=$?
  if [[ "$cr" -ne 0 || -z "$out" ]]; then
    printf '%s: FAIL (curl via proxy err=%s) proxy=%s target=%s\n' "$label" "${cr:-?}" "$proxy_url" "$target_url"
    return 1
  fi
  code=${out%% *}
  sec=${out#* }
  if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
    printf '%s: OK http=%s time=%ss (via %s)\n' "$label" "$code" "$sec" "$proxy_url"
    return 0
  fi
  printf '%s: FAIL http=%s time=%ss proxy=%s target=%s\n' "$label" "$code" "$sec" "$proxy_url" "$target_url"
  return 1
}

# curl using http(s)_proxy / all_proxy / no_proxy env (simulates typical shell exports). 2xx/3xx ok.
mpm_http_probe_with_proxy_env() {
  local hp=$1 hs=$2 ap=$3 np=$4 url=$5 label=$6
  local _mpm_probe_saved_e=0
  [[ $- == *e* ]] && _mpm_probe_saved_e=1
  trap 'if [[ "${_mpm_probe_saved_e}" == "1" ]]; then set -e; else set +e; fi; trap - RETURN' RETURN

  if [[ -z "$url" || "$url" == "null" ]]; then
    printf '%s: (no target URL — skip)\n' "$label"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "mpm: ${label}: curl is required for test" >&2
    return 1
  fi
  local out code sec
  set +e
  out=$(
    env \
      http_proxy="${hp}" https_proxy="${hs}" all_proxy="${ap}" no_proxy="${np}" \
      HTTP_PROXY="${hp}" HTTPS_PROXY="${hs}" ALL_PROXY="${ap}" NO_PROXY="${np}" \
      curl -sS -g -o /dev/null -w "%{http_code} %{time_total}" --connect-timeout 5 -m 25 -L "$url" 2>/dev/null
  )
  local cr=$?
  if [[ "$cr" -ne 0 || -z "$out" ]]; then
    printf '%s: FAIL (curl with proxy env err=%s) target=%s\n' "$label" "${cr:-?}" "$url"
    return 1
  fi
  code=${out%% *}
  sec=${out#* }
  if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
    printf '%s: OK http=%s time=%ss (http_proxy env)\n' "$label" "$code" "$sec"
    return 0
  fi
  printf '%s: FAIL http=%s time=%ss target=%s\n' "$label" "$code" "$sec" "$url"
  return 1
}

# stdout: sh lines to unset proxy vars (eval in current shell after mpm use direct-group).
mpm_emit_proxy_unsets_sh() {
  printf '%s\n' \
    'unset http_proxy https_proxy all_proxy no_proxy' \
    'unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY'
}

# stdout: export http(s)_proxy / all_proxy / no_proxy (lower + upper) for eval. $1=scope $2=preset id.
mpm_emit_proxy_exports_sh() {
  local sc=$1 pid=$2 hp hs ap np
  mpm_require_yq || return 1
  [[ "$pid" == "direct" || -z "$pid" ]] && {
    mpm_emit_proxy_unsets_sh
    return 0
  }
  hp=$(mpm_preset_resolve_field "$sc" "$pid" '.http_proxy // ""') || return 1
  [[ "$hp" == "null" ]] && hp=""
  hs=$(mpm_preset_resolve_field "$sc" "$pid" '.https_proxy // ""') || return 1
  [[ "$hs" == "null" ]] && hs=""
  ap=$(mpm_preset_resolve_field "$sc" "$pid" '.all_proxy // ""') || return 1
  [[ "$ap" == "null" ]] && ap=""
  np=$(mpm_preset_resolve_field "$sc" "$pid" '.no_proxy // ""') || return 1
  [[ "$np" == "null" ]] && np=""
  if [[ -z "$hp" && -z "$hs" && -z "$ap" ]]; then
    mpm_emit_proxy_unsets_sh
    return 0
  fi
  printf 'export http_proxy=%q\nexport https_proxy=%q\nexport all_proxy=%q\nexport no_proxy=%q\n' "$hp" "$hs" "$ap" "$np"
  printf 'export HTTP_PROXY=%q\nexport HTTPS_PROXY=%q\nexport ALL_PROXY=%q\nexport NO_PROXY=%q\n' "$hp" "$hs" "$ap" "$np"
}
