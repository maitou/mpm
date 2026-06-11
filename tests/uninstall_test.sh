#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PREFIX="$TMP/prefix"
BIN_DIR="$PREFIX/bin"
DATA_DIR="$PREFIX/share/mpm"
OV_FILE="$TMP/overrides.yaml"
USER_CFG="$TMP/home/.config/mpm"

setup_install_tree() {
  mkdir -p "$BIN_DIR" "$DATA_DIR/lib" "$USER_CFG"
  printf '#!/bin/sh\necho mpm\n' >"$BIN_DIR/mpm"
  chmod +x "$BIN_DIR/mpm"
  touch "$DATA_DIR/lib/common.sh"
  printf 'defaults:\n  proxy_port: "10808"\n' >"$OV_FILE"
}

run_uninstall_lib() {
  export MPM_UNINSTALL_SYSTEM_OVERRIDES="${MPM_UNINSTALL_SYSTEM_OVERRIDES:-/etc/mpm/overrides.yaml}"
  # shellcheck disable=SC1091
  source "$ROOT/lib/uninstall.sh"
  PREFIX="$PREFIX"
  DRY_RUN=${DRY_RUN:-0}
  REMOVE_OVERRIDES=${REMOVE_OVERRIDES:-0}
  REMOVE_YQ=${REMOVE_YQ:-0}
  REMOVE_USER_CONFIG=${REMOVE_USER_CONFIG:-0}
  SKIP_PROXY_NOTE=1
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      --remove-overrides) REMOVE_OVERRIDES=1 ;;
      --remove-yq) REMOVE_YQ=1 ;;
      --remove-user-config) REMOVE_USER_CONFIG=1 ;;
    esac
  done
  mpm_uninstall_main
}

# --- dry-run leaves files ---
setup_install_tree
out=$(bash "$ROOT/uninstall.sh" --prefix="$PREFIX" --dry-run --skip-proxy-note 2>&1)
[[ -x "$BIN_DIR/mpm" ]] || fail "dry-run removed mpm"
[[ "$out" == *'[dry-run]'* ]] || fail "dry-run log missing"
pass dry_run

# --- default removes mpm + share ---
setup_install_tree
run_uninstall_lib
[[ ! -e "$BIN_DIR/mpm" ]] || fail "mpm should be gone"
[[ ! -d "$DATA_DIR" ]] || fail "share/mpm should be gone"
pass default_remove

# --- remove-overrides (isolated path) ---
setup_install_tree
export MPM_UNINSTALL_SYSTEM_OVERRIDES="$OV_FILE"
REMOVE_OVERRIDES=1 run_uninstall_lib --remove-overrides
unset MPM_UNINSTALL_SYSTEM_OVERRIDES
[[ ! -f "$OV_FILE" ]] || fail "overrides should be removed"
pass remove_overrides

# --- remove-yq skips non-mikefarah ---
setup_install_tree
printf '#!/bin/sh\necho wrong-yq\n' >"$BIN_DIR/yq"
chmod +x "$BIN_DIR/yq"
REMOVE_YQ=1 run_uninstall_lib --remove-yq
[[ -f "$BIN_DIR/yq" ]] || fail "non-mikefarah yq should remain"
pass skip_non_mikefarah_yq

# --- idempotent second run ---
run_uninstall_lib
run_uninstall_lib
pass idempotent

# --- user config ---
setup_install_tree
HOME="$TMP/home"
export HOME
XDG_CONFIG_HOME="$TMP/home/.config"
export XDG_CONFIG_HOME
mkdir -p "$USER_CFG"
touch "$USER_CFG/state.json"
REMOVE_USER_CONFIG=1 run_uninstall_lib --remove-user-config
[[ ! -d "$USER_CFG" ]] || fail "user config should be removed"
pass remove_user_config

echo "All uninstall_test checks passed."
