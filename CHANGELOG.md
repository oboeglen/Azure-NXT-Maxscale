# Changelog

All notable changes to this project are documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) — versioning [Semantic Versioning](https://semver.org/).

---

## [2.3.5] — 2026-06-01

### Fixed
- **notify-push missing from docker-compose.yml** — `gen_compose()` used `\$$BIN` in a heredoc, causing a `set -u` error on the undefined variable `$BIN` that silently aborted writing the service. The variable is removed; the binary path is now repeated inline with `\$\$(uname -m)`
- **notify-push restart loop on first deploy** — container started before the `notify_push` binary was copied to the volume by `app-next-01`. Added a wait loop: `until [ -f .../notify_push ]; do sleep 5; done` before `exec`
- **Brute force / rate limiting lockout** — repeated login attempts during deployment triggered Nextcloud's rate limiter. `nextcloud-init.sh` now auto-whitelists `127.0.0.1`, `172.10.0.0/24` (Docker net), and the server's public IP detected at setup time
- **Wrong OIDC app installed** — `user_oidc` (OpenID Connect user backend) replaced by `oidc` (OIDC Identity Provider v1.17.0) in the app installation list
- **Mail and Assistant missing** — `mail` and `assistant` added to the auto-installed apps list in `nextcloud-init.sh`

---

## [2.3.4] — 2026-06-01

### Added
- **12 Nextcloud apps auto-enabled on first setup** — `nextcloud-init.sh` now installs and enables the following apps automatically: `contacts`, `calendar`, `user_ldap`, `files_external`, `quota_warning` (bundled), and `collectives`, `deck`, `forms`, `tables`, `groupfolders` (Team Folders), `twofactor_nextcloud_notification`, `user_oidc` (OIDC Identity Provider) from the App Store. All installs are non-fatal — unavailable apps are skipped with a warning without interrupting the setup. Apps requiring server-specific configuration (`user_ldap`, `user_oidc`) are installed only; post-deployment configuration is done via the Settings UI
- **Security audit section** — external attack surface audit (score 89/100) documented in README
- **Performance benchmarks** — Test C (full stack + Talk HA, dedicated server) and Talk HA authenticated WebSocket benchmark (100% auth success, 100 ms p(95)) added to README performance section

### Fixed
- **MinIO console login loop** — HAProxy `is_s3_console_root` ACL unconditionally redirected `/s3-console/` → `/s3-console/login`; after login the React SPA navigated back to `/s3-console/` causing an infinite redirect loop. Removed the ACL and redirect rule; routing and authentication are handled entirely client-side by the React SPA
- **HSTS badge language** — badge displayed "2 ans" (French); corrected to "2 years"

---

## [2.3.3] — 2026-05-31

### Fixed
- **`talk:turn:add` wrong argument order for Talk 23** — Talk 23 changed the command signature: the secret is now a `--secret=VALUE` option, not a positional argument. Previous call `talk:turn:add "turn:DOMAIN:3478" SECRET "turn" "udp,tcp"` failed with "Too many arguments". Fixed to `talk:turn:add --secret=SECRET "turn" "DOMAIN:3478" "udp,tcp"`
- **Notify Push wait loop used `wget` instead of `curl`** — `wget` is not available in the Nextcloud FPM image used by the `notify-push` container. The startup detection loop always timed out at 120 s instead of breaking early when the server was ready. Fixed to use `curl -sf`

---

## [2.3.2] — 2026-05-31

### Fixed
- **Talk admin page crash (`serverid` out of range)** — `nextcloud-custom.config.php` set `'serverid' => gethostname()`, which resolved to the Docker container short ID (e.g. `36653f7c76a9`). Nextcloud Talk parsed the leading digits as an integer (`36653`), exceeding the valid range 0–1023 required for Snowflake session ID generation. Removed `serverid` from `custom.config.php`; the value auto-generated in `config.php` during installation is used instead
- **Talk signaling `getSignalingSecret()` returning null** — `configure_talk()` now uses `config:app:set` directly to store the signaling config in the Talk 23 format with the secret embedded inside the server object (`{"servers":[{...,"secret":"..."}],"secret":"..."}`). `talk:signaling:add` only stores the secret at the root level, causing `getSignalingSecret()` to return null when the per-server secret field was absent. Also removes the legacy `signaling_secret` standalone key left by older Talk versions

---

## [2.3.1] — 2026-05-31

### Fixed
- **Talk signaling registered as `https://` without secret** — `nextcloud-init.sh` was configuring Talk via the deprecated `config:app:set spreed signaling_servers` API with `https://` before `configure_talk()` in `deploy.sh` had a chance to run. When `configure_talk()` detected the domain already present, it skipped `talk:signaling:add`, leaving the signaling server with the wrong URL scheme and no secret. Fixed by removing all signaling/STUN/TURN configuration from `nextcloud-init.sh` — the app is now only installed and enabled there; all URL and secret wiring is handled exclusively by `configure_talk()` which correctly uses `wss://` via `talk:signaling:add`
- **Notify Push startup timeout too tight** — the wait loop capped at 60 s (12 × 5 s), exactly matching `start_period` of the dependent FPM healthcheck. On slower servers this caused a race condition. Extended to 120 s (24 × 5 s)

### Added
- **UFW firewall section updated** — coturn TURN/STUN port (`3478/udp+tcp`) and media relay port range (`49152-65535/udp`) added to the recommended UFW rules

---

## [2.3.0] — 2026-05-31

### Added
- **Nextcloud Talk — HA Signaling** — full Talk backend deployed via `deploy.sh`: `spreed-signaling` nodes load-balanced by HAProxy (`leastconn`), NATS message broker for inter-node event routing, optional `coturn` TURN/STUN relay (`network_mode: host`, ports `3478/udp+tcp`)
- **Talk auto-configuration** — `configure_talk()` wires secrets end-to-end: generates `GEN_TALK_SECRET`, writes `signaling.conf`, registers `wss://TALK_DOMAIN/` via `occ talk:signaling:add --verify`, configures STUN/TURN via `occ talk:stun:add` / `occ talk:turn:add`
- **Notify Push (Client Push)** — `notify-push` container using the binary bundled in the Nextcloud image; HAProxy routes `/push` before the general Nextcloud rule; auto-configured via `occ notify_push:setup` + full self-test
- **Disk Wizard** — interactive disk preparation wizard: detects block devices via `lsblk --pairs`, formats XFS with tuned parameters (`agcount`, `lazy-count`), mounts with persistent `fstab` entry, refreshes the disk table after each operation
- **Talk HA scaling** — `spreed-signaling` nodes support scale-up and scale-down via the existing scaling menu
- **README** — new sections: Talk HA Signaling, Notify Push, Disk Wizard; updated architecture diagram, HA table, ports, HAProxy stats table, Docker images table (`IMG_NATS`, `IMG_SPREED_SIGNALING`, `IMG_COTURN`)

### Fixed
- **certbot TLS-ALPN-01 removed** — challenge type unsupported since certbot v2.6+; HTTP-01 standalone only
- **`signaling.conf` permissions** — changed from `600` to `644` so the non-root container user can read the file
- **HAProxy signaling health check** — switched to `HTTP/1.0` to avoid Host header substitution issues with `envsubst`
- **HAProxy ACL restoration** — `patch_haproxy()` now restores `acl is_talk`, `use_backend signaling`, and the full `backend signaling` block when `TALK_ENABLED` switches from `no` to `yes` on re-deploy

---

## [2.2.1] — 2026-05-27

### Changed
- **README** — removed the Image column from the Deployed services table

---

## [2.2.0] — 2026-05-26

### Fixed
- **Nextcloud brute force on first deployment** — without `trusted_proxies`, Nextcloud attributed all requests (HAProxy health checks + user logins) to the same internal Docker IP, saturating the brute force counter from the first login. Fixed via `trusted_proxies` with the 6 Docker subnets of the project (`172.10–172.100`), allowing Nextcloud to use the `X-Forwarded-For` header to track each client on its real IP (`/32`). `auth.bruteforce.protection` and `ratelimit.protection` are now active (previously disabled as a workaround)
- **Persistent Redis brute force entries between deployments** — `*Bruteforce*` keys accumulated during the init phase (Nextcloud not yet ready, HAProxy doing health checks) persisted in Redis between container restarts. Added `reset_bruteforce()` function called after `wait_healthy`: deletes all brute force keys on the 6 Redis cluster nodes via DEL in cluster mode (`-c`)

### Added
- **Backup section in the README** — `[!WARNING]` alert about the absence of a built-in backup solution, table of critical data (MinIO S3 first, MariaDB, config), recommended strategies (VM snapshot, `mc mirror`, `mariadb-dump`), key points (Galera ≠ backup, restore testing, encryption)
- **Docker Images section in the README** — version pinning explanation, `IMG_*` variable table with current versions, update example

---

## [2.1.16] — 2026-05-26

### Fixed
- **`${IMG_CERTBOT}` bug in quoted heredoc** — variable was not expanded by bash (heredoc `<<'ACME'`), docker-compose received the literal variable name instead of the image. Fixed by replacing with the string `certbot/certbot:v5.6.0` directly in the heredoc

### Changed
- **Full Docker image centralization** — added `IMG_HAPROXY`, `IMG_NGINX`, `IMG_REDIS`, `IMG_MARIADB` variables in the constants block at the top of the script. All images are now referenced via `IMG_*` in unquoted heredocs and the parallel pull list. The 3 quoted heredocs (HAPROXY, ACME, WBREDIS) retain literal strings because they contain docker-compose variables (`${NEXTCLOUD_DOMAIN}` etc.) that must not be expanded by bash

---

## [2.1.15] — 2026-05-26

### Fixed
- **Incorrect Nextcloud permissions on first deployment** — the `nextcloud-perms` service used `command:` with `user: root`, but the `nextcloud:fpm` image entrypoint runs `run_as()` which drops privileges to `www-data` before executing the command. As a result, `chown` failed silently on a fresh server, leaving volumes as `root:root` and blocking `nextcloud-setup`. Fixed by replacing `command:` with `entrypoint: ["/bin/sh", "-c", "chown ..."]` to bypass the native entrypoint

### Changed
- **Docker images — pinned versions** — all `:latest` and `:stable` tags replaced with precise versions extracted from production: `certbot/certbot:v5.6.0`, `minio/minio:RELEASE.2025-09-07T16-13-09Z`, `minio/mc:RELEASE.2025-08-13T08-35-41Z`, `collabora/code:25.04.9.4`, `ghcr.io/georgmangold/console:v1.9.1`, `willfarrell/autoheal` and `ghcr.io/nextcloud-releases/whiteboard` pinned by SHA256 digest. Versions centralized in `IMG_*` variables at the top of the script

---

## [2.1.14] — 2026-05-25

### Fixed
- **Collabora patch not applied to new nodes during scale-up** — `patch_collabora_binary` always extracted the binary from `collabora-node1`, which was already patched from the initial deployment. During scale-up (e.g. 3→6 nodes), re-patching the already-patched binary failed with `pattern_not_found` and new nodes (4–6) never received the patch. `patch_collabora_binary` now accepts a `first_src` parameter (first node to use for extraction) and `scale_nodes` passes `ORIG_COLLAB_NODES + 1`, ensuring extraction is done from a new node with an unpatched binary

## [2.1.13] — 2026-05-25

### Fixed
- **Collabora binary patch — false positive "already_patched"** — two types of false positives prevented the patch from being applied on coolwsd 25.04.9.4:
  - The `ORIG_PATCHED` sequence (`ba ff ff ff 7f b8 ff ff ff 7f 84 db`) naturally exists in the binary at a different address (0x269fcf), triggering a false "already patched" detection before even searching for the target pattern
  - 21 pairs of `MOV reg, INT_MAX + MOV reg, INT_MAX` (a natural value in the binary) triggered a false global detection
  - The "(MOV 20 + MOV 20) + TEST" strategy generates 56 false positives and was liable to patch wrong locations on re-run
  **Fixes**: removed all global "already patched" searches; the check is only performed at the exact offsets found by strategies; removed the (20+20) strategy and the reversed search order (10→20)

## [2.1.12] — 2026-05-25

### Fixed
- **Collabora binary patch not working on some versions of coolwsd** — the search algorithm was limited to a single hard-coded byte pattern (`mov edx,20 / mov eax,10 / test bl,bl`), specific to a single build. Replaced with a 4-strategy approach, independent of version:
  1. Original exact pattern (backward compatibility)
  2. All x86-64 register combinations for `(MOV r32, 20) + (MOV r32, 10)` with nearby `TEST`/`CMP` verification
  3. Same for `(MOV r32, 20) + (MOV r32, 20)` (when both limits are 20)
  4. Anchor on the `"home_mode.enable"` string in the binary then search for small constant pairs in adjacent code
  The "already patched" detection is also generalized (no longer tied to the exact pattern)

## [2.1.11] — 2026-05-25

### Fixed
- **Redis scale-up race condition — replica not integrated** — after adding a master node via `--cluster add-node`, the node was not yet visible in `cluster nodes` during the immediately following call to add the replica (`--cluster-slave --cluster-master-id`), causing a silent failure (redis-node8 absent from the cluster). `_redis_scale_up` now waits up to 30 s for the master to be visible in `cluster nodes` before adding the replica. If `--cluster add-node --cluster-slave` still fails, a `MEET + REPLICATE` fallback is attempted. A final check compares `cluster_known_nodes` to the expected count and warns in case of discrepancy

## [2.1.10] — 2026-05-25

### Fixed
- **MinIO crash loop on repeated scale** — `_minio_register_pool` had no duplicate check; if the configuration cache was stale, the same pool (`start:end`) was added twice to `.minio-pools`, causing a `FATAL Invalid command line arguments: duplicate endpoints found` on MinIO startup. A `grep -qF` dedup now prevents adding the same pool twice
- **Stale `ORIG_MINIO_NODES` from cache** — `scale_nodes()` loads the cache then checks the number of actually active containers; if the real count is higher than the cache, MINIO_NODES is corrected before being stored as ORIG_MINIO_NODES (protection against double-registrations)
- **HAProxy /stats lost after reboot** — `HAPROXY_STATS` was not written to `.env` (only to the transient cache `/tmp/`); after a reboot, reconstruction from `.env` fixed it to `no` by default, disabling the statistics page. `HAPROXY_STATS` is now persisted to `.env` and reread in the reconstruction path
- **`wait_healthy` stuck on containers in crash loop** — containers in `restarting` state (e.g. MinIO with duplicated pool) kept `all_healthy=false` indefinitely until timeout. After 3 consecutive restarts, a container is now flagged as "crash loop", excluded from the wait and a warning is displayed; other containers continue to be waited for normally

## [2.1.9] — 2026-05-25

### Added
- **Interactive scaling** — `deploy.sh` offers a "Scale up / down nodes" menu when a stack is already deployed. All data is preserved; only configuration files are regenerated
  - **Nextcloud FPM+nginx** — hot addition/removal of node pairs
  - **MariaDB Galera** — scale-up via automatic SST, scale-down via `--remove-orphans` (quorum maintained)
  - **Redis Cluster** — scale-up with cluster integration (`add-node`, `--cluster-slave`, `rebalance`) and scale-down with slot migration before removal (`reshard`, `del-node`, `rebalance`)
  - **Collabora CODE** — node addition/removal; `home_mode` binary patch automatically reapplied on new nodes
  - **Whiteboard** — node addition/removal
  - **MinIO** — scale-up via pool expansion (multi-pool MNMD) via `.minio-pools`; scale-down not supported by MinIO (redirected to `mc admin decommission`)
- `gen_minio_server_cmd()` function — MinIO `server` command built dynamically from `.minio-pools` (transparent multi-pool)
- `.minio-pools` file — tracks MinIO pool history (`start:end` format per line), used to rebuild the `server` command after a restart
- `MINIO_MODE` and `MINIO_BYPASS` persisted to `.env` (previously only in the transient cache `/tmp/`) — correctly rebuilt after a reboot without cache

### Fixed
- Broken `nextcloud-cron` healthcheck — `pgrep` absent from the `nextcloud:33.0.3-fpm` image; replaced by `grep -qa cron /proc/1/cmdline`
- Redis scale-up: `master_id` via hostname grep failed (`cluster nodes` shows IPs, not hostnames) — replaced by `cluster myid` directly on the new node
- Redis scale-up: slot in `migrating` state blocked replica addition — added `--cluster fix` before `--cluster rebalance`
- Redis scale-down: slots not rebalanced after removal (one master inherited all slots) — added `--cluster fix` + `rebalance` at the end of `_redis_scale_down`
- HAProxy reload after scaling: replaced `kill -USR2 1` (graceful, new backends inactive for in-flight traffic) with `docker compose restart haproxy` (new backends immediately active)

### Changed
- `deploy.sh` main menu: 3 options on existing stack — quick update · scaling · full deployment
- HAProxy reload after scaling: `docker compose restart haproxy` instead of `SIGUSR2`

---

## [2.1.8] — 2026-05-24

### Fixed
- Redis configuration order in `nextcloud-init.sh` fixed — `redis.cluster` seeds are now defined **before** `memcache.distributed` and `memcache.locking`, eliminating "No memory cache" and "Transactional file locking" warnings in the Nextcloud admin interface

### Changed
- README: Collabora patch persistence table updated — `deploy.sh` quick update mode automatically reapplies the patch after image pull

---

## [2.1.7] — 2026-05-24

### Added
- Quick update mode in `deploy.sh` — if a stack is already active in `$INSTALL_DIR`, the script prioritizes offering to only update images (`docker compose pull` + `docker compose up -d`) without regenerating configuration, followed by automatic reapplication of the Collabora binary patch and a `wait_healthy` check
- Automatic detection of node count from running containers when the configuration cache is absent

---

## [2.1.6] — 2026-05-24

### Fixed
- `letsencrypt` and `certbot_webroot` volumes declared `external: true` in the generated `docker-compose.yml` — removes the `volume already exists but was not created by Docker Compose` warning on startup
- In staging mode, `${COMPOSE_PROJECT_NAME}_letsencrypt` is now always pre-created by `gen_certs()` so that the renewal certbot container finds its volume

### Changed
- README: Collabora binary patch persistence documented — scenario table for crash / `docker restart` / recreate / `down+up` / image update

---

## [2.1.5] — 2026-05-24

### Added
- Automatic binary patch of `coolwsd` in `deploy.sh` — `patch_collabora_binary()` function that removes the `home_mode` limit (20 connections / 10 documents per node) by dynamically searching for the `mov edx,20 / mov eax,10` pattern in the binary and replacing it with `INT_MAX` across all configured Collabora nodes

### Changed
- Collabora no longer limits the number of simultaneous connections and documents — the patch is applied automatically after `docker compose up -d`, on all nodes (`COLLAB_NODES`), without touching `extra_params` or `home_mode.enable=true`
- `deploy.sh` load estimation: the `home_mode N×20 / N×10` line is replaced by `unlimited connections/documents (home_mode binary patch)`
- Deployer version: v2.1.5
- README: Collabora CODE section updated to reflect limit removal

---

## [2.1.4] — 2026-05-22

### Fixed
- Docker Compose project name inconsistency fixed in `deploy.sh` (the generated name could diverge depending on the working directory)

---

## [2.1.3] — 2026-05-22

### Fixed
- certbot `--post-hook` broken by incorrect YAML indentation in the generated `docker-compose.yml` — the HAProxy certificate was not rebuilt after renewal

---

## [2.1.2] — 2026-05-22

### Added
- Responsible disclosure policy (`SECURITY.md`)
- Nextcloud FPM node monitoring in the HAProxy statistics page (`listen nextcloud-fpm`)
- Collabora `home_mode` estimates (20 connections / 10 documents per node) displayed in the `deploy.sh` summary

### Fixed
- Invalid `no option forwardfor` on TCP-mode `listen nextcloud-fpm` removed — HAProxy startup error
- Git clone blocking in `deploy.sh` resolved (stdin/TTY conflict during non-interactive clone)
- OPcache preload removed — caused a `fatal error` on Nextcloud startup

### Changed
- README badges migrated from Simple Icons CDN (blocked by GitHub's camo proxy) to shields.io `for-the-badge`

---

## [2.1.1] — 2026-05-21

### Added
- Optional MinIO web console accessible via `/s3-console` (image `ghcr.io/georgmangold/console`) — enabled in `deploy.sh`, no additional port exposed
- MAXSCALE graphite login theme: custom CSS (`nxt-custom.css`), logo and wallpaper
- Load capacity estimation displayed after deployment summary (model calibrated on real measurements)
- Performance benchmarks and sizing tables by usage profile in README
- SME load test results 500 daily users (k6 v0.55, 34 VUs, 3,911 requests, 0 5xx errors)

### Fixed
- Redis cluster check made robust — `fsockopen` instead of `OC::$server`, explicit timeouts, non-blocking
- Whiteboard JWT expiry extended to 24 h (was 15 min — caused disconnections in long sessions)
- Handling of MinIO 1-byte stub files in `WhiteboardContentService` (`patch_wb.py`)
- HAProxy WebDAV filter extended: `PUT` on `/apps/whiteboard`, `PUT`/`DELETE` on `/s3-console`
- Automatic redirect of `/s3-console` and `/s3-console/` to `/s3-console/login`
- `/s3-console` prefix stripped in HAProxy before forwarding to `minio-console:9090` — fixed MIME errors on React assets
- Redis cluster detection fixed with literal key `redis.cluster` in `occ`
- `nextcloud-setup` crash on `Permission denied` when purging `nextcloud.log`
- Galera bootstrap: `mariadbd`-compatible entrypoint, double-mysqld and YAML `&&` syntax fixed
- UTF-8 alignment of banners and summaries in `deploy.sh` (multi-byte characters)
- Orphan cron job purge after app disable in `nextcloud-init.sh`
- App detection via `app:enable` (idempotent) instead of fragile grep on `app:list`
- Four Nextcloud configuration adjustments applied automatically (log level, OPcache, etc.)

### Changed
- 6 non-destructive reliability improvements: OPcache, Collabora healthchecks, Redis seeds, autoheal HC
- Deployment summary width calculated dynamically (adapts to the longest line)
- Nextcloud brand color aligned with MAXSCALE graphite palette

---

## [2.1.0] — 2026-05-20

Major version — complete architecture redesign towards an FPM + MinIO stack.

### Added
- **Nextcloud PHP-FPM** with nginx as FastCGI proxy (replacement of Apache mode)
- **Distributed MinIO S3** with erasure coding (replacement of RustFS) — bucket versioning enabled automatically
- **Distributed Redis Cluster** (≥ 6 master + replica nodes)
- **Collabora CODE** — collaborative office editing (Writer, Calc, Impress) in `home_mode`
- **Whiteboard** — real-time collaborative whiteboard (WebSocket + Redis Streams)
- `galera-autoheal` service — automatic restart of out-of-sync Galera nodes
- `nextcloud-perms` service — volume permission fix before installation
- `nextcloud-setup` service — post-installation auto-configuration (sentinel-protected, one-shot)
- `nextcloud-custom.config.php` mounted `:ro` in all containers — fixes `.well-known/caldav` and `.well-known/carddav`, enforces permanent HTTPS
- HAProxy configuration validation before deployment (dry-run)
- `wsrep_ready` healthcheck on Galera nodes + `safe_to_bootstrap` automatically managed by `galera-bootstrap.sh`
- Health check silencing in HAProxy logs (`/status.php`, `/robots.txt`, `/favicon.ico`) — ~80% noise reduction
- Collabora administration console blocked via HAProxy (HTTP 403)
- WebDAV method filtering restricted to API paths (`/remote.php`, `/public.php`, `/ocs`)
- Scanner user-agents blocked (sqlmap, nikto, nmap, masscan, zgrab) and common scan paths
- Anti-Slowloris protection (request dropped after 10 s)
- HSTS 2 years with `includeSubDomains` and `preload`
- TLS 1.2 minimum, TLS 1.3 preferred, `no-tls-tickets` (Perfect Forward Secrecy)

### Fixed
- `mjs` MIME types, `X-Robots-Tag` header, missing `nextcloud-cron` container
- CSP `unsafe-inline` and JS MIME types for Collabora CODE
- Collabora MIME rule moved after ACL definition (HAProxy parsing is sequential)
- `IFS` word-split on package installation in `deploy.sh`
- Superfluous `REDIS_NODES` variable removed from environment

---

[2.2.1]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.2.0...v2.2.1
[2.2.0]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.16...v2.2.0
[2.1.16]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.15...v2.1.16
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
[2.3.3]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.3.2...v2.3.3
[2.3.2]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.3.1...v2.3.2
[2.3.1]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.3.0...v2.3.1
[2.3.0]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.2.1...v2.3.0
[2.2.1]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.2.0...v2.2.1
[2.2.0]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.16...v2.2.0
[2.1.1]: https://github.com/oboeglen/Azure-NXT-Maxscale/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/oboeglen/Azure-NXT-Maxscale/releases/tag/v2.1.0
