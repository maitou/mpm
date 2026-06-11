#!/usr/bin/env bash
# mpm uninstaller: removes PREFIX/bin/mpm and PREFIX/share/mpm (see --help).
set -euo pipefail

MPM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/uninstall.sh
source "${MPM_ROOT}/lib/uninstall.sh"

mpm_uninstall_entry "$@"
