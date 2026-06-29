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

docker compose up -d 3xui

if [ "${ENABLE_SUBCONVERTER:-1}" = "1" ]; then
  docker compose up -d subconverter
fi

if [ "${ENABLE_SUB_CONFIG_EDITOR:-1}" = "1" ]; then
  docker compose up -d subconfig-api
fi

if [ "${ENABLE_MASK_SITE:-1}" = "1" ]; then
  if [ -n "${TLS_CERT_FILE:-}" ] && [ "${HTTPS_SITE_ENABLE:-0}" = "1" ]; then
    docker compose --profile site stop caddy-site >/dev/null 2>&1 || true
    docker compose --profile https-site up -d caddy-https
  else
    docker compose --profile https-site stop caddy-https >/dev/null 2>&1 || true
    docker compose --profile site up -d caddy-site
  fi
fi
