#!/bin/bash
# =============================================================================
# nextcloud-init.sh — Configuration automatique de Nextcloud post-installation
# Exécuté UNE SEULE FOIS par le service nextcloud-setup après app-next-01.
# Configure : Redis Cluster, Collabora Online, Nextcloud Whiteboard.
# =============================================================================
set -euo pipefail

OCC_BIN="php /var/www/html/occ --no-warnings"
NC_CONFIG="/var/www/html/config/config.php"

info()  { echo "[setup] ✓  $*"; }
step()  { echo ""; echo "[setup] ══════════════════════════════════════"; echo "[setup]  $*"; echo "[setup] ══════════════════════════════════════"; }
warn()  { echo "[setup] ⚠  $*"; }
err()   { echo "[setup] ✗  $*" >&2; exit 1; }

# Le container tourne en user www-data (uid 33) — pas besoin de su
# Wrapper avec retry automatique (5 tentatives, 10s entre chaque)
# Délai augmenté pour absorber les failovers Galera (re-élection ~5-8s)
occ() {
  local attempt=0 max=5
  while (( attempt < max )); do
    if ${OCC_BIN} "$@"; then return 0; fi
    (( attempt++ )) || true
    warn "occ $* — tentative ${attempt}/${max} échouée, retry dans 10s..."
    sleep 10
  done
  err "occ $* a échoué après ${max} tentatives"
}

# ---------------------------------------------------------------------------
# 1. Attente que Nextcloud soit opérationnel
# ---------------------------------------------------------------------------
step "Vérification de Nextcloud"
echo "[setup] Attente de Nextcloud (max 10 min)..."
RETRIES=120
until [ -f "${NC_CONFIG}" ] && occ status 2>/dev/null | grep -q "installed: true"; do
    RETRIES=$((RETRIES - 1))
    [ ${RETRIES} -le 0 ] && err "Nextcloud n'a pas démarré après 10 minutes."
    echo "[setup] En attente... (${RETRIES} essais restants)"
    sleep 5
done
info "Nextcloud opérationnel."

# ---------------------------------------------------------------------------
# 2. Redis Cluster
# ---------------------------------------------------------------------------
step "Configuration Redis Cluster"

occ config:system:set memcache.local        --value '\OC\Memcache\APCu'
occ config:system:set memcache.distributed  --value '\OC\Memcache\Redis'
occ config:system:set memcache.locking      --value '\OC\Memcache\Redis'
occ config:system:set filelocking.enabled   --type boolean --value true
occ config:system:set filelocking.ttl       --type integer --value 3600

# 3 seeds fixes — minimum 6 nœuds imposé, node1/node3/node5 existent toujours.
# Le client découvre la topologie complète depuis un seul seed vivant.
occ config:system:set redis.cluster seeds 0 --value "redis-node1:6379"
occ config:system:set redis.cluster seeds 1 --value "redis-node3:6379"
occ config:system:set redis.cluster seeds 2 --value "redis-node5:6379"
occ config:system:set redis.cluster password       --value "${REDIS_PASSWORD}"
occ config:system:set redis.cluster timeout        --type float   --value 1.5
occ config:system:set redis.cluster read_timeout   --type float   --value 1.5

info "Redis Cluster configuré (seeds : redis-node1, redis-node3, redis-node5)."

# ---------------------------------------------------------------------------
# 3. Domaines de confiance
# ---------------------------------------------------------------------------
step "Domaines de confiance et proxy"
occ config:system:set trusted_domains 0 --value "${NEXTCLOUD_DOMAIN}"
occ config:system:set trusted_domains 1 --value "localhost"
occ config:system:set trusted_domains 2 --value "127.0.0.1"
occ config:system:set overwrite.cli.url   --value "https://${NEXTCLOUD_DOMAIN}"
occ config:system:set overwriteprotocol  --value "https"

# Proxies de confiance : tout le réseau next-net (HAProxy, autres nodes Nextcloud)
# Sans cela, Nextcloud voit l'IP de HAProxy pour tous les clients → brute-force faux positifs
occ config:system:set trusted_proxies 0 --value "172.10.0.0/24"
occ config:system:set forwarded_for_headers 0 --value "HTTP_X_FORWARDED_FOR"
info "Proxies de confiance configurés (172.10.0.0/24)."

# ---------------------------------------------------------------------------
# 4. Collabora Online (richdocuments)
# ---------------------------------------------------------------------------
step "Installation Collabora Online (richdocuments)"

if occ app:list --output=plain 2>/dev/null | grep -qE '^richdocuments$|^\s*richdocuments\s'; then
    warn "richdocuments déjà présent — activation"
    occ app:enable richdocuments || true
else
    echo "[setup] Téléchargement depuis le Nextcloud App Store..."
    occ app:install richdocuments
fi

occ config:app:set richdocuments wopi_url        --value "https://${COLLABORA_DOMAIN}"
occ config:app:set richdocuments public_wopi_url --value "https://${COLLABORA_DOMAIN}"
# Autoriser le serveur Collabora (IP interne du cluster Docker)
occ config:app:set richdocuments wopi_allowlist  --value "172.10.0.0/24,172.40.0.0/24"

info "Collabora Online configuré → https://${COLLABORA_DOMAIN}"

# ---------------------------------------------------------------------------
# 5. Nextcloud Whiteboard
# ---------------------------------------------------------------------------
step "Installation Nextcloud Whiteboard"

if occ app:list --output=plain 2>/dev/null | grep -qE '^whiteboard$|^\s*whiteboard\s'; then
    warn "whiteboard déjà présent — activation"
    occ app:enable whiteboard || true
else
    echo "[setup] Téléchargement depuis le Nextcloud App Store..."
    occ app:install whiteboard
fi

occ config:app:set whiteboard collabBackendUrl --value "https://${WHITEBOARD_DOMAIN}"
occ config:app:set whiteboard jwt_secret_key   --value "${WHITEBOARD_JWT_SECRET}"

info "Whiteboard configuré → https://${WHITEBOARD_DOMAIN}"

# ---------------------------------------------------------------------------
# 6. Stockage objet S3 — MinIO via HAProxy (port 9000 interne)
# IMPORTANT : à configurer avant la création de données utilisateur
# ---------------------------------------------------------------------------
step "Configuration stockage objet S3 (MinIO)"

occ config:system:set objectstore class                  --value '\OC\Files\ObjectStore\S3'
occ config:system:set objectstore arguments bucket       --value "${NEXTCLOUD_S3_BUCKET:-nextcloud}"
occ config:system:set objectstore arguments autocreate   --type boolean --value true
occ config:system:set objectstore arguments hostname     --value 'haproxy'
occ config:system:set objectstore arguments key          --value "${MINIO_ACCESS_KEY}"
occ config:system:set objectstore arguments secret       --value "${MINIO_SECRET_KEY}"
occ config:system:set objectstore arguments port         --type integer --value 9000
occ config:system:set objectstore arguments use_path_style --type boolean --value true
occ config:system:set objectstore arguments use_ssl      --type boolean --value false

info "Stockage S3 configuré → haproxy:9000 / bucket: ${NEXTCLOUD_S3_BUCKET:-nextcloud}"

# ---------------------------------------------------------------------------
# 7. Paramètres système complémentaires
# ---------------------------------------------------------------------------
step "Paramètres système"
occ config:system:set default_language    --value 'fr'
occ config:system:set default_locale      --value 'fr_FR'
occ config:system:set default_phone_region --value 'FR'
occ config:system:set loglevel            --type integer --value 2
occ config:system:set maintenance_window_start --type integer --value 1

# Vider le dossier skeleton — aucun fichier exemple créé pour les nouveaux comptes
occ config:system:set skeletondirectory --value ''

# Sécurité / UX
# Autoriser Nextcloud à appeler sa propre URL (IPs locales Docker) — requis pour le check .well-known
occ config:system:set allow_local_remote_servers --type boolean --value true

occ config:system:set upgrade.disable-web      --type boolean --value true
occ config:system:set simpleSignUpLink.shown   --type boolean --value false

# Rotation des logs à 100 Mo (évite de remplir le disque)
occ config:system:set log_rotate_size --type integer --value 104857600

# Activer le mode cron système (nextcloud-cron container)
occ background:cron

info "Paramètres système configurés."

# Limites de génération de previews — désactiver les formats lourds (vidéo, HEIC, Office)
occ config:system:set preview_max_x            --type integer --value 2048
occ config:system:set preview_max_y            --type integer --value 2048
occ config:system:set preview_max_scale_factor --type integer --value 1
occ config:system:set enabledPreviewProviders 0 --value 'OC\Preview\PNG'
occ config:system:set enabledPreviewProviders 1 --value 'OC\Preview\JPEG'
occ config:system:set enabledPreviewProviders 2 --value 'OC\Preview\GIF'
occ config:system:set enabledPreviewProviders 3 --value 'OC\Preview\BMP'
occ config:system:set enabledPreviewProviders 4 --value 'OC\Preview\XBitmap'
occ config:system:set enabledPreviewProviders 5 --value 'OC\Preview\MarkDown'
occ config:system:set enabledPreviewProviders 6 --value 'OC\Preview\MP3'
occ config:system:set enabledPreviewProviders 7 --value 'OC\Preview\TXT'
occ config:system:set enabledPreviewProviders 8 --value 'OC\Preview\Svg'

info "Previews limités aux formats légers (images, texte, audio)."

# ---------------------------------------------------------------------------
# 8. Désactivation des applications inutiles / intrusives
# ---------------------------------------------------------------------------
step "Désactivation des applications non nécessaires"
# Utilise OCC_BIN directement (sans retry) — app absente = warning, pas d'erreur fatale
for app in \
  app_api \
  firstrunwizard \
  nextcloud_announcements \
  privacy \
  support \
  survey_client \
  related_resources \
  recommendations; do
  ${OCC_BIN} app:disable "$app" 2>/dev/null \
    && info "$app désactivé" \
    || warn "$app : non trouvé ou déjà désactivé"
done

# ---------------------------------------------------------------------------
# 9. Thème NXT — Logos, fond d'écran, favicon, CSS personnalisé
# ---------------------------------------------------------------------------
step "Configuration du thème NXT"

# S'assurer que l'app theming est active (activée par défaut)
occ app:enable theming || true

# Installer et activer Custom CSS
if occ app:list --output=plain 2>/dev/null | grep -qE '^theming_customcss$|^\s*theming_customcss\s'; then
    warn "theming_customcss déjà présent — activation"
    occ app:enable theming_customcss || true
else
    echo "[setup] Installation de theming_customcss depuis l'App Store..."
    occ app:install theming_customcss
fi

# Copier les assets vers /tmp pour éviter les problèmes d'encodage des noms de fichiers
cp "/img/Logo.png"                     /tmp/nxt-logo.png
cp "/img/Logo barre de navigation.png" /tmp/nxt-logoheader.png
cp "/img/Arrière plan.webp"            /tmp/nxt-background.webp
cp "/img/Favicon.png"                  /tmp/nxt-favicon.png

# Appliquer le thème (couleur primaire + slogan + images)
occ theming:config color      "#3a3a3c"
occ theming:config slogan     "Infrastructure Nextcloud HA"
occ theming:config logo        /tmp/nxt-logo.png
occ theming:config logoheader  /tmp/nxt-logoheader.png
occ theming:config background  /tmp/nxt-background.webp
occ theming:config favicon     /tmp/nxt-favicon.png

# Désactiver la personnalisation du thème par les utilisateurs
occ config:app:set theming disable-user-theming --value "yes"

# Appliquer le CSS personnalisé (login page + éléments globaux)
occ config:app:set theming_customcss customcss --value "$(cat /nxt-custom.css)"

info "Thème NXT configuré (logos, fond, favicon, CSS, user-theming désactivé)."

# ---------------------------------------------------------------------------
# 10. Maintenance finale
# ---------------------------------------------------------------------------
step "Maintenance et optimisation finale"
occ maintenance:repair --include-expensive
occ db:add-missing-indices
occ db:add-missing-primary-keys
occ db:convert-filecache-bigint --no-interaction

# ---------------------------------------------------------------------------
# 11. Purge des logs de démarrage
# Les erreurs Redis (Connection refused / Couldn't map cluster keyspace) sont
# normales pendant les premières secondes avant que le cluster soit initialisé.
# On les supprime ici pour ne pas polluer les logs applicatifs.
# ---------------------------------------------------------------------------
step "Purge des logs de démarrage (erreurs Redis au boot)"
log_file=$(${OCC_BIN} config:system:get logfile 2>/dev/null || echo "/var/www/html/data/nextcloud.log")
if [ -f "${log_file}" ]; then
    : > "${log_file}"
    info "Journal Nextcloud purgé."
fi

# ---------------------------------------------------------------------------
# Résumé
# ---------------------------------------------------------------------------
step "Setup Nextcloud terminé avec succès !"
echo "[setup]  Redis Cluster  : redis-node1..6:6379 (3 masters, 3 replicas)"
echo "[setup]  Collabora      : https://${COLLABORA_DOMAIN}"
echo "[setup]  Whiteboard     : https://${WHITEBOARD_DOMAIN}"
echo "[setup]  Nextcloud      : https://${NEXTCLOUD_DOMAIN}"
