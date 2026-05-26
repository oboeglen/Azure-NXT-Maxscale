# Changelog

Toutes les modifications notables de ce projet sont documentées dans ce fichier.

Format : [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/) — versionnage [Semantic Versioning](https://semver.org/lang/fr/).

---

## [2.1.15] — 2026-05-26

### Fixed
- **Permissions Nextcloud incorrectes au premier déploiement** — le service `nextcloud-perms` utilisait `command:` avec `user: root`, mais l'entrypoint de l'image `nextcloud:fpm` exécute `run_as()` qui réduit les privilèges vers `www-data` avant d'exécuter la commande. En résultat, `chown` échouait silencieusement sur un serveur vierge, laissant les volumes en `root:root` et bloquant `nextcloud-setup`. Corrigé en remplaçant `command:` par `entrypoint: ["/bin/sh", "-c", "chown ..."]` pour contourner l'entrypoint natif

### Changed
- **Images Docker — versions figées** — tous les tags `:latest` et `:stable` remplacés par des versions précises extraites de la production : `certbot/certbot:v5.6.0`, `minio/minio:RELEASE.2025-09-07T16-13-09Z`, `minio/mc:RELEASE.2025-08-13T08-35-41Z`, `collabora/code:25.04.9.4`, `ghcr.io/georgmangold/console:v1.9.1`, `willfarrell/autoheal` et `ghcr.io/nextcloud-releases/whiteboard` épinglés par digest SHA256. Versions centralisées dans des variables `IMG_*` en tête de script

---

## [2.1.14] — 2026-05-25

### Fixed
- **Patch Collabora non appliqué aux nouveaux nœuds lors d'un scale-up** — `patch_collabora_binary` extrayait toujours le binaire depuis `collabora-node1`, qui est déjà patché depuis le déploiement initial. Au scale-up (ex. 3→6 nœuds), le re-patch du binaire déjà patché échouait en `pattern_not_found` et les nouveaux nœuds (4–6) ne recevaient jamais le patch. `patch_collabora_binary` accepte maintenant un paramètre `first_src` (premier nœud à utiliser pour l'extraction) et `scale_nodes` passe `ORIG_COLLAB_NODES + 1`, garantissant que l'extraction se fait depuis un nouveau nœud au binaire non patché

## [2.1.13] — 2026-05-25

### Fixed
- **Patch binaire Collabora — faux positifs "already_patched"** — deux types de faux positifs empêchaient le patch de s'appliquer sur coolwsd 25.04.9.4 :
  - La séquence `ORIG_PATCHED` (`ba ff ff ff 7f b8 ff ff ff 7f 84 db`) existe naturellement dans le binaire à une adresse différente (0x269fcf), déclenchant une fausse détection "déjà patché" avant même de chercher le pattern cible
  - 21 paires `MOV reg, INT_MAX + MOV reg, INT_MAX` (valeur naturelle dans le binaire) déclenchaient une fausse détection globale
  - La stratégie "(MOV 20 + MOV 20) + TEST" génère 56 faux positifs et était susceptible de patcher de mauvais emplacements sur un re-run
  **Corrections** : suppression de toute recherche globale de "déjà patché" ; le check est uniquement effectué aux offsets précis trouvés par les stratégies ; suppression de la stratégie (20+20) et de la recherche en ordre inversé (10→20)

## [2.1.12] — 2026-05-25

### Fixed
- **Patch binaire Collabora non fonctionnel sur certaines versions de coolwsd** — l'algorithme de recherche était limité à un unique pattern d'octets codé en dur (`mov edx,20 / mov eax,10 / test bl,bl`), spécifique à un seul build. Remplacé par une approche à 4 stratégies successives, indépendante de la version :
  1. Pattern exact original (rétro-compatibilité)
  2. Toutes les combinaisons de registres x86-64 pour `(MOV r32, 20) + (MOV r32, 10)` avec vérification `TEST`/`CMP` à proximité
  3. Idem pour `(MOV r32, 20) + (MOV r32, 20)` (quand les deux limites valent 20)
  4. Ancrage sur la chaîne `"home_mode.enable"` dans le binaire puis recherche de paires de petites constantes dans le code voisin
  La détection « déjà patché » est aussi généralisée (plus liée au pattern exact)

## [2.1.11] — 2026-05-25

### Fixed
- **Race condition Redis scale-up — replica non intégré** — après l'ajout d'un nœud master via `--cluster add-node`, le nœud n'était pas encore visible dans `cluster nodes` lors de l'appel immédiat suivant pour ajouter le replica (`--cluster-slave --cluster-master-id`), provoquant un échec silencieux (redis-node8 absent du cluster). `_redis_scale_up` attend désormais jusqu'à 30 s que le master soit visible dans `cluster nodes` avant d'ajouter le replica. Si `--cluster add-node --cluster-slave` échoue malgré tout, un fallback `MEET + REPLICATE` est tenté. Un contrôle final compare `cluster_known_nodes` au compte attendu et avertit en cas d'écart

## [2.1.10] — 2026-05-25

### Fixed
- **MinIO crash loop sur scale répété** — `_minio_register_pool` n'avait pas de vérification de doublon ; si le cache de configuration était périmé, le même pool (`start:end`) était ajouté deux fois dans `.minio-pools`, ce qui provoquait un `FATAL Invalid command line arguments: duplicate endpoints found` au démarrage de MinIO. Un dedup par `grep -qF` empêche désormais l'ajout du même pool deux fois
- **ORIG_MINIO_NODES périmé depuis le cache** — `scale_nodes()` charge le cache puis vérifie le nombre de containers réellement actifs ; si le count réel est supérieur au cache, MINIO_NODES est corrigé avant d'être mémorisé comme ORIG_MINIO_NODES (protection contre les double-registrations)
- **HAProxy /stats perdu après reboot** — `HAPROXY_STATS` n'était pas écrit dans `.env` (seulement dans le cache transient `/tmp/`) ; après un reboot, la reconstruction depuis `.env` le fixait à `no` par défaut, désactivant la page de statistiques. `HAPROXY_STATS` est désormais persisté dans `.env` et relu dans le chemin de reconstruction
- **`wait_healthy` bloqué sur containers en crash loop** — des containers en état `restarting` (ex. MinIO avec pool dupliqué) maintenaient `all_healthy=false` indéfiniment jusqu'au timeout. Après 3 redémarrages consécutifs, un container est désormais marqué « crash loop », exclu du wait et un avertissement est affiché ; les autres containers continuent d'être attendus normalement

## [2.1.9] — 2026-05-25

### Added
- **Scaling interactif** — `deploy.sh` propose un menu « Augmenter / réduire les nœuds » lorsqu'une stack est déjà déployée. Toutes les données sont préservées ; seuls les fichiers de configuration sont régénérés
  - **Nextcloud FPM+nginx** — ajout/suppression de paires de nœuds en hot
  - **MariaDB Galera** — scale-up via SST automatique, scale-down via `--remove-orphans` (quorum maintenu)
  - **Redis Cluster** — scale-up avec intégration cluster (`add-node`, `--cluster-slave`, `rebalance`) et scale-down avec migration des slots avant retrait (`reshard`, `del-node`, `rebalance`)
  - **Collabora CODE** — ajout/suppression de nœuds ; patch binaire `home_mode` automatiquement réappliqué sur les nouveaux nœuds
  - **Whiteboard** — ajout/suppression de nœuds
  - **MinIO** — scale-up par expansion de pool (multi-pool MNMD) via `.minio-pools` ; scale-down non supporté par MinIO (renvoi vers `mc admin decommission`)
- Fonction `gen_minio_server_cmd()` — commande `server` MinIO construite dynamiquement depuis `.minio-pools` (multi-pool transparent)
- Fichier `.minio-pools` — trace l'historique des pools MinIO (format `start:end` par ligne), utilisé pour reconstruire la commande `server` après un redémarrage
- `MINIO_MODE` et `MINIO_BYPASS` persistés dans `.env` (étaient uniquement dans le cache transient `/tmp/`) — reconstruits correctement après un reboot sans cache

### Fixed
- Healthcheck `nextcloud-cron` cassé — `pgrep` absent de l'image `nextcloud:33.0.3-fpm` ; remplacé par `grep -qa cron /proc/1/cmdline`
- Redis scale-up : `master_id` via grep hostname échouait (`cluster nodes` affiche des IPs, pas des hostnames) — remplacé par `cluster myid` directement sur le nouveau nœud
- Redis scale-up : slot en état `migrating` bloquait l'ajout de la réplica — ajout d'un `--cluster fix` avant `--cluster rebalance`
- Redis scale-down : slots non rééquilibrés après retrait (un master héritait de tous les slots) — ajout de `--cluster fix` + `rebalance` en fin de `_redis_scale_down`
- HAProxy reload après scaling : remplacé `kill -USR2 1` (graceful, nouveaux backends inactifs pour trafic en cours) par `docker compose restart haproxy` (nouveaux backends actifs immédiatement)

### Changed
- Menu principal `deploy.sh` : 3 options sur stack existante — mise à jour rapide · scaling · déploiement complet
- HAProxy reload après scaling : `docker compose restart haproxy` au lieu de `SIGUSR2`

---

## [2.1.8] — 2026-05-24

### Fixed
- Ordre de configuration Redis dans `nextcloud-init.sh` corrigé — les seeds `redis.cluster` sont désormais définis **avant** `memcache.distributed` et `memcache.locking`, ce qui élimine les avertissements « Aucun cache mémoire » et « Verrouillage de fichiers transactionnels » dans l'interface d'administration Nextcloud

### Changed
- README : tableau de persistance du patch Collabora mis à jour — le mode mise à jour rapide de `deploy.sh` réapplique le patch automatiquement après pull des images

---

## [2.1.7] — 2026-05-24

### Added
- Mode mise à jour rapide dans `deploy.sh` — si une stack est déjà active dans `$INSTALL_DIR`, le script propose en priorité de ne mettre à jour que les images (`docker compose pull` + `docker compose up -d`) sans régénérer la configuration, suivi d'un réapplication automatique du patch binaire Collabora et d'une vérification `wait_healthy`
- Détection automatique du nombre de nœuds depuis les containers en cours si le cache de configuration est absent

---

## [2.1.6] — 2026-05-24

### Fixed
- Volumes `letsencrypt` et `certbot_webroot` déclarés `external: true` dans `docker-compose.yml` généré — supprime le warning `volume already exists but was not created by Docker Compose` au démarrage
- En mode staging, `${COMPOSE_PROJECT_NAME}_letsencrypt` est désormais toujours pré-créé par `gen_certs()` pour que le container certbot de renouvellement trouve son volume

### Changed
- README : persistance du patch binaire Collabora documentée — tableau scénarios crash / `docker restart` / recreate / `down+up` / mise à jour image

---

## [2.1.5] — 2026-05-24

### Added
- Patch binaire automatique de `coolwsd` dans `deploy.sh` — fonction `patch_collabora_binary()` qui supprime la limite `home_mode` (20 connexions / 10 documents par nœud) en recherchant dynamiquement le pattern `mov edx,20 / mov eax,10` dans le binaire et en le remplaçant par `INT_MAX` sur l'ensemble des nœuds Collabora configurés

### Changed
- Collabora ne limite plus le nombre de connexions et documents simultanés — le patch est appliqué automatiquement après `docker compose up -d`, sur tous les nœuds (`COLLAB_NODES`), sans toucher à `extra_params` ni à `home_mode.enable=true`
- Estimation de charge `deploy.sh` : la ligne `home_mode N×20 / N×10` est remplacée par `connexions/documents illimités (patch binaire home_mode)`
- Version du déployeur : v2.1.5
- README : section Collabora CODE mise à jour pour refléter la suppression de la limite

---

## [2.1.4] — 2026-05-22

### Fixed
- Incohérence du nom de projet Docker Compose corrigée dans `deploy.sh` (le nom généré pouvait diverger selon le répertoire de travail)

---

## [2.1.3] — 2026-05-22

### Fixed
- `--post-hook` certbot cassé par une indentation YAML incorrecte dans le `docker-compose.yml` généré — le certificat HAProxy n'était pas reconstruit après renouvellement

---

## [2.1.2] — 2026-05-22

### Added
- Politique de divulgation responsable (`SECURITY.md`)
- Monitoring des nœuds FPM Nextcloud dans la page de statistiques HAProxy (`listen nextcloud-fpm`)
- Estimations Collabora `home_mode` (20 connexions / 10 documents par nœud) affichées dans le récapitulatif `deploy.sh`

### Fixed
- `no option forwardfor` invalide sur `listen nextcloud-fpm` en mode TCP supprimé — erreur de démarrage HAProxy
- Blocage au clonage Git dans `deploy.sh` résolu (conflit stdin/TTY lors du clone non-interactif)
- OPcache preload supprimé — provoquait une `fatal error` au démarrage de Nextcloud

### Changed
- Badges README migrés de Simple Icons CDN (bloqué par le proxy camo de GitHub) vers shields.io `for-the-badge`

---

## [2.1.1] — 2026-05-21

### Added
- Console web MinIO optionnelle accessible via `/s3-console` (image `ghcr.io/georgmangold/console`) — activable dans `deploy.sh`, sans port supplémentaire exposé
- Thème de connexion MAXSCALE graphite : CSS personnalisé (`nxt-custom.css`), logo et fond d'écran
- Estimation de capacité de charge affichée après le récapitulatif de configuration (modèle calé sur les mesures réelles)
- Benchmarks de performance et tables de dimensionnement par profil d'usage dans le README
- Résultats du test de charge PME 500 utilisateurs quotidiens (k6 v0.55, 34 VUs, 3 911 requêtes, 0 erreur 5xx)

### Fixed
- Vérification du cluster Redis robustifiée — `fsockopen` au lieu de `OC::$server`, timeouts explicites, non-bloquant
- Expiration JWT Whiteboard portée à 24 h (était 15 min — causait des déconnexions en session longue)
- Gestion des fichiers stub MinIO 1 octet dans `WhiteboardContentService` (`patch_wb.py`)
- Filtre WebDAV HAProxy étendu : `PUT` sur `/apps/whiteboard`, `PUT`/`DELETE` sur `/s3-console`
- Redirection automatique `/s3-console` et `/s3-console/` vers `/s3-console/login`
- Strip du préfixe `/s3-console` dans HAProxy avant forward vers `minio-console:9090` — corrigeait les erreurs MIME sur les assets React
- Détection du cluster Redis corrigée avec la clé littérale `redis.cluster` dans `occ`
- Crash de `nextcloud-setup` sur `Permission denied` lors de la purge de `nextcloud.log`
- Bootstrap Galera : entrypoint compatible `mariadbd`, double-mysqld et syntaxe YAML `&&` corrigés
- Alignement UTF-8 des bandeaux et résumés dans `deploy.sh` (caractères multi-octets)
- Purge des cron orphelins après désactivation d'application dans `nextcloud-init.sh`
- Détection d'application par `app:enable` (idempotent) au lieu du grep fragile sur `app:list`
- Quatre ajustements de configuration Nextcloud appliqués automatiquement (log level, OPcache, etc.)

### Changed
- 6 améliorations de fiabilité non-destructives : OPcache, healthchecks Collabora, seeds Redis, autoheal HC
- Largeur du résumé de déploiement calculée dynamiquement (s'adapte à la ligne la plus longue)
- Couleur de marque Nextcloud alignée sur la palette graphite MAXSCALE

---

## [2.1.0] — 2026-05-20

Version majeure — refonte complète de l'architecture vers une stack FPM + MinIO.

### Added
- **Nextcloud PHP-FPM** avec nginx en proxy FastCGI (remplacement du mode Apache)
- **MinIO S3 distribué** en erasure coding (remplacement de RustFS) — versioning de bucket activé automatiquement
- **Redis Cluster** distribué (≥ 6 nœuds masters + réplicas)
- **Collabora CODE** — édition bureautique collaborative (Writer, Calc, Impress) en `home_mode`
- **Whiteboard** — tableau blanc collaboratif temps réel (WebSocket + Redis Streams)
- Service `galera-autoheal` — redémarrage automatique des nœuds Galera hors-sync
- Service `nextcloud-perms` — correction des permissions sur les volumes avant installation
- Service `nextcloud-setup` — auto-configuration post-installation (protégé par sentinel, one-shot)
- `nextcloud-custom.config.php` monté en `:ro` dans tous les conteneurs — corrige `.well-known/caldav` et `.well-known/carddav`, force HTTPS permanent
- Validation de la configuration HAProxy avant déploiement (dry-run)
- Healthcheck `wsrep_ready` sur les nœuds Galera + `safe_to_bootstrap` géré automatiquement par `galera-bootstrap.sh`
- Silençage des health checks dans les logs HAProxy (`/status.php`, `/robots.txt`, `/favicon.ico`) — ~80 % de réduction du bruit
- Blocage de la console d'administration Collabora via HAProxy (HTTP 403)
- Filtrage des méthodes WebDAV restreint aux chemins API (`/remote.php`, `/public.php`, `/ocs`)
- Blocage des user-agents scanners (sqlmap, nikto, nmap, masscan, zgrab) et des paths de scan courants
- Protection anti-Slowloris (abandon de requête après 10 s)
- HSTS 2 ans avec `includeSubDomains` et `preload`
- TLS 1.2 minimum, TLS 1.3 préféré, `no-tls-tickets` (Perfect Forward Secrecy)

### Fixed
- Types MIME `mjs`, en-tête `X-Robots-Tag`, conteneur `nextcloud-cron` absent
- CSP `unsafe-inline` et types MIME JS pour Collabora CODE
- Règle MIME Collabora déplacée après la définition ACL (le parsing HAProxy est séquentiel)
- `IFS` word-split sur l'installation des paquets dans `deploy.sh`
- Variable `REDIS_NODES` superflue supprimée de l'environnement

---

[2.1.15]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.14...v2.1.15
[2.1.14]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.13...v2.1.14
[2.1.13]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.12...v2.1.13
[2.1.12]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.11...v2.1.12
[2.1.11]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.10...v2.1.11
[2.1.10]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.9...v2.1.10
[2.1.9]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.8...v2.1.9
[2.1.8]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.7...v2.1.8
[2.1.7]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.6...v2.1.7
[2.1.6]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.5...v2.1.6
[2.1.5]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.4...v2.1.5
[2.1.4]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.3...v2.1.4
[2.1.3]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.2...v2.1.3
[2.1.2]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.1...v2.1.2
[2.1.1]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/oboeglen/Azure-NXT-Maxscale/releases/tag/v2.1.0
