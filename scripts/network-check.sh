#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

[ -f .env ] && {
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
}

DOMAIN_NAMES="${DOMAIN_NAMES:-}"
SERVER_ADDR="${SERVER_ADDR:-}"
PUBLIC_IPV4="${PUBLIC_IPV4:-}"
PUBLIC_IPV6="${PUBLIC_IPV6:-}"

normalize_domains() {
  printf '%s' "$1" | tr ',，;； ' '\n' | awk 'NF && !seen[$0]++ { print }'
}

detect_ipv4() {
  [ -n "$PUBLIC_IPV4" ] && { printf '%s' "$PUBLIC_IPV4"; return; }
  curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true
}

detect_ipv6() {
  [ -n "$PUBLIC_IPV6" ] && { printf '%s' "$PUBLIC_IPV6"; return; }
  curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null || true
}

resolve_a() {
  local host="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$host" | awk 'NF'
  else
    getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | awk '!seen[$0]++'
  fi
}

resolve_aaaa() {
  local host="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short AAAA "$host" | awk 'NF'
  else
    getent ahostsv6 "$host" 2>/dev/null | awk '{print $1}' | awk '!seen[$0]++'
  fi
}

contains_line() {
  local needle="$1"
  grep -Fxq "$needle"
}

ipv4="$(detect_ipv4)"
ipv6="$(detect_ipv6)"

echo "Server IPv4: ${ipv4:-not detected}"
echo "Server IPv6: ${ipv6:-not detected}"
echo

if [ -z "$DOMAIN_NAMES" ]; then
  echo "DOMAIN_NAMES is empty. Add every domain/prefix you want covered, for example:"
  echo "  DOMAIN_NAMES=example.com,www.example.com,a.example.com"
  exit 0
fi

ok=1
while IFS= read -r domain; do
  [ -n "$domain" ] || continue
  echo "Domain: $domain"
  a_records="$(resolve_a "$domain" || true)"
  aaaa_records="$(resolve_aaaa "$domain" || true)"
  echo "  A:    ${a_records:-none}"
  echo "  AAAA: ${aaaa_records:-none}"

  if [ -n "$ipv4" ]; then
    if printf '%s\n' "$a_records" | contains_line "$ipv4"; then
      echo "  IPv4: ok"
    else
      echo "  IPv4: not pointing to this VPS. Use DNS-only A record for proxy protocols."
      ok=0
    fi
  fi

  if [ -n "$ipv6" ]; then
    if printf '%s\n' "$aaaa_records" | contains_line "$ipv6"; then
      echo "  IPv6: ok"
    else
      echo "  IPv6: missing or not pointing to this VPS. Add an AAAA record for full IPv6 support."
      ok=0
    fi
  else
    echo "  IPv6: VPS public IPv6 not detected; skipped."
  fi
  echo
done < <(normalize_domains "$DOMAIN_NAMES")

echo "Ports:"
ss -lntp 2>/dev/null | grep -E '(:80|:443|:8388|:8443|:9443|:2053|:2096|:20510|:18080)' || true

if [ "$ok" = "1" ]; then
  echo
  echo "DNS check passed for configured domains."
else
  echo
  echo "DNS check found issues. Fix DNS, then run: sudo ./scripts/manage.sh domain && sudo ./scripts/manage.sh subscription"
fi
