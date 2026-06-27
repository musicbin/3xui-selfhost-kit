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
  update         Pull latest official image and restart
  backup         Backup local SQLite database and .env
  apply-presets  Re-apply protocol presets from .env
  links          Print generated client links
  token          Generate a fresh 3x-ui API token
  autostart      Open boot autostart settings
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
  update)
    ./scripts/manage.sh backup
    docker compose pull 3xui
    docker compose up -d 3xui
    docker exec "$XUI_CONTAINER" /app/x-ui setting -show true >/dev/null
    echo "Updated official 3x-ui image and restarted."
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
  *)
    usage
    [ -z "$cmd" ] || exit 1
    ;;
esac
