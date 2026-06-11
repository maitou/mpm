# shellcheck shell=bash
# mpm uninstall logic (used by uninstall.sh and mpm uninstall).
# Keep in sync with install.sh privilege / PREFIX conventions.

: "${MPM_UNINSTALL_SYSTEM_OVERRIDES:=/etc/mpm/overrides.yaml}"

mpm_uninstall_print_help() {
  cat <<'EOF'
Usage: bash uninstall.sh [OPTION]...
       mpm uninstall [OPTION]...

  --prefix=DIR              Install prefix (default: /usr/local); removes DIR/bin/mpm and DIR/share/mpm
  --dry-run                 Print actions only; do not delete
  --remove-overrides        Remove /etc/mpm/overrides.yaml (and empty /etc/mpm/)
  --remove-yq               Remove PREFIX/bin/yq when it is mikefarah/yq
  --remove-user-config      Remove ~/.config/mpm (respects XDG_CONFIG_HOME)
  --help                    Print help and exit 0

Removes mpm CLI and PREFIX/share/mpm only. Does NOT revert proxy drop-ins applied by mpm use;
run 'mpm use direct-group' first if you need direct outbound access.

To install: bash install.sh
EOF
}

mpm_uninstall_log() {
  printf 'mpm-uninstall: %s\n' "$*" >&2
}

mpm_uninstall_note_proxy() {
  mpm_uninstall_log "note: proxy settings applied by mpm (apt/shell/docker/kind/k3s/go) are NOT reverted automatically."
  mpm_uninstall_log "      run 'mpm use direct-group' before uninstall if you want direct outbound access."
}

mpm_uninstall_is_root() {
  [[ "${EUID:-0}" -eq 0 ]]
}

mpm_uninstall_needs_sudo() {
  mpm_uninstall_is_root && return 1
  local parent
  parent=$(dirname "$PREFIX")
  if [[ -w "$parent" ]] && { [[ ! -e "$PREFIX" ]] || [[ -w "$PREFIX" ]]; }; then
    return 1
  fi
  return 0
}

mpm_uninstall_seeds_system_overrides() {
  case "$PREFIX" in
    "$HOME/.local" | "$HOME"/.local/*) return 1 ;;
    /usr/local | /usr/local/* | /usr/*) return 0 ;;
  esac
  mpm_uninstall_needs_sudo
}

mpm_uninstall_sudo_cache_credentials() {
  mpm_uninstall_is_root && return 0
  if sudo -n -v 2>/dev/null; then
    return 0
  fi
  if [[ -t 0 ]]; then
    sudo -v
    return $?
  fi
  mpm_uninstall_log "sudo credentials required (run: sudo -v, or configure NOPASSWD)"
  return 1
}

mpm_uninstall_sudo() {
  if mpm_uninstall_is_root; then
    "$@"
    return $?
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] sudo' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  mpm_uninstall_sudo_cache_credentials || return 2
  sudo "$@"
}

mpm_uninstall_run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run]' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "$@"
}

mpm_uninstall_run_priv() {
  if mpm_uninstall_needs_sudo; then
    mpm_uninstall_sudo "$@"
  else
    mpm_uninstall_run "$@"
  fi
}

mpm_uninstall_is_mikefarah_yq() {
  local f=$1
  [[ -x "$f" ]] || return 1
  local ver
  ver=$("$f" --version 2>&1 || true)
  [[ "$ver" == *mikefarah* ]] || [[ "$ver" == *github.com/mikefarah* ]]
}

mpm_uninstall_user_config_dir() {
  printf '%s/mpm' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

mpm_uninstall_remove_path() {
  local path=$1 label=${2:-$1}
  if [[ -e "$path" || -L "$path" ]]; then
    mpm_uninstall_run_priv rm -rf "$path"
    mpm_uninstall_log "removed ${label}"
    return 0
  fi
  mpm_uninstall_log "skip (not found): ${label}"
  return 0
}

mpm_uninstall_remove_file() {
  local path=$1 label=${2:-$1}
  if [[ -f "$path" ]]; then
    mpm_uninstall_run_priv rm -f "$path"
    mpm_uninstall_log "removed ${label}"
    return 0
  fi
  mpm_uninstall_log "skip (not found): ${label}"
  return 0
}

mpm_uninstall_parse_args() {
  PREFIX="/usr/local"
  DRY_RUN=0
  REMOVE_OVERRIDES=0
  REMOVE_YQ=0
  REMOVE_USER_CONFIG=0
  SKIP_PROXY_NOTE=0

  local arg
  for arg in "$@"; do
    case "$arg" in
      --prefix=*)
        PREFIX="${arg#--prefix=}"
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --remove-overrides)
        REMOVE_OVERRIDES=1
        ;;
      --remove-yq)
        REMOVE_YQ=1
        ;;
      --remove-user-config)
        REMOVE_USER_CONFIG=1
        ;;
      --skip-proxy-note)
        SKIP_PROXY_NOTE=1
        ;;
      --help)
        mpm_uninstall_print_help
        exit 0
        ;;
      *)
        mpm_uninstall_log "unknown argument: ${arg} (see --help)"
        exit 1
        ;;
    esac
  done
}

mpm_uninstall_main() {
  local bin_mpm bin_yq data_dir overrides_dir user_cfg
  bin_mpm="${PREFIX}/bin/mpm"
  bin_yq="${PREFIX}/bin/yq"
  data_dir="${PREFIX}/share/mpm"
  overrides_dir=/etc/mpm
  user_cfg=$(mpm_uninstall_user_config_dir)

  mpm_uninstall_log "prefix=${PREFIX}"
  if [[ "$SKIP_PROXY_NOTE" != "1" ]]; then
    mpm_uninstall_note_proxy
  fi

  if [[ "$DRY_RUN" -eq 0 ]] && mpm_uninstall_needs_sudo; then
    mpm_uninstall_sudo_cache_credentials || exit 2
  fi

  mpm_uninstall_remove_file "$bin_mpm" "$bin_mpm"
  mpm_uninstall_remove_path "$data_dir" "$data_dir"

  if [[ "$REMOVE_YQ" -eq 1 ]]; then
    if [[ -f "$bin_yq" ]] && mpm_uninstall_is_mikefarah_yq "$bin_yq"; then
      mpm_uninstall_remove_file "$bin_yq" "$bin_yq"
    elif [[ -f "$bin_yq" ]]; then
      mpm_uninstall_log "skip yq (not mikefarah/yq): ${bin_yq}"
    else
      mpm_uninstall_log "skip (not found): ${bin_yq}"
    fi
  fi

  if [[ "$REMOVE_OVERRIDES" -eq 1 ]]; then
    if [[ -f "$MPM_UNINSTALL_SYSTEM_OVERRIDES" ]]; then
      mpm_uninstall_remove_file "$MPM_UNINSTALL_SYSTEM_OVERRIDES" "$MPM_UNINSTALL_SYSTEM_OVERRIDES"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        mpm_uninstall_log "[dry-run] would rmdir ${overrides_dir} if empty"
      elif [[ -d "$overrides_dir" ]] && [[ -z "$(ls -A "$overrides_dir" 2>/dev/null)" ]]; then
        mpm_uninstall_run_priv rmdir "$overrides_dir" 2>/dev/null && mpm_uninstall_log "removed empty ${overrides_dir}" || true
      fi
    else
      mpm_uninstall_log "skip (not found): ${MPM_UNINSTALL_SYSTEM_OVERRIDES}"
    fi
  elif mpm_uninstall_seeds_system_overrides && [[ -f "$MPM_UNINSTALL_SYSTEM_OVERRIDES" ]]; then
    mpm_uninstall_log "kept ${MPM_UNINSTALL_SYSTEM_OVERRIDES} (use --remove-overrides to delete)"
  fi

  if [[ "$REMOVE_USER_CONFIG" -eq 1 ]]; then
    if [[ -e "$user_cfg" ]]; then
      mpm_uninstall_run rm -rf "$user_cfg"
      mpm_uninstall_log "removed ${user_cfg}"
    else
      mpm_uninstall_log "skip (not found): ${user_cfg}"
    fi
  fi

  mpm_uninstall_log "done"
}

mpm_uninstall_entry() {
  if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    mpm_uninstall_log "Bash 4+ required (current: ${BASH_VERSION:-?})"
    exit 1
  fi
  mpm_uninstall_parse_args "$@"
  BIN_DIR="${PREFIX}/bin"
  mpm_uninstall_main
}

# When invoked as share/mpm/lib/uninstall.sh (installed tree).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  mpm_uninstall_entry "$@"
fi
