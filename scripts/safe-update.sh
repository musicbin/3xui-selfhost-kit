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
[ -f .env ] && {
  set -a
  . ./.env
  set +a
}
{
  echo "===== safe update started $(date -u +%FT%TZ) ====="
  echo "Current containers:"
  docker compose ps || true
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
