#!/bin/sh
# =============================================================================
# haproxy-entrypoint.sh — Substitute environment variables into haproxy.cfg
# before HAProxy starts.
# Variables: NEXTCLOUD_DOMAIN, COLLABORA_DOMAIN, WHITEBOARD_DOMAIN,
#            HAPROXY_STATS_PASSWORD, TALK_DOMAIN (optional — Talk HA)
# =============================================================================
set -e

TEMPLATE="/usr/local/etc/haproxy/haproxy.cfg"
OUTPUT="/tmp/haproxy.cfg"

if [ ! -f "${TEMPLATE}" ]; then
  echo "[entrypoint] ERROR: ${TEMPLATE} not found" >&2
  exit 1
fi

echo "[entrypoint] Substituting domains into haproxy.cfg..."
sed \
  -e "s|\${NEXTCLOUD_DOMAIN}|${NEXTCLOUD_DOMAIN:?NEXTCLOUD_DOMAIN is not set}|g" \
  -e "s|\${COLLABORA_DOMAIN}|${COLLABORA_DOMAIN:?COLLABORA_DOMAIN is not set}|g" \
  -e "s|\${WHITEBOARD_DOMAIN}|${WHITEBOARD_DOMAIN:?WHITEBOARD_DOMAIN is not set}|g" \
  -e "s|\${TALK_DOMAIN}|${TALK_DOMAIN:-}|g" \
  -e "s|\${HAPROXY_STATS_PASSWORD}|${HAPROXY_STATS_PASSWORD:-changeme}|g" \
  "${TEMPLATE}" > "${OUTPUT}"

echo "[entrypoint] Configuration generated for:"
echo "  Nextcloud  : ${NEXTCLOUD_DOMAIN}"
echo "  Collabora  : ${COLLABORA_DOMAIN}"
echo "  Whiteboard : ${WHITEBOARD_DOMAIN}"
[ -n "${TALK_DOMAIN:-}" ] && echo "  Talk       : ${TALK_DOMAIN}" || echo "  Talk       : disabled"

exec haproxy -f "${OUTPUT}" "$@"
