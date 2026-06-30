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
SERVER_ADDR="${SERVER_ADDR:-}"
DOMAIN_NAMES="${DOMAIN_NAMES:-}"
SERVER_ALIASES="${SERVER_ALIASES:-}"
DOMAIN_NODE_MODE="${DOMAIN_NODE_MODE:-1}"
SITE_HTTPS_PORT="${SITE_HTTPS_PORT:-443}"
HTTPS_SITE_ENABLE="${HTTPS_SITE_ENABLE:-0}"
XUI_BUILTIN_SUB_ENABLE="${XUI_BUILTIN_SUB_ENABLE:-1}"
XUI_BUILTIN_SUB_LISTEN="${XUI_BUILTIN_SUB_LISTEN:-127.0.0.1}"
XUI_BUILTIN_SUB_PORT="${XUI_BUILTIN_SUB_PORT:-2096}"
XUI_BUILTIN_JSON_ENABLE="${XUI_BUILTIN_JSON_ENABLE:-0}"
XUI_BUILTIN_CLASH_ENABLE="${XUI_BUILTIN_CLASH_ENABLE:-0}"
XUI_BUILTIN_RESTART="${XUI_BUILTIN_RESTART:-1}"
XUI_BUILTIN_RESTART_DELAY="${XUI_BUILTIN_RESTART_DELAY:-15}"
XUI_BUILTIN_ALL_NODES="${XUI_BUILTIN_ALL_NODES:-1}"
ALL_NODES_SUB_ID="${ALL_NODES_SUB_ID:-${DEFAULT_SUB_ID:-}}"
DEFAULT_SUB_ID="${DEFAULT_SUB_ID:-}"

log() { printf '[xui-sub] %s\n' "$*"; }

set_env_var() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ "^" k "=" { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' .env > "$tmp"
  mv "$tmp" .env
  chmod 600 .env
}

random_path() {
  local prefix="$1"
  printf '/%s-%s/' "$prefix" "$(openssl rand -hex 6)"
}

normalize_path() {
  local path="$1"
  path="${path%%[[:space:]]*}"
  [ -n "$path" ] || return 1
  case "$path" in /*) : ;; *) path="/$path" ;; esac
  case "$path" in */) : ;; *) path="$path/" ;; esac
  printf '%s' "$path"
}

ensure_random_path() {
  local var="$1"
  local prefix="$2"
  local value="${!var:-}"
  if [ -z "$value" ] || [ "$value" = "/sub/" ] || [ "$value" = "/json/" ] || [ "$value" = "/clash/" ]; then
    value="$(random_path "$prefix")"
  fi
  value="$(normalize_path "$value")"
  set_env_var "$var" "$value"
  printf '%s' "$value"
}

web_origin() {
  if [ "$HTTPS_SITE_ENABLE" != "1" ]; then
    return 1
  fi
  if [ -z "$SERVER_ADDR" ]; then
    return 1
  fi
  if [ "$SITE_HTTPS_PORT" = "443" ]; then
    printf 'https://%s' "$SERVER_ADDR"
  else
    printf 'https://%s:%s' "$SERVER_ADDR" "$SITE_HTTPS_PORT"
  fi
}

api_token() {
  if [ -n "${XUI_API_TOKEN:-}" ]; then
    printf '%s' "$XUI_API_TOKEN"
    return
  fi
  local out token
  out="$(docker exec "$XUI_CONTAINER" /app/x-ui setting -getApiToken true)"
  token="$(printf '%s\n' "$out" | awk '/apiToken:/ {print $2}' | tail -n1)"
  [ -n "$token" ] || { echo "Could not generate 3x-ui API token." >&2; exit 1; }
  set_env_var XUI_API_TOKEN "$token"
  printf '%s' "$token"
}

api_base() {
  printf 'http://127.0.0.1:%s/%s' "$PANEL_PORT" "${WEB_BASE_PATH#/}"
}

wait_api() {
  local token="$1"
  local base="$2"
  local i
  for i in $(seq 1 60); do
    if curl -fsS --connect-timeout 2 --max-time 5 -H "Authorization: Bearer ${token}" \
      -X POST "${base%/}/panel/api/setting/all" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "3x-ui API is not reachable at ${base%/}/panel/api/setting/all" >&2
  return 1
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

normalize_list_lines() {
  printf '%s' "$1" | tr ',，;； ' '\n' | awk 'NF && !seen[$0]++'
}

domain_node_count() {
  local values="${SERVER_ALIASES:-${DOMAIN_NAMES:-${SERVER_ADDR:-}}}"
  normalize_list_lines "$values" | awk 'NF { count++ } END { print count + 0 }'
}

domain_node_mode_active() {
  [ "$(truthy "${DOMAIN_NODE_MODE:-1}")" = "true" ] && [ "$(domain_node_count)" -gt 1 ]
}

ensure_subscription_ids() {
  if [ -z "${ALL_NODES_SUB_ID:-}" ]; then
    ALL_NODES_SUB_ID="$(openssl rand -hex 8)"
    set_env_var ALL_NODES_SUB_ID "$ALL_NODES_SUB_ID"
  fi
  if [ -z "${DEFAULT_SUB_ID:-}" ]; then
    DEFAULT_SUB_ID="$ALL_NODES_SUB_ID"
    set_env_var DEFAULT_SUB_ID "$DEFAULT_SUB_ID"
  fi
  set_env_var XUI_BUILTIN_ALL_NODES "$XUI_BUILTIN_ALL_NODES"
}

api_post_json() {
  local token="$1"
  local base="$2"
  local path="$3"
  local file="$4"
  curl -fsS --connect-timeout 3 --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -X POST --data-binary "@${file}" \
    "${base%/}${path}"
}

sync_all_subscription_id() {
  [ "$(truthy "$XUI_BUILTIN_ALL_NODES")" = "true" ] || return 0
  [ -n "$ALL_NODES_SUB_ID" ] || return 0

  local token="$1"
  local base="$2"
  local updates payload id file domain_mode
  if domain_node_mode_active; then
    domain_mode=true
  else
    domain_mode=false
  fi

  curl -fsS --connect-timeout 3 --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    "${base%/}/panel/api/inbounds/list" > runtime/xui-inbounds-for-all-nodes-subid.json

  updates="$(
    jq -c --arg subId "$ALL_NODES_SUB_ID" --argjson domainMode "$domain_mode" '
      def obj:
        if type == "string" then (fromjson? // {}) else (. // {}) end;
      def subscribable_client:
        type == "object";
      def domain_node:
        ((.comment // "") | startswith("domain-node:"));
      def generated_kit_client:
        (((.comment // "") | contains("generated by 3xui-selfhost-kit"))
        or ((.email // "") | test("^me-(vless|trojan|shadowsocks|hysteria2)-")));
      def desired_subid:
        if $domainMode then
          if domain_node then $subId
          elif generated_kit_client then ""
          else (.subId // "")
          end
        else $subId
        end;
      .obj[]? as $inbound
      | ($inbound.settings | obj) as $settings
      | ($settings.clients // []) as $clients
      | select(($clients | any(subscribable_client and ((.subId // "") != desired_subid))))
      | {
          id: $inbound.id,
          enable: ($inbound.enable // true),
          remark: ($inbound.remark // ""),
          listen: ($inbound.listen // ""),
          port: ($inbound.port // 0),
          shareAddr: ($inbound.shareAddr // ""),
          shareAddrStrategy: ($inbound.shareAddrStrategy // "listen"),
          protocol: ($inbound.protocol // ""),
          expiryTime: ($inbound.expiryTime // 0),
          total: ($inbound.total // 0),
          trafficReset: ($inbound.trafficReset // "never"),
          settings: ($settings | .clients = (($settings.clients // []) | map(if subscribable_client then .subId = desired_subid else . end))),
          streamSettings: ($inbound.streamSettings | obj),
          sniffing: ($inbound.sniffing | obj)
        }
    ' runtime/xui-inbounds-for-all-nodes-subid.json 2>/dev/null || true
  )"

  [ -n "$updates" ] || return 0
  while IFS= read -r payload; do
    [ -n "$payload" ] || continue
    id="$(printf '%s' "$payload" | jq -r '.id // empty')"
    [ -n "$id" ] || continue
    file="runtime/xui-inbound-all-nodes-subid-${id}.json"
    printf '%s\n' "$payload" > "$file"
    log "Syncing all client subId to ALL_NODES_SUB_ID for inbound ${id}"
    api_post_json "$token" "$base" "/panel/api/inbounds/update/${id}" "$file" | jq . || true
  done <<< "$updates"
}

write_builtin_client_links() {
  local token="$1"
  local base="$2"
  local sub_uri="$3"
  local json_uri="$4"
  local clash_uri="$5"
  local sub_path="$6"
  local json_path="$7"
  local clash_path="$8"

  [ -n "$sub_uri" ] || sub_uri="http://${XUI_BUILTIN_SUB_LISTEN}:${XUI_BUILTIN_SUB_PORT}${sub_path}"
  [ -n "$json_uri" ] || json_uri="http://${XUI_BUILTIN_SUB_LISTEN}:${XUI_BUILTIN_SUB_PORT}${json_path}"
  [ -n "$clash_uri" ] || clash_uri="http://${XUI_BUILTIN_SUB_LISTEN}:${XUI_BUILTIN_SUB_PORT}${clash_path}"

  curl -fsS --connect-timeout 3 --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    "${base%/}/panel/api/inbounds/list" > runtime/xui-builtin-inbounds.json

  jq -r \
    --arg subUri "$sub_uri" \
    --arg jsonUri "$json_uri" \
    --arg clashUri "$clash_uri" \
    --arg allNodesSubId "$ALL_NODES_SUB_ID" \
    --arg defaultSubId "$DEFAULT_SUB_ID" \
    --argjson allNodesEnable "$(truthy "$XUI_BUILTIN_ALL_NODES")" \
    --argjson jsonEnable "$(truthy "$XUI_BUILTIN_JSON_ENABLE")" \
    --argjson clashEnable "$(truthy "$XUI_BUILTIN_CLASH_ENABLE")" '
    def settings_obj:
      if (.settings | type) == "string" then (.settings | fromjson? // {}) else (.settings // {}) end;
    [
      .obj[]? as $inbound
      | ($inbound | settings_obj | .clients // [])[]?
      | select((.subId // "") != "")
      | {email: (.email // "unknown"), subId: .subId}
    ]
    | sort_by(.subId, .email)
    | group_by(.subId)[]
    | . as $clients
    | ($clients[0].subId) as $subId
    | (
        if $allNodesEnable and $allNodesSubId != "" and $subId == $allNodesSubId then
          "all-nodes (\($clients | length) nodes)"
        elif $defaultSubId != "" and $subId == $defaultSubId then
          "default-managed-nodes (\($clients | length) nodes)"
        elif ($clients | length) > 1 then
          "shared-subscription (\($clients | length) nodes)"
        else
          $clients[0].email
        end
      ) as $label
    | "client: \($label)",
      (if ($clients | length) > 1 then "  includes: \($clients | map(.email) | join(", "))" else empty end),
      "  sub: \($subUri)\($subId)",
      (if $jsonEnable then "  json: \($jsonUri)\($subId)" else empty end),
      (if $clashEnable then "  clash: \($clashUri)\($subId)" else empty end)
  ' runtime/xui-builtin-inbounds.json > runtime/xui-builtin-sub-links.txt

  if [ ! -s runtime/xui-builtin-sub-links.txt ]; then
    printf 'No enabled clients with subId were found yet.\n' > runtime/xui-builtin-sub-links.txt
  fi
  chmod 600 runtime/xui-builtin-sub-links.txt
}

configure_panel_subscription() {
  [ "$XUI_BUILTIN_SUB_ENABLE" = "1" ] || { log "Built-in 3x-ui subscription is disabled."; return 0; }

  local sub_path json_path clash_path origin sub_uri json_uri clash_uri token base
  sub_path="$(ensure_random_path XUI_BUILTIN_SUB_PATH xui-sub)"
  json_path="$(ensure_random_path XUI_BUILTIN_JSON_PATH xui-json)"
  clash_path="$(ensure_random_path XUI_BUILTIN_CLASH_PATH xui-clash)"
  set_env_var XUI_BUILTIN_SUB_LISTEN "$XUI_BUILTIN_SUB_LISTEN"
  set_env_var XUI_BUILTIN_SUB_PORT "$XUI_BUILTIN_SUB_PORT"
  set_env_var XUI_BUILTIN_JSON_ENABLE "$XUI_BUILTIN_JSON_ENABLE"
  set_env_var XUI_BUILTIN_CLASH_ENABLE "$XUI_BUILTIN_CLASH_ENABLE"

  if origin="$(web_origin)"; then
    sub_uri="${origin}${sub_path}"
    json_uri="${origin}${json_path}"
    clash_uri="${origin}${clash_path}"
  else
    sub_uri=""
    json_uri=""
    clash_uri=""
    log "HTTPS site is not enabled, so built-in public subscription URIs are left empty."
  fi

  mkdir -p runtime
  token="$(api_token)"
  base="$(api_base)"
  wait_api "$token" "$base"
  ensure_subscription_ids
  sync_all_subscription_id "$token" "$base"

  curl -fsS --connect-timeout 3 --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    -X POST "${base%/}/panel/api/setting/all" > runtime/xui-setting-all.json

  jq --arg listen "$XUI_BUILTIN_SUB_LISTEN" \
     --argjson port "$XUI_BUILTIN_SUB_PORT" \
     --arg subPath "$sub_path" \
     --arg jsonPath "$json_path" \
     --arg clashPath "$clash_path" \
     --arg subURI "$sub_uri" \
     --arg jsonURI "$json_uri" \
     --arg clashURI "$clash_uri" \
     --argjson jsonEnable "$(truthy "$XUI_BUILTIN_JSON_ENABLE")" \
     --argjson clashEnable "$(truthy "$XUI_BUILTIN_CLASH_ENABLE")" \
     '.obj
      | .subEnable=true
      | .subListen=$listen
      | .subPort=$port
      | .subPath=$subPath
      | .subURI=$subURI
      | .subJsonEnable=$jsonEnable
      | .subJsonPath=$jsonPath
      | .subJsonURI=$jsonURI
      | .subClashEnable=$clashEnable
      | .subClashPath=$clashPath
      | .subClashURI=$clashURI
      | .subCertFile=""
      | .subKeyFile=""' \
    runtime/xui-setting-all.json > runtime/xui-setting-update.json

  curl -fsS --connect-timeout 3 --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -X POST --data-binary @runtime/xui-setting-update.json \
    "${base%/}/panel/api/setting/update" > runtime/xui-setting-update-response.json

  jq -e '.success == true' runtime/xui-setting-update-response.json >/dev/null
  write_builtin_client_links "$token" "$base" "$sub_uri" "$json_uri" "$clash_uri" "$sub_path" "$json_path" "$clash_path"
  log "3x-ui built-in subscription base: ${sub_uri:-local-only at ${XUI_BUILTIN_SUB_LISTEN}:${XUI_BUILTIN_SUB_PORT}${sub_path}}"
  log "3x-ui built-in client links: ${ROOT_DIR}/runtime/xui-builtin-sub-links.txt"
}

caddy_base_path_args() {
  local sub_path json_path clash_path
  sub_path="$(normalize_path "${XUI_BUILTIN_SUB_PATH:-}")"
  json_path="$(normalize_path "${XUI_BUILTIN_JSON_PATH:-}")"
  clash_path="$(normalize_path "${XUI_BUILTIN_CLASH_PATH:-}")"
  printf '%s %s %s %s %s %s' \
    "${sub_path%/}" "$sub_path" \
    "${json_path%/}" "$json_path" \
    "${clash_path%/}" "$clash_path"
}

caddy_subid_path_args() {
  local sub_path json_path clash_path
  sub_path="$(normalize_path "${XUI_BUILTIN_SUB_PATH:-}")"
  json_path="$(normalize_path "${XUI_BUILTIN_JSON_PATH:-}")"
  clash_path="$(normalize_path "${XUI_BUILTIN_CLASH_PATH:-}")"
  printf '%s/* %s/* %s/*' \
    "${sub_path%/}" "${json_path%/}" "${clash_path%/}"
}

upsert_caddy_proxy() {
  [ "$HTTPS_SITE_ENABLE" = "1" ] || return 0
  [ -f caddy/Caddyfile ] || return 0

  local tmp block base_paths subid_paths
  tmp="$(mktemp)"
  block="$(mktemp)"
  base_paths="$(caddy_base_path_args)"
  subid_paths="$(caddy_subid_path_args)"
  cat > "$block" <<EOF
	# 3xui builtin subscription start
	@xuiBuiltinSubBase path ${base_paths}
	redir @xuiBuiltinSubBase /sub/ 308
	@xuiBuiltinSub path ${subid_paths}
	handle @xuiBuiltinSub {
		reverse_proxy 127.0.0.1:${XUI_BUILTIN_SUB_PORT}
	}
	# 3xui builtin subscription end
EOF

  awk -v block_file="$block" '
    BEGIN {
      while ((getline line < block_file) > 0) {
        block = block line "\n"
      }
    }
    /# 3xui builtin subscription start/ { skip = 1; next }
    /# 3xui builtin subscription end/ { skip = 0; next }
    skip { next }
    !inserted && $0 ~ /^[[:space:]]*(handle_path \/subconverter\/\*|root \*)/ {
      printf "%s", block
      inserted = 1
    }
    { print }
    END {
      if (!inserted) {
        printf "%s", block
      }
    }
  ' caddy/Caddyfile > "$tmp"
  mv "$tmp" caddy/Caddyfile
  rm -f "$block"

  if docker inspect "${CADDY_HTTPS_CONTAINER:-3xui_https_site}" >/dev/null 2>&1; then
    docker restart "${CADDY_HTTPS_CONTAINER:-3xui_https_site}" >/dev/null || true
  fi
}

secure_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${XUI_BUILTIN_SUB_PORT}/tcp" >/dev/null 2>&1 || true
    ufw deny "${XUI_BUILTIN_SUB_PORT}/tcp" >/dev/null 2>&1 || true
  fi
}

restart_xui_later() {
  [ "$XUI_BUILTIN_RESTART" = "1" ] || return 0
  mkdir -p runtime
  chmod 700 runtime
  log "Scheduling 3x-ui restart in ${XUI_BUILTIN_RESTART_DELAY}s so new subscription settings take effect."
  nohup sh -c "sleep '${XUI_BUILTIN_RESTART_DELAY}'; docker restart '${XUI_CONTAINER}' >>'${ROOT_DIR}/runtime/xui-builtin-subscription-restart.log' 2>&1 || true" >/dev/null 2>&1 &
}

main() {
  [ "$XUI_BUILTIN_SUB_ENABLE" = "1" ] || exit 0
  configure_panel_subscription
  # Reload env because paths/tokens may have been generated above.
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  XUI_BUILTIN_SUB_PORT="${XUI_BUILTIN_SUB_PORT:-2096}"
  upsert_caddy_proxy
  secure_firewall
  restart_xui_later
}

main "$@"
