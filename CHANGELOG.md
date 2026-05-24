# Changelog

Toutes les modifications notables de ce projet sont documentées dans ce fichier.

Format : [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/) — versionnage [Semantic Versioning](https://semver.org/lang/fr/).

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

[2.1.8]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.7...v2.1.8
[2.1.7]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.6...v2.1.7
[2.1.6]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.5...v2.1.6
[2.1.5]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.4...v2.1.5
[2.1.4]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.3...v2.1.4
[2.1.3]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.2...v2.1.3
[2.1.2]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.1...v2.1.2
[2.1.1]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/oboeglen/Azure-NXT-Maxscale/releases/tag/v2.1.0
