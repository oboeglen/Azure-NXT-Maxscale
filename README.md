<div align="center">

![Azure NXT Maxscale](NXTMAXSCALE.png)

# Azure NXT Maxscale

**Infrastructure Nextcloud haute disponibilité — déployable en une commande**

[![Version](https://img.shields.io/badge/version-2.0.0-blue)](https://github.com/oboeglen/Azure-NXT-Maxscale/releases/tag/v2.0.0)
[![Nextcloud](https://img.shields.io/badge/Nextcloud-33-0082C9)](https://nextcloud.com)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

*Debian · Ubuntu · RHEL · Rocky Linux · AlmaLinux — x86\_64*

</div>

---

## Déploiement en une commande

```bash
curl -fsSL https://raw.githubusercontent.com/oboeglen/Azure-NXT-Maxscale/main/deploy.sh \
  -o /tmp/deploy.sh && sudo bash /tmp/deploy.sh
```

Le script détecte votre OS, installe Docker si absent, pose les questions essentielles et déploie l'infrastructure complète. La configuration est sauvegardée et réutilisable si vous relancez.

---

## Ce que fait `deploy.sh`

| Étape | Action |
|-------|--------|
| ① | Vérification RAM (≥ 16 Go), disque (≥ 50 Go), Docker ≥ 20 |
| ② | Détection OS et installation automatique de Docker |
| ③ | Clone du repo depuis GitHub |
| ④ | Questions interactives — domaines, nœuds, disques MinIO, certificats |
| ⑤ | Génération de tous les mots de passe (aucun `#` dans Redis) |
| ⑥ | Génération du `.env`, `docker-compose.yml`, configs Galera |
| ⑦ | Vérification DNS + certificats SSL Let's Encrypt (HTTP-01 / TLS-ALPN-01) |
| ⑧ | Pull des images Docker en parallèle |
| ⑨ | Déploiement avec suivi en temps réel (timeout adaptatif) |
| ⑩ | Vérification de tous les services + test d'accès + affichage des identifiants |

**Contraintes appliquées automatiquement**

- MariaDB : nœuds en nombre impair (quorum Galera)
- Redis Cluster : nombre pair ≥ 6 (masters + replicas)
- MinIO : tolérance aux pannes calculée et expliquée selon votre choix
- Nextcloud attend que Galera soit SYNCED avant de démarrer (vérification WSREP via PDO PHP)

---

## Architecture

```
Internet ──► HAProxy (80/443)
              │
              ├── next-net (172.10.0.0/24)
              │     ├── nginx-next-01..N    — nginx (reverse proxy FPM, fichiers statiques)
              │     ├── app-next-01..N      — Nextcloud FPM (PHP-FPM, 1 par nginx)
              │     ├── nextcloud-cron      — Tâches de fond (cron.php / 5 min)
              │     ├── redis-node1..N      — Redis Cluster (pair ≥ 6)
              │     └── nginx-acme          — Challenge Let's Encrypt
              │
              ├── galera-net (172.30.0.0/24)
              │     └── mariadb-node1/...   — MariaDB Galera (impair)
              │
              ├── storage-net (172.20.0.0/24) + minionet (172.50.0.0/24)
              │     └── minio-node1..N      — MinIO S3 (N nœuds × D drives)
              │
              ├── collabora-net (172.40.0.0/24)
              │     └── collabora-node1/... — Collabora Online CODE
              │
              └── whiteboard-net (172.100.0.0/24)
                    ├── whiteboard-node1/... — Tableau blanc collaboratif
                    └── redis-whiteboard     — Redis dédié (Streams)
```

> Seul HAProxy expose des ports vers l'extérieur (80, 443). Tous les fichiers sont stockés dans MinIO. La chute d'un nœud est **transparente** pour l'utilisateur.

**Flux d'une requête Nextcloud :**
```
Client → HAProxy (SSL) → nginx-next-0X (statique) → app-next-0X (PHP-FPM :9000)
```

---

## Prérequis

| Composant | Requis |
|-----------|--------|
| OS | Debian 11/12/13 · Ubuntu 22.04/24.04 · RHEL / Rocky / AlmaLinux 8/9 |
| Architecture | x86_64 |
| CPU | 8 cœurs minimum |
| RAM | 16 Go minimum |
| Disque | 500 Go SSD (selon usage) |
| DNS | 3 sous-domaines pointant vers le serveur **avant** le lancement |
| Ports | 80 et 443 libres pour la génération des certificats |

> Docker et Docker Compose sont installés automatiquement s'ils sont absents.

---

## Services déployés

| Service | Image | Rôle |
|---------|-------|------|
| `haproxy` | `haproxy:2.8-alpine` | Reverse proxy, SSL, load balancer |
| `nginx-acme` | `nginx:1.27-alpine` | Challenge ACME Let's Encrypt |
| `certbot` | `certbot/certbot` | Renouvellement SSL automatique (12h) |
| `nginx-next-01..N` | `nginx:1.27-alpine` | Serving statique + proxy FastCGI vers FPM |
| `app-next-01..N` | `nextcloud:X.Y.Z-fpm` | Application Nextcloud (PHP-FPM) |
| `nextcloud-setup` | `nextcloud:X.Y.Z-fpm` | Auto-configuration post-install (one-shot) |
| `nextcloud-cron` | `nextcloud:X.Y.Z-fpm` | Tâches de fond — `cron.php` toutes les 5 min |
| `mariadb-node1..N` | `maxscale-mariadb-galera:11.4` | Base de données répliquée (Galera) |
| `redis-node1..N` | `redis:7.4-alpine` | Cache distribué (Redis Cluster) |
| `redis-cluster-init` | `redis:7.4-alpine` | Initialisation du cluster Redis (one-shot) |
| `minio-node1..N` | `minio/minio:latest` | Stockage objet S3 distribué (erasure coding) |
| `collabora-node1..N` | `collabora/code:latest` | Édition bureautique en ligne |
| `whiteboard-node1..N` | `ghcr.io/nextcloud-releases/whiteboard:stable` | Tableau blanc collaboratif |
| `redis-whiteboard` | `redis:7.4-alpine` | État partagé whiteboard (Redis Streams) |
| `galera-autoheal` | `willfarrell/autoheal` | Redémarrage automatique des nœuds Galera unhealthy |

**Ports exposés :** `80` (→ HTTPS) · `443` (Nextcloud, Collabora, Whiteboard, stats HAProxy sur `/stats`)

---

## Configuration Nextcloud post-installation

Tout est appliqué automatiquement par `nextcloud-setup` au premier démarrage.

**Intégrations**
- Redis Cluster, Collabora Online, Whiteboard, stockage S3 MinIO
- `trusted_proxies` + `forwarded_for_headers` — IPs clients réelles tracées derrière HAProxy

**Sécurité & UX**
- Mises à jour via CLI uniquement — `upgrade.disable-web = true`
- Lien d'inscription masqué sur la page de login
- Dossier skeleton vide — aucun fichier exemple pour les nouveaux comptes
- `allow_local_remote_servers` et `overwriteprotocol` définis dans `nextcloud-custom.config.php` (monté en `:ro` dans tous les conteneurs Nextcloud) — corrige `.well-known/caldav` et force HTTPS permanent

**Performance**
- Cron système — `nextcloud-cron` exécute `cron.php` toutes les 5 minutes
- Previews limitées à 2 048 px, formats légers uniquement (vidéo/Office désactivés)
- Rotation automatique des logs à 100 Mo
- `db:convert-filecache-bigint` en maintenance

**Applications désactivées à l'installation**

`AppAPI` · `First run wizard` · `Nextcloud Announcements` · `Privacy` · `Support` · `Usage Survey` · `Related Resources` · `Recommendations`

**Whiteboard** — limite upload WebSocket : 25 Mo

---

## Haute disponibilité

| Composant | Tolérance | Effet d'une panne |
|-----------|-----------|-------------------|
| Nextcloud | ✅ Automatique | Aucun — HAProxy redispatch instantané |
| MariaDB | ✅ Automatique | Aucun — Galera quorum maintenu (`galera-autoheal` redémarre les nœuds hors-sync) |
| Redis | ✅ Automatique | Aucun — cluster tolère 1 panne par slot |
| MinIO | ✅ Automatique | Lecture continue, écritures rétablies après resync |
| Collabora | ✅ Automatique | Session perdue, reconnexion automatique |
| Whiteboard | ✅ Automatique | Reconnexion WebSocket auto (état Redis partagé) |

---

## Stockage objet MinIO (S3)

MinIO fonctionne en erasure coding distribué — **N nœuds × D drives**.

| Mode | Tolérance |
|------|-----------|
| 4 nœuds × 2 drives | Perte de 1 nœud entier tolérée en écriture |
| 4 nœuds × 4 drives | Perte de 2 nœuds tolérée en lecture |

**Test mono-serveur** — tous les chemins sur le même disque (`/data/minio/...`), option automatique dans `deploy.sh`.

**Production** — chaque `DATA{D}` doit pointer vers un disque physique distinct pour que l'erasure coding soit effectif.

### Réparation après panne d'un nœud

```bash
source /opt/nxt-maxscale/.env
STORAGE_NET=$(docker inspect minio-node1 \
  --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' | awk '{print $1}')

docker run --rm --network "$STORAGE_NET" --entrypoint sh minio/mc -c "
  mc alias set r http://minio-node1:9000 ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} --quiet
  mc admin heal -r r/nextcloud
"
```

---

## Sécurité HAProxy

### TLS
- TLS 1.2 minimum, TLS 1.3 préféré
- Suites modernes uniquement — ECDHE + AES-GCM + CHACHA20
- `no-tls-tickets` — parfaite confidentialité persistante (PFS)

### En-têtes HTTP

| En-tête | Valeur |
|---------|--------|
| `Strict-Transport-Security` | 2 ans · includeSubDomains · preload |
| `X-Content-Type-Options` | nosniff |
| `X-XSS-Protection` | 1; mode=block |
| `Referrer-Policy` | strict-origin-when-cross-origin |
| `X-Frame-Options` | SAMEORIGIN (Nextcloud uniquement) |
| `Permissions-Policy` | camera=(self) · microphone=(self) · geolocation=(self) · payment=() |
| `Server`, `X-Powered-By` | Supprimés |

> `camera`, `microphone` et `geolocation` sont autorisés sur `(self)` pour Nextcloud Talk et les apps de géolocalisation.

### Filtrage des requêtes
- **Slowloris** — timeout HTTP-request 10 s
- **Méthodes dangereuses** bloquées — `TRACE`, `DEBUG`, `CONNECT`
- **Méthodes WebDAV** restreintes aux chemins API (`/remote.php`, `/public.php`, `/ocs`) — `OPTIONS` libre pour les preflight CORS
- **User-agents scanners** bloqués — sqlmap, nikto, nmap, masscan, zgrab
- **CSP étendue** — WebSocket autorisé vers Collabora et Whiteboard (`wss://`)

---

## Gestion du cluster MariaDB Galera

### Bootstrap initial ou après panne totale

```bash
# Démarrer le nœud bootstrap en premier
docker compose up -d mariadb-node1

# Une fois node1 healthy, démarrer les autres (SST parallèle)
docker compose up -d mariadb-node2 mariadb-node3
```

### Désactiver le mode bootstrap après synchronisation

Éditer `mariadb/galera-node1.cnf` :

```ini
wsrep_cluster_address = gcomm://mariadb-node1,mariadb-node2,mariadb-node3
```

Puis : `docker compose up -d mariadb-node1`

### Vérifier l'état du cluster

```bash
docker exec mariadb-node1 mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" \
  -e "SHOW GLOBAL STATUS LIKE 'wsrep_cluster%';"
```

---

## Renouvellement SSL

Automatique via `certbot` toutes les 12h. Pour forcer manuellement :

```bash
docker compose exec certbot certbot renew --webroot -w /var/www/certbot
docker compose restart haproxy
```

---

## Déploiement manuel (sans deploy.sh)

<details>
<summary>Voir les étapes</summary>

### 1. Cloner le repo

```bash
git clone https://github.com/oboeglen/Azure-NXT-Maxscale.git
cd Azure-NXT-Maxscale
```

### 2. Configurer l'environnement

```bash
cp .env.example .env
nano .env   # Remplir TOUTES les valeurs
```

### 3. Générer les certificats SSL

> Le DNS doit pointer vers ce serveur avant cette étape.

```bash
source .env
docker run --rm -p 80:80 \
  -v "maxscale_letsencrypt:/etc/letsencrypt" \
  certbot/certbot certonly --standalone --agree-tos --no-eff-email \
  --email "${CERTBOT_EMAIL}" \
  -d "${NEXTCLOUD_DOMAIN}" -d "${COLLABORA_DOMAIN}" -d "${WHITEBOARD_DOMAIN}" \
  --cert-name stack

mkdir -p certs
docker run --rm \
  -v "maxscale_letsencrypt:/etc/letsencrypt:ro" \
  -v "$(pwd)/certs:/certs" \
  alpine sh -c "cat /etc/letsencrypt/live/stack/fullchain.pem \
    /etc/letsencrypt/live/stack/privkey.pem > /certs/stack.pem && chmod 600 /certs/stack.pem"
```

### 4. Créer les répertoires MinIO

```bash
for node in 1 2 3 4; do
  for disk in 1 2 3 4; do
    path=$(grep "^MINIO_NODE${node}_DATA${disk}=" .env | cut -d= -f2)
    mkdir -p "${path}"
  done
done
```

### 5. Démarrer l'infrastructure

```bash
docker compose up -d
docker compose logs -f nextcloud-setup
```

</details>

---

## Performances & dimensionnement

> Benchmarks réalisés sur l'instance de référence (`nxt.azure-informatique.cloud`) — 3 nœuds FPM, Galera 3 nœuds, Redis 6 nœuds, MinIO 4×2 drives — depuis un client externe avec 20 connexions simultanées.

### Résultats mesurés

| Endpoint | Concurrence | Débit | Moy | P95 | P99 | Max | Erreurs |
|---|---|---|---|---|---|---|---|
| `/status.php` (léger) | 20 | **120 req/s** | 156 ms | 365 ms | 388 ms | 389 ms | 0 / 200 |
| `/login` (PHP complet) | 20 | **44 req/s** | 432 ms | 697 ms | 862 ms | 885 ms | 0 / 200 |
| `/status.php` stress | 50 | **247 req/s** | 192 ms | 299 ms | 375 ms | 403 ms | 0 / 500 |
| `/status.php` stress | 100 | **242 req/s** | 369 ms | 494 ms | 522 ms | 548 ms | 0 / 500 |
| `/login` stress | 50 | **60 req/s** | 783 ms | 1 061 ms | 1 154 ms | 1 333 ms | 0 / 300 |
| Stress maximum | 150 | **231 req/s** | 580 ms | 959 ms | 1 059 ms | 1 242 ms | 0 / 600 |

**0 erreur réseau** sur 1 900 requêtes totales. Le système tient à 150 connexions simultanées sans défaillance.

---

### Simulation par nombre de nœuds FPM

> Modèle basé sur les mesures réelles. Rendement décroissant de **88 % par nœud** (ressources partagées : DB, Redis, HAProxy). La base de données Galera 3 nœuds devient le goulot d'étranglement à partir de **7 nœuds FPM** (~1 500 TPS en écriture fixes).

| Nœuds FPM | req/s PHP | req/s léger | Concurrent | Actifs | Total users | P99 PHP | P99 léger | RAM min |
|:---------:|:---------:|:-----------:|:----------:|:------:|:-----------:|:-------:|:---------:|:-------:|
| 1 | ~20 | ~82 | ~18 | ~110 | ~1 100 | 2 356 ms | 765 ms | 11 Go |
| 2 | ~37 | ~154 | ~34 | ~206 | ~2 060 | 1 501 ms | 488 ms | 14 Go |
| **3** ⭐ | **~53** | **~218** | **~48** | **~291** | **~2 910** | **1 154 ms** | **375 ms** | **17 Go** |
| 5 | ~78 | ~324 | ~72 | ~432 | ~4 320 | 827 ms | 269 ms | 23 Go |
| 7 | ~98 | ~405 | ~90 | ~542 | ~5 420 | 665 ms | 216 ms | 29 Go |
| 9 | ~107 | ~443 | ~98 | ~592 | ~5 920 | 565 ms | 183 ms | 35 Go |
| 12 | ~112 | ~461 | ~102 | ~616 | ~6 160 | 468 ms | 152 ms | 44 Go |

> ⭐ Configuration actuelle testée en conditions réelles  
> **Actifs** = concurrent × 6 (sessions ouvertes sur fenêtre 5 min)  
> **Total users** = actifs × 10 (hypothèse 10 % connectés au pic)  
> **RAM min** = 3 Go/nœud FPM + 8 Go overhead (MariaDB, Redis, MinIO, HAProxy)

#### Point de saturation DB

Au-delà de **7 nœuds FPM**, chaque nœud supplémentaire n'apporte que ~5 req/s supplémentaires au lieu de ~20. Pour dépasser 6 000 utilisateurs, le prochain palier est **5 nœuds Galera** (configure `MARIADB_NODES=5` dans `deploy.sh`).

---

### Consommation des ressources par composant

| Composant | RAM typique | CPU (idle) | CPU (charge) | Réseau |
|---|---|---|---|---|
| HAProxy | ~50 Mo | < 1 % | 5–15 % | Tout le trafic |
| nginx (par nœud) | ~30 Mo | < 1 % | 2–5 % | Statique + proxy |
| Nextcloud FPM (par nœud) | 500 Mo – 1 Go | 5 % | 30–60 % | Interne FPM |
| MariaDB Galera (par nœud) | 1–2 Go | 5 % | 20–40 % | Galera replication |
| Redis (par nœud) | 50–200 Mo | < 1 % | 2–5 % | Cluster gossip |
| MinIO (par nœud) | 256–512 Mo | < 1 % | 10–30 % | Erasure coding |
| Collabora CODE (par nœud) | 500 Mo – 1 Go | 2 % | 40–80 % | WOPI + WebSocket |
| Whiteboard (par nœud) | ~100 Mo | < 1 % | 5–10 % | WebSocket |
| galera-autoheal | ~20 Mo | < 1 % | < 1 % | Docker socket |

---

### Recommandations par profil d'usage

| Profil | Nœuds FPM | Nœuds DB | Nœuds Redis | RAM serveur | Users estimés |
|---|---|---|---|---|---|
| 🧪 **Test / dev** | 1 | 1 (sans Galera) | 0 (APCu seul) | 8 Go | < 50 |
| 🏢 **PME — petite équipe** | 2–3 | 3 | 6 | 16–24 Go | 500 – 3 000 |
| 🏭 **Entreprise moyenne** | 5 | 3–5 | 6 | 32–48 Go | 3 000 – 6 000 |
| 🏦 **Grande organisation** | 7–9 | 5 | 6–8 | 64–96 Go | 5 000 – 10 000 |
| ⚠️ **Au-delà** | 12+ | 5+ | 8+ | 128 Go+ | Clustering applicatif requis |

> Pour les profils **Entreprise / Grande organisation**, prévoir des disques physiques dédiés pour MinIO (`MINIO_DISKS=4+`) et un nœud de monitoring séparé (Prometheus + Grafana).

---

## Support

**Projet :** [github.com/oboeglen/Azure-NXT-Maxscale](https://github.com/oboeglen/Azure-NXT-Maxscale)
