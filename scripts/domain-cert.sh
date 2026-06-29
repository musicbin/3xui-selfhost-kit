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
SITE_HTTP_PORT="${SITE_HTTP_PORT:-80}"
SITE_HTTPS_PORT="${SITE_HTTPS_PORT:-443}"
AUTO_ENABLE_TROJAN="${AUTO_ENABLE_TROJAN:-1}"
HTTPS_SITE_ENABLE="${HTTPS_SITE_ENABLE:-0}"
HTTPS_HTTP_MODE="${HTTPS_HTTP_MODE:-reject}"

green=$'\033[0;32m'
cyan=$'\033[0;36m'
yellow=$'\033[1;33m'
red=$'\033[0;31m'
plain=$'\033[0m'

log() { printf '[domain-cert] %s\n' "$*"; }

random_port() {
  local hex
  hex="$(openssl rand -hex 2)"
  printf '%d' $((20000 + 0x${hex} % 30000))
}

set_env_var() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  if [ -f .env ]; then
    awk -v k="$key" -v v="$value" '
      BEGIN { done = 0 }
      $0 ~ "^" k "=" { print k "=" v; done = 1; next }
      { print }
      END { if (!done) print k "=" v }
    ' .env > "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" > "$tmp"
  fi
  mv "$tmp" .env
  chmod 600 .env
}

normalize_domains() {
  printf '%s' "$1" | tr ',，;； ' '\n' | awk 'NF && !seen[$0]++ { printf "%s%s", sep, $0; sep="," }'
}

first_domain() {
  printf '%s' "$1" | awk -F',' '{print $1}'
}

prompt() {
  local label="$1"
  local default="${2:-}"
  local answer
  if [ -n "$default" ]; then
    read -r -p "${label} [${default}]: " answer </dev/tty || answer=""
  else
    read -r -p "${label}: " answer </dev/tty || answer=""
  fi
  printf '%s' "${answer:-$default}"
}

yes_no() {
  local label="$1"
  local default="${2:-y}"
  local suffix answer
  if [ "$default" = "y" ]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi
  answer="$(prompt "${label} (${suffix})" "")"
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

write_mask_page() {
  local primary="$1"
  if [ -x ./scripts/mask-site.sh ]; then
    MASK_SITE_BRAND="${MASK_SITE_BRAND:-Hearthline Goods}" ./scripts/mask-site.sh
  else
    mkdir -p site
    printf '<!doctype html><title>%s</title><h1>%s</h1>\n' "${primary:-Service}" "${primary:-Service}" > site/index.html
  fi
}

normalize_uri_path() {
  local path="$1"
  [ -n "$path" ] || return 1
  case "$path" in /*) : ;; *) path="/$path" ;; esac
  case "$path" in */) : ;; *) path="$path/" ;; esac
  printf '%s' "$path"
}

xui_builtin_sub_caddy_block() {
  [ "${XUI_BUILTIN_SUB_ENABLE:-1}" = "1" ] || return 0
  [ -n "${XUI_BUILTIN_SUB_PATH:-}" ] || return 0
  [ -n "${XUI_BUILTIN_JSON_PATH:-}" ] || return 0
  [ -n "${XUI_BUILTIN_CLASH_PATH:-}" ] || return 0

  local sub_path json_path clash_path port
  sub_path="$(normalize_uri_path "$XUI_BUILTIN_SUB_PATH")"
  json_path="$(normalize_uri_path "$XUI_BUILTIN_JSON_PATH")"
  clash_path="$(normalize_uri_path "$XUI_BUILTIN_CLASH_PATH")"
  port="${XUI_BUILTIN_SUB_PORT:-2096}"

  cat <<EOF
	# 3xui builtin subscription start
	@xuiBuiltinSub path ${sub_path%/} ${sub_path%/}/* ${json_path%/} ${json_path%/}/* ${clash_path%/} ${clash_path%/}/*
	handle @xuiBuiltinSub {
		reverse_proxy 127.0.0.1:${port}
	}
	# 3xui builtin subscription end
EOF
}

write_caddyfile() {
  mkdir -p caddy
  local panel_path="${WEB_BASE_PATH:-panel}"
  local xui_sub_block
  panel_path="${panel_path#/}"
  xui_sub_block="$(xui_builtin_sub_caddy_block)"
  if [ "${TLS_CERT_FILE:-}" != "" ] && [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    cat > caddy/Caddyfile <<EOF
:80 {
	redir https://{host}{uri} 308
}

:443 {
	tls /cert/domains/fullchain.pem /cert/domains/privkey.pem
	@panelRoot path /${panel_path}
	redir @panelRoot /${panel_path}/ 308
	@panelPath path /${panel_path}/*
	handle @panelPath {
		reverse_proxy 127.0.0.1:${PANEL_PORT:-2053}
	}
${xui_sub_block}
	handle_path /subconverter/* {
		reverse_proxy 127.0.0.1:${SUBCONVERTER_PORT:-25500}
	}
	handle_path /subconfig-api/* {
		reverse_proxy 127.0.0.1:${SUB_CONFIG_PORT:-27880}
	}
	root * /usr/share/caddy
	file_server
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options nosniff
		Referrer-Policy no-referrer
		X-Frame-Options DENY
	}
}
EOF
  elif [ "${TLS_CERT_FILE:-}" != "" ] && [ "${HTTPS_HTTP_MODE:-reject}" = "reject" ]; then
    cat > caddy/Caddyfile <<'EOF'
:80 {
	respond "HTTPS is required." 403
	header {
		X-Content-Type-Options nosniff
		Referrer-Policy no-referrer
		X-Frame-Options DENY
	}
}
EOF
  else
    cat > caddy/Caddyfile <<'EOF'
:80 {
	handle_path /subconverter/* {
		reverse_proxy 127.0.0.1:${SUBCONVERTER_PORT:-25500}
	}
	handle_path /subconfig-api/* {
		reverse_proxy 127.0.0.1:${SUB_CONFIG_PORT:-27880}
	}
	root * /usr/share/caddy
	file_server
	header {
		X-Content-Type-Options nosniff
		Referrer-Policy no-referrer
		X-Frame-Options DENY
	}
}
EOF
  fi
}

start_mask_site() {
  write_caddyfile
  if [ "${TLS_CERT_FILE:-}" != "" ] && [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    docker compose --profile site stop caddy-site >/dev/null 2>&1 || true
    docker compose --profile https-site up -d --force-recreate caddy-https
  else
    docker compose --profile https-site stop caddy-https >/dev/null 2>&1 || true
    docker compose --profile site up -d --force-recreate caddy-site
  fi
}

acme_bin() {
  if [ -x "$HOME/.acme.sh/acme.sh" ]; then
    printf '%s' "$HOME/.acme.sh/acme.sh"
  elif command -v acme.sh >/dev/null 2>&1; then
    command -v acme.sh
  else
    return 1
  fi
}

install_acme() {
  if acme_bin >/dev/null 2>&1; then
    return
  fi
  local email="${ACME_EMAIL:-}"
  if [ -z "$email" ]; then
    email="admin@$(first_domain "$DOMAIN_NAMES")"
  fi
  log "Installing official acme.sh from upstream."
  curl -fsSL https://get.acme.sh | sh -s email="$email"
}

issue_cert() {
  local domains="$1"
  local primary="$2"
  local acme domain_args=() domain_parts=() d

  install_acme
  acme="$(acme_bin)"

  "$acme" --set-default-ca --server letsencrypt >/dev/null

  IFS=',' read -r -a domain_parts <<< "$domains"
  for d in "${domain_parts[@]}"; do
    [ -n "$d" ] && domain_args+=(-d "$d")
  done

  mkdir -p data/cert/domains
  log "Issuing certificate for: ${domains}"
  if ! "$acme" --issue --webroot "$ROOT_DIR/site" "${domain_args[@]}" --keylength ec-256; then
    log "Certificate issue/renewal was skipped or failed; trying to install the existing certificate."
  fi
  "$acme" --install-cert -d "$primary" --ecc \
    --fullchain-file "$ROOT_DIR/data/cert/domains/fullchain.pem" \
    --key-file "$ROOT_DIR/data/cert/domains/privkey.pem" \
    --reloadcmd "cd $ROOT_DIR && docker restart $XUI_CONTAINER >/dev/null 2>&1 || true"

  set_env_var TLS_CERT_FILE "/root/cert/domains/fullchain.pem"
  set_env_var TLS_KEY_FILE "/root/cert/domains/privkey.pem"
  set_env_var TLS_SERVER_NAME "$primary"
  set_env_var ENABLE_ACME "1"

  TLS_CERT_FILE="/root/cert/domains/fullchain.pem"
  TLS_KEY_FILE="/root/cert/domains/privkey.pem"
  TLS_SERVER_NAME="$primary"
}

configure_firewall_ports() {
  if [ "${CONFIGURE_FIREWALL:-1}" != "1" ]; then
    return
  fi

  local ports=(
    "22/tcp"
    "${SITE_HTTP_PORT:-80}/tcp"
    "${REALITY_PORT:-443}/tcp"
  )

  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    ports+=("${SITE_HTTPS_PORT:-443}/tcp")
  fi
  if [ "${ENABLE_TROJAN:-0}" = "1" ] || [ "${AUTO_ENABLE_TROJAN:-1}" = "1" ]; then
    ports+=("${TROJAN_PORT:-9443}/tcp")
  fi
  if [ "${ENABLE_SHADOWSOCKS:-1}" = "1" ]; then
    ports+=("${SHADOWSOCKS_PORT:-8388}/tcp" "${SHADOWSOCKS_PORT:-8388}/udp")
  fi
  if [ "${ENABLE_HYSTERIA:-0}" = "1" ]; then
    ports+=("${HYSTERIA_PORT:-8443}/udp")
  fi

  if command -v ufw >/dev/null 2>&1; then
    local p
    for p in "${ports[@]}"; do
      ufw allow "$p" >/dev/null 2>&1 || true
    done
    if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
      ufw delete allow "${PANEL_PORT:-2053}/tcp" >/dev/null 2>&1 || true
      ufw deny "${PANEL_PORT:-2053}/tcp" >/dev/null 2>&1 || true
    fi
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
    log "No ufw/firewalld detected; make sure these ports are allowed by your VPS firewall: ${ports[*]}"
  fi
}

web_origin() {
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    if [ "${SITE_HTTPS_PORT:-443}" = "443" ]; then
      printf 'https://%s' "$1"
    else
      printf 'https://%s:%s' "$1" "${SITE_HTTPS_PORT:-443}"
    fi
  else
    if [ "${SITE_HTTP_PORT:-80}" = "80" ]; then
      printf 'http://%s' "$1"
    else
      printf 'http://%s:%s' "$1" "${SITE_HTTP_PORT:-80}"
    fi
  fi
}

secure_panel_for_https() {
  if [ "${HTTPS_SITE_ENABLE:-0}" != "1" ]; then
    return
  fi
  if [ "${AUTO_RANDOMIZE_DEFAULT_PANEL_PORT:-1}" = "1" ] && [ "${PANEL_PORT:-2053}" = "2053" ]; then
    PANEL_PORT="$(random_port)"
    set_env_var PANEL_PORT "$PANEL_PORT"
    log "Changed default panel port 2053 to random local port ${PANEL_PORT}."
  fi
  set_env_var PANEL_LISTEN_IP "127.0.0.1"
  PANEL_LISTEN_IP="127.0.0.1"
  if docker inspect "$XUI_CONTAINER" >/dev/null 2>&1; then
    docker exec "$XUI_CONTAINER" /app/x-ui setting \
      -port "${PANEL_PORT:-2053}" \
      -listenIP "127.0.0.1" \
      -username "${PANEL_USERNAME:-admin}" \
      -password "${PANEL_PASSWORD:-}" \
      -webBasePath "${WEB_BASE_PATH#/}" >/dev/null || true
    docker restart "$XUI_CONTAINER" >/dev/null || true
    sleep 5
  fi
}

main() {
  local domains="${DOMAIN_NAMES:-}"
  local primary email

  if [ "${1:-}" != "--auto" ]; then
    echo "${cyan}域名 / HTTPS 证书自动配置${plain}"
    domains="$(prompt "请输入域名，可多个，用逗号或空格分隔" "$domains")"
  fi

  domains="$(normalize_domains "$domains")"
  if [ -z "$domains" ]; then
    echo "${yellow}未配置域名，已跳过。${plain}"
    return 0
  fi

  primary="$(first_domain "$domains")"
  email="${ACME_EMAIL:-admin@${primary}}"

  set_env_var DOMAIN_NAMES "$domains"
  set_env_var TLS_SERVER_NAME "$primary"
  if [ "${USE_DOMAIN_FOR_LINKS:-1}" = "1" ]; then
    set_env_var SERVER_ADDR "$primary"
  fi
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && [ "${REALITY_PORT:-443}" = "443" ]; then
    log "HTTPS site needs 443, moving VLESS Reality to 8443."
    set_env_var REALITY_PORT "8443"
    REALITY_PORT="8443"
  fi

  if [ "${1:-}" != "--auto" ]; then
    email="$(prompt "ACME 续期通知邮箱" "$email")"
  fi
  set_env_var ACME_EMAIL "$email"

  write_mask_page "$primary"

  if [ "${ENABLE_ACME:-1}" = "1" ]; then
    issue_cert "$domains" "$primary"
  fi

  if [ "$AUTO_ENABLE_TROJAN" = "1" ]; then
    set_env_var ENABLE_TROJAN "1"
    ENABLE_TROJAN="1"
  fi

  configure_firewall_ports
  secure_panel_for_https

  if [ "${APPLY_AFTER_DOMAIN:-1}" = "1" ] && docker inspect "$XUI_CONTAINER" >/dev/null 2>&1; then
    ENABLE_TROJAN="${ENABLE_TROJAN:-0}" ./scripts/apply-presets.sh || true
  fi

  start_mask_site

  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && [ -x ./scripts/xui-builtin-subscription.sh ]; then
    ./scripts/xui-builtin-subscription.sh || true
  fi

  echo
  echo "${green}域名配置完成:${plain}"
  echo "  域名: ${domains}"
  echo "  主域名: ${primary}"
  echo "  Web入口: $(web_origin "$primary")/"
  echo "  订阅转换: $(web_origin "$primary")/sub/"
  if [ -n "${XUI_BUILTIN_SUB_PATH:-}" ]; then
    echo "  3X-UI内置订阅: $(web_origin "$primary")${XUI_BUILTIN_SUB_PATH#/}"
  fi
  echo "  HTTP模式: ${HTTPS_HTTP_MODE:-reject}"
  echo "  证书: ${ROOT_DIR}/data/cert/domains/fullchain.pem"
  echo "  私钥: ${ROOT_DIR}/data/cert/domains/privkey.pem"
  echo "  自动续期: acme.sh cron"
}

main "$@"
