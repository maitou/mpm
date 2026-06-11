#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
export MPM_PREFIX="$ROOT"

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/registry.sh
source "$ROOT/lib/registry.sh"
# shellcheck source=../lib/scopes/kind.sh
source "$ROOT/lib/scopes/kind.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

mpm_require_yq || fail "yq required"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export MPM_KIND_MANIFEST="$TMP/manifest.yaml"
MOCK_ROOT="$TMP/mock"
mkdir -p "$MOCK_ROOT"

# --- render env + drop-in ---
MPM_KIND_HP="http://172.18.0.1:7890"
MPM_KIND_HS="http://172.18.0.1:7890"
MPM_KIND_NP="localhost,127.0.0.1,10.96.0.0/16"
env_body=$(mpm_scope_kind__render_envfile_body "$MPM_KIND_HP" "$MPM_KIND_HS" "$MPM_KIND_NP")
[[ "$env_body" == *'mpm-managed'* ]] || fail "env marker"
[[ "$env_body" == *'HTTP_PROXY=http://172.18.0.1:7890'* ]] || fail "env http"
conf_body=$(mpm_scope_kind__render_dropin_conf containerd.service /etc/systemd/system/containerd.service.d/mpm-proxy.env)
[[ "$conf_body" == *'mpm-managed drop-in'* ]] || fail "drop-in marker"
[[ "$conf_body" == *'EnvironmentFile='/etc/systemd/system/containerd.service.d/mpm-proxy.env* ]] || fail "EnvironmentFile"
pass render_env_and_dropin

# --- discover clusters via MPM_KIND_CLUSTERS ---
export MPM_KIND_CLUSTERS="kind,kind-2"
mapfile -t found < <(mpm_scope_kind__discover_clusters_raw)
[[ "${#found[@]}" -eq 2 ]] || fail "discover raw count: ${#found[@]}"
[[ "${found[0]}" == "kind" ]] || fail "discover kind"
pass discover_clusters_env

# --- overrides clusters whitelist ---
OV="$TMP/overrides.yaml"
cat >"$OV" <<'EOF'
scopes:
  kind:
    clusters:
      - kind
EOF
export MPM_OVERRIDES_FILE="$OV"
MPM_OVERRIDE_LOADED=0
mode=$(mpm_runtime_override_kind_clusters_mode)
[[ "$mode" == "filter" ]] || fail "mode filter: $mode"
mpm_runtime_override_kind_cluster_in_whitelist kind || fail "kind in whitelist"
! mpm_runtime_override_kind_cluster_in_whitelist kind-2 || fail "kind-2 not in whitelist"
pass overrides_whitelist

cat >"$OV" <<'EOF'
scopes:
  kind:
    clusters: []
EOF
MPM_OVERRIDE_LOADED=0
mode=$(mpm_runtime_override_kind_clusters_mode)
[[ "$mode" == "none" ]] || fail "mode none: $mode"
pass overrides_empty_clusters

unset MPM_OVERRIDES_FILE
MPM_OVERRIDE_LOADED=0

# --- get_state with mocked docker ---
mpm_scope_kind_resolve_gateway_ip() {
  printf '172.18.0.1'
}

mkdir -p "$MOCK_ROOT/kind-control-plane/etc/systemd/system/containerd.service.d"
mkdir -p "$MOCK_ROOT/kind-control-plane/etc/systemd/system/kubelet.service.d"
want_env=$(mpm_scope_kind__expected_env_body_for_unit proxy kind kind-control-plane containerd.service) || fail "expected env"
want_conf_c=$(mpm_scope_kind__expected_conf_for_unit proxy kind containerd.service) || fail "expected conf c"
want_conf_k=$(mpm_scope_kind__expected_conf_for_unit proxy kind kubelet.service) || fail "expected conf k"
printf '%s' "$want_env" >"$MOCK_ROOT/kind-control-plane/etc/systemd/system/containerd.service.d/mpm-proxy.env"
printf '%s' "$want_conf_c" >"$MOCK_ROOT/kind-control-plane/etc/systemd/system/containerd.service.d/mpm-proxy.conf"
printf '%s' "$want_env" >"$MOCK_ROOT/kind-control-plane/etc/systemd/system/kubelet.service.d/mpm-proxy.env"
printf '%s' "$want_conf_k" >"$MOCK_ROOT/kind-control-plane/etc/systemd/system/kubelet.service.d/mpm-proxy.conf"

mpm_kind_docker() {
  case "$1" in
    ps)
      if [[ "$*" == *"label=io.x-k8s.kind.cluster"* && "$*" == *"{{.Names}}"* ]]; then
        echo -e "kind-control-plane\tkind"
        return 0
      fi
      if [[ "$*" == *"-a"* ]]; then
        echo "kind-control-plane"
        return 0
      fi
      if [[ "$*" == *io.x-k8s.kind.cluster=kind* ]]; then
        echo "kind-control-plane"
      fi
      return 0
      ;;
    network)
      echo "172.18.0.1"
      return 0
      ;;
    inspect)
      if [[ "$*" == *Networks* ]]; then
        echo '{}'
      fi
      return 0
      ;;
    info) return 0 ;;
    cp) return 0 ;;
    *) return 0 ;;
  esac
}

mpm_kind_docker_exec() {
  local node=$1
  shift
  case "$1" in
    cat)
      cat "${MOCK_ROOT}/${node}${2}" 2>/dev/null || true
      return 0
      ;;
    mkdir) return 0 ;;
    chmod) return 0 ;;
    rm) return 0 ;;
    systemctl) return 0 ;;
    printenv)
      echo ""
      return 0
      ;;
    *) return 0 ;;
  esac
}

export MPM_KIND_CLUSTERS="kind"
MPM_OVERRIDE_LOADED=0
st=$(mpm_scope_kind_get_state | awk -F= '/^state=/{print $2}')
[[ "$st" == "on" ]] || fail "get_state on: $st"
pass get_state_on_mock

# --- mixed: kubelet env differs but still mpm-managed ---
printf '# mpm-managed\nHTTP_PROXY=http://1.2.3.4:9\n' >"$MOCK_ROOT/kind-control-plane/etc/systemd/system/kubelet.service.d/mpm-proxy.env"
st=$(mpm_scope_kind_get_state | awk -F= '/^state=/{print $2}')
[[ "$st" == "mixed" ]] || fail "get_state mixed: $st"
pass get_state_mixed_mock

# --- merge no_proxy ---
merged=$(mpm_scope_kind__merge_no_proxy "a,b" "b,c")
[[ "$merged" == "a,b,c" ]] || fail "merge no_proxy: $merged"
pass merge_no_proxy

# --- probe image exists / remove before pull ---
KIND_TEST_REF="docker.io/library/hello-world:latest"
KIND_TEST_NODE="kind-probe-node"
KIND_TEST_RMI=0
KIND_TEST_PULL=0

mpm_kind_docker_exec() {
  local node=$1
  shift
  if [[ "$1" == "timeout" ]]; then
    shift 2 # 180 crictl
  fi
  case "$1" in
    crictl)
      shift
      case "$1" in
        images)
          if [[ "$2" == "-q" ]]; then
            [[ "$node" == "$KIND_TEST_NODE" && -f "$TMP/.hello_present" ]] && echo "$KIND_TEST_REF"
            return 0
          fi
          ;;
        rmi)
          KIND_TEST_RMI=$((KIND_TEST_RMI + 1))
          rm -f "$TMP/.hello_present"
          return 0
          ;;
        pull)
          KIND_TEST_PULL=$((KIND_TEST_PULL + 1))
          return 0
          ;;
      esac
      ;;
    cat)
      cat "${MOCK_ROOT}/${node}${2}" 2>/dev/null || true
      return 0
      ;;
    mkdir | chmod | rm | systemctl | printenv) return 0 ;;
    *) return 0 ;;
  esac
}

touch "$TMP/.hello_present"
mpm_scope_kind__probe_image_exists "$KIND_TEST_NODE" "$KIND_TEST_REF" || fail "hello should exist"
mpm_scope_kind__remove_probe_image "$KIND_TEST_NODE" "$KIND_TEST_REF"
[[ "$KIND_TEST_RMI" -eq 1 ]] || fail "expected one crictl rmi"
! mpm_scope_kind__probe_image_exists "$KIND_TEST_NODE" "$KIND_TEST_REF" || fail "hello should be gone"
KIND_TEST_RMI=0
mpm_scope_kind__remove_probe_image "$KIND_TEST_NODE" "$KIND_TEST_REF"
[[ "$KIND_TEST_RMI" -eq 0 ]] || fail "no rmi when image absent"
KIND_TEST_PULL=0
mpm_scope_kind__live_pull_smoke "$KIND_TEST_NODE" "$KIND_TEST_REF" || fail "live pull smoke"
[[ "$KIND_TEST_PULL" -eq 1 ]] || fail "expected one crictl pull"
pass probe_image_remove_and_pull

echo "All kind_scope_test checks passed."
