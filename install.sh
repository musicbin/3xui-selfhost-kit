#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/musicbin/3xui-selfhost-kit/main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/3xui-selfhost-kit}"

log() { printf '[3xui-kit] %s\n' "$*"; }
die() { printf '[3xui-kit] ERROR: %s\n' "$*" >&2; exit 1; }

random_hex() {
  openssl rand -hex "${1:-12}"
}

random_password() {
  openssl rand -base64 36 | tr -d '\n' | tr '/+' 'Aa' | cut -c1-32
}

random_port() {
  local hex
  hex="$(openssl rand -hex 2)"
  printf '%d' $((20000 + 0x${hex} % 30000))
}

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "Please run as root, for example: curl -fsSL ${REPO_RAW_BASE}/install.sh | sudo bash"
  fi
}

install_pkg() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${pkgs[@]}"
  else
    die "No supported package manager found. Install curl, openssl, jq, tar, and Docker manually."
  fi
}

ensure_base_tools() {
  local missing=()
  for bin in curl openssl jq tar; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing base tools: ${missing[*]}"
    install_pkg "${missing[@]}"
  fi
  command -v sed >/dev/null 2>&1 || die "sed is missing."
  command -v awk >/dev/null 2>&1 || die "awk is missing."
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now docker || true
    fi
    return
  fi

  if [ "${INSTALL_DOCKER:-1}" != "1" ]; then
    die "Docker or Docker Compose plugin is missing. Set INSTALL_DOCKER=1 or install Docker first."
  fi

  log "Installing Docker with Docker's official convenience installer."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker || true
  fi

  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is still unavailable after Docker install."
}

download_file() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  curl -fsSL "${REPO_RAW_BASE}/${src}" -o "$dst"
}

download_project() {
  log "Installing kit files into ${INSTALL_DIR}"
  mkdir -p "$INSTALL_DIR"

  local files=(
    "compose.yaml"
    "scripts/manage.sh"
    "scripts/apply-presets.sh"
    "scripts/domain-cert.sh"
    "scripts/subscription.sh"
    "scripts/xui-builtin-subscription.sh"
    "scripts/mask-site.sh"
    "scripts/subconfig-api.py"
    "scripts/start-services.sh"
    "scripts/menu.sh"
    "caddy/Caddyfile"
    "site/index.html"
    "site/sub/config/3.5.yaml"
    "README.md"
    "SECURITY.md"
  )

  for f in "${files[@]}"; do
    download_file "$f" "${INSTALL_DIR}/${f}"
  done

  chmod +x "${INSTALL_DIR}/scripts/"*.sh
}

install_cli_shortcut() {
  mkdir -p /usr/local/bin
  ln -sf "${INSTALL_DIR}/scripts/menu.sh" /usr/local/bin/3xui-kit
  ln -sf "${INSTALL_DIR}/scripts/menu.sh" /usr/local/bin/x-ui
  chmod +x "${INSTALL_DIR}/scripts/menu.sh"
}

configure_firewall_ports() {
  if [ "${CONFIGURE_FIREWALL:-1}" != "1" ]; then
    return
  fi

  local ports=(
    "22/tcp"
    "80/tcp"
    "${REALITY_PORT:-443}/tcp"
  )

  if [ "${PANEL_LISTEN_IP:-127.0.0.1}" = "0.0.0.0" ]; then
    ports+=("${PANEL_PORT:-2053}/tcp")
  fi
  if [ "${ENABLE_SHADOWSOCKS:-1}" = "1" ]; then
    ports+=("${SHADOWSOCKS_PORT:-8388}/tcp" "${SHADOWSOCKS_PORT:-8388}/udp")
  fi
  if [ "${ENABLE_TROJAN:-0}" = "1" ]; then
    ports+=("${TROJAN_PORT:-9443}/tcp")
  fi
  if [ "${ENABLE_HYSTERIA:-0}" = "1" ]; then
    ports+=("${HYSTERIA_PORT:-8443}/udp")
  fi

  if command -v ufw >/dev/null 2>&1; then
    local p
    for p in "${ports[@]}"; do
      ufw allow "$p" >/dev/null 2>&1 || true
    done
    log "Firewall rules ensured with ufw: ${ports[*]}"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    local p proto port
    for p in "${ports[@]}"; do
      port="${p%/*}"
      proto="${p#*/}"
      firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
    log "Firewall rules ensured with firewalld: ${ports[*]}"
  else
    log "No ufw/firewalld detected; make sure ports are allowed by your VPS firewall: ${ports[*]}"
  fi
}

generate_mask_site() {
  if [ "${ENABLE_MASK_SITE:-1}" != "1" ]; then
    return
  fi

  (cd "$INSTALL_DIR" && ./scripts/mask-site.sh)
}

start_mask_site() {
  if [ "${ENABLE_MASK_SITE:-1}" != "1" ]; then
    return
  fi
  cd "$INSTALL_DIR"
  if docker compose --profile site up -d caddy-site; then
    log "Masquerade static site is running on port 80."
  else
    log "Masquerade site did not start. Port 80 may already be in use."
  fi
}

configure_domains() {
  load_env
  if [ "${ENABLE_ACME:-0}" != "1" ] || [ -z "${DOMAIN_NAMES:-}" ]; then
    return
  fi
  log "Configuring domain certificates: ${DOMAIN_NAMES}"
  if ! (cd "$INSTALL_DIR" && AUTO_ENABLE_TROJAN="${AUTO_ENABLE_TROJAN:-1}" ./scripts/domain-cert.sh --auto); then
    log "Domain certificate automation did not fully complete. You can retry later with: x-ui -> domain/cert menu"
  fi
  load_env
}

configure_subscription() {
  load_env
  if [ "${ENABLE_SUBCONVERTER:-1}" != "1" ]; then
    return
  fi
  log "Configuring subscription converter web UI."
  if ! (cd "$INSTALL_DIR" && ./scripts/subscription.sh); then
    log "Subscription converter setup did not fully complete. Retry later with: x-ui -> subscription menu"
  fi
}

configure_xui_builtin_subscription() {
  load_env
  if [ "${XUI_BUILTIN_SUB_ENABLE:-1}" != "1" ]; then
    return
  fi
  if [ "${HTTPS_SITE_ENABLE:-0}" != "1" ]; then
    log "Skipping 3x-ui built-in public subscription URI until HTTPS site is enabled."
    return
  fi
  log "Configuring 3x-ui built-in subscription behind HTTPS reverse proxy."
  if ! (cd "$INSTALL_DIR" && ./scripts/xui-builtin-subscription.sh); then
    log "3x-ui built-in subscription setup did not fully complete. Retry later with: cd ${INSTALL_DIR} && ./scripts/manage.sh xui-subscription"
  fi
  load_env
}

install_systemd_autostart() {
  if [ "${ENABLE_SYSTEMD_AUTOSTART:-1}" != "1" ]; then
    return
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    log "systemd not found; Docker restart policy remains enabled."
    return
  fi
  if ! systemctl list-unit-files >/dev/null 2>&1; then
    log "systemd is not running; Docker restart policy remains enabled."
    return
  fi

  local docker_bin
  docker_bin="$(command -v docker)"
  cat > /etc/systemd/system/3xui-kit.service <<EOF
[Unit]
Description=3x-ui selfhost kit
Wants=network-online.target docker.service
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/env bash ${INSTALL_DIR}/scripts/start-services.sh
ExecStop=${docker_bin} compose stop 3xui subconverter subconfig-api caddy-site caddy-https
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now 3xui-kit.service
  log "Enabled boot autostart: 3xui-kit.service"
}

public_ip() {
  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true
}

tty_available() {
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

tty_print() {
  printf '%s\n' "$*" > /dev/tty
}

tty_prompt() {
  local prompt="$1"
  local default="${2:-}"
  local answer
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" > /dev/tty
  else
    printf '%s: ' "$prompt" > /dev/tty
  fi
  IFS= read -r answer < /dev/tty || answer=""
  printf '%s' "${answer:-$default}"
}

tty_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local suffix answer
  if [ "$default" = "y" ]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi
  answer="$(tty_prompt "${prompt} (${suffix})" "")"
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

run_config_wizard() {
  if [ "${CONFIG_WIZARD:-1}" != "1" ] || [ -f "${INSTALL_DIR}/.env" ] || ! tty_available; then
    return
  fi

  local detected_addr bind_choice target server_names chain_addr chain_port domains acme_email default_panel_port
  detected_addr="$(public_ip)"
  default_panel_port="${PANEL_PORT:-$(random_port)}"

  tty_print ""
  tty_print "============================================================"
  tty_print "  3x-ui self-host setup"
  tty_print "============================================================"
  tty_print "Press Enter to accept the safe default shown in brackets."
  tty_print ""

  SERVER_ADDR="${SERVER_ADDR:-$(tty_prompt "Server public IP or domain for client links" "${detected_addr}")}"

  domains="$(tty_prompt "Domains for HTTPS certificate, comma-separated, optional" "${DOMAIN_NAMES:-}")"
  if [ -n "$domains" ]; then
    DOMAIN_NAMES="${DOMAIN_NAMES:-$domains}"
    TLS_SERVER_NAME="${TLS_SERVER_NAME:-${domains%%,*}}"
    if tty_yes_no "Use the first domain for panel/client display instead of IP?" "y"; then
      SERVER_ADDR="${domains%%,*}"
    fi
    ENABLE_ACME=1
    acme_email="$(tty_prompt "ACME email for certificate renewal notices" "${ACME_EMAIL:-admin@${domains%%,*}}")"
    ACME_EMAIL="${ACME_EMAIL:-$acme_email}"
    if tty_yes_no "Enable Trojan TLS automatically after certificate is issued?" "y"; then
      ENABLE_TROJAN=1
      AUTO_ENABLE_TROJAN=1
    fi
    if tty_yes_no "Enable HTTPS masquerade site on 443? This moves VLESS REALITY to 8443" "y"; then
      HTTPS_SITE_ENABLE=1
      HTTPS_HTTP_MODE=redirect
    else
      HTTPS_SITE_ENABLE=0
      HTTPS_HTTP_MODE=reject
    fi
  fi

  tty_print ""
  tty_print "Panel exposure:"
  tty_print "  1) Safe: bind panel to 127.0.0.1 and open through SSH tunnel"
  tty_print "  2) Public: bind panel to 0.0.0.0"
  bind_choice="$(tty_prompt "Choose panel exposure" "1")"
  if [ "$bind_choice" = "2" ]; then
    PANEL_LISTEN_IP="${PANEL_LISTEN_IP:-0.0.0.0}"
  else
    PANEL_LISTEN_IP="${PANEL_LISTEN_IP:-127.0.0.1}"
  fi

  PANEL_PORT="${PANEL_PORT:-$(tty_prompt "Panel port" "$default_panel_port")}"
  WEB_BASE_PATH="${WEB_BASE_PATH:-$(tty_prompt "Panel random path, without leading slash" "p$(random_hex 9)")}"
  REALITY_PORT="${REALITY_PORT:-$(tty_prompt "VLESS REALITY public port" "443")}"
  target="$(tty_prompt "REALITY target" "${REALITY_TARGET:-www.cloudflare.com:443}")"
  REALITY_TARGET="${REALITY_TARGET:-$target}"
  server_names="$(tty_prompt "REALITY server names, comma-separated" "${REALITY_SERVER_NAMES:-www.cloudflare.com,cloudflare.com}")"
  REALITY_SERVER_NAMES="${REALITY_SERVER_NAMES:-$server_names}"

  if tty_yes_no "Enable Hysteria2 now? It needs a real TLS certificate for best security" "n"; then
    ENABLE_HYSTERIA=1
    HYSTERIA_PORT="${HYSTERIA_PORT:-$(tty_prompt "Hysteria2 UDP port" "8443")}"
    TLS_CERT_FILE="${TLS_CERT_FILE:-$(tty_prompt "TLS cert path inside container/host, e.g. /root/cert/fullchain.pem" "${TLS_CERT_FILE:-}")}"
    TLS_KEY_FILE="${TLS_KEY_FILE:-$(tty_prompt "TLS key path inside container/host, e.g. /root/cert/privkey.pem" "${TLS_KEY_FILE:-}")}"
  fi

  if tty_yes_no "Enable Trojan WS TLS now? It needs a real TLS certificate for best security" "n"; then
    ENABLE_TROJAN=1
    TROJAN_PORT="${TROJAN_PORT:-$(tty_prompt "Trojan TCP port" "9443")}"
    TLS_CERT_FILE="${TLS_CERT_FILE:-$(tty_prompt "TLS cert path inside container/host" "${TLS_CERT_FILE:-}")}"
    TLS_KEY_FILE="${TLS_KEY_FILE:-$(tty_prompt "TLS key path inside container/host" "${TLS_KEY_FILE:-}")}"
  fi

  if tty_yes_no "Enable Shadowsocks 2022 now?" "y"; then
    ENABLE_SHADOWSOCKS=1
    SHADOWSOCKS_PORT="${SHADOWSOCKS_PORT:-$(tty_prompt "Shadowsocks TCP/UDP port" "8388")}"
  else
    ENABLE_SHADOWSOCKS=0
  fi

  if tty_yes_no "Configure chain proxy outbound now?" "n"; then
    CHAIN_ENABLED=1
    CHAIN_MODE="${CHAIN_MODE:-$(tty_prompt "Chain mode: manual or all" "manual")}"
    CHAIN_TYPE="${CHAIN_TYPE:-$(tty_prompt "Chain type: socks, http, or trojan" "socks")}"
    chain_addr="$(tty_prompt "Chain proxy address" "${CHAIN_ADDRESS:-}")"
    chain_port="$(tty_prompt "Chain proxy port" "${CHAIN_PORT:-}")"
    CHAIN_ADDRESS="${CHAIN_ADDRESS:-$chain_addr}"
    CHAIN_PORT="${CHAIN_PORT:-$chain_port}"
    CHAIN_USER="${CHAIN_USER:-$(tty_prompt "Chain username, optional" "${CHAIN_USER:-}")}"
    CHAIN_PASS="${CHAIN_PASS:-$(tty_prompt "Chain password, optional" "${CHAIN_PASS:-}")}"
  fi

  tty_print ""
  tty_print "Configuration captured. Installing now..."
  tty_print "============================================================"
  tty_print ""
}

write_env() {
  cd "$INSTALL_DIR"
  if [ -f .env ]; then
    log "Keeping existing .env"
    return
  fi

  local base_path default_addr first_configured_domain server_addr_default enable_acme_default https_site_default https_http_default
  base_path="${WEB_BASE_PATH:-p$(random_hex 9)}"
  base_path="${base_path#/}"
  default_addr="$(public_ip)"
  first_configured_domain="$(printf '%s' "${DOMAIN_NAMES:-}" | awk -F'[,，;； ]+' '{print $1}')"
  server_addr_default="$default_addr"
  enable_acme_default="${ENABLE_ACME:-0}"
  https_site_default="${HTTPS_SITE_ENABLE:-0}"
  https_http_default="${HTTPS_HTTP_MODE:-reject}"
  if [ -n "$first_configured_domain" ]; then
    server_addr_default="$first_configured_domain"
    if [ "${ENABLE_ACME+x}" != "x" ]; then
      enable_acme_default=1
    fi
    if [ "${HTTPS_SITE_ENABLE+x}" != "x" ]; then
      https_site_default=1
    fi
    if [ "${HTTPS_HTTP_MODE+x}" != "x" ]; then
      https_http_default=redirect
    fi
  fi

  cat > .env <<EOF
COMPOSE_PROJECT_NAME=3xui_selfhost
XUI_IMAGE=${XUI_IMAGE:-ghcr.io/mhsanaei/3x-ui:latest}
XUI_CONTAINER=${XUI_CONTAINER:-3xui}

PANEL_PORT=${PANEL_PORT:-$(random_port)}
PANEL_LISTEN_IP=${PANEL_LISTEN_IP:-127.0.0.1}
PANEL_USERNAME=${PANEL_USERNAME:-admin_$(random_hex 4)}
PANEL_PASSWORD=${PANEL_PASSWORD:-$(random_password)}
WEB_BASE_PATH=${base_path}

SERVER_ADDR=${SERVER_ADDR:-${server_addr_default}}
REALITY_PORT=${REALITY_PORT:-443}
REALITY_TARGET=${REALITY_TARGET:-www.cloudflare.com:443}
REALITY_SERVER_NAMES=${REALITY_SERVER_NAMES:-www.cloudflare.com,cloudflare.com}
REALITY_SPIDER_X=${REALITY_SPIDER_X:-/}

ENABLE_PRESETS=${ENABLE_PRESETS:-1}
ENABLE_HYSTERIA=${ENABLE_HYSTERIA:-0}
ENABLE_TROJAN=${ENABLE_TROJAN:-0}
ENABLE_SHADOWSOCKS=${ENABLE_SHADOWSOCKS:-1}
ALLOW_SELF_SIGNED_TLS=${ALLOW_SELF_SIGNED_TLS:-0}
TLS_CERT_FILE=${TLS_CERT_FILE:-}
TLS_KEY_FILE=${TLS_KEY_FILE:-}
TLS_SERVER_NAME=${TLS_SERVER_NAME:-}
HYSTERIA_PORT=${HYSTERIA_PORT:-8443}
TROJAN_PORT=${TROJAN_PORT:-9443}
SHADOWSOCKS_PORT=${SHADOWSOCKS_PORT:-8388}

CHAIN_ENABLED=${CHAIN_ENABLED:-0}
CHAIN_MODE=${CHAIN_MODE:-manual}
CHAIN_TYPE=${CHAIN_TYPE:-socks}
CHAIN_ADDRESS=${CHAIN_ADDRESS:-}
CHAIN_PORT=${CHAIN_PORT:-}
CHAIN_USER=${CHAIN_USER:-}
CHAIN_PASS=${CHAIN_PASS:-}
CHAIN_SERVER_NAME=${CHAIN_SERVER_NAME:-}
CHAIN_ALLOW_INSECURE=${CHAIN_ALLOW_INSECURE:-0}

SITE_HTTP_PORT=${SITE_HTTP_PORT:-80}
ENABLE_MASK_SITE=${ENABLE_MASK_SITE:-1}
DOMAIN_NAMES=${DOMAIN_NAMES:-}
ENABLE_ACME=${enable_acme_default}
ACME_EMAIL=${ACME_EMAIL:-}
AUTO_ENABLE_TROJAN=${AUTO_ENABLE_TROJAN:-1}
HTTPS_SITE_ENABLE=${https_site_default}
HTTPS_HTTP_MODE=${https_http_default}
SITE_HTTPS_PORT=${SITE_HTTPS_PORT:-443}
ENABLE_SUBCONVERTER=${ENABLE_SUBCONVERTER:-1}
SUBCONVERTER_IMAGE=${SUBCONVERTER_IMAGE:-tindy2013/subconverter:latest}
SUBCONVERTER_PORT=${SUBCONVERTER_PORT:-25500}
SUBSCRIPTION_TOKEN=${SUBSCRIPTION_TOKEN:-}
ENABLE_SUB_CONFIG_EDITOR=${ENABLE_SUB_CONFIG_EDITOR:-1}
SUB_CONFIG_API_IMAGE=${SUB_CONFIG_API_IMAGE:-python:3-alpine}
SUB_CONFIG_PORT=${SUB_CONFIG_PORT:-27880}
SUB_CONFIG_ADMIN_TOKEN=${SUB_CONFIG_ADMIN_TOKEN:-}
XUI_BUILTIN_SUB_ENABLE=${XUI_BUILTIN_SUB_ENABLE:-1}
XUI_BUILTIN_SUB_LISTEN=${XUI_BUILTIN_SUB_LISTEN:-127.0.0.1}
XUI_BUILTIN_SUB_PORT=${XUI_BUILTIN_SUB_PORT:-2096}
XUI_BUILTIN_SUB_PATH=${XUI_BUILTIN_SUB_PATH:-/xui-sub-$(random_hex 6)/}
XUI_BUILTIN_JSON_ENABLE=${XUI_BUILTIN_JSON_ENABLE:-0}
XUI_BUILTIN_JSON_PATH=${XUI_BUILTIN_JSON_PATH:-/xui-json-$(random_hex 6)/}
XUI_BUILTIN_CLASH_ENABLE=${XUI_BUILTIN_CLASH_ENABLE:-0}
XUI_BUILTIN_CLASH_PATH=${XUI_BUILTIN_CLASH_PATH:-/xui-clash-$(random_hex 6)/}
EOF
  chmod 600 .env
}

compose_up() {
  cd "$INSTALL_DIR"
  log "Pulling latest official 3x-ui image and starting service."
  docker compose pull 3xui
  docker compose up -d 3xui
}

load_env() {
  set -a
  # shellcheck disable=SC1091
  . "${INSTALL_DIR}/.env"
  set +a
}

wait_panel_db() {
  local i
  for i in $(seq 1 60); do
    if docker exec "${XUI_CONTAINER:-3xui}" /app/x-ui setting -show true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "3x-ui did not become ready in time. Check: cd ${INSTALL_DIR} && docker compose logs 3xui"
}

wait_panel_http() {
  load_env
  local url="http://127.0.0.1:${PANEL_PORT:-2053}/${WEB_BASE_PATH#/}/"
  local i
  log "Waiting for panel web endpoint: ${url}"
  for i in $(seq 1 90); do
    if curl -sS --max-time 2 -o /dev/null "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  log "Panel web endpoint did not answer yet; continuing so credentials can be shown."
  return 1
}

configure_panel() {
  load_env
  local path_no_slash="${WEB_BASE_PATH#/}"
  log "Hardening panel login, base path, and listen IP."
  docker exec "$XUI_CONTAINER" /app/x-ui setting \
    -port "$PANEL_PORT" \
    -listenIP "$PANEL_LISTEN_IP" \
    -username "$PANEL_USERNAME" \
    -password "$PANEL_PASSWORD" \
    -webBasePath "$path_no_slash" >/dev/null
  docker restart "$XUI_CONTAINER" >/dev/null
  wait_panel_db
  wait_panel_http || true
}

write_install_summary() {
  load_env
  local summary="${INSTALL_DIR}/runtime/install-summary.txt"
  local public_panel_url="http://${SERVER_ADDR:-your-server}:${PANEL_PORT:-2053}/${WEB_BASE_PATH:-panel}/"
  local tunnel_cmd="ssh -L ${PANEL_PORT:-2053}:127.0.0.1:${PANEL_PORT:-2053} root@${SERVER_ADDR:-your-server}"
  local tunnel_panel_url="http://127.0.0.1:${PANEL_PORT:-2053}/${WEB_BASE_PATH:-panel}/"
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    public_panel_url="https://${SERVER_ADDR:-your-server}/${WEB_BASE_PATH:-panel}/"
  fi
  mkdir -p "${INSTALL_DIR}/runtime"
  chmod 700 "${INSTALL_DIR}/runtime"
  cat > "$summary" <<EOF
3x-ui self-host kit installed.

1) Install dir
  ${INSTALL_DIR}

2) Visual panel
  Panel bind: ${PANEL_LISTEN_IP:-127.0.0.1}:${PANEL_PORT:-2053}
  Panel path: /${WEB_BASE_PATH:-panel}/
  Username:   ${PANEL_USERNAME:-unknown}
  Password:   ${PANEL_PASSWORD:-unknown}

3) How to open the panel
  Panel public display URL:
    ${public_panel_url}

  Recommended SSH tunnel when Panel bind is 127.0.0.1:
    ${tunnel_cmd}

  Tunnel browser URL:
    ${tunnel_panel_url}

4) Client config links
  Script-generated main links:
    ${INSTALL_DIR}/runtime/client-links.txt

  3x-ui panel-rendered links:
    ${INSTALL_DIR}/runtime/panel-all-links.txt

  Print them:
    cd ${INSTALL_DIR}
    ./scripts/manage.sh links

5) Default protocol
  VLESS + TCP/Raw + XTLS Vision + REALITY
  Port: ${REALITY_PORT:-443}
  Reality target: ${REALITY_TARGET:-www.cloudflare.com:443}
  Reality server names: ${REALITY_SERVER_NAMES:-www.cloudflare.com,cloudflare.com}

6) Configure from command line
  Edit environment:
    nano ${INSTALL_DIR}/.env

  Re-apply protocol presets:
    cd ${INSTALL_DIR}
    ./scripts/manage.sh apply-presets

  Enable Hysteria2 with a real cert:
    TLS_CERT_FILE=/root/cert/fullchain.pem TLS_KEY_FILE=/root/cert/privkey.pem ENABLE_HYSTERIA=1 ./scripts/apply-presets.sh

  Enable Trojan WS TLS with a real cert:
    TLS_CERT_FILE=/root/cert/fullchain.pem TLS_KEY_FILE=/root/cert/privkey.pem ENABLE_TROJAN=1 ./scripts/apply-presets.sh

  Enable Shadowsocks 2022:
    ENABLE_SHADOWSOCKS=1 ./scripts/apply-presets.sh

  Add a chain proxy outbound and route all traffic through it:
    CHAIN_ENABLED=1 CHAIN_MODE=all CHAIN_TYPE=socks CHAIN_ADDRESS=1.2.3.4 CHAIN_PORT=1080 ./scripts/apply-presets.sh

  Add an upstream Trojan outbound:
    CHAIN_ENABLED=1 CHAIN_MODE=all CHAIN_TYPE=trojan CHAIN_ADDRESS=upstream.example.com CHAIN_PORT=443 CHAIN_PASS=trojan-password CHAIN_SERVER_NAME=upstream.example.com ./scripts/apply-presets.sh

7) Manage
  cd ${INSTALL_DIR}
  x-ui
  3xui-kit
  ./scripts/manage.sh menu
  ./scripts/manage.sh status
  ./scripts/manage.sh update
  ./scripts/manage.sh backup

8) Firewall reminder
  Public: open ${REALITY_PORT:-443}/tcp for VLESS REALITY.
  Private: keep ${PANEL_PORT:-2053}/tcp closed to public internet when PANEL_LISTEN_IP=127.0.0.1.

9) Autostart
  Docker container restart policy: unless-stopped
  systemd service: 3xui-kit.service
  Check status:
    systemctl status 3xui-kit.service --no-pager

10) Domains and HTTPS
  Domains: ${DOMAIN_NAMES:-not configured}
  ACME auto renew: ${ENABLE_ACME:-0}
  HTTPS masquerade site: ${HTTPS_SITE_ENABLE:-0}
  HTTP mode after certificate: ${HTTPS_HTTP_MODE:-reject}
  TLS cert in container: ${TLS_CERT_FILE:-not configured}

11) Subscription converter
  Web UI:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/sub/' "${SERVER_ADDR:-your-server}" || printf 'http://%s:%s/sub/' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}")
  Local node subscription:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/subscriptions/%s.txt' "${SERVER_ADDR:-your-server}" "${SUBSCRIPTION_TOKEN:-token}" || printf 'http://%s:%s/subscriptions/%s.txt' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}" "${SUBSCRIPTION_TOKEN:-token}")
  Base64 subscription for subconverter:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/subscriptions/%s.b64' "${SERVER_ADDR:-your-server}" "${SUBSCRIPTION_TOKEN:-token}" || printf 'http://%s:%s/subscriptions/%s.b64' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}" "${SUBSCRIPTION_TOKEN:-token}")
  Clash 3.5.yaml rendered subscription:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/subconfig-api/render/clash?token=%s' "${SERVER_ADDR:-your-server}" "${SUBSCRIPTION_TOKEN:-token}" || printf 'http://%s:%s/subconfig-api/render/clash?token=%s' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}" "${SUBSCRIPTION_TOKEN:-token}")
  Default local conversion config:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/sub/config/3.5.yaml' "${SERVER_ADDR:-your-server}" || printf 'http://%s:%s/sub/config/3.5.yaml' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}")
  Rules editor:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/sub/' "${SERVER_ADDR:-your-server}" || printf 'http://%s:%s/sub/' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}")
  Rules editor token:
    ${SUB_CONFIG_ADMIN_TOKEN:-not generated yet}
  Backend image:
    ${SUBCONVERTER_IMAGE:-tindy2013/subconverter:latest}
  Note:
    If HTTPS_SITE_ENABLE=0 and HTTPS_HTTP_MODE=reject, public /sub/ is intentionally blocked after certificate setup. Enable the HTTPS site from x-ui to use /sub/ over TLS.

12) 3X-UI built-in subscription
  Listen:
    ${XUI_BUILTIN_SUB_LISTEN:-127.0.0.1}:${XUI_BUILTIN_SUB_PORT:-2096}
  Reverse proxy URI:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s%s' "${SERVER_ADDR:-your-server}" "${XUI_BUILTIN_SUB_PATH:-/xui-sub/}" || printf 'local-only until HTTPS is enabled')
  JSON URI:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s%s' "${SERVER_ADDR:-your-server}" "${XUI_BUILTIN_JSON_PATH:-/xui-json/}" || printf 'local-only until HTTPS is enabled')
  Clash URI:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s%s' "${SERVER_ADDR:-your-server}" "${XUI_BUILTIN_CLASH_PATH:-/xui-clash/}" || printf 'local-only until HTTPS is enabled')
EOF
  chmod 600 "$summary"
}

print_install_summary() {
  load_env
  local summary="${INSTALL_DIR}/runtime/install-summary.txt"
  echo
  echo "============================================================"
  echo "  3x-ui deployment complete"
  echo "============================================================"
  cat "$summary"
  echo
  echo "Generated links:"
  if [ -s "${INSTALL_DIR}/runtime/client-links.txt" ]; then
    sed -n '1,120p' "${INSTALL_DIR}/runtime/client-links.txt"
  else
    echo "  No client links generated yet."
  fi
  echo "============================================================"
}

main() {
  need_root
  ensure_base_tools
  run_config_wizard
  ensure_docker
  download_project
  install_cli_shortcut
  write_env
  load_env
  generate_mask_site
  configure_firewall_ports
  compose_up
  install_systemd_autostart
  wait_panel_db
  configure_panel
  start_mask_site
  configure_domains

  if [ "${ENABLE_PRESETS:-1}" = "1" ]; then
    log "Applying protocol presets."
    if ! (cd "$INSTALL_DIR" && ./scripts/apply-presets.sh); then
      log "Protocol presets were not fully applied. The panel credentials will still be printed below."
      log "After the panel is reachable, run: cd ${INSTALL_DIR} && ./scripts/manage.sh apply-presets"
    fi
  fi

  configure_subscription
  configure_xui_builtin_subscription

  write_install_summary
  print_install_summary
  if [ "${MENU_AFTER_INSTALL:-1}" = "1" ] && tty_available; then
    log "Opening terminal menu. You can run it later with: 3xui-kit"
    "${INSTALL_DIR}/scripts/menu.sh"
  fi
}

main "$@"
