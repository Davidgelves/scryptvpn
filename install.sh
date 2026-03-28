#!/usr/bin/env bash
# Instalador: descarga vpn_panel.sh, normaliza LF y deja el comando menu.
set -euo pipefail

RAW_URL="${VPN_PANEL_URL:-https://raw.githubusercontent.com/Davidgelves/scryptvpn/main/vpn_panel.sh}"
TARGET="/usr/local/sbin/vpn_panel"
MENU="/usr/local/sbin/menu"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Ejecuta como root: sudo bash install.sh"
  exit 1
fi

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${RAW_URL}?v=$(date +%s)" -o "${TARGET}"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "${TARGET}" "${RAW_URL}?v=$(date +%s)"
else
  echo "Instala curl o wget."
  exit 1
fi

sed -i 's/\r$//' "${TARGET}"
chmod +x "${TARGET}"
ln -sf "${TARGET}" "${MENU}"

echo "Listo. Ejecuta: menu"
