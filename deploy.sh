#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Azure NXT Maxscale — Déployeur automatique v1.0
# Usage : sudo bash deploy.sh
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# Guard : _SOURCE_ONLY=1 doit être défini AVANT de sourcer ce fichier (tests).
# Par défaut 0 — fonctionne dans tous les contextes (bash -c, curl|bash, fichier).
: "${_SOURCE_ONLY:=0}"

INSTALL_DIR="/opt/nxt-maxscale"
REPO_URL="https://github.com/oboeglen/Azure-NXT-Maxscale"
ANSWERS_CACHE="/tmp/.nxt-maxscale-config.env"
LOG_FILE="/var/log/nxt-maxscale-deploy.log"
CERTBOT_STAGING="no"

# ─── Couleurs ────────────────────────────────────────────────────────────────
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

phase() {
  local n="$1" total="$2" name="$3"
  # Box width = 58 chars total (╔ + 56×═ + ╗)
  # Content: ║(1) + "  PHASE n/t — "(14) + %-42s(42) + ║(1) = 58 ✓
  echo ""
  echo -e "${C_BCYAN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
  printf "${C_BCYAN}║  PHASE %s/%s — %-42s║${C_RESET}\n" "$n" "$total" "$name"
  echo -e "${C_BCYAN}╚══════════════════════════════════════════════════════════╝${C_RESET}"
}

box() {
  local title="$1"; shift
  # TOTAL = 66 chars: ┌(1)+─(1)+space(1)+title+space(1)+─×dashes+┐(1) = 66
  # Content: │(1)+space(2)+%-62s(62)+│(1) = 66
  # Bottom:  └(1)+─×64+┘(1) = 66
  local TOTAL=66
  local inner=$(( TOTAL - 4 ))
  local titlelen=${#title}
  local dashes=$(( TOTAL - titlelen - 5 ))
  printf "\n${C_CYAN}┌─ %s " "$title"
  printf '─%.0s' $(seq 1 $dashes)
  printf "┐${C_RESET}\n"
  for line in "$@"; do
    printf "${C_CYAN}│${C_RESET}  %-${inner}s${C_CYAN}│${C_RESET}\n" "$line"
  done
  printf "${C_CYAN}└"
  printf '─%.0s' $(seq 1 $(( TOTAL - 2 )))
  printf "┘${C_RESET}\n"
}

setup_logging() {
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/nxt-maxscale-deploy.log"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  # Dupliquer stdout+stderr vers le log sans perturber l'affichage
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "Journal : $LOG_FILE"
}

check_requirements() {
  step "Vérification des prérequis système"

  # RAM
  local ram_kb ram_gb
  ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  ram_gb=$(( ram_kb / 1024 / 1024 ))
  if (( ram_kb < 14680064 )); then
    warn "RAM : ${ram_gb} Go détectés (minimum recommandé : 16 Go)"
    prompt_yn "Continuer quand même ?" "N" || die "Annulé — ajoutez de la RAM puis relancez."
  else
    info "RAM : ${ram_gb} Go ✓"
  fi

  # Disque
  local disk_kb disk_gb
  disk_kb=$(df -k "$(dirname "$INSTALL_DIR")" 2>/dev/null | awk 'NR==2{print $4}' || df -k / | awk 'NR==2{print $4}')
  disk_gb=$(( disk_kb / 1024 / 1024 ))
  if (( disk_kb < 52428800 )); then
    warn "Espace libre : ${disk_gb} Go (minimum recommandé : 50 Go)"
    prompt_yn "Continuer quand même ?" "N" || die "Annulé — libérez de l'espace disque puis relancez."
  else
    info "Disque : ${disk_gb} Go disponibles ✓"
  fi

  # Version Docker
  local docker_ver
  docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null | grep -oE '^[0-9]+' || echo "0")
  if (( docker_ver < 20 )); then
    die "Docker ${docker_ver} trop ancien — version ≥ 20 requise. Relancez le script pour le mettre à jour."
  fi
  info "Docker ${docker_ver} ✓"

  # Docker Compose v2
  local compose_maj
  compose_maj=$(docker compose version --short 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")
  if (( compose_maj < 2 )); then
    die "Docker Compose v${compose_maj} trop ancien — version ≥ 2 requise."
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
  echo -e "${C_BCYAN}"
  cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════════╗
  ║    █████╗ ███████╗██╗   ██╗██████╗ ███████╗                 ║
  ║   ██╔══██╗╚══███╔╝██║   ██║██╔══██╗██╔════╝                 ║
  ║   ███████║  ███╔╝ ██║   ██║██████╔╝█████╗                   ║
  ║   ██╔══██║ ███╔╝  ██║   ██║██╔══██╗██╔══╝                   ║
  ║   ██║  ██║███████╗╚██████╔╝██║  ██║███████╗                 ║
  ║        NXT Maxscale — Déployeur automatique v1.0             ║
  ╚══════════════════════════════════════════════════════════════╝
BANNER
  echo -e "${C_RESET}"
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
  [[ "${default^^}" == "Y" ]] && hint="O/n" || hint="o/N"
  printf "  ${C_WHITE}%s${C_RESET} ${C_GRAY}[%s]${C_RESET} : " "$question" "$hint"
  read -r REPLY
  [[ -z "$REPLY" ]] && REPLY="$default"
  [[ "${REPLY,,}" == "o" || "${REPLY,,}" == "y" ]]
}

# ─── [OS] Détection et installation ──────────────────────────────────────────

# Internal: pure logic, testable without /etc/os-release
# Args: $1=ID $2=ID_LIKE $3=VERSION_ID
# Sets globals: OS_ID, OS_VERSION, PKG_MGR
# Echoes the detected OS_ID
_detect_os_logic() {
  local id="$1" id_like="${2:-}" version="$3"
  OS_ID=""; OS_VERSION="$version"; PKG_MGR=""

  case "$id" in
    debian)
      [[ "$version" =~ ^(11|12|13)$ ]] || die "Debian $version non supporté (11, 12 ou 13 requis)"
      OS_ID="debian"; PKG_MGR="apt"
      ;;
    ubuntu)
      [[ "$version" =~ ^(22\.04|24\.04)$ ]] || die "Ubuntu $version non supporté (22.04 ou 24.04 requis)"
      OS_ID="ubuntu"; PKG_MGR="apt"
      ;;
    rhel|centos|rocky|almalinux)
      [[ "$version" =~ ^[89] ]] || die "RHEL/Rocky/Alma $version non supporté (8.x ou 9.x requis)"
      OS_ID="rhel"; PKG_MGR="dnf"
      ;;
    *)
      if echo "$id_like" | grep -qE "rhel|fedora"; then
        [[ "$version" =~ ^[89] ]] || die "RHEL-like $version non supporté (8.x ou 9.x requis)"
        OS_ID="rhel"; PKG_MGR="dnf"
      else
        die "OS '$id' non supporté. Distributions acceptées : Debian 11/12/13, Ubuntu 22.04/24.04, RHEL/Rocky/AlmaLinux 8/9"
      fi
      ;;
  esac
  echo "$OS_ID"
}

detect_os() {
  phase 1 7 "Détection du système"
  [[ -f /etc/os-release ]] || die "/etc/os-release introuvable — OS non détectable"

  local ID="" ID_LIKE="" VERSION_ID=""
  # shellcheck source=/dev/null
  source /etc/os-release
  _detect_os_logic "$ID" "${ID_LIKE:-}" "$VERSION_ID" > /dev/null

  info "Système détecté : ${OS_ID} ${OS_VERSION} (gestionnaire : ${PKG_MGR})"
  [[ "$(uname -m)" == "x86_64" ]] || die "Architecture x86_64 requise (détecté: $(uname -m))"
  [[ $EUID -eq 0 ]] || die "Ce script doit être exécuté en root : sudo bash deploy.sh"
}

install_deps() {
  phase 2 7 "Installation des dépendances"

  local pkgs_apt=(git curl wget openssl python3 ca-certificates gnupg lsb-release netcat-openbsd)
  local pkgs_dnf=(git curl wget openssl python3 ca-certificates gnupg2)

  step "Mise à jour des sources et installation des paquets essentiels"
  start_spinner "Mise à jour des paquets..."
  if [[ "$PKG_MGR" == "apt" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    stop_spinner "Sources mises à jour"
    start_spinner "Installation des paquets essentiels..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs_apt[@]}"
  else
    dnf makecache -q
    stop_spinner "Sources mises à jour"
    start_spinner "Installation des paquets essentiels..."
    dnf install -y -q "${pkgs_dnf[@]}"
  fi
  stop_spinner "Paquets essentiels installés"

  # Docker Engine
  if ! command -v docker &>/dev/null; then
    step "Installation de Docker Engine"
    start_spinner "Téléchargement du script d'installation Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    stop_spinner "Script Docker téléchargé"
    start_spinner "Installation de Docker (peut prendre quelques minutes)..."
    bash /tmp/get-docker.sh -q
    stop_spinner "Docker installé"
    systemctl enable --now docker
  else
    info "Docker $(docker --version | cut -d' ' -f3 | tr -d ',') déjà installé"
  fi

  # Docker Compose plugin
  if ! docker compose version &>/dev/null 2>&1; then
    step "Installation du plugin Docker Compose"
    local os_name compose_arch
    os_name=$(uname -s)
    compose_arch=$(uname -m)
    local compose_url="https://github.com/docker/compose/releases/latest/download/docker-compose-${os_name}-${compose_arch}"
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL "$compose_url" -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    info "Docker Compose $(docker compose version --short) installé"
  else
    info "Docker Compose $(docker compose version --short) déjà installé"
  fi

  # Vérifier accès docker pour l'utilisateur non-root
  local real_user="${SUDO_USER:-}"
  if [[ -n "$real_user" ]] && ! groups "$real_user" | grep -q docker; then
    usermod -aG docker "$real_user" 2>/dev/null || true
    warn "L'utilisateur '$real_user' a été ajouté au groupe docker — reconnectez-vous pour que ça prenne effet"
  fi
}

# ─── [CLONE] Récupération du projet ──────────────────────────────────────────

clone_repo() {
  phase 3 7 "Récupération du projet"

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    warn "Le répertoire $INSTALL_DIR existe déjà"
    if prompt_yn "Mettre à jour le repo (git pull) ?" "Y"; then
      start_spinner "Mise à jour du repo..."
      git -C "$INSTALL_DIR" fetch origin
      git -C "$INSTALL_DIR" reset --hard origin/main
      stop_spinner "Repo mis à jour"
    else
      info "Utilisation du repo existant"
    fi
  else
    start_spinner "Clonage depuis $REPO_URL..."
    git clone --depth=1 "$REPO_URL" "$INSTALL_DIR"
    stop_spinner "Projet cloné dans $INSTALL_DIR"
  fi

  cd "$INSTALL_DIR"
  info "Répertoire de travail : $INSTALL_DIR"
}

# ─── [CONFIG] Questions utilisateur ──────────────────────────────────────────

# --- Validation helpers ---
validate_domain() {
  local d="$1"
  [[ "$d" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}$ ]]
}

is_positive_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_odd()          { is_positive_int "$1" && (( $1 % 2 == 1 )); }
is_even_min6()    { is_positive_int "$1" && (( $1 % 2 == 0 )) && (( $1 >= 6 )); }

# ask_int "question" "default" validator_fn "error message" VARNAME
# Stocke le résultat dans VARNAME (pas de subshell, pas de capture stdout)
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
    warn "DNS : $domain ne résout pas encore"
    if ! prompt_yn "Continuer quand même ?" "N"; then
      die "Annulé — configurez votre DNS puis relancez"
    fi
  else
    info "DNS $domain → OK"
  fi
}

# --- ask_domains ---
ask_domains() {
  step "Domaines et email"

  while true; do
    prompt_input "Domaine Nextcloud" "nextcloud.exemple.tld"
    NC_DOMAIN="$REPLY"
    validate_domain "$NC_DOMAIN" && break
    error "Format invalide (ex: nextcloud.mon-site.fr)"
  done

  while true; do
    prompt_input "Domaine Collabora" "collabora.exemple.tld"
    COLLAB_DOMAIN="$REPLY"
    validate_domain "$COLLAB_DOMAIN" && break
    error "Format invalide"
  done

  while true; do
    prompt_input "Domaine Whiteboard" "whiteboard.exemple.tld"
    WB_DOMAIN="$REPLY"
    validate_domain "$WB_DOMAIN" && break
    error "Format invalide"
  done

  while true; do
    prompt_input "Email Let's Encrypt" "admin@exemple.tld"
    CERTBOT_EMAIL="$REPLY"
    [[ "$CERTBOT_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] && break
    error "Email invalide"
  done

  step "Vérification DNS"
  check_dns_warn "$NC_DOMAIN"
  check_dns_warn "$COLLAB_DOMAIN"
  check_dns_warn "$WB_DOMAIN"
}

# --- ask_versions ---
ask_versions() {
  step "Version Nextcloud"
  prompt_input "Version Nextcloud" "33.0.3-fpm"
  NC_VERSION="$REPLY"
  [[ "$NC_VERSION" == *"-fpm" ]] || NC_VERSION="${NC_VERSION}-fpm"
  info "Image : nextcloud:${NC_VERSION}"
}

# --- ask_nodes ---
ask_nodes() {
  phase 4 7 "Configuration"
  step "Nombre de nœuds par service"

  ask_int "Nextcloud — nœuds FPM+nginx  (1 nœud = 1 container FPM + 1 nginx)" "3" is_positive_int "Entier ≥ 1 requis" NC_NODES
  ask_int "MariaDB Galera — nœuds"     "3" is_odd          "Nombre impair requis (quorum Galera — évite le split-brain)" MARIADB_NODES
  ask_int "Redis Cluster — nœuds"      "6" is_even_min6    "Nombre pair ≥ 6 requis (masters + replicas)"                 REDIS_NODES
  ask_int "Collabora — nœuds"          "3" is_positive_int "Entier ≥ 1 requis"                                           COLLAB_NODES
  ask_int "Whiteboard — nœuds"         "2" is_positive_int "Entier ≥ 1 requis"                                           WB_NODES
  ask_int "MinIO — nœuds"             "4" is_positive_int "Entier ≥ 1 requis"                                           MINIO_NODES
  ask_int "MinIO — disques par nœud"  "4" is_positive_int "Entier ≥ 1 requis"                                           MINIO_DISKS
}

# --- ask_minio ---
minio_fault_tolerance() {
  local nodes="$1" disks="$2"
  local total=$(( nodes * disks ))
  local tol_read=$(( total / 2 ))
  local tol_write=$(( total / 2 - 1 ))
  echo "Configuration : ${nodes} nœuds × ${disks} disques = ${total} drives"
  echo "Erasure coding : $((total/2)) données + $((total/2)) parité"
  echo "→ Perte jusqu'à ${tol_read} drives tolérée en lecture"
  echo "→ Perte jusqu'à ${tol_write} drives tolérée en écriture"
  if (( nodes >= 2 )); then
    echo "→ Perte d'un nœud entier (${disks} drives) : service maintenu"
  else
    echo "→ Nœud unique : aucune tolérance nœud (mode test uniquement)"
  fi
}

ask_minio() {
  step "Configuration des disques MinIO (${MINIO_NODES} nœuds × ${MINIO_DISKS} disques)"
  declare -gA MINIO_PATHS

  echo ""
  echo -e "  ${C_WHITE}Comment configurer les disques MinIO ?${C_RESET}"
  echo -e "  ${C_CYAN}[1]${C_RESET} Test mono-serveur  — /data/minio/ (répertoires créés automatiquement)"
  echo -e "  ${C_CYAN}[2]${C_RESET} Chemins manuels    — je saisis chaque chemin"
  echo -e "  ${C_CYAN}[3]${C_RESET} Détection auto     — scanner les disques montés"
  echo ""

  local choice
  while true; do
    prompt_input "Choix" "1"
    choice="$REPLY"
    [[ "$choice" =~ ^[123]$ ]] && break
    error "Entrez 1, 2 ou 3"
  done

  MINIO_MODE="test"
  case "$choice" in
    1)
      MINIO_MODE="test"
      local n d
      for n in $(seq 1 "$MINIO_NODES"); do
        MINIO_PATHS["${n}_path"]="/data/minio/node${n}"
        for d in $(seq 1 "$MINIO_DISKS"); do
          MINIO_PATHS["${n}_${d}"]="/data/minio/node${n}/data${d}"
        done
      done
      ;;
    2)
      MINIO_MODE="manual"
      local n d
      for n in $(seq 1 "$MINIO_NODES"); do
        prompt_input "Nœud ${n} — chemin métadonnées" "/data/minio/node${n}"
        MINIO_PATHS["${n}_path"]="$REPLY"
        for d in $(seq 1 "$MINIO_DISKS"); do
          prompt_input "Nœud ${n} — Disque ${d}" "/mnt/node${n}-disk${d}"
          MINIO_PATHS["${n}_${d}"]="$REPLY"
        done
      done
      ;;
    3)
      MINIO_MODE="auto"
      step "Disques disponibles détectés"
      df -h --output=source,target,size 2>/dev/null \
        | grep -vE '^(tmpfs|udev|/dev/loop|Filesystem|/dev/sr)' \
        | grep -v ' /$' | grep -v '/boot' \
        | tail -n +2 | nl -ba
      echo ""
      warn "Saisissez les chemins à partir des points de montage ci-dessus"
      local n d
      for n in $(seq 1 "$MINIO_NODES"); do
        prompt_input "Nœud ${n} — chemin métadonnées" "/data/minio/node${n}"
        MINIO_PATHS["${n}_path"]="$REPLY"
        for d in $(seq 1 "$MINIO_DISKS"); do
          prompt_input "Nœud ${n} — Disque ${d}" ""
          MINIO_PATHS["${n}_${d}"]="$REPLY"
        done
      done
      ;;
  esac

  MINIO_BYPASS="false"
  [[ "$MINIO_MODE" == "test" ]] && MINIO_BYPASS="true"

  echo ""
  local ft_lines
  mapfile -t ft_lines < <(minio_fault_tolerance "$MINIO_NODES" "$MINIO_DISKS")
  box "Tolérance aux pannes MinIO" "${ft_lines[@]}"
}

# --- ask_haproxy ---
ask_haproxy() {
  step "Page de statistiques HAProxy (accessible via https://DOMAINE/stats)"
  if prompt_yn "Activer les stats HAProxy ?" "N"; then
    HAPROXY_STATS="yes"
    info "Stats activées — mot de passe généré automatiquement"
  else
    HAPROXY_STATS="no"
    info "Stats désactivées"
  fi
}

# --- show_recap ---
show_recap() {
  echo ""
  box "Récapitulatif de votre configuration" \
    "Nextcloud      : $NC_DOMAIN  (${NC_NODES} nœuds FPM + ${NC_NODES} nginx, v${NC_VERSION})" \
    "Collabora      : $COLLAB_DOMAIN  (${COLLAB_NODES} nœuds)" \
    "Whiteboard     : $WB_DOMAIN  (${WB_NODES} nœuds)" \
    "Email SSL      : $CERTBOT_EMAIL" \
    "MariaDB Galera : ${MARIADB_NODES} nœuds" \
    "Redis Cluster  : ${REDIS_NODES} nœuds" \
    "MinIO         : ${MINIO_NODES} nœuds × ${MINIO_DISKS} disques (mode: ${MINIO_MODE})" \
    "Stats HAProxy  : ${HAPROXY_STATS}"

  echo ""
  prompt_yn "Confirmer et lancer la génération ?" "Y" || die "Annulé par l'utilisateur"
}

# --- ask_cert_mode ---
ask_cert_mode() {
  step "Environnement des certificats SSL"
  echo ""
  echo -e "  ${C_WHITE}[1]${C_RESET} ${C_BGREEN}Production${C_RESET}  — Let's Encrypt réel (domaines DNS valides requis)"
  echo -e "  ${C_WHITE}[2]${C_RESET} ${C_YELLOW}Staging/Test${C_RESET} — Let's Encrypt staging (sans limite de taux, certificats non fiables)"
  echo ""
  local choice
  prompt_input "Votre choix" "1"
  choice="$REPLY"
  if [[ "$choice" == "2" ]]; then
    CERTBOT_STAGING="yes"
    warn "Mode STAGING activé — les certificats ne seront pas reconnus par les navigateurs"
    warn "Utilisez ce mode uniquement pour tester l'infrastructure, jamais en production"
  else
    CERTBOT_STAGING="no"
    info "Mode Production — certificats Let's Encrypt réels"
  fi
}

# --- save_answers / load_answers ---
save_answers() {
  {
    echo "# NXT Maxscale — Config sauvegardée le $(date '+%Y-%m-%d %H:%M:%S')"
    printf 'NC_DOMAIN="%s"\n'     "$NC_DOMAIN"
    printf 'COLLAB_DOMAIN="%s"\n' "$COLLAB_DOMAIN"
    printf 'WB_DOMAIN="%s"\n'     "$WB_DOMAIN"
    printf 'CERTBOT_EMAIL="%s"\n' "$CERTBOT_EMAIL"
    printf 'NC_VERSION="%s"\n'    "$NC_VERSION"
    printf 'NC_NODES="%s"\n'      "$NC_NODES"
    printf 'MARIADB_NODES="%s"\n' "$MARIADB_NODES"
    printf 'REDIS_NODES="%s"\n'   "$REDIS_NODES"
    printf 'COLLAB_NODES="%s"\n'  "$COLLAB_NODES"
    printf 'WB_NODES="%s"\n'      "$WB_NODES"
    printf 'MINIO_NODES="%s"\n'  "$MINIO_NODES"
    printf 'MINIO_DISKS="%s"\n'  "$MINIO_DISKS"
    printf 'MINIO_MODE="%s"\n'   "$MINIO_MODE"
    printf 'MINIO_BYPASS="%s"\n' "$MINIO_BYPASS"
    printf 'HAPROXY_STATS="%s"\n' "$HAPROXY_STATS"
    printf 'CERTBOT_STAGING="%s"\n' "$CERTBOT_STAGING"
    declare -p MINIO_PATHS | sed 's/^declare -A/declare -gA/'
  } > "$ANSWERS_CACHE"
  chmod 600 "$ANSWERS_CACHE"
}

load_answers() {
  [[ -f "$ANSWERS_CACHE" ]] || return 1
  local saved_date
  saved_date=$(grep '^#' "$ANSWERS_CACHE" | head -1 | sed 's/# NXT Maxscale — Config sauvegardée le //')
  echo ""
  warn "Configuration précédente trouvée (${saved_date}) :"
  grep -v '^#\|^declare' "$ANSWERS_CACHE" | while IFS= read -r line; do
    printf "  ${C_GRAY}%s${C_RESET}\n" "$line"
  done
  echo ""
  prompt_yn "Réutiliser cette configuration ?" "Y" || return 1
  declare -gA MINIO_PATHS 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$ANSWERS_CACHE"
  info "Configuration rechargée."
  return 0
}

# ─── [GENERATE] Génération des fichiers ──────────────────────────────────────

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
  phase 5 7 "Génération des mots de passe"
  start_spinner "Génération des secrets cryptographiques..."

  GEN_NC_ADMIN_PASS=$(gen_pass 18 "base64")
  GEN_DB_ROOT_PASS=$(gen_pass 18 "base64")
  GEN_DB_PASS=$(gen_pass 18 "base64")
  GEN_REDIS_PASS=$(gen_pass 32 "hex")
  GEN_REDIS_WB_PASS=$(gen_pass 32 "hex")
  GEN_MINIO_KEY=$(gen_pass 16 "hex")
  GEN_MINIO_SECRET=$(gen_pass 24 "base64")
  GEN_JWT_SECRET=$(gen_pass 36 "base64")
  if [[ "$HAPROXY_STATS" == "yes" ]]; then
    GEN_HAPROXY_STATS_PASS=$(gen_pass 12 "base64")
  else
    GEN_HAPROXY_STATS_PASS="disabled"
  fi

  stop_spinner "Mots de passe générés"
}

gen_env() {
  local dest="${1:-$INSTALL_DIR/.env}"
  step "Génération du fichier .env"

  # Build MinIO path lines dynamically
  local minio_lines="" n d
  for n in $(seq 1 "$MINIO_NODES"); do
    minio_lines+="MINIO_NODE${n}_PATH=${MINIO_PATHS[${n}_path]}"$'\n'
    for d in $(seq 1 "$MINIO_DISKS"); do
      minio_lines+="MINIO_NODE${n}_DATA${d}=${MINIO_PATHS[${n}_${d}]}"$'\n'
    done
    minio_lines+=$'\n'
  done

  cat > "$dest" <<EOF
# Généré automatiquement par deploy.sh — $(date '+%Y-%m-%d %H:%M:%S')
# NE PAS MODIFIER MANUELLEMENT — regénérer avec deploy.sh

COMPOSE_PROJECT_NAME=maxscale

NEXTCLOUD_DOMAIN=${NC_DOMAIN}
COLLABORA_DOMAIN=${COLLAB_DOMAIN}
WHITEBOARD_DOMAIN=${WB_DOMAIN}
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

MINIO_ACCESS_KEY=${GEN_MINIO_KEY}
MINIO_SECRET_KEY=${GEN_MINIO_SECRET}
NEXTCLOUD_S3_BUCKET=nextcloud

${minio_lines}
WHITEBOARD_JWT_SECRET=${GEN_JWT_SECRET}
EOF

  chmod 600 "$dest"
  info ".env généré : $dest"
}

gen_compose() {
  local dest="${1:-$INSTALL_DIR/docker-compose.yml}"
  step "Génération du docker-compose.yml"


  # ── Header ──────────────────────────────────────────────────────────────
  cat > "$dest" <<'HEADER'
# Généré automatiquement par deploy.sh
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
    environment:
      - REDIS_PASSWORD=\${REDIS_PASSWORD}
      - NEXTCLOUD_DOMAIN=\${NEXTCLOUD_DOMAIN}
      - COLLABORA_DOMAIN=\${COLLABORA_DOMAIN}
      - WHITEBOARD_DOMAIN=\${WHITEBOARD_DOMAIN}
      - WHITEBOARD_JWT_SECRET=\${WHITEBOARD_JWT_SECRET}
      - MINIO_ACCESS_KEY=\${MINIO_ACCESS_KEY}
      - MINIO_SECRET_KEY=\${MINIO_SECRET_KEY}
      - NEXTCLOUD_S3_BUCKET=\${NEXTCLOUD_S3_BUCKET:-nextcloud}
    networks:
      - next-net
    depends_on:
      app-next-01:
        condition: service_healthy
NCSETUP

  # ── nextcloud-cron (fixed) ──────────────────────────────────────────────
  # Exécute cron.php toutes les 5 min — remplace le mode ajax (background:cron)
  cat >> "$dest" <<NCCRON

  nextcloud-cron:
    image: nextcloud:${NC_VERSION}
    container_name: nextcloud-cron
    restart: unless-stopped
    entrypoint: /cron.sh
    volumes:
      - ./opcache-recommended.ini:/usr/local/etc/php/conf.d/opcache-recommended.ini:ro
      - nextcloud_html:/var/www/html
      - nextcloud_apps:/var/www/html/custom_apps
      - nextcloud_config:/var/www/html/config
      - nextcloud_data:/var/www/html/data
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
    image: certbot/certbot:latest
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
          certbot renew --webroot -w /var/www/certbot --quiet
            --post-hook 'cat /etc/letsencrypt/live/stack/fullchain.pem /etc/letsencrypt/live/stack/privkey.pem > /certs/stack.pem && chmod 600 /certs/stack.pem';
          sleep 12h & wait $$!;
        done"
    depends_on:
      - nginx-acme
ACME

  # ── Nextcloud app nodes (dynamic) ───────────────────────────────────────
  local i
  for i in $(seq 1 "$NC_NODES"); do
    local name; name="app-next-$(printf '%02d' "$i")"
    local start_period="120s"
    local depends_block
    if (( i == 1 )); then
      start_period="300s"
      depends_block="    depends_on:
      mariadb-node1:
        condition: service_healthy
      redis-node1:
        condition: service_healthy
      haproxy:
        condition: service_started
      minio-node1:
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
      # Verification WSREP via PDO PHP (mariadb-client absent dans limage nextcloud).
      # php -r "new PDO(...)" leve une exception si WSREP 1047 -> exit non-zero.
      # Pas de variable $ dans le YAML -> pas d'interpolation Docker Compose.
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
      - nextcloud_html:/var/www/html
      - nextcloud_apps:/var/www/html/custom_apps
      - nextcloud_config:/var/www/html/config
      - nextcloud_data:/var/www/html/data
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
      - OBJECTSTORE_S3_KEY=\${MINIO_ACCESS_KEY}
      - OBJECTSTORE_S3_SECRET=\${MINIO_SECRET_KEY}
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

  # ── nginx containers (1 par nœud Nextcloud FPM) ────────────────────────
  for i in $(seq 1 "$NC_NODES"); do
    local fpm_name; fpm_name="app-next-$(printf '%02d' "$i")"
    local nginx_name; nginx_name="nginx-next-$(printf '%02d' "$i")"

    cat >> "$dest" <<NGNX

  ${nginx_name}:
    image: nginx:1.27-alpine
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
      db_cmd="    command: --wsrep-new-cluster"
      db_init_vol="      - ./mariadb/init.sql:/docker-entrypoint-initdb.d/init.sql:ro"
      db_extra_env="      - MARIADB_USER=\${MARIADB_USER}
      - MARIADB_PASSWORD=\${MARIADB_PASSWORD}
      - MARIADB_DATABASE=\${MARIADB_DATABASE}"
    fi

    if (( i > 1 )); then
      # Tous les nodes non-bootstrap dépendent directement de node1 (pas du précédent).
      # Cela permet un démarrage parallèle — Galera sérialise les SST lui-même.
      db_depends="    depends_on:
      mariadb-node1:
        condition: service_healthy"
    fi

    # node1 : laisse le temps au bootstrap + init schema
    # nodes 2+ : 180s pour absorber un SST complet avant qu'autoheal intervienne
    local start_period_db="180s"
    (( i == 1 )) && start_period_db="120s"

    cat >> "$dest" <<DBNODE

  mariadb-node${i}:
    build:
      context: .
      dockerfile: Dockerfile.mariadb-galera
    image: maxscale-mariadb-galera:11.4
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
  cat >> "$dest" <<'AUTOHEAL'

  galera-autoheal:
    image: willfarrell/autoheal:latest
    container_name: galera-autoheal
    restart: always
    environment:
      - AUTOHEAL_CONTAINER_LABEL=autoheal
      - AUTOHEAL_INTERVAL=60
      - AUTOHEAL_START_PERIOD=300
      - AUTOHEAL_DEFAULT_STOP_TIMEOUT=30
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
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
    image: redis:7.4-alpine
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
    image: redis:7.4-alpine
    container_name: redis-cluster-init
    environment:
      - REDIS_PASSWORD=\${REDIS_PASSWORD}
    command: >
      sh -c "
        echo 'Attente des noeuds Redis...';
${redis_wait_block}
        CLUSTER_STATE=\$\$(redis-cli -h redis-node1 -a \$\$REDIS_PASSWORD --no-auth-warning cluster info 2>/dev/null | grep cluster_state | cut -d: -f2 | tr -d '[:space:]');
        if [ \"\$\$CLUSTER_STATE\" = \"ok\" ]; then
          echo 'Cluster Redis deja initialise.';
        else
          redis-cli --cluster create${redis_addr_list} --cluster-replicas 1 -a \$\$REDIS_PASSWORD --no-auth-warning --cluster-yes;
          echo 'Cluster Redis cree.';
        fi"
    networks:
      - next-net
    depends_on:
${redis_deps_block}
    restart: "no"
RCINIT

  # ── MinIO nodes (dynamic) ──────────────────────────────────────────────
  # Commande server : SNMD (1 nœud, N drives locaux) ou MNMD (N nœuds × D drives)
  local minio_server_cmd
  if (( MINIO_NODES == 1 )); then
    local vols_cmd=""
    for _d in $(seq 1 "$MINIO_DISKS"); do vols_cmd+=" /data${_d}"; done
    minio_server_cmd="server${vols_cmd} --address :9000"
  else
    minio_server_cmd="server http://minio-node{1...${MINIO_NODES}}/data{1...${MINIO_DISKS}} --address :9000"
  fi

  for i in $(seq 1 "$MINIO_NODES"); do
    local rfs_ip="172.50.0.$((10 + i))"
    local rfs_vol_lines=""
    local d
    for d in $(seq 1 "$MINIO_DISKS"); do
      rfs_vol_lines+="      - \${MINIO_NODE${i}_DATA${d}:-${MINIO_PATHS[${i}_${d}]}}:/data${d}"$'\n'
    done

    local bypass_env=""
    [[ "$MINIO_BYPASS" == "true" ]] && bypass_env="      - MINIO_CI_CD=on"

    local rfs_hc=""
    if (( i == 1 )); then
      rfs_hc="    healthcheck:
      test: [\"CMD-SHELL\", \"curl -sf http://localhost:9000/minio/health/live || exit 1\"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 90s"
    fi

    cat >> "$dest" <<MINIONODE

  minio-node${i}:
    image: minio/minio:latest
    container_name: minio-node${i}
    hostname: minio-node${i}
    restart: always
    user: root
    command: ${minio_server_cmd}
    expose:
      - "9000"
    volumes:
${rfs_vol_lines}
    environment:
      - MINIO_ROOT_USER=\${MINIO_ACCESS_KEY}
      - MINIO_ROOT_PASSWORD=\${MINIO_SECRET_KEY}
${bypass_env}
    networks:
      storage-net: {}
      minionet:
        ipv4_address: ${rfs_ip}
${rfs_hc}
MINIONODE
  done

  # ── Collabora nodes (dynamic) ───────────────────────────────────────────
  for i in $(seq 1 "$COLLAB_NODES"); do
    local collab_hc=""
    if (( i == 1 )); then
      collab_hc="    healthcheck:
      test: [\"CMD-SHELL\", \"curl -sf http://localhost:9980/ >/dev/null 2>&1 || exit 1\"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s"
    fi

    cat >> "$dest" <<COLLNODE

  collabora-node${i}:
    image: collabora/code:latest
    container_name: collabora-node${i}
    restart: always
    expose:
      - "9980"
    environment:
      - dictionaries=fr_FR en_US
      - extra_params=--o:ssl.enable=false --o:ssl.termination=true --o:net.listen=any --o:server_name=\${COLLABORA_DOMAIN} --o:mount_jail_tree=false
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
    image: ghcr.io/nextcloud-releases/whiteboard:stable
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
  minionet:
    name: minionet
    driver: bridge
    ipam:
      config:
        - subnet: 172.50.0.0/24
NETWORKS

  # ── Volumes ─────────────────────────────────────────────────────────────
  echo "" >> "$dest"
  echo "volumes:" >> "$dest"
  echo "  letsencrypt:" >> "$dest"
  echo "  certbot_webroot:" >> "$dest"
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

  info "docker-compose.yml généré ($dest)"
}

gen_galera_cnf() {
  local dir="${1:-$INSTALL_DIR/mariadb}"
  step "Génération des fichiers de configuration Galera"
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
  step "Mise à jour de nextcloud-init.sh (Redis ${REDIS_NODES} nœuds)"

  [[ -f "$file" ]] || die "nextcloud-init.sh introuvable : $file"

  # Update the summary line
  local masters=$(( REDIS_NODES / 2 ))
  sed -i "s/redis-node1, redis-node3, redis-node5/redis-node1, redis-node3, redis-node5 (${REDIS_NODES} nœuds total)/" "$file" 2>/dev/null || true

  info "nextcloud-init.sh prêt : seeds redis-node1/3/5 — ${REDIS_NODES} nœuds (${masters} masters + ${masters} replicas)"
}

create_minio_dirs() {
  step "Création des répertoires MinIO"
  start_spinner "Préparation des répertoires..."
  local n d
  for n in $(seq 1 "$MINIO_NODES"); do
    for d in $(seq 1 "$MINIO_DISKS"); do
      local path="${MINIO_PATHS[${n}_${d}]}"
      mkdir -p "$path"
      find "${path:?}" -mindepth 1 -delete 2>/dev/null || true
    done
  done
  stop_spinner "Répertoires MinIO prêts"
}

validate_haproxy() {
  local file="${1:-$INSTALL_DIR/haproxy.cfg}"
  step "Validation de la configuration HAProxy"

  local tmp tmp_certs
  tmp=$(mktemp)
  tmp_certs=$(mktemp -d)
  chmod 755 "$tmp_certs"

  # Substituer les variables avec des valeurs fictives
  NEXTCLOUD_DOMAIN=nc.valid \
  COLLABORA_DOMAIN=co.valid \
  WHITEBOARD_DOMAIN=wb.valid \
  HAPROXY_STATS_PASSWORD=check \
    envsubst < "$file" > "$tmp"
  chmod 644 "$tmp"

  # Certificat SSL factice — haproxy -c vérifie que bind :443 peut lire /certs/
  openssl req -x509 -newkey rsa:2048 \
    -keyout "${tmp_certs}/key.pem" \
    -out    "${tmp_certs}/cert.pem" \
    -days 1 -nodes -subj "/CN=validate" 2>/dev/null
  cat "${tmp_certs}/cert.pem" "${tmp_certs}/key.pem" > "${tmp_certs}/stack.pem"
  chmod 644 "${tmp_certs}/stack.pem"

  local output
  if output=$(docker run --rm \
      -v "${tmp}:/tmp/haproxy.cfg:ro" \
      -v "${tmp_certs}:/certs:ro" \
      haproxy:2.8-alpine \
      haproxy -c -f /tmp/haproxy.cfg 2>&1); then
    rm -f "$tmp"; rm -rf "$tmp_certs"
    info "Configuration HAProxy valide ✓"
  else
    rm -f "$tmp"; rm -rf "$tmp_certs"
    error "Configuration HAProxy invalide :"
    echo "$output" >&2
    die "Corrigez haproxy.cfg avant de relancer le déploiement."
  fi
}

patch_haproxy() {
  local file="${1:-$INSTALL_DIR/haproxy.cfg}"
  step "Mise à jour des backends HAProxy"

  [[ -f "$file" ]] || die "haproxy.cfg introuvable : $file"

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

  local minio_servers=""
  for i in $(seq 1 "$MINIO_NODES"); do
    minio_servers+="  server minio-node${i} minio-node${i}:9000 check"$'\n'
  done

  local redis_servers=""
  for i in $(seq 1 "$REDIS_NODES"); do
    redis_servers+="  server redis-node${i} redis-node${i}:6379 check"$'\n'
  done

  # Apply patches sequentially using temp files
  local tmp tmp2
  tmp=$(mktemp)
  tmp2=$(mktemp)
  cp "$file" "$tmp"

  _replace_servers "NEXTCLOUD"  "${nc_servers%$'\n'}"      "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  _replace_servers "COLLABORA"  "${collab_servers%$'\n'}"  "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  _replace_servers "WHITEBOARD" "${wb_servers%$'\n'}"      "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  _replace_servers "GALERA"     "${galera_servers%$'\n'}"  "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  _replace_servers "MINIO"      "${minio_servers%$'\n'}"   "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  _replace_servers "REDIS"      "${redis_servers%$'\n'}"   "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"

  # Supprimer le bloc stats de frontend https si désactivé (entre les markers BEGIN/END_STATS)
  if [[ "$HAPROXY_STATS" == "no" ]]; then
    awk '/# BEGIN_STATS/{skip=1} /# END_STATS/{skip=0; next} !skip{print}' \
      "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
  fi

  mv "$tmp" "$file"
  info "haproxy.cfg patché (NC:${NC_NODES} Collab:${COLLAB_NODES} WB:${WB_NODES} DB:${MARIADB_NODES} MinIO:${MINIO_NODES})"
}

# ─── [DEPLOY] Certificats et déploiement ─────────────────────────────────────

gen_certs() {
  phase 6 7 "Génération des certificats SSL"

  # Préfixe = nom du projet Docker Compose (doit correspondre aux volumes docker-compose.yml)
  local prefix; prefix=$(basename "$INSTALL_DIR")
  # En staging, on utilise un volume séparé pour ne pas polluer le volume prod
  local le_vol="${prefix}_letsencrypt"
  [[ "$CERTBOT_STAGING" == "yes" ]] && le_vol="${prefix}_letsencrypt_staging"

  if [[ "$CERTBOT_STAGING" == "yes" ]]; then
    warn "Mode STAGING — certificats non reconnus par les navigateurs (tests uniquement)"
  fi

  # ── Skip si stack.pem déjà valide ─────────────────────────────────────────
  if [[ -s "$INSTALL_DIR/certs/stack.pem" ]]; then
    info "Certificat existant valide trouvé — génération ignorée"
    return 0
  fi
  rm -f "$INSTALL_DIR/certs/stack.pem"

  # ── Réutiliser depuis le volume Let's Encrypt si disponible ───────────────
  step "Recherche d'un certificat existant dans le volume"
  docker volume create "${le_vol}" &>/dev/null || true
  docker volume create "${prefix}_certbot_webroot" &>/dev/null || true

  if docker run --rm -v "${le_vol}:/etc/letsencrypt" alpine \
      test -f /etc/letsencrypt/live/stack/fullchain.pem 2>/dev/null; then
    info "Certificat trouvé dans le volume — recombination sans appel Let's Encrypt"
    mkdir -p "$INSTALL_DIR/certs"
    docker run --rm \
      -v "${le_vol}:/etc/letsencrypt:ro" \
      -v "$INSTALL_DIR/certs:/certs" \
      alpine sh -c "cat /etc/letsencrypt/live/stack/fullchain.pem \
        /etc/letsencrypt/live/stack/privkey.pem > /certs/stack.pem.tmp \
        && mv /certs/stack.pem.tmp /certs/stack.pem && chmod 644 /certs/stack.pem"
    [[ -s "$INSTALL_DIR/certs/stack.pem" ]] && {
      info "Certificat recombinéstack.pem ($(wc -c < "$INSTALL_DIR/certs/stack.pem") octets)"
      return 0
    }
  fi

  # ── Vérification DNS ──────────────────────────────────────────────────────
  step "Vérification DNS des domaines"
  local my_ip dns_ok=true
  my_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
          curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || \
          hostname -I 2>/dev/null | awk '{print $1}')
  info "IP publique détectée : ${my_ip:-inconnue}"

  local domain
  for domain in "$NC_DOMAIN" "$COLLAB_DOMAIN" "$WB_DOMAIN"; do
    local resolved=""
    resolved=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
    [[ -z "$resolved" ]] && resolved=$(dig +short "$domain" A 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$my_ip" && "$resolved" == "$my_ip" ]]; then
      info "$domain → $resolved ✓"
    elif [[ -z "$resolved" ]]; then
      warn "$domain → non résolu (DNS manquant ?)"
      dns_ok=false
    else
      warn "$domain → $resolved  (IP serveur : ${my_ip:-?}) — divergence !"
      dns_ok=false
    fi
  done

  if ! $dns_ok; then
    warn "Certains domaines ne pointent pas vers ce serveur."
    warn "Let's Encrypt vérifie le DNS — les certificats échoueront si les entrées sont incorrectes."
    prompt_yn "Continuer quand même ?" "N" || die "Annulé — corrigez le DNS puis relancez."
  fi

  # ── Vérification des ports ────────────────────────────────────────────────
  local port80_free=true port443_free=true
  ss -tlnp 2>/dev/null | grep -q ':80 '  && port80_free=false
  ss -tlnp 2>/dev/null | grep -q ':443 ' && port443_free=false

  # ── Appel Certbot ─────────────────────────────────────────────────────────
  step "Génération des certificats Let's Encrypt"
  info "Domaines : ${NC_DOMAIN}, ${COLLAB_DOMAIN}, ${WB_DOMAIN}"
  info "Email    : ${CERTBOT_EMAIL}"

  local certbot_args=(
    certonly --standalone --non-interactive --keep-until-expiring
    --agree-tos --no-eff-email --email "$CERTBOT_EMAIL"
    -d "$NC_DOMAIN" -d "$COLLAB_DOMAIN" -d "$WB_DOMAIN"
    --cert-name stack
  )
  [[ "$CERTBOT_STAGING" == "yes" ]] && certbot_args+=(--staging)

  local cert_ok=false certbot_output=""

  # challenge = "http-01" | "tls-alpn-01"  port = "80:80" | "443:443"
  # NOTE : --preferred-challenges doit aller dans les args certbot, pas docker run
  _run_certbot() {
    local challenge="$1" port="$2"
    certbot_output=$(docker run --rm -p "$port" \
      -v "${le_vol}:/etc/letsencrypt" \
      certbot/certbot "${certbot_args[@]}" \
      --preferred-challenges "$challenge" 2>&1) && return 0 || return 1
  }

  # Tentative 1 : HTTP-01 port 80
  if $port80_free; then
    info "Tentative HTTP-01 (port 80)..."
    if _run_certbot "http-01" "80:80"; then
      cert_ok=true
    else
      warn "HTTP-01 (port 80) a échoué."
      echo "$certbot_output" | grep -iE 'error|detail|challenge|timeout|connection' | head -5 >&2 || true
    fi
  else
    warn "Port 80 occupé — HTTP-01 ignoré."
  fi

  # Tentative 2 : TLS-ALPN-01 port 443
  if ! $cert_ok; then
    if $port443_free; then
      info "Tentative TLS-ALPN-01 (port 443)..."
      if _run_certbot "tls-alpn-01" "443:443"; then
        cert_ok=true
      else
        warn "TLS-ALPN-01 (port 443) a également échoué."
        echo "$certbot_output" | grep -iE 'error|detail|challenge|timeout|connection' | head -5 >&2 || true
      fi
    else
      warn "Port 443 occupé — TLS-ALPN-01 ignoré."
    fi
  fi

  if ! $cert_ok; then
    error "Certbot a échoué sur les deux méthodes. Sortie complète :"
    echo "$certbot_output" | tail -20 >&2
    # Détecter rate limit et afficher l'heure de déblocage
    local retry_after=""
    retry_after=$(echo "$certbot_output" | grep -oE 'until [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z' | head -1 | sed 's/until //')
    [[ -n "$retry_after" ]] && error "Rate limit — réessayez après : $retry_after"
    die "Vérifiez :\n  • DNS : les domaines pointent vers ce serveur\n  • Ports 80/443 accessibles depuis Internet\n  • Rate limit : max 5 certificats / 7 jours (utilisez le mode Staging pour tester)"
  fi

  step "Combinaison fullchain + privkey pour HAProxy"
  mkdir -p "$INSTALL_DIR/certs"
  docker run --rm \
    -v "${le_vol}:/etc/letsencrypt:ro" \
    -v "$INSTALL_DIR/certs:/certs" \
    alpine sh -c "cat /etc/letsencrypt/live/stack/fullchain.pem \
      /etc/letsencrypt/live/stack/privkey.pem > /certs/stack.pem.tmp \
      && mv /certs/stack.pem.tmp /certs/stack.pem && chmod 644 /certs/stack.pem"

  [[ -s "$INSTALL_DIR/certs/stack.pem" ]] || die "Échec : stack.pem absent ou vide"
  info "Certificat disponible : $INSTALL_DIR/certs/stack.pem ($(wc -c < "$INSTALL_DIR/certs/stack.pem") octets)"
}

fix_galera_bootstrap() {
  # Si mariadb-node1 tourne déjà, on ne touche à rien
  local status
  status=$(docker inspect --format='{{.State.Status}}' mariadb-node1 2>/dev/null || echo "absent")
  [[ "$status" == "running" ]] && return 0

  local project_name; project_name=$(basename "$INSTALL_DIR")
  local vol1="${project_name}_mariadb_n1_data"

  # Pas de volume → premier démarrage propre, rien à faire
  docker volume inspect "$vol1" &>/dev/null || return 0

  # Pas de grastate.dat → MariaDB n'a jamais tourné, rien à faire
  docker run --rm -v "${vol1}:/data" alpine test -f /data/grastate.dat 2>/dev/null || return 0

  info "Volumes MariaDB existants détectés — correction du bootstrap Galera..."

  # Remettre safe_to_bootstrap à 0 sur tous les nœuds existants
  local n
  for n in $(seq 1 "$MARIADB_NODES"); do
    local vol="${project_name}_mariadb_n${n}_data"
    docker volume inspect "$vol" &>/dev/null || continue
    docker run --rm -v "${vol}:/data" alpine \
      sh -c "test -f /data/grastate.dat && \
        sed -i 's/safe_to_bootstrap: 1/safe_to_bootstrap: 0/' /data/grastate.dat" \
      2>/dev/null || true
  done

  # Forcer node1 comme nœud de bootstrap (correspond au --wsrep-new-cluster du compose)
  docker run --rm -v "${vol1}:/data" alpine \
    sed -i 's/safe_to_bootstrap: 0/safe_to_bootstrap: 1/' /data/grastate.dat \
    2>/dev/null
  info "Galera : mariadb-node1 défini comme nœud de bootstrap"
}

run_deploy() {
  cd "$INSTALL_DIR"

  # Vérification explicite du cert avant tout démarrage
  if [[ ! -s "./certs/stack.pem" ]]; then
    die "Certificat SSL absent : $(pwd)/certs/stack.pem\nRelancez le script pour regénérer le certificat."
  fi
  info "Certificat SSL OK : $(pwd)/certs/stack.pem ($(wc -c < "./certs/stack.pem") octets)"

  step "Pull des images Docker (parallèle)"
  local images=(
    "haproxy:2.8-alpine"
    "nginx:1.27-alpine"
    "certbot/certbot:latest"
    "nextcloud:${NC_VERSION}"
    "redis:7.4-alpine"
    "minio/minio:latest"
    "collabora/code:latest"
    "ghcr.io/nextcloud-releases/whiteboard:stable"
  )
  local total=${#images[@]}
  local tmpdir; tmpdir=$(mktemp -d)

  # Lancer tous les pulls en parallèle — on garde les PIDs pour wait ciblé
  # (wait sans args bloquerait sur le processus tee de setup_logging)
  local img pids=()
  for img in "${images[@]}"; do
    local safe; safe=$(echo "$img" | tr '/.:' '_')
    ( docker pull "$img" -q &>/dev/null && touch "$tmpdir/$safe" || touch "$tmpdir/${safe}.fail" ) &
    pids+=($!)
  done

  # Affichage temps réel
  local done_count=0
  while (( done_count < total )); do
    done_count=$(ls "$tmpdir" 2>/dev/null | wc -l)
    progress_bar "$done_count" "$total" "Images téléchargées en parallèle..."
    sleep 0.4
  done
  # Attendre uniquement les jobs de pull (pas le processus tee du journal)
  wait "${pids[@]}" 2>/dev/null || true
  echo ""

  # Vérifier les échecs
  local img_failed=0
  for img in "${images[@]}"; do
    local safe; safe=$(echo "$img" | tr '/.:' '_')
    if [[ -f "$tmpdir/${safe}.fail" ]]; then
      error "Échec du pull : $img"
      (( img_failed++ )) || true
    fi
  done
  rm -rf "$tmpdir"
  (( img_failed > 0 )) && die "${img_failed} image(s) n'ont pas pu être téléchargées"
  info "Toutes les images téléchargées"

  step "Build de l'image MariaDB Galera"
  start_spinner "docker compose build..."
  docker compose build --quiet
  stop_spinner "Image MariaDB Galera construite"

  step "Démarrage de l'infrastructure"

  # Démarrer HAProxy en premier et attendre qu'il soit healthy
  # avant de lancer les services qui en dépendent
  docker compose up -d haproxy nginx-acme certbot
  info "En attente que HAProxy réponde sur le port 80..."
  local elapsed=0 max_wait=60
  while (( elapsed < max_wait )); do
    # Test depuis l'hôte via /dev/tcp bash (plus fiable que nc dans alpine)
    if timeout 3 bash -c '</dev/tcp/127.0.0.1/80' 2>/dev/null; then
      info "HAProxy répond sur le port 80 ✓"
      break
    fi
    # Vérifier que le container n'a pas crashé
    local state
    state=$(docker inspect --format='{{.State.Status}}' haproxy 2>/dev/null || echo "absent")
    if [[ "$state" != "running" ]]; then
      error "Le container HAProxy s'est arrêté (état: $state). Logs :"
      docker logs haproxy --tail 20 >&2
      die "HAProxy a planté — vérifiez les logs ci-dessus."
    fi
    printf "\r  ${C_YELLOW}⟳${C_RESET}  HAProxy démarrage... (%ds/%ds)   " "$elapsed" "$max_wait"
    sleep 3
    (( elapsed += 3 )) || true
  done
  if (( elapsed >= max_wait )); then
    echo ""
    error "HAProxy ne répond pas après ${max_wait}s. Logs :"
    docker logs haproxy --tail 20 >&2
    die "HAProxy inaccessible — vérifiez les logs ci-dessus."
  fi
  echo ""

  # Corriger grastate.dat si des volumes MariaDB existent d'un déploiement précédent
  fix_galera_bootstrap

  # Lancer tous les autres services en arrière-plan
  start_spinner "Démarrage de tous les services..."
  docker compose up -d 2>&1 | grep -E '^\s*(✔|✘|Error)' || true
  stop_spinner "Services lancés"
  info "Services démarrés — attente de l'installation Nextcloud (max 15 min)..."
  local deadline=$(( $(date +%s) + 900 )) elapsed_setup=0
  while (( $(date +%s) < deadline )); do
    local setup_status
    setup_status=$(docker inspect --format='{{.State.Status}}' nextcloud-setup 2>/dev/null || echo "absent")
    if [[ "$setup_status" == "exited" ]]; then
      local exit_code
      exit_code=$(docker inspect --format='{{.State.ExitCode}}' nextcloud-setup 2>/dev/null || echo "1")
      if [[ "$exit_code" == "0" ]]; then
        info "nextcloud-setup terminé avec succès ✓"
      else
        warn "nextcloud-setup terminé avec erreur (code $exit_code)"
        docker logs nextcloud-setup --tail 20
      fi
      break
    fi
    (( elapsed_setup += 10 )) || true
    printf "\r  ${C_YELLOW}⟳${C_RESET}  Installation Nextcloud en cours... (%ds)" "$elapsed_setup"
    sleep 10
  done
  echo ""
}

# ─── [CHECK] Vérification et résumé ──────────────────────────────────────────

wait_healthy() {
  phase 7 7 "Vérification de l'infrastructure"
  step "Attente que tous les services soient healthy"

  # Timeout adaptatif selon le nombre de nœuds (base 600s + 60s/NC + 20s/DB + 20s/MinIO + 30s/Collab)
  local timeout interval=10
  timeout=$(( 600 + NC_NODES * 60 + MARIADB_NODES * 20 + MINIO_NODES * 20 + COLLAB_NODES * 30 ))
  (( timeout > 1800 )) && timeout=1800
  local elapsed=0

  # Critical containers to monitor
  local containers=("haproxy")
  local i
  for i in $(seq 1 "$NC_NODES");      do containers+=("app-next-$(printf '%02d' "$i")"); done
  for i in $(seq 1 "$NC_NODES");      do containers+=("nginx-next-$(printf '%02d' "$i")"); done
  for i in $(seq 1 "$MARIADB_NODES"); do containers+=("mariadb-node${i}"); done
  containers+=("redis-node1")
  for i in $(seq 1 "$MINIO_NODES");  do containers+=("minio-node${i}"); done

  info "Timeout calculé : ${timeout}s (${NC_NODES} NC + ${MARIADB_NODES} DB + ${MINIO_NODES} MinIO + ${COLLAB_NODES} Collabora)"

  while (( elapsed < timeout )); do
    local remaining=$(( timeout - elapsed ))
    local eta_min=$(( remaining / 60 )) eta_sec=$(( remaining % 60 ))
    printf "\n  ${C_GRAY}[ $(date '+%H:%M:%S') — %ds écoulées — ETA %dm%02ds ]${C_RESET}\n" \
      "$elapsed" "$eta_min" "$eta_sec"
    local all_healthy=true

    for name in "${containers[@]}"; do
      local status
      if ! docker inspect "$name" &>/dev/null; then
        status="absent"
      else
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null | tr -d '\n\r')
        if [[ -z "$health" || "$health" == "<no value>" ]]; then
          # Pas de healthcheck — utilise le statut du container
          local cstate
          cstate=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null | tr -d '\n\r')
          [[ "$cstate" == "running" ]] && status="healthy" || status="${cstate:-absent}"
        else
          status="$health"
        fi
      fi
      case "$status" in
        healthy)   printf "  ${C_BGREEN}✓${C_RESET}  %s\n" "$name" ;;
        starting)  printf "  ${C_YELLOW}⟳${C_RESET}  %s  ${C_GRAY}(starting...)${C_RESET}\n" "$name"; all_healthy=false ;;
        unhealthy) printf "  ${C_BRED}✗${C_RESET}  %s  ${C_RED}(unhealthy — docker logs %s)${C_RESET}\n" "$name" "$name"; all_healthy=false ;;
        *)         printf "  ${C_GRAY}·${C_RESET}  %s  ${C_GRAY}(%s)${C_RESET}\n" "$name" "$status"; all_healthy=false ;;
      esac
    done

    $all_healthy && { info "Tous les services sont healthy ✓"; return 0; }
    sleep "$interval"
    (( elapsed += interval )) || true
  done

  die "Timeout — certains services ne sont pas healthy après ${timeout}s.\nVérifiez : docker compose logs"
}

check_services() {
  step "Tests fonctionnels"
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

  _check "Nextcloud installé" \
    bash -c "curl -skf https://${NC_DOMAIN}/status.php | grep -q '\"installed\":true'"

  _check "MariaDB Galera actif" \
    docker exec mariadb-node1 mariadb-admin ping -uroot -p"${GEN_DB_ROOT_PASS}" --silent

  _check "Redis Cluster OK" \
    bash -c "docker exec redis-node1 redis-cli -a '${GEN_REDIS_PASS}' --no-auth-warning cluster info | grep -q 'cluster_state:ok'"

  _check "MinIO S3 health" \
    bash -c "docker exec minio-node1 curl -sf http://localhost:9000/minio/health/live 2>/dev/null"

  _check "nextcloud-setup terminé" \
    bash -c "docker logs nextcloud-setup 2>&1 | grep -q 'Setup Nextcloud terminé'"

  _check "nextcloud-cron actif" \
    bash -c "docker inspect nextcloud-cron --format='{{.State.Running}}' 2>/dev/null | grep -q true"

  if (( failures > 0 )); then
    warn "${failures} test(s) en échec — vérifiez : docker compose logs"
  else
    info "Tous les tests fonctionnels passent ✓"
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
MINIO_ACCESS_KEY=${GEN_MINIO_KEY}
MINIO_SECRET_KEY=${GEN_MINIO_SECRET}
HAPROXY_STATS_PASSWORD=${GEN_HAPROXY_STATS_PASS}
CREDS
  chmod 600 "$creds_file"

  local host_ip
  host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

  local stats_line="Stats HAProxy  : désactivées"
  [[ "$HAPROXY_STATS" == "yes" ]] && \
    stats_line="Stats HAProxy  : https://${NC_DOMAIN}/stats  (admin / ${GEN_HAPROXY_STATS_PASS})"

  # Box width = 70: ╔(1)+68×═+╗(1)=70  Content: ║(1)+"  "(2)+%-66s+║(1)=70
  local _B; printf -v _B '%*s' 68 ''; _B="${_B// /═}"
  local _TOP="╔${_B}╗" _SEP="╠${_B}╣" _BOT="╚${_B}╝"
  local I=66

  echo ""
  echo -e "${C_BGREEN}"
  echo "$_TOP"
  printf "║  %-${I}s║\n" "✓  DÉPLOIEMENT TERMINÉ AVEC SUCCÈS"
  echo "$_SEP"
  printf "║  %-${I}s║\n" "ACCÈS NEXTCLOUD"
  printf "║  %-${I}s║\n" "URL      : https://${NC_DOMAIN}"
  printf "║  %-${I}s║\n" "Login    : admin"
  printf "║  %-${I}s║\n" "Password : ${GEN_NC_ADMIN_PASS}"
  echo "$_SEP"
  printf "║  %-${I}s║\n" "SERVICES"
  printf "║  %-${I}s║\n" "Collabora  : https://${COLLAB_DOMAIN}"
  printf "║  %-${I}s║\n" "Whiteboard : https://${WB_DOMAIN}"
  printf "║  %-${I}s║\n" "$stats_line"
  echo "$_SEP"
  printf "║  %-${I}s║\n" "INFRASTRUCTURE"
  printf "║  %-${I}s║\n" "Nextcloud ${NC_NODES}×FPM + ${NC_NODES}×nginx  │  MariaDB ${MARIADB_NODES} nœuds  │  Redis ${REDIS_NODES} nœuds"
  printf "║  %-${I}s║\n" "MinIO ${MINIO_NODES}×${MINIO_DISKS}  │  Collabora ${COLLAB_NODES} nœuds  │  Whiteboard ${WB_NODES} nœuds"
  echo "$_SEP"
  printf "║  %-${I}s║\n" "Credentials : ${creds_file}"
  echo "$_SEP"
  printf "║  %-${I}s║\n" "APRÈS UNE PANNE NŒUD MINIO — commande de réparation :"
  printf "║  %-${I}s║\n" "docker run --rm --network storage-net --entrypoint sh minio/mc \\"
  printf "║  %-${I}s║\n" "  -c \"mc alias set r http://minio-node1:9000 KEY SECRET --quiet"
  printf "║  %-${I}s║\n" "        && mc admin heal -r r/nextcloud\""
  echo "$_BOT"
  echo -e "${C_RESET}"
}

final_check() {
  step "Test d'accès Nextcloud"
  local max_wait=90 elapsed=0
  while (( elapsed < max_wait )); do
    if curl -skf --max-time 10 "https://${NC_DOMAIN}/status.php" 2>/dev/null \
        | grep -q '"installed":true'; then
      info "Nextcloud répond ✓  →  https://${NC_DOMAIN}"
      return 0
    fi
    sleep 5; (( elapsed += 5 )) || true
    printf "\r\033[K  ${C_YELLOW}⟳${C_RESET}  Test accès Nextcloud... (%ds/%ds)" "$elapsed" "$max_wait"
  done
  echo ""
  warn "Nextcloud ne répond pas encore à https://${NC_DOMAIN}/status.php"
  warn "Vérifiez dans quelques secondes ou consultez : docker logs app-next-01"
}

# ─── [MAIN] Point d'entrée ───────────────────────────────────────────────────

main() {
  show_banner
  setup_logging

  # Phase 1-2 : Système
  detect_os
  install_deps
  check_requirements

  # Phase 3 : Clone
  clone_repo

  # Phase 4 : Configuration interactive
  if ! load_answers; then
    ask_domains
    ask_versions
    ask_nodes
    ask_minio
    ask_haproxy
    ask_cert_mode
  fi
  show_recap
  save_answers

  # Phase 5 : Génération des fichiers
  gen_passwords
  gen_env
  gen_compose
  gen_galera_cnf
  patch_haproxy
  validate_haproxy
  patch_nextcloud_init
  create_minio_dirs

  # Phase 6 : Déploiement
  gen_certs
  run_deploy

  # Phase 7 : Vérification
  wait_healthy
  check_services
  final_check
  show_summary
}

[[ $_SOURCE_ONLY -eq 0 ]] && main "$@" || true
