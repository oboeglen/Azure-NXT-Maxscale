# Azure NXT Maxscale — Deployment Guide

> **Version:** 2.5.3 · **Script:** `deploy.sh` · **Supported OS:** Debian 11/12 · Ubuntu 22.04/24.04 · RHEL/Rocky/AlmaLinux 8/9

---

## Table of contents

- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Phase 1 — System detection & dependencies](#phase-1--system-detection--dependencies)
- [Phase 2 — Project retrieval](#phase-2--project-retrieval)
- [Phase 3 — Interactive configuration](#phase-3--interactive-configuration)
- [Phase 4 — File generation](#phase-4--file-generation)
- [Phase 5 — SSL certificates](#phase-5--ssl-certificates)
- [Phase 6 — Deployment](#phase-6--deployment)
- [Phase 7 — Functional verification](#phase-7--functional-verification)
- [Post-deployment operations](#post-deployment-operations)
- [Update — pull new images](#update--pull-new-images)
- [Scale — add or remove nodes](#scale--add-or-remove-nodes)
- [Environment variables reference](#environment-variables-reference)

---

## Prerequisites

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| RAM | 16 GB | 32 GB |
| CPU | 4 cores | 8+ cores |
| OS disk | 50 GB | 100 GB |
| Data disks (RustFS) | 2 × any size | 4 × matched sizes |
| OS | Debian 11/12 · Ubuntu 22.04/24.04 · RHEL/Rocky/Alma 8/9 | — |
| Architecture | x86_64 | — |
| Docker | ≥ 20 (installed automatically if absent) | — |
| Network | Public IP · DNS A records pointing to server | — |

**DNS records required before running the script:**

```
nextcloud.domain.tld   A  <server-ip>
office.domain.tld      A  <server-ip>
whiteboard.domain.tld  A  <server-ip>
talk.domain.tld        A  <server-ip>   # only if Talk enabled
```

> [!IMPORTANT]
> Run as **root** or with **sudo**. The script installs system packages, Docker, and configures kernel parameters.

---

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/oboeglen/Azure-NXT-Maxscale/main/deploy.sh \
  -o /tmp/deploy.sh && sudo bash /tmp/deploy.sh
```

Configuration is saved to `/tmp/.nxt-maxscale-config.env` and reused on subsequent runs. Re-running the script on an existing deployment performs a **health check + optional update** without data loss.

---

## Phase 1 — System detection & dependencies

**What happens:**

1. Detects the OS (`/etc/os-release`) and validates it is supported
2. Verifies root privileges
3. Checks RAM (≥ 16 GB), disk space (≥ 50 GB), architecture (x86_64)
4. Installs system packages: `git`, `curl`, `openssl`, `xfsprogs`, `e2fsprogs`, `jq`, `python3`, `dnsutils`
5. Installs **Docker Engine** and **Docker Compose plugin** if not present (via `get.docker.com`)
6. Configures Docker log rotation (`/etc/docker/daemon.json`)
7. Sets kernel parameters for Redis: `vm.overcommit_memory=1`, `net.core.somaxconn=511`

**Key checks:**
- Docker version ≥ 20 (enforced)
- `docker compose` plugin availability (v2 API required)

---

## Phase 2 — Project retrieval

**What happens:**

1. Clones the repository from GitHub to `$INSTALL_DIR` (`/opt/nxt-maxscale`)
2. On re-run: fetches latest changes and resets to `origin/main` (with 120 s timeout)
3. Sets up working directory structure

**Files installed:**
```
/opt/nxt-maxscale/
├── deploy.sh              # main deployer (not re-sourced after clone)
├── haproxy.cfg            # HAProxy template (patched at phase 4)
├── nextcloud-init.sh      # Nextcloud setup script (runs inside container)
├── signaling.conf.example # Template for Talk signaling config
├── docker-compose.yml     # Generated at phase 4
└── .env                   # Generated at phase 4
```

---

## Phase 3 — Interactive configuration

The script prompts for all deployment parameters. Answers are cached in `/tmp/.nxt-maxscale-config.env` and reused on re-runs (with option to modify).

### Domain configuration

| Prompt | Variable | Example |
|--------|----------|---------|
| Nextcloud domain | `NEXTCLOUD_DOMAIN` | `cloud.example.com` |
| Collabora domain | `COLLABORA_DOMAIN` | `office.example.com` |
| Whiteboard domain | `WHITEBOARD_DOMAIN` | `whiteboard.example.com` |
| Admin email (SSL) | `CERTBOT_EMAIL` | `admin@example.com` |

### Node counts

| Component | Variable | Constraint | Default |
|-----------|----------|------------|---------|
| Nextcloud FPM | `NC_NODES` | ≥ 1 | 6 |
| MariaDB Galera | `MARIADB_NODES` | **Odd** ≥ 3 | 5 |
| Redis | `REDIS_NODES` | **Even** ≥ 6 | 6 |
| Collabora | `COLLAB_NODES` | ≥ 1 | 3 |
| Whiteboard | `WB_NODES` | ≥ 1 | 3 |
| RustFS | `RUSTFS_NODES` | ≥ 4 (EC:N/2) | 4 |
| Signaling | `SIGNALING_NODES` | ≥ 1 | 4 |

### RustFS disk configuration

The wizard profiles each disk and suggests the optimal XFS mount options:

```
sda  5.5T  → detected: HDD/NVMe/SSD
sdb  5.5T  → XFS: noatime,nodiratime,allocsize=64m,logbsize=256k,largeio
```

Each disk is formatted XFS, labelled, mounted, and added to `/etc/fstab`.

> Erasure coding tolerance: with N nodes, the cluster survives `N/2` simultaneous disk failures.

### Optional components

| Component | Variable | Effect |
|-----------|----------|--------|
| Talk (spreed-signaling) | `TALK_ENABLED` | Deploys NATS cluster + 4 signaling nodes + coturn |
| coturn | `COTURN_ENABLED` | TURN/STUN relay for NAT traversal |
| HAProxy stats | `HAPROXY_STATS` | Enables `/stats` page (requires password) |
| RustFS console | `RUSTFS_CONSOLE_ENABLED` | Enables `/s3-console` |
| SSL mode | `CERTBOT_STAGING` | `yes` = staging certs (no rate limit, untrusted) |

---

## Phase 4 — File generation

**Generated files:**

### `.env`
All deployment variables + generated secrets. Example generated secrets:
- `GEN_DB_ROOT_PASS` — MariaDB root password (32 chars, no `#`)
- `GEN_REDIS_PASS` — Redis cluster password
- `GEN_NC_ADMIN_PASS` — Nextcloud admin password
- `GEN_TALK_SECRET` — Spreed-signaling shared secret
- `GEN_COTURN_SECRET` — coturn static-auth-secret

### `docker-compose.yml`
Generated dynamically based on node counts and enabled features. Includes:
- All service definitions with healthchecks
- Network definitions (`next-net`, `galera-net`, `talk-net`, `storage-net`, etc.)
- Volume definitions (MariaDB data, Nextcloud data, Redis data, etc.)

### `signaling.conf` *(Talk only)*
```ini
[nats]
url = nats://nats-01:4222,nats://nats-02:4222,nats://nats-03:4222

[grpc]
listen = 0.0.0.0:9090
targets = spreed-signaling-01:9090,...,spreed-signaling-N:9090
```

### `haproxy.cfg` *(patched)*
`patch_haproxy()` replaces all `BEGIN_SERVERS_X / END_SERVERS_X` blocks with the correct number of servers based on node counts. In staging mode, HSTS is set to `max-age=0`.

### `mariadb/*.cnf`
Per-node Galera configuration with `wsrep_cluster_address` listing all nodes.

---

## Phase 5 — SSL certificates

**Steps:**

1. DNS verification — resolves each domain, checks it points to the server's public IP
2. Port 80 availability check — required for HTTP-01 ACME challenge
3. **Certbot HTTP-01** — obtains Let's Encrypt certificates for all domains
4. Combines `fullchain.pem` + `privkey.pem` → `certs/stack.pem` (HAProxy format)

**On re-run:** if `certs/stack.pem` already exists and is valid, certificate generation is skipped.

> [!NOTE]
> Staging mode (`CERTBOT_STAGING=yes`) uses Let's Encrypt's staging CA — no rate limits, untrusted by browsers. HSTS is automatically disabled to prevent permanent browser lockout.

---

## Phase 6 — Deployment

```
Pull images (parallel) → Build MariaDB Galera image → Start infrastructure
```

**Startup sequence:**

```
1. HAProxy + nginx-acme + certbot          → wait for port 80 ✓
2. MariaDB cluster (bootstrap node first)  → wait for Galera SYNCED
3. Redis cluster + init job                → wait for cluster_state:ok
4. RustFS nodes                            → wait for S3 health
5. Redis Cluster init job                  → runs once, exits 0
6. app-next-01 (FPM)                       → wait for healthy (PHP-FPM)
7. nextcloud-setup                         → install + configure Nextcloud (~5 min)
8. app-next-02..N + nginx-next-01..N       → started after app-next-01 healthy
9. Collabora nodes                         → wait for /hosting/discovery
10. Whiteboard nodes
11. NATS cluster + spreed-signaling nodes  → wait for gRPC interconnect
12. notify-push                            → wait for port 7867 (via app-next-01)
```

**Image pull:** all images are pulled in parallel with a progress bar. A failed pull is detected and reported.

**MariaDB bootstrap:** node1 bootstraps the Galera cluster (`wsrep_new_cluster`), then nodes 2..N join. The autoheal container monitors and recovers dead nodes automatically.

---

## Phase 7 — Functional verification

The script runs a series of end-to-end checks:

| Check | Method |
|-------|--------|
| HAProxy HTTP→HTTPS redirect | `curl` 301/302 on port 80 |
| Nextcloud installed | `/status.php` returns `"installed":true` |
| MariaDB Galera active | `mariadb-admin ping` |
| Redis Cluster OK | `cluster info` → `cluster_state:ok` |
| RustFS S3 health | `/health` endpoint |
| nextcloud-setup completed | Docker log grep |
| nextcloud-cron active | Container running check |
| Talk signaling reachable | `nc -w2 127.0.0.1 8080` |

**Credential display:** admin credentials are shown at the end of deployment.

---

## Post-deployment operations

### Access the deployment

| Service | URL |
|---------|-----|
| Nextcloud | `https://NEXTCLOUD_DOMAIN` |
| Collabora | `https://COLLABORA_DOMAIN` (internal use) |
| Whiteboard | `https://WHITEBOARD_DOMAIN` (internal use) |
| HAProxy stats | `https://NEXTCLOUD_DOMAIN/stats` *(if enabled)* |
| RustFS console | `https://NEXTCLOUD_DOMAIN/s3-console` *(if enabled)* |

### Re-run the deployer

```bash
sudo bash /tmp/deploy.sh
```

The script detects an existing deployment and offers:
- **[1] Continue / health check** — verify all services are healthy
- **[2] Update** — pull new images, recreate containers
- **[3] Scale** — change node counts

### Manual operations

```bash
# Check all containers
docker ps --format 'table {{.Names}}\t{{.Status}}'

# View Nextcloud logs
docker logs app-next-01 --tail 50

# Run occ commands
docker exec -u www-data app-next-01 php /var/www/html/occ <command>

# Galera cluster status
docker exec mariadb-node1 mariadb -uroot -p$DB_ROOT_PASS \
  -e "SHOW STATUS LIKE 'wsrep_%';"

# HAProxy stats via socket
docker exec haproxy sh -c 'echo "show info" | socat stdio /var/run/haproxy.sock'
```

---

## Update — pull new images

```bash
sudo bash /tmp/deploy.sh   # select [2] Update
```

**Steps:**
1. Pull all updated images in parallel
2. `docker compose up -d --remove-orphans` — recreate containers with new images
3. `docker compose restart haproxy` — reload backends
4. Re-apply Collabora patch on all nodes
5. Wait for all services to become healthy
6. Functional tests

> [!NOTE]
> Node data (MariaDB volumes, Nextcloud data, Redis data) is preserved. Only container images are updated.

---

## Scale — add or remove nodes

```bash
sudo bash /tmp/deploy.sh   # select [3] Scale
```

### Scaling rules

| Component | Scale up | Scale down |
|-----------|----------|------------|
| Nextcloud FPM | ✅ Supported — HAProxy updated automatically | ✅ Supported — HAProxy updated automatically |
| MariaDB Galera | ✅ Must remain **odd** | ✅ Must remain **odd** ≥ 3 |
| Redis | ✅ Must remain **even** ≥ 6; slots rebalanced automatically | ✅ Slots drained to remaining nodes |
| RustFS | ⚠️ **Not supported via deploy.sh** — see note below | ❌ Not supported (data loss risk) |
| Collabora | ✅ Add/remove freely | ✅ Add/remove freely |
| Signaling | ✅ Add/remove freely | ✅ Add/remove freely |

> [!WARNING]
> **RustFS scaling is not handled by deploy.sh.** RustFS uses a distributed erasure coding pool — adding nodes mid-deployment requires manual intervention via the RustFS admin CLI (`mc admin`) and is not automated. Changing `RUSTFS_NODES` in `.env` will start new containers but the data distribution will **not** automatically rebalance. Scale RustFS only from the initial deployment.

### Redis scale-up process

1. New nodes start and join the cluster
2. `redis-cli reshard` redistributes hash slots to new masters
3. New replicas assigned automatically
4. Health check waits for `cluster_state:ok`

### RustFS — no automated scale-up

RustFS supports pool expansion but requires manual steps outside deploy.sh:

```bash
# Manual RustFS pool expansion (not handled by deploy.sh)
# 1. Add new nodes with empty disks
# 2. Run via mc admin:
mc admin config set local/ storage add /data  # add new pool
mc admin rebalance start local/               # rebalance objects
```

> ⚠️ This is a future improvement. For now, plan your RustFS node count **before initial deployment**.

### HAProxy after scaling

`patch_haproxy()` is called automatically — it regenerates all `BEGIN_SERVERS_*/END_SERVERS_*` blocks and restarts HAProxy. No manual config edit required.

---

## Environment variables reference

Key variables stored in `/opt/nxt-maxscale/.env`:

| Variable | Description |
|----------|-------------|
| `NEXTCLOUD_DOMAIN` | Nextcloud FQDN |
| `COLLABORA_DOMAIN` | Collabora FQDN |
| `WHITEBOARD_DOMAIN` | Whiteboard FQDN |
| `TALK_DOMAIN` | Talk/signaling FQDN |
| `NC_NODES` | Number of Nextcloud FPM nodes |
| `MARIADB_NODES` | Number of MariaDB Galera nodes (odd) |
| `REDIS_NODES` | Number of Redis nodes (even ≥ 6) |
| `COLLAB_NODES` | Number of Collabora nodes |
| `WB_NODES` | Number of Whiteboard nodes |
| `RUSTFS_NODES` | Number of RustFS nodes |
| `SIGNALING_NODES` | Number of spreed-signaling nodes |
| `TALK_ENABLED` | `yes`/`no` — enable Talk HA |
| `COTURN_ENABLED` | `yes`/`no` — enable coturn |
| `HAPROXY_STATS` | `yes`/`no` — enable `/stats` |
| `CERTBOT_STAGING` | `yes`/`no` — Let's Encrypt staging |
| `CERTBOT_EMAIL` | Email for Let's Encrypt |
| `NC_VERSION` | Nextcloud image version |
| `GEN_NC_ADMIN_PASS` | Generated Nextcloud admin password |
| `GEN_DB_ROOT_PASS` | Generated MariaDB root password |
| `GEN_REDIS_PASS` | Generated Redis password |
| `GEN_TALK_SECRET` | Generated Talk shared secret |
| `HAPROXY_STATS_PASSWORD` | HAProxy stats page password |

---

*Generated for Azure NXT Maxscale v2.5.3 — [GitHub](https://github.com/oboeglen/Azure-NXT-Maxscale)*
