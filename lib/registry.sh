# shellcheck shell=bash
# Ordered scope list; scheduler runs use in this order.
# apt is first: system-level apt proxy before shell ~/.bashrc (scripts often apt right after env setup).
# docker → kind → k3s: Engine proxy before kind node drop-ins; k3s is separate host systemd stack.
MPM_SCOPE_REGISTRY=(apt shell docker kind k3s go)

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
