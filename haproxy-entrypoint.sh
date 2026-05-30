#!/bin/sh
# =============================================================================
# haproxy-entrypoint.sh — Substitution des variables d'environnement dans
# haproxy.cfg avant le démarrage de HAProxy
# Variables substituées : NEXTCLOUD_DOMAIN, COLLABORA_DOMAIN, WHITEBOARD_DOMAIN,
#                         HAPROXY_STATS_PASSWORD
# =============================================================================
set -e

TEMPLATE="/usr/local/etc/haproxy/haproxy.cfg"
OUTPUT="/tmp/haproxy.cfg"

if [ ! -f "${TEMPLATE}" ]; then
  echo "[entrypoint] ERREUR : ${TEMPLATE} introuvable" >&2
  exit 1
fi

echo "[entrypoint] Substitution des domaines dans haproxy.cfg..."
sed \
  -e "s|\${NEXTCLOUD_DOMAIN}|${NEXTCLOUD_DOMAIN:?NEXTCLOUD_DOMAIN non défini}|g" \
  -e "s|\${COLLABORA_DOMAIN}|${COLLABORA_DOMAIN:?COLLABORA_DOMAIN non défini}|g" \
  -e "s|\${WHITEBOARD_DOMAIN}|${WHITEBOARD_DOMAIN:?WHITEBOARD_DOMAIN non défini}|g" \
  -e "s|\${TALK_DOMAIN}|${TALK_DOMAIN:?TALK_DOMAIN non défini}|g" \
  -e "s|\${HAPROXY_STATS_PASSWORD}|${HAPROXY_STATS_PASSWORD:-changeme}|g" \
  "${TEMPLATE}" > "${OUTPUT}"

echo "[entrypoint] Configuration générée pour :"
echo "  Nextcloud  : ${NEXTCLOUD_DOMAIN}"
echo "  Collabora  : ${COLLABORA_DOMAIN}"
echo "  Whiteboard : ${WHITEBOARD_DOMAIN}"
echo "  Talk       : ${TALK_DOMAIN}"

exec haproxy -f "${OUTPUT}" "$@"
