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
    "scripts/menu.sh"
    "caddy/Caddyfile"
    "site/index.html"
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
  chmod +x "${INSTALL_DIR}/scripts/menu.sh"
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
ExecStart=${docker_bin} compose up -d 3xui
ExecStop=${docker_bin} compose stop 3xui
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

  local detected_addr bind_choice target server_names chain_addr chain_port
  detected_addr="$(public_ip)"

  tty_print ""
  tty_print "============================================================"
  tty_print "  3x-ui self-host setup"
  tty_print "============================================================"
  tty_print "Press Enter to accept the safe default shown in brackets."
  tty_print ""

  SERVER_ADDR="${SERVER_ADDR:-$(tty_prompt "Server public IP or domain for client links" "${detected_addr}")}"

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

  PANEL_PORT="${PANEL_PORT:-$(tty_prompt "Panel port" "2053")}"
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

  if tty_yes_no "Enable Shadowsocks 2022 now?" "n"; then
    ENABLE_SHADOWSOCKS=1
    SHADOWSOCKS_PORT="${SHADOWSOCKS_PORT:-$(tty_prompt "Shadowsocks TCP/UDP port" "8388")}"
  fi

  if tty_yes_no "Configure chain proxy outbound now?" "n"; then
    CHAIN_ENABLED=1
    CHAIN_MODE="${CHAIN_MODE:-$(tty_prompt "Chain mode: manual or all" "manual")}"
    CHAIN_TYPE="${CHAIN_TYPE:-$(tty_prompt "Chain type: socks or http" "socks")}"
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

  local base_path default_addr
  base_path="${WEB_BASE_PATH:-p$(random_hex 9)}"
  base_path="${base_path#/}"
  default_addr="$(public_ip)"

  cat > .env <<EOF
COMPOSE_PROJECT_NAME=3xui_selfhost
XUI_IMAGE=${XUI_IMAGE:-ghcr.io/mhsanaei/3x-ui:latest}
XUI_CONTAINER=${XUI_CONTAINER:-3xui}

PANEL_PORT=${PANEL_PORT:-2053}
PANEL_LISTEN_IP=${PANEL_LISTEN_IP:-127.0.0.1}
PANEL_USERNAME=${PANEL_USERNAME:-admin_$(random_hex 4)}
PANEL_PASSWORD=${PANEL_PASSWORD:-$(random_password)}
WEB_BASE_PATH=${base_path}

SERVER_ADDR=${SERVER_ADDR:-${default_addr}}
REALITY_PORT=${REALITY_PORT:-443}
REALITY_TARGET=${REALITY_TARGET:-www.cloudflare.com:443}
REALITY_SERVER_NAMES=${REALITY_SERVER_NAMES:-www.cloudflare.com,cloudflare.com}
REALITY_SPIDER_X=${REALITY_SPIDER_X:-/}

ENABLE_PRESETS=${ENABLE_PRESETS:-1}
ENABLE_HYSTERIA=${ENABLE_HYSTERIA:-0}
ENABLE_TROJAN=${ENABLE_TROJAN:-0}
ENABLE_SHADOWSOCKS=${ENABLE_SHADOWSOCKS:-0}
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

SITE_HTTP_PORT=${SITE_HTTP_PORT:-80}
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

7) Manage
  cd ${INSTALL_DIR}
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
  compose_up
  install_systemd_autostart
  load_env
  wait_panel_db
  configure_panel

  if [ "${ENABLE_PRESETS:-1}" = "1" ]; then
    log "Applying protocol presets."
    if ! (cd "$INSTALL_DIR" && ./scripts/apply-presets.sh); then
      log "Protocol presets were not fully applied. The panel credentials will still be printed below."
      log "After the panel is reachable, run: cd ${INSTALL_DIR} && ./scripts/manage.sh apply-presets"
    fi
  fi

  write_install_summary
  print_install_summary
  if [ "${MENU_AFTER_INSTALL:-1}" = "1" ] && tty_available; then
    log "Opening terminal menu. You can run it later with: 3xui-kit"
    "${INSTALL_DIR}/scripts/menu.sh"
  fi
}

main "$@"
