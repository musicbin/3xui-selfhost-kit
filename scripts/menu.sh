#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  TARGET="$(readlink "$SOURCE")"
  if [[ "$TARGET" == /* ]]; then
    SOURCE="$TARGET"
  else
    SOURCE="$DIR/$TARGET"
  fi
done
ROOT_DIR="$(cd "$(dirname "$SOURCE")/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

XUI_CONTAINER="${XUI_CONTAINER:-3xui}"
PANEL_PORT="${PANEL_PORT:-2053}"
PANEL_LISTEN_IP="${PANEL_LISTEN_IP:-127.0.0.1}"
WEB_BASE_PATH="${WEB_BASE_PATH:-panel}"
SERVER_ADDR="${SERVER_ADDR:-your-server}"
REALITY_PORT="${REALITY_PORT:-443}"
REALITY_TARGET="${REALITY_TARGET:-www.cloudflare.com:443}"
REALITY_SERVER_NAMES="${REALITY_SERVER_NAMES:-www.cloudflare.com,cloudflare.com}"
AUTOSTART_SERVICE="${AUTOSTART_SERVICE:-3xui-kit.service}"
DOMAIN_NAMES="${DOMAIN_NAMES:-}"
TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"
TLS_SERVER_NAME="${TLS_SERVER_NAME:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
ENABLE_SUBCONVERTER="${ENABLE_SUBCONVERTER:-1}"
SUBSCRIPTION_TOKEN="${SUBSCRIPTION_TOKEN:-}"
SUB_CONFIG_ADMIN_TOKEN="${SUB_CONFIG_ADMIN_TOKEN:-}"
SITE_HTTP_PORT="${SITE_HTTP_PORT:-80}"
SITE_HTTPS_PORT="${SITE_HTTPS_PORT:-443}"
HTTPS_SITE_ENABLE="${HTTPS_SITE_ENABLE:-0}"
HTTPS_HTTP_MODE="${HTTPS_HTTP_MODE:-reject}"
XUI_BUILTIN_SUB_LISTEN="${XUI_BUILTIN_SUB_LISTEN:-127.0.0.1}"
XUI_BUILTIN_SUB_PORT="${XUI_BUILTIN_SUB_PORT:-2096}"
XUI_BUILTIN_SUB_PATH="${XUI_BUILTIN_SUB_PATH:-}"
XUI_BUILTIN_JSON_PATH="${XUI_BUILTIN_JSON_PATH:-}"
XUI_BUILTIN_CLASH_PATH="${XUI_BUILTIN_CLASH_PATH:-}"
SERVER_ALIASES="${SERVER_ALIASES:-}"

green=$'\033[0;32m'
cyan=$'\033[0;36m'
yellow=$'\033[1;33m'
blue=$'\033[0;34m'
red=$'\033[0;31m'
plain=$'\033[0m'

line() {
  printf '%s\n' "${green}--------------------------------------------------------------------------------${plain}"
}

warn_line() {
  printf '%s\n' "${red}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${plain}"
}

pause() {
  echo
  read -r -p "按回车键返回菜单..." _ </dev/tty || true
}

need_root_hint() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "${yellow}提示：部分 Docker/面板操作需要 sudo。建议使用：sudo x-ui${plain}"
  fi
}

os_name() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    printf '%s' "${PRETTY_NAME:-Linux}"
  else
    uname -s
  fi
}

virt_name() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    systemd-detect-virt 2>/dev/null || printf 'unknown'
  else
    printf 'unknown'
  fi
}

bbr_name() {
  sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown'
}

local_ips() {
  hostname -I 2>/dev/null | awk '{$1=$1; print}' || true
}

container_state() {
  docker inspect -f '{{.State.Status}}' "$XUI_CONTAINER" 2>/dev/null || printf 'not-found'
}

container_health() {
  local state
  state="$(container_state)"
  case "$state" in
    running) printf '%s已运行%s' "$cyan" "$plain" ;;
    exited|dead) printf '%s未运行%s' "$red" "$plain" ;;
    not-found) printf '%s未安装/未找到%s' "$yellow" "$plain" ;;
    *) printf '%s%s%s' "$yellow" "$state" "$plain" ;;
  esac
}

docker_restart_policy() {
  docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$XUI_CONTAINER" 2>/dev/null || printf 'unknown'
}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files >/dev/null 2>&1
}

autostart_status() {
  local policy enabled active
  policy="$(docker_restart_policy)"
  if ! systemd_available; then
    printf '%s无 systemd%s，Docker重启策略: %s' "$yellow" "$plain" "$policy"
    return
  fi

  enabled="$(systemctl is-enabled "$AUTOSTART_SERVICE" 2>/dev/null || true)"
  active="$(systemctl is-active "$AUTOSTART_SERVICE" 2>/dev/null || true)"
  case "$enabled" in
    enabled)
      printf '%ssystemd已启用%s (%s)，Docker重启策略: %s' "$cyan" "$plain" "$active" "$policy"
      ;;
    disabled)
      printf '%ssystemd未启用%s，Docker重启策略: %s' "$yellow" "$plain" "$policy"
      ;;
    *)
      printf '%ssystemd未安装服务%s，Docker重启策略: %s' "$yellow" "$plain" "$policy"
      ;;
  esac
}

panel_url() {
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    printf '%s/%s/' "$(web_origin)" "${WEB_BASE_PATH#/}"
  else
    printf 'http://%s:%s/%s/' "$SERVER_ADDR" "$PANEL_PORT" "${WEB_BASE_PATH#/}"
  fi
}

tunnel_url() {
  printf 'http://127.0.0.1:%s/%s/' "$PANEL_PORT" "${WEB_BASE_PATH#/}"
}

tunnel_cmd() {
  printf 'ssh -L %s:127.0.0.1:%s root@%s' "$PANEL_PORT" "$PANEL_PORT" "$SERVER_ADDR"
}

web_origin() {
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    if [ "${SITE_HTTPS_PORT:-443}" = "443" ]; then
      printf 'https://%s' "$SERVER_ADDR"
    else
      printf 'https://%s:%s' "$SERVER_ADDR" "$SITE_HTTPS_PORT"
    fi
  else
    if [ "${SITE_HTTP_PORT:-80}" = "80" ]; then
      printf 'http://%s' "$SERVER_ADDR"
    else
      printf 'http://%s:%s' "$SERVER_ADDR" "$SITE_HTTP_PORT"
    fi
  fi
}

refresh_env() {
  if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
  fi
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

write_runtime_summary() {
  mkdir -p runtime
  chmod 700 runtime
  cat > runtime/install-summary.txt <<EOF
3x-ui self-host kit installed.

1) Install dir
  ${ROOT_DIR}

2) Visual panel
  Panel bind: ${PANEL_LISTEN_IP}:${PANEL_PORT}
  Panel path: /${WEB_BASE_PATH}/
  Username:   ${PANEL_USERNAME:-unknown}
  Password:   ${PANEL_PASSWORD:-unknown}

3) How to open the panel
  Panel public display URL:
    $(panel_url)

  Recommended SSH tunnel when Panel bind is 127.0.0.1:
    $(tunnel_cmd)

  Tunnel browser URL:
    $(tunnel_url)

4) Client config links
  ${ROOT_DIR}/runtime/client-links.txt
  ${ROOT_DIR}/runtime/panel-all-links.txt

5) Default protocol
  VLESS + TCP/Raw + XTLS Vision + REALITY
  Port: ${REALITY_PORT}
  Reality target: ${REALITY_TARGET}
  Reality server names: ${REALITY_SERVER_NAMES}

6) Autostart
  Docker container restart policy: $(docker_restart_policy)
  systemd service: ${AUTOSTART_SERVICE}
  Check status:
    systemctl status ${AUTOSTART_SERVICE} --no-pager

7) Domains and HTTPS
  Domains: ${DOMAIN_NAMES:-not configured}
  TLS cert: ${TLS_CERT_FILE:-not configured}
  TLS key: ${TLS_KEY_FILE:-not configured}
  HTTPS site: ${HTTPS_SITE_ENABLE:-0}
  HTTP mode: ${HTTPS_HTTP_MODE:-reject}

8) Subscription converter
  Web UI: $(web_origin)/sub/
  Local node subscription: $(web_origin)/subscriptions/${SUBSCRIPTION_TOKEN:-token}.txt
  Base64 subscription: $(web_origin)/subscriptions/${SUBSCRIPTION_TOKEN:-token}.b64
  Clash 3.5.yaml subscription: $(web_origin)/subconfig-api/render/clash?token=${SUBSCRIPTION_TOKEN:-token}
  Default local conversion config: $(web_origin)/sub/config/3.5.yaml
  Rules editor token: ${SUB_CONFIG_ADMIN_TOKEN:-not generated yet}
  Note: If HTTPS_SITE_ENABLE=0 and HTTPS_HTTP_MODE=reject, public /sub/ is intentionally blocked after certificate setup.

9) 3X-UI built-in subscription
  Listen: ${XUI_BUILTIN_SUB_LISTEN:-127.0.0.1}:${XUI_BUILTIN_SUB_PORT:-2096}
  Subscription prefix: $(web_origin)${XUI_BUILTIN_SUB_PATH:-/xui-sub/}
  Actual links require a subId. With XUI_BUILTIN_ALL_NODES=1, every client is synced to ALL_NODES_SUB_ID and the generated all-nodes link contains all current nodes:
    ${ROOT_DIR}/runtime/xui-builtin-sub-links.txt
  JSON URI: $(web_origin)${XUI_BUILTIN_JSON_PATH:-/xui-json/}
  Clash URI: $(web_origin)${XUI_BUILTIN_CLASH_PATH:-/xui-clash/}
EOF
  chmod 600 runtime/install-summary.txt
}

show_header() {
  clear 2>/dev/null || true
  warn_line
  echo "${cyan}3x-ui 自用部署管理脚本${plain}    快捷方式：${yellow}x-ui${plain}"
  warn_line
  echo "${green} 1. 一键安装 / 启动 3x-ui 官方镜像${plain}"
  echo "${green} 2. 删除卸载 3x-ui${plain}"
  line
  echo "${green} 3. 查看面板账号、路径、客户端配置链接${plain}"
  echo "${green} 4. 修改面板设置【用户名密码、登录端口、根路径、监听IP】${plain}"
  echo "${green} 5. 套用协议预设【VLESS Reality、Hysteria2、Trojan、SS、链式代理】${plain}"
  echo "${green} 6. 启动、停止、重启 3x-ui${plain}"
  echo "${green} 7. 安全更新官方 3x-ui 镜像【后台执行并自动修复配置】${plain}"
  echo "${green} 8. 备份数据库和 .env 配置${plain}"
  echo "${green} 9. 查看 3x-ui 日志${plain}"
  echo "${green}10. 管理 Acme 申请域名证书【支持多域名 / 自动续期】${plain}"
  echo "${green}11. 启动 / 更新 80 端口伪装静态站点${plain}"
  echo "${green}12. 刷新IP配置及参数显示 / 节点链接${plain}"
  echo "${green}13. 开机自启动设置【启用/禁用/查看】${plain}"
  echo "${green}14. 显示使用说明和安全建议${plain}"
  echo "${green}15. 订阅转换 Web 界面 / 3X-UI内置HTTPS订阅${plain}"
  echo "${green}16. 官方更新/系统更新后自检并恢复配置${plain}"
  echo "${green}17. 检查域名 A/AAAA、IPv4/IPv6、端口监听${plain}"
  echo "${green}18. 刷新全部入站订阅链接【使用 3.5.yaml 规则】${plain}"
  line
  echo "${green} 0. 退出脚本${plain}"
  warn_line
}

show_status() {
  echo "${green}VPS状态如下:${plain}"
  echo "系统: ${cyan}$(os_name)${plain}  内核: ${cyan}$(uname -r)${plain}  处理器: ${cyan}$(uname -m)${plain}  虚拟化: ${cyan}$(virt_name)${plain}  BBR算法: ${cyan}$(bbr_name)${plain}"
  echo "本地IP地址: ${blue}$(local_ips)${plain}"
  echo "服务器地址: ${blue}${SERVER_ADDR}${plain}"
  line
  echo "3x-ui容器状态: $(container_health)"
  echo "开机自启动: $(autostart_status)"
  echo "面板监听: ${cyan}${PANEL_LISTEN_IP}:${PANEL_PORT}${plain}"
  echo "面板路径: ${cyan}/${WEB_BASE_PATH}/ ${plain}"
  echo "面板公网地址: ${blue}$(panel_url)${plain}"
  if [ "$PANEL_LISTEN_IP" = "127.0.0.1" ] || [ "$PANEL_LISTEN_IP" = "localhost" ]; then
    echo "SSH隧道: ${yellow}$(tunnel_cmd)${plain}"
    echo "隧道访问地址: ${blue}$(tunnel_url)${plain}"
  fi
  line
  echo "x-ui登录信息如下:"
  echo "登录用户名: ${blue}${PANEL_USERNAME:-unknown}${plain}"
  echo "登录密码: ${blue}${PANEL_PASSWORD:-unknown}${plain}"
  echo "登录端口: ${blue}${PANEL_PORT}${plain}"
  echo "根路径: ${blue}/${WEB_BASE_PATH}/ ${plain}"
  line
  echo "默认协议: ${cyan}VLESS + TCP/Raw + XTLS Vision + REALITY${plain}"
  echo "REALITY端口: ${blue}${REALITY_PORT}${plain}"
  echo "REALITY目标: ${blue}${REALITY_TARGET}${plain}"
  echo "客户端链接: ${blue}${ROOT_DIR}/runtime/client-links.txt${plain}"
  echo "面板导出链接: ${blue}${ROOT_DIR}/runtime/panel-all-links.txt${plain}"
  echo "绑定域名: ${blue}${DOMAIN_NAMES:-未配置}${plain}"
  echo "订阅域名别名: ${blue}${SERVER_ALIASES:-${DOMAIN_NAMES:-未配置}}${plain}"
  echo "TLS证书: ${blue}${TLS_CERT_FILE:-未配置}${plain}"
  echo "HTTPS站点: ${blue}${HTTPS_SITE_ENABLE:-0}${plain}  HTTP模式: ${blue}${HTTPS_HTTP_MODE:-reject}${plain}"
  echo "订阅转换: ${blue}$(web_origin)/sub/ ${plain}"
  echo "规则配置: ${blue}$(web_origin)/sub/config/3.5.yaml${plain}"
  echo "规则编辑Token: ${blue}${SUB_CONFIG_ADMIN_TOKEN:-未生成}${plain}"
  echo "3X-UI内置订阅前缀: ${blue}$(web_origin)${XUI_BUILTIN_SUB_PATH:-/xui-sub/}${plain}  监听: ${cyan}${XUI_BUILTIN_SUB_LISTEN}:${XUI_BUILTIN_SUB_PORT}${plain}"
  echo "说明: ${yellow}内置订阅必须追加 subId；XUI_BUILTIN_ALL_NODES=1 时所有客户端共享 ALL_NODES_SUB_ID，all-nodes 链接包含全部当前节点。直接打开前缀会跳转到 /sub/。${plain}"
  if [ -s runtime/xui-builtin-sub-links.txt ]; then
    echo "3X-UI内置订阅客户端链接:"
    sed 's/^/  /' runtime/xui-builtin-sub-links.txt | head -30
  else
    echo "3X-UI内置订阅客户端链接: ${yellow}${ROOT_DIR}/runtime/xui-builtin-sub-links.txt 尚未生成，运行菜单 15 修复。${plain}"
  fi
}

show_menu() {
  show_header
  need_root_hint
  show_status
  warn_line
}

install_or_start() {
  if [ -z "${PANEL_USERNAME:-}" ]; then
    PANEL_USERNAME="admin"
    set_env_var PANEL_USERNAME "$PANEL_USERNAME"
  fi
  if [ -z "${PANEL_PASSWORD:-}" ]; then
    PANEL_PASSWORD="$(openssl rand -base64 24 | tr -d '\n' | tr '/+' 'Aa')"
    set_env_var PANEL_PASSWORD "$PANEL_PASSWORD"
  fi
  docker compose pull 3xui
  docker compose up -d 3xui
  docker exec "$XUI_CONTAINER" /app/x-ui setting \
    -port "$PANEL_PORT" \
    -listenIP "$PANEL_LISTEN_IP" \
    -username "$PANEL_USERNAME" \
    -password "$PANEL_PASSWORD" \
    -webBasePath "${WEB_BASE_PATH#/}" >/dev/null || true
  docker restart "$XUI_CONTAINER" >/dev/null || true
  write_runtime_summary
  echo "${cyan}3x-ui 已安装/启动。${plain}"
}

uninstall_xui() {
  echo "${yellow}将停止并删除容器。默认保留 data/ 数据。${plain}"
  read -r -p "确认卸载容器？输入 y 确认: " yn </dev/tty || yn=""
  [ "$yn" = "y" ] || return 0
  docker compose down
  read -r -p "是否同时删除 data/ runtime/ backups/？输入 DELETE 确认: " wipe </dev/tty || wipe=""
  if [ "$wipe" = "DELETE" ]; then
    rm -rf data runtime backups
    echo "${red}数据已删除。${plain}"
  else
    echo "${cyan}容器已删除，数据已保留。${plain}"
  fi
}

show_links() {
  ./scripts/manage.sh links
}

change_panel_settings() {
  local new_user new_pass new_port new_path new_listen
  echo "${cyan}留空表示保留当前值。${plain}"
  read -r -p "用户名 [${PANEL_USERNAME:-admin}]: " new_user </dev/tty || true
  read -r -p "密码 [保留当前密码]: " new_pass </dev/tty || true
  read -r -p "面板端口 [${PANEL_PORT}]: " new_port </dev/tty || true
  read -r -p "根路径，不带 / [${WEB_BASE_PATH#/}]: " new_path </dev/tty || true
  read -r -p "监听IP，127.0.0.1最安全 [${PANEL_LISTEN_IP}]: " new_listen </dev/tty || true

  new_user="${new_user:-${PANEL_USERNAME:-admin}}"
  new_pass="${new_pass:-${PANEL_PASSWORD:-}}"
  new_port="${new_port:-$PANEL_PORT}"
  new_path="${new_path:-${WEB_BASE_PATH#/}}"
  new_listen="${new_listen:-$PANEL_LISTEN_IP}"

  set_env_var PANEL_USERNAME "$new_user"
  [ -n "$new_pass" ] && set_env_var PANEL_PASSWORD "$new_pass"
  set_env_var PANEL_PORT "$new_port"
  set_env_var WEB_BASE_PATH "${new_path#/}"
  set_env_var PANEL_LISTEN_IP "$new_listen"
  refresh_env

  docker exec "$XUI_CONTAINER" /app/x-ui setting \
    -port "$PANEL_PORT" \
    -listenIP "$PANEL_LISTEN_IP" \
    -username "$PANEL_USERNAME" \
    -password "${PANEL_PASSWORD:-}" \
    -webBasePath "${WEB_BASE_PATH#/}" >/dev/null
  docker restart "$XUI_CONTAINER" >/dev/null
  write_runtime_summary
  echo "${cyan}面板设置已更新。${plain}"
}

protocol_presets_menu() {
  echo "${cyan}协议预设${plain}"
  echo "1. 只套用默认 VLESS Reality"
  echo "2. 启用 Hysteria2"
  echo "3. 启用 Trojan WS TLS"
  echo "4. 启用 Shadowsocks 2022"
  echo "5. 配置链式代理出口【socks/http/trojan】"
  echo "6. 添加 dokodemo-door 转发入站【3X-UI 中显示为 tunnel】"
  echo "7. 禁用不安全入站协议【vmess/http/mixed/mtproto/tun】"
  echo "0. 返回"
  read -r -p "请选择: " c </dev/tty || c=""
  case "$c" in
    1) ./scripts/apply-presets.sh ;;
    2) ENABLE_HYSTERIA=1 ./scripts/apply-presets.sh ;;
    3) ENABLE_TROJAN=1 ./scripts/apply-presets.sh ;;
    4) ENABLE_SHADOWSOCKS=1 ./scripts/apply-presets.sh ;;
    5)
      read -r -p "上游类型 socks/http/trojan [socks]: " ct </dev/tty || ct=""
      read -r -p "上游地址: " ca </dev/tty || ca=""
      read -r -p "上游端口: " cp </dev/tty || cp=""
      read -r -p "路由模式 manual/all [manual]: " cm </dev/tty || cm=""
      if [ "${ct:-socks}" = "trojan" ]; then
        read -r -p "Trojan密码: " cpass </dev/tty || cpass=""
        read -r -p "Trojan SNI/域名 [${ca}]: " csni </dev/tty || csni=""
        CHAIN_ENABLED=1 CHAIN_TYPE=trojan CHAIN_ADDRESS="$ca" CHAIN_PORT="$cp" CHAIN_PASS="$cpass" CHAIN_SERVER_NAME="${csni:-$ca}" CHAIN_MODE="${cm:-manual}" ./scripts/apply-presets.sh
      else
        CHAIN_ENABLED=1 CHAIN_TYPE="${ct:-socks}" CHAIN_ADDRESS="$ca" CHAIN_PORT="$cp" CHAIN_MODE="${cm:-manual}" ./scripts/apply-presets.sh
      fi
      ;;
    6)
      local dl dp da dt dn df
      read -r -p "监听IP [127.0.0.1，公网转发填0.0.0.0]: " dl </dev/tty || dl=""
      read -r -p "监听端口 [18080]: " dp </dev/tty || dp=""
      read -r -p "目标地址 [127.0.0.1]: " da </dev/tty || da=""
      read -r -p "目标端口 [80]: " dt </dev/tty || dt=""
      read -r -p "网络 tcp/udp/tcp,udp [tcp]: " dn </dev/tty || dn=""
      read -r -p "是否 followRedirect 透明转发？[y/N]: " df </dev/tty || df=""
      ENABLE_DOKODEMO=1 \
        DOKODEMO_LISTEN="${dl:-127.0.0.1}" \
        DOKODEMO_PORT="${dp:-18080}" \
        DOKODEMO_TARGET_ADDRESS="${da:-127.0.0.1}" \
        DOKODEMO_TARGET_PORT="${dt:-80}" \
        DOKODEMO_NETWORK="${dn:-tcp}" \
        DOKODEMO_FOLLOW_REDIRECT="$([ "${df:-n}" = "y" ] && printf 1 || printf 0)" \
        ./scripts/apply-presets.sh
      ;;
    7)
      PROTOCOL_GUARD_ACTION=disable ./scripts/protocol-guard.sh
      ;;
    *) return 0 ;;
  esac
}

domain_cert_menu() {
  local domains email use_domain enable_trojan https_site
  echo "${cyan}Acme 域名证书 / HTTPS / Trojan TLS 自动配置${plain}"
  echo "当前域名: ${DOMAIN_NAMES:-未配置}"
  echo "当前证书: ${TLS_CERT_FILE:-未配置}"
  echo
  read -r -p "请输入域名，可多个，用逗号或空格分隔 [${DOMAIN_NAMES:-}]: " domains </dev/tty || domains=""
  domains="${domains:-${DOMAIN_NAMES:-}}"
  if [ -z "$domains" ]; then
    echo "${yellow}未输入域名。${plain}"
    return 0
  fi
  read -r -p "ACME邮箱 [${ACME_EMAIL:-admin@${domains%%,*}}]: " email </dev/tty || email=""
  read -r -p "是否用第一个域名作为节点/面板显示地址？[Y/n]: " use_domain </dev/tty || use_domain=""
  read -r -p "证书成功后是否自动启用 Trojan TLS 节点？[Y/n]: " enable_trojan </dev/tty || enable_trojan=""
  read -r -p "是否启用 443 HTTPS 伪装站点？会把 Reality 默认端口从443改到8443 [Y/n]: " https_site </dev/tty || https_site=""

  set_env_var DOMAIN_NAMES "$domains"
  set_env_var ACME_EMAIL "${email:-${ACME_EMAIL:-admin@${domains%%,*}}}"
  set_env_var ENABLE_ACME "1"
  case "$use_domain" in n|N|no|NO|No) set_env_var USE_DOMAIN_FOR_LINKS "0" ;; *) set_env_var USE_DOMAIN_FOR_LINKS "1" ;; esac
  case "$enable_trojan" in n|N|no|NO|No) set_env_var AUTO_ENABLE_TROJAN "0" ;; *) set_env_var AUTO_ENABLE_TROJAN "1"; set_env_var ENABLE_TROJAN "1" ;; esac
  case "$https_site" in n|N|no|NO|No) set_env_var HTTPS_SITE_ENABLE "0"; set_env_var HTTPS_HTTP_MODE "reject" ;; *) set_env_var HTTPS_SITE_ENABLE "1"; set_env_var HTTPS_HTTP_MODE "redirect" ;; esac

  refresh_env
  ./scripts/domain-cert.sh
  refresh_env
  write_runtime_summary
}

service_menu() {
  echo "1. 启动"
  echo "2. 停止"
  echo "3. 重启"
  echo "0. 返回"
  read -r -p "请选择: " c </dev/tty || c=""
  case "$c" in
    1) docker compose up -d 3xui ;;
    2) docker compose stop 3xui ;;
    3) docker compose restart 3xui ;;
    *) return 0 ;;
  esac
}

require_root_for_autostart() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  echo "${red}自启动服务写入 /etc/systemd/system，需要 root 权限。请使用：sudo x-ui${plain}"
  return 1
}

install_autostart_service() {
  if ! systemd_available; then
    echo "${yellow}当前系统没有可用 systemd，已保留 Docker restart policy: $(docker_restart_policy)${plain}"
    return 1
  fi
  require_root_for_autostart || return 1

  local docker_bin
  docker_bin="$(command -v docker || true)"
  if [ -z "$docker_bin" ]; then
    echo "${red}未找到 docker 命令，无法创建自启动服务。${plain}"
    return 1
  fi

  cat > "/etc/systemd/system/${AUTOSTART_SERVICE}" <<EOF
[Unit]
Description=3x-ui selfhost kit
Wants=network-online.target docker.service
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${ROOT_DIR}
ExecStart=/usr/bin/env bash ${ROOT_DIR}/scripts/start-services.sh
ExecStop=${docker_bin} compose stop 3xui subconverter subconfig-api caddy-site caddy-https
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$AUTOSTART_SERVICE"
  write_runtime_summary
  echo "${cyan}已启用开机自启动：${AUTOSTART_SERVICE}${plain}"
}

disable_autostart_service() {
  if ! systemd_available; then
    echo "${yellow}当前系统没有可用 systemd。${plain}"
    return 1
  fi
  require_root_for_autostart || return 1
  systemctl disable "$AUTOSTART_SERVICE" >/dev/null 2>&1 || true
  echo "${yellow}已禁用 systemd 自启动服务。Docker restart policy 仍按 compose.yaml 保留。${plain}"
}

show_autostart_detail() {
  echo "当前自启动状态: $(autostart_status)"
  if systemd_available; then
    echo
    systemctl status "$AUTOSTART_SERVICE" --no-pager || true
  fi
}

autostart_menu() {
  echo "${cyan}开机自启动设置${plain}"
  echo "当前: $(autostart_status)"
  echo
  echo "1. 启用 / 修复 systemd 自启动"
  echo "2. 禁用 systemd 自启动"
  echo "3. 查看自启动详情"
  echo "0. 返回"
  read -r -p "请选择: " c </dev/tty || c=""
  case "$c" in
    1) install_autostart_service ;;
    2) disable_autostart_service ;;
    3) show_autostart_detail ;;
    *) return 0 ;;
  esac
}

subscription_menu() {
  echo "${cyan}订阅转换 Web 界面 / 3X-UI内置HTTPS订阅${plain}"
  if [ "${ENABLE_SUBCONVERTER:-1}" != "1" ]; then
    echo "${yellow}ENABLE_SUBCONVERTER=0，当前未启用。${plain}"
    read -r -p "是否启用订阅转换？[Y/n]: " yn </dev/tty || yn=""
    case "$yn" in n|N|no|NO|No) return 0 ;; esac
    set_env_var ENABLE_SUBCONVERTER "1"
  fi
  ./scripts/subscription.sh
  if [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    ./scripts/xui-builtin-subscription.sh || true
  else
    echo "${yellow}HTTPS站点未启用，3X-UI内置订阅保持本机监听，不生成公网HTTP链接。${plain}"
  fi
  refresh_env
  write_runtime_summary
}

show_help() {
  cat <<EOF
常用命令:
  x-ui
  3xui-kit
  cd ${ROOT_DIR}
  ./scripts/manage.sh status
  ./scripts/manage.sh links
  ./scripts/manage.sh update
  ./scripts/manage.sh backup
  ./scripts/manage.sh autostart
  ./scripts/manage.sh domain
  ./scripts/manage.sh subscription
  ./scripts/manage.sh xui-subscription
  ./scripts/manage.sh protocol-guard

安全建议:
  1. 面板默认绑定 127.0.0.1，通过 SSH 隧道访问。
  2. 公网只开放 ${REALITY_PORT}/tcp 给 VLESS REALITY。
  3. 不要把 .env、install-summary.txt、订阅链接发给别人。
  4. Trojan/Hysteria2 建议使用真实可信 TLS 证书。
  5. 输入域名申请证书前，请先把域名 A 记录解析到当前 VPS 公网 IP。
  6. 配置 HTTPS 证书后，80 端口默认拒绝 HTTP 明文访问；只有手动选择 HTTPS 伪装站点时才跳转到 HTTPS。
  7. 3X-UI 内置订阅服务绑定 127.0.0.1，并通过 HTTPS 随机路径反代，避免导出 http://:2096 链接。

自启动:
  1. Docker Compose 已设置 restart: unless-stopped。
  2. 安装脚本会启用 systemd 服务：${AUTOSTART_SERVICE}。
  3. 查看状态：systemctl status ${AUTOSTART_SERVICE} --no-pager
EOF
}

main_loop() {
  while true; do
    refresh_env
    show_menu
    read -r -p "请输入选项 [0-18]: " choice </dev/tty || choice="0"
    case "$choice" in
      1) install_or_start; pause ;;
      2) uninstall_xui; pause ;;
      3) show_status; show_links; pause ;;
      4) change_panel_settings; pause ;;
      5) protocol_presets_menu; pause ;;
      6) service_menu; pause ;;
      7) ./scripts/manage.sh update; pause ;;
      8) ./scripts/manage.sh backup; pause ;;
      9) docker compose logs --tail=200 3xui; pause ;;
      10) domain_cert_menu; pause ;;
      11) ./scripts/mask-site.sh; docker compose --profile site up -d caddy-site; pause ;;
      12) ./scripts/apply-presets.sh; ./scripts/subscription.sh; [ "${HTTPS_SITE_ENABLE:-0}" = "1" ] && ./scripts/xui-builtin-subscription.sh || true; show_status; show_links; pause ;;
      13) autostart_menu; pause ;;
      14) show_help; pause ;;
      15) subscription_menu; pause ;;
      16) ./scripts/reconcile.sh; pause ;;
      17) ./scripts/network-check.sh; pause ;;
      18) ./scripts/manage.sh refresh-links; show_links; pause ;;
      0) exit 0 ;;
      *) echo "${yellow}无效选项。${plain}"; pause ;;
    esac
  done
}

if [ "${1:-}" = "--print" ]; then
  show_menu
  exit 0
fi

if [ "${1:-}" = "--autostart" ]; then
  autostart_menu
  exit 0
fi

main_loop
