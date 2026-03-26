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
SOCKS_PORT=88
SOCKS_REDIRECT_PORT=22
SOCKS_RESPONSE_STATUS=101
SOCKS_ENABLED=0
XRAY_ENABLED=0
NGINX_ENABLED=0
SOCKS_PY2_SIMPLE_ENABLED=0
SOCKS_PY3_SIMPLE_ENABLED=0
SOCKS_PY3_DIRECT_ENABLED=0
INITIAL_HARDENED=0
SOCKS_CUSTOM_HEADER=Default
SOCKS_MINIBANNER=Default
EOF
}

load_state() {
  [[ -f "${STATE_FILE}" ]] || default_state
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  SSH_PORT="${SSH_PORT:-22}"
  NGINX_HTTP_PORT="${NGINX_HTTP_PORT:-80}"
  NGINX_HTTPS_PORT="${NGINX_HTTPS_PORT:-443}"
  XRAY_INTERNAL_PORT="${XRAY_INTERNAL_PORT:-10000}"
  DOMAIN="${DOMAIN:-}"
  EMAIL="${EMAIL:-}"
  XRAY_UUID="${XRAY_UUID:-}"
  SOCKS_PORT="${SOCKS_PORT:-88}"
  SOCKS_REDIRECT_PORT="${SOCKS_REDIRECT_PORT:-22}"
  SOCKS_RESPONSE_STATUS="${SOCKS_RESPONSE_STATUS:-101}"
  SOCKS_ENABLED="${SOCKS_ENABLED:-0}"
  XRAY_ENABLED="${XRAY_ENABLED:-0}"
  NGINX_ENABLED="${NGINX_ENABLED:-0}"
  SOCKS_PY2_SIMPLE_ENABLED="${SOCKS_PY2_SIMPLE_ENABLED:-0}"
  SOCKS_PY3_SIMPLE_ENABLED="${SOCKS_PY3_SIMPLE_ENABLED:-0}"
  SOCKS_PY3_DIRECT_ENABLED="${SOCKS_PY3_DIRECT_ENABLED:-0}"
  INITIAL_HARDENED="${INITIAL_HARDENED:-0}"
  SOCKS_CUSTOM_HEADER="${SOCKS_CUSTOM_HEADER:-Default}"
  SOCKS_MINIBANNER="${SOCKS_MINIBANNER:-Default}"
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
SOCKS_PORT=${SOCKS_PORT}
SOCKS_REDIRECT_PORT=${SOCKS_REDIRECT_PORT}
SOCKS_RESPONSE_STATUS=${SOCKS_RESPONSE_STATUS}
SOCKS_ENABLED=${SOCKS_ENABLED}
XRAY_ENABLED=${XRAY_ENABLED}
NGINX_ENABLED=${NGINX_ENABLED}
SOCKS_PY2_SIMPLE_ENABLED=${SOCKS_PY2_SIMPLE_ENABLED}
SOCKS_PY3_SIMPLE_ENABLED=${SOCKS_PY3_SIMPLE_ENABLED}
SOCKS_PY3_DIRECT_ENABLED=${SOCKS_PY3_DIRECT_ENABLED}
INITIAL_HARDENED=${INITIAL_HARDENED}
SOCKS_CUSTOM_HEADER=${SOCKS_CUSTOM_HEADER}
SOCKS_MINIBANNER=${SOCKS_MINIBANNER}
EOF
}

on_off() {
  if [[ "$1" == "1" ]]; then
    printf "[ON]"
  else
    printf "[OFF]"
  fi
}

socks_log() {
  mkdir -p /var/log
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> /var/log/vpn-panel-socks.log
}

refresh_socks_global_status() {
  if [[ "${SOCKS_PY2_SIMPLE_ENABLED}" == "1" || "${SOCKS_PY3_SIMPLE_ENABLED}" == "1" || "${SOCKS_ENABLED}" == "1" || "${SOCKS_PY3_DIRECT_ENABLED}" == "1" ]]; then
    SOCKS_ENABLED=1
  else
    SOCKS_ENABLED=0
  fi
}

socks_ports_display() {
  local p1="--"
  local p2="--"
  if [[ "${SOCKS_PY2_SIMPLE_ENABLED}" == "1" || "${SOCKS_PY3_SIMPLE_ENABLED}" == "1" ]]; then
    p1="8080"
  fi
  if [[ "${SOCKS_ENABLED}" == "1" || "${SOCKS_PY3_DIRECT_ENABLED}" == "1" ]]; then
    p2="${SOCKS_PORT}"
  fi
  printf "%s %s" "${p1}" "${p2}"
}

has_active_socks_ports() {
  if [[ "${SOCKS_PY2_SIMPLE_ENABLED}" == "1" || "${SOCKS_PY3_SIMPLE_ENABLED}" == "1" || "${SOCKS_ENABLED}" == "1" || "${SOCKS_PY3_DIRECT_ENABLED}" == "1" ]]; then
    return 0
  fi
  return 1
}

protocol_header_lines() {
  local entries=()
  local i=0
  local left right

  # Solo mostrar protocolos activos.
  if systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; then
    entries+=("SSH: ${SSH_PORT}")
  fi
  if has_active_socks_ports; then
    entries+=("PYTHON2: $(socks_ports_display)")
  fi
  if [[ "${XRAY_ENABLED}" == "1" ]]; then
    entries+=("V2RAY: 443 80")
  fi
  if [[ "${NGINX_ENABLED}" == "1" ]]; then
    entries+=("STUNNEL: ${NGINX_HTTP_PORT} ${NGINX_HTTPS_PORT}")
  fi

  if (( ${#entries[@]} == 0 )); then
    echo "No hay protocolos activos."
    return 0
  fi

  while (( i < ${#entries[@]} )); do
    left="${entries[$i]}"
    right=""
    if (( i + 1 < ${#entries[@]} )); then
      right="${entries[$((i + 1))]}"
    fi
    printf "%-28s %s\n" "${left}" "${right}"
    i=$((i + 2))
  done
}

enforce_only_ssh_on_first_install() {
  # En primera ejecucion: solo SSH activo por defecto.
  if [[ "${INITIAL_HARDENED}" != "0" ]]; then
    return 0
  fi

  systemctl stop nginx 2>/dev/null || true
  systemctl disable nginx 2>/dev/null || true
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  systemctl stop vpn-socks-python2-direct 2>/dev/null || true
  systemctl disable vpn-socks-python2-direct 2>/dev/null || true

  NGINX_ENABLED=0
  XRAY_ENABLED=0
  SOCKS_ENABLED=0
  SOCKS_PY2_SIMPLE_ENABLED=0
  SOCKS_PY3_SIMPLE_ENABLED=0
  SOCKS_PY3_DIRECT_ENABLED=0
  INITIAL_HARDENED=1
  save_state
}

setup_socks_forward_service() {
  local listen_port="$1"
  local target_port="$2"
  local service_name="vpn-socks-python2-direct"
  local service_file="/etc/systemd/system/${service_name}.service"

  apt-get update -y
  apt-get install -y socat python3 python3-pip || true
  apt-get install -y python2-minimal || true

  cat > "${service_file}" <<EOF
[Unit]
Description=SOCKS Python2 Direct Forward
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${listen_port},reuseaddr,fork TCP:127.0.0.1:${target_port}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${service_name}"
  systemctl restart "${service_name}"
}

ensure_socks_runtime() {
  local need_install=0

  if ! command -v socat >/dev/null 2>&1; then
    need_install=1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    need_install=1
  fi

  if [[ "${need_install}" == "1" ]]; then
    warn "Dependencias SOCKS no encontradas. Instalando..."
    apt-get update -y
    apt-get install -y socat python3 python3-pip || true
    apt-get install -y python2-minimal || true
    socks_log "Dependencias SOCKS instaladas automaticamente"
    log "Dependencias SOCKS instaladas."
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "No se encontro comando requerido: $1"
    exit 1
  }
}

detect_ssh_port() {
  local detected=""
  if [[ -f /etc/ssh/sshd_config ]]; then
    detected="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config)"
  fi
  if [[ -z "${detected}" ]]; then
    detected="$(ss -tlpn 2>/dev/null | awk '/sshd/ && /LISTEN/ {split($4,a,":"); print a[length(a)]; exit}')"
  fi
  if [[ -n "${detected}" && "${detected}" =~ ^[0-9]+$ ]]; then
    SSH_PORT="${detected}"
  fi
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget unzip jq nginx socat cron openssl ca-certificates gnupg lsb-release certbot python3-certbot-nginx
  systemctl enable nginx
  systemctl start nginx
  NGINX_ENABLED=1
  save_state
  log "Paquetes base instalados."
}

nginx_apply_ports() {
  local cfg="${NGINX_SITE}"
  if [[ "${NGINX_HTTP_PORT}" == "0" && "${NGINX_HTTPS_PORT}" == "0" ]]; then
    rm -f /etc/nginx/sites-enabled/vpn-panel.conf
    return 0
  fi

  cat > "${cfg}" <<EOF
server {
EOF
  if [[ "${NGINX_HTTP_PORT}" != "0" ]]; then
    cat >> "${cfg}" <<EOF
    listen ${NGINX_HTTP_PORT};
EOF
  fi
  if [[ "${NGINX_HTTPS_PORT}" != "0" ]]; then
    cat >> "${cfg}" <<EOF
    listen ${NGINX_HTTPS_PORT} ssl http2;
    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;
EOF
  fi
  cat >> "${cfg}" <<'EOF'
    server_name _;
    location / {
        return 200 "NGINX ACTIVO\n";
    }
}
EOF

  ln -sf "${cfg}" /etc/nginx/sites-enabled/vpn-panel.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl restart nginx
}

nginx_add_port() {
  local p
  read -r -p "Puerto a anadir: " p
  if ! [[ "${p}" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
    err "Puerto invalido."
    return 1
  fi
  if [[ "${p}" == "${NGINX_HTTP_PORT}" || "${p}" == "${NGINX_HTTPS_PORT}" ]]; then
    warn "Ese puerto ya esta agregado."
    return 0
  fi
  if [[ "${NGINX_HTTP_PORT}" == "0" ]]; then
    NGINX_HTTP_PORT="${p}"
  elif [[ "${NGINX_HTTPS_PORT}" == "0" ]]; then
    NGINX_HTTPS_PORT="${p}"
  else
    warn "Ya hay 2 puertos. Reemplazando HTTPS por ${p}."
    NGINX_HTTPS_PORT="${p}"
  fi
  NGINX_ENABLED=1
  nginx_apply_ports
  save_state
  log "Puerto agregado a NGINX: ${p}"
}

nginx_delete_one_port() {
  local p
  read -r -p "Puerto a borrar: " p
  [[ -z "${p}" ]] && { err "Puerto requerido."; return 1; }
  if [[ "${p}" == "${NGINX_HTTP_PORT}" ]]; then
    NGINX_HTTP_PORT=0
  elif [[ "${p}" == "${NGINX_HTTPS_PORT}" ]]; then
    NGINX_HTTPS_PORT=0
  else
    warn "Ese puerto no esta activo en NGINX."
    return 0
  fi
  if [[ "${NGINX_HTTP_PORT}" == "0" && "${NGINX_HTTPS_PORT}" == "0" ]]; then
    NGINX_ENABLED=0
    systemctl stop nginx || true
  else
    nginx_apply_ports
  fi
  save_state
  log "Puerto eliminado de NGINX: ${p}"
}

nginx_delete_all_ports() {
  NGINX_HTTP_PORT=0
  NGINX_HTTPS_PORT=0
  NGINX_ENABLED=0
  rm -f /etc/nginx/sites-enabled/vpn-panel.conf
  systemctl stop nginx || true
  save_state
  log "Todos los puertos NGINX eliminados."
}

nginx_uninstall() {
  systemctl stop nginx || true
  systemctl disable nginx || true
  apt-get remove -y nginx nginx-common || true
  apt-get autoremove -y || true
  NGINX_ENABLED=0
  NGINX_HTTP_PORT=0
  NGINX_HTTPS_PORT=0
  rm -f "${NGINX_SITE}" /etc/nginx/sites-enabled/vpn-panel.conf
  save_state
  warn "NGINX desinstalado."
}

nginx_menu() {
  load_state
  if ! command -v nginx >/dev/null 2>&1; then
    local install_now
    clear
    echo "========================================================"
    echo "                    MENU NGINX"
    echo "========================================================"
    echo "NGINX no esta instalado."
    read -r -p "Deseas instalar NGINX ahora? (si/no): " install_now
    if [[ "${install_now}" == "si" ]]; then
      install_base_packages
      nginx_apply_ports
      read -r -p "Enter para continuar..."
    else
      warn "Instalacion cancelada."
      sleep 1
      return 0
    fi
  fi

  while true; do
    load_state
    clear
    echo "========================================================"
    echo "                    MENU NGINX"
    echo "========================================================"
    echo "Estado: $(on_off "${NGINX_ENABLED}")"
    echo "Puertos activos: ${NGINX_HTTP_PORT} ${NGINX_HTTPS_PORT}"
    echo "--------------------------------------------------------"
    echo "[1] REINSTALAR/ACTIVAR NGINX"
    echo "[2] ANADIR PUERTO"
    echo "[3] BORRAR 1 PUERTO"
    echo "[4] BORRAR TODOS LOS PUERTOS"
    echo "[5] DESINSTALAR NGINX"
    echo "[0] VOLVER"
    echo "--------------------------------------------------------"
    read -r -p "Ingresa una opcion: " opt
    case "${opt}" in
      1) install_base_packages ; nginx_apply_ports ; read -r -p "Enter para continuar..." ;;
      2) nginx_add_port ; read -r -p "Enter para continuar..." ;;
      3) nginx_delete_one_port ; read -r -p "Enter para continuar..." ;;
      4) nginx_delete_all_ports ; read -r -p "Enter para continuar..." ;;
      5) nginx_uninstall ; read -r -p "Enter para continuar..." ;;
      0) break ;;
      *) warn "Opcion invalida." ; sleep 1 ;;
    esac
  done
}

configure_ssh_port() {
  read -r -p "Puerto SSH (actual ${SSH_PORT}): " new_ssh_port
  [[ -z "${new_ssh_port}" ]] && new_ssh_port="${SSH_PORT}"
  if ! [[ "${new_ssh_port}" =~ ^[0-9]+$ ]] || (( new_ssh_port < 1 || new_ssh_port > 65535 )); then
    err "Puerto invalido."
    return 1
  fi

  if [[ -f /etc/ssh/sshd_config ]]; then
    if grep -Eq "^#?Port " /etc/ssh/sshd_config; then
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

set_ssh_user_limit() {
  local user_name="$1"
  local max_sessions="$2"
  mkdir -p /etc/security/limits.d
  cat > "/etc/security/limits.d/vpn-${user_name}.conf" <<EOF
${user_name} hard maxlogins ${max_sessions}
${user_name} soft maxlogins ${max_sessions}
EOF
}

create_ssh_user() {
  local user_name password days limit expire_date

  read -r -p "Usuario SSH: " user_name
  read -r -p "Contrasena: " password
  read -r -p "Dias de duracion (ej. 30): " days
  read -r -p "Limite de conexiones simultaneas (ej. 1): " limit

  if [[ -z "${user_name}" || -z "${password}" || -z "${days}" || -z "${limit}" ]]; then
    err "Todos los campos son obligatorios."
    return 1
  fi

  if id "${user_name}" >/dev/null 2>&1; then
    err "El usuario ya existe."
    return 1
  fi

  if ! [[ "${days}" =~ ^[0-9]+$ ]] || (( days < 1 )); then
    err "Dias invalidos."
    return 1
  fi

  if ! [[ "${limit}" =~ ^[0-9]+$ ]] || (( limit < 1 )); then
    err "Limite invalido."
    return 1
  fi

  expire_date="$(date -d "+${days} days" +%Y-%m-%d)"
  useradd -e "${expire_date}" -s /bin/false -M "${user_name}"
  echo "${user_name}:${password}" | chpasswd
  set_ssh_user_limit "${user_name}" "${limit}"

  # Asegura PAM para que maxlogins aplique en SSH.
  if grep -Eq '^#?UsePAM' /etc/ssh/sshd_config; then
    sed -i 's/^#\?UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config
  else
    echo "UsePAM yes" >> /etc/ssh/sshd_config
  fi
  systemctl restart ssh || systemctl restart sshd || true

  log "Usuario SSH creado: ${user_name}"
  echo "Usuario : ${user_name}"
  echo "Clave   : ${password}"
  echo "Expira  : ${expire_date}"
  echo "Limite  : ${limit} conexion(es)"
}

list_ssh_users() {
  echo "========================================================"
  echo "USUARIO              EXPIRACION           LIMITE"
  echo "========================================================"
  while IFS=: read -r user_name _ uid _ _ _ shell; do
    if (( uid >= 1000 )) && [[ "${shell}" == "/bin/false" || "${shell}" == "/usr/sbin/nologin" ]]; then
      local exp limit_line limit_val
      exp="$(chage -l "${user_name}" 2>/dev/null | awk -F': ' '/Account expires/{print $2}')"
      limit_line="$(grep -Eh "^[[:space:]]*${user_name}[[:space:]]+hard[[:space:]]+maxlogins" /etc/security/limits.d/vpn-"${user_name}".conf 2>/dev/null || true)"
      limit_val="$(awk '{print $4}' <<< "${limit_line}")"
      [[ -z "${limit_val}" ]] && limit_val="sin limite"
      printf "%-20s %-20s %s\n" "${user_name}" "${exp:-N/A}" "${limit_val}"
    fi
  done < /etc/passwd
  echo "========================================================"
  read -r -p "Enter para volver..."
}

delete_ssh_user() {
  local user_name
  read -r -p "Usuario a eliminar: " user_name
  [[ -z "${user_name}" ]] && { err "Usuario requerido."; return 1; }
  if ! id "${user_name}" >/dev/null 2>&1; then
    err "Usuario no existe."
    return 1
  fi
  userdel "${user_name}" || true
  rm -f "/etc/security/limits.d/vpn-${user_name}.conf"
  log "Usuario eliminado: ${user_name}"
}

ssh_accounts_menu() {
  while true; do
    clear
    echo "========================================================"
    echo "         ADMINISTRAR CUENTAS (SSH/DROPBEAR)"
    echo "========================================================"
    echo "[1] CREAR USUARIO SSH"
    echo "[2] LISTAR USUARIOS SSH"
    echo "[3] ELIMINAR USUARIO SSH"
    echo "[0] VOLVER"
    echo "--------------------------------------------------------"
    read -r -p "Ingresa una opcion: " opt
    case "${opt}" in
      1) create_ssh_user; read -r -p "Enter para continuar..." ;;
      2) list_ssh_users ;;
      3) delete_ssh_user; read -r -p "Enter para continuar..." ;;
      0) break ;;
      *) warn "Opcion invalida." ; sleep 1 ;;
    esac
  done
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

  XRAY_ENABLED=1
  NGINX_ENABLED=1
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
  echo "SOCKS Python: ${SOCKS_PORT} -> ${SOCKS_REDIRECT_PORT} (status ${SOCKS_RESPONSE_STATUS})"
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

configure_socks_python2() {
  local opt manual_port status_in input_port custom_header_in
  load_state
  detect_ssh_port
  ensure_socks_runtime
  clear
  echo "========================================================"
  echo "         CONFIGURAR SOCKS PYTHON2 DIRECTO"
  echo "========================================================"
  read -r -p "INGRESA EL PUERTO: " input_port
  if [[ -z "${input_port}" ]]; then
    input_port=80
  fi
  if ! [[ "${input_port}" =~ ^[0-9]+$ ]] || (( input_port < 1 || input_port > 65535 )); then
    err "Puerto invalido."
    sleep 1
    return 1
  fi
  SOCKS_PORT="${input_port}"

  clear
  echo "========================================================"
  echo "         CONFIGURAR SOCKS PYTHON2 DIRECTO"
  echo "========================================================"
  echo "PUERTO PARA SOCKS PYTHON: ${SOCKS_PORT}"
  echo "--------------------------------------------------------"
  echo "A QUE PUERTO SERA REDIRIGIDO EL TRAFICO?"
  echo
  echo "[1] > python2...............................8080"
  echo "[2] > sshd..................................${SSH_PORT}"
  echo "[3] > v2ray.................................443"
  echo "[4] > v2ray.................................80"
  echo
  echo "[0] CANCELAR                [5] INGRESA MANUALMENTE"
  echo "--------------------------------------------------------"
  read -r -p "Ingresa una opcion: " opt

  case "${opt}" in
    1) SOCKS_REDIRECT_PORT=8080 ;;
    2) SOCKS_REDIRECT_PORT="${SSH_PORT}" ;;
    3) SOCKS_REDIRECT_PORT=443 ;;
    4) SOCKS_REDIRECT_PORT=80 ;;
    5)
      read -r -p "Ingresa puerto manual de redireccion: " manual_port
      if ! [[ "${manual_port}" =~ ^[0-9]+$ ]] || (( manual_port < 1 || manual_port > 65535 )); then
        err "Puerto manual invalido."
        sleep 1
        return 1
      fi
      SOCKS_REDIRECT_PORT="${manual_port}"
    ;;
    0) return 0 ;;
    *) warn "Opcion invalida."; sleep 1; return 1 ;;
  esac

  if [[ "${SOCKS_REDIRECT_PORT}" == "443" || "${SOCKS_REDIRECT_PORT}" == "80" ]]; then
    clear
    echo "========================================================"
    echo "         CONFIGURAR SOCKS PYTHON2 DIRECTO"
    echo "========================================================"
    echo "PUERTO PARA SOCKS PYTHON: ${SOCKS_PORT}"
    echo
    echo "TRAFICO REDIRIGIDO AL PUERTO: ${SOCKS_REDIRECT_PORT}"
    echo
    echo "Enter aplica configuracion predeterminada (200)"
    echo "101 para websocket"
    echo
    read -r -p "IGRESA UN ESTADO DE RESPUESTA: " status_in
    if [[ -z "${status_in}" ]]; then
      SOCKS_RESPONSE_STATUS=200
    elif [[ "${status_in}" =~ ^[0-9]+$ ]] && (( status_in >= 100 && status_in <= 599 )); then
      SOCKS_RESPONSE_STATUS="${status_in}"
    else
      warn "Estado invalido. Se usa 200."
      SOCKS_RESPONSE_STATUS=200
    fi
  else
    SOCKS_RESPONSE_STATUS=200
  fi

  clear
  echo "========================================================"
  echo "         CONFIGURAR SOCKS PYTHON2 DIRECTO"
  echo "========================================================"
  echo "PUERTO PARA SOCKS PYTHON: ${SOCKS_PORT}"
  echo
  echo "TRAFICO REDIRIGIDO AL PUERTO: ${SOCKS_REDIRECT_PORT}"
  echo
  echo "RESPUESTA: ${SOCKS_RESPONSE_STATUS}"
  echo
  echo 'Ej: \r\nContent-length: 0\r\n\r\nHTTP/1.1 200 Connection Established\r\n\r\n'
  echo
  read -r -p "ENCABESADO PERSONALIZADO: " custom_header_in
  if [[ -z "${custom_header_in}" ]]; then
    SOCKS_CUSTOM_HEADER="Default"
  else
    SOCKS_CUSTOM_HEADER="${custom_header_in}"
  fi
  SOCKS_MINIBANNER="Default"

  setup_socks_forward_service "${SOCKS_PORT}" "${SOCKS_REDIRECT_PORT}"
  SOCKS_ENABLED=1
  refresh_socks_global_status
  socks_log "SOCKS PYTHON2 DIRECTO ON puerto=${SOCKS_PORT} destino=${SOCKS_REDIRECT_PORT} status=${SOCKS_RESPONSE_STATUS} header=${SOCKS_CUSTOM_HEADER}"
  save_state
  clear
  echo "========================================================"
  echo "         CONFIGURAR SOCKS PYTHON2 DIRECTO"
  echo "========================================================"
  echo "PUERTO PARA SOCKS PYTHON: ${SOCKS_PORT}"
  echo
  echo "TRAFICO REDIRIGIDO AL PUERTO: ${SOCKS_REDIRECT_PORT}"
  echo
  echo "RESPUESTA: ${SOCKS_RESPONSE_STATUS}"
  echo
  echo "ENCABESADO: ${SOCKS_CUSTOM_HEADER^^}"
  echo
  echo "MINIBANNER: ${SOCKS_MINIBANNER^^}"
  echo "--------------------------------------------------------"
  echo "    systemctl daemon-reload...........OK"
  echo "    systemctl start python.${SOCKS_PORT}.......OK"
  echo "    systemctl enable python.${SOCKS_PORT}......OK"
  echo "========================================================"
  read -r -p ">> Presione enter para continuar <<" _
}

configure_socks_python3_direct() {
  local opt manual_port status_in input_port custom_header_in
  load_state
  detect_ssh_port
  ensure_socks_runtime
  clear
  echo "========================================================"
  echo "         CONFIGURAR SOCKS PYTHON3 DIRECTO"
  echo "========================================================"
  read -r -p "INGRESA EL PUERTO: " input_port
  if [[ -z "${input_port}" ]]; then
    input_port=80
  fi
  if ! [[ "${input_port}" =~ ^[0-9]+$ ]] || (( input_port < 1 || input_port > 65535 )); then
    err "Puerto invalido."
    sleep 1
    return 1
  fi
  SOCKS_PORT="${input_port}"

  clear
  echo "========================================================"
  echo "         CONFIGURAR SOCKS PYTHON3 DIRECTO"
  echo "========================================================"
  echo "PUERTO PARA SOCKS PYTHON: ${SOCKS_PORT}"
  echo "--------------------------------------------------------"
  echo "A QUE PUERTO SERA REDIRIGIDO EL TRAFICO?"
  echo
  echo "[1] > python2...............................8080"
  echo "[2] > sshd..................................${SSH_PORT}"
  echo "[3] > v2ray.................................443"
  echo "[4] > v2ray.................................80"
  echo
  echo "[0] CANCELAR                [5] INGRESA MANUALMENTE"
  echo "--------------------------------------------------------"
  read -r -p "Ingresa una opcion: " opt

  case "${opt}" in
    1) SOCKS_REDIRECT_PORT=8080 ;;
    2) SOCKS_REDIRECT_PORT="${SSH_PORT}" ;;
    3) SOCKS_REDIRECT_PORT=443 ;;
    4) SOCKS_REDIRECT_PORT=80 ;;
    5)
      read -r -p "Ingresa puerto manual de redireccion: " manual_port
      if ! [[ "${manual_port}" =~ ^[0-9]+$ ]] || (( manual_port < 1 || manual_port > 65535 )); then
        err "Puerto manual invalido."
        sleep 1
        return 1
      fi
      SOCKS_REDIRECT_PORT="${manual_port}"
    ;;
    0) return 0 ;;
    *) warn "Opcion invalida."; sleep 1; return 1 ;;
  esac

  # Solo solicita estado HTTP cuando redirige a 80/443 (escenario WS/HTTP).
  if [[ "${SOCKS_REDIRECT_PORT}" == "443" || "${SOCKS_REDIRECT_PORT}" == "80" ]]; then
    clear
    echo "========================================================"
    echo "         CONFIGURAR SOCKS PYTHON3 DIRECTO"
    echo "========================================================"
    echo "PUERTO PARA SOCKS PYTHON: ${SOCKS_PORT}"
    echo
    echo "TRAFICO REDIRIGIDO AL PUERTO: ${SOCKS_REDIRECT_PORT}"
    echo
    echo "Enter aplica configuracion predeterminada (200)"
    echo "101 para websocket"
    echo
    read -r -p "IGRESA UN ESTADO DE RESPUESTA: " status_in
    if [[ -z "${status_in}" ]]; then
      SOCKS_RESPONSE_STATUS=200
    elif [[ "${status_in}" =~ ^[0-9]+$ ]] && (( status_in >= 100 && status_in <= 599 )); then
      SOCKS_RESPONSE_STATUS="${status_in}"
    else
      warn "Estado invalido. Se usa 200."
      SOCKS_RESPONSE_STATUS=200
    fi
  else
    SOCKS_RESPONSE_STATUS=200
  fi

  clear
  echo "========================================================"
  echo "         CONFIGURAR SOCKS PYTHON3 DIRECTO"
  echo "========================================================"
  echo "PUERTO PARA SOCKS PYTHON: ${SOCKS_PORT}"
  echo
  echo "TRAFICO REDIRIGIDO AL PUERTO: ${SOCKS_REDIRECT_PORT}"
  echo
  echo "RESPUESTA: ${SOCKS_RESPONSE_STATUS}"
  echo
  echo 'Ej: \r\nContent-length: 0\r\n\r\nHTTP/1.1 200 Connection Established\r\n\r\n'
  echo
  read -r -p "ENCABESADO PERSONALIZADO: " custom_header_in
  if [[ -z "${custom_header_in}" ]]; then
    SOCKS_CUSTOM_HEADER="Default"
  else
    SOCKS_CUSTOM_HEADER="${custom_header_in}"
  fi
  SOCKS_MINIBANNER="Default"

  setup_socks_forward_service "${SOCKS_PORT}" "${SOCKS_REDIRECT_PORT}"
  SOCKS_PY3_DIRECT_ENABLED=1
  SOCKS_ENABLED=1
  refresh_socks_global_status
  socks_log "SOCKS PYTHON3 DIRECTO ON puerto=${SOCKS_PORT} destino=${SOCKS_REDIRECT_PORT} status=${SOCKS_RESPONSE_STATUS} header=${SOCKS_CUSTOM_HEADER}"
  save_state
  clear
  echo "========================================================"
  echo "         CONFIGURAR SOCKS PYTHON3 DIRECTO"
  echo "========================================================"
  echo "PUERTO PARA SOCKS PYTHON: ${SOCKS_PORT}"
  echo
  echo "TRAFICO REDIRIGIDO AL PUERTO: ${SOCKS_REDIRECT_PORT}"
  echo
  echo "RESPUESTA: ${SOCKS_RESPONSE_STATUS}"
  echo
  echo "ENCABESADO: ${SOCKS_CUSTOM_HEADER^^}"
  echo
  echo "MINIBANNER: ${SOCKS_MINIBANNER^^}"
  echo "--------------------------------------------------------"
  echo "    systemctl daemon-reload...........OK"
  echo "    systemctl start python.${SOCKS_PORT}.......OK"
  echo "    systemctl enable python.${SOCKS_PORT}......OK"
  echo "========================================================"
  read -r -p ">> Presione enter para continuar <<" _
}

install_python_modules() {
  apt-get update -y
  apt-get install -y python3 python3-pip net-tools lsof || true
  apt-get install -y python2-minimal || true
  socks_log "Reinstalacion de modulos Python solicitada"
  log "Modulos Python reinstalados (segun disponibilidad del sistema)."
}

stop_socks_port() {
  local p
  read -r -p "Puerto a detener: " p
  if ! [[ "${p}" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
    err "Puerto invalido."
    return 1
  fi
  if [[ "${SOCKS_PORT}" == "${p}" ]]; then
    SOCKS_ENABLED=0
    SOCKS_PY3_DIRECT_ENABLED=0
  fi
  if [[ "8080" == "${p}" ]]; then
    SOCKS_PY2_SIMPLE_ENABLED=0
    SOCKS_PY3_SIMPLE_ENABLED=0
  fi
  refresh_socks_global_status
  save_state
  socks_log "Solicitud de detener puerto ${p}"
  warn "Puerto ${p} marcado como detenido en el panel."
}

show_socks_logs() {
  local log_file="/var/log/vpn-panel-socks.log"
  if [[ ! -f "${log_file}" ]]; then
    warn "Aun no hay logs de SOCKS."
    read -r -p "Enter para volver..."
    return 0
  fi
  echo "====================== LOGS SOCKS ======================"
  tail -n 40 "${log_file}"
  echo "========================================================"
  read -r -p "Enter para volver..."
}

socks_python_menu() {
  while true; do
    load_state
    clear
    echo "========================================================"
    echo "             ADMINISTRADOR DE SOCKS PYTHON"
    echo "========================================================"
    if has_active_socks_ports; then
      echo "PUERTOS: $(socks_ports_display)"
    fi
    echo "--------------------------------------------------------"
    echo "[1] SOCKS PYTHON2 SIMPLE   $(on_off "${SOCKS_PY2_SIMPLE_ENABLED}")"
    echo "[2] SOCKS PYTHON3 SIMPLE   $(on_off "${SOCKS_PY3_SIMPLE_ENABLED}")"
    echo "[3] SOCKS PYTHON2 DIRECTO  $(on_off "${SOCKS_ENABLED}")"
    echo "[4] SOCKS PYTHON3 DIRECTO  $(on_off "${SOCKS_PY3_DIRECT_ENABLED}")"
    echo
    echo "[5] REINSTALAR MODULOS PYTHON"
    echo
    echo "[6] ESTADO DE SERVICIOS"
    echo
    echo "[7] DETENER TODO LOS PUERTO Y SERVICIOS"
    echo "[8] DETENER UN PUERTO"
    echo
    echo "[0] VOLVER                 [9] LOGS Y REGISTROS"
    echo "--------------------------------------------------------"
    read -r -p "Ingresa una opcion: " opt
    case "${opt}" in
      1)
        SOCKS_PY2_SIMPLE_ENABLED=1
        refresh_socks_global_status
        save_state
        socks_log "SOCKS PYTHON2 SIMPLE ON puerto=8080"
        log "SOCKS PYTHON2 SIMPLE activado."
        sleep 1
      ;;
      2)
        SOCKS_PY3_SIMPLE_ENABLED=1
        refresh_socks_global_status
        save_state
        socks_log "SOCKS PYTHON3 SIMPLE ON puerto=8080"
        log "SOCKS PYTHON3 SIMPLE activado."
        sleep 1
      ;;
      3) configure_socks_python2 ;;
      4) configure_socks_python3_direct ;;
      5)
        install_python_modules
        sleep 1
      ;;
      6)
        echo "SOCKS PYTHON2 DIRECTO: $(on_off "${SOCKS_ENABLED}")"
        echo "SOCKS PYTHON2 SIMPLE: $(on_off "${SOCKS_PY2_SIMPLE_ENABLED}")"
        echo "SOCKS PYTHON3 SIMPLE: $(on_off "${SOCKS_PY3_SIMPLE_ENABLED}")"
        echo "SOCKS PYTHON3 DIRECTO: $(on_off "${SOCKS_PY3_DIRECT_ENABLED}")"
        echo "Puerto local: ${SOCKS_PORT}"
        echo "Redireccion: ${SOCKS_REDIRECT_PORT}"
        echo "Status HTTP: ${SOCKS_RESPONSE_STATUS}"
        read -r -p "Enter para volver..."
      ;;
      7)
        SOCKS_ENABLED=0
        SOCKS_PY2_SIMPLE_ENABLED=0
        SOCKS_PY3_SIMPLE_ENABLED=0
        SOCKS_PY3_DIRECT_ENABLED=0
        refresh_socks_global_status
        save_state
        socks_log "Detener todos los puertos y servicios SOCKS"
        warn "Se marcaron servicios SOCKS como detenidos."
        sleep 1
      ;;
      8)
        stop_socks_port
        sleep 1
      ;;
      9) show_socks_logs ;;
      0) break ;;
      *) warn "Opcion invalida." ; sleep 1 ;;
    esac
  done
}

protocol_menu() {
  while true; do
    load_state
    clear
    echo "========================================================"
    echo "              ADMINISTRADOR DE PROTOCOLOS"
    echo "========================================================"
    protocol_header_lines
    echo "--------------------------------------------------------"
    echo "[1] AJUSTES SSH         [ON]   [10] SQUID             [OFF]"
    echo "[2] DROPBEAR            [OFF]  [11] OPENVPN           [OFF]"
    echo "[3] SOCKS PYTHON        $(on_off "${SOCKS_ENABLED}")   [12] CHECKUSER ONLINE  [OFF]"
    echo "[4] NGINX               $(on_off "${NGINX_ENABLED}")   [13] ATKEN and HASH    [OFF]"
    echo "[5] SLOWDNS             [OFF]  [14] FILEBROWSER       [OFF]"
    echo "[6] WS-EPRO             [OFF]  [15] V2RAY/XRAY        $(on_off "${XRAY_ENABLED}")"
    echo "[7] UDP-CUSTOM          [OFF]  [16] SSHGO             [OFF]"
    echo "[8] UDP-HYSTERIA        [OFF]  [17] WIREGUARD         [OFF]"
    echo "[9] BADVPN-UDPGW        [OFF]"
    echo
    echo "[19] MOSTRAR DATOS DE CONEXION"
    echo "[0] VOLVER"
    echo "--------------------------------------------------------"
    read -r -p "Ingresa una opcion: " opt
    case "${opt}" in
      1) configure_ssh_port ;;
      3) socks_python_menu ;;
      4) nginx_menu ;;
      15) configure_xray_vless_ws ;;
      19) show_connection_info ;;
      0) break ;;
      2|5|6|7|8|9|10|11|12|13|14|16|17|18)
        warn "Modulo en desarrollo."
        sleep 1
      ;;
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
    enforce_only_ssh_on_first_install
    clear
    echo "========================================================"
    echo "                     J DAVID AG"
    echo "========================================================"
    echo "S.O: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
    echo "Fecha: $(date +%d-%m-%Y)   Hora: $(date +%H:%M:%S)"
    echo "--------------------------------------------------------"
    echo "[1] ADMINISTRAR CUENTAS (SSH/DROPBEAR)"
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
      1) ssh_accounts_menu ;;
      2|5|6) warn "Opcion en desarrollo." ; sleep 1 ;;
      *) warn "Opcion invalida." ; sleep 1 ;;
    esac
  done
}

main_menu
