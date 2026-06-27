#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

[ -f .env ] || { echo ".env not found. Run install.sh first." >&2; exit 1; }

OVERRIDE_KEYS=(
  XUI_CONTAINER PANEL_PORT WEB_BASE_PATH SERVER_ADDR
  REALITY_PORT REALITY_TARGET REALITY_SERVER_NAMES REALITY_SPIDER_X
  ENABLE_HYSTERIA ENABLE_TROJAN ENABLE_SHADOWSOCKS ALLOW_SELF_SIGNED_TLS
  HYSTERIA_PORT TROJAN_PORT SHADOWSOCKS_PORT TLS_CERT_FILE TLS_KEY_FILE TLS_SERVER_NAME
  CHAIN_ENABLED CHAIN_MODE CHAIN_TYPE CHAIN_ADDRESS CHAIN_PORT CHAIN_USER CHAIN_PASS
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

add_inbound_if_missing() {
  local remark="$1"
  local file="$2"
  if inbound_exists "$remark"; then
    echo "Inbound exists: $remark"
    return
  fi
  echo "Adding inbound: $remark"
  api_post_json "/panel/api/inbounds/add" "$file" | jq .
}

first_csv() {
  printf '%s' "$1" | awk -F',' '{gsub(/^ +| +$/, "", $1); print $1}'
}

csv_to_json_array() {
  jq -Rn --arg s "$1" '$s | split(",") | map(gsub("^ +| +$"; "")) | map(select(length > 0))'
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
  local keypair private_key public_key uuid short_id sub_id server_names_json sni file

  keypair="$(api_get "/panel/api/server/getNewX25519Cert")"
  private_key="$(printf '%s' "$keypair" | jq -r '.obj.privateKey')"
  public_key="$(printf '%s' "$keypair" | jq -r '.obj.publicKey')"
  uuid="$(new_uuid)"
  short_id="$(rand_hex 8)"
  sub_id="$(rand_hex 8)"
  server_names_json="$(csv_to_json_array "${REALITY_SERVER_NAMES:-www.cloudflare.com}")"
  sni="$(first_csv "${REALITY_SERVER_NAMES:-www.cloudflare.com}")"
  file="runtime/vless-reality.json"

  jq -n \
    --arg remark "$remark" \
    --argjson port "${REALITY_PORT:-443}" \
    --arg shareAddr "${SERVER_ADDR:-}" \
    --arg uuid "$uuid" \
    --arg subId "$sub_id" \
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
        clients: [{
          id: $uuid,
          email: "me-vless-reality",
          flow: "xtls-rprx-vision",
          limitIp: 0,
          totalGB: 0,
          expiryTime: 0,
          enable: true,
          tgId: 0,
          subId: $subId,
          comment: "generated by 3xui-selfhost-kit",
          reset: 0
        }],
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

  add_inbound_if_missing "$remark" "$file"

  {
    echo "VLESS REALITY"
    echo "vless://${uuid}@${SERVER_ADDR:-YOUR_SERVER_IP}:${REALITY_PORT:-443}?type=tcp&security=reality&pbk=${public_key}&fp=chrome&sni=${sni}&sid=${short_id}&spx=%2F&flow=xtls-rprx-vision#${remark}"
    echo
  } >> runtime/client-links.txt
}

write_hysteria2_optional() {
  [ "${ENABLE_HYSTERIA:-0}" = "1" ] || return
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
  sub_id="$(rand_hex 8)"
  file="runtime/hysteria2.json"

  jq -n \
    --arg remark "$remark" \
    --argjson port "${HYSTERIA_PORT:-8443}" \
    --arg shareAddr "${SERVER_ADDR:-}" \
    --arg auth "$auth" \
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
          email: "me-hysteria2",
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

  add_inbound_if_missing "$remark" "$file"

  {
    echo "Hysteria2"
    echo "hysteria2://${auth}@${SERVER_ADDR:-YOUR_SERVER_IP}:${HYSTERIA_PORT:-8443}?security=tls&sni=${TLS_SERVER_NAME:-${SERVER_ADDR:-localhost}}&alpn=h3#${remark}"
    echo
  } >> runtime/client-links.txt
}

write_trojan_optional() {
  [ "${ENABLE_TROJAN:-0}" = "1" ] || return
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
  sub_id="$(rand_hex 8)"
  file="runtime/trojan-ws-tls.json"

  jq -n \
    --arg remark "$remark" \
    --argjson port "${TROJAN_PORT:-9443}" \
    --arg shareAddr "${SERVER_ADDR:-}" \
    --arg password "$password" \
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
          email: "me-trojan",
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

  add_inbound_if_missing "$remark" "$file"

  {
    echo "Trojan WS TLS"
    echo "trojan://${password}@${SERVER_ADDR:-YOUR_SERVER_IP}:${TROJAN_PORT:-9443}?type=ws&security=tls&sni=${TLS_SERVER_NAME:-${SERVER_ADDR:-localhost}}&path=%2Ftrojan#${remark}"
    echo
  } >> runtime/client-links.txt
}

write_shadowsocks_optional() {
  [ "${ENABLE_SHADOWSOCKS:-0}" = "1" ] || return
  local remark server_password client_password sub_id file
  remark="auto-shadowsocks-2022-${SHADOWSOCKS_PORT:-8388}"
  server_password="$(rand_b64 24)"
  client_password="$(rand_b64 24)"
  sub_id="$(rand_hex 8)"
  file="runtime/shadowsocks-2022.json"

  jq -n \
    --arg remark "$remark" \
    --argjson port "${SHADOWSOCKS_PORT:-8388}" \
    --arg shareAddr "${SERVER_ADDR:-}" \
    --arg serverPassword "$server_password" \
    --arg clientPassword "$client_password" \
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
          email: "me-shadowsocks",
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

  add_inbound_if_missing "$remark" "$file"

  {
    echo "Shadowsocks 2022"
    echo "ss://2022-blake3-aes-256-gcm:${server_password}:${client_password}@${SERVER_ADDR:-YOUR_SERVER_IP}:${SHADOWSOCKS_PORT:-8388}#${remark}"
    echo
  } >> runtime/client-links.txt
}

apply_chain_optional() {
  [ "${CHAIN_ENABLED:-0}" = "1" ] || return
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
    *)
      echo "CHAIN_TYPE currently supports socks or http for fully automatic Xray-template wiring." >&2
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

: > runtime/client-links.txt
wait_api
write_vless_reality
write_hysteria2_optional
write_trojan_optional
write_shadowsocks_optional
apply_chain_optional

api_get "/panel/api/inbounds/allLinks" | jq -r '.obj[]?' > runtime/panel-all-links.txt || true
chmod 600 runtime/panel-all-links.txt 2>/dev/null || true

api_post_form "/panel/api/server/restartXrayService" | jq . || true
chmod 600 runtime/client-links.txt
echo "Client links saved to runtime/client-links.txt"
echo "Panel-rendered links saved to runtime/panel-all-links.txt"
