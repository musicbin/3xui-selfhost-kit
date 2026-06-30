#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

[ -f .env ] || { echo ".env not found. Run install.sh first." >&2; exit 1; }

OVERRIDE_KEYS=(
  XUI_CONTAINER PANEL_PORT WEB_BASE_PATH SERVER_ADDR DOMAIN_NAMES SERVER_ALIASES DOMAIN_NODE_MODE
  REALITY_PORT REALITY_TARGET REALITY_SERVER_NAMES REALITY_SPIDER_X
  ENABLE_HYSTERIA ENABLE_TROJAN ENABLE_SHADOWSOCKS ALLOW_SELF_SIGNED_TLS
  HYSTERIA_PORT TROJAN_PORT SHADOWSOCKS_PORT TLS_CERT_FILE TLS_KEY_FILE TLS_SERVER_NAME
  ENABLE_DOKODEMO DOKODEMO_LISTEN DOKODEMO_PORT DOKODEMO_TARGET_ADDRESS DOKODEMO_TARGET_PORT
  DOKODEMO_NETWORK DOKODEMO_FOLLOW_REDIRECT DOKODEMO_TPROXY DOKODEMO_FORWARDS RECREATE_DOKODEMO_INBOUND
  CHAIN_ENABLED CHAIN_MODE CHAIN_TYPE CHAIN_ADDRESS CHAIN_PORT CHAIN_USER CHAIN_PASS
  CHAIN_SERVER_NAME CHAIN_ALLOW_INSECURE
  PRESET_CLIENT_SUFFIX ALL_NODES_SUB_ID DEFAULT_SUB_ID XUI_BUILTIN_ALL_NODES RECREATE_MANAGED_INBOUNDS
)

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

XUI_CONTAINER="${XUI_CONTAINER:-3xui}"
PANEL_PORT="${PANEL_PORT:-2053}"
WEB_BASE_PATH="${WEB_BASE_PATH:-panel}"
SERVER_ADDR="${SERVER_ADDR:-}"
DOMAIN_NAMES="${DOMAIN_NAMES:-}"
SERVER_ALIASES="${SERVER_ALIASES:-}"
DOMAIN_NODE_MODE="${DOMAIN_NODE_MODE:-1}"
API_BASE="http://127.0.0.1:${PANEL_PORT}/${WEB_BASE_PATH#/}"

mkdir -p runtime data/cert
chmod 700 runtime

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }
}

need curl
need jq
need openssl

rand_hex() { openssl rand -hex "${1:-8}"; }
rand_b64() { openssl rand -base64 "${1:-24}" | tr -d '\n' | tr '/+' 'Aa'; }
b64_url_no_pad() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

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

ensure_preset_client_suffix() {
  if [ -z "${PRESET_CLIENT_SUFFIX:-}" ]; then
    PRESET_CLIENT_SUFFIX="$(rand_hex 4)"
    set_env_var PRESET_CLIENT_SUFFIX "$PRESET_CLIENT_SUFFIX"
  fi
}

ensure_subscription_ids() {
  if [ -z "${ALL_NODES_SUB_ID:-}" ]; then
    ALL_NODES_SUB_ID="${DEFAULT_SUB_ID:-$(rand_hex 8)}"
    set_env_var ALL_NODES_SUB_ID "$ALL_NODES_SUB_ID"
  fi
  if [ -z "${DEFAULT_SUB_ID:-}" ]; then
    DEFAULT_SUB_ID="$ALL_NODES_SUB_ID"
    set_env_var DEFAULT_SUB_ID "$DEFAULT_SUB_ID"
  fi
}

ensure_preset_client_suffix
ensure_subscription_ids

new_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
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
  [ -n "$token" ] || { echo "Could not generate API token from 3x-ui CLI." >&2; exit 1; }
  printf '\nXUI_API_TOKEN=%s\n' "$token" >> .env
  printf '%s' "$token"
}

TOKEN="$(api_token)"
CURL_RETRY=(--connect-timeout 3 --max-time 30 --retry 20 --retry-delay 2 --retry-connrefused)

wait_api() {
  local i
  echo "Waiting for 3x-ui API at ${API_BASE}/panel/api/server/status ..."
  for i in $(seq 1 90); do
    if curl -fsS --connect-timeout 2 --max-time 5 -H "Authorization: Bearer ${TOKEN}" \
      "$API_BASE/panel/api/server/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "3x-ui API did not become reachable in time." >&2
  return 1
}

api_get() {
  curl -fsS "${CURL_RETRY[@]}" -H "Authorization: Bearer ${TOKEN}" "$API_BASE$1"
}

api_post_json() {
  local path="$1"
  local file="$2"
  curl -fsS "${CURL_RETRY[@]}" -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary "@${file}" \
    "$API_BASE$path"
}

api_post_form() {
  local path="$1"
  shift
  curl -fsS "${CURL_RETRY[@]}" -X POST -H "Authorization: Bearer ${TOKEN}" "$@" "$API_BASE$path"
}

inbound_exists() {
  local remark="$1"
  api_get "/panel/api/inbounds/list" | jq -e --arg remark "$remark" '.obj[]? | select(.remark == $remark)' >/dev/null
}

delete_inbound_by_remark() {
  local remark="$1"
  local ids id
  ids="$(api_get "/panel/api/inbounds/list" | jq -r --arg remark "$remark" '.obj[]? | select(.remark == $remark) | .id')"
  [ -n "$ids" ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    echo "Deleting managed inbound before re-create: $remark ($id)"
    api_post_form "/panel/api/inbounds/del/${id}" | jq . || true
  done <<< "$ids"
}

recreate_inbound_if_requested() {
  local remark="$1"
  [ "${RECREATE_MANAGED_INBOUNDS:-0}" = "1" ] || return 0
  delete_inbound_by_remark "$remark"
}

add_inbound_if_missing() {
  local remark="$1"
  local file="$2"
  local resp
  if inbound_exists "$remark"; then
    echo "Inbound exists: $remark"
    return 2
  fi
  echo "Adding inbound: $remark"
  resp="$(api_post_json "/panel/api/inbounds/add" "$file")"
  printf '%s\n' "$resp" | jq .
  printf '%s\n' "$resp" | jq -e '.success == true' >/dev/null
}

first_csv() {
  printf '%s' "$1" | awk -F',' '{gsub(/^ +| +$/, "", $1); print $1}'
}

csv_to_json_array() {
  jq -Rn --arg s "$1" '$s | split(",") | map(gsub("^ +| +$"; "")) | map(select(length > 0))'
}

normalize_list_lines() {
  printf '%s' "$1" | tr ',，;； ' '\n' | awk 'NF && !seen[$0]++'
}

domain_node_values() {
  local values
  if [ "$(truthy "${DOMAIN_NODE_MODE:-1}")" = "true" ]; then
    values="${SERVER_ALIASES:-${DOMAIN_NAMES:-${SERVER_ADDR:-}}}"
  else
    values="${SERVER_ADDR:-}"
  fi
  normalize_list_lines "$values"
}

domain_node_count() {
  domain_node_values | awk 'NF { count++ } END { print count + 0 }'
}

domain_node_mode_active() {
  [ "$(truthy "${DOMAIN_NODE_MODE:-1}")" = "true" ] && [ "$(domain_node_count)" -gt 1 ]
}

safe_node_label() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-' | sed 's/^-*//; s/-*$//; s/--*/-/g'
}

build_vless_domain_client_specs() {
  local tmp domain safe email uuid sub_id
  tmp="$(mktemp)"
  sub_id="${ALL_NODES_SUB_ID:-$DEFAULT_SUB_ID}"
  : > "$tmp"

  domain_node_values | while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    safe="$(safe_node_label "$domain")"
    [ -n "$safe" ] || safe="domain"
    email="me-vless-${safe}-${PRESET_CLIENT_SUFFIX}"
    uuid="$(new_uuid)"
    jq -n \
      --arg domain "$domain" \
      --arg email "$email" \
      --arg uuid "$uuid" \
      --arg subId "$sub_id" \
      '{domain:$domain,email:$email,uuid:$uuid,subId:$subId}' >> "$tmp"
  done

  if [ ! -s "$tmp" ]; then
    email="me-vless-reality-${PRESET_CLIENT_SUFFIX}"
    jq -n \
      --arg domain "${SERVER_ADDR:-YOUR_SERVER_IP}" \
      --arg email "$email" \
      --arg uuid "$(new_uuid)" \
      --arg subId "$sub_id" \
      '{domain:$domain,email:$email,uuid:$uuid,subId:$subId}' >> "$tmp"
  fi

  jq -s '.' "$tmp"
  rm -f "$tmp"
}

update_vless_domain_clients() {
  local remark="$1"
  local clients_json="$2"
  local resp payload id file

  resp="$(api_get "/panel/api/inbounds/list")"
  printf '%s\n' "$resp" > runtime/inbounds-before-vless-domain-sync.json

  payload="$(
    jq -c \
      --arg remark "$remark" \
      --arg shareAddr "${SERVER_ADDR:-}" \
      --argjson specs "$clients_json" '
      def obj:
        if type == "string" then (fromjson? // {}) else (. // {}) end;
      def generated_vless:
        (((.email // "") | startswith("me-vless-"))
        or ((.comment // "") | startswith("domain-node:"))
        or ((.comment // "") == "generated by 3xui-selfhost-kit"));
      .obj[]? as $inbound
      | select(($inbound.remark // "") == $remark)
      | ($inbound.settings | obj) as $settings
      | ($settings.clients // []) as $oldClients
      | def old_by_email($email): (($oldClients[]? | select((.email // "") == $email)) // {});
      ($specs | map(
          . as $spec
          | (old_by_email($spec.email)) as $old
          | {
              id: ($old.id // $spec.uuid),
              email: $spec.email,
              flow: ($old.flow // "xtls-rprx-vision"),
              limitIp: ($old.limitIp // 0),
              totalGB: ($old.totalGB // 0),
              expiryTime: ($old.expiryTime // 0),
              enable: ($old.enable // true),
              tgId: ($old.tgId // 0),
              subId: $spec.subId,
              comment: ("domain-node:" + $spec.domain + "; generated by 3xui-selfhost-kit"),
              reset: ($old.reset // 0)
            }
        )) as $domainClients
      | {
          id: $inbound.id,
          enable: ($inbound.enable // true),
          remark: ($inbound.remark // ""),
          listen: ($inbound.listen // ""),
          port: ($inbound.port // 0),
          shareAddr: $shareAddr,
          shareAddrStrategy: (if $shareAddr == "" then "listen" else "custom" end),
          protocol: ($inbound.protocol // "vless"),
          expiryTime: ($inbound.expiryTime // 0),
          total: ($inbound.total // 0),
          trafficReset: ($inbound.trafficReset // "never"),
          settings: ($settings | .clients = ((($oldClients // []) | map(select(generated_vless | not))) + $domainClients)),
          streamSettings: ($inbound.streamSettings | obj),
          sniffing: ($inbound.sniffing | obj)
        }
      ' runtime/inbounds-before-vless-domain-sync.json 2>/dev/null || true
  )"

  [ -n "$payload" ] || return 1
  id="$(printf '%s' "$payload" | jq -r '.id // empty')"
  [ -n "$id" ] || return 1
  file="runtime/vless-domain-clients-update-${id}.json"
  printf '%s\n' "$payload" > "$file"
  echo "Syncing VLESS domain clients for ${remark}"
  api_post_json "/panel/api/inbounds/update/${id}" "$file" | jq .
}

ensure_self_signed_cert() {
  local cert="data/cert/selfsigned.crt"
  local key="data/cert/selfsigned.key"
  if [ -f "$cert" ] && [ -f "$key" ]; then
    return
  fi
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$key" \
    -out "$cert" \
    -days 3650 \
    -subj "/CN=${SERVER_ADDR:-localhost}" >/dev/null 2>&1
  chmod 600 "$key"
}

write_vless_reality() {
  local remark="auto-vless-reality-${REALITY_PORT:-443}"
  local keypair private_key public_key short_id sub_id server_names_json sni file clients_json

  keypair="$(api_get "/panel/api/server/getNewX25519Cert")"
  private_key="$(printf '%s' "$keypair" | jq -r '.obj.privateKey')"
  public_key="$(printf '%s' "$keypair" | jq -r '.obj.publicKey')"
  short_id="$(rand_hex 8)"
  sub_id="${ALL_NODES_SUB_ID:-$DEFAULT_SUB_ID}"
  clients_json="$(build_vless_domain_client_specs)"
  server_names_json="$(csv_to_json_array "${REALITY_SERVER_NAMES:-www.cloudflare.com}")"
  sni="$(first_csv "${REALITY_SERVER_NAMES:-www.cloudflare.com}")"
  file="runtime/vless-reality.json"

  jq -n \
    --arg remark "$remark" \
    --argjson port "${REALITY_PORT:-443}" \
    --arg shareAddr "${SERVER_ADDR:-}" \
    --argjson clients "$clients_json" \
    --arg target "${REALITY_TARGET:-www.cloudflare.com:443}" \
    --argjson serverNames "$server_names_json" \
    --arg privateKey "$private_key" \
    --arg publicKey "$public_key" \
    --arg shortId "$short_id" \
    --arg spiderX "${REALITY_SPIDER_X:-/}" \
    '{
      enable: true,
      remark: $remark,
      listen: "",
      port: $port,
      shareAddr: $shareAddr,
      shareAddrStrategy: (if $shareAddr == "" then "listen" else "custom" end),
      protocol: "vless",
      expiryTime: 0,
      total: 0,
      trafficReset: "never",
      settings: {
        clients: ($clients | map({
          id: .uuid,
          email: .email,
          flow: "xtls-rprx-vision",
          limitIp: 0,
          totalGB: 0,
          expiryTime: 0,
          enable: true,
          tgId: 0,
          subId: .subId,
          comment: ("domain-node:" + .domain + "; generated by 3xui-selfhost-kit"),
          reset: 0
        })),
        decryption: "none",
        encryption: "none",
        fallbacks: []
      },
      streamSettings: {
        network: "tcp",
        tcpSettings: { header: { type: "none" } },
        security: "reality",
        realitySettings: {
          show: false,
          xver: 0,
          target: $target,
          serverNames: $serverNames,
          privateKey: $privateKey,
          minClientVer: "",
          maxClientVer: "",
          maxTimediff: 0,
          shortIds: [$shortId],
          mldsa65Seed: "",
          settings: {
            publicKey: $publicKey,
            fingerprint: "chrome",
            serverName: "",
            spiderX: $spiderX,
            mldsa65Verify: ""
          }
        }
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls", "quic", "fakedns"],
        metadataOnly: false,
        routeOnly: false,
        ipsExcluded: [],
        domainsExcluded: []
      }
    }' > "$file"

  recreate_inbound_if_requested "$remark"
  if [ "${RECREATE_MANAGED_INBOUNDS:-0}" = "1" ] && [ "${REALITY_PORT:-443}" != "443" ]; then
    delete_inbound_by_remark "auto-vless-reality-443"
  fi
  if add_inbound_if_missing "$remark" "$file"; then
    {
      echo "VLESS REALITY"
      jq -r \
        --arg port "${REALITY_PORT:-443}" \
        --arg publicKey "$public_key" \
        --arg sni "$sni" \
        --arg shortId "$short_id" \
        --arg remark "$remark" \
        '.[] | "vless://\(.uuid)@\(.domain):\($port)?type=tcp&security=reality&pbk=\($publicKey)&fp=chrome&sni=\($sni)&sid=\($shortId)&spx=%2F&flow=xtls-rprx-vision#\($remark)@\(.domain)"' \
        <<< "$clients_json"
      echo
    } >> runtime/client-links.txt
  else
    update_vless_domain_clients "$remark" "$clients_json" || true
  fi
}

write_hysteria2_optional() {
  if [ "${ENABLE_HYSTERIA:-0}" != "1" ]; then
    return 0
  fi
  if [ "${ALLOW_SELF_SIGNED_TLS:-0}" != "1" ] && { [ -z "${TLS_CERT_FILE:-}" ] || [ -z "${TLS_KEY_FILE:-}" ]; }; then
    echo "Skipping Hysteria2: set TLS_CERT_FILE/TLS_KEY_FILE or ALLOW_SELF_SIGNED_TLS=1."
    return
  fi

  local cert_file key_file remark auth sub_id file
  if [ -n "${TLS_CERT_FILE:-}" ] && [ -n "${TLS_KEY_FILE:-}" ]; then
    cert_file="$TLS_CERT_FILE"
    key_file="$TLS_KEY_FILE"
  else
    ensure_self_signed_cert
    cert_file="/root/cert/selfsigned.crt"
    key_file="/root/cert/selfsigned.key"
  fi

  remark="auto-hysteria2-${HYSTERIA_PORT:-8443}"
  auth="$(rand_b64 24)"
  sub_id="${ALL_NODES_SUB_ID:-$DEFAULT_SUB_ID}"
  file="runtime/hysteria2.json"

  jq -n \
    --arg remark "$remark" \
    --argjson port "${HYSTERIA_PORT:-8443}" \
    --arg shareAddr "${SERVER_ADDR:-}" \
    --arg auth "$auth" \
    --arg email "me-hysteria2-${PRESET_CLIENT_SUFFIX}" \
    --arg subId "$sub_id" \
    --arg certFile "$cert_file" \
    --arg keyFile "$key_file" \
    --arg sni "${TLS_SERVER_NAME:-${SERVER_ADDR:-localhost}}" \
    '{
      enable: true,
      remark: $remark,
      listen: "",
      port: $port,
      shareAddr: $shareAddr,
      shareAddrStrategy: (if $shareAddr == "" then "listen" else "custom" end),
      protocol: "hysteria",
      expiryTime: 0,
      total: 0,
      trafficReset: "never",
      settings: {
        version: 2,
        clients: [{
          auth: $auth,
          email: $email,
          limitIp: 0,
          totalGB: 0,
          expiryTime: 0,
          enable: true,
          tgId: 0,
          subId: $subId,
          comment: "generated by 3xui-selfhost-kit",
          reset: 0
        }]
      },
      streamSettings: {
        network: "hysteria",
        hysteriaSettings: {
          version: 2,
          udpIdleTimeout: 60,
          masquerade: { type: "", headers: {} }
        },
        security: "tls",
        tlsSettings: {
          serverName: $sni,
          minVersion: "1.2",
          maxVersion: "1.3",
          cipherSuites: "",
          rejectUnknownSni: false,
          disableSystemRoot: false,
          enableSessionResumption: false,
          certificates: [{
            certificateFile: $certFile,
            keyFile: $keyFile,
            oneTimeLoading: false,
            usage: "encipherment",
            buildChain: false
          }],
          alpn: ["h3"],
          echServerKeys: "",
          settings: { fingerprint: "", echConfigList: "", pinnedPeerCertSha256: [], verifyPeerCertByName: "" }
        }
      },
      sniffing: {
        enabled: false,
        destOverride: ["http", "tls", "quic", "fakedns"],
        metadataOnly: false,
        routeOnly: false,
        ipsExcluded: [],
        domainsExcluded: []
      }
    }' > "$file"

  recreate_inbound_if_requested "$remark"
  if add_inbound_if_missing "$remark" "$file"; then
    {
      echo "Hysteria2"
      echo "hysteria2://${auth}@${SERVER_ADDR:-YOUR_SERVER_IP}:${HYSTERIA_PORT:-8443}?security=tls&sni=${TLS_SERVER_NAME:-${SERVER_ADDR:-localhost}}&alpn=h3#${remark}"
      echo
    } >> runtime/client-links.txt
  fi
}

write_trojan_optional() {
  if [ "${ENABLE_TROJAN:-0}" != "1" ]; then
    return 0
  fi
  if [ "${ALLOW_SELF_SIGNED_TLS:-0}" != "1" ] && { [ -z "${TLS_CERT_FILE:-}" ] || [ -z "${TLS_KEY_FILE:-}" ]; }; then
    echo "Skipping Trojan: set TLS_CERT_FILE/TLS_KEY_FILE or ALLOW_SELF_SIGNED_TLS=1."
    return
  fi

  local cert_file key_file remark password sub_id file
  if [ -n "${TLS_CERT_FILE:-}" ] && [ -n "${TLS_KEY_FILE:-}" ]; then
    cert_file="$TLS_CERT_FILE"
    key_file="$TLS_KEY_FILE"
  else
    ensure_self_signed_cert
    cert_file="/root/cert/selfsigned.crt"
    key_file="/root/cert/selfsigned.key"
  fi

  remark="auto-trojan-ws-tls-${TROJAN_PORT:-9443}"
  password="$(rand_b64 24)"
  sub_id="${ALL_NODES_SUB_ID:-$DEFAULT_SUB_ID}"
  file="runtime/trojan-ws-tls.json"

  jq -n \
    --arg remark "$remark" \
    --argjson port "${TROJAN_PORT:-9443}" \
    --arg shareAddr "${SERVER_ADDR:-}" \
    --arg password "$password" \
    --arg email "me-trojan-${PRESET_CLIENT_SUFFIX}" \
    --arg subId "$sub_id" \
    --arg certFile "$cert_file" \
    --arg keyFile "$key_file" \
    --arg sni "${TLS_SERVER_NAME:-${SERVER_ADDR:-localhost}}" \
    '{
      enable: true,
      remark: $remark,
      listen: "",
      port: $port,
      shareAddr: $shareAddr,
      shareAddrStrategy: (if $shareAddr == "" then "listen" else "custom" end),
      protocol: "trojan",
      expiryTime: 0,
      total: 0,
      trafficReset: "never",
      settings: {
        clients: [{
          password: $password,
          email: $email,
          limitIp: 0,
          totalGB: 0,
          expiryTime: 0,
          enable: true,
          tgId: 0,
          subId: $subId,
          comment: "generated by 3xui-selfhost-kit",
          reset: 0
        }],
        fallbacks: []
      },
      streamSettings: {
        network: "ws",
        wsSettings: { acceptProxyProtocol: false, path: "/trojan", host: $sni, headers: {}, heartbeatPeriod: 0 },
        security: "tls",
        tlsSettings: {
          serverName: $sni,
          minVersion: "1.2",
          maxVersion: "1.3",
          cipherSuites: "",
          rejectUnknownSni: false,
          disableSystemRoot: false,
          enableSessionResumption: false,
          certificates: [{
            certificateFile: $certFile,
            keyFile: $keyFile,
            oneTimeLoading: false,
            usage: "encipherment",
            buildChain: false
          }],
          alpn: ["h2", "http/1.1"],
          echServerKeys: "",
          settings: { fingerprint: "chrome", echConfigList: "", pinnedPeerCertSha256: [], verifyPeerCertByName: "" }
        }
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls", "quic", "fakedns"],
        metadataOnly: false,
        routeOnly: false,
        ipsExcluded: [],
        domainsExcluded: []
      }
    }' > "$file"

  recreate_inbound_if_requested "$remark"
  if add_inbound_if_missing "$remark" "$file"; then
    {
      echo "Trojan WS TLS"
      echo "trojan://${password}@${SERVER_ADDR:-YOUR_SERVER_IP}:${TROJAN_PORT:-9443}?type=ws&security=tls&sni=${TLS_SERVER_NAME:-${SERVER_ADDR:-localhost}}&path=%2Ftrojan#${remark}"
      echo
    } >> runtime/client-links.txt
  fi
}

write_shadowsocks_optional() {
  if [ "${ENABLE_SHADOWSOCKS:-0}" != "1" ]; then
    return 0
  fi
  local remark server_password client_password sub_id file ss_userinfo
  remark="auto-shadowsocks-2022-${SHADOWSOCKS_PORT:-8388}"
  server_password="$(rand_b64 32)"
  client_password="$(rand_b64 32)"
  ss_userinfo="$(printf '%s' "2022-blake3-aes-256-gcm:${server_password}:${client_password}" | b64_url_no_pad)"
  sub_id="${ALL_NODES_SUB_ID:-$DEFAULT_SUB_ID}"
  file="runtime/shadowsocks-2022.json"

  jq -n \
    --arg remark "$remark" \
    --argjson port "${SHADOWSOCKS_PORT:-8388}" \
    --arg shareAddr "${SERVER_ADDR:-}" \
    --arg serverPassword "$server_password" \
    --arg clientPassword "$client_password" \
    --arg email "me-shadowsocks-${PRESET_CLIENT_SUFFIX}" \
    --arg subId "$sub_id" \
    '{
      enable: true,
      remark: $remark,
      listen: "",
      port: $port,
      shareAddr: $shareAddr,
      shareAddrStrategy: (if $shareAddr == "" then "listen" else "custom" end),
      protocol: "shadowsocks",
      expiryTime: 0,
      total: 0,
      trafficReset: "never",
      settings: {
        method: "2022-blake3-aes-256-gcm",
        password: $serverPassword,
        network: "tcp,udp",
        clients: [{
          method: "",
          password: $clientPassword,
          email: $email,
          limitIp: 0,
          totalGB: 0,
          expiryTime: 0,
          enable: true,
          tgId: 0,
          subId: $subId,
          comment: "generated by 3xui-selfhost-kit",
          reset: 0
        }],
        ivCheck: false
      },
      streamSettings: {
        network: "tcp",
        tcpSettings: { header: { type: "none" } },
        security: "none"
      },
      sniffing: {
        enabled: true,
        destOverride: ["http", "tls", "quic", "fakedns"],
        metadataOnly: false,
        routeOnly: false,
        ipsExcluded: [],
        domainsExcluded: []
      }
    }' > "$file"

  recreate_inbound_if_requested "$remark"
  if add_inbound_if_missing "$remark" "$file"; then
    {
      echo "Shadowsocks 2022"
      echo "ss://${ss_userinfo}@${SERVER_ADDR:-YOUR_SERVER_IP}:${SHADOWSOCKS_PORT:-8388}#${remark}"
      echo
    } >> runtime/client-links.txt
  fi
}

write_dokodemo_inbound() {
  local listen="$1"
  local port="$2"
  local target_address="$3"
  local target_port="$4"
  local network="${5:-tcp}"
  local follow="${6:-0}"
  local tproxy="${7:-off}"
  local remark file

  [ -n "$port" ] || { echo "Dokodemo listen port is empty." >&2; return 1; }
  [ -n "$target_address" ] || { echo "Dokodemo target address is empty." >&2; return 1; }
  [ -n "$target_port" ] || { echo "Dokodemo target port is empty." >&2; return 1; }

  remark="auto-dokodemo-door-${port}"
  file="runtime/dokodemo-door-${port}.json"

  case "$network" in
    tcp|udp|tcp,udp) ;;
    *) echo "DOKODEMO_NETWORK must be tcp, udp, or tcp,udp." >&2; return 1 ;;
  esac
  case "$follow" in
    y|Y|yes|YES|1|true|TRUE) follow=1 ;;
    *) follow=0 ;;
  esac

  jq -n \
    --arg remark "$remark" \
    --arg listen "$listen" \
    --argjson port "$port" \
    --arg targetAddress "$target_address" \
    --argjson targetPort "$target_port" \
    --arg network "$network" \
    --arg follow "$follow" \
    --arg tproxy "$tproxy" \
    '{
      enable: true,
      remark: $remark,
      listen: $listen,
      port: $port,
      shareAddr: "",
      shareAddrStrategy: "listen",
      protocol: "tunnel",
      expiryTime: 0,
      total: 0,
      trafficReset: "never",
      settings: {
        rewriteAddress: $targetAddress,
        rewritePort: $targetPort,
        allowedNetwork: $network,
        followRedirect: ($follow == "1"),
        portMap: {}
      },
      streamSettings: (
        {security: "none"}
        | if $tproxy != "" and $tproxy != "off" then .sockopt = {tproxy: $tproxy} else . end
      ),
      sniffing: {enabled: false}
    }' > "$file"

  recreate_inbound_if_requested "$remark"
  if [ "${RECREATE_DOKODEMO_INBOUND:-0}" = "1" ]; then
    delete_inbound_by_remark "$remark"
  fi
  if add_inbound_if_missing "$remark" "$file"; then
    {
      echo "dokodemo-door forwarder (3X-UI protocol: tunnel)"
      echo "${listen}:${port} -> ${target_address}:${target_port} (${network})"
      echo
    } >> runtime/client-links.txt
  fi

  ensure_dokodemo_direct_route "$port" "$network"
}

write_dokodemo_optional() {
  local entry port target_address target_port network listen follow tproxy

  if [ -n "${DOKODEMO_FORWARDS:-}" ]; then
    while IFS= read -r entry; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      [ -n "$entry" ] || continue
      IFS=',' read -r port target_address target_port network listen follow tproxy _extra <<< "$entry"
      port="${port:-}"
      target_address="${target_address:-}"
      target_port="${target_port:-}"
      network="${network:-tcp}"
      listen="${listen:-0.0.0.0}"
      follow="${follow:-0}"
      tproxy="${tproxy:-off}"
      write_dokodemo_inbound "$listen" "$port" "$target_address" "$target_port" "$network" "$follow" "$tproxy"
    done < <(printf '%s' "$DOKODEMO_FORWARDS" | tr ';' '\n')
    return 0
  fi

  if [ "${ENABLE_DOKODEMO:-0}" != "1" ]; then
    return 0
  fi
  write_dokodemo_inbound \
    "${DOKODEMO_LISTEN:-127.0.0.1}" \
    "${DOKODEMO_PORT:-}" \
    "${DOKODEMO_TARGET_ADDRESS:-}" \
    "${DOKODEMO_TARGET_PORT:-}" \
    "${DOKODEMO_NETWORK:-tcp}" \
    "${DOKODEMO_FOLLOW_REDIRECT:-0}" \
    "${DOKODEMO_TPROXY:-off}"
}

ensure_dokodemo_direct_route() {
  local port="$1"
  local network="$2"
  local resp template new tmp_out tag
  tag="in-${port}-${network}"
  resp="$(api_post_form "/panel/api/xray/")"
  template="$(printf '%s' "$resp" | jq -r '.obj' | jq '.xraySetting')"
  new="$(jq --arg tag "$tag" '
    def has_tag:
      (.inboundTag // []) as $tags
      | if ($tags | type) == "array" then ($tags | index($tag)) != null else $tags == $tag end;
    .routing = (.routing // {})
    | .routing.rules = (
        [{type:"field", inboundTag:[$tag], outboundTag:"direct"}]
        + ((.routing.rules // []) | map(select(has_tag | not)))
      )
  ' <<<"$template")"

  tmp_out="runtime/xray-with-dokodemo-route.json"
  printf '%s\n' "$new" > "$tmp_out"
  api_post_form "/panel/api/xray/update" \
    --data-urlencode "xraySetting=$(cat "$tmp_out")" \
    --data-urlencode "outboundTestUrl=https://www.google.com/generate_204" | jq .
  echo "Dokodemo-door direct route ensured: ${tag} -> direct"
}

apply_chain_optional() {
  if [ "${CHAIN_ENABLED:-0}" != "1" ]; then
    return 0
  fi
  [ -n "${CHAIN_ADDRESS:-}" ] || { echo "CHAIN_ENABLED=1 but CHAIN_ADDRESS is empty." >&2; return; }
  [ -n "${CHAIN_PORT:-}" ] || { echo "CHAIN_ENABLED=1 but CHAIN_PORT is empty." >&2; return; }

  local resp template new tmp_out outbound tag
  tag="chain-${CHAIN_TYPE:-socks}"
  resp="$(api_post_form "/panel/api/xray/")"
  template="$(printf '%s' "$resp" | jq -r '.obj' | jq '.xraySetting')"

  case "${CHAIN_TYPE:-socks}" in
    socks)
      outbound="$(jq -n --arg tag "$tag" --arg addr "$CHAIN_ADDRESS" --argjson port "$CHAIN_PORT" --arg user "${CHAIN_USER:-}" --arg pass "${CHAIN_PASS:-}" '
        {tag:$tag, protocol:"socks", settings:{servers:[{address:$addr, port:$port}]}}
        | if $user != "" then .settings.servers[0].users=[{user:$user, pass:$pass}] else . end
      ')"
      ;;
    http)
      outbound="$(jq -n --arg tag "$tag" --arg addr "$CHAIN_ADDRESS" --argjson port "$CHAIN_PORT" --arg user "${CHAIN_USER:-}" --arg pass "${CHAIN_PASS:-}" '
        {tag:$tag, protocol:"http", settings:{servers:[{address:$addr, port:$port}]}}
        | if $user != "" then .settings.servers[0].users=[{user:$user, pass:$pass}] else . end
      ')"
      ;;
    trojan)
      [ -n "${CHAIN_PASS:-}" ] || { echo "CHAIN_TYPE=trojan requires CHAIN_PASS." >&2; return; }
      outbound="$(jq -n \
        --arg tag "$tag" \
        --arg addr "$CHAIN_ADDRESS" \
        --argjson port "$CHAIN_PORT" \
        --arg pass "$CHAIN_PASS" \
        --arg sni "${CHAIN_SERVER_NAME:-$CHAIN_ADDRESS}" \
        --arg allowInsecure "${CHAIN_ALLOW_INSECURE:-0}" '
        {
          tag:$tag,
          protocol:"trojan",
          settings:{servers:[{address:$addr, port:$port, password:$pass}]},
          streamSettings:{
            network:"tcp",
            security:"tls",
            tlsSettings:{
              serverName:$sni,
              allowInsecure:($allowInsecure == "1"),
              fingerprint:"chrome"
            }
          }
        }
      ')"
      ;;
    *)
      echo "CHAIN_TYPE currently supports socks, http, or trojan for fully automatic Xray-template wiring." >&2
      return
      ;;
  esac

  new="$(jq --argjson outbound "$outbound" --arg tag "$tag" --arg mode "${CHAIN_MODE:-manual}" '
    .outbounds = ((.outbounds // []) | map(select(.tag != $tag)) + [$outbound])
    | if $mode == "all" then
        .routing = (.routing // {})
        | .routing.rules = ([{type:"field", network:"tcp,udp", outboundTag:$tag}] + ((.routing.rules // []) | map(select(.outboundTag != $tag))))
      else . end
  ' <<<"$template")"

  tmp_out="runtime/xray-with-chain.json"
  printf '%s\n' "$new" > "$tmp_out"
  api_post_form "/panel/api/xray/update" \
    --data-urlencode "xraySetting=$(cat "$tmp_out")" \
    --data-urlencode "outboundTestUrl=https://www.google.com/generate_204" | jq .
  echo "Chain outbound added: $tag"
}

sync_all_subscription_id() {
  [ "$(truthy "${XUI_BUILTIN_ALL_NODES:-1}")" = "true" ] || return 0
  [ -n "${ALL_NODES_SUB_ID:-}" ] || return 0

  local resp updates payload id file domain_mode
  if domain_node_mode_active; then
    domain_mode=true
  else
    domain_mode=false
  fi
  resp="$(api_get "/panel/api/inbounds/list" 2>/dev/null || true)"
  [ -n "$resp" ] || return 0
  printf '%s\n' "$resp" > runtime/inbounds-for-default-subid-sync.json

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
    ' runtime/inbounds-for-default-subid-sync.json 2>/dev/null || true
  )"

  [ -n "$updates" ] || return 0
  while IFS= read -r payload; do
    [ -n "$payload" ] || continue
    id="$(printf '%s' "$payload" | jq -r '.id // empty')"
    [ -n "$id" ] || continue
    file="runtime/inbound-all-nodes-subid-${id}.json"
    printf '%s\n' "$payload" > "$file"
    echo "Syncing all client subId to ALL_NODES_SUB_ID for inbound ${id}"
    api_post_json "/panel/api/inbounds/update/${id}" "$file" | jq . || true
  done <<< "$updates"
}

write_panel_links() {
  local links_file="runtime/panel-all-links.txt"
  local resp emails email encoded client_resp
  : > "$links_file"

  if [ -n "${ALL_NODES_SUB_ID:-}" ]; then
    resp="$(api_get "/panel/api/inbounds/list" 2>/dev/null || true)"
    emails="$(printf '%s' "$resp" | jq -r --arg subId "$ALL_NODES_SUB_ID" '
      def obj:
        if type == "string" then (fromjson? // {}) else (. // {}) end;
      .obj[]?
      | (.settings | obj | .clients // [])[]?
      | select((.subId // "") == $subId)
      | .email // empty
    ' 2>/dev/null | awk 'NF && !seen[$0]++')"
    while IFS= read -r email; do
      [ -n "$email" ] || continue
      encoded="$(jq -rn --arg v "$email" '$v|@uri')"
      client_resp="$(api_get "/panel/api/clients/links/${encoded}" 2>/dev/null || true)"
      printf '%s' "$client_resp" | jq -r '.obj[]?' >> "$links_file" 2>/dev/null || true
    done <<< "$emails"
    if [ -s "$links_file" ]; then
      return 0
    fi
  fi

  resp="$(api_get "/panel/api/inbounds/allLinks" 2>/dev/null || true)"
  if printf '%s' "$resp" | jq -e '.success == true and (.obj | length > 0)' >/dev/null 2>&1; then
    printf '%s' "$resp" | jq -r '.obj[]?' > "$links_file"
    return 0
  fi

  emails="$(api_get "/panel/api/inbounds/list" \
    | jq -r '.obj[]?.settings.clients[]?.email // empty' \
    | awk 'NF && !seen[$0]++')"
  while IFS= read -r email; do
    [ -n "$email" ] || continue
    encoded="$(jq -rn --arg v "$email" '$v|@uri')"
    client_resp="$(api_get "/panel/api/clients/links/${encoded}" 2>/dev/null || true)"
    printf '%s' "$client_resp" | jq -r '.obj[]?' >> "$links_file" 2>/dev/null || true
  done <<< "$emails"
}

: > runtime/client-links.txt
wait_api
write_vless_reality
write_hysteria2_optional
write_trojan_optional
write_shadowsocks_optional
write_dokodemo_optional
apply_chain_optional
sync_all_subscription_id

write_panel_links
chmod 600 runtime/panel-all-links.txt 2>/dev/null || true
if [ ! -s runtime/client-links.txt ] && [ -s runtime/panel-all-links.txt ]; then
  {
    echo "Panel-rendered all-nodes links"
    awk '/^(vless|vmess|trojan|ss|hysteria2):\/\// { print }' runtime/panel-all-links.txt
    echo
  } > runtime/client-links.txt
fi

api_post_form "/panel/api/server/restartXrayService" | jq . || true
chmod 600 runtime/client-links.txt
echo "Client links saved to runtime/client-links.txt"
echo "Panel-rendered links saved to runtime/panel-all-links.txt"
