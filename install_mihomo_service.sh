#!/usr/bin/env bash
# Install mihomo from a release .gz archive and register a systemd service.
# Usage: sudo ./install_mihomo_service.sh /path/to/mihomo-linux-amd64-v1.19.24.gz
# Comments in English per project convention.

set -euo pipefail

INSTALL_DIR="/opt/mihomo"
SERVICE_NAME="mihomo"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

usage() {
  echo "Usage: sudo $0 <path-to-mihomo-*.gz>" >&2
  echo "Example: sudo $0 \"\$HOME/proj/mihomo-linux-amd64-v1.19.24.gz\"" >&2
  exit 1
}

if [[ -z "${1:-}" || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

ARCHIVE="$(readlink -f "$1")"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Archive not found: $1" >&2
  exit 1
fi

if ! [[ "$ARCHIVE" =~ \.(gz|gzip)$ ]]; then
  echo "Warning: expected a .gz file from mihomo releases; continuing anyway." >&2
fi

mkdir -p "$INSTALL_DIR"

echo "Extracting binary from: $ARCHIVE"
gunzip -c "$ARCHIVE" >"${INSTALL_DIR}/mihomo"
chmod 755 "${INSTALL_DIR}/mihomo"

if ! file "${INSTALL_DIR}/mihomo" | grep -qiE 'ELF|executable'; then
  echo "Extracted file does not look like a Linux ELF binary; aborting." >&2
  rm -f "${INSTALL_DIR}/mihomo"
  exit 1
fi

CONFIG_PATH="${INSTALL_DIR}/config.yaml"
if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Creating minimal ${CONFIG_PATH} (all traffic DIRECT until you replace with your config)."
  cat >"$CONFIG_PATH" <<'MINCFG'
# Replace this file with your full mihomo / Clash Meta configuration.
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false
rules:
  - MATCH,DIRECT
MINCFG
  chmod 644 "$CONFIG_PATH"
else
  echo "Keeping existing ${CONFIG_PATH}"
fi

echo "Writing systemd unit: ${UNIT_PATH}"
{
  echo '[Unit]'
  echo 'Description=mihomo proxy (MetaCubeX)'
  echo 'Documentation=https://github.com/MetaCubeX/mihomo'
  echo 'After=network-online.target'
  echo 'Wants=network-online.target'
  echo ''
  echo '[Service]'
  echo 'Type=simple'
  echo "ExecStart=${INSTALL_DIR}/mihomo -d ${INSTALL_DIR}"
  echo 'Restart=on-failure'
  echo 'RestartSec=5'
  echo 'LimitNOFILE=65535'
  echo ''
  echo '[Install]'
  echo 'WantedBy=multi-user.target'
} >"$UNIT_PATH"
chmod 644 "$UNIT_PATH"

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"

echo ""
echo "Done. Data directory: ${INSTALL_DIR}"
echo "  binary:  ${INSTALL_DIR}/mihomo"
echo "  config:  ${CONFIG_PATH}"
echo ""
systemctl --no-pager -l status "${SERVICE_NAME}.service" || true
echo ""
echo "Useful commands:"
echo "  sudo systemctl status ${SERVICE_NAME}"
echo "  sudo journalctl -u ${SERVICE_NAME} -f"