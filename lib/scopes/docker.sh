# shellcheck shell=bash

mpm_scope_docker_metadata() {
  cat <<'EOF'
title=Docker Engine outbound HTTP(S) proxy
description=systemd drop-in + EnvironmentFile for docker.service (proxy variables)
requires_root=1
EOF
}

mpm_scope_docker_requires_root() {
  echo 1
}

mpm_scope_docker_resolve_gateway_ip() {
  local gw
  if command -v docker >/dev/null 2>&1; then
    gw=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
    if [[ -n "$gw" && "$gw" != "<no value>" ]]; then
      printf '%s' "$gw"
      return 0
    fi
  fi
  if command -v ip >/dev/null 2>&1; then
    gw=$(ip -4 addr show docker0 2>/dev/null | awk '/inet / { print $2 }' | cut -d/ -f1 | head -1)
    if [[ -n "$gw" ]]; then
      printf '%s' "$gw"
      return 0
    fi
  fi
  echo "mpm(docker): cannot resolve GATEWAY_IP (bridge gateway / docker0)" >&2
  return 1
}

mpm_scope_docker_dropin() {
  echo "/etc/systemd/system/docker.service.d/mpm-proxy.conf"
}

mpm_scope_docker_envfile() {
  echo "/etc/systemd/system/docker.service.d/mpm-proxy.env"
}

mpm_scope_docker__read_proxy_fields() {
  local preset=$1
  mpm_require_yq || return 1
  MPM_DOCKER_HP=$(mpm_preset_resolve_field docker "$preset" '.http_proxy') || return 1
  MPM_DOCKER_HS=$(mpm_preset_resolve_field docker "$preset" '.https_proxy') || return 1
  MPM_DOCKER_AP=$(mpm_preset_resolve_field docker "$preset" '.all_proxy') || return 1
  MPM_DOCKER_NP=$(mpm_preset_yq docker "$preset" '.no_proxy') || return 1
  [[ "$MPM_DOCKER_HP" == "null" ]] && MPM_DOCKER_HP=""
  [[ "$MPM_DOCKER_HS" == "null" ]] && MPM_DOCKER_HS=""
  [[ "$MPM_DOCKER_AP" == "null" ]] && MPM_DOCKER_AP=""
  [[ "$MPM_DOCKER_NP" == "null" ]] && MPM_DOCKER_NP=""
  return 0
}

# EnvironmentFile= format avoids systemd parsing quirks with '=' inside Environment="..." values (e.g. URLs).
mpm_scope_docker__render_envfile_body() {
  local hp=$1 hs=$2 ap=$3 np=$4
  cat <<EOF
# mpm-managed; remove with: mpm use direct-group --scopes=docker
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

mpm_scope_docker__render_dropin_conf() {
  local envpath=$1
  cat <<EOF
# mpm-managed drop-in for docker.service; safe to remove with: mpm use direct-group --scopes=docker
[Service]
EnvironmentFile=${envpath}
EOF
}

mpm_scope_docker__expected_env_body_for_preset() {
  local preset=$1
  mpm_scope_docker__read_proxy_fields "$preset" || return 1
  if [[ "$preset" == "direct" ]] || [[ -z "$MPM_DOCKER_HP" && -z "$MPM_DOCKER_HS" ]]; then
    printf ''
    return 0
  fi
  mpm_scope_docker__render_envfile_body "$MPM_DOCKER_HP" "$MPM_DOCKER_HS" "$MPM_DOCKER_AP" "$MPM_DOCKER_NP"
}

mpm_scope_docker__expected_conf_body() {
  mpm_scope_docker__render_dropin_conf "$(mpm_scope_docker_envfile)"
}

mpm_scope_docker_get_state() {
  local d ef want_env cur_env want_conf cur_conf
  d=$(mpm_scope_docker_dropin)
  ef=$(mpm_scope_docker_envfile)
  if [[ ! -f "$d" && ! -f "$ef" ]]; then
    echo "state=off"
    echo "preset=direct"
    echo "detail=no mpm docker drop-in or env file"
    return 0
  fi
  if [[ -f "$d" ]] && ! grep -q "mpm-managed drop-in" "$d" 2>/dev/null; then
    echo "state=unknown"
    echo "preset="
    echo "detail=${d} exists but is not mpm-managed"
    return 0
  fi
  if [[ -f "$ef" ]] && ! grep -q "mpm-managed" "$ef" 2>/dev/null; then
    echo "state=unknown"
    echo "preset="
    echo "detail=${ef} exists but is not mpm-managed"
    return 0
  fi
  want_env=$(mpm_scope_docker__expected_env_body_for_preset proxy) || {
    echo "state=unknown"
    echo "preset="
    echo "detail=cannot read preset"
    return 0
  }
  want_conf=$(mpm_scope_docker__expected_conf_body) || {
    echo "state=unknown"
    echo "preset="
    echo "detail=cannot build expected drop-in"
    return 0
  }
  if [[ -f "$ef" ]]; then
    cur_env=$(cat "$ef" 2>/dev/null || true)
  else
    cur_env=""
  fi
  if [[ -f "$d" ]]; then
    cur_conf=$(cat "$d" 2>/dev/null || true)
  else
    cur_conf=""
  fi
  if [[ -n "$want_env" && "$cur_env" == "$want_env" && "$cur_conf" == "$want_conf" ]]; then
    echo "state=on"
    echo "preset=proxy"
    echo "detail=mpm-managed docker drop-in + env match built-in proxy preset"
    return 0
  fi
  if [[ -z "$want_env" ]]; then
    echo "state=unknown"
    echo "preset="
    echo "detail=unexpected mpm files while resolving preset"
    return 0
  fi
  if { [[ -f "$ef" ]] && grep -qE '^(HTTP_PROXY|http_proxy)=' "$ef" 2>/dev/null; } ||
    { [[ -f "$d" ]] && grep -qE 'Environment(File)?=' "$d" 2>/dev/null; }; then
    echo "state=mixed"
    echo "preset="
    echo "detail=mpm docker files differ from built-in proxy preset template"
    return 0
  fi
  echo "state=unknown"
  echo "preset="
  echo "detail=cannot classify docker proxy files"
}

mpm_scope_docker_restart() {
  if systemctl is-active --quiet docker.service 2>/dev/null || systemctl is-active --quiet docker 2>/dev/null; then
    echo "mpm(docker): restarting docker.service…" >&2
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart docker.service 2>/dev/null || systemctl restart docker 2>/dev/null || {
      echo "mpm(docker): systemctl restart docker failed" >&2
      return 1
    }
    return 0
  fi
  echo "mpm(docker): docker.service not active; ran daemon-reload only." >&2
  systemctl daemon-reload 2>/dev/null || true
  return 0
}

mpm_scope_docker__ensure_fragment_parent() {
  local d=$1
  local parent
  parent=$(dirname "$d")
  if [[ -e "$parent" && ! -d "$parent" ]]; then
    echo "mpm(docker): ${parent} exists but is not a directory; fix systemd layout or remove that path" >&2
    return 1
  fi
  mkdir -p "$parent" || {
    echo "mpm(docker): mkdir -p ${parent} failed (errno $?)" >&2
    return 1
  }
  return 0
}

mpm_scope_docker_apply_preset() {
  local preset=$1
  mpm_is_root || {
    echo "mpm(docker): root required to write $(mpm_scope_docker_dropin)" >&2
    return 2
  }
  mpm_require_yq || return 1
  mpm_preset_has docker "$preset" || {
    echo "mpm(docker): unknown preset: ${preset}" >&2
    return 1
  }
  local d ef conf_body env_body wrote=0
  d=$(mpm_scope_docker_dropin)
  ef=$(mpm_scope_docker_envfile)
  mpm_scope_docker__ensure_fragment_parent "$d" || return 1

  if [[ "$preset" == "direct" ]]; then
    if [[ ! -f "$d" && ! -f "$ef" ]]; then
      echo "already using docker/direct" >&2
      return 0
    fi
    if [[ -f "$ef" ]] && ! grep -q "mpm-managed" "$ef" 2>/dev/null; then
      echo "mpm(docker): ${ef} exists and is not mpm-managed; leaving in place" >&2
      return 1
    fi
    if [[ -f "$d" ]] && ! grep -q "mpm-managed drop-in" "$d" 2>/dev/null; then
      echo "mpm(docker): ${d} exists and is not mpm-managed; leaving in place" >&2
      return 1
    fi
    [[ -f "$ef" ]] && mpm_backup_file "$ef" >/dev/null
    [[ -f "$d" ]] && mpm_backup_file "$d" >/dev/null
    rm -f "$ef" "$d"
    wrote=1
  else
    env_body=$(mpm_scope_docker__expected_env_body_for_preset "$preset") || {
      echo "mpm(docker): cannot build env body for ${preset} (check stderr above; expected preset file: ${MPM_SHARE_PROFILES}/presets/docker.yaml)" >&2
      return 1
    }
    [[ -n "$env_body" ]] || {
      echo "mpm(docker): preset ${preset} produced empty env file body" >&2
      return 1
    }
    conf_body=$(mpm_scope_docker__expected_conf_body) || return 1
  if [[ -f "$ef" && -f "$d" ]]; then
    local tmp_e tmp_c
    tmp_e=$(mktemp)
    tmp_c=$(mktemp)
    printf '%s\n' "$env_body" >"$tmp_e"
    printf '%s\n' "$conf_body" >"$tmp_c"
    if cmp -s "$ef" "$tmp_e" 2>/dev/null && cmp -s "$d" "$tmp_c" 2>/dev/null; then
      rm -f "$tmp_e" "$tmp_c"
      echo "already using docker/${preset}" >&2
      return 0
    fi
    rm -f "$tmp_e" "$tmp_c"
  fi
    [[ -f "$ef" ]] && mpm_backup_file "$ef" >/dev/null
    [[ -f "$d" ]] && mpm_backup_file "$d" >/dev/null
    if ! printf '%s\n' "$env_body" >"${ef}.tmp"; then
      echo "mpm(docker): cannot write ${ef}.tmp" >&2
      rm -f "${ef}.tmp"
      return 1
    fi
    if ! mv "${ef}.tmp" "$ef"; then
      echo "mpm(docker): cannot mv ${ef}.tmp -> ${ef}" >&2
      rm -f "${ef}.tmp"
      return 1
    fi
    chmod 0644 "$ef" || true
    if ! printf '%s\n' "$conf_body" >"${d}.tmp"; then
      echo "mpm(docker): cannot write ${d}.tmp" >&2
      rm -f "${d}.tmp"
      return 1
    fi
    if ! mv "${d}.tmp" "$d"; then
      echo "mpm(docker): cannot mv ${d}.tmp -> ${d}" >&2
      rm -f "${d}.tmp"
      return 1
    fi
    chmod 0644 "$d" || true
    wrote=1
  fi
  if [[ "$wrote" -eq 1 ]]; then
    mpm_scope_docker_restart || true
  fi
  return 0
}

mpm_scope_docker_apply_bundle() {
  local bundle=$1 p
  p=$(mpm_group_preset "$bundle" "docker") || {
    echo "mpm(docker): yq failed reading group preset (group=${bundle}, scope=docker); check ${MPM_SHARE_PROFILES}/groups.yaml and yq on PATH" >&2
    return 1
  }
  if [[ -z "$p" || "$p" == "null" ]]; then
    echo "mpm(docker): group ${bundle} has no docker mapping (empty or null). Fix groups.yaml." >&2
    return 1
  fi
  mpm_scope_docker_apply_preset "$p"
}

mpm_scope_docker_list_presets() {
  mpm_preset_table_lines docker
}

mpm_scope_docker__inferred_preset() {
  local k v pr=""
  while IFS= read -r line; do
    k=${line%%=*}
    v=${line#*=}
    [[ "$k" == preset ]] && pr="$v"
  done < <(mpm_scope_docker_get_state 2>/dev/null)
  printf '%s' "$pr"
}

# Remove probe image so the next pull always hits the registry (not local cache).
mpm_scope_docker__remove_probe_image() {
  local ref=$1
  DOCKER_CONTENT_TRUST=0 docker rmi -f "$ref" >/dev/null 2>&1 || true
}

# Live Engine smoke: pull hello-world (uses systemd proxy env when mpm-managed preset is active).
mpm_scope_docker__engine_probe() {
  local ref="docker.io/library/hello-world:latest"
  command -v docker >/dev/null 2>&1 || {
    echo "mpm(docker-test): docker CLI not found; install Docker client to validate Engine." >&2
    return 1
  }
  set +e
  if command -v timeout >/dev/null 2>&1; then
    if ! timeout 8 docker version >/dev/null 2>&1; then
      echo "mpm(docker-test): FAIL docker version (Engine unreachable? start docker or check DOCKER_HOST)" >&2
      set -e
      return 1
    fi
  elif ! docker version >/dev/null 2>&1; then
    echo "mpm(docker-test): FAIL docker version (Engine unreachable?)" >&2
    set -e
    return 1
  fi
  mpm_scope_docker__remove_probe_image "$ref"
  echo "mpm(docker-test): docker pull -q ${ref} (daemon uses mpm drop-in proxy env when active)" >&2
  local rc
  if command -v timeout >/dev/null 2>&1; then
    DOCKER_CONTENT_TRUST=0 timeout 90 docker pull -q "$ref" >/dev/null 2>&1
    rc=$?
    if [[ "$rc" -eq 124 ]]; then
      echo "mpm(docker-test): FAIL docker pull timed out (90s) for ${ref}" >&2
      set -e
      return 1
    fi
  else
    echo "mpm(docker-test): WARN no timeout(1); docker pull without time limit" >&2
    DOCKER_CONTENT_TRUST=0 docker pull -q "$ref" >/dev/null 2>&1
    rc=$?
  fi
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "mpm(docker-test): FAIL docker pull ${ref} (exit ${rc}); check proxy and registry reachability" >&2
    return 1
  fi
  mpm_scope_docker__remove_probe_image "$ref"
  printf 'docker/proxy: OK (Engine docker pull %s)\n' "$ref"
  return 0
}

mpm_scope_docker__test_preset_live() {
  local preset=$1
  echo "mpm(docker-test): ${preset} matches inferred preset → Engine probe (docker pull)" >&2
  mpm_scope_docker__engine_probe || return 1
}

mpm_scope_docker_test_preset() {
  local preset=$1 inferred hp probe target
  mpm_require_yq || return 1
  hp=$(mpm_preset_resolve_field docker "$preset" '.http_proxy // ""')
  [[ "$hp" == "null" ]] && hp=""
  probe=$(mpm_preset_yq docker "$preset" '.probe // ""')
  [[ "$probe" == "null" ]] && probe=""
  if [[ "$preset" == "direct" ]] || [[ -z "$hp" ]]; then
    echo "mpm(docker-test): direct — skip proxy tunnel probe" >&2
    return 0
  fi
  target="$probe"
  [[ -z "$target" ]] && target="https://hub.docker.com"
  inferred=$(mpm_scope_docker__inferred_preset)
  if [[ -n "$inferred" && "$inferred" == "$preset" ]]; then
    mpm_scope_docker__test_preset_live "$preset" || return 1
    return 0
  fi
  echo "mpm(docker-test): ${preset} is not the inferred preset (${inferred:-none}) → HTTP probe only (curl --proxy)" >&2
  mpm_http_probe_via_proxy "$hp" "$target" "docker/${preset}"
}
