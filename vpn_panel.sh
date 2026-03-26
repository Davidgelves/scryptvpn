#!/usr/bin/env bash
set -euo pipefail

# Panel base de protocolos VPN/Proxy para Ubuntu 20.04+
# Incluye: SSH, Nginx, SSL (Let's Encrypt), WebSocket y Xray (V2Ray core)

SCRIPT_NAME="Administrador de Protocolos"
STATE_DIR="/etc/vpn-panel"
STATE_FILE="${STATE_DIR}/state.env"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_SERVICE="/etc/systemd/system/xray.service"
NGINX_SITE="/etc/nginx/sites-available/vpn-panel.conf"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Este script debe ejecutarse como root."
  exit 1
fi

mkdir -p "${STATE_DIR}"

log() {
  printf "\033[1;32m[OK]\033[0m %s\n" "$1"
}

warn() {
  printf "\033[1;33m[WARN]\033[0m %s\n" "$1"
}

err() {
  printf "\033[1;31m[ERROR]\033[0m %s\n" "$1"
}

default_state() {
  cat > "${STATE_FILE}" <<'EOF'
SSH_PORT=22
NGINX_HTTP_PORT=80
NGINX_HTTPS_PORT=443
XRAY_INTERNAL_PORT=10000
DOMAIN=
EMAIL=
XRAY_UUID=
EOF
}

load_state() {
  [[ -f "${STATE_FILE}" ]] || default_state
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
}

save_state() {
  cat > "${STATE_FILE}" <<EOF
SSH_PORT=${SSH_PORT}
NGINX_HTTP_PORT=${NGINX_HTTP_PORT}
NGINX_HTTPS_PORT=${NGINX_HTTPS_PORT}
XRAY_INTERNAL_PORT=${XRAY_INTERNAL_PORT}
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
XRAY_UUID=${XRAY_UUID}
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "No se encontro comando requerido: $1"
    exit 1
  }
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget unzip jq nginx socat cron openssl ca-certificates gnupg lsb-release certbot python3-certbot-nginx
  systemctl enable nginx
  systemctl start nginx
  log "Paquetes base instalados."
}

configure_ssh_port() {
  read -r -p "Puerto SSH (actual ${SSH_PORT}): " new_ssh_port
  [[ -z "${new_ssh_port}" ]] && new_ssh_port="${SSH_PORT}"
  if ! [[ "${new_ssh_port}" =~ ^[0-9]+$ ]] || (( new_ssh_port < 1 || new_ssh_port > 65535 )); then
    err "Puerto invalido."
    return 1
  fi

  if [[ -f /etc/ssh/sshd_config ]]; then
    if rg -q "^#?Port " /etc/ssh/sshd_config; then
      sed -i "s/^#\?Port .*/Port ${new_ssh_port}/" /etc/ssh/sshd_config
    else
      echo "Port ${new_ssh_port}" >> /etc/ssh/sshd_config
    fi
    systemctl restart ssh || systemctl restart sshd || true
  fi

  SSH_PORT="${new_ssh_port}"
  save_state
  log "SSH configurado en puerto ${SSH_PORT}."
}

install_xray() {
  require_cmd bash
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
  systemctl enable xray || true
  log "Xray instalado."
}

configure_xray_vless_ws() {
  read -r -p "Dominio para SSL/WebSocket (ej. vpn.tudominio.com): " domain_in
  read -r -p "Correo para Let's Encrypt: " email_in
  read -r -p "Puerto interno Xray (actual ${XRAY_INTERNAL_PORT}): " xray_port_in

  [[ -z "${domain_in}" ]] && { err "Dominio requerido."; return 1; }
  [[ -z "${email_in}" ]] && { err "Correo requerido."; return 1; }
  [[ -z "${xray_port_in}" ]] && xray_port_in="${XRAY_INTERNAL_PORT}"

  if ! [[ "${xray_port_in}" =~ ^[0-9]+$ ]] || (( xray_port_in < 1 || xray_port_in > 65535 )); then
    err "Puerto interno invalido."
    return 1
  fi

  DOMAIN="${domain_in}"
  EMAIL="${email_in}"
  XRAY_INTERNAL_PORT="${xray_port_in}"

  install_base_packages
  install_xray

  XRAY_UUID="$(cat /proc/sys/kernel/random/uuid)"

  mkdir -p /usr/local/etc/xray
  cat > "${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${XRAY_INTERNAL_PORT},
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/vless"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

  cat > "${XRAY_SERVICE}" <<'EOF'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

  cat > "${NGINX_SITE}" <<EOF
server {
    listen ${NGINX_HTTP_PORT};
    server_name ${DOMAIN};

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen ${NGINX_HTTPS_PORT} ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location /vless {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${XRAY_INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

  ln -sf "${NGINX_SITE}" /etc/nginx/sites-enabled/vpn-panel.conf
  rm -f /etc/nginx/sites-enabled/default

  nginx -t
  systemctl reload nginx

  certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "${EMAIL}" --redirect

  systemctl daemon-reload
  systemctl enable xray
  systemctl restart xray
  systemctl reload nginx

  save_state
  log "Xray + WebSocket + SSL configurado."
}

service_status() {
  local svc="$1"
  if systemctl is-active --quiet "${svc}"; then
    printf "\033[1;32m[ON]\033[0m"
  else
    printf "\033[1;31m[OFF]\033[0m"
  fi
}

show_connection_info() {
  load_state
  local ip_public
  ip_public="$(curl -s https://ipv4.icanhazip.com || echo "IP_NO_DISPONIBLE")"
  clear
  echo "========================================================"
  echo "                ${SCRIPT_NAME}"
  echo "========================================================"
  echo "SSH: ${SSH_PORT}"
  echo "Nginx: ${NGINX_HTTP_PORT}/${NGINX_HTTPS_PORT}   Estado: $(service_status nginx)"
  echo "Xray interno: ${XRAY_INTERNAL_PORT}   Estado: $(service_status xray)"
  echo "IP publica: ${ip_public}"
  echo "Dominio: ${DOMAIN:-NO CONFIGURADO}"
  echo "--------------------------------------------------------"
  if [[ -n "${XRAY_UUID:-}" && -n "${DOMAIN:-}" ]]; then
    echo "URL VLESS sugerida:"
    echo "vless://${XRAY_UUID}@${DOMAIN}:${NGINX_HTTPS_PORT}?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=%2Fvless#VPN-PANEL"
  else
    echo "Aun no hay perfil VLESS generado."
  fi
  echo "========================================================"
  read -r -p "Enter para volver..."
}

protocol_menu() {
  while true; do
    load_state
    clear
    echo "========================================================"
    echo "              ADMINISTRADOR DE PROTOCOLOS"
    echo "========================================================"
    echo "SSH: ${SSH_PORT} | NGINX: ${NGINX_HTTP_PORT}/${NGINX_HTTPS_PORT} | XRAY: ${XRAY_INTERNAL_PORT}"
    echo "--------------------------------------------------------"
    echo "[1] AJUSTES SSH"
    echo "[2] INSTALAR/ACTUALIZAR NGINX"
    echo "[3] CONFIGURAR XRAY (V2RAY) + WS + SSL"
    echo "[4] MOSTRAR DATOS DE CONEXION"
    echo "[0] VOLVER"
    echo "--------------------------------------------------------"
    read -r -p "Ingresa una opcion: " opt
    case "${opt}" in
      1) configure_ssh_port ;;
      2) install_base_packages ;;
      3) configure_xray_vless_ws ;;
      4) show_connection_info ;;
      0) break ;;
      *) warn "Opcion invalida." ; sleep 1 ;;
    esac
  done
}

extras_menu() {
  while true; do
    clear
    echo "========================================================"
    echo "                HERRAMIENTAS EXTRAS"
    echo "========================================================"
    echo "[1] REINICIAR SERVICIOS (nginx + xray)"
    echo "[2] VER ESTADO SERVICIOS"
    echo "[0] VOLVER"
    echo "--------------------------------------------------------"
    read -r -p "Ingresa una opcion: " opt
    case "${opt}" in
      1)
        systemctl restart nginx || true
        systemctl restart xray || true
        log "Servicios reiniciados."
        sleep 1
      ;;
      2)
        echo "nginx: $(service_status nginx)"
        echo "xray:  $(service_status xray)"
        read -r -p "Enter para volver..."
      ;;
      0) break ;;
      *) warn "Opcion invalida." ; sleep 1 ;;
    esac
  done
}

main_menu() {
  while true; do
    load_state
    clear
    echo "========================================================"
    echo "                     J DAVID AG"
    echo "========================================================"
    echo "S.O: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
    echo "Fecha: $(date +%d-%m-%Y)   Hora: $(date +%H:%M:%S)"
    echo "--------------------------------------------------------"
    echo "[1] ADMINISTRAR CUENTAS (SSH/DROPBEAR) [proximo]"
    echo "[2] ADMINISTRAR CUENTAS (V2RAY/XRAY)   [proximo]"
    echo "[3] CONFIGURACION DE PROTOCOLOS"
    echo "[4] HERRAMIENTAS EXTRAS"
    echo "[5] CONFIGURACION DEL SCRIPT            [proximo]"
    echo "[6] IDIOMA / LANGUAGE                   [proximo]"
    echo "[7] DESINSTALAR PANEL"
    echo "[0] SALIR"
    echo "--------------------------------------------------------"
    read -r -p "Ingresa una opcion: " opt

    case "${opt}" in
      3) protocol_menu ;;
      4) extras_menu ;;
      7)
        read -r -p "Confirmar desinstalacion del panel (si/no): " confirm
        if [[ "${confirm}" == "si" ]]; then
          rm -f "${STATE_FILE}"
          warn "Panel desinstalado (se conservaron servicios instalados)."
          sleep 1
        fi
      ;;
      0) exit 0 ;;
      1|2|5|6) warn "Opcion en desarrollo." ; sleep 1 ;;
      *) warn "Opcion invalida." ; sleep 1 ;;
    esac
  done
}

main_menu
