# shellcheck shell=bash
# Overrides: MPM_OVERRIDES_FILE > /etc/mpm/overrides.yaml > preset defaults.

MPM_SYSTEM_OVERRIDES_FILE="${MPM_SYSTEM_OVERRIDES_FILE:-/etc/mpm/overrides.yaml}"
MPM_OVERRIDE_LOADED=0
MPM_OVERRIDE_FILE=""
declare -gA MPM_OVERRIDE_DEFAULTS=()
declare -gA MPM_OVERRIDE_SCOPE=()

mpm_runtime_override_config_path() {
  if [[ -n "${MPM_OVERRIDES_FILE:-}" ]]; then
    printf '%s' "$MPM_OVERRIDES_FILE"
    return 0
  fi
  printf '%s' "$MPM_SYSTEM_OVERRIDES_FILE"
}

mpm_runtime_override_is_builtin_token() {
  case "$1" in
    DEFAULT_IP | HOST_IP | GATEWAY_IP | WSL_HOST_IP) return 0 ;;
    *) return 1 ;;
  esac
}

mpm_runtime_override_validate_port() {
  local port=$1 ctx=$2
  [[ "$port" =~ ^[0-9]+$ ]] || {
    echo "mpm: overrides ${ctx}: invalid proxy_port (must be 1-65535): ${port}" >&2
    return 1
  }
  local n=$port
  if [[ "$n" -lt 1 || "$n" -gt 65535 ]]; then
    echo "mpm: overrides ${ctx}: invalid proxy_port (must be 1-65535): ${port}" >&2
    return 1
  fi
  return 0
}

mpm_runtime_override_resolve_host_token() {
  local scope=$1 token=$2
  mpm_template_resolve_builtin "$token" "$scope"
}

mpm_runtime_override_scope_registered() {
  local scope=$1 rid ok=0
  while IFS= read -r rid; do
    [[ "$rid" == "$scope" ]] && ok=1
  done < <(mpm_registry_list 2>/dev/null)
  [[ "$ok" -eq 1 ]]
}

mpm_runtime_override_store_field() {
  local layer=$1 scope=$2 field=$3 val=$4 ctx
  [[ -n "$val" && "$val" != "null" ]] || return 0
  ctx="${layer}"
  [[ -n "$scope" ]] && ctx="${layer}.${scope}"
  case "$field" in
    proxy_port)
      mpm_runtime_override_validate_port "$val" "$ctx" || return 1
      ;;
    proxy_host)
      if mpm_runtime_override_is_builtin_token "$val"; then
        :
      elif [[ "$val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        :
      elif [[ "$val" =~ ^[A-Za-z0-9._-]+$ ]]; then
        :
      else
        echo "mpm: overrides ${ctx}: invalid proxy_host: ${val}" >&2
        return 1
      fi
      ;;
    no_proxy) ;;
    *)
      echo "mpm: overrides ${ctx}: unknown field ${field}" >&2
      return 1
      ;;
  esac
  if [[ "$layer" == "defaults" ]]; then
    MPM_OVERRIDE_DEFAULTS["${field}"]=$val
  else
    MPM_OVERRIDE_SCOPE["${scope}:${field}"]=$val
  fi
  return 0
}

mpm_runtime_override_load_config() {
  local f scope field val
  [[ "$MPM_OVERRIDE_LOADED" == "1" ]] && return 0
  MPM_OVERRIDE_LOADED=1
  f=$(mpm_runtime_override_config_path)
  MPM_OVERRIDE_FILE=$f
  [[ -f "$f" ]] || return 0
  mpm_require_yq || return 1
  if ! yq -e 'true' "$f" >/dev/null 2>&1; then
    echo "mpm: overrides file invalid YAML: ${f}" >&2
    return 1
  fi
  for field in proxy_host proxy_port no_proxy; do
    val=$(yq -r ".defaults.${field} // \"\"" "$f" 2>/dev/null) || return 1
    mpm_runtime_override_store_field defaults "" "$field" "$val" || return 1
  done
  while IFS= read -r scope; do
    [[ -z "$scope" || "$scope" == "null" ]] && continue
    if ! mpm_runtime_override_scope_registered "$scope"; then
      echo "mpm: overrides: unknown scope '${scope}' (ignored)" >&2
      continue
    fi
    for field in proxy_host proxy_port no_proxy; do
      val=$(yq -r ".scopes[\"${scope}\"].${field} // \"\"" "$f" 2>/dev/null) || return 1
      mpm_runtime_override_store_field scope "$scope" "$field" "$val" || return 1
    done
  done < <(yq -r '.scopes // {} | keys | .[]' "$f" 2>/dev/null)
  return 0
}

mpm_runtime_override_effective_raw() {
  local scope=$1 field=$2
  if [[ -n "${MPM_OVERRIDE_SCOPE[${scope}:${field}]+x}" ]]; then
    printf '%s' "${MPM_OVERRIDE_SCOPE[${scope}:${field}]}"
    return 0
  fi
  if [[ -n "${MPM_OVERRIDE_DEFAULTS[${field}]+x}" ]]; then
    printf '%s' "${MPM_OVERRIDE_DEFAULTS[${field}]}"
    return 0
  fi
  return 1
}

mpm_runtime_override_has_any() {
  [[ "$MPM_OVERRIDE_LOADED" == "1" && -f "$MPM_OVERRIDE_FILE" ]] || return 1
  [[ ${#MPM_OVERRIDE_DEFAULTS[@]} -gt 0 || ${#MPM_OVERRIDE_SCOPE[@]} -gt 0 ]]
}

mpm_runtime_override_active_fields() {
  local scope=$1 field
  for field in proxy_host proxy_port no_proxy; do
    mpm_runtime_override_effective_raw "$scope" "$field" && printf '%s\n' "$field"
  done
}

mpm_runtime_override_parse_proxy_url() {
  local url=$1
  local _scheme _host _port
  if [[ "$url" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://([^:/]+):([0-9]+)$ ]]; then
    _scheme="${BASH_REMATCH[1]}"
    _host="${BASH_REMATCH[2]}"
    _port="${BASH_REMATCH[3]}"
    printf '%s\n%s\n%s' "$_scheme" "$_host" "$_port"
    return 0
  fi
  return 1
}

mpm_runtime_override_apply_proxy_url() {
  local scope=$1 preset=$2 _field=$3 url=$4
  local host port scheme parsed_host parsed_port raw_host raw_port out
  [[ -n "$url" ]] || {
    printf '%s' "$url"
    return 0
  }
  [[ "$preset" != "direct" ]] || {
    printf '%s' "$url"
    return 0
  }
  mpm_runtime_override_has_any || {
    printf '%s' "$url"
    return 0
  }
  if [[ ! "$url" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://([^:/]+):([0-9]+)$ ]]; then
    printf '%s' "$url"
    return 0
  fi
  scheme="${BASH_REMATCH[1]}"
  parsed_host="${BASH_REMATCH[2]}"
  parsed_port="${BASH_REMATCH[3]}"
  host=$parsed_host
  port=$parsed_port
  if raw_host=$(mpm_runtime_override_effective_raw "$scope" proxy_host); then
    if mpm_runtime_override_is_builtin_token "$raw_host"; then
      host=$(mpm_runtime_override_resolve_host_token "$scope" "$raw_host") || return 1
    else
      host=$raw_host
    fi
  fi
  if raw_port=$(mpm_runtime_override_effective_raw "$scope" proxy_port); then
    port=$raw_port
  fi
  printf '%s://%s:%s' "$scheme" "$host" "$port"
}

mpm_runtime_override_apply_no_proxy() {
  local scope=$1 preset=$2 expanded=$3
  local raw
  [[ "$preset" != "direct" ]] || {
    printf '%s' "$expanded"
    return 0
  }
  if raw=$(mpm_runtime_override_effective_raw "$scope" no_proxy); then
    printf '%s' "$raw"
    return 0
  fi
  printf '%s' "$expanded"
}

mpm_runtime_override_format_detail_suffix() {
  local scope=$1
  local parts=() raw resolved f
  mpm_runtime_override_has_any || return 0
  if raw=$(mpm_runtime_override_effective_raw "$scope" proxy_host); then
    if mpm_runtime_override_is_builtin_token "$raw"; then
      resolved=$(mpm_runtime_override_resolve_host_token "$scope" "$raw" 2>/dev/null) || resolved="$raw"
      parts+=("host=${resolved}")
    else
      parts+=("host=${raw}")
    fi
  fi
  if raw=$(mpm_runtime_override_effective_raw "$scope" proxy_port); then
    parts+=("port=${raw}")
  fi
  if mpm_runtime_override_effective_raw "$scope" no_proxy >/dev/null; then
    parts+=("no_proxy=overridden")
  fi
  [[ ${#parts[@]} -eq 0 ]] && return 0
  local joined
  joined=$(IFS=','; echo "${parts[*]}")
  printf ' (overrides: %s)' "$joined"
}

mpm_runtime_override_json_object() {
  local scope=$1
  if ! mpm_runtime_override_has_any; then
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  local file host_raw host_res port np active_json
  file=$MPM_OVERRIDE_FILE
  host_raw=$(mpm_runtime_override_effective_raw "$scope" proxy_host 2>/dev/null) || host_raw=""
  host_res=$host_raw
  if [[ -n "$host_raw" ]] && mpm_runtime_override_is_builtin_token "$host_raw"; then
    host_res=$(mpm_runtime_override_resolve_host_token "$scope" "$host_raw" 2>/dev/null) || host_res="$host_raw"
  fi
  port=$(mpm_runtime_override_effective_raw "$scope" proxy_port 2>/dev/null) || port=""
  np=$(mpm_runtime_override_effective_raw "$scope" no_proxy 2>/dev/null) || np=""
  active_json=$(mpm_runtime_override_active_fields "$scope" | jq -R . | jq -s .)
  jq -n \
    --arg file "$file" \
    --arg proxy_host "$host_res" \
    --arg proxy_host_token "$host_raw" \
    --arg proxy_port "$port" \
    --arg no_proxy "$np" \
    --argjson active_fields "$active_json" \
    '{file:$file,proxy_host:$proxy_host,proxy_host_token:$proxy_host_token,proxy_port:$proxy_port,no_proxy:$no_proxy,active_fields:$active_fields}'
}
