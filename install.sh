#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/musicbin/3xui-selfhost-kit/main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/3xui-selfhost-kit}"

INSTALL_ENV_OVERRIDE_KEYS=(
  DOMAIN_NAMES SERVER_ALIASES SERVER_ADDR DOMAIN_NODE_MODE
  ENABLE_ACME ACME_EMAIL STRICT_DOMAIN_CERT USE_DOMAIN_FOR_LINKS HTTPS_SITE_ENABLE HTTPS_HTTP_MODE SITE_HTTPS_PORT AUTO_ENABLE_TROJAN
  ENABLE_TROJAN ENABLE_SHADOWSOCKS ENABLE_HYSTERIA
  REALITY_PORT REALITY_TARGET REALITY_SERVER_NAMES REALITY_SPIDER_X
  TLS_SERVER_NAME TLS_CERT_FILE TLS_KEY_FILE
  TROJAN_PORT SHADOWSOCKS_PORT HYSTERIA_PORT
  ENABLE_DOKODEMO DOKODEMO_LISTEN DOKODEMO_PORT DOKODEMO_TARGET_ADDRESS DOKODEMO_TARGET_PORT
  DOKODEMO_NETWORK DOKODEMO_FOLLOW_REDIRECT DOKODEMO_TPROXY DOKODEMO_FORWARDS
  ENABLE_SUBCONVERTER SUBSCRIPTION_EXPAND_ALIASES
  XUI_BUILTIN_SUB_ENABLE XUI_BUILTIN_ALL_NODES XUI_BUILTIN_JSON_ENABLE XUI_BUILTIN_CLASH_ENABLE
)

for key in "${INSTALL_ENV_OVERRIDE_KEYS[@]}"; do
  if [ "${!key+x}" = "x" ]; then
    printf -v "__install_override_${key}" '%s' "${!key}"
  fi
done

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

set_env_var() {
  local key="$1"
  local value="$2"
  if [ "$key" = "DOKODEMO_FORWARDS" ]; then
    value="'$(printf '%s' "$value" | sed "s/'/'\\\\''/g")'"
  fi
  local env_file="${3:-.env}"
  local tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ "^" k "=" { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$env_file" > "$tmp"
  mv "$tmp" "$env_file"
  chmod 600 "$env_file"
}

env_has_key() {
  local key="$1"
  local env_file="${2:-.env}"
  grep -q "^${key}=" "$env_file" 2>/dev/null
}

ensure_env_var() {
  local key="$1"
  local value="$2"
  local env_file="${3:-.env}"
  env_has_key "$key" "$env_file" || set_env_var "$key" "$value" "$env_file"
}

has_install_override() {
  local key="$1"
  local override_name="__install_override_${key}"
  [ "${!override_name+x}" = "x" ]
}

install_override_value() {
  local key="$1"
  local override_name="__install_override_${key}"
  printf '%s' "${!override_name}"
}

first_domain() {
  printf '%s' "$1" | awk -F'[,，;；[:space:]]+' '{print $1}'
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
    "scripts/protocol-guard.sh"
    "scripts/network-check.sh"
    "scripts/reconcile.sh"
    "scripts/safe-update.sh"
    "scripts/subconfig-api.py"
    "scripts/start-services.sh"
    "scripts/menu.sh"
    "caddy/Caddyfile"
    "site/index.html"
    "site/forward/index.html"
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
  if [ -n "${DOKODEMO_FORWARDS:-}" ]; then
    local entry port _target _target_port network listen
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      IFS=',' read -r port _target _target_port network listen _rest <<< "$entry"
      listen="${listen:-0.0.0.0}"
      network="${network:-tcp}"
      if [ "$listen" = "127.0.0.1" ] || [ "$listen" = "localhost" ]; then
        continue
      fi
      [ -n "$port" ] || continue
      case "$network" in
        tcp) ports+=("${port}/tcp") ;;
        udp) ports+=("${port}/udp") ;;
        *) ports+=("${port}/tcp" "${port}/udp") ;;
      esac
    done < <(printf '%s' "$DOKODEMO_FORWARDS" | tr ';' '\n')
  fi
  if [ "${ENABLE_DOKODEMO:-0}" = "1" ] && [ "${DOKODEMO_LISTEN:-127.0.0.1}" != "127.0.0.1" ] && [ "${DOKODEMO_LISTEN:-127.0.0.1}" != "localhost" ]; then
    case "${DOKODEMO_NETWORK:-tcp}" in
      tcp) ports+=("${DOKODEMO_PORT:-18080}/tcp") ;;
      udp) ports+=("${DOKODEMO_PORT:-18080}/udp") ;;
      *) ports+=("${DOKODEMO_PORT:-18080}/tcp" "${DOKODEMO_PORT:-18080}/udp") ;;
    esac
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
    if [ "${STRICT_DOMAIN_CERT:-0}" = "1" ]; then
      die "Domain HTTPS setup failed in strict mode. Fix DNS/certificate coverage for every DOMAIN_NAMES entry, then rerun the one-click command."
    fi
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

configure_protocol_guard() {
  load_env
  if [ "${ENABLE_PROTOCOL_GUARD:-1}" != "1" ]; then
    return
  fi
  log "Disabling unsafe inbound protocols if any exist."
  if ! (cd "$INSTALL_DIR" && ./scripts/protocol-guard.sh); then
    log "Protocol guard did not fully complete. Retry later with: cd ${INSTALL_DIR} && ./scripts/manage.sh protocol-guard"
  fi
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

apply_existing_env_overrides() {
  cd "$INSTALL_DIR"
  [ -f .env ] || return 0

  local key value domains primary all_nodes_sub_id default_sub_id server_addr_default
  for key in "${INSTALL_ENV_OVERRIDE_KEYS[@]}"; do
    if has_install_override "$key"; then
      value="$(install_override_value "$key")"
      set_env_var "$key" "$value"
      log "Applied install override to existing .env: ${key}"
    fi
  done

  if has_install_override DOMAIN_NAMES; then
    domains="$(install_override_value DOMAIN_NAMES)"
    primary="$(first_domain "$domains")"
    if [ -n "$domains" ]; then
      has_install_override SERVER_ALIASES || set_env_var SERVER_ALIASES "$domains"
      if [ -n "$primary" ]; then
        has_install_override SERVER_ADDR || set_env_var SERVER_ADDR "$primary"
        has_install_override TLS_SERVER_NAME || set_env_var TLS_SERVER_NAME "$primary"
      fi
      has_install_override ENABLE_ACME || set_env_var ENABLE_ACME "1"
      has_install_override STRICT_DOMAIN_CERT || set_env_var STRICT_DOMAIN_CERT "1"
      has_install_override USE_DOMAIN_FOR_LINKS || set_env_var USE_DOMAIN_FOR_LINKS "1"
      has_install_override HTTPS_SITE_ENABLE || set_env_var HTTPS_SITE_ENABLE "1"
      has_install_override HTTPS_HTTP_MODE || set_env_var HTTPS_HTTP_MODE "redirect"
      has_install_override AUTO_ENABLE_TROJAN || set_env_var AUTO_ENABLE_TROJAN "1"
      has_install_override ENABLE_TROJAN || set_env_var ENABLE_TROJAN "1"
      has_install_override ENABLE_SUBCONVERTER || set_env_var ENABLE_SUBCONVERTER "1"
      has_install_override SUBSCRIPTION_EXPAND_ALIASES || set_env_var SUBSCRIPTION_EXPAND_ALIASES "1"
      has_install_override DOMAIN_NODE_MODE || set_env_var DOMAIN_NODE_MODE "1"
      has_install_override XUI_BUILTIN_SUB_ENABLE || set_env_var XUI_BUILTIN_SUB_ENABLE "1"
      has_install_override XUI_BUILTIN_ALL_NODES || set_env_var XUI_BUILTIN_ALL_NODES "1"
      log "Domain one-click mode enabled for existing install: ${domains}"
    fi
  fi

  ensure_env_var ENABLE_SUBCONVERTER "1"
  ensure_env_var SUBSCRIPTION_EXPAND_ALIASES "1"
  ensure_env_var DOMAIN_NODE_MODE "1"
  ensure_env_var XUI_BUILTIN_SUB_ENABLE "1"
  ensure_env_var XUI_BUILTIN_ALL_NODES "1"

  ensure_env_var COMPOSE_PROJECT_NAME "3xui_selfhost"
  ensure_env_var XUI_IMAGE "ghcr.io/mhsanaei/3x-ui:latest"
  ensure_env_var XUI_CONTAINER "3xui"
  ensure_env_var PANEL_PORT "$(random_port)"
  ensure_env_var PANEL_LISTEN_IP "127.0.0.1"
  ensure_env_var PANEL_USERNAME "admin_$(random_hex 4)"
  ensure_env_var PANEL_PASSWORD "$(random_password)"
  ensure_env_var WEB_BASE_PATH "p$(random_hex 9)"
  server_addr_default="$(public_ip)"
  ensure_env_var SERVER_ADDR "${server_addr_default:-127.0.0.1}"
  ensure_env_var REALITY_PORT "443"
  ensure_env_var REALITY_TARGET "www.cloudflare.com:443"
  ensure_env_var REALITY_SERVER_NAMES "www.cloudflare.com,cloudflare.com"
  ensure_env_var REALITY_SPIDER_X "/"
  ensure_env_var ENABLE_PRESETS "1"
  ensure_env_var ENABLE_SHADOWSOCKS "1"
  ensure_env_var SHADOWSOCKS_PORT "8388"
  ensure_env_var TROJAN_PORT "9443"
  ensure_env_var HYSTERIA_PORT "8443"
  ensure_env_var SAFE_PROTOCOLS "vless,trojan,shadowsocks,wireguard,hysteria,tunnel"
  ensure_env_var PROTOCOL_GUARD_ACTION "disable"
  ensure_env_var ENABLE_PROTOCOL_GUARD "1"
  ensure_env_var SITE_HTTP_PORT "80"
  ensure_env_var ENABLE_MASK_SITE "1"
  ensure_env_var SUBCONVERTER_IMAGE "tindy2013/subconverter:latest"
  ensure_env_var SUBCONVERTER_PORT "25500"
  ensure_env_var ENABLE_SUB_CONFIG_EDITOR "1"
  ensure_env_var SUB_CONFIG_API_IMAGE "python:3-alpine"
  ensure_env_var SUB_CONFIG_PORT "27880"
  ensure_env_var XUI_API_BASE "http://127.0.0.1:$(awk -F= '$1=="PANEL_PORT"{print $2; exit}' .env)/$(awk -F= '$1=="WEB_BASE_PATH"{print $2; exit}' .env)"
  ensure_env_var XUI_BUILTIN_SUB_LISTEN "127.0.0.1"
  ensure_env_var XUI_BUILTIN_SUB_PORT "2096"
  ensure_env_var XUI_BUILTIN_SUB_PATH "/xui-sub-$(random_hex 6)/"
  ensure_env_var XUI_BUILTIN_JSON_ENABLE "0"
  ensure_env_var XUI_BUILTIN_JSON_PATH "/xui-json-$(random_hex 6)/"
  ensure_env_var XUI_BUILTIN_CLASH_ENABLE "0"
  ensure_env_var XUI_BUILTIN_CLASH_PATH "/xui-clash-$(random_hex 6)/"

  all_nodes_sub_id="$(awk -F= '$1=="ALL_NODES_SUB_ID"{print $2; exit}' .env)"
  default_sub_id="$(awk -F= '$1=="DEFAULT_SUB_ID"{print $2; exit}' .env)"
  if [ -z "$all_nodes_sub_id" ]; then
    all_nodes_sub_id="${default_sub_id:-$(random_hex 8)}"
    set_env_var ALL_NODES_SUB_ID "$all_nodes_sub_id"
  fi
  if [ -z "$default_sub_id" ]; then
    set_env_var DEFAULT_SUB_ID "$all_nodes_sub_id"
  fi
}

write_env() {
  cd "$INSTALL_DIR"
  if [ -f .env ]; then
    log "Keeping existing .env and applying explicit one-click overrides."
    apply_existing_env_overrides
    return
  fi

  local base_path default_addr first_configured_domain server_addr_default enable_acme_default strict_domain_default use_domain_default https_site_default https_http_default all_nodes_sub_id default_sub_id
  base_path="${WEB_BASE_PATH:-p$(random_hex 9)}"
  base_path="${base_path#/}"
  default_addr="$(public_ip)"
  first_configured_domain="$(first_domain "${DOMAIN_NAMES:-}")"
  server_addr_default="$default_addr"
  enable_acme_default="${ENABLE_ACME:-0}"
  strict_domain_default="${STRICT_DOMAIN_CERT:-0}"
  use_domain_default="${USE_DOMAIN_FOR_LINKS:-1}"
  https_site_default="${HTTPS_SITE_ENABLE:-0}"
  https_http_default="${HTTPS_HTTP_MODE:-reject}"
  if [ -n "$first_configured_domain" ]; then
    server_addr_default="$first_configured_domain"
    if [ "${ENABLE_ACME+x}" != "x" ]; then
      enable_acme_default=1
    fi
    if [ "${STRICT_DOMAIN_CERT+x}" != "x" ]; then
      strict_domain_default=1
    fi
    if [ "${USE_DOMAIN_FOR_LINKS+x}" != "x" ]; then
      use_domain_default=1
    fi
    if [ "${HTTPS_SITE_ENABLE+x}" != "x" ]; then
      https_site_default=1
    fi
    if [ "${HTTPS_HTTP_MODE+x}" != "x" ]; then
      https_http_default=redirect
    fi
  fi
  all_nodes_sub_id="${ALL_NODES_SUB_ID:-${DEFAULT_SUB_ID:-$(random_hex 8)}}"
  default_sub_id="${DEFAULT_SUB_ID:-$all_nodes_sub_id}"

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
ALL_NODES_SUB_ID=${all_nodes_sub_id}
DEFAULT_SUB_ID=${default_sub_id}
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
ENABLE_DOKODEMO=${ENABLE_DOKODEMO:-0}
DOKODEMO_LISTEN=${DOKODEMO_LISTEN:-127.0.0.1}
DOKODEMO_PORT=${DOKODEMO_PORT:-18080}
DOKODEMO_TARGET_ADDRESS=${DOKODEMO_TARGET_ADDRESS:-127.0.0.1}
DOKODEMO_TARGET_PORT=${DOKODEMO_TARGET_PORT:-80}
DOKODEMO_NETWORK=${DOKODEMO_NETWORK:-tcp}
DOKODEMO_FOLLOW_REDIRECT=${DOKODEMO_FOLLOW_REDIRECT:-0}
DOKODEMO_TPROXY=${DOKODEMO_TPROXY:-off}
DOKODEMO_FORWARDS=
SAFE_PROTOCOLS=${SAFE_PROTOCOLS:-vless,trojan,shadowsocks,wireguard,hysteria,tunnel}
PROTOCOL_GUARD_ACTION=${PROTOCOL_GUARD_ACTION:-disable}
ENABLE_PROTOCOL_GUARD=${ENABLE_PROTOCOL_GUARD:-1}

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
STRICT_DOMAIN_CERT=${strict_domain_default}
USE_DOMAIN_FOR_LINKS=${use_domain_default}
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
SERVER_ALIASES=${SERVER_ALIASES:-${DOMAIN_NAMES:-${SERVER_ADDR:-${server_addr_default}}}}
SUBSCRIPTION_EXPAND_ALIASES=${SUBSCRIPTION_EXPAND_ALIASES:-1}
DOMAIN_NODE_MODE=${DOMAIN_NODE_MODE:-1}
XUI_API_BASE=${XUI_API_BASE:-http://127.0.0.1:${PANEL_PORT:-2053}/${base_path}}
XUI_API_TOKEN=${XUI_API_TOKEN:-}
XUI_BUILTIN_SUB_ENABLE=${XUI_BUILTIN_SUB_ENABLE:-1}
XUI_BUILTIN_SUB_LISTEN=${XUI_BUILTIN_SUB_LISTEN:-127.0.0.1}
XUI_BUILTIN_SUB_PORT=${XUI_BUILTIN_SUB_PORT:-2096}
XUI_BUILTIN_SUB_PATH=${XUI_BUILTIN_SUB_PATH:-/xui-sub-$(random_hex 6)/}
XUI_BUILTIN_ALL_NODES=${XUI_BUILTIN_ALL_NODES:-1}
XUI_BUILTIN_JSON_ENABLE=${XUI_BUILTIN_JSON_ENABLE:-0}
XUI_BUILTIN_JSON_PATH=${XUI_BUILTIN_JSON_PATH:-/xui-json-$(random_hex 6)/}
XUI_BUILTIN_CLASH_ENABLE=${XUI_BUILTIN_CLASH_ENABLE:-0}
XUI_BUILTIN_CLASH_PATH=${XUI_BUILTIN_CLASH_PATH:-/xui-clash-$(random_hex 6)/}
EOF
  chmod 600 .env
  set_env_var DOKODEMO_FORWARDS "${DOKODEMO_FORWARDS:-}"
}

compose_up() {
  cd "$INSTALL_DIR"
  remove_orphan_compose_containers
  log "Pulling latest official 3x-ui image and starting service."
  docker compose pull 3xui
  docker compose up -d 3xui
}

remove_orphan_compose_containers() {
  local expected_project="${COMPOSE_PROJECT_NAME:-3xui_selfhost}"
  local entries=(
    "${XUI_CONTAINER:-3xui}:3xui"
    "${SUBCONVERTER_CONTAINER:-3xui_subconverter}:subconverter"
    "${SUB_CONFIG_API_CONTAINER:-3xui_subconfig_api}:subconfig-api"
    "${CADDY_CONTAINER:-3xui_site}:caddy-site"
    "${CADDY_HTTPS_CONTAINER:-3xui_https_site}:caddy-https"
  )
  local entry name service project_label service_label
  for entry in "${entries[@]}"; do
    name="${entry%%:*}"
    service="${entry#*:}"
    docker inspect "$name" >/dev/null 2>&1 || continue
    project_label="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
    service_label="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$name" 2>/dev/null || true)"
    if [ "$project_label" = "$expected_project" ] && [ "$service_label" = "$service" ]; then
      continue
    fi
    log "Removing orphan/conflicting container ${name} before compose up."
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
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
  local base_path="${WEB_BASE_PATH:-panel}"
  local url="http://127.0.0.1:${PANEL_PORT:-2053}/${base_path#/}/"
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
  local path_no_slash="${WEB_BASE_PATH:-panel}"
  path_no_slash="${path_no_slash#/}"
  log "Hardening panel login, base path, and listen IP."
  docker exec "${XUI_CONTAINER:-3xui}" /app/x-ui setting \
    -port "${PANEL_PORT:-2053}" \
    -listenIP "${PANEL_LISTEN_IP:-127.0.0.1}" \
    -username "${PANEL_USERNAME:-admin}" \
    -password "${PANEL_PASSWORD:-$(random_password)}" \
    -webBasePath "$path_no_slash" >/dev/null
  docker restart "${XUI_CONTAINER:-3xui}" >/dev/null
  wait_panel_db
  wait_panel_http || true
}

write_install_summary() {
  load_env
  local summary="${INSTALL_DIR}/runtime/install-summary.txt"
  local public_panel_url="http://${SERVER_ADDR:-your-server}:${PANEL_PORT:-2053}/${WEB_BASE_PATH:-panel}/"
  local tunnel_cmd="ssh -L ${PANEL_PORT:-2053}:127.0.0.1:${PANEL_PORT:-2053} root@${SERVER_ADDR:-your-server}"
  local tunnel_panel_url="http://127.0.0.1:${PANEL_PORT:-2053}/${WEB_BASE_PATH:-panel}/"
  local panel_urls="${INSTALL_DIR}/runtime/panel-public-urls.txt"
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    public_panel_url="https://${SERVER_ADDR:-your-server}/${WEB_BASE_PATH:-panel}/"
  fi
  mkdir -p "${INSTALL_DIR}/runtime"
  chmod 700 "${INSTALL_DIR}/runtime"
  : > "$panel_urls"
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && [ -n "${DOMAIN_NAMES:-}" ]; then
    printf '%s' "$DOMAIN_NAMES" | tr ',，;； ' '\n' | awk 'NF && !seen[$0]++' | while IFS= read -r domain; do
      printf 'https://%s/%s/\n' "$domain" "${WEB_BASE_PATH:-panel}" >> "$panel_urls"
    done
  else
    printf '%s\n' "$public_panel_url" > "$panel_urls"
  fi
  chmod 600 "$panel_urls"
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
  All configured domain panel URLs:
    ${panel_urls}

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

  Add a dokodemo-door forwarding inbound (3X-UI protocol name: tunnel):
    ENABLE_DOKODEMO=1 DOKODEMO_LISTEN=127.0.0.1 DOKODEMO_PORT=18080 DOKODEMO_TARGET_ADDRESS=127.0.0.1 DOKODEMO_TARGET_PORT=80 DOKODEMO_NETWORK=tcp ./scripts/apply-presets.sh

  Add multiple port-forward nodes in one command:
    DOKODEMO_FORWARDS='27677,api.example.com,9999,tcp,0.0.0.0;27678,127.0.0.1,8080,tcp,0.0.0.0' ./scripts/apply-presets.sh

  Add or update a port forward from the command line:
    ./scripts/manage.sh forward 27677 127.0.0.1 9999 tcp 0.0.0.0

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
  Forward web UI:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/forward/' "${SERVER_ADDR:-your-server}" || printf 'http://%s:%s/forward/' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}")
  Forward web UI with token auto-filled:
    $([ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && printf 'https://%s/forward/#token=%s' "${SERVER_ADDR:-your-server}" "${SUB_CONFIG_ADMIN_TOKEN:-token}" || printf 'http://%s:%s/forward/#token=%s' "${SERVER_ADDR:-your-server}" "${SITE_HTTP_PORT:-80}" "${SUB_CONFIG_ADMIN_TOKEN:-token}")
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
  Forward editor token:
    ${SUB_CONFIG_ADMIN_TOKEN:-not generated yet}
  Backend image:
    ${SUBCONVERTER_IMAGE:-tindy2013/subconverter:latest}
  Note:
    If HTTPS_SITE_ENABLE=0 and HTTPS_HTTP_MODE=reject, public /sub/ is intentionally blocked after certificate setup. Enable the HTTPS site from x-ui to use /sub/ over TLS.

12) 3X-UI built-in subscription
  Listen:
    ${XUI_BUILTIN_SUB_LISTEN:-127.0.0.1}:${XUI_BUILTIN_SUB_PORT:-2096}
  All nodes subId:
    ${ALL_NODES_SUB_ID:-${DEFAULT_SUB_ID:-not generated yet}}
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

  configure_protocol_guard
  configure_xui_builtin_subscription
  configure_subscription

  write_install_summary
  print_install_summary
  if [ "${MENU_AFTER_INSTALL:-1}" = "1" ] && tty_available; then
    log "Opening terminal menu. You can run it later with: 3xui-kit"
    "${INSTALL_DIR}/scripts/menu.sh"
  fi
}

main "$@"
