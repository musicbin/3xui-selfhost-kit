#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

[ -f .env ] || { echo ".env not found. Run install.sh first." >&2; exit 1; }

mkdir -p runtime data/backups
chmod 700 runtime

ts="$(date +%Y%m%d-%H%M%S)"
log_file="$ROOT_DIR/runtime/safe-update.log"
run_file="$ROOT_DIR/runtime/safe-update-run.sh"

if [ -f data/db/x-ui.db ]; then
  cp -p data/db/x-ui.db "data/backups/x-ui-before-update-${ts}.db"
fi
cp -p .env "data/backups/env-before-update-${ts}.txt"
chmod 600 data/backups/*"${ts}"* 2>/dev/null || true

cat > "$run_file" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/musicbin/3xui-selfhost-kit/main}"
[ -f .env ] && {
  set -a
  . ./.env
  set +a
}

download_kit_file() {
  local src="$1"
  local dst="$2"
  local tmp
  mkdir -p "$(dirname "$dst")"
  tmp="$(mktemp)"
  if ! curl -fsSL "${REPO_RAW_BASE}/${src}" -o "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$dst"
}

sync_kit_files() {
  local files=(
    "compose.yaml"
    "scripts/manage.sh"
    "scripts/apply-presets.sh"
    "scripts/domain-cert.sh"
    "scripts/subscription.sh"
    "scripts/xui-builtin-subscription.sh"
    "scripts/mask-site.sh"
    "scripts/protocol-guard.sh"
    "scripts/network-check.sh"
    "scripts/reconcile.sh"
    "scripts/safe-update.sh"
    "scripts/subconfig-api.py"
    "scripts/start-services.sh"
    "scripts/menu.sh"
    "caddy/Caddyfile"
    "site/index.html"
    "site/forward/index.html"
    "site/sub/config/3.5.yaml"
    "README.md"
    "SECURITY.md"
  )
  local f
  for f in "${files[@]}"; do
    download_kit_file "$f" "$f"
  done
  chmod +x scripts/*.sh
}

{
  echo "===== safe update started $(date -u +%FT%TZ) ====="
  echo "Current containers:"
  docker compose ps || true
  echo
  echo "Syncing latest 3xui-selfhost-kit scripts..."
  if ! sync_kit_files; then
    echo "Kit script sync failed; continuing with the existing local files."
  fi
  echo
  echo "Pulling latest official 3X-UI image..."
  docker compose pull 3xui
  echo
  echo "Starting/recreating 3X-UI..."
  docker compose up -d 3xui || docker start "${XUI_CONTAINER:-3xui}" || true
  sleep 8
  echo
  echo "Reconciling local hardening, domains, subscriptions, and protocols..."
  ./scripts/reconcile.sh
  echo "===== safe update completed $(date -u +%FT%TZ) ====="
} >> runtime/safe-update.log 2>&1
EOF
chmod +x "$run_file"

nohup "$run_file" >/dev/null 2>&1 &

echo "Safe update started in background."
echo "Backup:"
echo "  data/backups/x-ui-before-update-${ts}.db"
echo "  data/backups/env-before-update-${ts}.txt"
echo "Log:"
echo "  $log_file"
echo
echo "Watch:"
echo "  tail -f $log_file"
