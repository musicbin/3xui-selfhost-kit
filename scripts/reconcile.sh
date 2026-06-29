#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

[ -f .env ] || { echo ".env not found. Run install.sh first." >&2; exit 1; }

set -a
# shellcheck disable=SC1091
. ./.env
set +a

XUI_CONTAINER="${XUI_CONTAINER:-3xui}"
PANEL_PORT="${PANEL_PORT:-2053}"
PANEL_LISTEN_IP="${PANEL_LISTEN_IP:-127.0.0.1}"
WEB_BASE_PATH="${WEB_BASE_PATH:-panel}"

log() { printf '[reconcile] %s\n' "$*"; }

api_token() {
  if [ -n "${XUI_API_TOKEN:-}" ]; then
    printf '%s' "$XUI_API_TOKEN"
    return
  fi
  local out token
  out="$(docker exec "$XUI_CONTAINER" /app/x-ui setting -getApiToken true)"
  token="$(printf '%s\n' "$out" | awk '/apiToken:/ {print $2}' | tail -n1)"
  [ -n "$token" ] || return 1
  printf '%s' "$token"
}

wait_panel() {
  local token i base
  token="$(api_token)"
  base="http://127.0.0.1:${PANEL_PORT}/${WEB_BASE_PATH#/}"
  for i in $(seq 1 90); do
    if curl -fsS --connect-timeout 2 --max-time 5 -H "Authorization: Bearer ${token}" \
      "$base/panel/api/server/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

ok=1

log "Ensuring 3X-UI container is running."
docker compose up -d 3xui || ok=0
docker start "$XUI_CONTAINER" >/dev/null 2>&1 || true

if wait_panel; then
  log "Panel API is reachable."
else
  log "Panel API is not reachable."
  ok=0
fi

log "Re-applying panel port, listen IP, and base path."
docker exec "$XUI_CONTAINER" /app/x-ui setting \
  -port "$PANEL_PORT" \
  -listenIP "$PANEL_LISTEN_IP" \
  -webBasePath "${WEB_BASE_PATH#/}" >/dev/null || ok=0

if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && [ -n "${DOMAIN_NAMES:-}" ]; then
  log "Reconciling domains, HTTPS, Caddy, and built-in subscription proxy."
  ./scripts/domain-cert.sh --auto || ok=0
fi

log "Reconciling protocol presets."
./scripts/apply-presets.sh || ok=0

log "Applying unsafe protocol guard."
./scripts/protocol-guard.sh || ok=0

log "Refreshing subscription converter and editable 3.5.yaml UI."
./scripts/subscription.sh || ok=0

if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
  log "Reconciling 3X-UI built-in subscription HTTPS URI."
  ./scripts/xui-builtin-subscription.sh || ok=0
fi

log "Regenerating masquerade page."
./scripts/mask-site.sh || true

if [ -x ./scripts/network-check.sh ]; then
  log "Running DNS/IPv4/IPv6 check."
  ./scripts/network-check.sh || true
fi

if [ "$ok" = "1" ]; then
  log "Reconcile completed."
else
  log "Reconcile completed with errors. Check logs above."
  exit 1
fi
