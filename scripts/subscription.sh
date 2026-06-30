#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

SERVER_ADDR="${SERVER_ADDR:-your-server}"
DOMAIN_NAMES="${DOMAIN_NAMES:-}"
XUI_CONTAINER="${XUI_CONTAINER:-3xui}"
PANEL_PORT="${PANEL_PORT:-2053}"
WEB_BASE_PATH="${WEB_BASE_PATH:-panel}"
SITE_HTTP_PORT="${SITE_HTTP_PORT:-80}"
SITE_HTTPS_PORT="${SITE_HTTPS_PORT:-443}"
HTTPS_SITE_ENABLE="${HTTPS_SITE_ENABLE:-0}"
SUBSCRIPTION_TOKEN="${SUBSCRIPTION_TOKEN:-}"
ENABLE_SUB_CONFIG_EDITOR="${ENABLE_SUB_CONFIG_EDITOR:-1}"
SUB_CONFIG_ADMIN_TOKEN="${SUB_CONFIG_ADMIN_TOKEN:-}"
SERVER_ALIASES="${SERVER_ALIASES:-}"
SUBSCRIPTION_EXPAND_ALIASES="${SUBSCRIPTION_EXPAND_ALIASES:-1}"
XUI_API_BASE="${XUI_API_BASE:-}"
XUI_API_TOKEN="${XUI_API_TOKEN:-}"

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

new_token() {
  openssl rand -hex 16
}

normalize_aliases() {
  local values="$1"
  printf '%s' "$values" | tr ',，;； ' '\n' | awk 'NF && !seen[$0]++ { printf "%s%s", sep, $0; sep="," }'
}

ensure_xui_api_env() {
  local aliases token out
  XUI_API_BASE="http://127.0.0.1:${PANEL_PORT}/${WEB_BASE_PATH#/}"
  set_env_var XUI_API_BASE "$XUI_API_BASE"

  if [ -z "$SERVER_ALIASES" ]; then
    aliases="$(normalize_aliases "${DOMAIN_NAMES:-$SERVER_ADDR}")"
    SERVER_ALIASES="${aliases:-$SERVER_ADDR}"
  fi
  set_env_var SERVER_ALIASES "$SERVER_ALIASES"
  set_env_var SUBSCRIPTION_EXPAND_ALIASES "$SUBSCRIPTION_EXPAND_ALIASES"

  if [ -z "$XUI_API_TOKEN" ] && docker inspect "$XUI_CONTAINER" >/dev/null 2>&1; then
    out="$(docker exec "$XUI_CONTAINER" /app/x-ui setting -getApiToken true 2>/dev/null || true)"
    token="$(printf '%s\n' "$out" | awk '/apiToken:/ {print $2}' | tail -n1)"
    if [ -n "$token" ]; then
      XUI_API_TOKEN="$token"
      set_env_var XUI_API_TOKEN "$XUI_API_TOKEN"
    fi
  elif [ -n "$XUI_API_TOKEN" ]; then
    set_env_var XUI_API_TOKEN "$XUI_API_TOKEN"
  fi
}

public_origin_hint() {
  if [ "$HTTPS_SITE_ENABLE" = "1" ]; then
    if [ "$SITE_HTTPS_PORT" = "443" ]; then
      printf 'https://%s' "$SERVER_ADDR"
    else
      printf 'https://%s:%s' "$SERVER_ADDR" "$SITE_HTTPS_PORT"
    fi
  else
    if [ "$SITE_HTTP_PORT" = "80" ]; then
      printf 'http://%s' "$SERVER_ADDR"
    else
      printf 'http://%s:%s' "$SERVER_ADDR" "$SITE_HTTP_PORT"
    fi
  fi
}

write_subscription_files() {
  mkdir -p site/sub/config site/subscriptions runtime
  chmod 700 runtime

  if [ -z "$SUBSCRIPTION_TOKEN" ]; then
    SUBSCRIPTION_TOKEN="$(new_token)"
    set_env_var SUBSCRIPTION_TOKEN "$SUBSCRIPTION_TOKEN"
  fi
  if [ -z "$SUB_CONFIG_ADMIN_TOKEN" ]; then
    SUB_CONFIG_ADMIN_TOKEN="$(new_token)"
    set_env_var SUB_CONFIG_ADMIN_TOKEN "$SUB_CONFIG_ADMIN_TOKEN"
  fi

  if [ ! -s site/sub/config/3.5.yaml ]; then
    cat > site/sub/config/3.5.yaml <<'EOF'
port: 7890
socks-port: 7891
allow-lan: true
mode: Rule
log-level: info
external-controller: 127.0.0.1:9090
proxies:
  - {name: 测试3ip, server: example.com, port: 443, type: vmess, uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, cipher: auto, tls: true}
  - {name: 测试4域名, server: example.com, port: 443, type: vmess, uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, cipher: auto, tls: true}
  - {name: 测试5V6, server: example.com, port: 443, type: vmess, uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, cipher: auto, tls: true}
  - {name: 测试6域名, server: example.com, port: 443, type: vmess, uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, cipher: auto, tls: true}
  - {name: 测试10域名, server: example.com, port: 443, type: vmess, uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, cipher: auto, tls: true}
proxy-groups:
  - name: 🚀 节点选择
    type: select
    proxies:
      - 测试3ip
      - 测试4域名
      - 测试5V6
      - 测试6域名
      - 测试10域名
      - DIRECT
rules:
  - MATCH,🚀 节点选择
EOF
  fi

  local links_source=""
  if [ -s runtime/panel-all-links.txt ]; then
    links_source="runtime/panel-all-links.txt"
  elif [ -s runtime/client-links.txt ]; then
    links_source="runtime/client-links.txt"
  fi

  if [ -n "$links_source" ]; then
    awk '/^(vless|vmess|trojan|ss|hysteria2):\/\// { print }' "$links_source" > "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt"
    if command -v base64 >/dev/null 2>&1 && base64 --help 2>&1 | grep -q -- '-w'; then
      base64 -w0 "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt" > "site/subscriptions/${SUBSCRIPTION_TOKEN}.b64"
    else
      openssl base64 -A -in "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt" -out "site/subscriptions/${SUBSCRIPTION_TOKEN}.b64"
    fi
    printf '\n' >> "site/subscriptions/${SUBSCRIPTION_TOKEN}.b64"
  else
    cat > "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt" <<'EOF'
# No node links generated yet.
# Run: cd /opt/3xui-selfhost-kit && ./scripts/manage.sh apply-presets
EOF
    cp "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt" "site/subscriptions/${SUBSCRIPTION_TOKEN}.b64"
  fi
  chmod 644 "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt" 2>/dev/null || true
  chmod 644 "site/subscriptions/${SUBSCRIPTION_TOKEN}.b64" 2>/dev/null || true
}

write_web_ui() {
  local token="$SUBSCRIPTION_TOKEN"
  cat > site/sub/index.html <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex,nofollow">
  <title>Subscription Converter</title>
  <style>
    :root { color-scheme: light dark; font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; min-height: 100vh; background: #f5f7fb; color: #172033; display: grid; place-items: center; }
    main { width: min(880px, calc(100vw - 32px)); background: rgba(255,255,255,.9); border: 1px solid #d9e2ef; padding: 28px; box-shadow: 0 18px 60px rgba(15,23,42,.12); }
    h1 { margin: 0 0 8px; font-size: 30px; letter-spacing: 0; }
    p { color: #5b6473; line-height: 1.6; }
    label { display: block; margin: 18px 0 8px; font-weight: 700; }
    input, select, textarea { width: 100%; box-sizing: border-box; border: 1px solid #bdc8d8; border-radius: 6px; padding: 12px; font: inherit; background: #fff; color: #111827; }
    textarea { min-height: 86px; resize: vertical; }
    button, a.button { display: inline-flex; align-items: center; justify-content: center; border: 0; border-radius: 6px; padding: 11px 16px; margin: 14px 10px 0 0; background: #2563eb; color: #fff; font-weight: 700; text-decoration: none; cursor: pointer; }
    button.secondary { background: #334155; }
    code { word-break: break-all; display: block; background: #eef2f7; padding: 12px; border-radius: 6px; }
    .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }
    .editor { margin-top: 32px; padding-top: 24px; border-top: 1px solid #d9e2ef; }
    #configEditor { min-height: 420px; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 13px; line-height: 1.5; }
    #editStatus { margin-top: 12px; white-space: pre-wrap; }
    @media (max-width: 760px) { .grid { grid-template-columns: 1fr; } main { padding: 20px; } }
    @media (prefers-color-scheme: dark) {
      body { background: #0f172a; color: #e5e7eb; }
      main { background: rgba(15,23,42,.92); border-color: #334155; }
      p { color: #b6c2d1; }
      input, select, textarea { background: #111827; color: #e5e7eb; border-color: #475569; }
      code { background: #111827; }
      .editor { border-color: #334155; }
    }
  </style>
</head>
<body>
  <main>
    <h1>订阅转换</h1>
    <p>本页使用当前 VPS 上的 subconverter 后端。默认订阅地址来自安装脚本生成的节点文件；也可以填入你自己的远程订阅 URL。</p>
    <label for="url">订阅 URL</label>
    <textarea id="url"></textarea>
    <div class="grid">
      <div>
        <label for="target">目标格式</label>
        <select id="target">
          <option value="clash-35">Clash 3.5.yaml</option>
          <option value="clash">Clash subconverter</option>
          <option value="singbox">sing-box</option>
          <option value="v2ray">V2Ray</option>
          <option value="surge&ver=4">Surge 4</option>
          <option value="quanx">Quantumult X</option>
          <option value="mixed">Mixed</option>
        </select>
      </div>
      <div>
        <label for="config">规则配置</label>
        <input id="config">
      </div>
    </div>
    <button onclick="build()">生成转换链接</button>
    <button onclick="refreshLinks()">刷新全部入站链接</button>
    <button class="secondary" onclick="copyResult()">复制</button>
    <button class="secondary" onclick="copyClash35()">复制 3.5 订阅</button>
    <button class="secondary" onclick="saveDefaults()">保存为默认</button>
    <a class="button" href="https://acl4ssr-sub.github.io/" target="_blank" rel="noreferrer">打开 ACL4SSR 公共页面</a>
    <a class="button" href="/sub/config/3.5.yaml" target="_blank" rel="noreferrer">查看 3.5.yaml</a>
    <label>转换链接</label>
    <code id="result"></code>
    <label>全部入站订阅</label>
    <code id="allLinksStatus">使用规则编辑 Token 可从 3X-UI 刷新 all-nodes 客户端；域名节点模式会按 SERVER_ALIASES 一对一生成多个域名节点。</code>
    <section class="editor">
      <h1>3.5.yaml 规则</h1>
      <p>转换链接默认使用这份规则配置。保存时请保留节点名称，分流组会按这些名称匹配。</p>
      <label for="adminToken">规则编辑 Token</label>
      <input id="adminToken" type="password" autocomplete="off">
      <button class="secondary" onclick="loadRules()">读取规则</button>
      <button onclick="saveRules()">保存规则</button>
      <label for="configEditor">规则内容</label>
      <textarea id="configEditor" spellcheck="false"></textarea>
      <code id="editStatus"></code>
    </section>
  </main>
  <script>
    const token = "${token}";
    const defaultConfig = location.origin + "/sub/config/3.5.yaml";
    const rawSub = location.origin + "/subscriptions/" + token + ".txt";
    const localSub = location.origin + "/subscriptions/" + token + ".b64";
    const clash35 = location.origin + "/subconfig-api/render/clash?token=" + encodeURIComponent(token);
    const urlEl = document.getElementById("url");
    const targetEl = document.getElementById("target");
    const configEl = document.getElementById("config");
    const resultEl = document.getElementById("result");
    const adminTokenEl = document.getElementById("adminToken");
    const configEditorEl = document.getElementById("configEditor");
    const editStatusEl = document.getElementById("editStatus");
    urlEl.value = localStorage.getItem("xuiSubSource") || localSub;
    targetEl.value = localStorage.getItem("xuiSubTarget") || "clash-35";
    configEl.value = localStorage.getItem("xuiSubConfig") || defaultConfig;
    adminTokenEl.value = localStorage.getItem("xuiSubConfigAdminToken") || "";
    function build() {
      const targetValue = targetEl.value;
      const config = configEl.value.trim();
      const source = urlEl.value.trim();
      if (targetValue === "clash-35") {
        resultEl.textContent = clash35;
        return;
      }
      const params = new URLSearchParams();
      for (const [index, part] of targetValue.split("&").entries()) {
        const [k, v] = part.split("=");
        if (index === 0) {
          params.set("target", k);
        } else {
          params.set(k, v || "");
        }
      }
      params.set("url", source);
      if (config) params.set("config", config);
      resultEl.textContent = location.origin + "/subconverter/sub?" + params.toString();
    }
    async function copyResult() {
      if (!resultEl.textContent) build();
      await navigator.clipboard.writeText(resultEl.textContent);
    }
    async function copyClash35() {
      await navigator.clipboard.writeText(clash35);
      resultEl.textContent = clash35;
    }
    async function refreshLinks() {
      try {
        const response = await fetch(location.origin + "/subconfig-api/refresh-links", {
          method: "POST",
          headers: {"X-Admin-Token": adminTokenEl.value.trim()}
        });
        const data = await response.json();
        if (!response.ok || !data.success) throw new Error(data.error || response.statusText);
        localStorage.setItem("xuiSubConfigAdminToken", adminTokenEl.value.trim());
        document.getElementById("allLinksStatus").textContent =
          "已刷新 " + data.count + " 条链接。原始订阅: " + rawSub + "    3.5.yaml订阅: " + clash35;
        resultEl.textContent = clash35;
      } catch (error) {
        document.getElementById("allLinksStatus").textContent = "刷新失败: " + error.message;
      }
    }
    function saveDefaults() {
      localStorage.setItem("xuiSubSource", urlEl.value.trim());
      localStorage.setItem("xuiSubTarget", targetEl.value);
      localStorage.setItem("xuiSubConfig", configEl.value.trim() || defaultConfig);
      build();
    }
    async function configApi(method, body) {
      const headers = {"X-Admin-Token": adminTokenEl.value.trim()};
      if (body !== undefined) headers["Content-Type"] = "text/yaml; charset=utf-8";
      const response = await fetch(location.origin + "/subconfig-api/config", {method, headers, body});
      const text = await response.text();
      if (!response.ok) throw new Error(text || response.statusText);
      return text;
    }
    async function loadRules() {
      try {
        editStatusEl.textContent = "正在读取...";
        localStorage.setItem("xuiSubConfigAdminToken", adminTokenEl.value.trim());
        configEditorEl.value = await configApi("GET");
        editStatusEl.textContent = "已读取服务器上的 3.5.yaml。";
      } catch (error) {
        editStatusEl.textContent = "读取失败: " + error.message;
      }
    }
    async function saveRules() {
      try {
        editStatusEl.textContent = "正在保存...";
        localStorage.setItem("xuiSubConfigAdminToken", adminTokenEl.value.trim());
        await configApi("PUT", configEditorEl.value);
        configEl.value = defaultConfig;
        saveDefaults();
        editStatusEl.textContent = "已保存。新的转换链接会继续使用 /sub/config/3.5.yaml。";
      } catch (error) {
        editStatusEl.textContent = "保存失败: " + error.message;
      }
    }
    build();
  </script>
</body>
</html>
EOF
}

start_subscription_services() {
  if [ "${ENABLE_SUBCONVERTER:-1}" != "1" ]; then
    return
  fi
  docker compose pull subconverter
  docker compose up -d subconverter
  if [ "${ENABLE_SUB_CONFIG_EDITOR:-1}" = "1" ]; then
    docker compose pull subconfig-api
    docker compose up -d --force-recreate subconfig-api
  fi
}

refresh_links_from_api() {
  [ "${ENABLE_SUB_CONFIG_EDITOR:-1}" = "1" ] || return 0
  [ -n "${SUB_CONFIG_ADMIN_TOKEN:-}" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  local i response
  for i in $(seq 1 20); do
    response="$(curl -fsS --connect-timeout 2 --max-time 10 \
      -X POST \
      -H "X-Admin-Token: ${SUB_CONFIG_ADMIN_TOKEN}" \
      "http://127.0.0.1:${SUB_CONFIG_PORT:-27880}/refresh-links" 2>/dev/null || true)"
    if printf '%s' "$response" | grep -Eq '"success"[[:space:]]*:[[:space:]]*true'; then
      if [ -s "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt" ]; then
        {
          echo "Domain all-nodes subscription links"
          awk '/^(vless|vmess|trojan|ss|hysteria2):\/\// { print }' "site/subscriptions/${SUBSCRIPTION_TOKEN}.txt"
          echo
        } > runtime/client-links.txt
        chmod 600 runtime/client-links.txt 2>/dev/null || true
      fi
      echo "Subscription links refreshed from 3X-UI all-nodes clients."
      return 0
    fi
    sleep 1
  done
  echo "Subscription API refresh did not complete yet; use the Web UI refresh button or run manage.sh refresh-links later." >&2
}

main() {
  ensure_xui_api_env
  write_subscription_files
  write_web_ui
  start_subscription_services
  refresh_links_from_api
  echo "Subscription web UI:"
  echo "  $(public_origin_hint)/sub/"
  echo "Tokenized local node subscription:"
  echo "  $(public_origin_hint)/subscriptions/${SUBSCRIPTION_TOKEN}.txt"
  echo "Default conversion config:"
  echo "  $(public_origin_hint)/sub/config/3.5.yaml"
  echo "Rules editor token:"
  echo "  ${SUB_CONFIG_ADMIN_TOKEN}"
}

main "$@"
