#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
  OVERRIDE_KEYS=(XUI_CONTAINER PANEL_PORT WEB_BASE_PATH SERVER_ADDR)
  for key in "${OVERRIDE_KEYS[@]}"; do
    if [ "${!key+x}" = "x" ]; then
      printf -v "__override_${key}" '%s' "${!key}"
    fi
  done
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  for key in "${OVERRIDE_KEYS[@]}"; do
    override_name="__override_${key}"
    if [ "${!override_name+x}" = "x" ]; then
      printf -v "$key" '%s' "${!override_name}"
      export "$key"
    fi
  done
fi

XUI_CONTAINER="${XUI_CONTAINER:-3xui}"

usage() {
  cat <<'EOF'
Usage: ./scripts/manage.sh <command>

Commands:
  menu           Open terminal menu panel
  status         Show container status and panel URL hint
  logs           Tail 3x-ui logs
  update         Start safe official-image update in background
  safe-update    Start safe official-image update in background
  reconcile      Re-apply local hardening after image/system changes
  backup         Backup local SQLite database and .env
  apply-presets  Re-apply protocol presets from .env
  refresh-links  Refresh domain nodes for /sub/, 3.5.yaml render, and 3X-UI built-in all-nodes subscription
  links          Print generated client links
  token          Generate a fresh 3x-ui API token
  autostart      Open boot autostart settings
  domain         Configure domains, HTTPS certificates, and Trojan TLS
  subscription   Generate local subscription converter web UI
  xui-subscription Configure 3x-ui built-in subscription behind HTTPS
  mask-site      Regenerate the static masquerade site
  network-check  Check A/AAAA records, IPv4/IPv6, and local listeners
  protocol-guard Disable or delete unsafe inbound protocols
  forward        Add/update a dokodemo-door/tunnel port forward

Forward examples:
  ./scripts/manage.sh forward
  ./scripts/manage.sh forward 27677 127.0.0.1 9999
  ./scripts/manage.sh forward 27677 127.0.0.1 9999 tcp 0.0.0.0
EOF
}

validate_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || { echo "Invalid port: ${port}" >&2; exit 1; }
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { echo "Port out of range: ${port}" >&2; exit 1; }
}

validate_no_newline() {
  local label="$1"
  local value="$2"
  case "$value" in
    *$'\n'*|*$'\r'*) echo "Invalid ${label}: contains newline" >&2; exit 1 ;;
  esac
}

normalize_network() {
  local network="${1:-tcp}"
  network="${network,,}"
  case "$network" in
    tcp|udp|tcp,udp) printf '%s' "$network" ;;
    *) echo "Network must be tcp, udp, or tcp,udp." >&2; exit 1 ;;
  esac
}

open_forward_firewall() {
  local listen_addr="$1"
  local listen_port="$2"
  local network="$3"

  case "$listen_addr" in
    127.0.0.1|localhost|::1)
      echo "Forward listens on ${listen_addr}; no public firewall rule needed."
      return 0
      ;;
  esac

  if command -v ufw >/dev/null 2>&1; then
    case "$network" in
      tcp) ufw allow "${listen_port}/tcp" >/dev/null 2>&1 || true ;;
      udp) ufw allow "${listen_port}/udp" >/dev/null 2>&1 || true ;;
      tcp,udp)
        ufw allow "${listen_port}/tcp" >/dev/null 2>&1 || true
        ufw allow "${listen_port}/udp" >/dev/null 2>&1 || true
        ;;
    esac
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    case "$network" in
      tcp) firewall-cmd --permanent --add-port="${listen_port}/tcp" >/dev/null 2>&1 || true ;;
      udp) firewall-cmd --permanent --add-port="${listen_port}/udp" >/dev/null 2>&1 || true ;;
      tcp,udp)
        firewall-cmd --permanent --add-port="${listen_port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${listen_port}/udp" >/dev/null 2>&1 || true
        ;;
    esac
    firewall-cmd --reload >/dev/null 2>&1 || true
  else
    echo "No ufw/firewalld detected. If this is public, also open ${listen_port}/${network} in the VPS firewall/security group."
  fi
}

configure_forward() {
  local interactive=0
  [ "$#" -lt 3 ] && interactive=1
  local listen_port="${1:-}"
  local target_addr="${2:-}"
  local target_port="${3:-}"
  local network="${4:-}"
  local listen_addr="${5:-}"
  local follow_redirect="${6:-}"

  if [ -z "$listen_port" ]; then
    echo "端口转发：外部访问端口 -> 目标IP:目标端口"
    echo "例子：公网访问 服务器IP:27677 转到本机 127.0.0.1:9999"
    echo
    read -r -p "外部访问端口，例如 27677: " listen_port </dev/tty || listen_port=""
  fi
  if [ -z "$target_addr" ]; then
    read -r -p "转发到哪个IP/域名 [127.0.0.1]: " target_addr </dev/tty || target_addr=""
    target_addr="${target_addr:-127.0.0.1}"
  fi
  if [ -z "$target_port" ]; then
    read -r -p "转发到哪个端口，例如 9999: " target_port </dev/tty || target_port=""
  fi
  if [ -z "$network" ]; then
    if [ "$interactive" = "1" ]; then
      read -r -p "协议 tcp/udp/tcp,udp [tcp]: " network </dev/tty || network=""
    fi
    network="${network:-tcp}"
  fi
  if [ -z "$listen_addr" ]; then
    if [ "$interactive" = "1" ]; then
      read -r -p "谁能访问这个转发？本机填 127.0.0.1，公网填 0.0.0.0 [127.0.0.1]: " listen_addr </dev/tty || listen_addr=""
    fi
    listen_addr="${listen_addr:-127.0.0.1}"
  fi
  if [ -z "$follow_redirect" ]; then
    if [ "$interactive" = "1" ]; then
      read -r -p "是否开启透明转发 followRedirect？普通端口转发直接回车 [y/N]: " follow_redirect </dev/tty || follow_redirect=""
    fi
    follow_redirect="${follow_redirect:-0}"
  fi

  validate_port "$listen_port"
  validate_port "$target_port"
  validate_no_newline "target address" "$target_addr"
  validate_no_newline "listen address" "$listen_addr"
  network="$(normalize_network "$network")"
  case "$follow_redirect" in
    y|Y|yes|YES|1|true|TRUE) follow_redirect=1 ;;
    *) follow_redirect=0 ;;
  esac

  set_env_var ENABLE_DOKODEMO "1"
  set_env_var DOKODEMO_LISTEN "$listen_addr"
  set_env_var DOKODEMO_PORT "$listen_port"
  set_env_var DOKODEMO_TARGET_ADDRESS "$target_addr"
  set_env_var DOKODEMO_TARGET_PORT "$target_port"
  set_env_var DOKODEMO_NETWORK "$network"
  set_env_var DOKODEMO_FOLLOW_REDIRECT "$follow_redirect"

  ENABLE_DOKODEMO=1 \
    DOKODEMO_LISTEN="$listen_addr" \
    DOKODEMO_PORT="$listen_port" \
    DOKODEMO_TARGET_ADDRESS="$target_addr" \
    DOKODEMO_TARGET_PORT="$target_port" \
    DOKODEMO_NETWORK="$network" \
    DOKODEMO_FOLLOW_REDIRECT="$follow_redirect" \
    DOKODEMO_FORWARDS="" \
    RECREATE_DOKODEMO_INBOUND=1 \
    ./scripts/apply-presets.sh

  open_forward_firewall "$listen_addr" "$listen_port" "$network"
  echo "Forward ready: ${listen_addr}:${listen_port} -> ${target_addr}:${target_port} (${network})"
  echo "3X-UI panel protocol name: tunnel"
}

cmd="${1:-}"

case "$cmd" in
  menu)
    ./scripts/menu.sh
    ;;
  status)
    docker compose ps
    echo
    if [ -x ./scripts/menu.sh ]; then
      ./scripts/menu.sh --print
    else
      echo "Visual panel:"
      echo "  Bind:      ${PANEL_LISTEN_IP:-127.0.0.1}:${PANEL_PORT:-2053}"
      echo "  Path:      /${WEB_BASE_PATH:-panel}/"
      echo "  Public:    http://${SERVER_ADDR:-your-server}:${PANEL_PORT:-2053}/${WEB_BASE_PATH:-panel}/"
      echo "  Username:  ${PANEL_USERNAME:-unknown}"
      echo "  Password:  ${PANEL_PASSWORD:-unknown}"
      echo
      echo "Open through SSH tunnel:"
      echo "  ssh -L ${PANEL_PORT:-2053}:127.0.0.1:${PANEL_PORT:-2053} root@${SERVER_ADDR:-your-server}"
      echo "  http://127.0.0.1:${PANEL_PORT:-2053}/${WEB_BASE_PATH:-panel}/"
    fi
    ;;
  logs)
    docker compose logs -f --tail=200 3xui
    ;;
  update|safe-update)
    ./scripts/safe-update.sh
    ;;
  reconcile)
    ./scripts/reconcile.sh
    ;;
  backup)
    ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p data/backups
    if [ -f data/db/x-ui.db ]; then
      cp -p data/db/x-ui.db "data/backups/x-ui-${ts}.db"
    fi
    cp -p .env "data/backups/env-${ts}.txt"
    chmod 600 data/backups/*"${ts}"* 2>/dev/null || true
    echo "Backup written to data/backups/*${ts}*"
    ;;
  apply-presets)
    ./scripts/apply-presets.sh
    ;;
  refresh-links)
    ./scripts/apply-presets.sh
    if [ "${XUI_BUILTIN_SUB_ENABLE:-1}" = "1" ]; then
      ./scripts/xui-builtin-subscription.sh || true
    fi
    ./scripts/subscription.sh
    echo "Domain nodes refreshed for /sub/, 3.5.yaml render, and 3X-UI built-in all-nodes subscription."
    ;;
  links)
    if [ -f runtime/install-summary.txt ]; then
      echo "Config files:"
      echo "  runtime/client-links.txt"
      echo "  runtime/panel-all-links.txt"
      echo
    fi
    if [ -f runtime/client-links.txt ]; then
      echo "Script-generated links:"
      cat runtime/client-links.txt
    else
      echo "No generated links yet. Run: ./scripts/manage.sh apply-presets"
    fi
    if [ -s runtime/panel-all-links.txt ]; then
      echo
      echo "Panel-rendered links:"
      cat runtime/panel-all-links.txt
    fi
    ;;
  token)
    docker exec "$XUI_CONTAINER" /app/x-ui setting -getApiToken true
    ;;
  autostart)
    ./scripts/menu.sh --autostart
    ;;
  domain)
    ./scripts/domain-cert.sh
    ;;
  subscription)
    ./scripts/subscription.sh
    ;;
  xui-subscription)
    ./scripts/xui-builtin-subscription.sh
    ;;
  mask-site)
    ./scripts/mask-site.sh
    if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
      docker compose --profile https-site up -d caddy-https
    else
      docker compose --profile site up -d caddy-site
    fi
    ;;
  protocol-guard)
    ./scripts/protocol-guard.sh
    ;;
  forward|port-forward|dokodemo|tunnel)
    shift
    configure_forward "$@"
    ;;
  network-check)
    ./scripts/network-check.sh
    ;;
  *)
    usage
    [ -z "$cmd" ] || exit 1
    ;;
esac
