#!/usr/bin/env bash

# cloudflared-router share provider for DDEV
#
# Routes tunnel traffic through ddev-router (Traefik) itself — no extra
# binary, no extra container:
#
#   cloudflared -> ddev-router (Traefik rewrite middlewares) -> web container
#
# When the tunnel URL is known, this script pushes a per-share Traefik
# dynamic-config file into the router's watched config directory. Traefik's
# file provider picks it up live (no restart). The pushed config adds:
#   - a router rule matching the tunnel hostname
#   - a headers middleware that forwards the request upstream with the
#     project's normal local Host header
#   - a rewrite-body plugin middleware rewriting the local hostname to the
#     tunnel hostname in text/HTML/JSON/XML/JS response bodies
#   - a rewrite-headers plugin middleware doing the same for Location headers
#
# One-time setup (Traefik plugins are "static" config, read at router start):
#   1. Copy traefik/static_config.share-rewrite.yaml from this repo into
#      ~/.ddev/traefik/
#   2. ddev poweroff && ddev start
#
# Requirements: cloudflared, jq, docker
#
# Usage:
#   ddev share --provider=cloudflared-router
#
# Known limitations:
#   - Content saved *through* the tunnel (e.g. editing posts in wp-admin) can
#     persist tunnel URLs into the database. Use this for viewing/testing.
#   - URLs inside WebSocket payloads are not rewritten.
#   - Responses to requests without an Accept header are not rewritten
#     (rewrite-body plugin gates on the request's Accept header; browsers,
#     fetch(), and curl all send one).

set -euo pipefail

if [[ "${DDEV_DEBUG:-}" == "true" ]] || [[ "${DDEV_VERBOSE:-}" == "true" ]]; then
  set -x
fi

# ----------------------------------------------------------
# Validate dependencies
# ----------------------------------------------------------
for cmd in cloudflared jq docker; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd not found in PATH." >&2
    exit 1
  fi
done

# ----------------------------------------------------------
# Discover project name, hostname, and router entrypoint
# ----------------------------------------------------------
DESCRIBE=$(ddev describe -j)
PROJECT=$(echo "$DESCRIBE" | jq -r '.raw.name')
PRIMARY_URL=$(echo "$DESCRIBE" | jq -r '.raw.primary_url')

LOCAL_HOST=${PRIMARY_URL#*://}
LOCAL_HOST=${LOCAL_HOST%%/*}
if [[ "$LOCAL_HOST" == *:* ]]; then
  HTTPS_PORT=${LOCAL_HOST##*:}
  LOCAL_HOST=${LOCAL_HOST%%:*}
else
  HTTPS_PORT=443
fi
ENTRYPOINT="http-${HTTPS_PORT}"

# ----------------------------------------------------------
# Preflight: router running, rewrite plugins loaded
# ----------------------------------------------------------
if ! docker inspect -f '{{.State.Running}}' ddev-router 2>/dev/null | grep -q true; then
  echo "Error: ddev-router is not running. This provider requires the router (not router: none)." >&2
  exit 1
fi

if ! grep -q "rewrite-body" "$HOME/.ddev/traefik/.static_config.yaml" 2>/dev/null; then
  echo "Error: the rewrite-body Traefik plugin is not configured in the router." >&2
  echo "One-time setup:" >&2
  echo "  1. Copy traefik/static_config.share-rewrite.yaml from the ddev-share-proxy repo into ~/.ddev/traefik/" >&2
  echo "  2. Run: ddev poweroff && ddev start" >&2
  exit 1
fi

ROUTER_CONF="/mnt/ddev-global-cache/traefik/config/share-${PROJECT}.yaml"

# DDEV may kill the provider without letting the EXIT trap run, so clean up
# leftovers from previous runs of this project here as well.
docker exec ddev-router rm -f "$ROUTER_CONF" 2>/dev/null || true
rm -rf "/tmp/ddev-share-router.${PROJECT}."* 2>/dev/null || true
WORKDIR=$(mktemp -d "/tmp/ddev-share-router.${PROJECT}.XXXXXX")

cleanup() {
  docker exec ddev-router rm -f "$ROUTER_CONF" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

# ----------------------------------------------------------
# Generate and push the per-share Traefik dynamic config
# ----------------------------------------------------------
push_config() {
  local tunnel_host=$1
  local local_re=${LOCAL_HOST//./\\.}
  local tunnel_re=${tunnel_host//./\\.}

  cat > "$WORKDIR/share-config.yaml" <<EOF
# Pushed by the cloudflared-router DDEV share provider; removed when the
# share session ends.
http:
  routers:
    share-${PROJECT}:
      entryPoints:
        - "${ENTRYPOINT}"
      rule: Host(\`${tunnel_host}\`)
      service: share-${PROJECT}
      tls: true
      middlewares:
        - share-${PROJECT}-host
        - share-${PROJECT}-body
        - share-${PROJECT}-location

  services:
    share-${PROJECT}:
      loadBalancer:
        servers:
          - url: http://ddev-${PROJECT}-web:80

  middlewares:
    share-${PROJECT}-host:
      headers:
        customRequestHeaders:
          Host: "${LOCAL_HOST}"
    share-${PROJECT}-body:
      plugin:
        rewrite-body:
          lastModified: true
          monitoring:
            methods:
              - GET
              - POST
            # '*/*' makes the plugin's request-side Accept-header gate pass
            # for browsers, fetch(), and curl; the response-side gate still
            # filters on real Content-Type values below.
            types:
              - '*/*'
              - text/html
              - text/plain
              - text/css
              - text/xml
              - application/json
              - application/javascript
              - application/xml
              - application/rss+xml
              - application/atom+xml
              - application/manifest+json
              - application/vnd.api+json
          rewrites:
            - regex: '${local_re}'
              replacement: '${tunnel_host}'
            - regex: 'http://${tunnel_re}'
              replacement: 'https://${tunnel_host}'
            - regex: 'http:\\\\/\\\\/${tunnel_re}'
              replacement: 'https:\\/\\/${tunnel_host}'
    share-${PROJECT}-location:
      plugin:
        rewrite-headers:
          rewrites:
            - header: "Location"
              regex: 'https?://${local_re}'
              replacement: 'https://${tunnel_host}'
EOF

  docker cp "$WORKDIR/share-config.yaml" "ddev-router:${ROUTER_CONF}" >/dev/null
  # Give Traefik's file watcher a moment to load the new route before the
  # URL is announced.
  sleep 1
  echo "Pushed share route for ${tunnel_host} into ddev-router (${ROUTER_CONF})" >&2
}

# ----------------------------------------------------------
# Start cloudflared against the router's HTTPS entrypoint
# (URL detection below mirrors the stock cloudflared provider)
# ----------------------------------------------------------
ROUTER_URL="https://127.0.0.1:${HTTPS_PORT}"

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
  push_config "$HOSTNAME"
  echo "https://$HOSTNAME" # Output to stdout - CRITICAL: This is captured by DDEV
  URL_FOUND="https://$HOSTNAME"
fi

if [[ -n "$TUNNEL_NAME" ]]; then
  echo "Using named tunnel: $TUNNEL_NAME" >&2
  cloudflared --url "$ROUTER_URL" --no-tls-verify --protocol http2 $ARGS tunnel run "$TUNNEL_NAME" 2>&1
else
  cloudflared tunnel --url "$ROUTER_URL" --no-tls-verify --protocol http2 $ARGS 2>&1
fi | while IFS= read -r line; do
  if [[ -z "$URL_FOUND" ]] && [[ "$line" =~ https://[a-z0-9-]+\.trycloudflare\.com ]]; then
    POTENTIAL_URL="${BASH_REMATCH[0]}"
    if [[ ! "$POTENTIAL_URL" =~ api\.trycloudflare\.com ]]; then
      URL_FOUND="$POTENTIAL_URL"
      push_config "${URL_FOUND#https://}"
      echo "$URL_FOUND" # Output to stdout - CRITICAL: This is captured by DDEV
    fi
  fi
  if [[ "${DDEV_VERBOSE:-}" == "true" ]] || [[ ! "$line" =~ " INF " ]]; then
    echo "$line" >&2
  fi
done
