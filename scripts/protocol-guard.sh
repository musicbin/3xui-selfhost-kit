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
WEB_BASE_PATH="${WEB_BASE_PATH:-panel}"
PROTOCOL_GUARD_ACTION="${PROTOCOL_GUARD_ACTION:-disable}"
SAFE_PROTOCOLS="${SAFE_PROTOCOLS:-vless,trojan,shadowsocks,wireguard,hysteria,tunnel}"

api_token() {
  if [ -n "${XUI_API_TOKEN:-}" ]; then
    printf '%s' "$XUI_API_TOKEN"
    return
  fi
  local out token
  out="$(docker exec "$XUI_CONTAINER" /app/x-ui setting -getApiToken true)"
  token="$(printf '%s\n' "$out" | awk '/apiToken:/ {print $2}' | tail -n1)"
  [ -n "$token" ] || { echo "Could not generate 3x-ui API token." >&2; exit 1; }
  printf '%s' "$token"
}

api_base() {
  printf 'http://127.0.0.1:%s/%s' "$PANEL_PORT" "${WEB_BASE_PATH#/}"
}

is_safe_protocol() {
  local protocol="$1"
  printf ',%s,' "$SAFE_PROTOCOLS" | grep -q ",${protocol},"
}

main() {
  local token base list rows changed id protocol remark enable
  token="$(api_token)"
  base="$(api_base)"
  list="$(curl -fsS --connect-timeout 3 --max-time 30 -H "Authorization: Bearer ${token}" "${base%/}/panel/api/inbounds/list")"
  rows="$(printf '%s' "$list" | jq -r '.obj[]? | [.id, .protocol, .remark, .enable] | @tsv')"
  changed=0

  while IFS=$'\t' read -r id protocol remark enable; do
    [ -n "$id" ] || continue
    if is_safe_protocol "$protocol"; then
      continue
    fi
    case "$PROTOCOL_GUARD_ACTION" in
      delete)
        echo "Deleting unsafe inbound: ${remark} (${protocol}, id=${id})"
        curl -fsS --connect-timeout 3 --max-time 30 -X POST -H "Authorization: Bearer ${token}" \
          "${base%/}/panel/api/inbounds/del/${id}" | jq . || true
        changed=1
        ;;
      disable|*)
        if [ "$enable" = "true" ]; then
          echo "Disabling unsafe inbound: ${remark} (${protocol}, id=${id})"
          curl -fsS --connect-timeout 3 --max-time 30 -X POST -H "Authorization: Bearer ${token}" \
            -F enable=false "${base%/}/panel/api/inbounds/setEnable/${id}" | jq . || true
          changed=1
        else
          echo "Already disabled unsafe inbound: ${remark} (${protocol}, id=${id})"
        fi
        ;;
    esac
  done <<< "$rows"

  if [ "$changed" = "1" ]; then
    curl -fsS --connect-timeout 3 --max-time 30 -X POST -H "Authorization: Bearer ${token}" \
      "${base%/}/panel/api/server/restartXrayService" | jq . || true
  fi

  echo "Safe protocol allowlist: ${SAFE_PROTOCOLS}"
  echo "Action: ${PROTOCOL_GUARD_ACTION}"
}

main "$@"
