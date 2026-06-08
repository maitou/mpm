# shellcheck shell=bash
# Preset URL template expansion: ${DEFAULT_IP}, ${HOST_IP}, ${GATEWAY_IP}, ${WSL_HOST_IP}, optional preset params.

declare -gA MPM_TEMPLATE_MEMO=()

mpm_template_builtin_names_csv() {
  printf '%s' 'DEFAULT_IP,HOST_IP,GATEWAY_IP,WSL_HOST_IP'
}

mpm_template_is_builtin_name() {
  local name=$1
  case "$name" in
    DEFAULT_IP | HOST_IP | GATEWAY_IP | WSL_HOST_IP) return 0 ;;
    *) return 1 ;;
  esac
}

mpm_template_is_builtin_token_value() {
  mpm_template_is_builtin_name "$1"
}

mpm_template_memo_get() {
  local key=$1
  [[ -n "${MPM_TEMPLATE_MEMO[$key]+x}" ]] || return 1
  printf '%s' "${MPM_TEMPLATE_MEMO[$key]}"
}

mpm_template_memo_set() {
  MPM_TEMPLATE_MEMO[$1]=$2
}

mpm_template_resolve_builtin() {
  local name=$1 scope=$2 memo_key val fn
  memo_key="${scope}:${name}"
  if mpm_template_memo_get "$memo_key"; then
    return 0
  fi
  case "$name" in
    DEFAULT_IP) val=$(mpm_resolve_default_ip) ;;
    HOST_IP) val=$(mpm_resolve_host_ip) || return 1 ;;
    GATEWAY_IP)
      fn="mpm_scope_${scope}_resolve_gateway_ip"
      if declare -f "$fn" >/dev/null 2>&1; then
        val=$("$fn") || return 1
      else
        val=$(mpm_resolve_default_ip)
      fi
      ;;
    WSL_HOST_IP) val=$(mpm_resolve_wsl_host_ip) || return 1 ;;
    *) return 1 ;;
  esac
  mpm_template_memo_set "$memo_key" "$val"
  printf '%s' "$val"
}

# Read .[preset].params.* from YAML; reject keys that collide with builtins.
mpm_template_preset_param() {
  local scope=$1 preset=$2 key=$3
  mpm_require_yq || return 1
  local f val
  f=$(mpm_preset_file "$scope")
  if mpm_template_is_builtin_name "$key"; then
    echo "mpm: preset ${scope}/${preset} params must not override builtin ${key}" >&2
    return 1
  fi
  val=$(yq -r ".[\"${preset}\"].params[\"${key}\"] // \"\"" "$f" 2>/dev/null) || return 1
  [[ "$val" == "null" ]] && val=""
  [[ -n "$val" ]] || return 1
  printf '%s' "$val"
}

mpm_template_resolve_var() {
  local name=$1 scope=$2 preset=$3 memo_key val
  memo_key="${scope}:param:${name}"
  if mpm_template_memo_get "$memo_key"; then
    return 0
  fi
  if mpm_template_is_builtin_name "$name"; then
    mpm_template_resolve_builtin "$name" "$scope"
    return $?
  fi
  if val=$(mpm_template_preset_param "$scope" "$preset" "$name"); then
    if mpm_template_is_builtin_token_value "$val"; then
      mpm_template_resolve_builtin "$val" "$scope"
      return $?
    fi
    mpm_template_memo_set "$memo_key" "$val"
    printf '%s' "$val"
    return 0
  fi
  echo "mpm: unknown template variable \${${name}} in preset ${scope}/${preset}" >&2
  echo "mpm: builtins: $(mpm_template_builtin_names_csv); add custom keys under params: in preset YAML" >&2
  return 1
}

# Expand all ${VAR} in $1. VAR = [A-Z][A-Z0-9_]*. No ${ → passthrough.
mpm_template_expand() {
  local raw=$1 scope=$2 preset=$3
  local out="$raw" var val before
  if [[ "$raw" != *'${'* ]]; then
    printf '%s' "$raw"
    return 0
  fi
  out="$raw"
  while [[ "$out" =~ \$\{([A-Z][A-Z0-9_]+)\} ]]; do
    var="${BASH_REMATCH[1]}"
    val=$(mpm_template_resolve_var "$var" "$scope" "$preset") || return 1
    before="$out"
    out="${out//\$\{${var}\}/$val}"
    if [[ "$out" == "$before" ]]; then
      echo "mpm: template expansion stuck on \${${var}}" >&2
      return 1
    fi
  done
  if [[ "$out" == *'${'* ]]; then
    echo "mpm: unresolved template placeholders remain in: ${out}" >&2
    return 1
  fi
  printf '%s' "$out"
}

mpm_template_clear_memo() {
  MPM_TEMPLATE_MEMO=()
}
