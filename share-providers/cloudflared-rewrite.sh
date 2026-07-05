#!/usr/bin/env bash

# cloudflared-rewrite share provider for DDEV
#
# Like the stock cloudflared provider, but chains the tunnel through a small
# local Go reverse proxy (ddev-share-proxy) that rewrites the project's
# hostname to the tunnel hostname in response bodies and Location headers:
#
#   cloudflared -> ddev-share-proxy -> DDEV web container
#
# This makes CMSes that generate absolute URLs from a stored base URL
# (WordPress, Magento 2, ...) fully browsable through the tunnel with no
# database changes and no CMS-side code. The backend always sees a normal
# local request for the project hostname with X-Forwarded-Proto: https —
# identical to traffic from the DDEV router — so trusted-host checks,
# is_ssl(), and host-keyed caches behave as usual.
#
# Requirements:
#   - cloudflared (https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/)
#   - jq
#   - ~/.ddev/bin/ddev-share-proxy built from https://github.com/<you>/ddev-share-proxy
#     (proof-of-concept: not auto-installed yet, build it yourself with `go build`)
#
# Usage:
#   ddev share --provider=cloudflared-rewrite
#
# Known limitations:
#   - Content saved *through* the tunnel (e.g. editing posts in wp-admin) can
#     persist tunnel URLs into the database. Use this for viewing/testing.
#   - URLs inside WebSocket payloads are not rewritten.

set -euo pipefail

if [[ "${DDEV_DEBUG:-}" == "true" ]] || [[ "${DDEV_VERBOSE:-}" == "true" ]]; then
  set -x
fi

# ----------------------------------------------------------
# Validate dependencies
# ----------------------------------------------------------
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "Error: cloudflared not found in PATH." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed. Install it with: sudo apt install jq" >&2
  exit 1
fi

if [[ -z "${DDEV_LOCAL_URL:-}" ]]; then
  echo "Error: DDEV_LOCAL_URL not set" >&2
  exit 1
fi

PROXY_BIN="$HOME/.ddev/bin/ddev-share-proxy"
if [[ ! -x "$PROXY_BIN" ]]; then
  echo "Error: $PROXY_BIN not found or not executable." >&2
  echo "Build it with: cd /home/delat/ddev-share-proxy && go build -o $PROXY_BIN ." >&2
  exit 1
fi

# ----------------------------------------------------------
# Discover the project hostname
# ----------------------------------------------------------
PRIMARY_URL=$(ddev describe -j | jq -r '.raw.primary_url')
LOCAL_HOST=${PRIMARY_URL#*://}
LOCAL_HOST=${LOCAL_HOST%%/*}

# ----------------------------------------------------------
# Find a free localhost port for the rewrite proxy
# ----------------------------------------------------------
PROXY_PORT=""
for port in $(seq 8410 8499); do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    PROXY_PORT=$port
    break
  fi
  exec 3>&- || true
done
if [[ -z "$PROXY_PORT" ]]; then
  echo "Error: no free port found for the rewrite proxy" >&2
  exit 1
fi

# ----------------------------------------------------------
# Start the rewrite proxy
# ----------------------------------------------------------
# DDEV kills the provider without letting the EXIT trap run, so clean up
# leftovers from previous runs of this project here instead.
rm -rf "/tmp/ddev-share-rewrite.${LOCAL_HOST}."* 2>/dev/null || true
WORKDIR=$(mktemp -d "/tmp/ddev-share-rewrite.${LOCAL_HOST}.XXXXXX")

"$PROXY_BIN" \
  --upstream "$DDEV_LOCAL_URL" \
  --host "$LOCAL_HOST" \
  --listen "127.0.0.1:${PROXY_PORT}" \
  ${DDEV_VERBOSE:+--verbose} \
  > "$WORKDIR/proxy.log" 2>&1 &
PROXY_PID=$!

cleanup() {
  kill "$PROXY_PID" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

sleep 0.5
if ! kill -0 "$PROXY_PID" 2>/dev/null; then
  echo "Error: rewrite proxy failed to start:" >&2
  cat "$WORKDIR/proxy.log" >&2
  exit 1
fi

echo "Rewrite proxy: 127.0.0.1:${PROXY_PORT} -> ${DDEV_LOCAL_URL} (rewriting ${LOCAL_HOST} -> tunnel host)" >&2

# ----------------------------------------------------------
# Start cloudflared against the rewrite proxy
# (URL detection below mirrors the stock cloudflared provider)
# ----------------------------------------------------------
ARGS="${DDEV_SHARE_ARGS:-}"
TUNNEL_NAME=""
HOSTNAME=""

if [[ "$ARGS" =~ --tunnel([[:space:]]+|=)([^[:space:]]+) ]]; then
  TUNNEL_NAME="${BASH_REMATCH[2]}"
  ARGS=$(echo "$ARGS" | sed -E 's/--tunnel([[:space:]]+|=)[^[:space:]]+//')
fi

if [[ "$ARGS" =~ --hostname([[:space:]]+|=)([^[:space:]]+) ]]; then
  HOSTNAME="${BASH_REMATCH[2]}"
  ARGS=$(echo "$ARGS" | sed -E 's/--hostname([[:space:]]+|=)[^[:space:]]+//')
fi

ARGS=$(echo "$ARGS" | sed -E 's/[[:space:]]+/ /g;s/^ //;s/ $//')

URL_FOUND=""
if [[ -n "$HOSTNAME" ]]; then
  echo "https://$HOSTNAME" # Output to stdout - CRITICAL: This is captured by DDEV
  URL_FOUND="https://$HOSTNAME"
fi

PROXY_URL="http://127.0.0.1:${PROXY_PORT}"

if [[ -n "$TUNNEL_NAME" ]]; then
  echo "Using named tunnel: $TUNNEL_NAME" >&2
  cloudflared --url "$PROXY_URL" --protocol http2 $ARGS tunnel run "$TUNNEL_NAME" 2>&1
else
  cloudflared tunnel --url "$PROXY_URL" --protocol http2 $ARGS 2>&1
fi | while IFS= read -r line; do
  if [[ -z "$URL_FOUND" ]] && [[ "$line" =~ https://[a-z0-9-]+\.trycloudflare\.com ]]; then
    POTENTIAL_URL="${BASH_REMATCH[0]}"
    if [[ ! "$POTENTIAL_URL" =~ api\.trycloudflare\.com ]]; then
      URL_FOUND="$POTENTIAL_URL"
      echo "$URL_FOUND" # Output to stdout - CRITICAL: This is captured by DDEV
    fi
  fi
  if [[ "${DDEV_VERBOSE:-}" == "true" ]] || [[ ! "$line" =~ " INF " ]]; then
    echo "$line" >&2
  fi
done
