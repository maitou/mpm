# shellcheck shell=bash
# Kind node containers: containerd + kubelet systemd drop-ins via docker exec.

mpm_scope_kind_metadata() {
  cat <<'EOF'
title=Kind clusters (in-node containerd/kubelet proxy)
description=systemd drop-ins inside kind node Docker containers; requires docker CLI (docker group or sudo)
requires_root=0
EOF
}

mpm_scope_kind_requires_root() {
  echo 0
}

mpm_kind_docker_exec() {
  local node=$1
  shift
  mpm_kind_docker exec "$node" "$@"
}

# --- session caches (one mpm invocation; invalidate node file cache on write) ---
MPM_KIND_DOCKER_MODE=""
MPM_KIND_CLUSTERS_CACHE=()
MPM_KIND_CLUSTERS_CACHE_LOADED=0
MPM_KIND_RAW_CLUSTERS=()
declare -gA MPM_KIND_CLUSTER_NODES=()
MPM_KIND_TOPOLOGY_LOADED=0
MPM_KIND_PROXY_CACHE_KEY=""
declare -gA MPM_KIND_FILE_CACHE=()
declare -gA MPM_KIND_NO_PROXY_EXTRA_CACHE=()

mpm_scope_kind__cache_key_file() {
  printf '%s|%s' "$1" "$2"
}

mpm_scope_kind__invalidate_node_file_cache() {
  local node=$1 k
  for k in "${!MPM_KIND_FILE_CACHE[@]}"; do
    [[ "$k" == "${node}|"* ]] && unset 'MPM_KIND_FILE_CACHE[$k]'
  done
}

mpm_kind_docker() {
  case "${MPM_KIND_DOCKER_MODE:-}" in
    direct)
      docker "$@"
      return $?
      ;;
    sudo)
      if mpm_is_root; then
        docker "$@"
      else
        mpm_sudo docker "$@"
      fi
      return $?
      ;;
  esac
  if docker "$@" 2>/dev/null; then
    MPM_KIND_DOCKER_MODE=direct
    return 0
  fi
  if mpm_is_root; then
    MPM_KIND_DOCKER_MODE=sudo
    docker "$@"
    return $?
  fi
  MPM_KIND_DOCKER_MODE=sudo
  mpm_sudo docker "$@"
}

mpm_scope_kind_manifest_path() {
  if [[ -n "${MPM_KIND_MANIFEST:-}" ]]; then
    printf '%s' "$MPM_KIND_MANIFEST"
    return 0
  fi
  printf '%s/kind/manifest.yaml' "$(mpm_config_dir)"
}

mpm_scope_kind__managed_units() {
  printf '%s\n' containerd.service kubelet.service
}

mpm_scope_kind__fragment_dir() {
  local unit=$1
  echo "/etc/systemd/system/${unit}.d"
}

mpm_scope_kind__dropin_conf() {
  local unit=$1
  echo "$(mpm_scope_kind__fragment_dir "$unit")/mpm-proxy.conf"
}

mpm_scope_kind__envfile() {
  local unit=$1
  echo "$(mpm_scope_kind__fragment_dir "$unit")/mpm-proxy.env"
}

mpm_scope_kind_resolve_gateway_ip() {
  local gw net node
  # WSL + Windows-side proxy: kind nodes must reach the Windows host, not the kind docker bridge.
  if mpm_is_wsl 2>/dev/null; then
    if gw=$(mpm_resolve_wsl_host_ip 2>/dev/null); then
      printf '%s' "$gw"
      return 0
    fi
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "mpm(kind): docker CLI not found" >&2
    return 1
  fi
  net=${MPM_KIND_SHARED_NETWORK:-}
  if [[ -n "$net" ]]; then
    gw=$(mpm_kind_docker network inspect "$net" -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
    [[ -n "$gw" && "$gw" != "<no value>" ]] && {
      printf '%s' "$gw"
      return 0
    }
  fi
  gw=$(mpm_kind_docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
  [[ -n "$gw" && "$gw" != "<no value>" ]] && {
    printf '%s' "$gw"
    return 0
  }
  node=$(mpm_kind_docker ps --filter label=io.x-k8s.kind.role --format '{{.Names}}' 2>/dev/null | head -1)
  if [[ -n "$node" ]]; then
    gw=$(mpm_kind_docker_exec "$node" ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    [[ -n "$gw" ]] && {
      printf '%s' "$gw"
      return 0
    }
  fi
  gw=$(mpm_kind_docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
  [[ -n "$gw" && "$gw" != "<no value>" ]] && {
    printf '%s' "$gw"
    return 0
  }
  echo "mpm(kind): cannot resolve GATEWAY_IP; set overrides scopes.kind.proxy_host or MPM_KIND_SHARED_NETWORK" >&2
  return 1
}

mpm_scope_kind__ensure_topology() {
  local name cluster c part dup s
  [[ "$MPM_KIND_TOPOLOGY_LOADED" == "1" ]] && return 0
  MPM_KIND_RAW_CLUSTERS=()
  if [[ -n "${MPM_KIND_CLUSTERS:-}" ]]; then
    IFS=',' read -ra parts <<<"${MPM_KIND_CLUSTERS}"
    for part in "${parts[@]}"; do
      c=${part// /}
      [[ -z "$c" ]] && continue
      MPM_KIND_RAW_CLUSTERS+=("$c")
    done
  fi
  if command -v docker >/dev/null 2>&1; then
    while IFS=$'\t' read -r name cluster; do
      [[ -z "$name" || -z "$cluster" ]] && continue
      if [[ ${#MPM_KIND_RAW_CLUSTERS[@]} -gt 0 ]]; then
        dup=0
        for s in "${MPM_KIND_RAW_CLUSTERS[@]}"; do
          [[ "$s" == "$cluster" ]] && dup=1
        done
        [[ "$dup" -eq 0 ]] && continue
      fi
      MPM_KIND_CLUSTER_NODES["$cluster"]+="${name}"$'\n'
      dup=0
      for s in "${MPM_KIND_RAW_CLUSTERS[@]}"; do
        [[ "$s" == "$cluster" ]] && dup=1
      done
      [[ "$dup" -eq 0 ]] && MPM_KIND_RAW_CLUSTERS+=("$cluster")
    done < <(mpm_kind_docker ps --filter label=io.x-k8s.kind.cluster --format '{{.Names}}\t{{.Label "io.x-k8s.kind.cluster"}}' 2>/dev/null)
  elif [[ ${#MPM_KIND_RAW_CLUSTERS[@]} -eq 0 ]] && command -v kind >/dev/null 2>&1; then
    while IFS= read -r cluster; do
      [[ -z "$cluster" ]] && continue
      MPM_KIND_RAW_CLUSTERS+=("$cluster")
    done < <(kind get clusters 2>/dev/null)
  fi
  MPM_KIND_TOPOLOGY_LOADED=1
}

mpm_scope_kind__discover_clusters_raw() {
  local c part
  if [[ -n "${MPM_KIND_CLUSTERS:-}" ]]; then
    IFS=',' read -ra parts <<<"${MPM_KIND_CLUSTERS}"
    for part in "${parts[@]}"; do
      c=${part// /}
      [[ -n "$c" ]] && printf '%s\n' "$c"
    done
    return 0
  fi
  mpm_scope_kind__ensure_topology
  printf '%s\n' "${MPM_KIND_RAW_CLUSTERS[@]}"
}

mpm_scope_kind__discover_clusters() {
  local mode c
  if [[ "$MPM_KIND_CLUSTERS_CACHE_LOADED" == "1" ]]; then
    printf '%s\n' "${MPM_KIND_CLUSTERS_CACHE[@]}"
    return 0
  fi
  mode=$(mpm_runtime_override_kind_clusters_mode 2>/dev/null) || mode=all
  if [[ "$mode" == "none" ]]; then
    MPM_KIND_CLUSTERS_CACHE_LOADED=1
    return 0
  fi
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    if [[ "$mode" == "filter" ]]; then
      mpm_runtime_override_kind_cluster_in_whitelist "$c" || continue
    fi
    MPM_KIND_CLUSTERS_CACHE+=("$c")
    printf '%s\n' "$c"
  done < <(mpm_scope_kind__discover_clusters_raw)
  MPM_KIND_CLUSTERS_CACHE_LOADED=1
}

mpm_scope_kind__discover_nodes() {
  local cluster=$1 node
  mpm_scope_kind__ensure_topology
  while IFS= read -r node; do
    [[ -z "$node" ]] && continue
    printf '%s\n' "$node"
  done <<<"${MPM_KIND_CLUSTER_NODES[$cluster]:-}"
}

mpm_scope_kind__no_proxy_extra_for_node() {
  local node=$1
  local json line
  json=$(mpm_kind_docker inspect "$node" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null) || return 0
  command -v jq >/dev/null 2>&1 || return 0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == "null" ]] && continue
    printf '%s,' "$line"
  done < <(jq -r 'to_entries[] | .value.IPAMConfig.Subnet // empty' <<<"$json" 2>/dev/null)
}

mpm_scope_kind__merge_no_proxy() {
  local base=$1 extra=$2
  local combined="" parts=() p seen=() out=() dup s
  if [[ -n "$base" && -n "$extra" ]]; then
    combined="${base},${extra}"
  elif [[ -n "$base" ]]; then
    combined="$base"
  else
    combined="$extra"
  fi
  IFS=',' read -ra parts <<<"$combined"
  for p in "${parts[@]}"; do
    p=${p// /}
    [[ -z "$p" ]] && continue
    dup=0
    for s in "${seen[@]}"; do
      [[ "$s" == "$p" ]] && dup=1
    done
    [[ "$dup" -eq 1 ]] && continue
    seen+=("$p")
    out+=("$p")
  done
  (IFS=','; echo "${out[*]}")
}

mpm_scope_kind__resolve_proxy_url_for_cluster() {
  local preset=$1 cluster=$2 url=$3
  local scheme host port raw_host raw_port
  [[ -n "$url" ]] || {
    printf ''
    return 0
  }
  [[ "$url" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://([^:/]+):([0-9]+)$ ]] || {
    printf '%s' "$url"
    return 0
  }
  scheme="${BASH_REMATCH[1]}"
  host="${BASH_REMATCH[2]}"
  port="${BASH_REMATCH[3]}"
  if raw_host=$(mpm_runtime_override_kind_cluster_field "$cluster" proxy_host 2>/dev/null); then
    if mpm_runtime_override_is_builtin_token "$raw_host"; then
      host=$(mpm_runtime_override_resolve_host_token kind "$raw_host") || return 1
    else
      host=$raw_host
    fi
  fi
  if raw_port=$(mpm_runtime_override_kind_cluster_field "$cluster" proxy_port 2>/dev/null); then
    port=$raw_port
  fi
  printf '%s://%s:%s' "$scheme" "$host" "$port"
}

mpm_scope_kind__read_proxy_fields() {
  local preset=$1 cluster=$2
  mpm_require_yq || return 1
  MPM_KIND_HP=$(mpm_preset_resolve_field kind "$preset" '.http_proxy') || return 1
  MPM_KIND_HS=$(mpm_preset_resolve_field kind "$preset" '.https_proxy') || return 1
  MPM_KIND_AP=$(mpm_preset_resolve_field kind "$preset" '.all_proxy') || return 1
  MPM_KIND_NP=$(mpm_preset_resolve_field kind "$preset" '.no_proxy') || return 1
  [[ "$MPM_KIND_HP" == "null" ]] && MPM_KIND_HP=""
  [[ "$MPM_KIND_HS" == "null" ]] && MPM_KIND_HS=""
  [[ "$MPM_KIND_AP" == "null" ]] && MPM_KIND_AP=""
  [[ "$MPM_KIND_NP" == "null" ]] && MPM_KIND_NP=""
  if [[ -n "$cluster" && "$preset" != "direct" ]]; then
    MPM_KIND_HP=$(mpm_scope_kind__resolve_proxy_url_for_cluster "$preset" "$cluster" "$MPM_KIND_HP") || return 1
    MPM_KIND_HS=$(mpm_scope_kind__resolve_proxy_url_for_cluster "$preset" "$cluster" "$MPM_KIND_HS") || return 1
    if np=$(mpm_runtime_override_kind_cluster_field "$cluster" no_proxy 2>/dev/null); then
      MPM_KIND_NP=$np
    fi
  fi
  return 0
}

mpm_scope_kind__read_proxy_fields_memo() {
  local preset=$1 cluster=$2 key="${preset}|${cluster}|fields"
  if [[ "$MPM_KIND_PROXY_CACHE_KEY" == "$key" ]]; then
    return 0
  fi
  mpm_scope_kind__read_proxy_fields "$preset" "$cluster" || return 1
  MPM_KIND_PROXY_CACHE_KEY=$key
}

mpm_scope_kind__no_proxy_extra_for_node_cached() {
  local node=$1
  if [[ -n "${MPM_KIND_NO_PROXY_EXTRA_CACHE[$node]+x}" ]]; then
    printf '%s' "${MPM_KIND_NO_PROXY_EXTRA_CACHE[$node]}"
    return 0
  fi
  local extra
  extra=$(mpm_scope_kind__no_proxy_extra_for_node "$node")
  MPM_KIND_NO_PROXY_EXTRA_CACHE[$node]=$extra
  printf '%s' "$extra"
}

mpm_scope_kind__parse_prefetch_output() {
  local node=$1 out=$2 path buf rest
  rest=$out
  while [[ "$rest" == *'===MPM:'* ]]; do
    rest=${rest#*===MPM:}
    path=${rest%%===*}
    rest=${rest#"${path}==="}
    rest=${rest#$'\n'}
    if [[ "$rest" == *$'\n'===MPM:END===* ]]; then
      buf=${rest%%$'\n'===MPM:END===*}
      rest=${rest#*===MPM:END===}
    else
      buf=${rest%%===MPM:END===*}
      rest=${rest#*===MPM:END===}
    fi
    rest=${rest#$'\n'}
    MPM_KIND_FILE_CACHE["$(mpm_scope_kind__cache_key_file "$node" "$path")"]=$buf
  done
}

mpm_scope_kind__prefetch_node_proxy_files() {
  local node=$1 unit paths=() f script out
  [[ -n "${MPM_KIND_FILE_CACHE[${node}|__done__]+x}" ]] && return 0
  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    paths+=("$(mpm_scope_kind__envfile "$unit")")
    paths+=("$(mpm_scope_kind__dropin_conf "$unit")")
  done < <(mpm_scope_kind__managed_units)
  script=""
  for f in "${paths[@]}"; do
    script+='printf "===MPM:%s===\n" "'"$f"'"; cat "'"$f"'" 2>/dev/null || true; printf "\n===MPM:END===\n"; '
  done
  out=$(mpm_kind_docker_exec "$node" sh -c "$script" 2>/dev/null) || out=""
  if [[ "$out" == *'===MPM:'* ]]; then
    mpm_scope_kind__parse_prefetch_output "$node" "$out"
  else
    MPM_KIND_FILE_CACHE["${node}|__fallback__"]=1
  fi
  MPM_KIND_FILE_CACHE["${node}|__done__"]=1
}

mpm_scope_kind__read_container_file() {
  local node=$1 path=$2
  mpm_kind_docker_exec "$node" cat "$path" 2>/dev/null || true
}

mpm_scope_kind__read_container_file_cached() {
  local node=$1 path=$2 key content
  key=$(mpm_scope_kind__cache_key_file "$node" "$path")
  if [[ -n "${MPM_KIND_FILE_CACHE[$key]+x}" ]]; then
    printf '%s' "${MPM_KIND_FILE_CACHE[$key]}"
    return 0
  fi
  mpm_scope_kind__prefetch_node_proxy_files "$node"
  if [[ -n "${MPM_KIND_FILE_CACHE[$key]+x}" ]]; then
    printf '%s' "${MPM_KIND_FILE_CACHE[$key]}"
    return 0
  fi
  content=$(mpm_scope_kind__read_container_file "$node" "$path")
  MPM_KIND_FILE_CACHE[$key]=$content
  printf '%s' "$content"
}

mpm_scope_kind__render_envfile_body() {
  local hp=$1 hs=$2 np=$3
  cat <<EOF
# mpm-managed; remove with: mpm use direct-group --scopes=kind
HTTP_PROXY=${hp}
HTTPS_PROXY=${hs}
http_proxy=${hp}
https_proxy=${hs}
NO_PROXY=${np}
no_proxy=${np}
EOF
}

mpm_scope_kind__render_dropin_conf() {
  local unit=$1 envpath=$2
  cat <<EOF
# mpm-managed drop-in for ${unit}; safe to remove with: mpm use direct-group --scopes=kind
[Service]
EnvironmentFile=${envpath}
EOF
}

mpm_scope_kind__expected_env_body_for_unit() {
  local preset=$1 cluster=$2 node=$3 unit=$4
  mpm_scope_kind__read_proxy_fields_memo "$preset" "$cluster" || return 1
  if [[ "$preset" == "direct" ]] || [[ -z "$MPM_KIND_HP" && -z "$MPM_KIND_HS" ]]; then
    printf ''
    return 0
  fi
  local np=$MPM_KIND_NP
  if [[ -n "$node" ]]; then
    np=$(mpm_scope_kind__merge_no_proxy "$np" "$(mpm_scope_kind__no_proxy_extra_for_node_cached "$node")")
  fi
  mpm_scope_kind__render_envfile_body "$MPM_KIND_HP" "$MPM_KIND_HS" "$np"
}

mpm_scope_kind__expected_conf_for_unit() {
  local preset=$1 cluster=$2 unit=$3
  if [[ "$preset" == "direct" ]]; then
    printf ''
    return 0
  fi
  mpm_scope_kind__read_proxy_fields_memo "$preset" "$cluster" || return 1
  [[ -n "$MPM_KIND_HP" || -n "$MPM_KIND_HS" ]] || {
    printf ''
    return 0
  }
  mpm_scope_kind__render_dropin_conf "$unit" "$(mpm_scope_kind__envfile "$unit")"
}

mpm_scope_kind__write_container_file() {
  local node=$1 dest=$2 content=$3
  local tmp parent
  tmp=$(mktemp)
  printf '%s' "$content" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  parent=$(dirname "$dest")
  mpm_kind_docker_exec "$node" mkdir -p "$parent" || {
    rm -f "$tmp"
    return 1
  }
  mpm_kind_docker cp "$tmp" "${node}:${dest}" || {
    rm -f "$tmp"
    return 1
  }
  rm -f "$tmp"
  mpm_kind_docker_exec "$node" chmod 0644 "$dest" 2>/dev/null || true
  mpm_scope_kind__invalidate_node_file_cache "$node"
  return 0
}

mpm_scope_kind__remove_container_files() {
  local node=$1 ef=$2 cf=$3
  mpm_kind_docker_exec "$node" rm -f "$ef" "$cf" 2>/dev/null || true
  mpm_scope_kind__invalidate_node_file_cache "$node"
}

mpm_scope_kind__node_unit_state() {
  local node=$1 cluster=$2 unit=$3 want_env=$4 want_conf=$5
  local ef cf cur_env cur_conf
  ef=$(mpm_scope_kind__envfile "$unit")
  cf=$(mpm_scope_kind__dropin_conf "$unit")
  [[ -n "$want_env" && -n "$want_conf" ]] || {
    want_env=$(mpm_scope_kind__expected_env_body_for_unit proxy "$cluster" "$node" "$unit") || want_env=""
    want_conf=$(mpm_scope_kind__expected_conf_for_unit proxy "$cluster" "$unit") || want_conf=""
  }
  cur_env=$(mpm_scope_kind__read_container_file_cached "$node" "$ef")
  cur_conf=$(mpm_scope_kind__read_container_file_cached "$node" "$cf")
  if [[ -z "$cur_env" && -z "$cur_conf" ]]; then
    echo off
    return 0
  fi
  if [[ -n "$cur_env" ]] && ! grep -q "mpm-managed" <<<"$cur_env" 2>/dev/null; then
    echo unknown
    return 0
  fi
  if [[ -n "$cur_conf" ]] && ! grep -q "mpm-managed drop-in" <<<"$cur_conf" 2>/dev/null; then
    echo unknown
    return 0
  fi
  if [[ -n "$want_env" && "$cur_env" == "$want_env" && "$cur_conf" == "$want_conf" ]]; then
    echo on
    return 0
  fi
  if [[ -n "$cur_env" || -n "$cur_conf" ]]; then
    echo mixed
    return 0
  fi
  echo unknown
}

mpm_scope_kind__node_has_create_time_proxy_hint() {
  local node=$1
  local hp
  hp=$(mpm_kind_docker_exec "$node" printenv HTTP_PROXY 2>/dev/null || true)
  [[ -n "$hp" ]] && return 0
  return 1
}

mpm_scope_kind__proxy_fingerprint() {
  local preset=$1 cluster=$2
  local hp
  mpm_scope_kind__read_proxy_fields "$preset" "$cluster" || return 1
  hp=$MPM_KIND_HP
  printf '%s' "$hp" | sha256sum | awk '{print substr($1,1,8)}'
}

mpm_scope_kind__restart_units_in_node() {
  local node=$1 preset=$2
  local unit
  mpm_kind_docker_exec "$node" systemctl daemon-reload 2>/dev/null || true
  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    if mpm_kind_docker_exec "$node" systemctl is-active --quiet "${unit}" 2>/dev/null; then
      echo "mpm(kind): ${node}: restarting ${unit}…" >&2
      mpm_kind_docker_exec "$node" systemctl restart "${unit}" 2>/dev/null || {
        echo "mpm(kind): ${node}: restart ${unit} failed" >&2
        return 1
      }
    fi
  done < <(yq -r ".[\"${preset}\"].restart_units[]?" "${MPM_SHARE_PROFILES}/presets/kind.yaml" 2>/dev/null)
  return 0
}

mpm_scope_kind__write_manifest() {
  local preset=$1
  local mf
  mf=$(mpm_scope_kind_manifest_path)
  mkdir -p "$(dirname "$mf")"
  {
    echo "preset: ${preset}"
    echo "proxy_fingerprint: $(mpm_scope_kind__proxy_fingerprint "$preset" "" 2>/dev/null || echo unknown)"
    echo "clusters:"
    local cluster node
    while IFS= read -r cluster; do
      [[ -z "$cluster" ]] && continue
      echo "  - name: ${cluster}"
      echo "    nodes:"
      while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        echo "      - ${node}"
      done < <(mpm_scope_kind__discover_nodes "$cluster")
    done < <(mpm_scope_kind__discover_clusters)
  } >"$mf"
}

mpm_scope_kind_get_state() {
  local clusters=() cluster node unit st
  local on=0 off=0 mix=0 unk=0 total=0 create_hint=0
  mpm_scope_kind__ensure_topology
  mapfile -t clusters < <(mpm_scope_kind__discover_clusters)
  if [[ ${#clusters[@]} -eq 0 ]]; then
    echo "state=off"
    echo "preset=direct"
    echo "detail=no kind clusters discovered (or clusters whitelist is empty)"
    return 0
  fi
  for cluster in "${clusters[@]}"; do
    while IFS= read -r node; do
      [[ -z "$node" ]] && continue
      total=$((total + 1))
      mpm_scope_kind__prefetch_node_proxy_files "$node"
      local want_env want_conf_c want_conf_k
      want_env=$(mpm_scope_kind__expected_env_body_for_unit proxy "$cluster" "$node" containerd.service) || want_env=""
      want_conf_c=$(mpm_scope_kind__expected_conf_for_unit proxy "$cluster" containerd.service) || want_conf_c=""
      want_conf_k=$(mpm_scope_kind__expected_conf_for_unit proxy "$cluster" kubelet.service) || want_conf_k=""
      local n_on=0 n_off=0 n_mix=0 n_unk=0 u stu want_conf
      for unit in containerd.service kubelet.service; do
        want_conf=$want_conf_c
        [[ "$unit" == "kubelet.service" ]] && want_conf=$want_conf_k
        stu=$(mpm_scope_kind__node_unit_state "$node" "$cluster" "$unit" "$want_env" "$want_conf")
        case "$stu" in
          on) n_on=$((n_on + 1)) ;;
          off) n_off=$((n_off + 1)) ;;
          mixed) n_mix=$((n_mix + 1)) ;;
          *) n_unk=$((n_unk + 1)) ;;
        esac
      done
      if [[ "$n_on" -eq 2 ]]; then
        on=$((on + 1))
      elif [[ "$n_off" -eq 2 ]]; then
        off=$((off + 1))
        mpm_scope_kind__node_has_create_time_proxy_hint "$node" && create_hint=1
      elif [[ "$n_unk" -gt 0 ]]; then
        unk=$((unk + 1))
      else
        mix=$((mix + 1))
      fi
    done < <(mpm_scope_kind__discover_nodes "$cluster")
  done
  if [[ "$total" -eq 0 ]]; then
    echo "state=off"
    echo "preset=direct"
    echo "detail=kind clusters listed but no running nodes"
    return 0
  fi
  if [[ "$on" -eq "$total" ]]; then
    echo "state=on"
    echo "preset=proxy"
    echo "detail=all ${total} node(s) across ${#clusters[@]} cluster(s) match kind/proxy"
    return 0
  fi
  if [[ "$off" -eq "$total" ]]; then
    echo "state=off"
    echo "preset=direct"
    if [[ "$create_hint" -eq 1 ]]; then
      echo "detail=no mpm drop-ins (${total} node(s)); some nodes have kind create-time HTTP_PROXY env only"
    else
      echo "detail=no mpm kind proxy files on ${total} node(s)"
    fi
    return 0
  fi
  if [[ "$unk" -gt 0 ]]; then
    echo "state=unknown"
    echo "preset="
    echo "detail=non-mpm proxy files on some nodes (${on} on / ${off} off / ${mix} mixed / ${unk} unknown of ${total})"
    return 0
  fi
  echo "state=mixed"
  echo "preset="
  echo "detail=partial kind proxy (${on} on / ${off} off / ${mix} mixed of ${total} node(s))"
}

mpm_scope_kind_apply_preset() {
  local preset=$1
  mpm_require_yq || return 1
  mpm_preset_has kind "$preset" || {
    echo "mpm(kind): unknown preset: ${preset}" >&2
    return 1
  }
  case "${KIND_EXPERIMENTAL_PROVIDER:-docker}" in
    docker | "") ;;
    *)
      echo "mpm(kind): KIND_EXPERIMENTAL_PROVIDER=${KIND_EXPERIMENTAL_PROVIDER} — skip (docker only in MVP)" >&2
      return 0
      ;;
  esac
  mpm_require_docker || return 1
  mpm_scope_kind__ensure_topology
  local clusters=() cluster node unit ef cf env_body conf_body
  local wrote=0 failed=0 any=0
  mapfile -t clusters < <(mpm_scope_kind__discover_clusters)
  if [[ ${#clusters[@]} -eq 0 ]]; then
    echo "mpm(kind): no kind clusters to manage" >&2
    return 0
  fi

  if [[ "$preset" == "direct" ]]; then
    for cluster in "${clusters[@]}"; do
      while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        any=1
        local node_changed=0
        mpm_scope_kind__prefetch_node_proxy_files "$node"
        for unit in containerd.service kubelet.service; do
          ef=$(mpm_scope_kind__envfile "$unit")
          cf=$(mpm_scope_kind__dropin_conf "$unit")
          local cur_env cur_conf
          cur_env=$(mpm_scope_kind__read_container_file_cached "$node" "$ef")
          cur_conf=$(mpm_scope_kind__read_container_file_cached "$node" "$cf")
          [[ -z "$cur_env" && -z "$cur_conf" ]] && continue
          if [[ -n "$cur_env" ]] && ! grep -q "mpm-managed" <<<"$cur_env" 2>/dev/null; then
            echo "mpm(kind): ${node}:${ef} is not mpm-managed; skipping" >&2
            continue
          fi
          if [[ -n "$cur_conf" ]] && ! grep -q "mpm-managed drop-in" <<<"$cur_conf" 2>/dev/null; then
            echo "mpm(kind): ${node}:${cf} is not mpm-managed; skipping" >&2
            continue
          fi
          mpm_scope_kind__remove_container_files "$node" "$ef" "$cf"
          node_changed=1
          wrote=1
        done
        if [[ "$node_changed" -eq 1 ]]; then
          mpm_scope_kind__restart_units_in_node "$node" "$preset" || failed=1
        fi
      done < <(mpm_scope_kind__discover_nodes "$cluster")
    done
    [[ "$wrote" -eq 0 && "$any" -eq 1 ]] && echo "already using kind/direct" >&2
    [[ "$failed" -ne 0 ]] && return 1
    mpm_scope_kind__write_manifest "$preset"
    return 0
  fi

  for cluster in "${clusters[@]}"; do
    while IFS= read -r node; do
      [[ -z "$node" ]] && continue
      any=1
      local node_changed=0
      mpm_scope_kind__prefetch_node_proxy_files "$node"
      for unit in containerd.service kubelet.service; do
        ef=$(mpm_scope_kind__envfile "$unit")
        cf=$(mpm_scope_kind__dropin_conf "$unit")
        env_body=$(mpm_scope_kind__expected_env_body_for_unit "$preset" "$cluster" "$node" "$unit") || {
          echo "mpm(kind): cannot build env for ${node}/${unit}" >&2
          failed=1
          continue
        }
        conf_body=$(mpm_scope_kind__expected_conf_for_unit "$preset" "$cluster" "$unit") || {
          echo "mpm(kind): cannot build drop-in for ${node}/${unit}" >&2
          failed=1
          continue
        }
        [[ -n "$env_body" && -n "$conf_body" ]] || continue
        local cur_env cur_conf tmp_e tmp_c
        cur_env=$(mpm_scope_kind__read_container_file_cached "$node" "$ef")
        cur_conf=$(mpm_scope_kind__read_container_file_cached "$node" "$cf")
        if [[ "$cur_env" == "$env_body" && "$cur_conf" == "$conf_body" ]]; then
          continue
        fi
        mpm_scope_kind__write_container_file "$node" "$ef" "$env_body" || {
          echo "mpm(kind): write ${node}:${ef} failed" >&2
          failed=1
          continue
        }
        mpm_scope_kind__write_container_file "$node" "$cf" "$conf_body" || {
          echo "mpm(kind): write ${node}:${cf} failed" >&2
          failed=1
          continue
        }
        node_changed=1
        wrote=1
      done
      if [[ "$node_changed" -eq 1 ]]; then
        mpm_scope_kind__restart_units_in_node "$node" "$preset" || failed=1
      fi
    done < <(mpm_scope_kind__discover_nodes "$cluster")
  done
  if [[ "$wrote" -eq 0 && "$any" -eq 1 && "$failed" -eq 0 ]]; then
    echo "already using kind/${preset}" >&2
  fi
  if [[ "$failed" -ne 0 ]]; then
    return 1
  fi
  mpm_scope_kind__write_manifest "$preset"
  return 0
}

mpm_scope_kind_apply_bundle() {
  local bundle=$1 p
  p=$(mpm_group_preset "$bundle" "kind") || return 1
  [[ -n "$p" && "$p" != "null" ]] || return 1
  mpm_scope_kind_apply_preset "$p"
}

mpm_scope_kind_list_presets() {
  mpm_preset_table_lines kind
}

mpm_scope_kind__inferred_preset() {
  local k v pr=""
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == preset ]] && pr="$v"
  done < <(mpm_scope_kind_get_state 2>/dev/null)
  printf '%s' "$pr"
}

mpm_scope_kind__probe_image_ref() {
  printf '%s' 'docker.io/library/hello-world:latest'
}

mpm_scope_kind__probe_image_exists() {
  local node=$1 ref=$2 out
  out=$(mpm_kind_docker_exec "$node" crictl images -q "$ref" 2>/dev/null) || return 1
  [[ -n "$out" ]]
}

# Remove probe image when present so the next pull hits the registry (not local cache).
mpm_scope_kind__remove_probe_image() {
  local node=$1 ref=$2
  if mpm_scope_kind__probe_image_exists "$node" "$ref"; then
    echo "mpm(kind-test): ${node}: removing existing ${ref}" >&2
    mpm_kind_docker_exec "$node" crictl rmi "$ref" >/dev/null 2>&1 || true
  fi
}

mpm_scope_kind__live_pull_smoke() {
  local node=$1 ref=$2 log rc
  log=$(mktemp)
  : >"$log"
  mpm_scope_kind__remove_probe_image "$node" "$ref"
  echo "mpm(kind-test): ${node}: crictl pull ${ref} (containerd uses mpm drop-in proxy env when active)" >&2
  set +e
  if command -v timeout >/dev/null 2>&1; then
    mpm_kind_docker_exec "$node" timeout 180 crictl pull "$ref" >>"$log" 2>&1
    rc=$?
    if [[ "$rc" -eq 124 ]]; then
      echo "mpm(kind-test): FAIL crictl pull timed out (180s) for ${ref} on ${node}" >&2
      tail -n 25 "$log" >&2 || true
      rm -f "$log"
      set -e
      return 1
    fi
  else
    echo "mpm(kind-test): WARN no timeout(1); crictl pull without time limit" >&2
    mpm_kind_docker_exec "$node" crictl pull "$ref" >>"$log" 2>&1
    rc=$?
  fi
  set -e
  if [[ "$rc" -eq 0 ]]; then
    mpm_scope_kind__remove_probe_image "$node" "$ref"
    rm -f "$log"
    return 0
  fi
  echo "mpm(kind-test): FAIL crictl pull ${ref} on ${node} (exit ${rc})" >&2
  tail -n 25 "$log" >&2 || true
  rm -f "$log"
  return 1
}

mpm_scope_kind__test_preset_live() {
  local preset=$1 cluster node ref
  ref=$(mpm_scope_kind__probe_image_ref)
  echo "mpm(kind-test): ${preset} matches inferred → live pull ${ref} (crictl in kind nodes; uses containerd systemd proxy env)" >&2
  mapfile -t clusters < <(mpm_scope_kind__discover_clusters)
  for cluster in "${clusters[@]}"; do
    node=$(mpm_scope_kind__discover_nodes "$cluster" | head -1)
    [[ -z "$node" ]] && continue
    if mpm_scope_kind__live_pull_smoke "$node" "$ref"; then
      printf 'kind/%s: OK (live pull %s on %s)\n' "$preset" "$ref" "$node"
      return 0
    fi
  done
  return 1
}

mpm_scope_kind_test_preset() {
  local preset=$1 inferred hp probe target
  mpm_require_yq || return 1
  mapfile -t clusters < <(mpm_scope_kind__discover_clusters)
  if [[ ${#clusters[@]} -eq 0 ]]; then
    echo "mpm(kind-test): no kind clusters — skip" >&2
    return 0
  fi
  if ! mpm_require_docker 2>/dev/null; then
    echo "mpm(kind-test): docker unavailable — skip" >&2
    return 0
  fi
  hp=$(mpm_preset_resolve_field kind "$preset" '.http_proxy // ""')
  [[ "$hp" == "null" ]] && hp=""
  probe=$(mpm_preset_yq kind "$preset" '.probe // ""')
  [[ "$probe" == "null" ]] && probe=""
  if [[ "$preset" == "direct" ]] || [[ -z "$hp" ]]; then
    echo "mpm(kind-test): direct — skip proxy tunnel probe" >&2
    return 0
  fi
  target="$probe"
  [[ -z "$target" ]] && target="https://hub.docker.com"
  inferred=$(mpm_scope_kind__inferred_preset)
  if [[ -n "$inferred" && "$inferred" == "$preset" ]]; then
    mpm_scope_kind__test_preset_live "$preset" || return 1
    return 0
  fi
  echo "mpm(kind-test): ${preset} is not the inferred preset (${inferred:-none}) → HTTP probe only (curl --proxy)" >&2
  mpm_http_probe_via_proxy "$hp" "$target" "kind/${preset}"
}
