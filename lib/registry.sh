# shellcheck shell=bash
# Ordered scope list; scheduler runs use in this order.
MPM_SCOPE_REGISTRY=(shell docker k3s go)

mpm_registry_list() {
  printf '%s\n' "${MPM_SCOPE_REGISTRY[@]}"
}

# Comma-separated scope ids for a group, in registry order (keys from groups.yaml).
mpm_group_scope_ids_ordered_csv() {
  local group=$1
  mpm_group_exists "$group" || return 1
  mpm_require_yq || return 1
  local keys=() key sid
  while IFS= read -r key; do
    [[ -z "$key" || "$key" == "null" ]] && continue
    keys+=("$key")
  done < <(yq -r ".[\"${group}\"] | keys | .[]" "${MPM_SHARE_PROFILES}/groups.yaml")
  local out=()
  while IFS= read -r sid; do
    local k
    for k in "${keys[@]}"; do
      [[ "$sid" == "$k" ]] && out+=("$sid")
    done
  done < <(mpm_registry_list)
  (IFS=','; echo "${out[*]}")
}
