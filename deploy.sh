#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Azure NXT Maxscale — Automatic Deployer v2.5.2
# Usage: sudo bash deploy.sh
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# Guard: _SOURCE_ONLY=1 must be set BEFORE sourcing this file (tests).
# Defaults to 0 — works in all contexts (bash -c, curl|bash, file).
: "${_SOURCE_ONLY:=0}"

INSTALL_DIR="/opt/nxt-maxscale"
COMPOSE_PROJECT_NAME="maxscale"
REPO_URL="https://github.com/oboeglen/Azure-NXT-Maxscale"
ANSWERS_CACHE="/tmp/.nxt-maxscale-config.env"
LOG_FILE="/var/log/nxt-maxscale-deploy.log"
CERTBOT_STAGING="no"

# ─── Images — pinned versions ─────────────────────────────────────────────────
IMG_CERTBOT="certbot/certbot:v5.6.0"
IMG_AUTOHEAL="willfarrell/autoheal:latest"
IMG_RUSTFS="rustfs/rustfs:1.0.0-beta.6"
IMG_COLLABORA="collabora/code:25.04.9.4.1"
IMG_WHITEBOARD="ghcr.io/nextcloud-releases/whiteboard:v1.5.8"
IMG_SPREED_SIGNALING="strukturag/nextcloud-spreed-signaling:latest"
IMG_COTURN="coturn/coturn:4.6"
IMG_HAPROXY="haproxy:2.8-alpine"
IMG_NGINX="nginx:1.27-alpine"
IMG_REDIS="redis:7.4-alpine"
IMG_MARIADB="maxscale-mariadb-galera:11.4"

# ─── Colors ──────────────────────────────────────────────────────────────────
C_RESET='\033[0m'
C_CYAN='\033[0;36m';  C_BCYAN='\033[1;36m'
C_GREEN='\033[0;32m'; C_BGREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m';   C_BRED='\033[1;31m'
C_WHITE='\033[1;37m'; C_GRAY='\033[0;37m'

# ─── UI helpers ──────────────────────────────────────────────────────────────
info()    { echo -e " ${C_BGREEN}✓${C_RESET}  $*"; }
warn()    { echo -e " ${C_YELLOW}!${C_RESET}  $*"; }
error()   { echo -e " ${C_BRED}✗${C_RESET}  $*" >&2; }
die()     { error "$*"; exit 1; }
step()    { echo -e "\n${C_BCYAN}  ▸ $*${C_RESET}"; }

# Visual width of a string: strips ANSI codes, counts characters (not bytes)
_vlen() {
  local s
  s=$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*[mK]//g')
  echo ${#s}
}

# Pads $1 with spaces to visual width $2
_rpad() {
  local s="$1" w="$2" vw n
  vw=$(_vlen "$s")
  printf '%s' "$s"
  n=$(( w - vw ))
  if (( n > 0 )); then printf '%*s' "$n" ''; fi
}

phase() {
  local n="$1" total="$2" name="$3"
  local INNER=56
  echo ""
  printf "${C_BCYAN}╔"; printf '═%.0s' $(seq 1 $INNER); printf "╗${C_RESET}\n"
  local prefix="  PHASE ${n}/${total} — "
  local prefix_len; prefix_len=$(_vlen "$prefix")
  printf "${C_BCYAN}║${C_RESET}%s" "$prefix"
  _rpad "$name" $(( INNER - prefix_len ))
  printf "${C_BCYAN}║${C_RESET}\n"
  printf "${C_BCYAN}╚"; printf '═%.0s' $(seq 1 $INNER); printf "╝${C_RESET}\n"
}

box() {
  local title="$1"; shift

  # Auto width: adapts to the longest content line
  local max_content=0 line lw
  for line in "$@"; do
    lw=$(_vlen "$line")
    (( lw > max_content )) && max_content=$lw
  done

  # Geometry: total = │(1) + 2sp + inner + │(1) = inner + 4
  local title_len; title_len=$(_vlen "$title")
  local inner=$max_content
  local total=$(( inner + 4 ))
  local min_total=$(( title_len + 6 ))   # ┌─ T ─┐ : at least 1 dash
  if (( total < min_total )); then total=$min_total; inner=$(( total - 4 )); fi

  printf "\n${C_CYAN}┌─ %s " "$title"
  printf '─%.0s' $(seq 1 $(( total - title_len - 5 )))
  printf "┐${C_RESET}\n"
  for line in "$@"; do
    printf "${C_CYAN}│${C_RESET}  "
    _rpad "$line" "$inner"
    printf "${C_CYAN}│${C_RESET}\n"
  done
  printf "${C_CYAN}└"
  printf '─%.0s' $(seq 1 $(( total - 2 )))
  printf "┘${C_RESET}\n"
}

setup_logging() {
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/nxt-maxscale-deploy.log"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  # Duplicate stdout+stderr to log without disturbing output
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "Log file: $LOG_FILE"
}

check_requirements() {
  step "Checking system requirements"

  # RAM
  local ram_kb ram_gb
  ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  ram_gb=$(( ram_kb / 1024 / 1024 ))
  if (( ram_kb < 14680064 )); then
    warn "RAM: ${ram_gb} GB detected (recommended minimum: 16 GB)"
    prompt_yn "Continue anyway?" "Y" || die "Aborted — add more RAM and retry."
  else
    info "RAM: ${ram_gb} GB ✓"
  fi

  # Disk
  local disk_kb disk_gb
  disk_kb=$(df -k "$(dirname "$INSTALL_DIR")" 2>/dev/null | awk 'NR==2{print $4}' || df -k / | awk 'NR==2{print $4}')
  disk_gb=$(( disk_kb / 1024 / 1024 ))
  if (( disk_kb < 52428800 )); then
    warn "Free space: ${disk_gb} GB (recommended minimum: 50 GB)"
    prompt_yn "Continue anyway?" "N" || die "Aborted — free up disk space and retry."
  else
    info "Disk: ${disk_gb} GB available ✓"
  fi

  # Docker version
  local docker_ver
  docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null | grep -oE '^[0-9]+' || echo "0")
  if (( docker_ver < 20 )); then
    die "Docker ${docker_ver} is too old — version ≥ 20 required. Re-run the script to update it."
  fi
  info "Docker ${docker_ver} ✓"

  # Docker Compose v2
  local compose_maj
  compose_maj=$(docker compose version --short 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")
  if (( compose_maj < 2 )); then
    die "Docker Compose v${compose_maj} is too old — version ≥ 2 required."
  fi
  info "Docker Compose v2 ✓"
}

SPINNER_PID=""
start_spinner() {
  local msg="$1"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  (
    local i=0
    while true; do
      printf "\r ${C_CYAN}${frames[$i]}${C_RESET}  %s" "$msg"
      i=$(( (i+1) % 10 ))
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null || true
}

stop_spinner() {
  local msg="${1:-}"
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi
  printf "\r\033[K"
  [[ -n "$msg" ]] && info "$msg"
}

progress_bar() {
  local current="$1" total="$2" label="$3"
  [[ $total -eq 0 ]] && total=1
  local pct=$(( current * 100 / total ))
  local filled=$(( pct * 30 / 100 ))
  local empty=$(( 30 - filled ))
  local bar=""
  local i
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty;  i++)); do bar+="░"; done
  printf "\r\033[K  ${C_CYAN}[%s]${C_RESET} %3d%%  %s" "$bar" "$pct" "$label"
}

show_banner() {
  clear
  local inner=62 border
  border=$(printf '═%.0s' $(seq 1 $inner))
  echo ""
  printf "  ${C_BCYAN}╔%s╗${C_RESET}\n" "$border"
  for line in \
    "    █████╗ ███████╗██╗   ██╗██████╗ ███████╗" \
    "   ██╔══██╗╚══███╔╝██║   ██║██╔══██╗██╔════╝" \
    "   ███████║  ███╔╝ ██║   ██║██████╔╝█████╗" \
    "   ██╔══██║ ███╔╝  ██║   ██║██╔══██╗██╔══╝" \
    "   ██║  ██║███████╗╚██████╔╝██║  ██║███████╗" \
    "        NXT Maxscale — Automatic Deployer v2.5.2"; do
    printf "  ${C_BCYAN}║${C_RESET}"
    _rpad "$line" "$inner"
    printf "${C_BCYAN}║${C_RESET}\n"
  done
  printf "  ${C_BCYAN}╚%s╝${C_RESET}\n" "$border"
  echo ""
}

prompt_input() {
  local question="$1" default="${2:-}"
  if [[ -n "$default" ]]; then
    printf "  ${C_WHITE}%s${C_RESET} ${C_GRAY}[%s]${C_RESET} : " "$question" "$default"
  else
    printf "  ${C_WHITE}%s${C_RESET} : " "$question"
  fi
  read -r REPLY
  [[ -z "$REPLY" && -n "$default" ]] && REPLY="$default"
}

prompt_yn() {
  local question="$1" default="${2:-N}"
  local hint
  [[ "${default^^}" == "Y" ]] && hint="Y/n" || hint="y/N"
  printf "  ${C_WHITE}%s${C_RESET} ${C_GRAY}[%s]${C_RESET} : " "$question" "$hint"
  read -r REPLY
  [[ -z "$REPLY" ]] && REPLY="$default"
  [[ "${REPLY,,}" == "o" || "${REPLY,,}" == "y" ]]
}

# ─── [OS] Detection and installation ─────────────────────────────────────────

# Internal: pure logic, testable without /etc/os-release
# Args: $1=ID $2=ID_LIKE $3=VERSION_ID
# Sets globals: OS_ID, OS_VERSION, PKG_MGR
# Echoes the detected OS_ID
_detect_os_logic() {
  local id="$1" id_like="${2:-}" version="$3"
  OS_ID=""; OS_VERSION="$version"; PKG_MGR=""

  case "$id" in
    debian)
      [[ "$version" =~ ^(11|12|13)$ ]] || die "Debian $version not supported (11, 12 or 13 required)"
      OS_ID="debian"; PKG_MGR="apt"
      ;;
    ubuntu)
      [[ "$version" =~ ^(22\.04|24\.04)$ ]] || die "Ubuntu $version not supported (22.04 or 24.04 required)"
      OS_ID="ubuntu"; PKG_MGR="apt"
      ;;
    rhel|centos|rocky|almalinux)
      [[ "$version" =~ ^[89] ]] || die "RHEL/Rocky/Alma $version not supported (8.x or 9.x required)"
      OS_ID="rhel"; PKG_MGR="dnf"
      ;;
    *)
      if echo "$id_like" | grep -qE "rhel|fedora"; then
        [[ "$version" =~ ^[89] ]] || die "RHEL-like $version not supported (8.x or 9.x required)"
        OS_ID="rhel"; PKG_MGR="dnf"
      else
        die "OS '$id' not supported. Accepted distributions: Debian 11/12/13, Ubuntu 22.04/24.04, RHEL/Rocky/AlmaLinux 8/9"
      fi
      ;;
  esac
  echo "$OS_ID"
}

detect_os() {
  phase 1 7 "System Detection"
  [[ -f /etc/os-release ]] || die "/etc/os-release not found — OS cannot be detected"

  local ID="" ID_LIKE="" VERSION_ID=""
  # shellcheck source=/dev/null
  source /etc/os-release
  _detect_os_logic "$ID" "${ID_LIKE:-}" "$VERSION_ID" > /dev/null

  info "Detected OS: ${OS_ID} ${OS_VERSION} (package manager: ${PKG_MGR})"
  [[ "$(uname -m)" == "x86_64" ]] || die "x86_64 architecture required (detected: $(uname -m))"
  [[ $EUID -eq 0 ]] || die "This script must be run as root: sudo bash deploy.sh"
}

install_deps() {
  phase 2 7 "Installing Dependencies"

  # netcat-openbsd  : nc (signaling health checks, port tests)
  # xfsprogs        : mkfs.xfs, xfs_repair (disk wizard — XFS format)
  # e2fsprogs       : mkfs.ext4, e2fsck   (disk wizard — EXT4 format)
  # util-linux      : lsblk, blkid, findmnt (disk detection)
  # dnsutils/bind-utils : dig (DNS verification in gen_certs)
  local pkgs_apt=(
    git curl wget openssl python3 ca-certificates gnupg lsb-release
    netcat-openbsd xfsprogs e2fsprogs util-linux dnsutils
  )
  local pkgs_dnf=(
    git curl wget openssl python3 ca-certificates gnupg2
    nmap-ncat xfsprogs e2fsprogs util-linux bind-utils
  )

  step "Updating sources and installing essential packages"
  start_spinner "Updating packages..."
  if [[ "$PKG_MGR" == "apt" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    stop_spinner "Package sources updated"
    start_spinner "Installing essential packages..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs_apt[@]}"
  else
    dnf makecache -q
    stop_spinner "Package sources updated"
    start_spinner "Installing essential packages..."
    dnf install -y -q "${pkgs_dnf[@]}"
  fi
  stop_spinner "Essential packages installed"

  # Docker Engine
  if ! command -v docker &>/dev/null; then
    step "Installing Docker Engine"
    start_spinner "Downloading Docker installation script..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    stop_spinner "Docker script downloaded"
    start_spinner "Installing Docker (this may take a few minutes)..."
    bash /tmp/get-docker.sh -q
    stop_spinner "Docker installed"
    systemctl enable --now docker
  else
    info "Docker $(docker --version | cut -d' ' -f3 | tr -d ',') already installed"
  fi

  # Docker Compose plugin
  if ! docker compose version &>/dev/null 2>&1; then
    step "Installing Docker Compose plugin"
    local os_name compose_arch
    os_name=$(uname -s)
    compose_arch=$(uname -m)
    local compose_url="https://github.com/docker/compose/releases/latest/download/docker-compose-${os_name}-${compose_arch}"
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL "$compose_url" -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    info "Docker Compose $(docker compose version --short) installed"
  else
    info "Docker Compose $(docker compose version --short) already installed"
  fi

  # Docker log rotation — 100 MB × 3 files per container (~300 MB max)
  local daemon_json="/etc/docker/daemon.json"
  if [[ ! -f "$daemon_json" ]] || ! grep -q "max-size" "$daemon_json" 2>/dev/null; then
    cat > "$daemon_json" <<'DAEMON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
DAEMON
    systemctl reload docker 2>/dev/null || true
    info "Docker log rotation configured (100 MB × 3 files)"
  else
    info "Docker log rotation already configured"
  fi

  # Check docker access for non-root user
  local real_user="${SUDO_USER:-}"
  if [[ -n "$real_user" ]] && ! groups "$real_user" | grep -q docker; then
    usermod -aG docker "$real_user" 2>/dev/null || true
    warn "User '$real_user' was added to the docker group — log out and back in for this to take effect"
  fi
}

# ─── [CLONE] Project retrieval ───────────────────────────────────────────────

clone_repo() {
  phase 3 7 "Project Retrieval"

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    warn "Directory $INSTALL_DIR already exists"
    if prompt_yn "Update repository (git pull)?" "Y"; then
      start_spinner "Updating repository..."
      GIT_TERMINAL_PROMPT=0 timeout 120 git -C "$INSTALL_DIR" fetch origin || {
        stop_spinner
        die "Cannot reach $REPO_URL — check network connectivity"
      }
      git -C "$INSTALL_DIR" reset --hard origin/main
      stop_spinner "Repository updated"
    else
      info "Using existing repository"
    fi
  else
    # Detect local source directory (script launched from a project copy)
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _sentinel_files=(haproxy.cfg nextcloud-init.sh galera-bootstrap.sh)
    local _all_present=true
    for _f in "${_sentinel_files[@]}"; do
      [[ -f "$SCRIPT_DIR/$_f" ]] || { _all_present=false; break; }
    done

    if $_all_present && [[ "$SCRIPT_DIR" != "$INSTALL_DIR" ]]; then
      step "Local files detected in $SCRIPT_DIR — local copy (no Git clone)"
      start_spinner "Copying files to $INSTALL_DIR..."
      mkdir -p "$INSTALL_DIR"
      cp -a "$SCRIPT_DIR/." "$INSTALL_DIR/"
      stop_spinner "Files copied to $INSTALL_DIR"
    else
      start_spinner "Cloning from $REPO_URL..."
      if ! GIT_TERMINAL_PROMPT=0 timeout 120 git clone --depth=1 "$REPO_URL" "$INSTALL_DIR"; then
        stop_spinner
        die "Clone failed — check:\n  • Connectivity: curl -sf https://github.com\n  • Public repo: $REPO_URL\n  • Alternative: copy files to $INSTALL_DIR and retry"
      fi
      stop_spinner "Project cloned into $INSTALL_DIR"
    fi
  fi

  cd "$INSTALL_DIR"
  info "Working directory: $INSTALL_DIR"
}

# ─── [CONFIG] User questions ─────────────────────────────────────────────────

# --- Validation helpers ---
validate_domain() {
  local d="$1"
  [[ "$d" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}$ ]]
}

is_positive_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_non_neg_int()  { [[ "$1" =~ ^[0-9]+$ ]]; }
is_odd()          { is_positive_int "$1" && (( $1 % 2 == 1 )); }
is_even_min6()    { is_positive_int "$1" && (( $1 % 2 == 0 )) && (( $1 >= 6 )); }

# ask_int "question" "default" validator_fn "error message" VARNAME
# Stores result in VARNAME (no subshell, no stdout capture)
ask_int() {
  local question="$1" default="$2" validator="$3" errmsg="$4" __var="${5:-_ASK_INT_RESULT}"
  while true; do
    prompt_input "$question" "$default"
    local val="$REPLY"
    if $validator "$val"; then
      printf -v "$__var" '%s' "$val"
      return
    fi
    error "$errmsg"
  done
}

check_dns_warn() {
  local domain="$1"
  if ! host "$domain" &>/dev/null 2>&1; then
    warn "DNS: $domain does not resolve yet"
    if ! prompt_yn "Continue anyway?" "N"; then
      die "Aborted — configure your DNS and retry"
    fi
  else
    info "DNS $domain → OK"
  fi
}

# --- ask_domains ---
ask_domains() {
  step "Domains and email"

  while true; do
    prompt_input "Nextcloud domain" "nextcloud.example.tld"
    NC_DOMAIN="$REPLY"
    validate_domain "$NC_DOMAIN" && break
    error "Invalid format (e.g.: nextcloud.my-site.com)"
  done

  while true; do
    prompt_input "Collabora domain" "collabora.example.tld"
    COLLAB_DOMAIN="$REPLY"
    validate_domain "$COLLAB_DOMAIN" && break
    error "Invalid format"
  done

  while true; do
    prompt_input "Whiteboard domain" "whiteboard.example.tld"
    WB_DOMAIN="$REPLY"
    validate_domain "$WB_DOMAIN" && break
    error "Invalid format"
  done

  echo ""
  if prompt_yn "Deploy Talk HA signaling backend?" "Y"; then
    TALK_ENABLED="yes"
    while true; do
      prompt_input "Talk signaling domain" "talk.example.tld"
      TALK_DOMAIN="$REPLY"
      validate_domain "$TALK_DOMAIN" && break
      error "Invalid format"
    done
  else
    TALK_ENABLED="no"
    TALK_DOMAIN=""
    info "Talk HA disabled — Nextcloud Talk will use the built-in signaling (limited scalability)"
  fi

  while true; do
    prompt_input "Let's Encrypt email" "admin@example.tld"
    CERTBOT_EMAIL="$REPLY"
    [[ "$CERTBOT_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] && break
    error "Invalid email"
  done

  step "DNS Check"
  check_dns_warn "$NC_DOMAIN"
  check_dns_warn "$COLLAB_DOMAIN"
  check_dns_warn "$WB_DOMAIN"
  [[ "$TALK_ENABLED" == "yes" ]] && check_dns_warn "$TALK_DOMAIN"
}

# --- ask_versions ---
ask_versions() {
  step "Nextcloud Version"
  prompt_input "Nextcloud version" "33.0.3-fpm"
  NC_VERSION="$REPLY"
  [[ "$NC_VERSION" == *"-fpm" ]] || NC_VERSION="${NC_VERSION}-fpm"
  info "Image: nextcloud:${NC_VERSION}"
}

# --- ask_nodes ---
ask_nodes() {
  phase 4 7 "Configuration"
  step "Number of nodes per service"

  ask_int "Nextcloud — FPM+nginx nodes  (1 node = 1 FPM container + 1 nginx)" "3" is_positive_int "Integer ≥ 1 required" NC_NODES
  ask_int "MariaDB Galera — nodes"     "3" is_odd          "Odd number required (Galera quorum — prevents split-brain)" MARIADB_NODES
  ask_int "Redis Cluster — nodes"      "6" is_even_min6    "Even number ≥ 6 required (masters + replicas)"              REDIS_NODES
  ask_int "Collabora — nodes"          "3" is_positive_int "Integer ≥ 1 required"                                       COLLAB_NODES
  ask_int "Whiteboard — nodes"         "2" is_positive_int "Integer ≥ 1 required"                                       WB_NODES
  ask_int "RustFS — nodes"             "4" is_positive_int "Integer ≥ 1 required"                                       RUSTFS_NODES
  ask_int "RustFS — disks per node"    "4" is_positive_int "Integer ≥ 1 required"                                       RUSTFS_DISKS
}

# ─── [RUSTFS] Disk wizard helpers ─────────────────────────────────────────────

# Returns "nvme", "ssd", or "hdd" for a given block device
_detect_disk_type() {
  local dev="$1"
  local base; base=$(basename "$dev" | sed 's/[0-9]*p\?[0-9]*$//' | sed 's/[0-9]*$//')
  [[ "$base" =~ ^nvme ]] && echo "nvme" && return
  local rot
  rot=$(cat "/sys/block/${base}/queue/rotational" 2>/dev/null || echo "1")
  [[ "$rot" == "0" ]] && echo "ssd" || echo "hdd"
}

# Returns disk size in GB (integer)
_disk_size_gb() {
  local dev="$1"
  local bytes
  bytes=$(lsblk -bdno SIZE "$dev" 2>/dev/null | head -1 || true)
  [[ -z "$bytes" || "$bytes" == "0" ]] && echo "0" && return
  echo $(( bytes / 1024 / 1024 / 1024 ))
}

# Sets globals XFS_MKFS_OPTS (array), XFS_MOUNT_OPTS, XFS_PROFILE_DESC
# based on disk type and size — tuned for RustFS object storage workloads
_xfs_profile() {
  local disk_type="$1" size_gb="$2"

  # Log size: XFS write-ahead log — default 10MB is far too small for RustFS.
  # Larger log reduces per-write latency by amortising commits over more data.
  # Allocation groups: parallelism units. More AGs benefit multi-threaded I/O.
  # HDDs are sequential-bound so fewer AGs are better (less head seeking).
  local log_size agcount
  if   (( size_gb >= 8000 )); then log_size="256m"; agcount=32
  elif (( size_gb >= 2000 )); then log_size="256m"; agcount=16
  elif (( size_gb >= 500  )); then log_size="128m"; agcount=8
  else                              log_size="64m";  agcount=4
  fi

  # HDDs: halve agcount (sequential workload — fewer AGs reduces head travel)
  if [[ "$disk_type" == "hdd" ]]; then
    agcount=$(( agcount / 2 ))
    (( agcount < 2 )) && agcount=2
  fi

  # Skip agcount on very small disks to avoid mkfs minimum-AG-size errors
  XFS_MKFS_OPTS=(-l "size=${log_size},lazy-count=1")
  (( size_gb >= 10 )) && XFS_MKFS_OPTS+=(-d "agcount=${agcount}")

  # allocsize: preallocate on write to reduce fragmentation for large objects
  # logbsize:  in-memory log buffer (256k = max; cuts expensive log flushes)
  # largeio:   HDD hint — suggests kernel uses larger I/O units
  case "$disk_type" in
    nvme) XFS_MOUNT_OPTS="noatime,nodiratime,allocsize=64m,logbsize=256k"
          XFS_PROFILE_DESC="NVMe — log=${log_size}, ${agcount} AGs, allocsize=64m, logbsize=256k" ;;
    ssd)  XFS_MOUNT_OPTS="noatime,nodiratime,allocsize=64m,logbsize=256k"
          XFS_PROFILE_DESC="SSD — log=${log_size}, ${agcount} AGs, allocsize=64m, logbsize=256k" ;;
    hdd)  XFS_MOUNT_OPTS="noatime,nodiratime,allocsize=64m,logbsize=256k,largeio"
          XFS_PROFILE_DESC="HDD — log=${log_size}, ${agcount} AGs, allocsize=64m, logbsize=256k, largeio" ;;
  esac
}

# Sets globals EXT4_MKFS_OPTS (array), EXT4_MOUNT_OPTS, EXT4_PROFILE_DESC
_ext4_profile() {
  local disk_type="$1" size_gb="$2"
  # Journal size: larger = fewer forced commits per second under write load
  local journal_size
  (( size_gb >= 500 )) && journal_size="256" || journal_size="128"
  # lazy_itable_init=0: initialise inode tables immediately (no background init)
  EXT4_MKFS_OPTS=(-b 4096 -E "lazy_itable_init=0,lazy_journal_init=0" -J "size=${journal_size}")
  EXT4_MOUNT_OPTS="noatime,nodiratime,data=ordered"
  EXT4_PROFILE_DESC="journal=${journal_size}MB, data=ordered"
}

# Verify that disk formatting tools are present before the wizard runs.
_check_disk_tools() {
  local missing=()
  command -v lsblk   &>/dev/null || missing+=("lsblk (util-linux)")
  command -v blkid   &>/dev/null || missing+=("blkid (util-linux)")
  command -v findmnt &>/dev/null || missing+=("findmnt (util-linux)")
  command -v mkfs.xfs  &>/dev/null || missing+=("mkfs.xfs (xfsprogs)")
  command -v mkfs.ext4 &>/dev/null || missing+=("mkfs.ext4 (e2fsprogs)")
  if (( ${#missing[@]} > 0 )); then
    error "Missing tools required for the disk wizard:"
    for t in "${missing[@]}"; do
      error "  • $t"
    done
    die "Install the listed packages and retry."
  fi
}

# Scans available block devices (excludes root disk, swap, loop).
# Populates globals: DISK_COUNT, DISK_NAMES[], DISK_SIZES[], DISK_FSTYPES[],
#                    DISK_MOUNTS[], DISK_MODELS[]
_scan_available_disks() {
  DISK_COUNT=0
  DISK_NAMES=(); DISK_SIZES=(); DISK_FSTYPES=(); DISK_MOUNTS=(); DISK_MODELS=()

  # Identify root disk to exclude it and all its partitions
  local root_source root_disk
  root_source=$(findmnt -n -o SOURCE / 2>/dev/null || df / 2>/dev/null | awk 'NR==2{print $1}')
  root_disk=$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -1 | tr -d '[:space:]')
  [[ -z "$root_disk" ]] && root_disk=$(basename "$root_source" | sed 's/[0-9]*$//')

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local name size fstype mount model
    # Use --pairs (-P) output: NAME="/dev/sda" SIZE="5.5T" FSTYPE="" MOUNTPOINT="" MODEL="..."
    # awk field-splitting breaks when FSTYPE/MOUNTPOINT are empty (adjacent spaces collapse)
    name=$(  grep -oP 'NAME="\K[^"]*'       <<< "$line")
    size=$(  grep -oP 'SIZE="\K[^"]*'       <<< "$line")
    fstype=$(grep -oP 'FSTYPE="\K[^"]*'     <<< "$line")
    mount=$( grep -oP 'MOUNTPOINT="\K[^"]*' <<< "$line")
    model=$( grep -oP 'MODEL="\K[^"]*'      <<< "$line")

    # Skip root disk and its children
    [[ -n "$root_disk" && "$name" == "/dev/${root_disk}"* ]] && continue
    # Skip swap, loop, critical mounts
    [[ "$fstype" == "swap" ]] && continue
    [[ "$mount" == "/" || "$mount" =~ ^/boot ]] && continue
    [[ "$name" =~ /loop ]] && continue

    # Try blkid for filesystem type if lsblk returned nothing
    if [[ -z "$fstype" ]]; then
      fstype=$(blkid -s TYPE -o value "$name" 2>/dev/null || true)
    fi

    DISK_NAMES[$DISK_COUNT]="$name"
    DISK_SIZES[$DISK_COUNT]="$size"
    DISK_FSTYPES[$DISK_COUNT]="${fstype:--}"
    DISK_MOUNTS[$DISK_COUNT]="${mount:--}"
    DISK_MODELS[$DISK_COUNT]="${model:--}"
    (( DISK_COUNT++ )) || true
  done < <(lsblk -P -p -n -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL 2>/dev/null)
}

# Prints the candidate disk table
_show_disk_table() {
  echo ""
  printf "  ${C_WHITE}%-5s  %-18s  %-7s  %-8s  %-22s  %s${C_RESET}\n" \
    "No." "Device" "Size" "FS" "Mountpoint" "Model"
  printf "  %-5s  %-18s  %-7s  %-8s  %-22s  %s\n" \
    "---" "------" "----" "--" "----------" "-----"
  local i
  for i in $(seq 0 $(( DISK_COUNT - 1 ))); do
    local fs="${DISK_FSTYPES[$i]}" mnt="${DISK_MOUNTS[$i]}" col="$C_GRAY"
    [[ "$fs"  != "-" ]] && col="$C_YELLOW"
    [[ "$mnt" != "-" ]] && col="$C_BGREEN"
    printf "  ${C_CYAN}[%-2d]${C_RESET}  %-18s  %-7s  ${col}%-8s${C_RESET}  %-22s  %s\n" \
      $(( i + 1 )) "${DISK_NAMES[$i]}" "${DISK_SIZES[$i]}" \
      "$fs" "$mnt" "${DISK_MODELS[$i]}"
  done
  echo ""
}

# Checks / formats / mounts a disk and adds it to fstab if needed.
# Args: dev mount_path current_fs preferred_fs
_prepare_rustfs_disk() {
  local dev="$1" mount_path="$2" current_fs="$3" preferred_fs="$4"

  # Already mounted at target — nothing to do
  if mountpoint -q "$mount_path" 2>/dev/null; then
    info "$dev already mounted at $mount_path — using as-is"
    return 0
  fi

  local chosen_fs="$preferred_fs"

  # ── Detect disk profile (type + size) ───────────────────────────────────
  local disk_type size_gb
  disk_type=$(_detect_disk_type "$dev")
  size_gb=$(_disk_size_gb "$dev")

  # Pre-compute tuning params (globals XFS_*/EXT4_* set by profile functions)
  _xfs_profile  "$disk_type" "$size_gb"
  _ext4_profile "$disk_type" "$size_gb"

  # ── Format if no filesystem ──────────────────────────────────────────────
  if [[ "$current_fs" == "-" || -z "$current_fs" ]]; then
    echo ""
    warn "No filesystem detected on $dev"
    local alt_fs; [[ "$preferred_fs" == "xfs" ]] && alt_fs="ext4" || alt_fs="xfs"
    echo -e "  ${C_WHITE}Filesystem to create on ${dev}?${C_RESET}"
    echo -e "  ${C_CYAN}[1]${C_RESET} ${preferred_fs^^}  ${C_GRAY}(default — recommended for object storage)${C_RESET}"
    echo -e "  ${C_CYAN}[2]${C_RESET} ${alt_fs^^}"
    echo ""
    prompt_input "Choice" "1"
    [[ "$REPLY" == "2" ]] && chosen_fs="$alt_fs"
    echo ""
    warn "⚠  This will PERMANENTLY erase all data on ${dev}."
    prompt_yn "Format ${dev} as ${chosen_fs^^}?" "N" || die "Format cancelled — aborting"

    local label; label="rustfs-$(basename "$dev")"

    if [[ "$chosen_fs" == "xfs" ]]; then
      # shellcheck disable=SC2086
      info "XFS profile: ${XFS_PROFILE_DESC}"
      start_spinner "Formatting $dev as XFS (${size_gb}GB ${disk_type^^})..."
      local _mkfs_out
      _mkfs_out=$(mkfs.xfs -f -L "$label" "${XFS_MKFS_OPTS[@]}" "$dev" 2>&1) \
        || { stop_spinner; die "mkfs.xfs failed on $dev"$'\n'"${_mkfs_out}"; }
    else
      info "EXT4 profile: ${EXT4_PROFILE_DESC}"
      start_spinner "Formatting $dev as EXT4 (${size_gb}GB ${disk_type^^})..."
      local _mkfs_out
      _mkfs_out=$(mkfs.ext4 -F -L "$label" "${EXT4_MKFS_OPTS[@]}" "$dev" 2>&1) \
        || { stop_spinner; die "mkfs.ext4 failed on $dev"$'\n'"${_mkfs_out}"; }
    fi
    stop_spinner "Formatted: $dev → ${chosen_fs^^}"
  else
    chosen_fs="$current_fs"
    info "Existing filesystem on $dev: ${current_fs^^} — skipping format"
    # Show profile for informational purposes even when not formatting
    [[ "$chosen_fs" == "xfs"  ]] && info "XFS mount profile: ${XFS_PROFILE_DESC}"
    [[ "$chosen_fs" == "ext4" ]] && info "EXT4 mount profile: ${EXT4_PROFILE_DESC}"
  fi

  # ── Select mount options based on detected FS and disk profile ───────────
  local mount_opts
  case "$chosen_fs" in
    xfs)  mount_opts="$XFS_MOUNT_OPTS"  ;;
    ext4) mount_opts="$EXT4_MOUNT_OPTS" ;;
    *)    mount_opts="noatime,nodiratime" ;;
  esac

  # ── Create mount point ───────────────────────────────────────────────────
  mkdir -p "$mount_path"

  # ── Check / update /etc/fstab ────────────────────────────────────────────
  local uuid
  uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)
  local in_fstab=false
  if [[ -n "$uuid" ]] && grep -qsE "UUID=${uuid}" /etc/fstab 2>/dev/null; then
    in_fstab=true
    info "$dev (UUID=${uuid:0:8}…) already in /etc/fstab"
  elif grep -qsE "^${dev}[[:space:]]" /etc/fstab 2>/dev/null; then
    in_fstab=true; info "$dev already in /etc/fstab by device path"
  elif grep -qsE "[[:space:]]${mount_path}[[:space:]]" /etc/fstab 2>/dev/null; then
    in_fstab=true; info "$mount_path already in /etc/fstab"
  fi

  if ! $in_fstab; then
    echo ""
    if prompt_yn "Add $dev to /etc/fstab (auto-mount on reboot)?" "Y"; then
      local entry
      if [[ -n "$uuid" ]]; then
        entry="UUID=${uuid}  ${mount_path}  ${chosen_fs}  ${mount_opts}  0 2"
      else
        entry="${dev}  ${mount_path}  ${chosen_fs}  ${mount_opts}  0 2"
      fi
      echo "$entry" >> /etc/fstab
      info "Added to /etc/fstab: ${mount_opts}"
    fi
  fi

  # ── Mount ────────────────────────────────────────────────────────────────
  start_spinner "Mounting $dev at $mount_path..."
  if mount "$mount_path" 2>/dev/null \
      || mount -t "$chosen_fs" "$dev" "$mount_path" 2>/dev/null; then
    stop_spinner "Mounted: $dev → $mount_path"
  else
    stop_spinner
    die "Failed to mount $dev at $mount_path — check filesystem and /etc/fstab entry"
  fi
}

# --- ask_rustfs ---
rustfs_fault_tolerance() {
  local nodes="$1" disks="$2" disk_size_gb="${3:-0}"
  local total=$(( nodes * disks ))
  local tol_read=$(( total / 2 ))
  local tol_write=$(( total / 2 - 1 ))
  echo "Configuration: ${nodes} nodes × ${disks} disks = ${total} drives"
  echo "Erasure coding: $((total/2)) data + $((total/2)) parity"
  echo "→ Up to ${tol_read} drive losses tolerated for reads"
  echo "→ Up to ${tol_write} drive losses tolerated for writes"
  if (( nodes >= 2 )); then
    echo "→ Loss of an entire node (${disks} drives): service maintained"
  else
    echo "→ Single node: no node-level tolerance (testing mode only)"
  fi
  if (( disk_size_gb > 0 )); then
    local raw_gb=$(( nodes * disks * disk_size_gb ))
    local usable_gb=$(( raw_gb / 2 ))
    local raw_tb usable_tb
    raw_tb=$(awk -v r="$raw_gb"    'BEGIN{printf "%.1f", r/1000}')
    usable_tb=$(awk -v u="$usable_gb" 'BEGIN{printf "%.1f", u/1000}')
    echo "Raw capacity   : ${raw_tb} TB  (${nodes}×${disks}×${disk_size_gb} GB)"
    echo "Usable storage : ${usable_tb} TB  (50% overhead for parity — default EC:N/2)"
  fi
}

ask_rustfs() {
  step "RustFS disk configuration (${RUSTFS_NODES} nodes × ${RUSTFS_DISKS} disks)"
  declare -gA RUSTFS_PATHS

  echo ""
  echo -e "  ${C_WHITE}How to configure RustFS disks?${C_RESET}"
  echo -e "  ${C_CYAN}[1]${C_RESET} Single-server test  — /data/rustfs/ (directories created automatically)"
  echo -e "  ${C_CYAN}[2]${C_RESET} Manual paths        — enter mount points manually (disks already prepared)"
  echo -e "  ${C_CYAN}[3]${C_RESET} Disk wizard         — detect disks, select, format and mount automatically"
  echo ""

  local choice
  while true; do
    prompt_input "Choice" "1"
    choice="$REPLY"
    [[ "$choice" =~ ^[123]$ ]] && break
    error "Enter 1, 2 or 3"
  done

  RUSTFS_MODE="test"
  case "$choice" in
    1)
      RUSTFS_MODE="test"
      local n d
      for n in $(seq 1 "$RUSTFS_NODES"); do
        RUSTFS_PATHS["${n}_path"]="/data/rustfs/node${n}"
        for d in $(seq 1 "$RUSTFS_DISKS"); do
          RUSTFS_PATHS["${n}_${d}"]="/data/rustfs/node${n}/data${d}"
        done
      done
      ;;
    2)
      RUSTFS_MODE="manual"
      box "Recommended disk format for RustFS" \
        "Filesystem : XFS  (best for object storage — large sequential I/O)" \
        "             ext4 also supported, but XFS recommended" \
        "" \
        "Format     : mkfs.xfs -f -L rustfs-node1-disk1 /dev/sdX" \
        "Mount opts : noatime,nodiratime  (avoids access-time write overhead)" \
        "" \
        "/etc/fstab : /dev/sdX  /mnt/node1-disk1  xfs  defaults,noatime,nodiratime  0 2" \
        "" \
        "Rules      : 1 physical disk per path — no RAID (RustFS handles erasure coding)" \
        "             Avoid bind-mounts, LVM stripes, or shared NAS mounts" \
        "             All data disks must be the same size for optimal erasure coding"
      echo ""
      local n d
      for n in $(seq 1 "$RUSTFS_NODES"); do
        prompt_input "Node ${n} — metadata path" "/data/rustfs/node${n}"
        RUSTFS_PATHS["${n}_path"]="$REPLY"
        for d in $(seq 1 "$RUSTFS_DISKS"); do
          prompt_input "Node ${n} — Disk ${d}" "/mnt/node${n}-disk${d}"
          RUSTFS_PATHS["${n}_${d}"]="$REPLY"
        done
      done
      ;;
    3)
      RUSTFS_MODE="auto"
      _check_disk_tools
      step "Scanning block devices..."
      _scan_available_disks

      if (( DISK_COUNT == 0 )); then
        warn "No candidate disk found — falling back to manual path entry"
        RUSTFS_MODE="manual"
        local n d
        for n in $(seq 1 "$RUSTFS_NODES"); do
          prompt_input "Node ${n} — metadata path" "/data/rustfs/node${n}"
          RUSTFS_PATHS["${n}_path"]="$REPLY"
          for d in $(seq 1 "$RUSTFS_DISKS"); do
            prompt_input "Node ${n} — Disk ${d}" "/mnt/node${n}-disk${d}"
            RUSTFS_PATHS["${n}_${d}"]="$REPLY"
          done
        done
      else
        info "${DISK_COUNT} disk(s)/partition(s) found"
        _show_disk_table

        # Legend
        echo -e "  ${C_BGREEN}Green${C_RESET} = already mounted   ${C_YELLOW}Yellow${C_RESET} = formatted but not mounted   ${C_GRAY}Gray${C_RESET} = no filesystem"
        echo ""

        # Global filesystem preference for unformatted disks
        local preferred_fs="xfs"
        echo -e "  ${C_WHITE}Default filesystem for unformatted disks?${C_RESET}"
        echo -e "  ${C_CYAN}[1]${C_RESET} XFS   ${C_GRAY}(recommended — optimal for object storage, large sequential I/O)${C_RESET}"
        echo -e "  ${C_CYAN}[2]${C_RESET} EXT4  ${C_GRAY}(more universal, slightly lower throughput)${C_RESET}"
        echo ""
        prompt_input "Choice" "1"
        [[ "$REPLY" == "2" ]] && preferred_fs="ext4"
        info "Default filesystem: ${preferred_fs^^}"
        echo ""

        local total_slots=$(( RUSTFS_NODES * RUSTFS_DISKS ))
        info "Assign ${total_slots} disk(s) — ${RUSTFS_NODES} nodes × ${RUSTFS_DISKS} disks/node"
        echo ""

        # Track already-selected devices to warn on duplicates
        local -a _selected_devs=()

        local n d ci
        for n in $(seq 1 "$RUSTFS_NODES"); do
          for d in $(seq 1 "$RUSTFS_DISKS"); do
            echo ""
            step "Assign: Node ${n} — Disk ${d}"
            _show_disk_table

            while true; do
              prompt_input "Select disk [1-${DISK_COUNT}]" ""
              if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= DISK_COUNT )); then
                ci=$(( REPLY - 1 ))
                # Warn on duplicate selection (allowed but unusual)
                if [[ " ${_selected_devs[*]} " == *" ${DISK_NAMES[$ci]} "* ]]; then
                  warn "${DISK_NAMES[$ci]} is already assigned to another slot"
                  prompt_yn "Use it anyway?" "N" || continue
                fi
                break
              fi
              error "Enter a number between 1 and ${DISK_COUNT}"
            done

            _selected_devs+=("${DISK_NAMES[$ci]}")

            # Auto-detect disk size from first selected disk (all disks should be identical in RustFS)
            if (( n == 1 && d == 1 )); then
              RUSTFS_DISK_SIZE_GB=$(_disk_size_gb "${DISK_NAMES[$ci]}")
            fi

            # Determine mount point (use existing if already mounted)
            local target_mount="/mnt/rustfs-node${n}-disk${d}"
            if [[ "${DISK_MOUNTS[$ci]}" != "-" && -n "${DISK_MOUNTS[$ci]}" ]]; then
              target_mount="${DISK_MOUNTS[$ci]}"
            fi

            _prepare_rustfs_disk \
              "${DISK_NAMES[$ci]}" "$target_mount" \
              "${DISK_FSTYPES[$ci]}" "$preferred_fs"

            # Refresh disk state so the table shows updated FS/mountpoint on next iteration
            _scan_available_disks

            RUSTFS_PATHS["${n}_${d}"]="$target_mount"
          done
          # Metadata path = mount point of first disk of this node
          RUSTFS_PATHS["${n}_path"]="${RUSTFS_PATHS["${n}_1"]}"
        done
      fi
      ;;
  esac

  RUSTFS_BYPASS="false"
  [[ "$RUSTFS_MODE" == "test" ]] && RUSTFS_BYPASS="true"

  echo ""
  if [[ "$RUSTFS_MODE" == "auto" && "${RUSTFS_DISK_SIZE_GB:-0}" -gt 0 ]]; then
    info "Disk size detected automatically: ${RUSTFS_DISK_SIZE_GB} GB per disk"
  else
    step "Estimated usable capacity"
    echo -e "  ${C_GRAY}Disk size per disk — used to calculate real usable storage (erasure coding).${C_RESET}"
    echo -e "  ${C_GRAY}Examples: 4000 ≈ 4 TB · 8000 ≈ 8 TB · 12000 ≈ 12 TB. Enter 0 to skip.${C_RESET}"
    echo ""
    ask_int "Disk size per disk (GB)" "0" is_non_neg_int "Integer ≥ 0 required" RUSTFS_DISK_SIZE_GB
  fi

  local ft_lines
  mapfile -t ft_lines < <(rustfs_fault_tolerance "$RUSTFS_NODES" "$RUSTFS_DISKS" "${RUSTFS_DISK_SIZE_GB:-0}")
  box "RustFS Fault Tolerance" "${ft_lines[@]}"
}

# --- ask_haproxy ---
ask_haproxy() {
  step "HAProxy statistics page (accessible via https://DOMAIN/stats)"
  if prompt_yn "Enable HAProxy stats?" "N"; then
    HAPROXY_STATS="yes"
    info "Stats enabled — password generated automatically"
  else
    HAPROXY_STATS="no"
    info "Stats disabled"
  fi
}

# --- ask_rustfs_console ---
ask_rustfs_console() {
  step "RustFS Console (accessible via https://DOMAIN/s3-console)"
  echo ""
  echo -e "  ${C_WHITE}Web interface to manage RustFS buckets, users and versioning.${C_RESET}"
  echo -e "  ${C_GRAY}Authentication: RustFS credentials (RUSTFS_ACCESS_KEY / RUSTFS_SECRET_KEY).${C_RESET}"
  echo ""
  if prompt_yn "Enable RustFS console?" "N"; then
    RUSTFS_CONSOLE="yes"
    info "RustFS console enabled — accessible via /s3-console"
  else
    RUSTFS_CONSOLE="no"
    info "RustFS console disabled"
  fi
}

# --- ask_talk ---
ask_talk() {
  if [[ "${TALK_ENABLED:-no}" != "yes" ]]; then
    SIGNALING_NODES=0
    COTURN_ENABLED="no"
    return 0
  fi

  step "Nextcloud Talk — signaling nodes"
  ask_int "Talk signaling — nodes" "2" is_positive_int "Integer ≥ 1 required" SIGNALING_NODES

  step "Nextcloud Talk — TURN server (coturn)"
  echo ""
  echo -e "  ${C_WHITE}A TURN server relays WebRTC media through NAT for remote users.${C_RESET}"
  echo -e "  ${C_GRAY}Without it, Talk falls back to the public STUN server (stun.nextcloud.com:443).${C_RESET}"
  echo -e "  ${C_GRAY}Requires exposing UDP/TCP port 3478 to the Internet.${C_RESET}"
  echo ""
  if prompt_yn "Deploy coturn TURN server?" "N"; then
    COTURN_ENABLED="yes"
    warn "coturn uses network_mode: host (Linux VPS only)"
    warn "Open UDP+TCP port 3478 in your cloud firewall / security group"
    info "coturn enabled"
  else
    COTURN_ENABLED="no"
    info "coturn disabled — Talk will use public STUN (stun.nextcloud.com:443)"
  fi
}

# --- show_recap ---
show_load_estimate() {
  # Model calibrated on real tests (README):
  #   6 FPM → 44 req/s PHP · 34 VUs → 500 DAU · P99 1,154 ms · 0 errors / 1,900 req
  # Diminishing returns at 88% per node (shared resources: DB, Redis, HAProxy).
  local req_s_php req_s_light concurrent total p99_php ram_total

  # PHP req/s: geometric series with ratio 0.88 starting from 10 req/s for 1 node
  req_s_php=$(awk -v n="$NC_NODES" \
    'BEGIN{s=0; for(i=0;i<n;i++) s+=10*0.88^i; printf "%.0f", s}')

  # Light req/s (/status.php, statics) ≈ 4.15× PHP throughput
  req_s_light=$(( req_s_php * 415 / 100 ))

  # Peak VUs (concurrent sessions): req_s_php × 0.77
  # Calibrated on SMB test: 6 FPM → 44 req/s → 34 VUs  (34/44 = 0.773)
  concurrent=$(awk -v r="$req_s_php" 'BEGIN{printf "%.0f", r * 0.77}')
  [[ $concurrent -lt 1 ]] && concurrent=1

  # Estimated DAU: 1 VU ≈ 15 DAU (measured ratio: 34 VUs for 500 DAU in SMB test)
  total=$(( concurrent * 15 ))

  # Estimated PHP P99: 3,381 ms × n^-0.6 (calibrated on real measurements)
  p99_php=$(awk -v n="$NC_NODES" 'BEGIN{printf "%.0f", 3381 * n^(-0.6)}')

  # RAM: 3 GB/FPM node + dynamic overhead (1.5 GB/Galera, 0.125/Redis,
  #       0.375/RustFS, 0.75/Collabora, 0.1/Whiteboard)
  #       + 0.7 GB fixed (HAProxy 0.05 + nginx-acme 0.03 + certbot 0.03
  #                       + nextcloud-cron 0.5 + galera-autoheal 0.02 + OS 0.07)
  # Verified: 6 FPM + 5 Galera + 6 Redis + 4 RustFS + 3 Collab + 3 WB = 31 GB (README)
  ram_total=$(awk \
    -v nc="$NC_NODES" -v db="$MARIADB_NODES" -v redis="$REDIS_NODES" \
    -v rustfs="$RUSTFS_NODES" -v collab="$COLLAB_NODES" -v wb="$WB_NODES" \
    'BEGIN{printf "%.0f",
       nc*3 + db*1.5 + redis*0.125 + rustfs*0.375 + collab*0.75 + wb*0.1 + 0.7}')

  local write_tps=1500
  (( MARIADB_NODES >= 5 )) && write_tps=2500   # measured: 5 nodes → ~2,500 TPS
  (( MARIADB_NODES >= 7 )) && write_tps=3500

  local redis_masters=$(( REDIS_NODES / 2 ))

  local rustfs_total=$(( RUSTFS_NODES * RUSTFS_DISKS ))
  # Write tolerance (quorum N/2+1 drives) = rustfs_total/2 - 1
  # Ex. 4 nodes × 2 drives = 8 → write tolerates 3 lost drives (README: "Loss of 3 drives")
  local rustfs_tol_drives=$(( rustfs_total / 2 - 1 ))
  local rustfs_tol_nodes=$(( RUSTFS_NODES / 2 ))

  local rustfs_storage_line=""
  if (( ${RUSTFS_DISK_SIZE_GB:-0} > 0 )); then
    local _raw_gb=$(( RUSTFS_NODES * RUSTFS_DISKS * RUSTFS_DISK_SIZE_GB ))
    local _usable_tb _raw_tb
    _raw_tb=$(awk    -v r="$_raw_gb"              'BEGIN{printf "%.1f", r/1000}')
    _usable_tb=$(awk -v u="$(( _raw_gb / 2 ))"   'BEGIN{printf "%.1f", u/1000}')
    rustfs_storage_line="RustFS storage            : ${_usable_tb} TB usable  (${_raw_tb} TB raw · EC:N/2)"
  fi

  local _estimate_args=(
    "Concurrent sessions      : ~${concurrent} VUs  (ref: 34 VUs measured at 6 nodes)"
    "Daily active users       : ~${total} DAU  (ratio 1 VU : 15 DAU measured)"
    "PHP throughput (login/API): ~${req_s_php} req/s  (ref: 44 req/s at 6 nodes)"
    "Light throughput (/status…): ~${req_s_light} req/s"
    "Estimated PHP P99        : ~${p99_php} ms"
    "Recommended RAM          : ~${ram_total} GB"
    "MariaDB writes           : ~${write_tps} TPS  (Galera ${MARIADB_NODES} nodes)"
    "Redis cache              : ${redis_masters} masters  > 500,000 ops/s"
    "RustFS tolerance          : ${rustfs_tol_nodes} node(s) or ${rustfs_tol_drives} drives losable (writes)"
  )
  [[ -n "$rustfs_storage_line" ]] && _estimate_args+=("$rustfs_storage_line")
  _estimate_args+=(
    "Collabora                : ${COLLAB_NODES} node(s) — unlimited connections/documents (home_mode binary patch)"
    ""
    "Real data: 0 errors / 1,900 req · 150 concurrent · max 247 req/s"
  )
  box "Load Estimate" "${_estimate_args[@]}"
}

show_recap() {
  echo ""
  box "Configuration Summary" \
    "Nextcloud      : $NC_DOMAIN  (${NC_NODES} FPM nodes + ${NC_NODES} nginx, v${NC_VERSION})" \
    "Collabora      : $COLLAB_DOMAIN  (${COLLAB_NODES} nodes)" \
    "Whiteboard     : $WB_DOMAIN  (${WB_NODES} nodes)" \
    "$( [[ "${TALK_ENABLED:-no}" == "yes" ]] \
        && echo "Talk signaling : $TALK_DOMAIN  (${SIGNALING_NODES:-2} nodes + NATS)  coturn: ${COTURN_ENABLED}" \
        || echo "Talk signaling : disabled (built-in signaling only)" )" \
    "SSL Email      : $CERTBOT_EMAIL" \
    "MariaDB Galera : ${MARIADB_NODES} nodes" \
    "Redis Cluster  : ${REDIS_NODES} nodes" \
    "RustFS          : ${RUSTFS_NODES} nodes × ${RUSTFS_DISKS} disks (mode: ${RUSTFS_MODE})" \
    "HAProxy Stats  : ${HAPROXY_STATS}" \
    "RustFS Console  : ${RUSTFS_CONSOLE}"

  show_load_estimate

  echo ""
  prompt_yn "Confirm and start generation?" "Y" || die "Cancelled by user"
}

# --- ask_cert_mode ---
ask_cert_mode() {
  step "SSL Certificate Environment"
  echo ""
  echo -e "  ${C_WHITE}[1]${C_RESET} ${C_BGREEN}Production${C_RESET}  — Real Let's Encrypt (valid DNS domains required)"
  echo -e "  ${C_WHITE}[2]${C_RESET} ${C_YELLOW}Staging/Test${C_RESET} — Let's Encrypt staging (no rate limit, untrusted certificates)"
  echo ""
  local choice
  prompt_input "Your choice" "1"
  choice="$REPLY"
  if [[ "$choice" == "2" ]]; then
    CERTBOT_STAGING="yes"
    warn "STAGING mode enabled — certificates will not be trusted by browsers"
    warn "Use this mode only to test infrastructure, never in production"
  else
    CERTBOT_STAGING="no"
    info "Production mode — real Let's Encrypt certificates"
  fi
}

# --- save_answers / load_answers ---
save_answers() {
  {
    echo "# NXT Maxscale — Config saved on $(date '+%Y-%m-%d %H:%M:%S')"
    printf 'NC_DOMAIN="%s"\n'     "$NC_DOMAIN"
    printf 'COLLAB_DOMAIN="%s"\n' "$COLLAB_DOMAIN"
    printf 'WB_DOMAIN="%s"\n'     "$WB_DOMAIN"
    printf 'TALK_ENABLED="%s"\n'  "${TALK_ENABLED:-no}"
    printf 'TALK_DOMAIN="%s"\n'   "${TALK_DOMAIN:-}"
    printf 'CERTBOT_EMAIL="%s"\n' "$CERTBOT_EMAIL"
    printf 'NC_VERSION="%s"\n'    "$NC_VERSION"
    printf 'NC_NODES="%s"\n'      "$NC_NODES"
    printf 'MARIADB_NODES="%s"\n' "$MARIADB_NODES"
    printf 'REDIS_NODES="%s"\n'   "$REDIS_NODES"
    printf 'COLLAB_NODES="%s"\n'  "$COLLAB_NODES"
    printf 'WB_NODES="%s"\n'      "$WB_NODES"
    printf 'RUSTFS_NODES="%s"\n'        "$RUSTFS_NODES"
    printf 'RUSTFS_DISKS="%s"\n'        "$RUSTFS_DISKS"
    printf 'RUSTFS_DISK_SIZE_GB="%s"\n' "${RUSTFS_DISK_SIZE_GB:-0}"
    printf 'RUSTFS_MODE="%s"\n'         "$RUSTFS_MODE"
    printf 'RUSTFS_BYPASS="%s"\n' "$RUSTFS_BYPASS"
    printf 'HAPROXY_STATS="%s"\n' "$HAPROXY_STATS"
    printf 'RUSTFS_CONSOLE="%s"\n' "$RUSTFS_CONSOLE"
    printf 'COTURN_ENABLED="%s"\n' "$COTURN_ENABLED"
    printf 'SIGNALING_NODES="%s"\n' "${SIGNALING_NODES:-2}"
    printf 'CERTBOT_STAGING="%s"\n' "$CERTBOT_STAGING"
    declare -p RUSTFS_PATHS | sed 's/^declare -A/declare -gA/'
  } > "$ANSWERS_CACHE"
  chmod 600 "$ANSWERS_CACHE"
}

load_answers() {
  [[ -f "$ANSWERS_CACHE" ]] || return 1
  local saved_date
  saved_date=$(grep '^#' "$ANSWERS_CACHE" | head -1 | sed 's/# NXT Maxscale — Config saved on //')
  echo ""
  warn "Previous configuration found (${saved_date}):"
  grep -v '^#\|^declare' "$ANSWERS_CACHE" | while IFS= read -r line; do
    printf "  ${C_GRAY}%s${C_RESET}\n" "$line"
  done
  echo ""
  prompt_yn "Reuse this configuration?" "Y" || return 1
  declare -gA RUSTFS_PATHS 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$ANSWERS_CACHE"
  info "Configuration reloaded."
  return 0
}

# ─── [GENERATE] File generation ──────────────────────────────────────────────

# gen_pass <length> <"hex"|"base64"> → stdout, guaranteed no # char
gen_pass() {
  local len="$1" mode="$2"
  local pass
  while true; do
    if [[ "$mode" == "hex" ]]; then
      pass=$(openssl rand -hex "$len")
    else
      pass=$(openssl rand -base64 "$len")
    fi
    # Remove # (breaks Redis/Node.js URL parsing) and line breaks
    pass="${pass//#/}"
    pass="${pass//$'\n'/}"
    pass="${pass//$'\r'/}"
    [[ ${#pass} -ge 16 ]] && echo "$pass" && return
  done
}

gen_passwords() {
  phase 5 7 "Password Generation"
  start_spinner "Generating cryptographic secrets..."

  GEN_NC_ADMIN_PASS=$(gen_pass 18 "base64")
  GEN_DB_ROOT_PASS=$(gen_pass 18 "base64")
  GEN_DB_PASS=$(gen_pass 18 "base64")
  GEN_REDIS_PASS=$(gen_pass 32 "hex")
  GEN_REDIS_WB_PASS=$(gen_pass 32 "hex")
  GEN_RUSTFS_KEY=$(gen_pass 16 "hex")
  GEN_RUSTFS_SECRET=$(gen_pass 24 "base64")
  GEN_JWT_SECRET=$(gen_pass 36 "base64")
  GEN_TALK_SECRET=$(gen_pass 32 "hex")
  GEN_SIGNALING_INTERNAL_SECRET=$(gen_pass 32 "hex")
  GEN_COTURN_SECRET=$(gen_pass 24 "base64")
  GEN_TURN_APIKEY=$(gen_pass 16 "hex")
  GEN_SIGNALING_HASHKEY=$(gen_pass 32 "hex")
  GEN_SIGNALING_BLOCKKEY=$(gen_pass 16 "hex")
  if [[ "$HAPROXY_STATS" == "yes" ]]; then
    GEN_HAPROXY_STATS_PASS=$(gen_pass 12 "base64")
  else
    GEN_HAPROXY_STATS_PASS="disabled"
  fi

  stop_spinner "Passwords generated"
}

gen_env() {
  local dest="${1:-$INSTALL_DIR/.env}"
  step "Generating .env file"

  # Build RustFS path lines dynamically
  local rustfs_lines="" n d
  for n in $(seq 1 "$RUSTFS_NODES"); do
    rustfs_lines+="RUSTFS_NODE${n}_PATH=${RUSTFS_PATHS[${n}_path]}"$'\n'
    for d in $(seq 1 "$RUSTFS_DISKS"); do
      rustfs_lines+="RUSTFS_NODE${n}_DATA${d}=${RUSTFS_PATHS[${n}_${d}]}"$'\n'
    done
    rustfs_lines+=$'\n'
  done

  cat > "$dest" <<EOF
# Auto-generated by deploy.sh — $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT EDIT MANUALLY — regenerate with deploy.sh

COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}

NEXTCLOUD_DOMAIN=${NC_DOMAIN}
COLLABORA_DOMAIN=${COLLAB_DOMAIN}
WHITEBOARD_DOMAIN=${WB_DOMAIN}
TALK_ENABLED=${TALK_ENABLED:-no}
TALK_DOMAIN=${TALK_DOMAIN:-}
CERTBOT_EMAIL=${CERTBOT_EMAIL}

HAPROXY_STATS_PASSWORD=${GEN_HAPROXY_STATS_PASS}

NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=${GEN_NC_ADMIN_PASS}

MARIADB_ROOT_PASSWORD=${GEN_DB_ROOT_PASS}
MARIADB_USER=nextcloud
MARIADB_PASSWORD=${GEN_DB_PASS}
MARIADB_DATABASE=nextcloud

REDIS_PASSWORD=${GEN_REDIS_PASS}
REDIS_WHITEBOARD_PASSWORD=${GEN_REDIS_WB_PASS}

RUSTFS_ACCESS_KEY=${GEN_RUSTFS_KEY}
RUSTFS_SECRET_KEY=${GEN_RUSTFS_SECRET}
NEXTCLOUD_S3_BUCKET=nextcloud

${rustfs_lines}
RUSTFS_MODE=${RUSTFS_MODE}
RUSTFS_BYPASS=${RUSTFS_BYPASS}
HAPROXY_STATS=${HAPROXY_STATS}

WHITEBOARD_JWT_SECRET=${GEN_JWT_SECRET}

TALK_SIGNALING_SECRET=${GEN_TALK_SECRET}
COTURN_SECRET=${GEN_COTURN_SECRET}
COTURN_ENABLED=${COTURN_ENABLED}
SIGNALING_NODES=${SIGNALING_NODES:-2}
EOF

  chmod 600 "$dest"
  info ".env generated: $dest"
}

# gen_rustfs_volumes_env — builds the volume specification from the pools file.
#
# Single-node (SNSD/SNMD): returns space-separated absolute paths (/data1 /data2 …)
#   → used in RUSTFS_VOLUMES env var; the entrypoint creates dirs + chowns them.
#
# Multi-node (MNMD, single or multiple pools): returns explicit HTTP URLs
#   (http://rustfs-nodeN:9000/dataN …) with every node × disk fully expanded.
#   → used as command: args in docker-compose; the entrypoint receives them via $@,
#     prefixes /usr/bin/rustfs, and skips RUSTFS_VOLUMES (set to "none" to suppress
#     the default /data fallback in the entrypoint).
#
# Why explicit expansion instead of brace notation for HTTP URLs:
#   The entrypoint.sh skips any RUSTFS_VOLUMES token that is not an absolute path.
#   Passing URLs directly as command args is the only reliable way to run distributed
#   mode with the Docker Hub image entrypoint.
gen_rustfs_volumes_env() {
  local pools_file="$INSTALL_DIR/.rustfs-pools"

  if (( RUSTFS_NODES == 1 )); then
    # ── Single node: local paths via RUSTFS_VOLUMES ──────────────────────────
    local vols="" _d
    for _d in $(seq 1 "$RUSTFS_DISKS"); do vols+=" /data${_d}"; done
    echo "${vols# }"
    return
  fi

  # ── Multi-node: fully-expanded HTTP URLs ─────────────────────────────────
  local urls=""

  if [[ -f "$pools_file" ]]; then
    # Multi-pool: each pool has its own node range (scale-up history)
    while IFS=: read -r start end; do
      [[ -n "$start" && -n "$end" ]] || continue
      local n
      for n in $(seq "$start" "$end"); do
        local d
        for d in $(seq 1 "$RUSTFS_DISKS"); do
          urls+=" http://rustfs-node${n}:9000/data${d}"
        done
      done
    done < "$pools_file"
  else
    # Single pool
    local n
    for n in $(seq 1 "$RUSTFS_NODES"); do
      local d
      for d in $(seq 1 "$RUSTFS_DISKS"); do
        urls+=" http://rustfs-node${n}:9000/data${d}"
      done
    done
  fi

  echo "${urls# }"
}

gen_compose() {
  local dest="${1:-$INSTALL_DIR/docker-compose.yml}"
  step "Generating docker-compose.yml"


  # ── Header ──────────────────────────────────────────────────────────────
  cat > "$dest" <<'HEADER'
# Auto-generated by deploy.sh
services:
HEADER

  # ── HAProxy (fixed) ─────────────────────────────────────────────────────
  cat >> "$dest" <<'HAPROXY'

  haproxy:
    image: haproxy:2.8-alpine
    container_name: haproxy
    restart: always
    ports:
      - "80:80"
      - "443:443"
    entrypoint: ["/bin/sh", "/haproxy-entrypoint.sh"]
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
      - ./haproxy-entrypoint.sh:/haproxy-entrypoint.sh:ro
      - ./certs:/certs:ro
    environment:
      - NEXTCLOUD_DOMAIN=${NEXTCLOUD_DOMAIN}
      - COLLABORA_DOMAIN=${COLLABORA_DOMAIN}
      - WHITEBOARD_DOMAIN=${WHITEBOARD_DOMAIN}
      - TALK_DOMAIN=${TALK_DOMAIN}
      - HAPROXY_STATS_PASSWORD=${HAPROXY_STATS_PASSWORD}
    networks:
      next-net:
        aliases:
          - "${NEXTCLOUD_DOMAIN}"
          - "${COLLABORA_DOMAIN}"
          - "${WHITEBOARD_DOMAIN}"
      galera-net: {}
      storage-net: {}
      collabora-net:
        ipv4_address: 172.40.0.10
        aliases:
          - "${NEXTCLOUD_DOMAIN}"
      whiteboard-net:
        ipv4_address: 172.100.0.10
        aliases:
          - "${NEXTCLOUD_DOMAIN}"
      talk-net: {}
    healthcheck:
      test: ["CMD-SHELL", "grep -q ':0050 ' /proc/net/tcp || grep -q ':0050 ' /proc/net/tcp6 || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 6
      start_period: 10s
HAPROXY

  # ── nextcloud-setup (fixed, uses NC_VERSION bash var) ───────────────────
  cat >> "$dest" <<NCSETUP

  nextcloud-setup:
    image: nextcloud:${NC_VERSION}
    container_name: nextcloud-setup
    restart: on-failure:3
    user: "33"
    entrypoint: ["/bin/bash", "/nextcloud-init.sh"]
    volumes:
      - ./nextcloud-init.sh:/nextcloud-init.sh:ro
      - nextcloud_html:/var/www/html
      - nextcloud_apps:/var/www/html/custom_apps
      - nextcloud_config:/var/www/html/config
      - nextcloud_data:/var/www/html/data
      - ./opcache-recommended.ini:/usr/local/etc/php/conf.d/opcache-recommended.ini:ro
      - ./opcache-preload.php:/opcache-preload.php:ro
      - ./nextcloud-custom.config.php:/var/www/html/config/custom.config.php:ro
      - ./img:/img:ro
      - ./nxt-custom.css:/nxt-custom.css:ro
    environment:
      - REDIS_PASSWORD=\${REDIS_PASSWORD}
      - NEXTCLOUD_DOMAIN=\${NEXTCLOUD_DOMAIN}
      - COLLABORA_DOMAIN=\${COLLABORA_DOMAIN}
      - WHITEBOARD_DOMAIN=\${WHITEBOARD_DOMAIN}
      - TALK_DOMAIN=\${TALK_DOMAIN}
      - TALK_SIGNALING_SECRET=\${TALK_SIGNALING_SECRET}
      - COTURN_SECRET=\${COTURN_SECRET}
      - WHITEBOARD_JWT_SECRET=\${WHITEBOARD_JWT_SECRET}
      - RUSTFS_ACCESS_KEY=\${RUSTFS_ACCESS_KEY}
      - RUSTFS_SECRET_KEY=\${RUSTFS_SECRET_KEY}
      - NEXTCLOUD_S3_BUCKET=\${NEXTCLOUD_S3_BUCKET:-nextcloud}
    networks:
      - next-net
    depends_on:
      app-next-01:
        condition: service_healthy
NCSETUP

  # ── nextcloud-cron (fixed) ──────────────────────────────────────────────
  # Runs cron.php every 5 min — replaces ajax mode (background:cron)
  cat >> "$dest" <<NCCRON

  nextcloud-cron:
    image: nextcloud:${NC_VERSION}
    container_name: nextcloud-cron
    restart: unless-stopped
    entrypoint: /cron.sh
    volumes:
      - ./opcache-recommended.ini:/usr/local/etc/php/conf.d/opcache-recommended.ini:ro
      - ./opcache-preload.php:/opcache-preload.php:ro
      - nextcloud_html:/var/www/html
      - nextcloud_apps:/var/www/html/custom_apps
      - nextcloud_config:/var/www/html/config
      - nextcloud_data:/var/www/html/data
      - ./nextcloud-custom.config.php:/var/www/html/config/custom.config.php:ro
    environment:
      - MYSQL_HOST=haproxy
      - MYSQL_DATABASE=\${MARIADB_DATABASE}
      - MYSQL_USER=\${MARIADB_USER}
      - MYSQL_PASSWORD=\${MARIADB_PASSWORD}
      - REDIS_PASSWORD=\${REDIS_PASSWORD}
    networks:
      - next-net
    depends_on:
      app-next-01:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "grep -qa cron /proc/1/cmdline || exit 1"]
      interval: 60s
      timeout: 5s
      retries: 3
      start_period: 30s
NCCRON

  # ── nginx-acme + certbot (fixed) ────────────────────────────────────────
  cat >> "$dest" <<'ACME'

  nginx-acme:
    image: nginx:1.27-alpine
    container_name: nginx-acme
    restart: always
    expose:
      - "80"
    volumes:
      - certbot_webroot:/usr/share/nginx/html:ro
    networks:
      - next-net
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost/ >/dev/null 2>&1 || exit 0"]
      interval: 30s
      timeout: 5s
      retries: 3

  certbot:
    image: certbot/certbot:v5.6.0
    container_name: certbot
    restart: unless-stopped
    volumes:
      - letsencrypt:/etc/letsencrypt
      - certbot_webroot:/var/www/certbot
      - ./certs:/certs
    entrypoint: >
      /bin/sh -c "
        trap exit TERM;
        while :; do
          certbot renew --webroot -w /var/www/certbot --quiet --post-hook 'cat /etc/letsencrypt/live/stack/fullchain.pem /etc/letsencrypt/live/stack/privkey.pem > /certs/stack.pem && chmod 600 /certs/stack.pem';
          sleep 12h & wait $$!;
        done"
    healthcheck:
      test: ["CMD-SHELL", "openssl x509 -checkend 2592000 -noout -in /etc/letsencrypt/live/stack/fullchain.pem 2>/dev/null"]
      interval: 12h
      timeout: 10s
      retries: 1
      start_period: 5m
    depends_on:
      - nginx-acme
ACME

  # ── nextcloud-perms (one-shot, fixes config/data volume ownership) ────────
  cat >> "$dest" <<NCPERMS

  nextcloud-perms:
    image: nextcloud:${NC_VERSION}
    container_name: nextcloud-perms
    restart: "no"
    user: root
    entrypoint: ["/bin/sh", "-c", "chown -R www-data:www-data /var/www/html/config /var/www/html/data /var/www/html/custom_apps"]
    volumes:
      - nextcloud_config:/var/www/html/config
      - nextcloud_data:/var/www/html/data
      - nextcloud_apps:/var/www/html/custom_apps
NCPERMS

  # ── Nextcloud app nodes (dynamic) ───────────────────────────────────────
  local i
  for i in $(seq 1 "$NC_NODES"); do
    local name; name="app-next-$(printf '%02d' "$i")"
    local start_period="120s"
    local depends_block
    if (( i == 1 )); then
      start_period="300s"
      depends_block="    depends_on:
      nextcloud-perms:
        condition: service_completed_successfully
      mariadb-node1:
        condition: service_healthy
      redis-node1:
        condition: service_healthy
      haproxy:
        condition: service_started
      rustfs-node1:
        condition: service_healthy"
    else
      depends_block="    depends_on:
      app-next-01:
        condition: service_healthy"
    fi

    # First node gets admin env vars + entrypoint wrapper, others don't
    local admin_env=""
    local entrypoint_override=""
    if (( i == 1 )); then
      admin_env="      - NEXTCLOUD_ADMIN_USER=\${NEXTCLOUD_ADMIN_USER}
      - NEXTCLOUD_ADMIN_PASSWORD=\${NEXTCLOUD_ADMIN_PASSWORD}"
      # WSREP verification via PHP PDO (mariadb-client absent from nextcloud image).
      # php -r "new PDO(...)" throws an exception on WSREP 1047 -> non-zero exit.
      # No $ variable in YAML -> no Docker Compose interpolation.
      entrypoint_override='    entrypoint: ["/bin/bash", "-c", "until php -r \"new PDO('"'"'mysql:host=haproxy;port=3306'"'"', getenv('"'"'MYSQL_USER'"'"'), getenv('"'"'MYSQL_PASSWORD'"'"')); echo '"'"'ok'"'"';\" 2>/dev/null | grep -q ok; do echo waiting for Galera WSREP...; sleep 3; done; exec /entrypoint.sh php-fpm"]'
    fi

    cat >> "$dest" <<NCNODE

  ${name}:
    image: nextcloud:${NC_VERSION}
    container_name: ${name}
    restart: always
${entrypoint_override}
    expose:
      - "9000"
    volumes:
      - ./opcache-recommended.ini:/usr/local/etc/php/conf.d/opcache-recommended.ini:ro
      - ./opcache-preload.php:/opcache-preload.php:ro
      - nextcloud_html:/var/www/html
      - nextcloud_apps:/var/www/html/custom_apps
      - nextcloud_config:/var/www/html/config
      - nextcloud_data:/var/www/html/data
      - ./nextcloud-custom.config.php:/var/www/html/config/custom.config.php:ro
    environment:
      - PHP_UPLOAD_LIMIT=16G
      - PHP_MEMORY_LIMIT=1G
${admin_env}
      - MYSQL_HOST=haproxy
      - MYSQL_DATABASE=\${MARIADB_DATABASE}
      - MYSQL_USER=\${MARIADB_USER}
      - MYSQL_PASSWORD=\${MARIADB_PASSWORD}
      - NEXTCLOUD_TRUSTED_DOMAINS=\${NEXTCLOUD_DOMAIN} localhost 127.0.0.1
      - OBJECTSTORE_S3_HOST=haproxy
      - OBJECTSTORE_S3_PORT=9000
      - OBJECTSTORE_S3_BUCKET=\${NEXTCLOUD_S3_BUCKET:-nextcloud}
      - OBJECTSTORE_S3_KEY=\${RUSTFS_ACCESS_KEY}
      - OBJECTSTORE_S3_SECRET=\${RUSTFS_SECRET_KEY}
      - OBJECTSTORE_S3_USEPATH_STYLE=true
      - OBJECTSTORE_S3_SSL=false
      - OBJECTSTORE_S3_AUTOCREATE=true
      - OBJECTSTORE_S3_REGION=us-east-1
    networks:
      - next-net
${depends_block}
    healthcheck:
      test: ["CMD-SHELL", "php /var/www/html/occ status 2>/dev/null | grep -q 'installed: true' || exit 1"]
      interval: 30s
      timeout: 15s
      retries: 10
      start_period: ${start_period}
NCNODE
  done

  # ── nginx containers (1 per Nextcloud FPM node) ───────────────────────
  for i in $(seq 1 "$NC_NODES"); do
    local fpm_name; fpm_name="app-next-$(printf '%02d' "$i")"
    local nginx_name; nginx_name="nginx-next-$(printf '%02d' "$i")"

    cat >> "$dest" <<NGNX

  ${nginx_name}:
    image: ${IMG_NGINX}
    container_name: ${nginx_name}
    restart: always
    expose:
      - "80"
    volumes_from:
      - ${fpm_name}
    volumes:
      - ./nginx-nextcloud.conf.template:/etc/nginx/templates/default.conf.template:ro
    environment:
      - FPM_HOST=${fpm_name}
    networks:
      - next-net
    depends_on:
      ${fpm_name}:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "echo '' | nc -w1 127.0.0.1 80 > /dev/null 2>&1 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 10s
NGNX
  done

  # ── MariaDB Galera nodes (dynamic) ──────────────────────────────────────
  for i in $(seq 1 "$MARIADB_NODES"); do
    local db_cmd="" db_init_vol="" db_extra_env="" db_depends=""

    if (( i == 1 )); then
      db_cmd="    entrypoint: [\"/bin/bash\", \"/galera-bootstrap.sh\"]"
      db_init_vol="      - ./mariadb/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
      - ./galera-bootstrap.sh:/galera-bootstrap.sh:ro"
      db_extra_env="      - MARIADB_USER=\${MARIADB_USER}
      - MARIADB_PASSWORD=\${MARIADB_PASSWORD}
      - MARIADB_DATABASE=\${MARIADB_DATABASE}"
    fi

    if (( i > 1 )); then
      # All non-bootstrap nodes depend directly on node1 (not the previous one).
      # This allows parallel startup — Galera serializes SST itself.
      db_depends="    depends_on:
      mariadb-node1:
        condition: service_healthy"
    fi

    # node1: allows time for bootstrap + schema init
    # nodes 2+: 180s to absorb a full SST before autoheal intervenes
    local start_period_db="180s"
    (( i == 1 )) && start_period_db="120s"

    cat >> "$dest" <<DBNODE

  mariadb-node${i}:
    build:
      context: .
      dockerfile: Dockerfile.mariadb-galera
    image: ${IMG_MARIADB}
    container_name: mariadb-node${i}
    restart: always
    labels:
      autoheal: "true"
${db_cmd}
    expose:
      - "3306"
      - "4444"
      - "4567"
      - "4568"
    volumes:
      - ./mariadb/galera-node${i}.cnf:/etc/mysql/conf.d/galera.cnf:ro
${db_init_vol}
      - mariadb_n${i}_data:/var/lib/mysql
    environment:
      - MARIADB_ROOT_PASSWORD=\${MARIADB_ROOT_PASSWORD}
${db_extra_env}
    networks:
      - galera-net
${db_depends}
    healthcheck:
      test: ["CMD-SHELL", "mariadb -uroot -p\$\$MARIADB_ROOT_PASSWORD -e \"SHOW STATUS LIKE 'wsrep_ready'\" 2>/dev/null | grep -q ON || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: ${start_period_db}
DBNODE
  done

  # ── galera-autoheal ────────────────────────────────────────────────────
  cat >> "$dest" <<AUTOHEAL

  galera-autoheal:
    image: ${IMG_AUTOHEAL}
    container_name: galera-autoheal
    restart: always
    environment:
      - AUTOHEAL_CONTAINER_LABEL=autoheal
      - AUTOHEAL_INTERVAL=60
      - AUTOHEAL_START_PERIOD=300
      - AUTOHEAL_DEFAULT_STOP_TIMEOUT=30
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f autoheal > /dev/null || exit 1"]
      interval: 60s
      timeout: 5s
      retries: 3
      start_period: 30s
AUTOHEAL

  # ── Redis Cluster nodes (dynamic) ───────────────────────────────────────
  for i in $(seq 1 "$REDIS_NODES"); do
    local redis_hc=""
    if (( i == 1 )); then
      redis_hc="    environment:
      - REDIS_PASSWORD=\${REDIS_PASSWORD}
    healthcheck:
      test: [\"CMD-SHELL\", \"redis-cli -a \$\$REDIS_PASSWORD --no-auth-warning ping | grep -q PONG || exit 1\"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s"
    fi

    cat >> "$dest" <<RNODE

  redis-node${i}:
    image: ${IMG_REDIS}
    container_name: redis-node${i}
    restart: always
    expose:
      - "6379"
    command: >
      redis-server
      --cluster-enabled yes
      --cluster-config-file /data/nodes.conf
      --cluster-node-timeout 5000
      --appendonly yes
      --requirepass \${REDIS_PASSWORD}
      --masterauth \${REDIS_PASSWORD}
      --bind 0.0.0.0
      --protected-mode no
    volumes:
      - redis_data_${i}:/data
${redis_hc}
    networks:
      - next-net
RNODE
  done

  # redis-cluster-init (dynamic node list)
  local redis_wait_block="" redis_addr_list="" redis_deps_block=""
  for i in $(seq 1 "$REDIS_NODES"); do
    redis_wait_block+="          until redis-cli -h redis-node${i} -a \$\$REDIS_PASSWORD --no-auth-warning ping 2>/dev/null | grep -q PONG; do sleep 3; done;"$'\n'
    redis_addr_list+=" redis-node${i}:6379"
    local cond="service_started"
    (( i == 1 )) && cond="service_healthy"
    redis_deps_block+="      redis-node${i}:"$'\n'
    redis_deps_block+="        condition: ${cond}"$'\n'
  done

  cat >> "$dest" <<RCINIT

  redis-cluster-init:
    image: ${IMG_REDIS}
    container_name: redis-cluster-init
    environment:
      - REDIS_PASSWORD=\${REDIS_PASSWORD}
    command: >
      sh -c "
        echo 'Waiting for Redis nodes...';
${redis_wait_block}
        CLUSTER_STATE=\$\$(redis-cli -h redis-node1 -a \$\$REDIS_PASSWORD --no-auth-warning cluster info 2>/dev/null | grep cluster_state | cut -d: -f2 | tr -d '[:space:]');
        if [ \"\$\$CLUSTER_STATE\" = \"ok\" ]; then
          echo 'Redis cluster already initialized.';
        else
          redis-cli --cluster create${redis_addr_list} --cluster-replicas 1 -a \$\$REDIS_PASSWORD --no-auth-warning --cluster-yes;
          echo 'Redis cluster created.';
        fi"
    networks:
      - next-net
    depends_on:
${redis_deps_block}
    restart: on-failure:5
RCINIT

  # ── RustFS nodes (dynamic) ──────────────────────────────────────────────
  # RUSTFS_VOLUMES: space-separated paths (SNSD) or URL notation (MNMD / multi-pool)
  local rustfs_volumes_val
  rustfs_volumes_val=$(gen_rustfs_volumes_env)

  for i in $(seq 1 "$RUSTFS_NODES"); do
    local rfs_ip="172.50.0.$((10 + i))"
    local rfs_vol_lines=""
    local d
    for d in $(seq 1 "$RUSTFS_DISKS"); do
      rfs_vol_lines+="      - \${RUSTFS_NODE${i}_DATA${d}:-${RUSTFS_PATHS[${i}_${d}]}}:/data${d}"$'\n'
    done

    # Built-in console on port 9001 (enabled via RUSTFS_CONSOLE_ENABLE)
    local console_enable="false"
    [[ "$RUSTFS_CONSOLE" == "yes" ]] && console_enable="true"
    local console_expose=""
    [[ "$RUSTFS_CONSOLE" == "yes" ]] && console_expose="      - \"9001\""$'\n'

    # Multi-node distributed mode: pass all volume URLs directly as command args.
    # The entrypoint normalises them to: /usr/bin/rustfs http://nodeN:9000/dataN …
    # RUSTFS_VOLUMES is set to "none" to suppress the entrypoint's /data fallback.
    # Single-node: use RUSTFS_VOLUMES with absolute paths (entrypoint creates dirs).
    local rfs_volumes_line rfs_cmd_line=""
    if (( RUSTFS_NODES == 1 )); then
      rfs_volumes_line="      - RUSTFS_VOLUMES=${rustfs_volumes_val}"
    else
      rfs_volumes_line="      - RUSTFS_VOLUMES=none"
      # Build YAML list form so each URL is a separate argv to the entrypoint.
      # Shell-form command: (quoted string) would be wrapped in /bin/sh -c "..."
      # and the entrypoint would receive /bin/sh as $1 — completely wrong.
      # List form passes each URL directly as $1, $2, … to the entrypoint.
      rfs_cmd_line=$'    command:\n'
      # IFS=$'\n\t' is set globally — override to space for this split only.
      local _url _urls=()
      IFS=' ' read -r -a _urls <<< "$rustfs_volumes_val"
      for _url in "${_urls[@]}"; do
        rfs_cmd_line+=$'      - "'${_url}$'"\n'
      done
    fi

    local rfs_hc=""
    if (( i == 1 )); then
      rfs_hc="    healthcheck:
      test: [\"CMD-SHELL\", \"curl -sf http://localhost:9000/health 2>/dev/null || exit 1\"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 90s"
    fi

    cat >> "$dest" <<RUSTFSNODE

  rustfs-node${i}:
    image: ${IMG_RUSTFS}
    container_name: rustfs-node${i}
    hostname: rustfs-node${i}
    restart: always
${rfs_cmd_line}    expose:
      - "9000"
${console_expose}    volumes:
${rfs_vol_lines}
    environment:
      - RUSTFS_ACCESS_KEY=\${RUSTFS_ACCESS_KEY}
      - RUSTFS_SECRET_KEY=\${RUSTFS_SECRET_KEY}
${rfs_volumes_line}
      - RUSTFS_ADDRESS=0.0.0.0:9000
      - RUSTFS_CONSOLE_ENABLE=${console_enable}
    networks:
      storage-net: {}
      rustfsnet:
        ipv4_address: ${rfs_ip}
${rfs_hc}
RUSTFSNODE
  done


  # ── RustFS console — built-in on port 9001, no separate container needed ──

  # ── Collabora nodes (dynamic) ───────────────────────────────────────────
  for i in $(seq 1 "$COLLAB_NODES"); do
    local collab_hc="    healthcheck:
      test: [\"CMD-SHELL\", \"curl -sf http://localhost:9980/hosting/discovery >/dev/null 2>&1 || exit 1\"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s"

    cat >> "$dest" <<COLLNODE

  collabora-node${i}:
    image: ${IMG_COLLABORA}
    container_name: collabora-node${i}
    restart: always
    expose:
      - "9980"
    environment:
      - dictionaries=fr_FR en_US
      - extra_params=--o:ssl.enable=false --o:ssl.termination=true --o:net.listen=any --o:server_name=\${COLLABORA_DOMAIN} --o:mount_jail_tree=false --o:home_mode.enable=true --o:net.max_file_size=104857600
      - DONT_GEN_SSL_CERT=true
      - aliasgroup1=https://\${NEXTCLOUD_DOMAIN}:443
    cap_add:
      - MKNOD
      - SYS_ADMIN
    networks:
      - collabora-net
${collab_hc}
COLLNODE
  done

  # ── Whiteboard nodes + Redis whiteboard (dynamic) ───────────────────────
  for i in $(seq 1 "$WB_NODES"); do
    cat >> "$dest" <<WBNODE

  whiteboard-node${i}:
    image: ${IMG_WHITEBOARD}
    container_name: whiteboard-node${i}
    restart: always
    expose:
      - "3002"
    environment:
      - NEXTCLOUD_URL=https://\${NEXTCLOUD_DOMAIN}
      - JWT_SECRET_KEY=\${WHITEBOARD_JWT_SECRET}
      - STORAGE_STRATEGY=redis
      - REDIS_URL=redis://:\${REDIS_WHITEBOARD_PASSWORD}@redis-whiteboard:6379/0
      - MAX_UPLOAD_FILE_SIZE=26214400
    networks:
      - whiteboard-net
    depends_on:
      redis-whiteboard:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "echo '' | nc -w1 127.0.0.1 3002 > /dev/null 2>&1 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s
WBNODE
  done

  cat >> "$dest" <<'WBREDIS'

  redis-whiteboard:
    image: redis:7.4-alpine
    container_name: redis-whiteboard
    restart: always
    expose:
      - "6379"
    command: >
      redis-server
      --requirepass ${REDIS_WHITEBOARD_PASSWORD}
      --appendonly yes
      --bind 0.0.0.0
    volumes:
      - redis_whiteboard_data:/data
    environment:
      - REDIS_WHITEBOARD_PASSWORD=${REDIS_WHITEBOARD_PASSWORD}
    networks:
      - whiteboard-net
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a $$REDIS_WHITEBOARD_PASSWORD --no-auth-warning ping | grep -q PONG || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
WBREDIS

  # ── notify-push (Client Push — real-time sync notifications) ───────────
  cat >> "$dest" <<NOTIFYPUSH

  notify-push:
    image: nextcloud:${NC_VERSION}
    container_name: notify-push
    restart: always
    entrypoint: ["/bin/sh", "-c"]
    command: >
      "until [ -f /var/www/html/apps/notify_push/bin/\$\$(uname -m)/notify_push ]; do sleep 5; done;
       exec /var/www/html/apps/notify_push/bin/\$\$(uname -m)/notify_push /var/www/html/config/config.php"
    environment:
      - PORT=7867
      - LOG=warn
    volumes:
      - nextcloud_html:/var/www/html:ro
      - nextcloud_apps:/var/www/html/custom_apps:ro
      - nextcloud_config:/var/www/html/config:ro
    networks:
      - next-net
    depends_on:
      app-next-01:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:7867/test/cookie > /dev/null; exit 0"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
NOTIFYPUSH

  # ── Talk: spreed-signaling nodes (opt-in) ──────────────────────────────
  # NATS removed in v2.x — cross-node relay handled by gRPC (nats://loopback used internally)
  if [[ "${TALK_ENABLED:-no}" == "yes" ]]; then
  local _sig_n="${SIGNALING_NODES:-2}"
  for i in $(seq 1 "$_sig_n"); do
    local _name; _name="spreed-signaling-$(printf '%02d' "$i")"
    cat >> "$dest" <<SIGSVC

  ${_name}:
    image: ${IMG_SPREED_SIGNALING}
    container_name: ${_name}
    restart: always
    expose:
      - "8080"
      - "9090"
    volumes:
      - ./signaling.conf:/config/server.conf:ro
    networks:
      - talk-net
      - next-net
    healthcheck:
      test: ["CMD-SHELL", "echo '' | nc -w1 127.0.0.1 8080 > /dev/null 2>&1 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 15s
SIGSVC
  done

  # ── Talk: coturn (opt-in) ───────────────────────────────────────────────
  if [[ "$COTURN_ENABLED" == "yes" ]]; then
    cat >> "$dest" <<COTURNBLOCK

  coturn:
    image: ${IMG_COTURN}
    container_name: coturn
    restart: always
    # network_mode: host — required for TURN relay UDP (port range 49152-65535).
    # Bridge networking cannot map thousands of relay ports. Linux VPS only.
    network_mode: host
    entrypoint: ["/bin/sh", "-c"]
    command: >
      "EXT_IP=\$\$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if(\$\$i==\"src\") {print \$\$(i+1); exit}}');
       EXT_IP=\$\${EXT_IP:-\$\$(hostname -I | awk '{print \$\$1}')};
       exec turnserver
         --external-ip=\$\$EXT_IP
         --listening-ip=0.0.0.0
         --listening-port=3478
         --use-auth-secret
         --static-auth-secret=\$\$COTURN_SECRET
         --realm=\$\$TALK_DOMAIN
         --stale-nonce=600
         --fingerprint
         --no-software-attribute
         --no-multicast-peers
         --no-tls
         --no-dtls
         --log-file=stdout"
    environment:
      - COTURN_SECRET=\${COTURN_SECRET}
      - TALK_DOMAIN=\${TALK_DOMAIN}
COTURNBLOCK
  fi
  fi  # end TALK_ENABLED

  # ── Networks ────────────────────────────────────────────────────────────
  cat >> "$dest" <<'NETWORKS'

networks:
  next-net:
    name: next-net
    driver: bridge
    ipam:
      config:
        - subnet: 172.10.0.0/24
  galera-net:
    name: galera-net
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.0.0/24
  storage-net:
    name: storage-net
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24
  collabora-net:
    name: collabora-net
    driver: bridge
    ipam:
      config:
        - subnet: 172.40.0.0/24
  whiteboard-net:
    name: whiteboard-net
    driver: bridge
    ipam:
      config:
        - subnet: 172.100.0.0/24
  rustfsnet:
    name: rustfsnet
    driver: bridge
    ipam:
      config:
        - subnet: 172.50.0.0/24
  talk-net:
    name: talk-net
    driver: bridge
    ipam:
      config:
        - subnet: 172.60.0.0/24
NETWORKS

  # ── Volumes ─────────────────────────────────────────────────────────────
  echo "" >> "$dest"
  echo "volumes:" >> "$dest"
  # Pre-created by gen_certs() before docker compose up → external: true avoids the warning
  echo "  letsencrypt:" >> "$dest"
  echo "    external: true" >> "$dest"
  echo "    name: ${COMPOSE_PROJECT_NAME}_letsencrypt" >> "$dest"
  echo "  certbot_webroot:" >> "$dest"
  echo "    external: true" >> "$dest"
  echo "    name: ${COMPOSE_PROJECT_NAME}_certbot_webroot" >> "$dest"
  echo "  nextcloud_html:" >> "$dest"
  echo "  nextcloud_apps:" >> "$dest"
  echo "  nextcloud_config:" >> "$dest"
  echo "  nextcloud_data:" >> "$dest"
  local j
  for j in $(seq 1 "$MARIADB_NODES"); do
    echo "  mariadb_n${j}_data:" >> "$dest"
  done
  for j in $(seq 1 "$REDIS_NODES"); do
    echo "  redis_data_${j}:" >> "$dest"
  done
  echo "  redis_whiteboard_data:" >> "$dest"

  # Initialize the RustFS pools file on first deployment
  local _pools_file="$INSTALL_DIR/.rustfs-pools"
  if [[ ! -f "$_pools_file" ]] && (( RUSTFS_NODES > 1 )); then
    echo "1:${RUSTFS_NODES}" > "$_pools_file"
  fi

  info "docker-compose.yml generated ($dest)"
}

gen_signaling_conf() {
  local dest="${1:-$INSTALL_DIR/signaling.conf}"
  step "Generating signaling.conf (nextcloud-spreed-signaling)"

  # Build gRPC targets list — all signaling nodes (each node skips its own address at runtime)
  local grpc_targets=""
  local _sig_n="${SIGNALING_NODES:-2}"
  for _i in $(seq 1 "$_sig_n"); do
    grpc_targets+="${grpc_targets:+,}spreed-signaling-$(printf '%02d' "$_i"):9090"
  done

  # Build optional [turn] section when coturn is deployed
  local turn_section=""
  if [[ "$COTURN_ENABLED" == "yes" ]]; then
    turn_section="
[turn]
# API key clients send to /api/v1/turn to get temporary TURN credentials
apikey = ${GEN_TURN_APIKEY}
# Shared secret with coturn (must match --static-auth-secret)
secret = ${GEN_COTURN_SECRET}
servers = turn:${TALK_DOMAIN}:3478?transport=udp,turn:${TALK_DOMAIN}:3478?transport=tcp"
  fi

  cat > "$dest" <<EOF
# Auto-generated by deploy.sh — $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT EDIT MANUALLY — regenerate with deploy.sh

[http]
# Listen on all interfaces — HAProxy (talk-net) proxies inbound requests
listen = :8080

[app]
debug = false
# Trust HAProxy IPs on talk-net so X-Real-IP forwarding works correctly
trustedproxies = 172.60.0.0/24

[sessions]
# hashkey: 32 bytes (64 hex chars) — signs session tokens
hashkey = ${GEN_SIGNALING_HASHKEY}
# blockkey: 16 bytes (32 hex chars) — encrypts session payload (must be 16, 24 or 32 bytes)
blockkey = ${GEN_SIGNALING_BLOCKKEY}

[clients]
# internalsecret: for internal services (SIP bridge etc.) — distinct from backend secret
internalsecret = ${GEN_SIGNALING_INTERNAL_SECRET}

[backend]
backends = nc
timeout = 10
connectionsperhost = 8

[nc]
# urls: comma-separated list of Nextcloud instance URLs (section must be named after the backend id, not [backend "id"])
urls = https://${NC_DOMAIN}
# Shared secret — must match the secret registered via talk:signaling:add
secret = ${GEN_TALK_SECRET}
${turn_section}
[nats]
# loopback = built-in in-memory bus (no external NATS server needed since v2.x)
url = nats://loopback

[grpc]
# Listen for cross-node gRPC connections (required for multi-node session relay)
listen = 0.0.0.0:9090
# All signaling nodes as targets — each node detects and skips its own address
targets = ${grpc_targets}
EOF

  chmod 644 "$dest"
  info "signaling.conf generated: $dest"
}

gen_galera_cnf() {
  local dir="${1:-$INSTALL_DIR/mariadb}"
  step "Generating Galera configuration files"
  mkdir -p "$dir"

  # Build comma-separated cluster node list
  local cluster_nodes="" i
  for i in $(seq 1 "$MARIADB_NODES"); do
    [[ -n "$cluster_nodes" ]] && cluster_nodes+=","
    cluster_nodes+="mariadb-node${i}"
  done

  for i in $(seq 1 "$MARIADB_NODES"); do
    local wsrep_addr
    if (( i == 1 )); then
      wsrep_addr="gcomm://"
    else
      wsrep_addr="gcomm://${cluster_nodes}"
    fi

    cat > "${dir}/galera-node${i}.cnf" <<CNF
[mysqld]
wsrep_on                 = ON
wsrep_provider           = /usr/lib/galera/libgalera_smm.so
wsrep_cluster_name       = galera-cluster
wsrep_cluster_address    = ${wsrep_addr}
wsrep_node_name          = mariadb-node${i}
wsrep_node_address       = mariadb-node${i}
wsrep_sst_method         = rsync

binlog_format            = ROW
default_storage_engine   = InnoDB
innodb_autoinc_lock_mode = 2
innodb_flush_log_at_trx_commit = 0
innodb_buffer_pool_size  = 512M
innodb_log_file_size     = 128M

[mysqld_safe]
skip_log_error
CNF
    info "galera-node${i}.cnf → ${wsrep_addr}"
  done
}

patch_nextcloud_init() {
  local file="${1:-$INSTALL_DIR/nextcloud-init.sh}"
  step "Updating nextcloud-init.sh (Redis ${REDIS_NODES} nodes)"

  [[ -f "$file" ]] || die "nextcloud-init.sh not found: $file"

  # Rebuild seed lines dynamically for all REDIS_NODES nodes
  local seed_lines="" i
  for i in $(seq 0 $(( REDIS_NODES - 1 ))); do
    seed_lines+="occ config:system:set 'redis.cluster' seeds ${i} --value \"redis-node$(( i + 1 )):6379\"\n"
  done

  # Replace the full seed block (from seeds 0 to last seed before password line)
  python3 - "$file" <<PYEOF
import sys, re
path = sys.argv[1]
txt = open(path).read()
block = r"(occ config:system:set 'redis\.cluster' seeds \d+ --value \"redis-node\d+:6379\"\n)+"
new_seeds = """${seed_lines}"""
txt2 = re.sub(block, new_seeds, txt)
open(path, 'w').write(txt2)
PYEOF

  local masters=$(( REDIS_NODES / 2 ))
  info "nextcloud-init.sh ready: ${REDIS_NODES} seeds (redis-node1..${REDIS_NODES}) — ${masters} masters + ${masters} replicas"
}

create_rustfs_dirs() {
  step "Creating RustFS directories"
  start_spinner "Preparing directories..."
  local n d
  for n in $(seq 1 "$RUSTFS_NODES"); do
    for d in $(seq 1 "$RUSTFS_DISKS"); do
      local path="${RUSTFS_PATHS[${n}_${d}]}"
      mkdir -p "$path"
      find "${path:?}" -mindepth 1 -delete 2>/dev/null || true
      # RustFS container runs as UID 10001 (user rustfs) — ensure write access
      chown -R 10001:10001 "$path" 2>/dev/null || true
    done
  done
  stop_spinner "RustFS directories ready"
}

patch_haproxy() {
  local file="${1:-$INSTALL_DIR/haproxy.cfg}"
  step "Updating HAProxy backends"

  [[ -f "$file" ]] || die "haproxy.cfg not found: $file"

  # Replace server lines between BEGIN/END markers
  _replace_servers() {
    local marker="$1" new_block="$2" cfg="$3"
    awk -v marker="$marker" -v block="$new_block" '
      $0 ~ "# BEGIN_SERVERS_" marker { print; printf "%s\n", block; skip=1; next }
      $0 ~ "# END_SERVERS_" marker   { skip=0 }
      !skip { print }
    ' "$cfg"
  }

  # Generate server blocks for each service
  local nc_servers="" i
  for i in $(seq 1 "$NC_NODES"); do
    local name; name="nginx-next-$(printf '%02d' "$i")"
    nc_servers+="  server ${name} ${name}:80 check cookie NC$(printf '%02d' "$i")"$'\n'
  done

  local collab_servers=""
  for i in $(seq 1 "$COLLAB_NODES"); do
    collab_servers+="  server collabora-node${i} collabora-node${i}:9980 check"$'\n'
  done

  local wb_servers=""
  for i in $(seq 1 "$WB_NODES"); do
    wb_servers+="  server whiteboard-node${i} whiteboard-node${i}:3002 check cookie WB${i}"$'\n'
  done

  local galera_servers=""
  for i in $(seq 1 "$MARIADB_NODES"); do
    galera_servers+="  server mariadb-node${i} mariadb-node${i}:3306 check"$'\n'
  done

  local rustfs_servers=""
  for i in $(seq 1 "$RUSTFS_NODES"); do
    rustfs_servers+="  server rustfs-node${i} rustfs-node${i}:9000 check"$'\n'
  done

  local redis_servers=""
  for i in $(seq 1 "$REDIS_NODES"); do
    redis_servers+="  server redis-node${i} redis-node${i}:6379 check"$'\n'
  done

  local fpm_servers=""
  for i in $(seq 1 "$NC_NODES"); do
    fpm_servers+="  server app-next-$(printf '%02d' "$i") app-next-$(printf '%02d' "$i"):9000 check"$'\n'
  done

  local signaling_servers=""
  for i in $(seq 1 "${SIGNALING_NODES:-2}"); do
    signaling_servers+="  server spreed-signaling-$(printf '%02d' "$i") spreed-signaling-$(printf '%02d' "$i"):8080 check"$'\n'
  done

  # Apply patches sequentially using temp files
  local tmp tmp2
  tmp=$(mktemp)
  tmp2=$(mktemp)
  cp "$file" "$tmp"

  _replace_servers "NEXTCLOUD"     "${nc_servers%$'\n'}"        "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  _replace_servers "NEXTCLOUD_FPM" "${fpm_servers%$'\n'}"       "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  _replace_servers "COLLABORA"     "${collab_servers%$'\n'}"    "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  _replace_servers "WHITEBOARD"    "${wb_servers%$'\n'}"        "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  _replace_servers "GALERA"        "${galera_servers%$'\n'}"    "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  _replace_servers "RUSTFS"              "${rustfs_servers%$'\n'}"     "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  # Console servers: same nodes as S3 but on port 9001
  local console_servers=""
  for i in $(seq 1 "$RUSTFS_NODES"); do
    console_servers+="  server rustfs-node${i} rustfs-node${i}:9001 check cookie RC${i}"$'\n'
  done
  _replace_servers "RUSTFS_CONSOLE"  "${console_servers%$'\n'}"    "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  _replace_servers "REDIS"           "${redis_servers%$'\n'}"      "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"

  # Talk HA: populate signaling servers or strip the whole Talk section
  if [[ "${TALK_ENABLED:-no}" == "yes" ]]; then
    _replace_servers "SIGNALING" "${signaling_servers%$'\n'}" "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
    # Restore ACL and routing lines if stripped by a previous TALK_ENABLED=no run
    if ! grep -q 'acl is_talk' "$tmp"; then
      sed -i '/acl is_whiteboard/a\  acl is_talk        hdr(host) -i ${TALK_DOMAIN}' "$tmp"
    fi
    if ! grep -q 'use_backend signaling' "$tmp"; then
      sed -i '/use_backend whiteboard/a\  use_backend signaling   if is_talk' "$tmp"
    fi
    # Restore full backend signaling block if stripped by a previous TALK_ENABLED=no run
    if ! grep -q 'backend signaling' "$tmp"; then
      local _sig_servers="${signaling_servers%$'\n'}"
      python3 - "$tmp" "$_sig_servers" <<'PYEOF'
import sys
path, servers = sys.argv[1], sys.argv[2]
content = open(path).read()
block = (
  "# BEGIN_TALK_BACKEND\n"
  "# Backend Talk Signaling (nextcloud-spreed-signaling)\n"
  "backend signaling\n"
  "  mode http\n"
  "  balance leastconn\n"
  "  no option http-server-close\n"
  "  no option redispatch\n"
  "  retries 0\n"
  "  timeout connect 5s\n"
  "  timeout server  60s\n"
  "  timeout tunnel  3600s\n"
  "  option httpchk\n"
  "  http-check send meth GET uri /api/v1/welcome ver HTTP/1.1 hdr Host ${TALK_DOMAIN}\n"
  "  http-check expect status 200\n"
  "  default-server inter 10s fastinter 1s rise 2 fall 2 resolvers docker init-addr libc,none\n"
  "  # BEGIN_SERVERS_SIGNALING\n"
  + servers + "\n"
  "  # END_SERVERS_SIGNALING\n"
  "# END_TALK_BACKEND\n\n"
)
anchor = "# BEGIN_RUSTFS_CONSOLE_BACKEND"
content = content.replace(anchor, block + anchor) if anchor in content else content + "\n" + block
open(path, "w").write(content)
PYEOF
    fi
  else
    # Remove acl + backend routing lines
    awk '!/acl is_talk / && !/use_backend signaling /' "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
    # Strip Talk domains from CSP replace-header line
    sed 's| https://\${TALK_DOMAIN} wss://\${TALK_DOMAIN}||g' "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
    # Remove backend signaling block
    awk '/# BEGIN_TALK_BACKEND/{skip=1} /# END_TALK_BACKEND/{skip=0; next} !skip{print}' \
      "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  fi

  # Remove stats block from https frontend if disabled (between BEGIN/END_STATS markers)
  if [[ "$HAPROXY_STATS" == "no" ]]; then
    awk '/# BEGIN_STATS/{skip=1} /# END_STATS/{skip=0; next} !skip{print}' \
      "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  fi

  # Remove RustFS console blocks if disabled
  if [[ "$RUSTFS_CONSOLE" != "yes" ]]; then
    awk '/# BEGIN_RUSTFS_CONSOLE$/{skip=1} /# END_RUSTFS_CONSOLE$/{skip=0; next} !skip{print}' \
      "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
    awk '/# BEGIN_RUSTFS_CONSOLE_BACKEND/{skip=1} /# END_RUSTFS_CONSOLE_BACKEND/{skip=0; next} !skip{print}' \
      "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  fi

  mv "$tmp" "$file"
  local _talk_status="${TALK_ENABLED:-no}"; [[ "$_talk_status" == "yes" ]] && _talk_status="yes (${SIGNALING_NODES:-2} nodes)"
  info "haproxy.cfg patched (NC:${NC_NODES} Collab:${COLLAB_NODES} WB:${WB_NODES} DB:${MARIADB_NODES} RustFS:${RUSTFS_NODES} Talk:${_talk_status})"
}

# ─── [PATCH] Collabora binary patch — removing home_mode limit ───────────────

patch_collabora_binary() {
  # $1 optional: first node preferred for extraction (e.g. first new node
  #   during scale-up, which has an unpatched binary). Default = 1.
  local first_src="${1:-1}"
  step "Collabora binary patch — removing home_mode limit"

  # Wait for Collabora containers to be running (max 120 s)
  local max_wait=120 elapsed=0
  start_spinner "Waiting for Collabora containers..."
  while (( elapsed < max_wait )); do
    local all_up=true i
    for i in $(seq 1 "$COLLAB_NODES"); do
      local st
      st=$(docker inspect --format='{{.State.Status}}' "collabora-node${i}" 2>/dev/null || echo "absent")
      [[ "$st" == "running" ]] || { all_up=false; break; }
    done
    $all_up && break
    sleep 3; (( elapsed += 3 )) || true
  done
  stop_spinner

  if (( elapsed >= max_wait )); then
    warn "Collabora containers unavailable after ${max_wait}s — patch skipped"
    return 0
  fi

  local bin_tmp patched_tmp
  bin_tmp=$(mktemp)
  patched_tmp=$(mktemp)

  # Extract binary from first_src preferentially (new node = unpatched binary),
  # then fall back to other nodes if first_src is not available.
  local src_node=""
  for i in $(seq "$first_src" "$COLLAB_NODES") $(seq 1 $(( first_src - 1 ))); do
    if docker cp "collabora-node${i}:/usr/bin/coolwsd" "$bin_tmp" 2>/dev/null; then
      src_node="collabora-node${i}"
      break
    fi
  done

  if [[ -z "$src_node" ]]; then
    warn "Cannot extract coolwsd — patch skipped"
    rm -f "$bin_tmp" "$patched_tmp"
    return 0
  fi

  # Apply patch via dynamic pattern search in the binary
  local patch_result
  patch_result=$(python3 - "$bin_tmp" "$patched_tmp" <<'PATCHPY'
import sys, struct

INT_MAX  = b"\xff\xff\xff\x7f"
MAX_GAP  = 64   # max bytes between the two MOV instructions
TEST_WIN = 24   # window after the 2nd MOV to search for TEST/CMP

data = bytearray(open(sys.argv[1], "rb").read())

# ── Generate all MOV r32, <val> encodings (x86-64) ───────────────────────────
# Opcodes B8..BF = eax/ecx/edx/ebx/esp/ebp/esi/edi
# 41 B8..BF = r8d..r15d  (REX.B prefix)
_base = list(range(0xB8, 0xC0))

def all_mov(val):
    """Returns list of (pattern_bytes, offset_of_immediate_in_pattern)."""
    r = []
    v = struct.pack("<I", val)
    for op in _base:
        r.append((bytes([op]) + v, 1))
    for op in _base:
        r.append((bytes([0x41, op]) + v, 2))
    return r

def find_pair(data, list_a, list_b, max_gap, require_test=True):
    """Searches for (MOV A, MOV B) with optional TEST/CMP in the following window."""
    for pa, off_a in list_a:
        start = 0
        while True:
            pos_a = data.find(pa, start)
            if pos_a == -1:
                break
            end_b = pos_a + len(pa) + max_gap
            for pb, off_b in list_b:
                pos_b = data.find(pb, pos_a + len(pa), end_b)
                if pos_b == -1:
                    continue
                if require_test:
                    after = pos_b + len(pb)
                    win = bytes(data[after : after + TEST_WIN])
                    # TEST r/m8 = 0x84 ; TEST r/m32 = 0x85 ; CMP r/m32 = 0x83/0x81
                    if 0x84 not in win and 0x85 not in win and 0x83 not in win:
                        continue
                return pos_a, off_a, pos_b, off_b
            start = pos_a + 1
    return None

mov20 = all_mov(20)
mov10 = all_mov(10)

# ── Strategy 1: exact original pattern ───────────────────────────────────────
# No global ORIG_PATCHED search — false positives exist in the binary.
# "Already patched" detection is done only at the found offset.
ORIG = b"\xba\x14\x00\x00\x00\xb8\x0a\x00\x00\x00\x84\xdb"
idx = data.find(ORIG)
if idx != -1:
    if data[idx + 1 : idx + 5] == INT_MAX and data[idx + 6 : idx + 10] == INT_MAX:
        print("already_patched")
        sys.exit(0)
    data[idx + 1 : idx + 5]  = INT_MAX
    data[idx + 6 : idx + 10] = INT_MAX
    open(sys.argv[2], "wb").write(data)
    print(f"patched_exact_at_0x{idx:x}")
    sys.exit(0)

# ── Strategy 2: MOV r32,20 + MOV r32,10 (any register) + TEST ────────────────
# Fixed order (20 then 10): reversed order generates false positives on patched binary
result = find_pair(data, mov20, mov10, MAX_GAP)

# ── Strategy 3: anchor on "home_mode.enable" string in the binary ────────────
# (Strategy (20+20) removed: 56+ false positives in the binary)
if result is None:
    anchor = b"home_mode.enable"
    str_pos = data.find(anchor)
    if str_pos != -1:
        code_refs = []
        for i in range(max(0, str_pos - 0x100000), min(len(data) - 4, str_pos + 0x100000)):
            try:
                disp = struct.unpack_from("<i", data, i)[0]
                if i + 4 + disp == str_pos:
                    code_refs.append(i)
            except Exception:
                pass
        for ref in code_refs:
            win_start = max(0, ref - 128)
            win_end   = min(len(data), ref + 256)
            sub = bytearray(data[win_start:win_end])
            for val_a in [20, 10]:
                for val_b in [20, 10]:
                    if val_a == val_b:
                        continue
                    r = find_pair(sub, all_mov(val_a), all_mov(val_b), MAX_GAP)
                    if r:
                        pos_a, off_a, pos_b, off_b = r
                        result = (win_start + pos_a, off_a, win_start + pos_b, off_b)
                        break
                if result:
                    break
            if result:
                break

if result is None:
    print("pattern_not_found")
    sys.exit(2)

pos_a, off_a, pos_b, off_b = result
# Already-patched detection at precise found offsets (no global false positive)
if (data[pos_a + off_a : pos_a + off_a + 4] == INT_MAX and
        data[pos_b + off_b : pos_b + off_b + 4] == INT_MAX):
    print("already_patched")
    sys.exit(0)
data[pos_a + off_a : pos_a + off_a + 4] = INT_MAX
data[pos_b + off_b : pos_b + off_b + 4] = INT_MAX
open(sys.argv[2], "wb").write(data)
print(f"patched_at_0x{pos_a:x}_0x{pos_b:x}")
PATCHPY
  2>/dev/null)

  local py_rc=$?

  if [[ "$patch_result" == "already_patched" ]]; then
    info "Collabora patch already present in image — no action taken"
    rm -f "$bin_tmp" "$patched_tmp"
    return 0
  fi

  if (( py_rc != 0 )) || [[ "$patch_result" == "pattern_not_found" ]]; then
    warn "home_mode limit not found in coolwsd — 3 strategies attempted (exact, multi-register 20/10, 'home_mode.enable' string anchor)"
    warn "The binary may have changed its limit values or encoding. If the patch is already applied on this container, ignore this message."
    rm -f "$bin_tmp" "$patched_tmp"
    return 0
  fi

  chmod 755 "$patched_tmp"

  # Deploy to all nodes and restart
  local failed=0
  for i in $(seq 1 "$COLLAB_NODES"); do
    if docker cp "$patched_tmp" "collabora-node${i}:/usr/bin/coolwsd" 2>/dev/null; then
      docker exec "collabora-node${i}" chmod 755 /usr/bin/coolwsd 2>/dev/null || true
      docker restart "collabora-node${i}" &>/dev/null || true
      info "Patch applied + restart: collabora-node${i}  (${patch_result})"
    else
      warn "Cannot patch collabora-node${i}"
      (( failed++ )) || true
    fi
  done

  rm -f "$bin_tmp" "$patched_tmp"

  if (( failed > 0 )); then
    warn "${failed} node(s) not patched — home_mode limit still active"
  else
    info "Collabora: home_mode limit removed on ${COLLAB_NODES} node(s) — unlimited connections/documents"
  fi
}

# ─── [DEPLOY] Certificates and deployment ────────────────────────────────────

gen_certs() {
  phase 6 7 "SSL Certificate Generation"

  # Prefix = Docker Compose project name (must match volumes in docker-compose.yml)
  local prefix; prefix="$COMPOSE_PROJECT_NAME"
  # In staging, use a separate volume to avoid polluting the prod volume
  local le_vol="${prefix}_letsencrypt"
  [[ "$CERTBOT_STAGING" == "yes" ]] && le_vol="${prefix}_letsencrypt_staging"

  if [[ "$CERTBOT_STAGING" == "yes" ]]; then
    warn "STAGING mode — certificates not trusted by browsers (testing only)"
  fi

  # ── Skip if stack.pem already valid ──────────────────────────────────────
  if [[ -s "$INSTALL_DIR/certs/stack.pem" ]]; then
    info "Valid existing certificate found — generation skipped"
    return 0
  fi
  rm -f "$INSTALL_DIR/certs/stack.pem"

  # ── Reuse from Let's Encrypt volume if available ──────────────────────────
  step "Searching for existing certificate in volume"
  docker volume create "${prefix}_letsencrypt" &>/dev/null || true   # always created (used by renewal certbot in compose)
  docker volume create "${le_vol}" &>/dev/null || true               # same in prod; creates _staging in staging mode
  docker volume create "${prefix}_certbot_webroot" &>/dev/null || true

  if docker run --rm -v "${le_vol}:/etc/letsencrypt" alpine \
      test -f /etc/letsencrypt/live/stack/fullchain.pem 2>/dev/null; then
    info "Certificate found in volume — recombining without calling Let's Encrypt"
    mkdir -p "$INSTALL_DIR/certs"
    docker run --rm \
      -v "${le_vol}:/etc/letsencrypt:ro" \
      -v "$INSTALL_DIR/certs:/certs" \
      alpine sh -c "cat /etc/letsencrypt/live/stack/fullchain.pem \
        /etc/letsencrypt/live/stack/privkey.pem > /certs/stack.pem.tmp \
        && mv /certs/stack.pem.tmp /certs/stack.pem && chmod 644 /certs/stack.pem"
    [[ -s "$INSTALL_DIR/certs/stack.pem" ]] && {
      info "Certificate recombined: stack.pem ($(wc -c < "$INSTALL_DIR/certs/stack.pem") bytes)"
      return 0
    }
  fi

  # ── DNS verification ──────────────────────────────────────────────────────
  step "Domain DNS verification"
  local my_ip dns_ok=true
  my_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
          curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || \
          hostname -I 2>/dev/null | awk '{print $1}')
  info "Public IP detected: ${my_ip:-unknown}"

  local domain
  local _cert_domains=("$NC_DOMAIN" "$COLLAB_DOMAIN" "$WB_DOMAIN")
  [[ "${TALK_ENABLED:-no}" == "yes" ]] && _cert_domains+=("$TALK_DOMAIN")
  for domain in "${_cert_domains[@]}"; do
    local resolved=""
    resolved=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
    [[ -z "$resolved" ]] && resolved=$(dig +short "$domain" A 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$my_ip" && "$resolved" == "$my_ip" ]]; then
      info "$domain → $resolved ✓"
    elif [[ -z "$resolved" ]]; then
      warn "$domain → not resolved (DNS missing?)"
      dns_ok=false
    else
      warn "$domain → $resolved  (server IP: ${my_ip:-?}) — mismatch!"
      dns_ok=false
    fi
  done

  if ! $dns_ok; then
    warn "Some domains do not point to this server."
    warn "Let's Encrypt verifies DNS — certificates will fail if entries are incorrect."
    prompt_yn "Continue anyway?" "N" || die "Aborted — fix DNS and retry."
  fi

  # ── Port check ───────────────────────────────────────────────────────────
  local port80_free=true
  ss -tlnp 2>/dev/null | grep -q ':80 ' && port80_free=false

  # ── Certbot call ──────────────────────────────────────────────────────────
  step "Generating Let's Encrypt certificates"
  local _domain_list="${NC_DOMAIN}, ${COLLAB_DOMAIN}, ${WB_DOMAIN}"
  [[ "${TALK_ENABLED:-no}" == "yes" ]] && _domain_list+=", ${TALK_DOMAIN}"
  info "Domains: ${_domain_list}"
  info "Email  : ${CERTBOT_EMAIL}"

  local certbot_args=(
    certonly --standalone --non-interactive --keep-until-expiring
    --agree-tos --no-eff-email --email "$CERTBOT_EMAIL"
    -d "$NC_DOMAIN" -d "$COLLAB_DOMAIN" -d "$WB_DOMAIN"
  )
  [[ "${TALK_ENABLED:-no}" == "yes" ]] && certbot_args+=(-d "$TALK_DOMAIN")
  certbot_args+=(--cert-name stack)
  [[ "$CERTBOT_STAGING" == "yes" ]] && certbot_args+=(--staging)

  local cert_ok=false certbot_output=""

  if ! $port80_free; then
    die "Port 80 is in use — free it before running certbot (HTTP-01 requires port 80)."
  fi

  info "Attempting HTTP-01 (port 80)..."
  certbot_output=$(docker run --rm -p "80:80" \
    -v "${le_vol}:/etc/letsencrypt" \
    certbot/certbot "${certbot_args[@]}" \
    --preferred-challenges http-01 2>&1) && cert_ok=true

  if ! $cert_ok; then
    error "Certbot failed. Full output:"
    echo "$certbot_output" | tail -20 >&2
    # Detect rate limit and show unlock time
    local retry_after=""
    retry_after=$(echo "$certbot_output" | grep -oE 'until [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z' | head -1 | sed 's/until //')
    [[ -n "$retry_after" ]] && error "Rate limit — retry after: $retry_after"
    die "Check:\n  • DNS: domains point to this server\n  • Port 80 accessible from the Internet\n  • Rate limit: max 5 certificates / 7 days (use Staging mode for testing)"
  fi

  step "Combining fullchain + privkey for HAProxy"
  mkdir -p "$INSTALL_DIR/certs"
  docker run --rm \
    -v "${le_vol}:/etc/letsencrypt:ro" \
    -v "$INSTALL_DIR/certs:/certs" \
    alpine sh -c "cat /etc/letsencrypt/live/stack/fullchain.pem \
      /etc/letsencrypt/live/stack/privkey.pem > /certs/stack.pem.tmp \
      && mv /certs/stack.pem.tmp /certs/stack.pem && chmod 644 /certs/stack.pem"

  [[ -s "$INSTALL_DIR/certs/stack.pem" ]] || die "Failed: stack.pem is missing or empty"
  info "Certificate ready: $INSTALL_DIR/certs/stack.pem ($(wc -c < "$INSTALL_DIR/certs/stack.pem") bytes)"
}

fix_galera_bootstrap() {
  # If mariadb-node1 is already running, do nothing
  local status
  status=$(docker inspect --format='{{.State.Status}}' mariadb-node1 2>/dev/null || echo "absent")
  [[ "$status" == "running" ]] && return 0

  local project_name; project_name="$COMPOSE_PROJECT_NAME"
  local vol1="${project_name}_mariadb_n1_data"

  # No volume → clean first start, nothing to do
  docker volume inspect "$vol1" &>/dev/null || return 0

  # No grastate.dat → MariaDB has never run, nothing to do
  docker run --rm -v "${vol1}:/data" alpine test -f /data/grastate.dat 2>/dev/null || return 0

  info "Existing MariaDB volumes detected — fixing Galera bootstrap..."

  # Reset safe_to_bootstrap to 0 on all existing nodes
  local n
  for n in $(seq 1 "$MARIADB_NODES"); do
    local vol="${project_name}_mariadb_n${n}_data"
    docker volume inspect "$vol" &>/dev/null || continue
    docker run --rm -v "${vol}:/data" alpine \
      sh -c "test -f /data/grastate.dat && \
        sed -i 's/safe_to_bootstrap: 1/safe_to_bootstrap: 0/' /data/grastate.dat" \
      2>/dev/null || true
  done

  # Force node1 as bootstrap node (matches --wsrep-new-cluster in compose)
  docker run --rm -v "${vol1}:/data" alpine \
    sed -i 's/safe_to_bootstrap: 0/safe_to_bootstrap: 1/' /data/grastate.dat \
    2>/dev/null
  info "Galera: mariadb-node1 set as bootstrap node"
}

run_deploy() {
  cd "$INSTALL_DIR"

  # Explicit certificate check before any startup
  if [[ ! -s "./certs/stack.pem" ]]; then
    die "SSL certificate missing: $(pwd)/certs/stack.pem\nRe-run the script to regenerate the certificate."
  fi
  info "SSL certificate OK: $(pwd)/certs/stack.pem ($(wc -c < "./certs/stack.pem") bytes)"

  step "Pulling Docker images (parallel)"
  local images=(
    "${IMG_HAPROXY}"
    "${IMG_NGINX}"
    "${IMG_CERTBOT}"
    "nextcloud:${NC_VERSION}"
    "${IMG_REDIS}"
    "${IMG_RUSTFS}"
    "${IMG_COLLABORA}"
    "${IMG_WHITEBOARD}"
  )
  if [[ "${TALK_ENABLED:-no}" == "yes" ]]; then
    images+=("${IMG_SPREED_SIGNALING}")
    [[ "$COTURN_ENABLED" == "yes" ]] && images+=("${IMG_COTURN}")
  fi
  local total=${#images[@]}
  local tmpdir; tmpdir=$(mktemp -d)

  # Launch all pulls in parallel — keep PIDs for targeted wait
  # (wait without args would block on the tee process from setup_logging)
  local img pids=()
  for img in "${images[@]}"; do
    local safe; safe=$(echo "$img" | tr '/.:' '_')
    ( docker pull "$img" -q &>/dev/null && touch "$tmpdir/$safe" || touch "$tmpdir/${safe}.fail" ) &
    pids+=($!)
  done

  # Real-time display
  local done_count=0
  while (( done_count < total )); do
    done_count=$(ls "$tmpdir" 2>/dev/null | wc -l)
    progress_bar "$done_count" "$total" "Images being downloaded in parallel..."
    sleep 0.4
  done
  # Wait only for pull jobs (not the tee process from the log)
  wait "${pids[@]}" 2>/dev/null || true
  echo ""

  # Check for failures
  local img_failed=0
  for img in "${images[@]}"; do
    local safe; safe=$(echo "$img" | tr '/.:' '_')
    if [[ -f "$tmpdir/${safe}.fail" ]]; then
      error "Pull failed: $img"
      (( img_failed++ )) || true
    fi
  done
  rm -rf "$tmpdir"
  (( img_failed > 0 )) && die "${img_failed} image(s) could not be downloaded"
  info "All images downloaded"

  step "Building MariaDB Galera image"
  start_spinner "docker compose build..."
  docker compose build --quiet
  stop_spinner "MariaDB Galera image built"

  step "Starting infrastructure"

  # Start HAProxy first and wait for it to be healthy
  # before launching services that depend on it
  docker compose up -d haproxy nginx-acme certbot
  info "Waiting for HAProxy to respond on port 80..."
  local elapsed=0 max_wait=60
  while (( elapsed < max_wait )); do
    # Test from host via bash /dev/tcp (more reliable than nc in alpine)
    if timeout 3 bash -c '</dev/tcp/127.0.0.1/80' 2>/dev/null; then
      info "HAProxy responds on port 80 ✓"
      break
    fi
    # Check that the container has not crashed
    local state
    state=$(docker inspect --format='{{.State.Status}}' haproxy 2>/dev/null || echo "absent")
    if [[ "$state" != "running" ]]; then
      error "HAProxy container stopped (state: $state). Logs:"
      docker logs haproxy --tail 20 >&2
      die "HAProxy crashed — check logs above."
    fi
    printf "\r  ${C_YELLOW}⟳${C_RESET}  HAProxy starting... (%ds/%ds)   " "$elapsed" "$max_wait"
    sleep 3
    (( elapsed += 3 )) || true
  done
  if (( elapsed >= max_wait )); then
    echo ""
    error "HAProxy not responding after ${max_wait}s. Logs:"
    docker logs haproxy --tail 20 >&2
    die "HAProxy unreachable — check logs above."
  fi
  echo ""

  # Fix grastate.dat if MariaDB volumes exist from a previous deployment
  fix_galera_bootstrap

  # Launch all other services in the background
  start_spinner "Starting all services..."
  docker compose up -d 2>&1 | grep -E '^\s*(✔|✘|Error)' || true
  stop_spinner "Services started"
  info "Services started — waiting for Nextcloud installation (max 15 min)..."
  local deadline=$(( $(date +%s) + 900 )) elapsed_setup=0
  while (( $(date +%s) < deadline )); do
    local setup_status
    setup_status=$(docker inspect --format='{{.State.Status}}' nextcloud-setup 2>/dev/null || echo "absent")
    if [[ "$setup_status" == "exited" ]]; then
      local exit_code
      exit_code=$(docker inspect --format='{{.State.ExitCode}}' nextcloud-setup 2>/dev/null || echo "1")
      if [[ "$exit_code" == "0" ]]; then
        info "nextcloud-setup completed successfully ✓"
      else
        warn "nextcloud-setup completed with error (code $exit_code)"
        docker logs nextcloud-setup --tail 20
      fi
      break
    fi
    (( elapsed_setup += 10 )) || true
    local last_log
    last_log=$(docker logs nextcloud-setup --tail 1 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*[mK]//g' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    printf "\r\033[K  ${C_YELLOW}⟳${C_RESET}  [%ds]  %s" \
      "$elapsed_setup" "${last_log:-Nextcloud installation in progress...}"
    sleep 10
  done
  echo ""
}

# ─── [CHECK] Verification and summary ───────────────────────────────────────

wait_healthy() {
  phase 7 7 "Infrastructure Verification"
  step "Waiting for all services to be healthy"

  # Adaptive timeout based on node count (base 600s + 60s/NC + 20s/DB + 20s/RustFS + 30s/Collab)
  local timeout interval=10
  timeout=$(( 600 + NC_NODES * 60 + MARIADB_NODES * 20 + RUSTFS_NODES * 20 + COLLAB_NODES * 30 ))
  (( timeout > 1800 )) && timeout=1800
  local elapsed=0

  # Critical containers to monitor
  local containers=("haproxy")
  local i
  for i in $(seq 1 "$NC_NODES");      do containers+=("app-next-$(printf '%02d' "$i")"); done
  for i in $(seq 1 "$NC_NODES");      do containers+=("nginx-next-$(printf '%02d' "$i")"); done
  for i in $(seq 1 "$MARIADB_NODES"); do containers+=("mariadb-node${i}"); done
  containers+=("redis-node1")
  for i in $(seq 1 "$RUSTFS_NODES");  do containers+=("rustfs-node${i}"); done

  info "Calculated timeout: ${timeout}s (${NC_NODES} NC + ${MARIADB_NODES} DB + ${RUSTFS_NODES} RustFS + ${COLLAB_NODES} Collabora)"

  # Consecutive restart counters per container (crash loop detection)
  declare -A _restart_counts=()
  local _crash_loop=()

  while (( elapsed < timeout )); do
    local remaining=$(( timeout - elapsed ))
    local eta_min=$(( remaining / 60 )) eta_sec=$(( remaining % 60 ))
    printf "\n  ${C_GRAY}[ $(date '+%H:%M:%S') — %ds elapsed — ETA %dm%02ds ]${C_RESET}\n" \
      "$elapsed" "$eta_min" "$eta_sec"
    local all_healthy=true

    for name in "${containers[@]}"; do
      # Containers confirmed in crash loop: display and ignore (no longer block the wait)
      if [[ " ${_crash_loop[*]:-} " == *" ${name} "* ]]; then
        printf "  ${C_BRED}✗${C_RESET}  %s  ${C_RED}(crash loop — excluded)${C_RESET}\n" "$name"
        continue
      fi

      local status
      if ! docker inspect "$name" &>/dev/null; then
        status="absent"
      else
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null | tr -d '\n\r')
        if [[ -z "$health" || "$health" == "<no value>" ]]; then
          local cstate
          cstate=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null | tr -d '\n\r')
          [[ "$cstate" == "running" ]] && status="healthy" || status="${cstate:-absent}"
        else
          status="$health"
        fi
      fi

      case "$status" in
        healthy)
          printf "  ${C_BGREEN}✓${C_RESET}  %s\n" "$name"
          _restart_counts["$name"]=0
          ;;
        starting)
          printf "  ${C_YELLOW}⟳${C_RESET}  %s  ${C_GRAY}(starting...)${C_RESET}\n" "$name"
          all_healthy=false
          ;;
        unhealthy)
          printf "  ${C_BRED}✗${C_RESET}  %s  ${C_RED}(unhealthy — docker logs %s)${C_RESET}\n" "$name" "$name"
          all_healthy=false
          ;;
        restarting)
          _restart_counts["$name"]=$(( ${_restart_counts["$name"]:-0} + 1 ))
          local rc=${_restart_counts["$name"]}
          if (( rc >= 3 )); then
            warn "${name} in crash loop (${rc} restarts) — excluded from wait"
            warn "  docker logs ${name}"
            _crash_loop+=("$name")
          else
            printf "  ${C_YELLOW}⟳${C_RESET}  %s  ${C_GRAY}(restarting… %d/3)${C_RESET}\n" "$name" "$rc"
            all_healthy=false
          fi
          ;;
        *)
          printf "  ${C_GRAY}·${C_RESET}  %s  ${C_GRAY}(%s)${C_RESET}\n" "$name" "$status"
          all_healthy=false
          ;;
      esac
    done

    if $all_healthy; then
      if (( ${#_crash_loop[@]} > 0 )); then
        warn "Services in crash loop (non-blocking): ${_crash_loop[*]}"
      fi
      info "All monitored services are healthy ✓"
      return 0
    fi
    sleep "$interval"
    (( elapsed += interval )) || true
  done

  if (( ${#_crash_loop[@]} > 0 )); then
    warn "Crash loop containers detected: ${_crash_loop[*]}"
    warn "Check: docker logs ${_crash_loop[0]}"
  fi
  die "Timeout — some services are not healthy after ${timeout}s.\nCheck: docker compose logs"
}

reset_bruteforce() {
  local redis_pass
  redis_pass=$(grep -m1 '^REDIS_PASSWORD=' "$INSTALL_DIR/.env" | cut -d= -f2)
  [[ -z "$redis_pass" ]] && { warn "REDIS_PASSWORD not found — skipping bruteforce reset"; return 0; }

  step "Cleaning Nextcloud brute force entries (Redis)"
  local deleted=0 i key keys

  for i in $(seq 1 "$REDIS_NODES"); do
    keys=$(docker exec "redis-node${i}" redis-cli -a "$redis_pass" --no-auth-warning \
      KEYS '*Bruteforce*' 2>/dev/null) || true
    if [[ -n "$keys" ]]; then
      while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        docker exec redis-node1 redis-cli -c -a "$redis_pass" --no-auth-warning \
          DEL "$key" &>/dev/null && (( deleted++ )) || true
      done <<< "$keys"
    fi
  done

  (( deleted > 0 )) \
    && info "Brute force reset: ${deleted} key(s) deleted from Redis" \
    || info "Brute force reset: no entries to delete"
}

configure_talk() {
  [[ "${TALK_ENABLED:-no}" != "yes" ]] && return 0

  step "Configuring Nextcloud Talk (spreed)"

  local -a occ=(docker exec -u www-data app-next-01 php /var/www/html/occ)
  local talk_secret
  talk_secret=$(grep -m1 '^TALK_SIGNALING_SECRET=' "$INSTALL_DIR/.env" | cut -d= -f2 | tr -d '"')

  if [[ -z "$talk_secret" ]]; then
    warn "TALK_SIGNALING_SECRET not found in .env — skipping Talk configuration"
    return 0
  fi

  # Install and enable spreed app — must be enabled before talk:* commands work
  local install_out
  if "${occ[@]}" app:list 2>/dev/null | grep -q 'spreed'; then
    info "Talk (spreed) app already present — enabling"
  else
    info "Installing Talk (spreed) app..."
    install_out=$("${occ[@]}" app:install spreed 2>&1) \
      && info "spreed installed: ${install_out}" \
      || warn "app:install spreed: ${install_out}"
  fi
  "${occ[@]}" app:enable spreed 2>&1 | grep -v '^$' | while read -r l; do info "$l"; done || true

  local out

  # Use config:app:set directly to store the correct Talk 23 format.
  # talk:signaling:add omits the secret inside the server object, causing
  # Config::getSignalingSecret() to return null (TypeError on the admin page).
  # Talk 23 requires: {"servers":[{"server":"wss://...","verify":true,"secret":"..."}],"secret":"..."}
  local signaling_json
  signaling_json='{"servers":[{"server":"wss://'"${TALK_DOMAIN}"'/","verify":true,"secret":"'"${talk_secret}"'"}],"secret":"'"${talk_secret}"'"}'
  out=$("${occ[@]}" config:app:set spreed signaling_servers --value "$signaling_json" 2>&1)
  info "signaling_servers set: $out"

  # Remove legacy standalone key left by older Talk versions
  "${occ[@]}" config:app:delete spreed signaling_secret 2>/dev/null || true

  # Verify
  local stored
  stored=$("${occ[@]}" talk:signaling:list 2>/dev/null)
  info "Signaling servers: $stored"

  # Configure STUN/TURN if coturn is deployed
  if [[ "$COTURN_ENABLED" == "yes" ]]; then
    local coturn_secret
    coturn_secret=$(grep -m1 '^COTURN_SECRET=' "$INSTALL_DIR/.env" | cut -d= -f2 | tr -d '"')

    # STUN
    "${occ[@]}" talk:stun:list 2>/dev/null | grep -q "${TALK_DOMAIN}" \
      && info "STUN server already registered — skipping add" \
      || {
        out=$("${occ[@]}" talk:stun:add "${TALK_DOMAIN}:3478" 2>&1)
        info "talk:stun:add: $out"
      }

    # TURN
    "${occ[@]}" talk:turn:list 2>/dev/null | grep -q "${TALK_DOMAIN}" \
      && info "TURN server already registered — skipping add" \
      || {
        out=$("${occ[@]}" talk:turn:add --secret="$coturn_secret" "turn" "${TALK_DOMAIN}:3478" "udp,tcp" 2>&1)
        info "talk:turn:add: $out"
      }
  fi
}

configure_notify_push() {
  step "Configuring Nextcloud Client Push (notify_push)"
  local -a occ=(docker exec -u www-data app-next-01 php /var/www/html/occ)

  if "${occ[@]}" app:list 2>/dev/null | grep -q 'notify_push'; then
    info "notify_push already installed — enabling"
    "${occ[@]}" app:enable notify_push &>/dev/null || true
  else
    info "Installing notify_push app..."
    local out
    out=$("${occ[@]}" app:install notify_push 2>&1)
    info "$out"
  fi

  # Block until notify-push binary responds on port 7867 (max 300s safety cap)
  # Check via app-next-01 (same Docker network, guaranteed to have curl)
  info "Waiting for notify-push binary to be ready..."
  local _np_wait=0
  until docker exec app-next-01 curl -sf http://notify-push:7867/test/cookie 2>/dev/null | grep -q 'false'; do
    sleep 3; _np_wait=$(( _np_wait + 3 ))
    if [[ $_np_wait -ge 300 ]]; then
      warn "notify_push: binary did not respond after 300s — setup will likely fail"
      break
    fi
  done

  # Retry setup up to 6 times — "can't load mount info" is transient on first boot
  local _push_ok=0 _attempt
  for _attempt in $(seq 1 6); do
    local out
    out=$("${occ[@]}" notify_push:setup "https://${NC_DOMAIN}/push" 2>&1)
    info "notify_push:setup: $out"
    if echo "$out" | grep -q 'configuration saved'; then
      _push_ok=1; break
    fi
    [[ $_attempt -lt 6 ]] && { warn "notify_push: setup attempt ${_attempt}/6 failed, retrying in 10s..."; sleep 10; }
  done
  [[ $_push_ok -eq 0 ]] && warn "notify_push: setup failed after retries — run manually: occ notify_push:setup https://${NC_DOMAIN}/push"
}

check_services() {
  step "Functional tests"
  local failures=0

  _check() {
    local label="$1"; shift
    if "$@" &>/dev/null 2>&1; then
      printf "  ${C_BGREEN}✓${C_RESET}  %s\n" "$label"
    else
      printf "  ${C_BRED}✗${C_RESET}  %s\n" "$label"
      (( failures++ )) || true
    fi
  }

  _check "HAProxy HTTP→HTTPS redirect" \
    bash -c "curl -sf -o /dev/null -w '%{http_code}' http://localhost/ | grep -qE '301|302'"

  _check "Nextcloud installed" \
    bash -c "curl -skf https://${NC_DOMAIN}/status.php | grep -q '\"installed\":true'"

  _check "MariaDB Galera actif" \
    docker exec mariadb-node1 mariadb-admin ping -uroot -p"${GEN_DB_ROOT_PASS}" --silent

  _check "Redis Cluster OK" \
    bash -c "docker exec redis-node1 redis-cli -a '${GEN_REDIS_PASS}' --no-auth-warning cluster info | grep -q 'cluster_state:ok'"

  _check "RustFS S3 health" \
    bash -c "docker exec rustfs-node1 curl -sf http://localhost:9000/health 2>/dev/null"

  _check "nextcloud-setup completed" \
    bash -c "docker logs nextcloud-setup 2>&1 | grep -q 'Setup Nextcloud terminé'"

  _check "nextcloud-cron actif" \
    bash -c "docker inspect nextcloud-cron --format='{{.State.Running}}' 2>/dev/null | grep -q true"

  if [[ "${TALK_ENABLED:-no}" == "yes" ]]; then
    local _sig_i
    for _sig_i in $(seq 1 "${SIGNALING_NODES:-2}"); do
      local _sig_name="spreed-signaling-$(printf '%02d' "$_sig_i")"
      _check "Talk signaling reachable (${_sig_name})" \
        bash -c "docker exec ${_sig_name} sh -c \"echo '' | nc -w2 127.0.0.1 8080\" 2>/dev/null"
    done
  fi

  if (( failures > 0 )); then
    warn "${failures} test(s) failed — check: docker compose logs"
  else
    info "All functional tests pass ✓"
  fi
}

show_summary() {
  # Save credentials first
  local creds_file="$INSTALL_DIR/.credentials"
  cat > "$creds_file" <<CREDS
# Azure NXT Maxscale — Credentials — $(date '+%Y-%m-%d %H:%M:%S')
NEXTCLOUD_URL=https://${NC_DOMAIN}
NEXTCLOUD_USER=admin
NEXTCLOUD_PASSWORD=${GEN_NC_ADMIN_PASS}
MARIADB_ROOT_PASSWORD=${GEN_DB_ROOT_PASS}
MARIADB_PASSWORD=${GEN_DB_PASS}
REDIS_PASSWORD=${GEN_REDIS_PASS}
RUSTFS_ACCESS_KEY=${GEN_RUSTFS_KEY}
RUSTFS_SECRET_KEY=${GEN_RUSTFS_SECRET}
HAPROXY_STATS_PASSWORD=${GEN_HAPROXY_STATS_PASS}
CREDS
  chmod 600 "$creds_file"

  local host_ip
  host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

  local stats_line="HAProxy Stats  : disabled"
  [[ "$HAPROXY_STATS" == "yes" ]] && \
    stats_line="HAProxy Stats  : https://${NC_DOMAIN}/stats  (admin / ${GEN_HAPROXY_STATS_PASS})"

  local console_line="RustFS Console  : disabled"
  [[ "$RUSTFS_CONSOLE" == "yes" ]] && \
    console_line="RustFS Console  : https://${NC_DOMAIN}/s3-console  (login: RUSTFS_ACCESS_KEY / RUSTFS_SECRET_KEY)"

  local talk_line
  if [[ "${TALK_ENABLED:-no}" == "yes" ]]; then
    talk_line="Talk signaling : https://${TALK_DOMAIN}  (${SIGNALING_NODES:-2} nodes + NATS)  coturn: ${COTURN_ENABLED}"
  else
    talk_line="Talk signaling : disabled"
  fi

  # Dynamic width: adapts to the longest line (password, domain, etc.)
  local I=0 _lw
  for _line in \
      "✓  DEPLOYMENT COMPLETED SUCCESSFULLY" \
      "URL      : https://${NC_DOMAIN}" \
      "Password : ${GEN_NC_ADMIN_PASS}" \
      "Collabora  : https://${COLLAB_DOMAIN}" \
      "Whiteboard : https://${WB_DOMAIN}" \
      "$talk_line" \
      "$stats_line" \
      "$console_line" \
      "Nextcloud ${NC_NODES}×FPM + ${NC_NODES}×nginx  │  MariaDB ${MARIADB_NODES} nodes  │  Redis ${REDIS_NODES} nodes" \
      "RustFS ${RUSTFS_NODES}×${RUSTFS_DISKS}  │  Collabora ${COLLAB_NODES} nodes  │  Whiteboard ${WB_NODES} nodes" \
      "Credentials : ${creds_file}" \
      "AFTER A RUSTFS NODE FAILURE:" \
      "  RustFS restores data automatically via erasure coding."; do
    _lw=$(_vlen "$_line")
    (( _lw > I )) && I=$_lw
  done
  local _B; printf -v _B '%*s' $(( I + 2 )) ''; _B="${_B// /═}"
  local _TOP="╔${_B}╗" _SEP="╠${_B}╣" _BOT="╚${_B}╝"
  _sl() { printf '║  '; _rpad "$1" $I; printf '║\n'; }

  echo ""
  echo -e "${C_BGREEN}"
  echo "$_TOP"
  _sl "✓  DEPLOYMENT COMPLETED SUCCESSFULLY"
  echo "$_SEP"
  _sl "NEXTCLOUD ACCESS"
  _sl "URL      : https://${NC_DOMAIN}"
  _sl "Login    : admin"
  _sl "Password : ${GEN_NC_ADMIN_PASS}"
  echo "$_SEP"
  _sl "SERVICES"
  _sl "Collabora  : https://${COLLAB_DOMAIN}"
  _sl "Whiteboard : https://${WB_DOMAIN}"
  _sl "$talk_line"
  _sl "$stats_line"
  _sl "$console_line"
  echo "$_SEP"
  _sl "INFRASTRUCTURE"
  _sl "Nextcloud ${NC_NODES}×FPM + ${NC_NODES}×nginx  │  MariaDB ${MARIADB_NODES} nodes  │  Redis ${REDIS_NODES} nodes"
  _sl "RustFS ${RUSTFS_NODES}×${RUSTFS_DISKS}  │  Collabora ${COLLAB_NODES} nodes  │  Whiteboard ${WB_NODES} nodes"
  echo "$_SEP"
  _sl "Credentials : ${creds_file}"
  echo "$_SEP"
  _sl "AFTER A RUSTFS NODE FAILURE:"
  _sl "  RustFS restores data automatically via erasure coding."
  _sl "  Check cluster status: docker logs rustfs-node1"
  echo "$_BOT"
  echo -e "${C_RESET}"
}

final_check() {
  step "Nextcloud access test"
  local max_wait=90 elapsed=0
  while (( elapsed < max_wait )); do
    if curl -skf --max-time 10 "https://${NC_DOMAIN}/status.php" 2>/dev/null \
        | grep -q '"installed":true'; then
      info "Nextcloud responds ✓  →  https://${NC_DOMAIN}"
      return 0
    fi
    sleep 5; (( elapsed += 5 )) || true
    printf "\r\033[K  ${C_YELLOW}⟳${C_RESET}  Testing Nextcloud access... (%ds/%ds)" "$elapsed" "$max_wait"
  done
  echo ""
  warn "Nextcloud is not responding yet at https://${NC_DOMAIN}/status.php"
  warn "Check again in a few seconds or run: docker logs app-next-01"
}

# ─── [UPDATE] Detection and update on existing stack ────────────────────────

detect_existing_stack() {
  [[ -d "$INSTALL_DIR" ]] || return 1
  [[ -f "$INSTALL_DIR/docker-compose.yml" ]] || return 1
  local state
  state=$(docker inspect --format='{{.State.Status}}' haproxy 2>/dev/null || echo "absent")
  [[ "$state" == "running" ]]
}

_detect_node_count() {
  local filter="$1" pattern="$2"
  local n
  n=$(docker ps --filter "name=${filter}" --format "{{.Names}}" 2>/dev/null \
      | grep -E "${pattern}" | wc -l)
  (( n < 1 )) && n=1
  echo "$n"
}

update_images() {
  step "Updating NXT Maxscale stack"
  cd "$INSTALL_DIR"

  # Load nodes from cache or detect from containers
  if [[ -f "$ANSWERS_CACHE" ]]; then
    declare -gA RUSTFS_PATHS 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$ANSWERS_CACHE"
    info "Configuration reloaded (${NC_NODES} NC · ${MARIADB_NODES} DB · ${REDIS_NODES} Redis · ${COLLAB_NODES} Collab · ${RUSTFS_NODES} RustFS)"
  else
    warn "Cache missing — auto-detecting from running containers"
    NC_NODES=$(_detect_node_count     "app-next-"       "^app-next-[0-9]")
    MARIADB_NODES=$(_detect_node_count "mariadb-node"   "^mariadb-node[0-9]")
    REDIS_NODES=$(_detect_node_count   "redis-node"     "^redis-node[0-9]")
    COLLAB_NODES=$(_detect_node_count  "collabora-node" "^collabora-node[0-9]")
    WB_NODES=$(_detect_node_count      "whiteboard-node" "^whiteboard-node[0-9]")
    RUSTFS_NODES=$(_detect_node_count   "rustfs-node"     "^rustfs-node[0-9]")
    SIGNALING_NODES=$(_detect_node_count "spreed-signaling-" "^spreed-signaling-[0-9]")
    SIGNALING_NODES="${SIGNALING_NODES:-0}"
    TALK_ENABLED=$(grep -m1 '^TALK_ENABLED=' "$INSTALL_DIR/.env" | cut -d= -f2 || echo "no")
    TALK_ENABLED="${TALK_ENABLED:-no}"
    (( SIGNALING_NODES > 0 )) && TALK_ENABLED="yes"
    info "Detected nodes: NC=${NC_NODES} · DB=${MARIADB_NODES} · Redis=${REDIS_NODES} · Collab=${COLLAB_NODES} · WB=${WB_NODES} · RustFS=${RUSTFS_NODES} · Talk:${TALK_ENABLED}"
  fi

  step "Pulling new Docker images"
  start_spinner "Downloading images..."
  docker compose pull -q 2>/dev/null || true
  stop_spinner "Images downloaded"

  step "Recreating containers with updated images"
  start_spinner "Applying updates..."
  docker compose up -d 2>&1 | grep -E '^\s*(✔|✘|Recreated|Started|Error)' || true
  stop_spinner "Containers updated"

  # Re-apply patch if Collabora image changed (recreate = original binary restored)
  patch_collabora_binary

  wait_healthy

  local nc_url
  nc_url=$(grep -m1 '^NEXTCLOUD_DOMAIN=' "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "your-domain")
  info "Update complete ✓  →  https://${nc_url}"
}

# ─── [REDIS] Cluster operations (scale-up / scale-down) ─────────────────────

_redis_scale_up() {
  local new_count="$1" old_count="$2"
  local redis_pass
  redis_pass=$(grep -m1 '^REDIS_PASSWORD=' "$INSTALL_DIR/.env" | cut -d= -f2)
  [[ -z "$redis_pass" ]] && die "REDIS_PASSWORD not found in .env"

  local add_pairs=$(( (new_count - old_count) / 2 ))

  for i in $(seq $((old_count+1)) $new_count); do
    start_spinner "Waiting for redis-node${i}..."
    local elapsed=0
    while (( elapsed < 120 )); do
      docker exec redis-node1 redis-cli -h "redis-node${i}" \
        -a "$redis_pass" --no-auth-warning ping 2>/dev/null | grep -q PONG && break
      sleep 3; (( elapsed+=3 )) || true
    done
    stop_spinner "redis-node${i} ready"
  done

  for p in $(seq 1 $add_pairs); do
    local mi=$(( old_count + (p-1)*2 + 1 ))
    local ri=$(( old_count + (p-1)*2 + 2 ))
    step "Integrating: redis-node${mi} (master) + redis-node${ri} (replica)"

    docker exec redis-node1 redis-cli --cluster add-node \
      "redis-node${mi}:6379" "redis-node1:6379" \
      -a "$redis_pass" --no-auth-warning

    # Wait for the new master to be visible in cluster nodes before adding the replica
    local master_id="" wait_master=0
    while (( wait_master < 30 )); do
      master_id=$(docker exec "redis-node${mi}" redis-cli \
        -a "$redis_pass" --no-auth-warning cluster myid 2>/dev/null | tr -d '[:space:]')
      # Verify this node is seen as master by redis-node1
      if [[ -n "$master_id" ]] && docker exec redis-node1 redis-cli \
          -a "$redis_pass" --no-auth-warning cluster nodes 2>/dev/null \
          | grep -q "^${master_id}.*master"; then
        break
      fi
      sleep 2; (( wait_master += 2 )) || true
    done

    if [[ -z "$master_id" ]]; then
      warn "Cannot get master_id for redis-node${mi} — replica redis-node${ri} skipped"
      continue
    fi

    docker exec redis-node1 redis-cli --cluster add-node \
      "redis-node${ri}:6379" "redis-node1:6379" \
      -a "$redis_pass" --no-auth-warning \
      --cluster-slave --cluster-master-id "$master_id"

    # Verify the replica has joined the cluster
    sleep 3
    local replica_id
    replica_id=$(docker exec "redis-node${ri}" redis-cli \
      -a "$redis_pass" --no-auth-warning cluster myid 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$replica_id" ]] && ! docker exec redis-node1 redis-cli \
        -a "$redis_pass" --no-auth-warning cluster nodes 2>/dev/null \
        | grep -q "^${replica_id}"; then
      warn "redis-node${ri} not integrated via add-node — attempting MEET+REPLICATE"
      local ri_ip
      ri_ip=$(docker inspect "redis-node${ri}" \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)
      docker exec redis-node1 redis-cli \
        -a "$redis_pass" --no-auth-warning cluster meet "$ri_ip" 6379 2>/dev/null || true
      sleep 3
      docker exec "redis-node${ri}" redis-cli \
        -a "$redis_pass" --no-auth-warning cluster replicate "$master_id" 2>/dev/null || true
    fi
  done

  # Fix any open/migrating slots before rebalance
  docker exec redis-node1 redis-cli --cluster fix "redis-node1:6379" \
    -a "$redis_pass" --no-auth-warning 2>/dev/null || true
  sleep 3

  step "Rebalancing Redis slots across all masters"
  docker exec redis-node1 redis-cli --cluster rebalance "redis-node1:6379" \
    -a "$redis_pass" --no-auth-warning --cluster-use-empty-masters

  # Final check: all expected nodes are in the cluster
  local expected_nodes="$new_count"
  local known_nodes
  known_nodes=$(docker exec redis-node1 redis-cli \
    -a "$redis_pass" --no-auth-warning cluster info 2>/dev/null \
    | grep 'cluster_known_nodes' | cut -d: -f2 | tr -d '[:space:]')
  if [[ "$known_nodes" != "$expected_nodes" ]]; then
    warn "cluster_known_nodes=${known_nodes} ≠ expected=${expected_nodes} — verify manually"
  fi
  info "Redis: ${new_count} nodes ($((new_count/2)) masters + $((new_count/2)) replicas)"
}

_redis_scale_down() {
  local new_count="$1" old_count="$2"
  local redis_pass
  redis_pass=$(grep -m1 '^REDIS_PASSWORD=' "$INSTALL_DIR/.env" | cut -d= -f2)
  [[ -z "$redis_pass" ]] && die "REDIS_PASSWORD not found in .env"

  for n in $(seq $old_count -1 $((new_count + 1))); do
    local node_line
    node_line=$(docker exec "redis-node${n}" redis-cli \
      -a "$redis_pass" --no-auth-warning cluster nodes 2>/dev/null | grep myself || true)
    if [[ -z "$node_line" ]]; then
      warn "redis-node${n} unreachable — skipped"; continue
    fi

    local node_id; node_id=$(echo "$node_line" | cut -d' ' -f1)
    local node_flags; node_flags=$(echo "$node_line" | awk '{print $3}')

    if echo "$node_flags" | grep -q "master"; then
      local slot_count
      slot_count=$(echo "$node_line" | awk '{
        for(i=9;i<=NF;i++){
          n=split($i,a,"-")
          if(n==2 && a[1]~/^[0-9]+$/ && a[2]~/^[0-9]+$/) c+=a[2]-a[1]+1
        }
      } END{print c+0}')

      if (( slot_count > 0 )); then
        local target_id
        target_id=$(docker exec redis-node1 redis-cli \
          -a "$redis_pass" --no-auth-warning cluster nodes 2>/dev/null \
          | awk -v skip="$node_id" '!/myself/ && /master/ && $1!=skip {print $1; exit}')
        step "Migrating ${slot_count} slots from redis-node${n}"
        docker exec redis-node1 redis-cli --cluster reshard "redis-node1:6379" \
          -a "$redis_pass" --no-auth-warning \
          --cluster-from "$node_id" --cluster-to "$target_id" \
          --cluster-slots "$slot_count" --cluster-yes
      fi
    fi

    info "Removing redis-node${n} from cluster"
    docker exec redis-node1 redis-cli --cluster del-node \
      "redis-node1:6379" "$node_id" \
      -a "$redis_pass" --no-auth-warning
  done

  # Rebalance slots evenly after all removals
  step "Rebalancing Redis slots after scale-down"
  docker exec redis-node1 redis-cli --cluster fix "redis-node1:6379" \
    -a "$redis_pass" --no-auth-warning 2>/dev/null || true
  sleep 2
  docker exec redis-node1 redis-cli --cluster rebalance "redis-node1:6379" \
    -a "$redis_pass" --no-auth-warning 2>/dev/null || true
  info "Redis: ${new_count} nodes ($((new_count/2)) masters + $((new_count/2)) replicas)"
}

# ─── [RUSTFS] Registering a new pool ──────────────────────────────────────────

_rustfs_register_pool() {
  local old_count="$1" new_count="$2"
  local pools_file="$INSTALL_DIR/.rustfs-pools"
  local new_start=$(( old_count + 1 ))

  # Backward compatibility: create file if absent
  if [[ ! -f "$pools_file" ]]; then
    echo "1:${old_count}" > "$pools_file"
    info "RustFS pools file initialized (pool 1: nodes 1–${old_count})"
  fi

  # Dedup: do not register the same pool twice
  if grep -qF "${new_start}:${new_count}" "$pools_file" 2>/dev/null; then
    warn "RustFS pool ${new_start}:${new_count} already present in .rustfs-pools — duplicate ignored"
    return 0
  fi

  echo "${new_start}:${new_count}" >> "$pools_file"
  info "New RustFS pool registered: nodes ${new_start}–${new_count}"

  local n d
  for n in $(seq $new_start $new_count); do
    grep -q "^RUSTFS_NODE${n}_PATH=" "$INSTALL_DIR/.env" || \
      echo "RUSTFS_NODE${n}_PATH=${RUSTFS_PATHS[${n}_path]}" >> "$INSTALL_DIR/.env"
    for d in $(seq 1 "$RUSTFS_DISKS"); do
      grep -q "^RUSTFS_NODE${n}_DATA${d}=" "$INSTALL_DIR/.env" || \
        echo "RUSTFS_NODE${n}_DATA${d}=${RUSTFS_PATHS[${n}_${d}]}" >> "$INSTALL_DIR/.env"
    done
  done
  info "New RustFS node paths added to .env"
}

# ─── [SCALE] Modifying node count on existing stack ──────────────────────────

scale_nodes() {
  step "Scaling mode — modifying node counts"
  cd "$INSTALL_DIR"

  # ── Configuration loading ────────────────────────────────────────────────────
  declare -gA RUSTFS_PATHS 2>/dev/null || true

  if [[ -f "$ANSWERS_CACHE" ]]; then
    # shellcheck source=/dev/null
    source "$ANSWERS_CACHE"
    info "Configuration reloaded from cache"
    # Safety check: verify RUSTFS_NODES from cache matches actual containers
    # (prevents stale ORIG_RUSTFS_NODES → double call to _rustfs_register_pool)
    local _actual_rustfs
    _actual_rustfs=$(_detect_node_count "rustfs-node" "^rustfs-node[0-9]")
    if (( _actual_rustfs > RUSTFS_NODES )); then
      warn "RUSTFS_NODES cache (${RUSTFS_NODES}) < actual containers (${_actual_rustfs}) — correcting"
      RUSTFS_NODES="$_actual_rustfs"
    fi
  elif [[ -f "$INSTALL_DIR/.env" ]]; then
    warn "Cache missing — rebuilding from .env and running containers"
    NC_DOMAIN=$(grep    -m1 '^NEXTCLOUD_DOMAIN='    "$INSTALL_DIR/.env" | cut -d= -f2)
    COLLAB_DOMAIN=$(grep -m1 '^COLLABORA_DOMAIN='   "$INSTALL_DIR/.env" | cut -d= -f2)
    WB_DOMAIN=$(grep    -m1 '^WHITEBOARD_DOMAIN='   "$INSTALL_DIR/.env" | cut -d= -f2)
    TALK_DOMAIN=$(grep   -m1 '^TALK_DOMAIN='         "$INSTALL_DIR/.env" | cut -d= -f2 || echo "talk.${NC_DOMAIN#*.}")
    CERTBOT_EMAIL=$(grep -m1 '^CERTBOT_EMAIL='       "$INSTALL_DIR/.env" | cut -d= -f2 || echo "")
    NC_NODES=$(_detect_node_count     "app-next-"       "^app-next-[0-9]")
    MARIADB_NODES=$(_detect_node_count "mariadb-node"   "^mariadb-node[0-9]")
    REDIS_NODES=$(_detect_node_count   "redis-node"     "^redis-node[0-9]")
    COLLAB_NODES=$(_detect_node_count  "collabora-node" "^collabora-node[0-9]")
    WB_NODES=$(_detect_node_count      "whiteboard-node" "^whiteboard-node[0-9]")
    RUSTFS_NODES=$(_detect_node_count   "rustfs-node"     "^rustfs-node[0-9]")
    NC_VERSION=$(docker inspect --format='{{index .Config.Image}}' app-next-01 2>/dev/null \
                 | cut -d: -f2 || echo "latest-fpm")
    RUSTFS_DISKS="${RUSTFS_DISKS:-4}"
    RUSTFS_DISK_SIZE_GB=$(grep -m1 '^RUSTFS_DISK_SIZE_GB=' "$INSTALL_DIR/.env" | cut -d= -f2 || echo "0")
    RUSTFS_DISK_SIZE_GB="${RUSTFS_DISK_SIZE_GB:-0}"
    RUSTFS_MODE=$(grep -m1 '^RUSTFS_MODE=' "$INSTALL_DIR/.env" | cut -d= -f2 || echo "test")
    RUSTFS_MODE="${RUSTFS_MODE:-test}"
    RUSTFS_BYPASS=$(grep -m1 '^RUSTFS_BYPASS=' "$INSTALL_DIR/.env" | cut -d= -f2 || echo "true")
    RUSTFS_BYPASS="${RUSTFS_BYPASS:-true}"
    HAPROXY_STATS=$(grep -m1 '^HAPROXY_STATS=' "$INSTALL_DIR/.env" | cut -d= -f2 || echo "no")
    HAPROXY_STATS="${HAPROXY_STATS:-no}"
    RUSTFS_CONSOLE=$(grep -m1 '^RUSTFS_CONSOLE=' "$INSTALL_DIR/.env" | cut -d= -f2 || echo "no")
    RUSTFS_CONSOLE="${RUSTFS_CONSOLE:-no}"
    COTURN_ENABLED=$(grep -m1 '^COTURN_ENABLED=' "$INSTALL_DIR/.env" | cut -d= -f2 || echo "no")
    COTURN_ENABLED="${COTURN_ENABLED:-no}"
    TALK_ENABLED=$(grep -m1 '^TALK_ENABLED=' "$INSTALL_DIR/.env" | cut -d= -f2 || echo "no")
    TALK_ENABLED="${TALK_ENABLED:-no}"
    SIGNALING_NODES=$(grep -m1 '^SIGNALING_NODES=' "$INSTALL_DIR/.env" | cut -d= -f2 || echo "2")
    SIGNALING_NODES="${SIGNALING_NODES:-2}"
    CERTBOT_STAGING="${CERTBOT_STAGING:-no}"
    local n d
    for n in $(seq 1 "$RUSTFS_NODES"); do
      RUSTFS_PATHS["${n}_path"]=$(grep -m1 "^RUSTFS_NODE${n}_PATH=" "$INSTALL_DIR/.env" 2>/dev/null \
                                  | cut -d= -f2 || echo "/data/rustfs/node${n}")
      for d in $(seq 1 "$RUSTFS_DISKS"); do
        RUSTFS_PATHS["${n}_${d}"]=$(grep -m1 "^RUSTFS_NODE${n}_DATA${d}=" "$INSTALL_DIR/.env" 2>/dev/null \
                                    | cut -d= -f2 || echo "/data/rustfs/node${n}/data${d}")
      done
    done
    info "Configuration rebuilt: NC=${NC_NODES} · DB=${MARIADB_NODES} · Redis=${REDIS_NODES} · Collab=${COLLAB_NODES} · WB=${WB_NODES} · RustFS=${RUSTFS_NODES} · Signaling=${SIGNALING_NODES}"
  else
    die "Neither config cache nor .env file found in $INSTALL_DIR — cannot scale"
  fi

  # ── Display current configuration ───────────────────────────────────────────
  box "Current Nodes" \
    "Nextcloud FPM+nginx : ${NC_NODES} nodes" \
    "MariaDB Galera      : ${MARIADB_NODES} nodes  (odd number required)" \
    "Redis Cluster       : ${REDIS_NODES} nodes  (even ≥ 6, even delta)" \
    "Collabora           : ${COLLAB_NODES} nodes" \
    "Whiteboard          : ${WB_NODES} nodes" \
    "$( [[ "${TALK_ENABLED:-no}" == "yes" ]] \
        && echo "Talk signaling      : ${SIGNALING_NODES:-2} nodes  (stateless — scale up or down freely)" \
        || echo "Talk signaling      : disabled" )" \
    "RustFS               : ${RUSTFS_NODES} nodes × ${RUSTFS_DISKS} disks  (scale-up by pool)"
  echo ""

  # ── Enter new values ─────────────────────────────────────────────────────────
  local ORIG_NC_NODES="$NC_NODES"
  local ORIG_MARIADB_NODES="$MARIADB_NODES"
  local ORIG_REDIS_NODES="$REDIS_NODES"
  local ORIG_COLLAB_NODES="$COLLAB_NODES"
  local ORIG_WB_NODES="$WB_NODES"
  local ORIG_RUSTFS_NODES="$RUSTFS_NODES"
  local ORIG_SIGNALING_NODES="${SIGNALING_NODES:-2}"
  SIGNALING_NODES="$ORIG_SIGNALING_NODES"

  step "New node counts (Enter = keep current value)"
  ask_int "Nextcloud — FPM+nginx nodes"        "$NC_NODES"      is_positive_int "Integer ≥ 1 required"          NC_NODES
  ask_int "MariaDB Galera — nodes (odd)"        "$MARIADB_NODES" is_odd          "Odd number required (quorum)"  MARIADB_NODES
  ask_int "Redis Cluster — nodes (even ≥ 6)"   "$REDIS_NODES"   is_even_min6    "Even number ≥ 6 required"      REDIS_NODES
  ask_int "Collabora — nodes"                  "$COLLAB_NODES"  is_positive_int "Integer ≥ 1 required"          COLLAB_NODES
  ask_int "Whiteboard — nodes"                 "$WB_NODES"      is_positive_int "Integer ≥ 1 required"          WB_NODES
  if [[ "${TALK_ENABLED:-no}" == "yes" ]]; then
    ask_int "Talk signaling — nodes (↑↓ free)"   "$SIGNALING_NODES" is_positive_int "Integer ≥ 1 required"        SIGNALING_NODES
  fi

  # RustFS: scale-up only (pool expansion) — scale-down via manual decommission
  echo ""
  ask_int "RustFS — total nodes (≥ ${ORIG_RUSTFS_NODES}, ↑ only)" \
    "$RUSTFS_NODES" is_positive_int "Integer ≥ 1 required" RUSTFS_NODES
  if (( RUSTFS_NODES < ORIG_RUSTFS_NODES )); then
    warn "RustFS scale-down not supported — value reset to ${ORIG_RUSTFS_NODES}"
    warn "To reduce RustFS: decommission via RustFS admin tools (manual procedure)"
    RUSTFS_NODES="$ORIG_RUSTFS_NODES"
  fi

  # Validate that the Redis delta is even (master+replica per pair)
  local redis_delta=$(( REDIS_NODES - ORIG_REDIS_NODES ))
  if (( redis_delta != 0 && redis_delta % 2 != 0 )); then
    warn "Redis: delta must be even — value reset to ${ORIG_REDIS_NODES}"
    REDIS_NODES="$ORIG_REDIS_NODES"
    redis_delta=0
  fi

  # If RustFS scale-up: collect paths for new nodes NOW
  local rustfs_scaled_up=false
  if (( RUSTFS_NODES > ORIG_RUSTFS_NODES )); then
    rustfs_scaled_up=true
    local new_pool_start=$(( ORIG_RUSTFS_NODES + 1 ))
    step "New RustFS pool — nodes ${new_pool_start}–${RUSTFS_NODES}  (${RUSTFS_DISKS} disk(s) each)"
    warn "All existing RustFS nodes will restart with the new pool (~30s downtime)."
    warn "Data is preserved — only the server command changes."
    info "New nodes must use exactly ${RUSTFS_DISKS} disk(s) each (must match existing pool)"
    echo ""

    if [[ "$RUSTFS_MODE" == "auto" ]]; then
      # ── Disk wizard for new nodes ──────────────────────────────────────────
      _check_disk_tools
      _scan_available_disks

      if (( DISK_COUNT == 0 )); then
        warn "No candidate disk found — falling back to manual path entry"
        local n d
        for n in $(seq $new_pool_start $RUSTFS_NODES); do
          prompt_input "Node ${n} — metadata path" "/data/rustfs/node${n}"
          RUSTFS_PATHS["${n}_path"]="$REPLY"
          for d in $(seq 1 "$RUSTFS_DISKS"); do
            prompt_input "Node ${n} — Disk ${d}" "/data/rustfs/node${n}/data${d}"
            RUSTFS_PATHS["${n}_${d}"]="$REPLY"
          done
        done
      else
        info "${DISK_COUNT} disk(s)/partition(s) found"
        _show_disk_table
        echo -e "  ${C_BGREEN}Green${C_RESET} = already mounted   ${C_YELLOW}Yellow${C_RESET} = formatted   ${C_GRAY}Gray${C_RESET} = no filesystem"
        echo ""

        local preferred_fs="xfs"
        echo -e "  ${C_WHITE}Filesystem for unformatted disks?${C_RESET}"
        echo -e "  ${C_CYAN}[1]${C_RESET} XFS   ${C_GRAY}(recommended — optimal for object storage)${C_RESET}"
        echo -e "  ${C_CYAN}[2]${C_RESET} EXT4"
        echo ""
        prompt_input "Choice" "1"
        [[ "$REPLY" == "2" ]] && preferred_fs="ext4"
        info "Filesystem: ${preferred_fs^^}"
        echo ""

        local -a _selected_devs=()
        local n d ci
        for n in $(seq $new_pool_start $RUSTFS_NODES); do
          for d in $(seq 1 "$RUSTFS_DISKS"); do
            echo ""
            step "New node ${n} — Disk ${d}"
            _show_disk_table
            while true; do
              prompt_input "Select disk [1-${DISK_COUNT}]" ""
              if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= DISK_COUNT )); then
                ci=$(( REPLY - 1 ))
                if [[ " ${_selected_devs[*]} " == *" ${DISK_NAMES[$ci]} "* ]]; then
                  warn "${DISK_NAMES[$ci]} already assigned to another slot"
                  prompt_yn "Use anyway?" "N" || continue
                fi
                break
              fi
              error "Enter a number between 1 and ${DISK_COUNT}"
            done

            _selected_devs+=("${DISK_NAMES[$ci]}")
            local target_mount="/mnt/rustfs-node${n}-disk${d}"
            if [[ "${DISK_MOUNTS[$ci]}" != "-" && -n "${DISK_MOUNTS[$ci]}" ]]; then
              target_mount="${DISK_MOUNTS[$ci]}"
            fi

            _prepare_rustfs_disk \
              "${DISK_NAMES[$ci]}" "$target_mount" \
              "${DISK_FSTYPES[$ci]}" "$preferred_fs"

            # Refresh disk state so the table shows updated FS/mountpoint on next iteration
            _scan_available_disks

            RUSTFS_PATHS["${n}_${d}"]="$target_mount"
          done
          RUSTFS_PATHS["${n}_path"]="${RUSTFS_PATHS["${n}_1"]}"
        done
      fi

    else
      # ── Manual / test path entry ───────────────────────────────────────────
      if [[ "$RUSTFS_MODE" == "manual" ]]; then
        box "Reminder — ensure disks are ready before proceeding" \
          "Format : mkfs.xfs -f /dev/sdX  (or mkfs.ext4 -F /dev/sdX)" \
          "Mount  : mount -t xfs -o noatime,nodiratime,allocsize=64m /dev/sdX /mnt/..." \
          "fstab  : UUID=... /mnt/...  xfs  noatime,nodiratime,allocsize=64m,logbsize=256k  0 2"
        echo ""
      fi
      local n d
      for n in $(seq $new_pool_start $RUSTFS_NODES); do
        prompt_input "Node ${n} — metadata path" "/data/rustfs/node${n}"
        RUSTFS_PATHS["${n}_path"]="$REPLY"
        for d in $(seq 1 "$RUSTFS_DISKS"); do
          prompt_input "Node ${n} — Disk ${d}" "/data/rustfs/node${n}/data${d}"
          RUSTFS_PATHS["${n}_${d}"]="$REPLY"
        done
      done
    fi
  fi

  # ── Check for changes ────────────────────────────────────────────────────────
  local changed=false
  [[ "$NC_NODES"         != "$ORIG_NC_NODES"         ]] && changed=true
  [[ "$MARIADB_NODES"    != "$ORIG_MARIADB_NODES"    ]] && changed=true
  [[ "$REDIS_NODES"      != "$ORIG_REDIS_NODES"      ]] && changed=true
  [[ "$COLLAB_NODES"     != "$ORIG_COLLAB_NODES"     ]] && changed=true
  [[ "$WB_NODES"         != "$ORIG_WB_NODES"         ]] && changed=true
  [[ "$SIGNALING_NODES"  != "$ORIG_SIGNALING_NODES"  ]] && changed=true
  $rustfs_scaled_up && changed=true

  if ! $changed; then
    info "No changes requested — operation cancelled"
    return 0
  fi

  # ── Summary and confirmations ────────────────────────────────────────────────
  box "Planned changes" \
    "Nextcloud  : ${ORIG_NC_NODES} → ${NC_NODES} nodes" \
    "Galera     : ${ORIG_MARIADB_NODES} → ${MARIADB_NODES} nodes" \
    "Redis      : ${ORIG_REDIS_NODES} → ${REDIS_NODES} nodes" \
    "Collabora  : ${ORIG_COLLAB_NODES} → ${COLLAB_NODES} nodes" \
    "Whiteboard : ${ORIG_WB_NODES} → ${WB_NODES} nodes" \
    "$( [[ "${TALK_ENABLED:-no}" == "yes" ]] \
        && echo "Signaling  : ${ORIG_SIGNALING_NODES} → ${SIGNALING_NODES} nodes" \
        || echo "Signaling  : disabled" )" \
    "RustFS      : ${ORIG_RUSTFS_NODES} → ${RUSTFS_NODES} nodes"

  if (( MARIADB_NODES > ORIG_MARIADB_NODES )); then
    info "Galera: new nodes will join the cluster via SST (automatic)."
  elif (( MARIADB_NODES < ORIG_MARIADB_NODES )); then
    warn "⚠  Galera reduction: data replicated on all nodes — no loss if quorum maintained."
    prompt_yn "Confirm Galera cluster reduction?" "N" || { info "Cancelled"; return 0; }
  fi

  if (( REDIS_NODES > ORIG_REDIS_NODES )); then
    info "Redis scale-up: $((redis_delta/2)) master+replica pair(s) — slots redistributed automatically."
  elif (( REDIS_NODES < ORIG_REDIS_NODES )); then
    warn "⚠  Redis scale-down: slots migrated before removal — no data loss."
    warn "   Duration varies depending on cached data volume."
    prompt_yn "Confirm Redis cluster reduction?" "N" || { info "Cancelled"; return 0; }
  fi

  prompt_yn "Apply these changes?" "Y" || { info "Cancelled"; return 0; }

  # ── APPLICATION ───────────────────────────────────────────────────────────────

  # Step 1: Redis scale-DOWN — migrate slots BEFORE any compose change
  if (( REDIS_NODES < ORIG_REDIS_NODES )); then
    step "Redis scale-down: migrating slots and removing nodes"
    _redis_scale_down "$REDIS_NODES" "$ORIG_REDIS_NODES"
  fi

  # Step 2: RustFS pool expansion — register BEFORE gen_compose
  if $rustfs_scaled_up; then
    _rustfs_register_pool "$ORIG_RUSTFS_NODES" "$RUSTFS_NODES"

    if [[ "$RUSTFS_MODE" == "auto" ]]; then
      # Wizard already formatted, mounted and configured fstab — verify only
      step "Verifying new RustFS node mount points"
      local n d
      for n in $(seq $(( ORIG_RUSTFS_NODES + 1 )) $RUSTFS_NODES); do
        for d in $(seq 1 "$RUSTFS_DISKS"); do
          local path="${RUSTFS_PATHS[${n}_${d}]}"
          if mountpoint -q "$path" 2>/dev/null; then
            info "Node ${n} disk ${d}: $path ✓ (mounted)"
          else
            warn "Node ${n} disk ${d}: $path is not a mount point — RustFS may fail to start"
          fi
        done
      done
    else
      # Test / manual mode: create directories and clear them for RustFS
      # (RustFS refuses to start if data dirs contain unexpected files)
      step "Creating RustFS directories (new nodes)"
      local n d
      for n in $(seq $(( ORIG_RUSTFS_NODES + 1 )) $RUSTFS_NODES); do
        for d in $(seq 1 "$RUSTFS_DISKS"); do
          local path="${RUSTFS_PATHS[${n}_${d}]}"
          mkdir -p "$path"
          find "${path:?}" -mindepth 1 -delete 2>/dev/null || true
        done
      done
    fi
  fi

  # Step 3: Generate config files (without .env — passwords preserved)
  save_answers
  gen_compose
  gen_galera_cnf
  patch_haproxy
  patch_nextcloud_init

  # Step 4: Start / stop containers
  step "Applying scaling (new containers started, orphans removed)"
  start_spinner "docker compose up -d --remove-orphans..."
  docker compose up -d --remove-orphans 2>&1 \
    | grep -E '^\s*(✔|✘|Created|Started|Removed|Error)' || true
  stop_spinner "Containers updated"

  # Step 5: Restart HAProxy to apply new backends
  step "Restarting HAProxy"
  docker compose restart haproxy 2>/dev/null || true
  info "HAProxy restarted (new backends active immediately)"

  # Step 6: Redis scale-UP — integrate new nodes into the cluster
  if (( REDIS_NODES > ORIG_REDIS_NODES )); then
    step "Redis scale-up: integrating new nodes into the cluster"
    _redis_scale_up "$REDIS_NODES" "$ORIG_REDIS_NODES"
  fi

  # Step 7: Collabora binary patch on new nodes (scale-up only)
  # Pass (ORIG_COLLAB_NODES + 1) to extract from a new node (unpatched binary)
  # rather than from node1 which is already patched since initial deployment.
  if (( COLLAB_NODES > ORIG_COLLAB_NODES )); then
    patch_collabora_binary $(( ORIG_COLLAB_NODES + 1 ))
  fi

  wait_healthy

  box "Scaling complete ✓" \
    "Nextcloud  : ${NC_NODES} FPM nodes + ${NC_NODES} nginx" \
    "Galera     : ${MARIADB_NODES} nodes" \
    "Redis      : ${REDIS_NODES} nodes ($((REDIS_NODES/2)) masters + $((REDIS_NODES/2)) replicas)" \
    "Collabora  : ${COLLAB_NODES} nodes" \
    "Whiteboard : ${WB_NODES} nodes" \
    "$( [[ "${TALK_ENABLED:-no}" == "yes" ]] && echo "Signaling  : ${SIGNALING_NODES} nodes" || echo "Signaling  : disabled" )" \
    "RustFS      : ${RUSTFS_NODES} nodes × ${RUSTFS_DISKS} disks"
}

# ─── [MAIN] Entry point ──────────────────────────────────────────────────────

main() {
  show_banner
  setup_logging

  # Detect existing stack → offer update / scaling / full redeployment
  if detect_existing_stack; then
    box "Existing stack detected" \
      "An NXT Maxscale stack is running in ${INSTALL_DIR}." \
      "" \
      "→ [1] Quick update    : pull images + Collabora patch (configuration preserved)" \
      "→ [2] Scale nodes     : increase/decrease nodes without reinitialization" \
      "→ [3] Full deployment : regenerates all files (⚠  starts from scratch)"
    echo ""
    echo -e "  ${C_WHITE}[1]${C_RESET} Quick update ${C_GRAY}(recommended)${C_RESET}"
    echo -e "  ${C_WHITE}[2]${C_RESET} Scale up / down nodes"
    echo -e "  ${C_WHITE}[3]${C_RESET} Full deployment ${C_GRAY}(starts from scratch)${C_RESET}"
    echo ""
    local stack_choice
    while true; do
      prompt_input "Your choice" "1"
      stack_choice="$REPLY"
      [[ "$stack_choice" =~ ^[123]$ ]] && break
      error "Enter 1, 2 or 3"
    done
    case "$stack_choice" in
      1)
        update_images
        return 0
        ;;
      2)
        scale_nodes
        return 0
        ;;
      3)
        info "Full deployment selected"
        echo ""
        ;;
    esac
  fi

  # Phase 1-2: System
  detect_os
  install_deps
  check_requirements

  # Phase 3: Clone
  clone_repo

  # Phase 4: Interactive configuration
  if ! load_answers; then
    ask_domains
    ask_versions
    ask_nodes
    ask_rustfs
    ask_haproxy
    ask_rustfs_console
    ask_talk
    ask_cert_mode
  fi
  show_recap
  save_answers

  # Phase 5: File generation
  gen_passwords
  gen_env
  gen_compose
  [[ "${TALK_ENABLED:-no}" == "yes" ]] && gen_signaling_conf
  gen_galera_cnf
  patch_haproxy
  patch_nextcloud_init
  create_rustfs_dirs

  # Phase 6: Deployment
  gen_certs
  run_deploy
  patch_collabora_binary

  # Phase 7: Verification
  wait_healthy
  reset_bruteforce
  configure_talk
  configure_notify_push
  check_services
  final_check
  show_summary
}

[[ $_SOURCE_ONLY -eq 0 ]] && main "$@" || true
