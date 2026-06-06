# Changelog

All notable changes to this project are documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) — versioning [Semantic Versioning](https://semver.org/).

---

## [2.7.1] — 2026-06-06

### Fixed
- **deploy.sh — Classic storage disk wizard** — `_scan_block_devices` and `_print_disk_table` did not exist; corrected to `_scan_available_disks` and `_show_disk_table`. Wrong variable names `DISK_FS`/`DISK_MOUNT` replaced by `DISK_FSTYPES`/`DISK_MOUNTS`. Disk index was 0-based in prompt but the table displays 1-based — input now converted correctly

---

## [2.7.0] — 2026-06-06

### Added
- **Classic storage — local disk as alternative to RustFS/S3** — new `STORAGE_TYPE` option at configuration time: choose between S3 (RustFS, existing behavior) or Classic (local disk bind-mounted at `/data`). In Classic mode: RustFS containers are not deployed, disk wizard formats and mounts a dedicated disk (XFS + fstab), Nextcloud uses its native filesystem driver, HAProxy S3/RustFS rules are stripped, `IMG_RUSTFS` is not pulled

---

## [2.6.1] — 2026-06-04

### Added
- **deploy.sh — Quick Update syncs `IMG_*` tags** — Quick Update now reads `IMG_*` variables from `deploy.sh` and patches `docker-compose.yml` image tags before pulling. Updating an image no longer requires a full redeploy — edit the variable, run Quick Update

### Fixed
- **deploy.sh — Collabora patch skipped when image unchanged** — Quick Update was re-running the binary patch on every execution, failing with "pattern not found" warnings when the patch was already applied. The patch is now skipped unless the container's image digest has changed

---

## [2.6.0] — 2026-06-04

### Added
- **deploy.sh — visual overhaul** — `log_run()` wrapper suppresses verbose terminal output (apt-get, docker build, git clone, docker compose up) while keeping everything in the log file. Spinner now shows elapsed time. `step()` prints a full-width separator. `phase()` adapts to terminal width
- **deploy.sh — compact wait_healthy** — replaced the per-container status table (printed every 10s, causing scroll) with a single updating progress bar `[████░░░░] 34/47  40s  ← pending-container`
- **deploy.sh — `log_run()`** — all verbose commands silently log to `/var/log/nxt-maxscale-deploy.log`; on failure, shows last 20 lines

### Fixed
- **deploy.sh — notify_push always calls `app:enable`** — when `app:install` returned non-zero (partial install, Nextcloud quirk), `app:enable` was never called leaving the app inactive. Now called unconditionally after install
- **deploy.sh — notify_push retries 6 → 12** — `maintenance:repair` may take time to propagate DB structures on first boot; 120s total gives more margin
- **deploy.sh — ANSI escape codes showing as `\033[0;37m`** — `printf %s` does not interpret `\033` in data args; pre-render colored strings using `printf` octal escapes
- **deploy.sh — division by zero in `wait_healthy`** — guard added if `containers=()` is empty
- **deploy.sh — `_SPINNER_START` used before `start_spinner`** — `stop_spinner` now uses `${_SPINNER_START:-$SECONDS}` to avoid wildly incorrect elapsed time
- **deploy.sh — occ raw output in terminal** — `configure_talk` and `configure_notify_push` no longer dump raw occ command output to the terminal; clean status messages only
- **haproxy — RustFS console Basic auth stripping** — browser-cached Nextcloud WebDAV credentials forwarded to RustFS console caused `InvalidRequest: invalid header: authorization`; stripped on GET requests only (POST/Bearer preserved)

---

## [2.5.6] — 2026-06-04

### Added
- **PHP-FPM pool auto-sizing** — `gen_fpm_conf()` measures actual PSS of running PHP-FPM processes via `/proc/$pid/smaps` (ps_mem.py approach) and calculates optimal `pm.max_children` per node: `(RAM × 60% ÷ NC_NODES) ÷ PSS/worker`. Falls back to 80 MB/worker on fresh deploys. Regenerated on every deploy and scale operation
- **`custom-fpm.conf`** — mounted into all `app-next` containers, overrides the default `pm.max_children=5` that causes 6–10s whiteboard save delays under concurrent saves
- **GitHub Actions CI** for patched signaling image (`Dockerfile.signaling` + `signaling.patch`)

### Fixed
- **scale_nodes — NC_NODES overwritten by running count** — pre-scale validation was comparing the new desired value against currently-running containers (which hadn't scaled yet), resetting NC_NODES=10 back to 8 before `docker compose up` could create the new containers. Fixed to only correct drift on services the user did NOT intentionally change
- **gen_fpm_conf missing from scale_nodes() flow** — was only called in `deploy()`, not in `scale_nodes()`, so FPM pool settings were never recalculated on scale

### Changed
- Signaling image switched to `strukturag/nextcloud-spreed-signaling:master` (official upstream)
- HAProxy signaling backend remains `balance leastconn`

---

## [2.5.5] — 2026-06-03

### Fixed
- **deploy.sh — AppArmor blocking every container start** — On kernels with AppArmor compiled in but `securityfs` not mounted (OVH VPS, some bare-metal Debian), Docker fails with `open /sys/kernel/security/apparmor/profiles: no such file or directory`. Fix: mount `securityfs` at startup, install `apparmor` package, add `--security-opt apparmor=unconfined` to all standalone `docker run` calls and all compose services
- **deploy.sh — invalid `default-security-opts` key crashes Docker daemon** — Neither `default-security-opt` nor `default-security-opts` are valid `daemon.json` keys. Added self-healing: script detects and removes both variants at startup before attempting to start Docker
- **deploy.sh — Docker daemon not running at version check** — `check_prerequisites()` runs before `install_packages()` which mounts securityfs and starts Docker. Added daemon startup + securityfs mount to `check_prerequisites()` so the version check doesn't fail with `Docker 0`
- **deploy.sh — syntax error `local function()`** — `local _haproxy_cleanup() { ... }` is invalid bash syntax. Replaced with plain `trap`
- **deploy.sh — `_run_tmpdir` unbound variable on EXIT** — Fixed trap to use `${_run_tmpdir:-}` to prevent unbound variable error when trap fires after local vars go out of scope
- **deploy.sh — `jq` not installed, signaling JSON empty** — `configure_talk()` used `jq` which was not in the package list, causing `signaling_servers` to be set to empty string. Added `jq` to `pkgs_apt`/`pkgs_dnf` and added `python3` fallback
- **deploy.sh — `notify_push:setup` fails with "can't load mount info"** — On fresh installs the DB structures notify_push reads aren't populated. Running `occ maintenance:repair` before `notify_push:setup` populates the required tables
- **deploy.sh — `gen_pass` infinite loop** — Capped retry loop at 20 attempts with explicit `die`
- **deploy.sh — securityfs not persisted across reboots** — Added `securityfs` mount to `/etc/fstab`

### Changed
- `apparmor` and `jq` added to package dependencies (`pkgs_apt`/`pkgs_dnf`)

---

## [2.5.4] — 2026-06-03

### Fixed
- **deploy.sh — mktemp files leaked on unexpected exit** — `patch_haproxy()` created temp files without a trap; added `trap EXIT` to ensure cleanup on any exit path
- **deploy.sh — docker-compose.yml not validated before deployment** — added `docker compose config --quiet` check before `docker compose up -d` to catch generation errors early
- **deploy.sh — certbot failure left empty cert slot** — added backup of existing `stack.pem` before renewal; restored automatically if certbot fails so the next run can retry
- **deploy.sh — `_detect_node_count` silently defaulted to 1** — now emits a warning when no containers match the filter, making the fallback visible in logs
- **deploy.sh — git fetch result not properly gated** — used `if/!` pattern to ensure `git reset --hard` never runs after a failed fetch
- **deploy.sh — HSTS not disabled in staging mode** — `Strict-Transport-Security: max-age=0` is now set when `CERTBOT_STAGING=yes` to prevent permanent browser lockout after a staging cert warning bypass
- **DEPLOYMENT.md — RustFS scale-up incorrectly described as supported** — clarified that `deploy.sh` does not handle RustFS scaling; added manual steps via `mc admin`

### Added
- **DEPLOYMENT.md** — comprehensive deployment guide covering all phases, scaling rules, environment variable reference, and post-deployment operations

---

## [2.5.3] — 2026-06-03

### Fixed
- **Talk — cross-node calls broken (WebRTC offer/answer/ICE not delivered)** — `nats://loopback` is an in-process bus per node. All WebRTC signaling messages sent to a session on another node were silently dropped because each node's loopback bus is isolated. Restored the external NATS container and changed `url = nats://nats:4222`; NATS is required for cross-node message relay even though gRPC handles session lookup
- **Talk — gRPC `LookupSessionId` race condition** — when a remote node queried a session that was concurrently being registered, the one-shot lookup returned `codes.Unknown desc = "unknown room session id"` before `SetRoomSession` completed. Added a retry loop (10 × 50 ms) in the gRPC server handler so lookups succeed within the registration window. Custom patched image published at `ghcr.io/oboeglen/azure-nxt-maxscale/nextcloud-spreed-signaling:latest` (upstream issue [#1261](https://github.com/strukturag/nextcloud-spreed-signaling/issues/1261))
- **deploy.sh — notify_push readiness check always timed out** — `curl -sf | grep -q 'false'` never matched because `/test/cookie` returns HTTP 400 (missing `token` header), not the string `false`. Replaced with `curl -s -o /dev/null` (any HTTP response = binary ready) checked via `app-next-01` over the Docker network
- **deploy.sh — notify_push wait loop could hang indefinitely** — no timeout cap on the `until` loop. Added a 300 s safety break to prevent infinite hang if the binary never starts

### Changed
- **NATS container restored** — `nats://loopback` cannot relay cross-node messages; external NATS is mandatory for multi-node Talk HA
- **Signaling image** — switched from `strukturag/nextcloud-spreed-signaling:latest` to the patched custom build `ghcr.io/oboeglen/azure-nxt-maxscale/nextcloud-spreed-signaling:latest`

---

## [2.5.2] — 2026-06-02

### Fixed
- **Talk — participants stuck on "waiting" across signaling nodes** — `nextcloud-spreed-signaling` v2.x replaced NATS with gRPC for cross-node session relay. Without a `[grpc]` section in the config, each node ran in complete isolation; participants on different nodes could never see each other. Added `listen = 0.0.0.0:9090` and `targets` listing all nodes — each node auto-detects and removes its own address at startup
- **Talk — WebSocket cut after ~60 s** — `timeout client 60s` in HAProxy defaults applied to signaling WebSocket connections. `timeout tunnel` in the backend only protects the server side; the client side remained at 60 s, causing HAProxy to RST the connection mid-call. Added `timeout tunnel 3600s` to the defaults section so both sides of all tunnels (Talk, notify_push, Whiteboard, Collabora) are covered

### Changed
- **NATS container removed** — replaced by the built-in `nats://loopback` bus (in-process, no external server). Cross-node relay is now handled exclusively by gRPC. One less container, no operational change

---

## [2.5.1] — 2026-06-02

### Fixed
- **RustFS console — XML error on expired token** — when the browser-side JS sent a request with a stale AWS4 token, RustFS returned `400/401/403 InvalidRequest` XML and the page went blank. HAProxy now intercepts these responses in the `rustfs-s3api` backend and redirects the browser to `/rustfs/console/auth/login/` instead of showing raw XML
- **RustFS console — double path on logout** — RustFS beta emits a relative redirect on logout (`rustfs/console/auth/login/` without leading `/`), causing the browser to double the base path to `/rustfs/console/rustfs/console/auth/login/`. HAProxy now intercepts any path beginning with `/rustfs/console/rustfs/console/` and redirects to the correct login URL

---

## [2.5.0] — 2026-06-02

### Fixed
- **`RUSTFS_SERVER_DOMAINS` breaks S3 bucket creation** — the variable forces the `s3s` library into virtual-hosted bucket routing; path-style `PUT /nextcloud` sent by Nextcloud's objectstore returned `400 InvalidBucketName`. Removed from all RustFS node environments in `gen_compose()` and `docker-compose.yml`. Console CORS is already handled by `RUSTFS_CONSOLE_CORS_ALLOWED_ORIGINS=*`
- **All `app:install` calls are non-fatal** — `richdocuments`, `spreed`, `whiteboard`, and `theming_customcss` now use `${OCC_BIN} app:install ... || warn "..."` instead of the fatal `occ()` wrapper. App Store rate-limiting or unavailability no longer causes setup to restart
- **Shell quoting error in deploy.sh monitoring loop** — `| xargs` used to trim whitespace broke on log lines containing apostrophes; replaced with `sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`

### Docs
- README accuracy fixes post-RustFS migration (architecture, container table, routing description)
- RustFS idle RAM footprint corrected: `~120–180 MB` per node (measured on Intel Xeon D-1521, 15.5 GB RAM, 4-node cluster) — previous estimate of 256–512 MB was too high
- HAProxy stats screenshot updated with current capture

---

## [2.4.2] — 2026-06-01

### Fixed
- **RustFS console login** — three cascading bugs prevented browser login: (1) ACL `path_beg /s3-console` did not match `/rustfs/*` paths after the console's internal redirect to `/rustfs/console/` — the browser landed on Nextcloud 404; (2) `RUSTFS_SERVER_DOMAINS` was not set, causing RustFS to reject logins from the external domain; (3) the console JS makes browser-side S3 API calls (`POST /`, `GET /`) which HAProxy was forwarding to Nextcloud — a new ACL `is_s3_api` routes requests with `Authorization: AWS4-HMAC-SHA256` header to the RustFS S3 backend (port 9000)
- **HAProxy method filter blocked console operations** — PUT/DELETE on `/rustfs/*` were denied by the WebDAV method ACL (`is_api_path`); `/rustfs` added to the allowed-path list so bucket/object management from the console works correctly
- **Sticky session cookie for console** — without `cookie RUSTFS_CONSOLE insert`, HAProxy could route mid-session requests to a different node, causing auth loops; sticky session now pins the browser session to one node via `RC1..RCN` cookie values
- **IFS word-split bug in `gen_compose`** — `IFS=$'\n\t'` (set globally in deploy.sh line 7) prevented space-based word-splitting of `$rustfs_volumes_val` in the `for _url in ...` loop. All URLs were concatenated into a single YAML list item instead of separate items, so the entrypoint received one big string as a single argument. Fixed with `read -r -a` array split
- **`RUSTFS_SERVER_DOMAINS` missing from generated compose** — `gen_compose()` and `docker-compose.yml` now include `RUSTFS_SERVER_DOMAINS=${NC_DOMAIN}` in all RustFS node environments

### Changed
- **RustFS image pinned to `1.0.0-beta.6`** — replaces `:latest` for reproducible deployments; last tested and validated version
- **`mc` (minio/mc) removed** — no longer used; bucket versioning step removed from post-install (versioning is already active by default in the deployed bucket and can be managed via `/s3-console`)
- **RustFS console route** — `/s3-console` now issues a 301 redirect to `/rustfs/console/` (the console's native base path); HAProxy routes `path_beg /rustfs` to port 9001 without path stripping; a dedicated `backend rustfs-s3api` handles browser-side S3 calls via the `is_s3_api` ACL

### Docs
- RustFS beta warning added to object storage section: pool rebalancing and decommission return 501 (not implemented in v1.0.0-beta.6); `mc admin` protocol not supported
- RustFS console section updated with accurate HAProxy routing, `RUSTFS_SERVER_DOMAINS` requirement, sticky session, and AWS4 S3 routing explanation
- Image update procedure corrected: quick update does not change versions (no `gen_compose` call); a full deploy is required when modifying `IMG_*` variables
- Historical CHANGELOG entries restored: pre-migration sections (v2.1.x–v2.3.x) incorrectly had "MinIO" replaced by "RustFS"; original entries now accurate
- RustFS scale-up documented as unsupported in beta (`formats length for erasure.sets does not match`)

---

## [2.4.1] — 2026-06-01

### Fixed
- **RustFS distributed mode — command args, not env var** — after auditing the official `entrypoint.sh`, `RUSTFS_VOLUMES` with HTTP URLs is silently skipped by the entrypoint (only absolute paths are processed). Volume URLs for multi-node mode are now passed as YAML list-form `command:` args so the entrypoint receives each URL as a separate `$@` argument and prepends `/usr/bin/rustfs`. `RUSTFS_VOLUMES=none` suppresses the entrypoint's default `/data` fallback
- **Shell-form command would break entrypoint dispatch** — a quoted YAML `command: "http://..."` string is wrapped by Docker Compose as `/bin/sh -c "string"`, causing the entrypoint to receive `/bin/sh` as `$1` and call rustfs incorrectly. Switched to YAML list form (`command: [url1, url2, ...]`) which passes each URL as a separate positional argument
- **Health check endpoint** — changed from generic HTTP response check to the documented `/health` endpoint (`curl -sf http://localhost:9000/health`), now also used in `check_deploy()`
- **Removed `user: root`** — RustFS container defaults to UID 10001; `create_rustfs_dirs()` pre-chowns data directories on the host before container start
- **`gen_rustfs_volumes_env()` rewritten** — single-node returns space-separated absolute paths (for `RUSTFS_VOLUMES`); multi-node and multi-pool return fully-expanded explicit HTTP URLs (for `command:` args), with no brace notation

---

## [2.4.0] — 2026-06-01

### Changed
- **Migrated from MinIO to RustFS** — object storage backend replaced by [RustFS](https://rustfs.com) (`rustfs/rustfs:latest`), an S3-compatible, Apache 2.0 licensed, high-performance distributed object store written in Rust. All `MINIO_*` environment variables renamed to `RUSTFS_*`. Container names changed from `minio-node*` to `rustfs-node*`. Erasure coding, pool expansion, and S3 API compatibility maintained. `RUSTFS_VOLUMES` env var (RustFS cluster mode) replaces the MinIO `server` positional argument
- **Built-in RustFS console** — the separate `georgmangold/console` container is replaced by the console built into `rustfs/rustfs` (port 9001). HAProxy routes `/s3-console` to `rustfs-node*:9001` — no extra container required. Enabled via `RUSTFS_CONSOLE_ENABLE=true` during deployment
- **Automatic node failure recovery** — RustFS handles erasure-coded data healing automatically when a node returns; no manual `mc admin heal` step required

---

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
