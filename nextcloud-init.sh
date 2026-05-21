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
# Sentinel — évite la ré-exécution complète si le container redémarre après
# un setup réussi. Supprimer le fichier pour forcer une ré-exécution.
# ---------------------------------------------------------------------------
SENTINEL="/var/www/html/data/.setup-done"
if [ -f "${SENTINEL}" ]; then
    info "Setup déjà effectué le $(cat ${SENTINEL}) — arrêt."
    info "Supprimez ${SENTINEL} pour forcer une ré-exécution."
    exit 0
fi

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
# IMPORTANT : "redis cluster seeds N" (espaces) crée $config['redis']['cluster']['seeds'][N]
# "redis.cluster seeds N" (point) crée $config['redis.cluster']['seeds'][N] — clé littérale
# que RedisFactory ne lit pas → "Redis cluster config is missing the seeds attribute"
occ config:system:set redis cluster seeds 0 --value "redis-node1:6379"
occ config:system:set redis cluster seeds 1 --value "redis-node3:6379"
occ config:system:set redis cluster seeds 2 --value "redis-node5:6379"
occ config:system:set redis cluster password       --value "${REDIS_PASSWORD}"
occ config:system:set redis cluster timeout        --type float   --value 5.0
occ config:system:set redis cluster read_timeout   --type float   --value 5.0

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

if ! ${OCC_BIN} app:enable richdocuments 2>/dev/null; then
    echo "[setup] Téléchargement depuis le Nextcloud App Store..."
    occ app:install richdocuments
else
    info "richdocuments déjà présent — activé"
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

if ! ${OCC_BIN} app:enable whiteboard 2>/dev/null; then
    echo "[setup] Téléchargement depuis le Nextcloud App Store..."
    occ app:install whiteboard
else
    info "whiteboard déjà présent — activé"
fi

occ config:app:set whiteboard collabBackendUrl --value "https://${WHITEBOARD_DOMAIN}"
occ config:app:set whiteboard jwt_secret_key   --value "${WHITEBOARD_JWT_SECRET}"
occ config:app:set whiteboard jwt_expiry       --value "86400"

info "Whiteboard configuré → https://${WHITEBOARD_DOMAIN}"

# Patch WhiteboardContentService — bug MinIO objectstore (fichier initialisé avec 1 octet)
# Avec le backend S3/MinIO, les nouveaux fichiers .whiteboard reçoivent 1 octet au lieu
# de vide. La vérification === '' est en strict equality et ne le détecte pas →
# json_decode() lève une JsonException. On ajoute trim() === '' et un try/catch.
# Upstream : https://github.com/nextcloud/whiteboard/issues/XXX
WB_SERVICE="/var/www/html/apps/whiteboard/lib/Service/WhiteboardContentService.php"
if [ -f "${WB_SERVICE}" ]; then
    php <<'PHPEOF'
<?php
$file = '/var/www/html/apps/whiteboard/lib/Service/WhiteboardContentService.php';
$content = file_get_contents($file);

$old = "\tpublic function getContent(File \$file): array {\n"
     . "\t\t\$fileContent = \$file->getContent();\n"
     . "\t\tif (\$fileContent === '') {\n"
     . "\t\t\t\$fileContent = '{\"elements\":[],\"scrollToContent\":true}';\n"
     . "\t\t}\n"
     . "\n"
     . "\t\treturn json_decode(\$fileContent, true, 512, JSON_THROW_ON_ERROR);\n"
     . "\t}";

$new = "\tpublic function getContent(File \$file): array {\n"
     . "\t\t\$fileContent = \$file->getContent();\n"
     . "\t\tif (\$fileContent === '' || trim(\$fileContent) === '') {\n"
     . "\t\t\t\$fileContent = '{\"elements\":[],\"scrollToContent\":true}';\n"
     . "\t\t}\n"
     . "\n"
     . "\t\ttry {\n"
     . "\t\t\treturn json_decode(\$fileContent, true, 512, JSON_THROW_ON_ERROR);\n"
     . "\t\t} catch (\\JsonException \$e) {\n"
     . "\t\t\treturn ['elements' => [], 'files' => [], 'scrollToContent' => true];\n"
     . "\t\t}\n"
     . "\t}";

if (strpos($content, $old) !== false) {
    copy($file, $file . '.bak');
    file_put_contents($file, str_replace($old, $new, $content));
    echo "[setup] Patch WhiteboardContentService appliqué (bug MinIO 1-octet)\n";
} else {
    echo "[setup] WhiteboardContentService: pattern non trouvé — déjà patché ou version différente\n";
}
PHPEOF
else
    warn "WhiteboardContentService.php introuvable — patch ignoré"
fi

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
occ config:system:set maintenance_window_start --type integer --value 1

# Vider le dossier skeleton — aucun fichier exemple créé pour les nouveaux comptes
occ config:system:set skeletondirectory --value ''

# Sécurité / UX
# Autoriser Nextcloud à appeler sa propre URL (IPs locales Docker) — requis pour le check .well-known
occ config:system:set allow_local_remote_servers --type boolean --value true

occ config:system:set upgrade.disable-web      --type boolean --value true
occ config:system:set simpleSignUpLink.shown   --type boolean --value false

# Masquer les liens Aide et Confidentialité dans le menu utilisateur
occ config:system:set knowledgebaseenabled --type boolean --value false

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
  recommendations \
  updatenotification; do
  ${OCC_BIN} app:disable "$app" 2>/dev/null \
    && info "$app désactivé" \
    || warn "$app : non trouvé ou déjà désactivé"
done

# Purge des cron jobs orphelins — occ app:disable ne les retire pas de oc_jobs,
# ce qui génère des warnings QueryNotFoundException à chaque exécution du cron.
# Heredoc single-quoté : aucune expansion bash, LEFT() évite les pb d'échappement LIKE+backslash.
php <<'PHPCLEAN' 2>/dev/null || warn "Nettoyage des cron jobs orphelins ignoré"
<?php
require_once '/var/www/html/lib/base.php';
$db = \OC::$server->getDatabaseConnection();
$prefixes = [
    'OCA\AppAPI\\',
    'OCA\FirstRunWizard\\',
    'OCA\NextcloudAnnouncements\\',
    'OCA\Support\\',
    'OCA\UpdateNotification\\',
    'OCA\RelatedResources\\',
    'OCA\Recommendations\\',
    'OCA\SurveyClient\\',
];
$total = 0;
foreach ($prefixes as $p) {
    $total += (int)$db->executeStatement(
        'DELETE FROM oc_jobs WHERE LEFT(class, ?) = ?',
        [strlen($p), $p]
    );
}
echo '[setup] ' . $total . ' cron job(s) orphelin(s) supprimé(s)' . PHP_EOL;
PHPCLEAN

# ---------------------------------------------------------------------------
# 9. Thème NXT — Logos, fond d'écran, favicon, CSS personnalisé
# ---------------------------------------------------------------------------
step "Configuration du thème NXT"

# Attendre que le cluster Redis soit pleinement opérationnel (cluster_state:ok).
# fsockopen ne suffit pas — le port peut être ouvert mais le cluster en LOADING.
info "Attente cluster Redis (cluster_state:ok)..."
redis_ok=0
for _attempt in $(seq 1 30); do
    # Interroge CLUSTER INFO via socket raw (pas de PHP Redis, pas de bootstrap NC)
    # stream_set_timeout évite que fgets() bloque indéfiniment après les données CLUSTER INFO
    # (la socket reste ouverte après la réponse → feof() ne revient jamais sans timeout)
    _state=$(php -r '
        $fp = @fsockopen("redis-node1", 6379, $e, $m, 5);
        if (!$fp) { exit(1); }
        stream_set_timeout($fp, 3);
        $pass = getenv("REDIS_PASSWORD");
        fwrite($fp, "*2\r\n$4\r\nAUTH\r\n$" . strlen($pass) . "\r\n" . $pass . "\r\n");
        fgets($fp, 128);
        fwrite($fp, "*2\r\n$7\r\nCLUSTER\r\n$4\r\nINFO\r\n");
        $buf = ""; $lines = 0;
        while ($lines < 30) {
            $line = fgets($fp, 256);
            if ($line === false) break;
            $buf .= $line;
            $lines++;
            if (stream_get_meta_data($fp)["timed_out"]) break;
        }
        fclose($fp);
        echo strpos($buf, "cluster_state:ok") !== false ? "ok" : "loading";
    ' 2>/dev/null)
    if [ "${_state}" = "ok" ]; then
        redis_ok=1
        info "Redis cluster opérationnel (tentative ${_attempt})"
        break
    fi
    warn "Redis cluster pas encore ok (tentative ${_attempt}/30, état: ${_state:-unreachable}), attente 5s..."
    sleep 5
done
[ $redis_ok -eq 0 ] && warn "Redis cluster non confirmé après 150s — theming continuera"

# S'assurer que l'app theming est active (activée par défaut)
occ app:enable theming || true

# Installer et activer Custom CSS
if ! ${OCC_BIN} app:enable theming_customcss 2>/dev/null; then
    echo "[setup] Installation de theming_customcss depuis l'App Store..."
    occ app:install theming_customcss
else
    info "theming_customcss déjà présent — activé"
fi

# Copier les assets vers /tmp pour éviter les problèmes d'encodage des noms de fichiers
cp "/img/Logo.png"                     /tmp/nxt-logo.png
cp "/img/Logo barre de navigation.png" /tmp/nxt-logoheader.png
cp "/img/Arrière plan.webp"            /tmp/nxt-background.webp
cp "/img/Favicon.png"                  /tmp/nxt-favicon.png

# Appliquer le thème — non-bloquant : si Redis est instable au moment du theming
# le setup continue quand même (le thème sera incomplet mais NC fonctionnera).
theming() { timeout 30s ${OCC_BIN} theming:config "$@" 2>&1 && return 0; warn "theming:config $* ignoré (timeout ou Redis instable)"; return 0; }
theming name       "NXT Maxscale"
theming color      "#3a3a3c"
theming slogan     "Infrastructure Nextcloud HA"
theming logo        /tmp/nxt-logo.png
theming logoheader  /tmp/nxt-logoheader.png
theming background  /tmp/nxt-background.webp
theming favicon     /tmp/nxt-favicon.png

# Désactiver la personnalisation du thème par les utilisateurs
${OCC_BIN} config:app:set theming disable-user-theming --value "yes" 2>/dev/null || true

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
# Marquer le setup comme terminé pour éviter les ré-exécutions
date '+%Y-%m-%d %H:%M:%S' > "${SENTINEL}"
info "Sentinel créé : ${SENTINEL}"

step "Setup Nextcloud terminé avec succès !"
echo "[setup]  Redis Cluster  : redis-node1..6:6379 (3 masters, 3 replicas)"
echo "[setup]  Collabora      : https://${COLLABORA_DOMAIN}"
echo "[setup]  Whiteboard     : https://${WHITEBOARD_DOMAIN}"
echo "[setup]  Nextcloud      : https://${NEXTCLOUD_DOMAIN}"
