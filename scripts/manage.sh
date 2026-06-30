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
EOF
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
  network-check)
    ./scripts/network-check.sh
    ;;
  *)
    usage
    [ -z "$cmd" ] || exit 1
    ;;
esac
