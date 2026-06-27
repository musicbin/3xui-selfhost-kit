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

public_ip() {
  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true
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
}

write_install_summary() {
  load_env
  local summary="${INSTALL_DIR}/runtime/install-summary.txt"
  local public_panel_url="http://${SERVER_ADDR:-your-server}:${PANEL_PORT:-2053}/${WEB_BASE_PATH:-panel}/"
  local tunnel_cmd="ssh -L ${PANEL_PORT:-2053}:127.0.0.1:${PANEL_PORT:-2053} root@${SERVER_ADDR:-your-server}"
  local local_panel_url="http://127.0.0.1:${PANEL_PORT:-2053}/${WEB_BASE_PATH:-panel}/"
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
  Recommended SSH tunnel:
    ${tunnel_cmd}

  Then open in your browser:
    ${local_panel_url}

  If you intentionally set PANEL_LISTEN_IP=0.0.0.0, the direct URL is:
    ${public_panel_url}

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
  ./scripts/manage.sh status
  ./scripts/manage.sh update
  ./scripts/manage.sh backup

8) Firewall reminder
  Public: open ${REALITY_PORT:-443}/tcp for VLESS REALITY.
  Private: keep ${PANEL_PORT:-2053}/tcp closed to public internet when PANEL_LISTEN_IP=127.0.0.1.
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
  ensure_docker
  download_project
  write_env
  compose_up
  load_env
  wait_panel_db
  configure_panel

  if [ "${ENABLE_PRESETS:-1}" = "1" ]; then
    log "Applying protocol presets."
    (cd "$INSTALL_DIR" && ./scripts/apply-presets.sh)
  fi

  write_install_summary
  print_install_summary
}

main "$@"
