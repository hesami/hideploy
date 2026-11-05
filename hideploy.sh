#!/usr/bin/env bash
# =============================================================================
# HiDeploy
# -----------------------------------------------------------------------------
# One interactive script to:
#   1) Prepare a fresh Ubuntu server (Docker, Git, GitLab Runner, shared network)
#   2) Install shared services (ONE nginx container + ONE MariaDB container)
#   3) Generate the standard project files (Dockerfile, compose, CI, ...)
#   4) Deploy a new Laravel project (clone, DB, .env, container, vhost, SSL)
#   5) Manage projects (logs, deploy, backup, SSL, remove)
#
# Architecture (kept deliberately simple):
#
#   Internet --> [global-nginx] --> [project container 1: php-fpm+queue+scheduler]
#                               --> [project container 2: ...]
#                [global-mariadb] <-- all projects
#
#   Project code lives on the server disk:  /var/www/projects/<domain>
#   Shared infrastructure lives in:         /var/www/infrastructure
#
# Usage:  sudo hideploy            (menu)
#         hideploy --version | --help | update
# =============================================================================

set -uo pipefail

HIDEPLOY_VERSION="1.3.0"
HIDEPLOY_REPO="hesami/hideploy"

# ----------------------------------------------------------------------------
# Configuration (change here if you ever need to)
# ----------------------------------------------------------------------------
NETWORK="web_network"
BASE_DIR="/var/www"
INFRA_DIR="$BASE_DIR/infrastructure"
NGINX_DIR="$INFRA_DIR/nginx"
DB_DIR="$INFRA_DIR/database"
PROJECTS_DIR="$BASE_DIR/projects"
CONFIG_FILE="$INFRA_DIR/config.env"
TEMPLATES_DIR="/root/hideploy-templates"
BACKUP_DIR="/var/backups/hideploy"

NGINX_CONTAINER="global-nginx"
DB_CONTAINER="global-mariadb"
PMA_CONTAINER="global-phpmyadmin"
PMA_DIR="$INFRA_DIR/phpmyadmin"
PMA_HTPASSWD="$NGINX_DIR/conf.d/pma.htpasswd"
RUNNER_USER="gitlab-runner"

NGINX_IMAGE="nginx:stable-alpine"
MARIADB_IMAGE="mariadb:10.11"
PMA_IMAGE="phpmyadmin:5-apache"
CERTBOT_IMAGE="certbot/certbot"
DEFAULT_NODE_IMAGE="node:22-alpine"   # used only for temporary frontend-build containers

RENEW_SCRIPT="/usr/local/bin/hideploy-renew-ssl"
RENEW_CRON="/etc/cron.d/hideploy-ssl-renew"
RENEW_LOG="/var/log/hideploy-ssl-renew.log"

# Backups
BK_DIR="$INFRA_DIR/backup"                 # settings, passphrase, destination keys (root only; never inside a backup)
BK_CONF="$BK_DIR/backup.env"
BK_PASS="$BK_DIR/passphrase"
BK_SSH_KEY="$BK_DIR/id_ed25519"
BK_KNOWN="$BK_DIR/known_hosts"
BK_RCLONE_ENV="$BK_DIR/rclone.env"
BK_LOCAL_DIR="$BACKUP_DIR/auto"            # automatic backups kept on this server
BK_CRON="/etc/cron.d/hideploy-backup"
BK_LOG="/var/log/hideploy-backup.log"
RCLONE_IMAGE="rclone/rclone"

# Disk cleanup
CLEANUP_CRON="/etc/cron.d/hideploy-cleanup"
CLEANUP_LOG="/var/log/hideploy-cleanup.log"

# Performance tuning
PERF_CONF="$INFRA_DIR/performance.env"
PERF_NGINX_CONF="$NGINX_DIR/conf.d/10-hideploy-performance.conf"

DEPLOY_MAINT_ON="no"                       # set while a deployment keeps the site in maintenance mode

# ----------------------------------------------------------------------------
# Colors and output helpers
# ----------------------------------------------------------------------------
# Colors are disabled automatically when output is not a terminal or NO_COLOR is set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
    C_CYAN=$'\033[1;36m'; C_MAGENTA=$'\033[1;35m'; C_BLUE=$'\033[1;34m'
    C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_MAGENTA=""; C_BLUE=""
    C_BOLD=""; C_DIM=""; C_RESET=""
fi

info()  { printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()   { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*"; }

# banner "Title" [color] — each menu uses its own title color
banner() {
    local color="${2:-$C_GREEN}" line="================================================================="
    printf '%s%s%s\n' "$color" "$line" "$C_RESET"
    printf '%s  %s%s\n' "$color" "$1" "$C_RESET"
    printf '%s%s%s\n' "$color" "$line" "$C_RESET"
}

section() { printf '\n%s━━ %s ━━%s\n' "$C_BOLD" "$*" "$C_RESET"; }

explain() {
    local line
    for line in "$@"; do printf '%s  %s%s\n' "$C_DIM" "$line" "$C_RESET"; done
}

next_steps() {
    printf '\n%sWhat to do next:%s\n' "$C_YELLOW" "$C_RESET"
    local line
    for line in "$@"; do printf '   • %s\n' "$line"; done
}

pause() {
    echo ""
    read -r -p "${C_MAGENTA}Press [Enter] to continue...${C_RESET}" _
}

# ask "Prompt" "default" VARNAME   (Enter accepts the default)
ask() {
    local prompt="$1" default="${2:-}" __var="$3" reply
    if [ -n "$default" ]; then
        read -r -p "${C_YELLOW}${prompt} [${default}]: ${C_RESET}" reply
    else
        read -r -p "${C_YELLOW}${prompt}: ${C_RESET}" reply
    fi
    printf -v "$__var" '%s' "${reply:-$default}"
}

# ask_secret "Prompt" VARNAME   (hidden input)
ask_secret() {
    local prompt="$1" __var="$2" reply
    read -r -s -p "${C_YELLOW}${prompt}: ${C_RESET}" reply
    echo ""
    printf -v "$__var" '%s' "$reply"
}

# confirm "Question" [y|n]   -> returns 0 for yes
confirm() {
    local prompt="$1" default="${2:-y}" reply hint
    if [ "$default" = "y" ]; then hint="Y/n"; else hint="y/N"; fi
    read -r -p "${C_YELLOW}${prompt} [${hint}]: ${C_RESET}" reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

# Run a long-running command that the user may stop with Ctrl-C (e.g. log follow)
follow_cmd() {
    trap ':' INT
    "$@"
    trap - INT
}

# ----------------------------------------------------------------------------
# Generic helpers
# ----------------------------------------------------------------------------
has_cmd()           { command -v "$1" >/dev/null 2>&1; }
docker_ready()      { has_cmd docker && docker info >/dev/null 2>&1; }
net_exists()        { docker network inspect "$NETWORK" >/dev/null 2>&1; }
container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
runner_registered() { grep -qs '^\[\[runners\]\]' /etc/gitlab-runner/config.toml /home/*/.gitlab-runner/config.toml; }
renew_enabled()     { [ -f "$RENEW_CRON" ]; }
runner_home()       { getent passwd "$RUNNER_USER" | cut -d: -f6; }

as_runner() { runuser -u "$RUNNER_USER" -- env HOME="$(runner_home)" "$@"; }

valid_domain() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; }
valid_ident()  { [[ "$1" =~ ^[A-Za-z0-9_]{1,64}$ ]]; }

gen_password() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24; }

cfg_get() {
    [ -f "$CONFIG_FILE" ] || return 0
    grep -E "^$1=" "$CONFIG_FILE" | tail -n1 | cut -d= -f2-
}

cfg_set() {
    local tmp
    mkdir -p "$INFRA_DIR"; touch "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
    tmp="$(mktemp)"
    grep -v "^$1=" "$CONFIG_FILE" > "$tmp" || true
    printf '%s=%s\n' "$1" "$2" >> "$tmp"
    cat "$tmp" > "$CONFIG_FILE"; rm -f "$tmp"
}

cfg_unset() {
    [ -f "$CONFIG_FILE" ] || return 0
    local tmp; tmp="$(mktemp)"
    grep -v "^$1=" "$CONFIG_FILE" > "$tmp" || true
    cat "$tmp" > "$CONFIG_FILE"; rm -f "$tmp"
}

# Escape a value for use inside a single-quoted SQL string
sql_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\'/\\\'}"
    printf '%s' "$s"
}

# Wrap a value in double quotes for a Laravel .env file
env_quote() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"$]/\\&/g')"; }

# env_get FILE KEY
env_get() {
    [ -f "$1" ] || return 0
    grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'
}

# env_set FILE KEY VALUE  (replaces an active line, else a commented one, else appends)
env_set() {
    local file="$1" key="$2" value="$3" tmp pattern
    tmp="$(mktemp)"
    if grep -qE "^${key}=" "$file" 2>/dev/null; then pattern="^${key}="; else pattern="^[#[:space:]]*${key}="; fi
    NEWVAL="$value" awk -v pat="$pattern" -v k="$key" '
        BEGIN { done = 0 }
        { if (!done && $0 ~ pat) { print k "=" ENVIRON["NEWVAL"]; done = 1 } else print }
        END { if (!done) print k "=" ENVIRON["NEWVAL"] }
    ' "$file" > "$tmp" && cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Run SQL (from stdin) as root inside the central MariaDB container.
# The root password never leaves the container, so it is not visible in "ps".
db_sql() {
    docker exec -i "$DB_CONTAINER" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot -N -B'
}

# ----------------------------------------------------------------------------
# Status and "recommended next step" engine
# ----------------------------------------------------------------------------
project_count() {
    find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env 2>/dev/null | wc -l
}

# Three-state detection: missing / stopped / ready
docker_state() {
    has_cmd docker || { echo missing; return; }
    if docker info >/dev/null 2>&1; then echo ready; else echo stopped; fi
}

container_state() {
    docker_ready || { echo unknown; return; }
    if container_running "$1"; then echo running
    elif docker inspect "$1" >/dev/null 2>&1; then echo stopped
    else echo missing; fi
}

# badge KIND TEXT -> colored "[ TEXT ]"   (KIND: good | warn | bad)
badge() {
    local color
    case "$1" in good) color="$C_GREEN" ;; warn) color="$C_YELLOW" ;; dim) color="$C_DIM" ;; *) color="$C_RED" ;; esac
    printf '%s[ %-14s ]%s' "$color" "$2" "$C_RESET"
}

status_row() { printf '  %-20s %s  %s%s%s\n' "$1" "$(badge "$2" "$3")" "$C_DIM" "${4:-}" "$C_RESET"; }

pma_status_row() {
    local d; d="$(cfg_get PMA_DOMAIN || true)"
    if [ -z "$d" ]; then
        status_row "phpMyAdmin" dim "NOT SET UP" "optional: Shared Services -> phpMyAdmin"
    elif container_running "$PMA_CONTAINER"; then
        status_row "phpMyAdmin" warn "OPEN" "public at https://$d - stop it when you are done"
    else
        status_row "phpMyAdmin" good "CLOSED" "https://$d (stopped, not reachable)"
    fi
}

container_row() {
    case "$(container_state "$2")" in
        running) status_row "$1" good "RUNNING" "$2" ;;
        stopped) status_row "$1" warn "STOPPED" "start it: docker start $2" ;;
        missing) status_row "$1" bad  "NOT INSTALLED" ;;
        *)       status_row "$1" warn "UNKNOWN" "needs Docker" ;;
    esac
}

suggest_next() {
    case "$(docker_state)" in
        missing) echo "Choose 1) Prepare Server -> Docker (or option A to do everything)"; return ;;
        stopped) echo "Docker is installed but not running: systemctl start docker"; return ;;
    esac
    if [ "$(disk_pct || true)" -ge 90 ] 2>/dev/null; then echo "The disk is almost full: choose 5) Manage Projects -> Disk usage and cleanup"; return; fi
    if ! net_exists;            then echo "Choose 1) Prepare Server -> Shared network"; return; fi
    if ! has_cmd gitlab-runner; then echo "Choose 1) Prepare Server -> Install GitLab Runner"; return; fi
    if ! runner_registered;     then echo "Choose 1) Prepare Server -> Register GitLab Runner"; return; fi
    case "$(container_state "$NGINX_CONTAINER")" in
        stopped) echo "nginx is stopped: docker start $NGINX_CONTAINER"; return ;;
        missing) echo "Choose 2) Shared Services -> Install nginx"; return ;;
    esac
    case "$(container_state "$DB_CONTAINER")" in
        stopped) echo "MariaDB is stopped: docker start $DB_CONTAINER"; return ;;
        missing) echo "Choose 2) Shared Services -> Install MariaDB"; return ;;
    esac
    if ! renew_enabled;                  then echo "Choose 2) Shared Services -> Enable SSL auto-renew"; return; fi
    if [ "$(project_count)" -eq 0 ];     then echo "Choose 3) Generate Project Files, then 4) Deploy New Project"; return; fi
    if ! bk_enabled;                     then echo "Choose 6) Backups -> set up automatic, encrypted backups"; return; fi
    echo "Choose 4) to deploy another project, or 5) to manage existing ones"
}

show_status() {
    printf '%sServer status%s\n' "$C_BOLD" "$C_RESET"
    case "$(docker_state)" in
        ready)   status_row "Docker engine" good "READY" ;;
        stopped) status_row "Docker engine" warn "STOPPED" "installed but not running: systemctl start docker" ;;
        *)       status_row "Docker engine" bad  "NOT INSTALLED" ;;
    esac
    if docker_ready; then
        if net_exists; then status_row "Shared network" good "READY" "$NETWORK"
        else status_row "Shared network" bad "MISSING" "$NETWORK"; fi
    else
        status_row "Shared network" warn "UNKNOWN" "needs Docker"
    fi
    if has_cmd gitlab-runner; then
        if runner_registered; then status_row "GitLab Runner" good "REGISTERED"
        else status_row "GitLab Runner" warn "NOT REGISTERED" "installed, but no runner is registered yet"; fi
    else
        status_row "GitLab Runner" bad "NOT INSTALLED"
    fi
    container_row "nginx container" "$NGINX_CONTAINER"
    container_row "MariaDB container" "$DB_CONTAINER"
    if renew_enabled; then status_row "SSL auto-renew" good "ENABLED"; else status_row "SSL auto-renew" warn "DISABLED"; fi
    pma_status_row
    bk_status_row
    disk_row
    printf '  %-20s %s\n' "Deployed projects" "$(project_count)"
    printf '\n%sRecommended next step:%s %s\n' "$C_YELLOW" "$C_RESET" "$(suggest_next)"
}

require_stack() {
    local missing=0
    if ! docker_ready;                         then err "Docker is not ready.            → Main menu 1) Prepare Server"; missing=1; fi
    if docker_ready && ! net_exists;           then err "Network '$NETWORK' is missing.  → Main menu 1) Prepare Server"; missing=1; fi
    if ! id "$RUNNER_USER" >/dev/null 2>&1;    then err "GitLab Runner is not installed. → Main menu 1) Prepare Server"; missing=1; fi
    if docker_ready && ! container_running "$NGINX_CONTAINER"; then err "nginx container is not running. → Main menu 2) Shared Services"; missing=1; fi
    if docker_ready && ! container_running "$DB_CONTAINER";    then err "MariaDB container is not running. → Main menu 2) Shared Services"; missing=1; fi
    [ "$missing" -eq 0 ]
}

# ============================================================================
# PART 1 — PREPARE SERVER
# ============================================================================

step_essentials() {
    section "Update system and install essential tools"
    explain "Runs apt update and installs: curl, git, unzip, nano, openssl, cron, ca-certificates."
    export DEBIAN_FRONTEND=noninteractive
    if apt-get update -y && apt-get install -y curl git unzip nano ca-certificates openssl cron; then
        systemctl enable --now cron >/dev/null 2>&1 || true
        ok "Essential tools installed."
        next_steps "Install Docker (Prepare Server → Docker)."
    else
        err "apt failed. Check your internet connection and try again."
        return 1
    fi
}

step_docker() {
    section "Install Docker + Compose plugin"
    explain "Uses the official installer from get.docker.com. Skipped if Docker already exists."
    if has_cmd docker; then
        ok "Docker is already installed ($(docker --version))."
    else
        info "Installing Docker..."
        if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh; then
            rm -f /tmp/get-docker.sh
            ok "Docker installed."
        else
            err "Docker installation failed."
            return 1
        fi
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
    if docker compose version >/dev/null 2>&1; then
        ok "Docker Compose plugin is available ($(docker compose version --short))."
    else
        info "Installing docker-compose-plugin..."
        apt-get install -y docker-compose-plugin || { err "Could not install the compose plugin."; return 1; }
    fi
    next_steps "Create the shared network (Prepare Server → Shared network)."
}

step_network() {
    section "Create shared Docker network '$NETWORK'"
    explain "nginx, MariaDB and every project container join this network, so they can reach each other by container name."
    docker_ready || { err "Docker is not ready. Install Docker first."; return 1; }
    if net_exists; then
        ok "Network '$NETWORK' already exists."
    else
        docker network create "$NETWORK" >/dev/null && ok "Network '$NETWORK' created." || return 1
    fi
    next_steps "Install GitLab Runner (Prepare Server → Install GitLab Runner)."
}

step_runner_install() {
    section "Install GitLab Runner"
    explain "Adds GitLab's package repository and installs gitlab-runner (the program that executes your CI/CD jobs)."
    if has_cmd gitlab-runner; then
        ok "GitLab Runner is already installed."
    else
        info "Installing GitLab Runner..."
        if curl -fsSL "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | bash \
            && apt-get install -y gitlab-runner; then
            ok "GitLab Runner installed."
        else
            err "GitLab Runner installation failed."
            return 1
        fi
    fi
    next_steps "Register the runner (Prepare Server → Register GitLab Runner)."
}

step_runner_register() {
    section "Register GitLab Runner"
    has_cmd gitlab-runner || { err "GitLab Runner is not installed yet."; return 1; }
    if runner_registered; then
        ok "A runner is already registered on this server."
        confirm "Register another one?" n || { next_steps "Continue with Prepare Server → Runner access."; return 0; }
    fi
    explain \
        "First create the runner in GitLab (GitLab now uses 'authentication tokens'):" \
        "  1. Open your GitLab project → Settings → CI/CD → Runners → 'New project runner'." \
        "  2. Tags: enter a tag such as 'production' (remember it, the pipeline file uses it)." \
        "  3. Click 'Create runner' and copy the token (it starts with glrt-)."
    local url token desc
    ask "GitLab URL" "https://gitlab.com/" url
    ask_secret "Runner authentication token (glrt-...)" token
    [ -n "$token" ] || { err "Token is empty."; return 1; }
    [[ "$token" == glrt-* ]] || warn "Token does not start with 'glrt-'. Legacy tokens may not work on recent GitLab versions."
    ask "Runner description" "$(hostname)-runner" desc
    if gitlab-runner register --non-interactive --url "$url" --token "$token" --executor shell --description "$desc"; then
        ok "Runner registered."
        systemctl restart gitlab-runner >/dev/null 2>&1 || true
        next_steps "Configure runner access (Prepare Server → Runner access)."
    else
        err "Registration failed. Check the URL and the token."
        return 1
    fi
}

# Generate the runner's SSH key if needed and trust a git host
ensure_runner_key() {
    local home grp
    home="$(runner_home)"; grp="$(id -gn "$RUNNER_USER")"
    install -d -m 700 -o "$RUNNER_USER" -g "$grp" "$home/.ssh"
    if [ ! -f "$home/.ssh/id_ed25519" ]; then
        as_runner ssh-keygen -t ed25519 -N "" -C "${RUNNER_USER}@$(hostname)" -f "$home/.ssh/id_ed25519" >/dev/null
        ok "SSH key created for user '$RUNNER_USER'."
    fi
}

trust_git_host() {
    local host="$1" home
    home="$(runner_home)"
    touch "$home/.ssh/known_hosts"; chown "$RUNNER_USER" "$home/.ssh/known_hosts"
    if ! ssh-keygen -F "$host" -f "$home/.ssh/known_hosts" >/dev/null 2>&1; then
        ssh-keyscan -H "$host" >> "$home/.ssh/known_hosts" 2>/dev/null
        chown "$RUNNER_USER" "$home/.ssh/known_hosts"
    fi
}

show_runner_pubkey() {
    printf '\n%s%s%s\n' "$C_GREEN" "$(cat "$(runner_home)/.ssh/id_ed25519.pub")" "$C_RESET"
}

repo_host() { sed -E 's#^(ssh://)?([^@]+@)?([^:/]+).*#\3#' <<<"$1"; }

step_runner_access() {
    section "Runner access: Docker permission + SSH deploy key"
    explain \
        "• Adds user '$RUNNER_USER' to the docker group (needed so pipeline jobs can run docker)." \
        "• Creates an SSH key for '$RUNNER_USER' (used to 'git pull' your private repositories)." \
        "• Removes ~/.bash_logout, a known cause of failing jobs on Ubuntu."
    id "$RUNNER_USER" >/dev/null 2>&1 || { err "User '$RUNNER_USER' not found. Install GitLab Runner first."; return 1; }
    usermod -aG docker "$RUNNER_USER" && ok "Runner added to docker group."
    rm -f "$(runner_home)/.bash_logout"
    ensure_runner_key
    trust_git_host "gitlab.com"
    systemctl restart gitlab-runner >/dev/null 2>&1 || true
    ok "Runner service restarted."
    info "Public key of the runner (you will add it to each GitLab project as a read-only Deploy Key):"
    show_runner_pubkey
    next_steps \
        "Optional: firewall and swap (next two items in this menu)." \
        "Then go to main menu 2) Shared Services."
}

step_firewall() {
    section "Firewall (UFW) — optional"
    explain "Allows only SSH, HTTP (80) and HTTPS (443). Everything else incoming is blocked."
    local ssh_port
    ssh_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"; ssh_port="${ssh_port:-22}"
    warn "Make sure SSH port ${ssh_port} is the one you use to log in, otherwise you could lock yourself out."
    confirm "Enable UFW with ports ${ssh_port}, 80, 443?" n || { info "Skipped."; return 0; }
    has_cmd ufw || apt-get install -y ufw
    ufw allow "${ssh_port}/tcp" && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable
    ok "Firewall enabled."
}

step_swap() {
    section "Swap file — optional"
    explain "Small servers can run out of RAM during 'composer install'. A swap file prevents crashes."
    if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then ok "Swap already active."; return 0; fi
    confirm "Create a swap file?" y || { info "Skipped."; return 0; }
    local size; ask "Swap size" "2G" size
    fallocate -l "$size" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile \
        && { grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab; } \
        && ok "Swap of $size enabled." || err "Could not create swap."
}

run_all_prepare() {
    step_essentials     || return 1
    step_docker         || return 1
    step_network        || return 1
    step_runner_install || return 1
    step_runner_register
    step_runner_access
    step_firewall
    step_swap
    next_steps "Go to main menu 2) Shared Services."
}

# ============================================================================
# PART 2 — SHARED SERVICES (nginx, MariaDB, SSL auto-renew)
# ============================================================================

step_nginx_install() {
    section "Install shared nginx container"
    explain \
        "One nginx container receives ALL web traffic (ports 80/443) and forwards each domain" \
        "to the right project container through the '$NETWORK' network."
    docker_ready && net_exists || { err "Docker/network not ready. Use main menu 1) first."; return 1; }
    if container_running "$NGINX_CONTAINER"; then ok "nginx container is already running."; return 0; fi

    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq ':(80|443)$'; then
        err "Port 80 or 443 is already in use on this server:"
        ss -ltnp | grep -E ':(80|443)\s' || true
        explain "Stop that service first (e.g. 'systemctl disable --now apache2 nginx'), then run this again."
        return 1
    fi

    mkdir -p "$NGINX_DIR/conf.d" "$NGINX_DIR/certbot-www" "$NGINX_DIR/letsencrypt" "$PROJECTS_DIR"
    chmod 755 "$PROJECTS_DIR"

    if [ ! -f "$NGINX_DIR/conf.d/00-default.conf" ]; then
        cat > "$NGINX_DIR/conf.d/00-default.conf" <<'EOF'
# Global settings + catch-all server (unknown domains get no answer)
server_tokens off;
gzip on;
gzip_types text/css application/javascript application/json image/svg+xml text/plain text/xml;

server {
    listen 80 default_server;
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 444; }
}
EOF
    fi

    cat > "$NGINX_DIR/docker-compose.yml" <<EOF
services:
  nginx:
    image: ${NGINX_IMAGE}
    container_name: ${NGINX_CONTAINER}
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./certbot-www:/var/www/certbot:ro
      - ./letsencrypt:/etc/letsencrypt:ro
      - ${PROJECTS_DIR}:${PROJECTS_DIR}:ro
    networks:
      - ${NETWORK}

networks:
  ${NETWORK}:
    external: true
EOF
    if docker compose -f "$NGINX_DIR/docker-compose.yml" up -d && container_running "$NGINX_CONTAINER"; then
        ok "nginx is running."
        explain "Config folder: $NGINX_DIR/conf.d   (one .conf file per domain, managed by this script)"
        next_steps "Install MariaDB (Shared Services → Install MariaDB)."
    else
        err "nginx failed to start. See: docker logs $NGINX_CONTAINER"
        return 1
    fi
}

step_mariadb_install() {
    section "Install shared MariaDB container"
    explain \
        "One MariaDB container stores the databases of ALL projects (saves RAM and disk)." \
        "It is NOT exposed to the internet; only containers on '$NETWORK' can reach it."
    docker_ready && net_exists || { err "Docker/network not ready. Use main menu 1) first."; return 1; }
    if container_running "$DB_CONTAINER"; then ok "MariaDB container is already running."; return 0; fi

    local pass suggested
    suggested="$(gen_password)"
    explain "Allowed root password characters: letters, digits and . _ @ % + = : , -   (min 12 characters)"
    while true; do
        ask "MariaDB root password (Enter = use generated one)" "$suggested" pass
        [[ "$pass" =~ ^[A-Za-z0-9._@%+=:,-]{12,}$ ]] && break
        err "Password not allowed. Use at least 12 characters from the allowed set."
    done

    mkdir -p "$DB_DIR"
    printf 'MARIADB_ROOT_PASSWORD=%s\n' "$pass" > "$DB_DIR/.env"
    chmod 600 "$DB_DIR/.env"

    cat > "$DB_DIR/docker-compose.yml" <<EOF
services:
  mariadb:
    image: ${MARIADB_IMAGE}
    container_name: ${DB_CONTAINER}
    restart: always
    environment:
      MARIADB_ROOT_PASSWORD: \${MARIADB_ROOT_PASSWORD}
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --innodb-buffer-pool-size=128M
      - --max-connections=60
    volumes:
      - mariadb_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - ${NETWORK}

networks:
  ${NETWORK}:
    external: true

volumes:
  mariadb_data:
EOF
    docker compose -f "$DB_DIR/docker-compose.yml" up -d || { err "MariaDB failed to start."; return 1; }
    info "Waiting for MariaDB to become healthy..."
    local i status
    for i in $(seq 1 40); do
        status="$(docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER" 2>/dev/null)"
        [ "$status" = "healthy" ] && break
        sleep 3
    done
    if [ "${status:-}" = "healthy" ]; then
        ok "MariaDB is healthy."
        warn "Root password: $pass"
        explain "Saved (root-only) in: $DB_DIR/.env  — you normally never need it; this script uses it internally."
        next_steps "Enable SSL auto-renew (Shared Services → Enable SSL auto-renew)."
    else
        err "MariaDB is not healthy yet. Check: docker logs $DB_CONTAINER"
        return 1
    fi
}

step_renew_enable() {
    section "Enable automatic SSL renewal"
    explain \
        "Creates a daily job (03:17) that renews certificates expiring in less than 30 days" \
        "and reloads nginx. Running it daily is safe; certbot skips certificates that are not due."
    [ -d "$NGINX_DIR" ] || { err "Install nginx first."; return 1; }
    cat > "$RENEW_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -u
echo "[$(date -Is)] Checking certificates..."
docker run --rm \
    -v "__NGINX_DIR__/letsencrypt:/etc/letsencrypt" \
    -v "__NGINX_DIR__/certbot-www:/var/www/certbot" \
    __CERTBOT_IMAGE__ renew --quiet
rc=$?
if docker exec __NGINX_CONTAINER__ nginx -s reload >/dev/null 2>&1; then echo "nginx reloaded"; fi
echo "[$(date -Is)] Finished (certbot exit code: $rc)"
exit $rc
EOF
    sed -i -e "s|__NGINX_DIR__|$NGINX_DIR|g" -e "s|__CERTBOT_IMAGE__|$CERTBOT_IMAGE|g" \
           -e "s|__NGINX_CONTAINER__|$NGINX_CONTAINER|g" "$RENEW_SCRIPT"
    chmod 755 "$RENEW_SCRIPT"
    printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n17 3 * * * root %s >> %s 2>&1\n' \
        "$RENEW_SCRIPT" "$RENEW_LOG" > "$RENEW_CRON"
    chmod 644 "$RENEW_CRON"
    ok "Auto-renew enabled. Log file: $RENEW_LOG"
    next_steps "Shared services are ready. Go to main menu 3) / 4) to prepare and deploy a project."
}

step_renew_disable() {
    rm -f "$RENEW_CRON" && ok "Auto-renew disabled."
}

services_status() {
    section "Shared services status"
    docker ps -a --filter "name=$NGINX_CONTAINER" --filter "name=$DB_CONTAINER" \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    echo ""
    printf 'Network %s: %s\n' "$NETWORK" "$(net_exists && echo present || echo MISSING)"
    printf 'SSL auto-renew: %s\n' "$(renew_enabled && echo enabled || echo disabled)"
}

run_all_services() {
    step_nginx_install   || return 1
    step_mariadb_install || return 1
    step_renew_enable
}

# ============================================================================
# PROJECT FILE TEMPLATES (these files live INSIDE your project repository)
# ============================================================================

tpl_dockerfile() {
    cat <<'EOF'
# Generated by HiDeploy — safe to edit, commit it in your repo.
# The image only contains PHP + tools. Your code stays on the server disk (bind mount).
FROM php:8.3-fpm-alpine

# Same UID/GID as the server's gitlab-runner user => no permission conflicts, no chmod 777
ARG APP_UID=1000
ARG APP_GID=1000

RUN apk add --no-cache git curl zip unzip supervisor \
        libpng-dev libjpeg-turbo-dev freetype-dev libzip-dev oniguruma-dev libxml2-dev icu-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql mbstring exif pcntl bcmath gd zip intl opcache

RUN set -eu; \
    u="$(getent passwd "${APP_UID}" | cut -d: -f1 || true)"; [ -z "$u" ] || deluser "$u"; \
    g="$(getent group "${APP_GID}" | cut -d: -f1 || true)"; [ -z "$g" ] || delgroup "$g"; \
    addgroup -g "${APP_GID}" app; \
    adduser -D -u "${APP_UID}" -G app app

# PHP-FPM pool. The values come from environment variables: the defaults below are low-memory friendly and the
# server can change them (main menu 7 -> Performance tuning) through docker-compose.prod.yml and .deploy.env.
ENV FPM_PM=ondemand FPM_MAX_CHILDREN=5 FPM_START_SERVERS=2 FPM_MIN_SPARE=1 FPM_MAX_SPARE=3 FPM_IDLE_TIMEOUT=10s FPM_MAX_REQUESTS=500
RUN printf '%s\n' \
      '[www]' \
      'user = app' \
      'group = app' \
      'pm = ${FPM_PM}' \
      'pm.max_children = ${FPM_MAX_CHILDREN}' \
      'pm.start_servers = ${FPM_START_SERVERS}' \
      'pm.min_spare_servers = ${FPM_MIN_SPARE}' \
      'pm.max_spare_servers = ${FPM_MAX_SPARE}' \
      'pm.process_idle_timeout = ${FPM_IDLE_TIMEOUT}' \
      'pm.max_requests = ${FPM_MAX_REQUESTS}' \
      'php_admin_value[memory_limit] = 256M' \
      'php_admin_value[upload_max_filesize] = 50M' \
      'php_admin_value[post_max_size] = 50M' \
    > /usr/local/etc/php-fpm.d/zz-laravel.conf \
 && printf '%s\n' \
      'expose_php = 0' \
      'opcache.enable = 1' \
      'opcache.memory_consumption = 64' \
      'opcache.validate_timestamps = 1' \
      'opcache.revalidate_freq = 10' \
    > /usr/local/etc/php/conf.d/zz-laravel.ini

# One container runs: php-fpm + queue worker + scheduler (supervisor keeps them alive)
RUN printf '%s\n' \
      '[supervisord]' \
      'nodaemon=true' \
      'logfile=/dev/null' \
      'logfile_maxbytes=0' \
      'pidfile=/tmp/supervisord.pid' \
      '' \
      '[program:php-fpm]' \
      'command=php-fpm' \
      'autorestart=true' \
      'redirect_stderr=true' \
      'stdout_logfile=/dev/stdout' \
      'stdout_logfile_maxbytes=0' \
      '' \
      '[program:queue]' \
      'command=sh -c "until [ -f vendor/autoload.php ] && [ -f .env ]; do sleep 5; done; exec php artisan queue:work --sleep=3 --tries=3 --max-time=3600"' \
      'directory=%(ENV_APP_PATH)s' \
      'user=app' \
      'autorestart=true' \
      'stopwaitsecs=60' \
      'redirect_stderr=true' \
      'stdout_logfile=/dev/stdout' \
      'stdout_logfile_maxbytes=0' \
      '' \
      '[program:scheduler]' \
      'command=sh -c "until [ -f vendor/autoload.php ] && [ -f .env ]; do sleep 5; done; exec php artisan schedule:work"' \
      'directory=%(ENV_APP_PATH)s' \
      'user=app' \
      'autorestart=true' \
      'redirect_stderr=true' \
      'stdout_logfile=/dev/stdout' \
      'stdout_logfile_maxbytes=0' \
    > /etc/supervisord-app.conf

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

CMD ["supervisord", "-c", "/etc/supervisord-app.conf"]
EOF
}

tpl_compose() {
    cat <<'EOF'
# Generated by HiDeploy — generic file, identical for every project.
# Server-specific values come from ".deploy.env" (lives on the server, not in git).
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        APP_UID: ${APP_UID:?APP_UID missing in .deploy.env}
        APP_GID: ${APP_GID:?APP_GID missing in .deploy.env}
    container_name: ${CONTAINER_NAME:?CONTAINER_NAME missing in .deploy.env}
    restart: unless-stopped
    init: true
    working_dir: ${APP_PATH:?APP_PATH missing in .deploy.env}
    environment:
      APP_PATH: ${APP_PATH}
      FPM_PM: ${FPM_PM:-ondemand}
      FPM_MAX_CHILDREN: ${FPM_MAX_CHILDREN:-5}
      FPM_START_SERVERS: ${FPM_START_SERVERS:-2}
      FPM_MIN_SPARE: ${FPM_MIN_SPARE:-1}
      FPM_MAX_SPARE: ${FPM_MAX_SPARE:-3}
      FPM_IDLE_TIMEOUT: ${FPM_IDLE_TIMEOUT:-10s}
      FPM_MAX_REQUESTS: ${FPM_MAX_REQUESTS:-500}
    volumes:
      - ${APP_PATH}:${APP_PATH}
    networks:
      - web_network
    mem_limit: ${MEM_LIMIT:-512m}
    stop_grace_period: 60s

networks:
  web_network:
    external: true
EOF
}

tpl_dockerignore() { printf '# The image contains no project code, so send nothing to the Docker build.\n*\n'; }

# Frontend build snippet. Single source of truth: used by the pipeline file AND by this script.
# It expects APP_PATH, APP_UID, APP_GID, FRONTEND_BUILD and (optionally) NODE_IMAGE in the environment,
# and the current directory to be the project folder. Package manager is detected from the lock file.
tpl_frontend_snippet() {
    cat <<'EOF'
if [ "${FRONTEND_BUILD:-no}" = "yes" ]; then
  echo "==> Building frontend assets (temporary Node container)"
  if   [ -f pnpm-lock.yaml ];    then PM_INSTALL="pnpm install --frozen-lockfile";        PM_BUILD="pnpm run build"
  elif [ -f yarn.lock ];         then PM_INSTALL="yarn install --frozen-lockfile";        PM_BUILD="yarn build"
  elif [ -f package-lock.json ]; then PM_INSTALL="npm ci --no-audit --no-fund";           PM_BUILD="npm run build"
  else                                PM_INSTALL="npm install --no-audit --no-fund";      PM_BUILD="npm run build"
  fi
  docker run --rm --user "$APP_UID:$APP_GID" \
    -e HOME=/tmp -e CI=true -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    -e NPM_CONFIG_UPDATE_NOTIFIER=false -e npm_config_store_dir=/tmp/.pnpm-store \
    -v "$APP_PATH:/app" -w /app "${NODE_IMAGE:-node:22-alpine}" \
    sh -c "mkdir -p /tmp/bin && (corepack enable --install-directory /tmp/bin 2>/dev/null || true); export PATH=/tmp/bin:\$PATH; $PM_INSTALL && $PM_BUILD && rm -rf node_modules"
  [ -f public/build/manifest.json ] || echo "WARNING: public/build/manifest.json was not created (check your Vite config)."
fi
EOF
}

tpl_ci() {
    cat <<'EOF'
# Generated by HiDeploy.
# Runs on the production server through the GitLab Runner (shell executor).
stages:
  - deploy

deploy_production:
  stage: deploy
  tags:
    - __TAG__
  resource_group: production
  rules:
    - if: '$CI_COMMIT_BRANCH == "__BRANCH__"'
  variables:
    GIT_STRATEGY: none
    DEPLOY_PATH: "__DEPLOY_PATH__"
  script:
    - |
      set -euo pipefail
      cd "$DEPLOY_PATH"
      set -a; . ./.deploy.env; set +a

      dc()      { docker compose -p "$CONTAINER_NAME" --env-file .deploy.env -f docker-compose.prod.yml "$@"; }
      dexec()   { docker exec -u "$APP_UID:$APP_GID" -w "$APP_PATH" "$CONTAINER_NAME" "$@"; }
      artisan() { dexec php artisan "$@"; }
      record()  {
        echo "$(date -Is) $(git rev-parse --short HEAD 2>/dev/null || echo unknown) $1 $(git log -1 --format=%s 2>/dev/null | tr -d '\r\n' | cut -c1-80)" >> .deploy.history
        tail -n 200 .deploy.history > .deploy.history.tmp && mv .deploy.history.tmp .deploy.history
        grep -qxF ".deploy.history" .git/info/exclude 2>/dev/null || echo ".deploy.history" >> .git/info/exclude
      }

      MAINT=no
      trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo; echo "!! Deployment FAILED."; if [ "$MAINT" = yes ]; then echo "!! The site was left in maintenance mode on purpose (half-updated code can break pages or data)."; fi; echo "!! Fix the problem and push again, or roll back: sudo hideploy -> 5) Manage Projects -> this project -> 13) Deployments -> Roll back."; record failed || true; fi' EXIT

      if [ ! -f storage/framework/down ] && docker exec "$CONTAINER_NAME" true 2>/dev/null && [ -f vendor/autoload.php ]; then
        echo "==> Maintenance mode ON (visitors see a friendly page while the site updates)"
        if artisan down --retry=60 --refresh=15 >/dev/null 2>&1 || artisan down >/dev/null 2>&1; then MAINT=yes; fi
      fi

      echo "==> Updating code"
      git fetch origin "$CI_COMMIT_BRANCH"
      git reset --hard "origin/$CI_COMMIT_BRANCH"

      echo "==> Building and starting container"
      dc up -d --build
      for i in $(seq 1 30); do docker exec "$CONTAINER_NAME" true 2>/dev/null && break; sleep 1; done

      echo "==> Installing dependencies"
      dexec composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist

EOF
    tpl_frontend_snippet | sed 's/^/      /'
    cat <<'EOF'

      if [ "${USE_DATABASE:-yes}" = "yes" ]; then
        echo "==> Migrating database"
        artisan migrate --force
      fi

      echo "==> Refreshing caches"
      artisan optimize:clear
      artisan optimize
      artisan queue:restart

      if [ "$MAINT" = yes ]; then
        artisan up
        echo "==> Maintenance mode OFF"
      fi
      docker image prune -f >/dev/null 2>&1 || true

      echo "==> Health check (informational)"
      curl -s -o /dev/null -w "HTTPS status: %{http_code}\n" -k --max-time 15 \
        --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/up" || true

      record ok
      trap - EXIT
      echo "Deployment finished successfully."
EOF
}

# generate_project_files DIR DOMAIN BRANCH TAG OVERWRITE(yes|no)
generate_project_files() {
    local dir="$1" domain="$2" branch="$3" tag="$4" overwrite="$5" type="${6:-laravel}" pm="${7:-pnpm}" tmp f
    tmp="$(mktemp -d)"
    if [ "$type" = "nextjs" ]; then
        tpl_next_dockerfile "$pm" > "$tmp/Dockerfile"
        tpl_next_compose          > "$tmp/docker-compose.prod.yml"
        tpl_next_dockerignore     > "$tmp/.dockerignore"
        tpl_next_ci | sed -e "s|__TAG__|$tag|g" -e "s|__BRANCH__|$branch|g" \
                          -e "s|__DEPLOY_PATH__|$PROJECTS_DIR/$domain|g" > "$tmp/.gitlab-ci.yml"
    else
        tpl_dockerfile   > "$tmp/Dockerfile"
        tpl_compose      > "$tmp/docker-compose.prod.yml"
        tpl_dockerignore > "$tmp/.dockerignore"
        tpl_ci | sed -e "s|__TAG__|$tag|g" -e "s|__BRANCH__|$branch|g" \
                     -e "s|__DEPLOY_PATH__|$PROJECTS_DIR/$domain|g" > "$tmp/.gitlab-ci.yml"
    fi
    mkdir -p "$dir"
    for f in Dockerfile docker-compose.prod.yml .dockerignore .gitlab-ci.yml; do
        if [ -e "$dir/$f" ] && [ "$overwrite" != "yes" ]; then
            warn "$f already exists — kept as is."
        else
            cp "$tmp/$f" "$dir/$f" && ok "Created $f"
        fi
    done
    rm -rf "$tmp"
}

# validate_project_files DIR DOMAIN  -> prints problems, returns number of problems
validate_project_files() {
    local dir="$1" domain="$2" problems=0 f
    if [ "${3:-laravel}" = "nextjs" ]; then validate_next_files "$dir" "$domain"; return $?; fi
    for f in Dockerfile docker-compose.prod.yml .dockerignore .gitlab-ci.yml; do
        if [ ! -f "$dir/$f" ]; then err "Missing file: $f"; problems=$((problems+1)); fi
    done
    if [ -f "$dir/docker-compose.prod.yml" ]; then
        grep -qE '^  app:' "$dir/docker-compose.prod.yml"          || { err "docker-compose.prod.yml: the service must be named 'app'."; problems=$((problems+1)); }
        grep -q 'web_network' "$dir/docker-compose.prod.yml"       || { err "docker-compose.prod.yml: must join the external network 'web_network'."; problems=$((problems+1)); }
        grep -q 'CONTAINER_NAME' "$dir/docker-compose.prod.yml"    || { err "docker-compose.prod.yml: use container_name: \${CONTAINER_NAME}."; problems=$((problems+1)); }
        grep -q 'APP_PATH' "$dir/docker-compose.prod.yml"          || { err "docker-compose.prod.yml: use \${APP_PATH} for the volume and working_dir."; problems=$((problems+1)); }
        grep -q 'APP_UID' "$dir/docker-compose.prod.yml"           || { err "docker-compose.prod.yml: pass APP_UID/APP_GID as build args."; problems=$((problems+1)); }
    fi
    if [ -f "$dir/Dockerfile" ]; then
        grep -q 'ARG APP_UID' "$dir/Dockerfile"                    || { err "Dockerfile: missing 'ARG APP_UID' / 'ARG APP_GID'."; problems=$((problems+1)); }
        grep -q 'queue:work' "$dir/Dockerfile"                     || warn "Dockerfile: no queue worker found — queued jobs/emails will NOT be processed."
        grep -q 'schedule:work' "$dir/Dockerfile"                  || warn "Dockerfile: no scheduler found — scheduled tasks will NOT run."
        grep -q '9000\|php-fpm' "$dir/Dockerfile"                  || warn "Dockerfile: php-fpm not detected; nginx expects PHP-FPM on port 9000."
    fi
    if [ -f "$dir/.gitlab-ci.yml" ]; then
        grep -q '.deploy.env' "$dir/.gitlab-ci.yml"                || { err ".gitlab-ci.yml: should load .deploy.env on the server."; problems=$((problems+1)); }
        grep -q "$PROJECTS_DIR/$domain" "$dir/.gitlab-ci.yml"      || warn ".gitlab-ci.yml: DEPLOY_PATH is not '$PROJECTS_DIR/$domain'."
        grep -q 'chmod -R 777' "$dir/.gitlab-ci.yml"               && warn ".gitlab-ci.yml contains 'chmod -R 777' — not needed with this setup."
        grep -q 'FRONTEND_BUILD' "$dir/.gitlab-ci.yml"            || warn ".gitlab-ci.yml is an older version (no frontend-build / optional-database support). Regenerate it: main menu 3)."
    fi
    return "$problems"
}

menu_generate_files() {
    clear; banner "3) Generate Project Files" "$C_YELLOW"
    explain \
        "Creates the 4 standard files that must live INSIDE your Laravel project (and be committed to git):" \
        "  Dockerfile, docker-compose.prod.yml, .dockerignore, .gitlab-ci.yml" \
        "They are generic: the same files work for every project. Server-specific values are kept in" \
        "'.deploy.env' on the server, so they never change the files in your repository."
    local domain branch tag outdir ptype="laravel" pm="pnpm" tchoice
    echo " Project type:"
    echo "  1) Laravel (PHP)"
    echo "  2) Next.js (Node)"
    read -r -p "Select [1]: " tchoice
    if [ "$tchoice" = "2" ]; then
        ptype="nextjs"
        explain "Next.js files: a multi-stage Dockerfile (standalone output), docker-compose.prod.yml, .dockerignore and .gitlab-ci.yml."
        while true; do ask "Package manager (pnpm is recommended / npm / yarn)" "pnpm" pm; pm="${pm,,}"; [[ "$pm" =~ ^(pnpm|npm|yarn)$ ]] && break; err "Choose pnpm, npm or yarn."; done
    fi
    while true; do ask "Project domain (e.g. api.example.com)" "" domain; domain="${domain,,}"; valid_domain "$domain" && break; err "Invalid domain."; done
    ask "Git branch that triggers deployment" "main" branch
    ask "GitLab runner tag" "$(cfg_get RUNNER_TAG || true)" tag
    tag="${tag:-production}"
    cfg_set RUNNER_TAG "$tag"
    outdir="$TEMPLATES_DIR/$domain"
    echo ""
    generate_project_files "$outdir" "$domain" "$branch" "$tag" yes "$ptype" "$pm"
    local ip; ip="$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || echo 'SERVER_IP')"
    echo ""
    ok "Files are in: $outdir"
    info "Copy them into your project on YOUR computer (run this on your computer, inside the project folder):"
    printf '\n   %sscp -r root@%s:%s/. .%s\n\n' "$C_GREEN" "$ip" "$outdir" "$C_RESET"
    confirm "Print the files here so you can copy/paste them instead?" n && {
        local f; for f in Dockerfile docker-compose.prod.yml .dockerignore .gitlab-ci.yml; do
            printf '\n%s──────── %s ────────%s\n' "$C_MAGENTA" "$f" "$C_RESET"; cat "$outdir/$f"
        done
    }
    next_steps \
        "On your computer: git add Dockerfile docker-compose.prod.yml .dockerignore .gitlab-ci.yml" \
        "Then: git commit -m 'Add deployment files' && git push origin $branch" \
        "Then come back and choose 4) Deploy New Project."
    pause
}

# ============================================================================
# NGINX VHOST + SSL
# ============================================================================

tpl_vhost_common() {
    cat <<'EOF'
    root __ROOT__;
    index index.php;
    client_max_body_size 50M;

    # Docker's internal DNS. Using a variable below means nginx still starts
    # (and other sites keep working) even if this project's container is stopped.
    resolver 127.0.0.11 valid=10s ipv6=off;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Shown by nginx itself when the project container is restarting during a deployment
    error_page 502 504 =503 /hideploy-maintenance.html;
    location = /hideploy-maintenance.html {
        internal;
        root /etc/nginx/conf.d;
        add_header Retry-After 30 always;
        add_header Cache-Control "no-store" always;
    }

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /index.php {
        set $php_upstream "__CONTAINER__:9000";
        include fastcgi_params;
        fastcgi_pass $php_upstream;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        fastcgi_read_timeout 60s;
    }

    location ~ \.php$ { return 404; }

    location ~ /\.(?!well-known) { deny all; }
EOF
}

# write_vhost DOMAIN CONTAINER MODE(http|https)
write_vhost() {
    local domain="$1" container="$2" mode="$3" out="$NGINX_DIR/conf.d/$1.conf" root
    if [ "${4:-laravel}" = "pma" ]; then write_pma_vhost "$domain" "$mode"; return; fi
    if [ "${4:-laravel}" = "nextjs" ]; then write_next_vhost "$domain" "$container" "$mode"; return; fi
    ensure_maintenance_page
    root="$PROJECTS_DIR/$domain/public"
    {
        if [ "$mode" = "http" ]; then
            echo "server {"
            echo "    listen 80;"
            echo "    server_name __DOMAIN__;"
            perf_server_extras http
            tpl_vhost_common
            perf_laravel_static
            echo "}"
        else
            echo "server {"
            echo "    listen 80;"
            echo "    server_name __DOMAIN__;"
            echo "    location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; }"
            echo "    location / { return 301 https://\$host\$request_uri; }"
            echo "}"
            echo ""
            echo "server {"
            echo "    listen 443 ssl;"
            echo "    http2 on;"
            echo "    server_name __DOMAIN__;"
            echo "    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;"
            echo "    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;"
            echo "    ssl_protocols TLSv1.2 TLSv1.3;"
            echo "    ssl_session_cache shared:SSL:10m;"
            perf_server_extras https
            tpl_vhost_common
            perf_laravel_static
            echo "}"
        fi
    } | sed -e "s|__DOMAIN__|$domain|g" -e "s|__CONTAINER__|$container|g" -e "s|__ROOT__|$root|g" > "$out"
}

nginx_test_reload() {
    local out
    if out="$(docker exec "$NGINX_CONTAINER" nginx -t 2>&1)"; then
        docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null 2>&1
        return 0
    fi
    printf '%s\n' "$out"
    return 1
}

# apply_vhost DOMAIN CONTAINER MODE — writes, tests and reloads; restores the old file on failure
apply_vhost() {
    local domain="$1" container="$2" mode="$3" conf="$NGINX_DIR/conf.d/$1.conf" backup=""
    if [ -f "$conf" ]; then backup="$(mktemp)"; cp "$conf" "$backup"; fi
    write_vhost "$domain" "$container" "$mode" "${4:-laravel}"
    if nginx_test_reload; then
        [ -n "$backup" ] && rm -f "$backup"
        return 0
    fi
    err "nginx rejected the new configuration; restoring the previous state."
    if [ -n "$backup" ]; then cp "$backup" "$conf"; rm -f "$backup"; else rm -f "$conf"; fi
    nginx_test_reload >/dev/null 2>&1 || true
    return 1
}

server_ip() { curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null; }

dns_check() {
    local domain="$1" dns_ip my_ip
    dns_ip="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}')"
    my_ip="$(server_ip)"
    printf '  Domain %s resolves to: %s\n  This server public IP:  %s\n' "$domain" "${dns_ip:-<nothing>}" "${my_ip:-<unknown>}"
    [ -n "$dns_ip" ] && [ -n "$my_ip" ] && [ "$dns_ip" = "$my_ip" ]
}

certbot_run() {
    docker run --rm \
        -v "$NGINX_DIR/letsencrypt:/etc/letsencrypt" \
        -v "$NGINX_DIR/certbot-www:/var/www/certbot" \
        "$CERTBOT_IMAGE" "$@"
}

cert_days() {
    local f="$NGINX_DIR/letsencrypt/live/$1/fullchain.pem" end
    [ -f "$f" ] || return 0
    end="$(openssl x509 -enddate -noout -in "$f" | cut -d= -f2)"
    echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}

# ssl_setup DOMAIN CONTAINER — issue a certificate and switch the vhost to HTTPS
ssl_setup() {
    local domain="$1" container="$2" kind="${3:-laravel}" email
    section "SSL certificate for $domain"
    explain \
        "Let's Encrypt will request http://$domain/.well-known/acme-challenge/... (served by nginx)." \
        "nginx stays online the whole time; no ports need to be freed."
    container_running "$NGINX_CONTAINER" || { err "nginx container is not running."; return 1; }
    [ -f "$NGINX_DIR/conf.d/$domain.conf" ] || apply_vhost "$domain" "$container" http "$kind" || return 1
    if ! dns_check "$domain"; then
        warn "DNS does not point to this server. If you use Cloudflare, switch the record to 'DNS only' (grey cloud) while issuing."
        confirm "Try anyway?" n || return 1
    fi
    ask "Email for expiry notices" "$(cfg_get ADMIN_EMAIL || true)" email
    [ -n "$email" ] || { err "Email is required."; return 1; }
    cfg_set ADMIN_EMAIL "$email"
    if certbot_run certonly --webroot -w /var/www/certbot -d "$domain" \
            --email "$email" --agree-tos --no-eff-email --non-interactive; then
        apply_vhost "$domain" "$container" https "$kind" || return 1
        ok "HTTPS enabled for $domain (certificate valid for $(cert_days "$domain") days)."
        renew_enabled || warn "Auto-renew is OFF. Enable it: Shared Services → Enable SSL auto-renew."
        return 0
    fi
    err "Certificate request failed. Common causes: DNS not pointing here, port 80 blocked by a firewall, or too many requests."
    return 1
}

# ============================================================================
# SSL MANAGEMENT MENU
# ============================================================================

ssl_list() {
    section "Installed certificates"
    local d name f end end_ts days color found=0 now
    now="$(date +%s)"
    printf '%-36s %-12s %-10s\n' "DOMAIN" "EXPIRES" "DAYS LEFT"
    for d in "$NGINX_DIR"/letsencrypt/live/*/; do
        [ -d "$d" ] || continue
        f="${d}fullchain.pem"; [ -f "$f" ] || continue
        name="$(basename "$d")"
        end="$(openssl x509 -enddate -noout -in "$f" | cut -d= -f2)"
        end_ts="$(date -d "$end" +%s)"
        days=$(( (end_ts - now) / 86400 ))
        if [ "$days" -lt 15 ]; then color="$C_RED"; elif [ "$days" -lt 30 ]; then color="$C_YELLOW"; else color="$C_GREEN"; fi
        printf '%-36s %-12s %s%-10s%s\n' "$name" "$(date -d "$end" +%F)" "$color" "$days" "$C_RESET"
        printf '%s    files: %s%s\n' "$C_DIM" "${d%/}" "$C_RESET"
        found=1
    done
    [ "$found" -eq 1 ] || info "No certificates yet."
    echo ""
    printf 'Auto-renew: %s\n' "$(renew_enabled && echo "ENABLED (daily 03:17, log: $RENEW_LOG)" || echo "DISABLED")"
}

menu_ssl() {
    local c domain
    while true; do
        clear; banner "SSL Management" "$C_BLUE"
        echo " 1) List certificates (expiry date, days left, file paths)"
        echo " 2) Renew all certificates that are due now"
        echo " 3) Force-renew ONE domain"
        echo " 4) Test renewal (dry run, changes nothing)"
        echo " 5) Auto-renew status / enable / disable"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) ssl_list; pause ;;
            2) certbot_run renew && docker exec "$NGINX_CONTAINER" nginx -s reload && ok "Done (nginx reloaded)."; pause ;;
            3) ask "Domain" "" domain
               if [ -d "$NGINX_DIR/letsencrypt/live/$domain" ]; then
                   warn "Let's Encrypt limits repeated issuance per domain; use this only when needed."
                   confirm "Force renew $domain now?" n && certbot_run renew --cert-name "$domain" --force-renewal \
                       && docker exec "$NGINX_CONTAINER" nginx -s reload && ok "Renewed."
               else err "No certificate found for '$domain'."; fi
               pause ;;
            4) certbot_run renew --dry-run; pause ;;
            5) if renew_enabled; then
                   ok "Auto-renew is ENABLED."; [ -f "$RENEW_LOG" ] && { echo "Last log lines:"; tail -n 8 "$RENEW_LOG"; }
                   confirm "Disable auto-renew?" n && step_renew_disable
               else
                   warn "Auto-renew is DISABLED."
                   confirm "Enable it now?" y && step_renew_enable
               fi
               pause ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# phpMyAdmin (optional) — served on its own domain, protected, start/stop on demand
# ============================================================================

# write_pma_vhost DOMAIN MODE   MODE: http (certificate not issued yet) | open | closed | https (= open if running, else closed)
write_pma_vhost() {
    local domain="$1" mode="$2" out="$NGINX_DIR/conf.d/$1.conf" ip have_allow=0
    local -a ips=()
    if [ "$mode" = "https" ]; then
        if container_running "$PMA_CONTAINER"; then mode="open"; else mode="closed"; fi
    fi
    IFS=',' read -ra ips <<< "$(cfg_get PMA_ALLOW || true)"
    {
        if [ "$mode" = "http" ]; then
            # Never serve phpMyAdmin over plain HTTP (passwords would travel unencrypted).
            echo "server {"
            echo "    listen 80;"
            echo "    server_name __DOMAIN__;"
            echo "    location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; }"
            echo "    location / { return 444; }"
            echo "}"
        else
            echo "server {"
            echo "    listen 80;"
            echo "    server_name __DOMAIN__;"
            echo "    location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; }"
            if [ "$mode" = "open" ]; then echo '    location / { return 301 https://$host$request_uri; }'; else echo "    location / { return 444; }"; fi
            echo "}"
            echo ""
            echo "server {"
            echo "    listen 443 ssl;"
            echo "    http2 on;"
            echo "    server_name __DOMAIN__;"
            echo "    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;"
            echo "    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;"
            echo "    ssl_protocols TLSv1.2 TLSv1.3;"
            echo "    ssl_session_cache shared:SSL:10m;"
            if [ "$mode" = "closed" ]; then
                echo ""
                echo "    # phpMyAdmin is stopped: this domain is closed completely."
                echo "    return 444;"
            else
                echo "    client_max_body_size 300M;"
                echo "    resolver 127.0.0.11 valid=10s ipv6=off;"
                for ip in "${ips[@]}"; do
                    ip="${ip// /}"
                    [ -n "$ip" ] && { echo "    allow $ip;"; have_allow=1; }
                done
                [ "$have_allow" -eq 1 ] && echo "    deny all;"
                echo '    auth_basic "Restricted";'
                echo "    auth_basic_user_file /etc/nginx/conf.d/pma.htpasswd;"
                echo '    add_header X-Robots-Tag "noindex, nofollow" always;'
                cat <<'EOF'

    location / {
        set $pma_upstream "http://__PMA__:80";
        proxy_pass $pma_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_request_buffering off;
    }
EOF
            fi
            echo "}"
        fi
    } | sed -e "s|__DOMAIN__|$domain|g" -e "s|__PMA__|$PMA_CONTAINER|g" > "$out"
}

pma_write_compose() {
    local domain="$1"
    mkdir -p "$PMA_DIR"
    cat > "$PMA_DIR/docker-compose.yml" <<EOF
services:
  phpmyadmin:
    image: ${PMA_IMAGE}
    container_name: ${PMA_CONTAINER}
    restart: "no"          # does NOT come back after a server reboot: you start it only when you need it
    environment:
      PMA_HOST: ${DB_CONTAINER}
      PMA_ABSOLUTE_URI: https://${domain}/
      UPLOAD_LIMIT: 256M
      MEMORY_LIMIT: 256M
      MAX_EXECUTION_TIME: 600
    mem_limit: 384m
    networks:
      - ${NETWORK}

networks:
  ${NETWORK}:
    external: true
EOF
}

pma_dc() { docker compose -f "$PMA_DIR/docker-compose.yml" "$@"; }

pma_write_auth() {
    local user="$1" pass="$2" hash
    hash="$(printf '%s' "$pass" | openssl passwd -apr1 -stdin)" || return 1
    printf '%s:%s\n' "$user" "$hash" > "$PMA_HTPASSWD"
    chmod 644 "$PMA_HTPASSWD"
}

# Sets PMA_NEW_USER / PMA_NEW_PASS / PMA_PASS_GENERATED
pma_ask_auth() {
    local pass pass2 def
    PMA_NEW_USER=""; PMA_NEW_PASS=""; PMA_PASS_GENERATED="no"
    explain \
        "First protection layer: a browser login (HTTP Basic Auth) in front of phpMyAdmin." \
        "After it you still log in to phpMyAdmin itself with a MariaDB user."
    while true; do
        ask "Basic-auth username" "${1:-admin}" PMA_NEW_USER
        [[ "$PMA_NEW_USER" =~ ^[A-Za-z0-9_.-]{3,32}$ ]] && break
        err "Use 3-32 characters: letters, digits, dot, dash, underscore."
    done
    def="$(gen_password)"
    while true; do
        ask_secret "Basic-auth password (Enter = auto-generate a strong one)" pass
        if [ -z "$pass" ]; then PMA_NEW_PASS="$def"; PMA_PASS_GENERATED="yes"; break; fi
        [ "${#pass}" -ge 10 ] || { err "Use at least 10 characters."; continue; }
        ask_secret "Repeat password" pass2
        [ "$pass" = "$pass2" ] && { PMA_NEW_PASS="$pass"; break; }
        err "Passwords do not match."
    done
}

pma_ask_ips() {
    local ips ip ok_all=1 mine="${SSH_CLIENT:-}"
    mine="${mine%% *}"
    explain \
        "Second protection layer (optional): only these IP addresses may open phpMyAdmin at all." \
        "Example: 203.0.113.10,198.51.100.0/24   (Enter = no IP restriction)"
    [ -n "$mine" ] && explain "Your current IP (from your SSH session) looks like: $mine"
    while true; do
        ask "Allowed IPs, comma-separated" "$(cfg_get PMA_ALLOW || true)" ips
        ips="${ips// /}"; ok_all=1
        local -a list=(); IFS=',' read -ra list <<< "$ips"
        for ip in "${list[@]}"; do
            [[ "$ip" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || ok_all=0
        done
        [ "$ok_all" -eq 1 ] && break
        err "Invalid IP list."
    done
    cfg_set PMA_ALLOW "$ips"
}

pma_configured() { [ -f "$PMA_DIR/docker-compose.yml" ] && [ -n "$(cfg_get PMA_DOMAIN || true)" ]; }

pma_setup() {
    section "phpMyAdmin setup (optional)"
    explain \
        "Creates a phpMyAdmin container on its own domain with HTTPS, a Basic-Auth login and an optional IP list." \
        "It does NOT start automatically after a reboot. Start it when you need it, stop it when you are done." \
        "While stopped, the domain is completely closed (no answer from the server)."
    docker_ready && net_exists && container_running "$NGINX_CONTAINER" && container_running "$DB_CONTAINER" \
        || { err "Docker, the network, nginx and MariaDB must be ready first (main menu 1 and 2)."; return 1; }
    local domain
    while true; do
        ask "phpMyAdmin domain (e.g. pma.example.com)" "$(cfg_get PMA_DOMAIN || true)" domain
        domain="${domain,,}"; valid_domain "$domain" && break; err "Invalid domain."
    done
    if [ -f "$NGINX_DIR/conf.d/$domain.conf" ] && ! pma_configured; then
        err "A site configuration for $domain already exists (used by a project). Choose another domain."; return 1
    fi
    explain "Create an A record for $domain pointing to this server first."
    if ! dns_check "$domain"; then
        warn "DNS does not point to this server yet."
        confirm "Continue anyway? (the certificate will fail until DNS is correct)" n || return 1
    fi
    pma_ask_auth "admin"
    pma_ask_ips
    pma_write_compose "$domain"
    pma_write_auth "$PMA_NEW_USER" "$PMA_NEW_PASS" || { err "Could not create the password file."; return 1; }
    cfg_set PMA_DOMAIN "$domain"
    info "Starting the phpMyAdmin container (first start downloads the image)..."
    pma_dc up -d || { err "Could not start phpMyAdmin."; return 1; }
    apply_vhost "$domain" "$PMA_CONTAINER" http pma || return 1
    if ssl_setup "$domain" "$PMA_CONTAINER" pma; then
        echo ""; banner "phpMyAdmin is ready" "$C_BLUE"
        printf '  URL:             https://%s\n  Basic-auth user: %s\n' "$domain" "$PMA_NEW_USER"
        if [ "$PMA_PASS_GENERATED" = "yes" ]; then printf '  Basic-auth pass: %s   (shown only now, save it)\n' "$PMA_NEW_PASS"; else printf '  Basic-auth pass: the one you typed\n'; fi
        explain "" \
            "Then phpMyAdmin asks for a MariaDB login:" \
            "  • a project's DB user (see its .env: DB_USERNAME / DB_PASSWORD) — sees only that project's database (recommended)" \
            "  • or root, with the password stored in $DB_DIR/.env (sees everything)"
        warn "While it is running, anyone with the Basic-Auth password can reach the login page. Stop it when you finish."
        confirm "Leave phpMyAdmin OPEN right now?" y || pma_stop
        next_steps "Stop it any time: Shared Services → phpMyAdmin → Stop." "Start it again: Shared Services → phpMyAdmin → Start."
    else
        warn "SSL failed, so for safety phpMyAdmin stays closed. Fix DNS and run this setup again."
        pma_dc stop >/dev/null 2>&1
        return 1
    fi
}

pma_start() {
    pma_configured || { err "phpMyAdmin is not set up yet (option 1)."; return 1; }
    local domain; domain="$(cfg_get PMA_DOMAIN)"
    container_running "$DB_CONTAINER" || { err "MariaDB is not running."; return 1; }
    pma_dc up -d || { err "Could not start phpMyAdmin."; return 1; }
    apply_vhost "$domain" "$PMA_CONTAINER" open pma || return 1
    ok "phpMyAdmin is OPEN: https://$domain"
    warn "Remember to stop it when you are done: Shared Services → phpMyAdmin → Stop."
}

pma_stop() {
    pma_configured || { err "phpMyAdmin is not set up."; return 1; }
    local domain; domain="$(cfg_get PMA_DOMAIN)"
    apply_vhost "$domain" "$PMA_CONTAINER" closed pma || return 1
    pma_dc stop >/dev/null 2>&1
    ok "phpMyAdmin is CLOSED: the domain no longer answers and the container is stopped."
}

pma_status() {
    section "phpMyAdmin status"
    if ! pma_configured; then info "Not set up. Use option 1."; return 0; fi
    local d days allow user
    d="$(cfg_get PMA_DOMAIN)"; days="$(cert_days "$d")"; allow="$(cfg_get PMA_ALLOW || true)"
    user="$(cut -d: -f1 "$PMA_HTPASSWD" 2>/dev/null)"
    printf '  Domain:          https://%s\n' "$d"
    printf '  State:           %s\n' "$(container_running "$PMA_CONTAINER" && echo "OPEN (running)" || echo "CLOSED (stopped)")"
    printf '  SSL days left:   %s\n' "${days:--}"
    printf '  Basic-auth user: %s\n' "${user:--}"
    printf '  Allowed IPs:     %s\n' "${allow:-anyone with the password}"
}

pma_remove() {
    pma_configured || { err "phpMyAdmin is not set up."; return 1; }
    local domain; domain="$(cfg_get PMA_DOMAIN)"
    warn "This removes the phpMyAdmin container, its nginx configuration and its password file (your databases are NOT touched)."
    confirm "Remove phpMyAdmin?" n || return 0
    pma_dc down >/dev/null 2>&1
    rm -f "$NGINX_DIR/conf.d/$domain.conf" "$PMA_HTPASSWD"
    nginx_test_reload >/dev/null 2>&1
    if [ -d "$NGINX_DIR/letsencrypt/live/$domain" ] && confirm "Delete the SSL certificate for $domain too?" y; then
        certbot_run delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 && ok "Certificate deleted."
    fi
    rm -rf "$PMA_DIR"; cfg_unset PMA_DOMAIN; cfg_unset PMA_ALLOW
    ok "phpMyAdmin removed."
}

menu_phpmyadmin() {
    local c domain
    while true; do
        clear; banner "phpMyAdmin (optional)" "$C_BLUE"
        pma_status_row; echo ""
        echo " 1) Set up phpMyAdmin (domain + HTTPS + password + optional IP list)"
        echo " 2) Start  (open it to the internet)"
        echo " 3) Stop   (close it completely)"
        echo " 4) Show status"
        echo " 5) Change the Basic-Auth username/password"
        echo " 6) Change the allowed IP list"
        echo " 7) Remove phpMyAdmin"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item pma_setup ;;
            2) run_item pma_start ;;
            3) run_item pma_stop ;;
            4) run_item pma_status ;;
            5) if pma_configured; then
                   pma_ask_auth "$(cut -d: -f1 "$PMA_HTPASSWD" 2>/dev/null)"
                   pma_write_auth "$PMA_NEW_USER" "$PMA_NEW_PASS" && ok "Credentials updated (effective immediately)."
                   [ "$PMA_PASS_GENERATED" = "yes" ] && warn "New generated password: $PMA_NEW_PASS   (shown only now)"
               else err "phpMyAdmin is not set up."; fi
               pause ;;
            6) if pma_configured; then
                   pma_ask_ips
                   domain="$(cfg_get PMA_DOMAIN)"
                   apply_vhost "$domain" "$PMA_CONTAINER" https pma && ok "IP list applied."
               else err "phpMyAdmin is not set up."; fi
               pause ;;
            7) run_item pma_remove ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# PROJECT HELPERS
# ============================================================================

# Load a project's .deploy.env into the current shell
load_project() {
    local path="$1"
    [ -f "$path/.deploy.env" ] || { err "No .deploy.env in $path"; return 1; }
    # Defaults for optional settings (older projects do not have them), so values never leak between projects
    FRONTEND_BUILD="no"; USE_DATABASE="yes"; NODE_IMAGE="$DEFAULT_NODE_IMAGE"; PROJECT_TYPE="laravel"; APP_PORT="3000"
    set -a; . "$path/.deploy.env"; set +a
}

dc()      { docker compose -p "$CONTAINER_NAME" --env-file "$APP_PATH/.deploy.env" -f "$APP_PATH/docker-compose.prod.yml" "$@"; }
dexec()   { docker exec -u "$APP_UID:$APP_GID" -w "$APP_PATH" "$CONTAINER_NAME" "$@"; }
artisan() { dexec php artisan "$@"; }

wait_container() {
    local i
    for i in $(seq 1 40); do
        docker exec "$CONTAINER_NAME" true >/dev/null 2>&1 && return 0
        sleep 1
    done
    err "Container '$CONTAINER_NAME' did not start. See: docker logs $CONTAINER_NAME"
    return 1
}

# deploy_project_inner PATH [pull yes|no] [target-commit] — same steps as the CI pipeline
deploy_project_inner() {
    local path="$1" pull="${2:-yes}" target="${3:-}"
    if [ -n "$target" ]; then
        info "Switching the code to version $target"
        git_reset_to "$path" "$target" || { err "Could not switch to that version."; return 1; }
    elif [ "$pull" = "yes" ]; then
        info "Pulling latest code from origin/$BRANCH"
        git_sync "$path" "$BRANCH" || { err "git update failed."; return 1; }
    fi
    if is_next; then
        info "Building the image and starting the container (the current version keeps serving until the new one is ready)"
        dc up -d --build || { err "Build failed. The previous version is still running."; return 1; }
        wait_healthy || return 1
        return 0
    fi
    info "Building and starting the container (first build takes a few minutes)"
    dc up -d --build || { err "Build failed."; return 1; }
    wait_container || return 1
    info "Installing Composer dependencies"
    dexec composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist || { err "composer install failed."; return 1; }
    if [ "$FRONTEND_BUILD" = "yes" ]; then
        frontend_build || return 1
    fi
    if ! grep -qE '^APP_KEY=.+' "$path/.env"; then
        info "Generating APP_KEY"; artisan key:generate --force || return 1
    fi
    if [ "$USE_DATABASE" = "yes" ] && [ "${DEPLOY_MIGRATE:-yes}" = "yes" ]; then
        info "Running database migrations"; artisan migrate --force || { err "Migration failed."; return 1; }
    elif [ "$USE_DATABASE" != "yes" ]; then
        info "This project has no database: skipping migrations."
    fi
    artisan storage:link >/dev/null 2>&1 || true
    info "Refreshing caches and restarting queue workers"
    artisan optimize:clear >/dev/null && artisan optimize && artisan queue:restart \
        || { err "Cache refresh failed (for example, routes defined with closures cannot be cached)."; return 1; }
}

# deploy_project PATH [pull yes|no] [target-commit]
# Keeps the site in maintenance mode while the code is replaced, records the result in .deploy.history
deploy_project() {
    local path="$1" pull="${2:-yes}" target="${3:-}" rc status="ok"
    load_project "$path" || return 1
    cd "$path" || return 1
    deploy_maint_on
    deploy_project_inner "$path" "$pull" "$target"; rc=$?
    [ -z "$target" ] || status="rollback"
    if [ "$rc" -eq 0 ]; then
        if [ "$DEPLOY_MAINT_ON" = "yes" ]; then
            artisan up >/dev/null 2>&1 && info "Maintenance mode OFF."
        fi
        docker image prune -f >/dev/null 2>&1 || true
        deploy_record "$path" "$status"
        ok "Deployment finished."
    else
        deploy_record "$path" failed
        if [ "$DEPLOY_MAINT_ON" = "yes" ]; then
            warn "The site was left in maintenance mode on purpose: half-updated code can break pages or data."
            explain "Fix the problem and deploy again, or roll back: Manage Projects -> this project -> Deployments -> Roll back."
        fi
    fi
    return "$rc"
}

# git_wait_lock PATH — wait for / clear a stale .git/index.lock; fails if another git is really running
git_wait_lock() {
    local path="$1" lock="$1/.git/index.lock" i
    for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$lock" ] || break; sleep 1; done
    if [ -f "$lock" ]; then
        if pgrep -u "$RUNNER_USER" -x git >/dev/null 2>&1; then
            err "Another git process is still running in $path. Wait until it finishes, then try again."
            return 1
        fi
        warn "Removing a stale git lock file: $lock"
        rm -f "$lock"
    fi
}

# git_sync PATH BRANCH — update the server copy to the latest origin/BRANCH
git_sync() {
    git_wait_lock "$1" || return 1
    as_runner git -C "$1" fetch origin "$2" && as_runner git -C "$1" reset --hard "origin/$2"
}

# git_reset_to PATH COMMIT — put the server copy on a specific version
git_reset_to() {
    git_wait_lock "$1" || return 1
    as_runner git -C "$1" reset --hard "$2"
}

# frontend_build — run in a temporary Node container; project must be loaded with load_project
frontend_build() {
    [ -f "$APP_PATH/package.json" ] || { err "No package.json in $APP_PATH."; return 1; }
    info "Building frontend assets with a temporary Node container ($NODE_IMAGE). The first run downloads the image."
    ( cd "$APP_PATH" && FRONTEND_BUILD=yes bash -c "$(tpl_frontend_snippet)" ) || { err "Frontend build failed."; return 1; }
    ok "Frontend assets built."
}

# normalize_mem VALUE — "256" -> "256m", "1G" -> "1g"; fails on invalid input
normalize_mem() {
    local v="${1,,}"
    [[ "$v" =~ ^[0-9]+$ ]] && v="${v}m"
    [[ "$v" =~ ^[1-9][0-9]*[mg]$ ]] || return 1
    printf '%s' "$v"
}
mem_to_mb() { local n="${1%[mg]}"; [[ "$1" == *g ]] && n=$((n * 1024)); echo "$n"; }

# write_db_env PATH — writes PROV_DB / PROV_USER / PROV_PASS into the project's .env
write_db_env() {
    local path="$1"
    env_set "$path/.env" DB_CONNECTION mysql
    env_set "$path/.env" DB_HOST "$DB_CONTAINER"
    env_set "$path/.env" DB_PORT 3306
    env_set "$path/.env" DB_DATABASE "$PROV_DB"
    env_set "$path/.env" DB_USERNAME "$PROV_USER"
    env_set "$path/.env" DB_PASSWORD "$(env_quote "$PROV_PASS")"
}

project_add_database() {
    local path="$1"
    load_project "$path" || return 1
    section "Add a database to $(basename "$path")"
    container_running "$DB_CONTAINER" || { err "The MariaDB container is not running."; return 1; }
    if [ "$USE_DATABASE" = "yes" ] && [ -n "$(env_get "$path/.env" DB_DATABASE)" ]; then
        warn "This project already has a database configured ($(env_get "$path/.env" DB_DATABASE))."
        confirm "Configure another one anyway?" n || return 0
    fi
    explain "Press Enter to accept a suggestion, or type your own value."
    db_provision "$(basename "$path")" || return 1
    if is_next; then
        write_db_env_next "$path"
        env_set "$path/.deploy.env" USE_DATABASE yes
        USE_DATABASE="yes"
        ok ".env updated with the new database settings (DATABASE_URL and DB_*)."
        info "Recreating the container so it reads the new .env..."
        dc up -d --force-recreate >/dev/null 2>&1 && wait_healthy
        return 0
    fi
    write_db_env "$path"
    env_set "$path/.deploy.env" USE_DATABASE yes
    USE_DATABASE="yes"
    ok ".env updated with the new database settings."
    if confirm "Switch SESSION_DRIVER, CACHE_STORE and QUEUE_CONNECTION to 'database'?" y; then
        env_set "$path/.env" SESSION_DRIVER database
        env_set "$path/.env" CACHE_STORE database
        env_set "$path/.env" CACHE_DRIVER database
        env_set "$path/.env" QUEUE_CONNECTION database
        ok "Drivers switched to 'database' (they need the migrations below)."
    fi
    if confirm "Run migrations now?" y; then
        artisan migrate --force || { err "Migration failed."; return 1; }
    fi
    artisan optimize:clear >/dev/null && artisan optimize && artisan queue:restart
    ok "Database added."
    next_steps "Future deployments (pipeline and manual) will now run migrations automatically."
}

project_frontend_menu() {
    local path="$1" c
    while true; do
        load_project "$path" || return
        clear; banner "Frontend assets: $(basename "$path")" "$C_GREEN"
        printf '  Build during deployments: %s     Node image: %s\n' "$FRONTEND_BUILD" "$NODE_IMAGE"
        [ -f "$path/package.json" ] || warn "No package.json found in this project."
        explain "" \
            "Assets (Vite) are built in a temporary Node container, so nothing is added to the PHP image." \
            "The package manager (pnpm / yarn / npm) is detected from the lock file in your project."
        echo ""
        echo " 1) Build assets now"
        echo " 2) Enable the build in every deployment"
        echo " 3) Disable the build in deployments"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) frontend_build; pause ;;
            2) env_set "$path/.deploy.env" FRONTEND_BUILD yes; ok "Enabled."
               grep -q 'FRONTEND_BUILD' "$path/.gitlab-ci.yml" 2>/dev/null \
                   || warn "Your .gitlab-ci.yml is an older version. Regenerate it (main menu 3), copy it to your project and push, otherwise the pipeline will not build assets."
               pause ;;
            3) env_set "$path/.deploy.env" FRONTEND_BUILD no; ok "Disabled."; pause ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# pick_sql_file VARNAME — choose a .sql / .sql.gz file; returns 1 if cancelled
pick_sql_file() {
    local __var="$1" f i=1 choice
    local -a files=()
    mapfile -t files < <(ls -t "$BACKUP_DIR"/*.sql "$BACKUP_DIR"/*.sql.gz /root/*.sql /root/*.sql.gz 2>/dev/null | head -n 15)
    echo ""
    if [ "${#files[@]}" -gt 0 ]; then
        echo "  SQL files found:"
        for f in "${files[@]}"; do
            printf '   %2d) %s  (%s, %s)\n' "$i" "$f" "$(du -h "$f" | cut -f1)" "$(date -r "$f" '+%F %H:%M')"
            i=$((i+1))
        done
    else
        info "No .sql / .sql.gz files found in $BACKUP_DIR or /root."
        explain "Upload your file first, e.g. from your computer:   scp backup.sql root@SERVER_IP:/root/"
    fi
    echo "    m) Type a full path manually"
    echo "    0) Cancel"
    while true; do
        read -r -p "${C_YELLOW}Select: ${C_RESET}" choice
        case "$choice" in
            0) return 1 ;;
            m|M) read -r -p "Full path: " f
                 if [ -f "$f" ] && [ -s "$f" ]; then printf -v "$__var" '%s' "$f"; return 0; fi
                 err "File not found or empty." ;;
            *) if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ]; then
                   printf -v "$__var" '%s' "${files[$((choice-1))]}"; return 0
               fi
               err "Invalid selection." ;;
        esac
    done
}

# db_import_file DBNAME FILE — import a dump into an existing database
db_import_file() {
    local db="$1" file="$2" fix=0 rc
    local -a reader
    valid_ident "$db" || { err "Invalid database name."; return 1; }
    [ -f "$file" ] && [ -s "$file" ] || { err "File not found or empty: $file"; return 1; }
    case "$file" in
        *.gz) gzip -t "$file" 2>/dev/null || { err "This is not a valid .gz file."; return 1; }
              reader=(gzip -dc -- "$file") ;;
        *)    reader=(cat -- "$file") ;;
    esac
    info "Checking the dump..."
    if "${reader[@]}" 2>/dev/null | grep -q -m1 'utf8mb4_0900_ai_ci'; then
        warn "This dump comes from MySQL 8 (collation utf8mb4_0900_ai_ci), which MariaDB does not support."
        confirm "Convert it automatically to utf8mb4_unicode_ci while importing?" y && fix=1
    fi
    info "Importing $(du -h "$file" | cut -f1) into '$db' — large files can take several minutes..."
    {
        echo 'SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;'
        # Drop CREATE DATABASE / USE lines so the data always lands in THIS project's database
        "${reader[@]}" | sed -E '/^CREATE DATABASE/d; /^USE `/d' \
            | { if [ "$fix" -eq 1 ]; then sed 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g'; else cat; fi; }
        echo 'SET FOREIGN_KEY_CHECKS=1; SET UNIQUE_CHECKS=1;'
    } | docker exec -i "$DB_CONTAINER" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot "$1"' _ "$db"
    rc="${PIPESTATUS[-1]}"
    if [ "$rc" -eq 0 ]; then ok "Import finished."; return 0; fi
    err "Import failed (see the SQL error above). The import stops at the first error."
    return 1
}

project_restore_db() {
    local path="$1" preset="${2:-}" db dbuser file mode typed tables maint="no" rc=0
    load_project "$path" || return 1
    section "Restore database — $(basename "$path")"
    [ "$USE_DATABASE" = "yes" ] || { err "This project has no database. Use 'Add a database' first."; return 1; }
    container_running "$DB_CONTAINER" || { err "The MariaDB container is not running."; return 1; }
    db="$(env_get "$path/.env" DB_DATABASE)"; dbuser="$(env_get "$path/.env" DB_USERNAME)"
    valid_ident "$db" || { err "DB_DATABASE is missing or invalid in $path/.env"; return 1; }
    explain \
        "Target database: $db" \
        "Supports .sql and .sql.gz files. Dumps from MySQL 8 are converted automatically if needed."
    if [ -n "$preset" ]; then file="$preset"; else pick_sql_file file || { info "Cancelled."; return 0; }; fi
    tables="$(printf "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='%s';\n" "$db" | db_sql)"
    echo ""
    printf 'The database "%s" currently has %s table(s).\n' "$db" "${tables:-0}"
    echo " 1) REPLACE (recommended): automatic backup, then drop + recreate the database, then import"
    echo " 2) ADD on top of existing data (fails at the first table that already exists)"
    echo " 0) Cancel"
    read -r -p "Select: " mode
    case "$mode" in
        1) warn "All current data in '$db' will be replaced (an automatic backup is made first)."
           read -r -p "${C_RED}Type the database name to confirm ($db): ${C_RESET}" typed
           [ "$typed" = "$db" ] || { info "Cancelled."; return 0; }
           project_backup "$path" || { err "The safety backup failed, so nothing was changed."; return 1; } ;;
        2) [ "${tables:-0}" -gt 0 ] && warn "$tables table(s) already exist; any table with the same name will make the import stop with an error."
           confirm "Continue?" n || { info "Cancelled."; return 0; } ;;
        *) info "Cancelled."; return 0 ;;
    esac
    if ! is_next && container_running "$CONTAINER_NAME" && confirm "Put the site in maintenance mode during the restore?" y; then
        artisan down --retry=60 >/dev/null 2>&1 && maint="yes"
    fi
    if [ "$mode" = "1" ]; then
        printf "DROP DATABASE IF EXISTS \`%s\`;\nCREATE DATABASE \`%s\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\nGRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%%';\nFLUSH PRIVILEGES;\n" \
            "$db" "$db" "$db" "$(sql_escape "$dbuser")" | db_sql || { err "Could not recreate the database."; rc=1; }
    fi
    if [ "$rc" -eq 0 ]; then db_import_file "$db" "$file" || rc=1; fi
    [ "$maint" = "yes" ] && artisan up >/dev/null 2>&1
    if [ "$rc" -ne 0 ]; then
        [ "$mode" = "1" ] && warn "The database was replaced before the failure. Your safety backup is in $BACKUP_DIR (restore it with this same menu)."
        return 1
    fi
    if ! is_next && confirm "Run pending migrations now (needed if your code is newer than the backup)?" y; then
        artisan migrate --force || warn "Migration reported an error."
    fi
    if ! is_next; then artisan optimize:clear >/dev/null 2>&1 && artisan optimize >/dev/null 2>&1; artisan queue:restart >/dev/null 2>&1; fi
    ok "Restore complete. Check the site in your browser."
}

# ============================================================================
# DEPLOYMENTS: history, rollback, maintenance mode
# ============================================================================
# Each deployment (pipeline or manual) appends one line to <project>/.deploy.history:
#   <time> <short commit> <ok|failed|rollback> <commit message>
# Rollback goes back to an earlier version of the CODE. The database is never rolled back automatically.

tpl_maintenance_page() {
    cat <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="15">
<title>Back soon</title>
<style>
  :root { --bg: #f6f7f9; --fg: #1f2933; --muted: #52606d; --accent: #3b82f6; }
  @media (prefers-color-scheme: dark) { :root { --bg: #11151a; --fg: #e4e7eb; --muted: #9aa5b1; --accent: #60a5fa; } }
  html, body { height: 100%; margin: 0; }
  body { background: var(--bg); color: var(--fg); font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
         display: flex; align-items: center; justify-content: center; text-align: center; padding: 24px; box-sizing: border-box; }
  main { max-width: 460px; }
  h1 { font-size: 1.6rem; margin: 0 0 12px; }
  p { color: var(--muted); line-height: 1.6; margin: 0 0 8px; }
  .bar { width: 120px; height: 4px; margin: 24px auto 0; border-radius: 2px; background: var(--accent); opacity: .5; animation: pulse 1.6s ease-in-out infinite; }
  @keyframes pulse { 0%, 100% { opacity: .25; } 50% { opacity: .8; } }
</style>
</head>
<body>
<main>
  <h1>We&rsquo;ll be right back</h1>
  <p>This site is being updated.</p>
  <p>This page refreshes automatically, no need to do anything.</p>
  <div class="bar"></div>
</main>
</body>
</html>
EOF
}

# The page is written once; you may edit it, it is never overwritten.
ensure_maintenance_page() {
    local f="$NGINX_DIR/conf.d/hideploy-maintenance.html"
    [ -f "$f" ] || tpl_maintenance_page > "$f"
    chmod 644 "$f"
}

# deploy_maint_on — turn Laravel maintenance mode on before the code is replaced
deploy_maint_on() {
    DEPLOY_MAINT_ON="no"
    [ "${PROJECT_TYPE:-laravel}" = "laravel" ] || return 0
    [ "${MAINTENANCE_ON_DEPLOY:-yes}" = "yes" ] || return 0
    [ -f "$APP_PATH/storage/framework/down" ] && return 0      # already down: leave it alone
    if container_running "$CONTAINER_NAME" && [ -f "$APP_PATH/vendor/autoload.php" ]; then
        if artisan down --retry=60 --refresh=15 >/dev/null 2>&1 || artisan down >/dev/null 2>&1; then
            DEPLOY_MAINT_ON="yes"
            info "Maintenance mode ON: visitors see a friendly page while the site updates."
        fi
    fi
}

# deploy_record PATH STATUS
deploy_record() {
    local path="$1" status="$2" f="$1/.deploy.history" sha msg
    sha="$(as_runner git -C "$path" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    msg="$(as_runner git -C "$path" log -1 --format=%s 2>/dev/null | tr -d '\r\n' | cut -c1-80)"
    printf '%s %s %s %s\n' "$(date -Is)" "$sha" "$status" "$msg" >> "$f"
    tail -n 200 "$f" > "$f.tmp" && cat "$f.tmp" > "$f"; rm -f "$f.tmp"
    chown "${APP_UID:-0}:${APP_GID:-0}" "$f" 2>/dev/null || true
    grep -qxF '.deploy.history' "$path/.git/info/exclude" 2>/dev/null || echo '.deploy.history' >> "$path/.git/info/exclude"
}

project_deploy_history() {
    local path="$1" f="$1/.deploy.history" ts sha st msg col
    section "Deployment history: $(basename "$path")"
    if [ ! -s "$f" ]; then
        info "No history yet. It is recorded by every deployment from now on (pipeline or manual)."
        explain "Projects deployed through the pipeline record history after you regenerate .gitlab-ci.yml (main menu 3) and push it."
        return 0
    fi
    printf '  %-20s %-9s %-10s %s\n' "WHEN" "VERSION" "RESULT" "MESSAGE"
    tail -n 15 "$f" | tac | while read -r ts sha st msg; do
        case "$st" in ok) col="$C_GREEN" ;; failed) col="$C_RED" ;; *) col="$C_YELLOW" ;; esac
        printf '  %-20s %-9s %s%-10s%s %s\n' "${ts:0:19}" "$sha" "$col" "$st" "$C_RESET" "$msg"
    done
}

project_rollback() {
    local path="$1" cur hist i=1 default=0 line ts sha st msg mark choice target n rc
    local -a rows=() shas=()
    load_project "$path" || return 1
    section "Roll back: $(basename "$path")"
    explain \
        "Goes back to an EARLIER VERSION OF THE CODE, rebuilds it and brings the site back online." \
        "The database is NOT rolled back. If the bad version changed the database, use a backup (Restore database)." \
        "The rollback is temporary: your next git push deploys the newest code again."
    cur="$(as_runner git -C "$path" rev-parse --short HEAD 2>/dev/null)"
    hist="$path/.deploy.history"
    if [ -s "$hist" ]; then
        mapfile -t rows < <(grep -E '^[^ ]+ [0-9a-f]+ (ok|rollback) ' "$hist" | tac | awk '!seen[$2]++' | head -n 10)
    fi
    if [ "${#rows[@]}" -eq 0 ]; then
        warn "No deployment history yet, so these versions come from git on this server (not verified as working)."
        mapfile -t rows < <(as_runner git -C "$path" reflog --format='%cI %h reflog %s' 2>/dev/null | awk '!seen[$2]++' | head -n 10)
    fi
    echo ""
    for line in "${rows[@]}"; do
        read -r ts sha st msg <<< "$line"
        shas+=("$sha")
        mark=""; [ "$sha" = "$cur" ] && mark="   <- running now"
        if [ "$default" -eq 0 ] && [ "$sha" != "$cur" ]; then default="$i"; fi
        printf '   %2d) %s  %s  %s%s\n' "$i" "$sha" "${ts:0:16}" "$msg" "$mark"
        i=$((i+1))
    done
    [ "$default" -gt 0 ] || { err "There is no earlier version to roll back to."; return 1; }
    ask "Roll back to which version? (number, 0 = cancel)" "$default" choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#shas[@]}" ] || { info "Cancelled."; return 0; }
    target="${shas[$((choice-1))]}"
    as_runner git -C "$path" cat-file -e "${target}^{commit}" 2>/dev/null || { err "Version $target is not available in this server's git history."; return 1; }
    n="$(as_runner git -C "$path" diff --name-only --diff-filter=A "$target" HEAD -- database/migrations 2>/dev/null | wc -l)"
    if [ "${n:-0}" -gt 0 ]; then
        warn "$n database migration(s) were added after version $target and are already applied to the database."
        explain "Old code usually keeps working with extra tables/columns. If it does not, restore a database backup after the rollback."
    fi
    if [ "$USE_DATABASE" = "yes" ] && confirm "Make a database backup first (recommended)?" y; then
        project_backup "$path" || { err "The backup failed, so the rollback was cancelled."; return 1; }
    fi
    confirm "Roll back $(basename "$path") to $target now? The site shows a maintenance page while it rebuilds." n || { info "Cancelled."; return 0; }
    DEPLOY_MIGRATE="no"
    deploy_project "$path" no "$target"; rc=$?
    unset DEPLOY_MIGRATE
    if [ "$rc" -eq 0 ]; then
        ok "Rolled back to $target."
        next_steps \
            "Check the site in your browser." \
            "Remember: the next 'git push' to $BRANCH deploys the newest code again." \
            "To keep the old version, on your computer run:  git revert <bad-commit>  and push, or fix the bug and push."
    else
        err "The rollback did not finish. See the messages above."
        return 1
    fi
}

project_maintenance_toggle() {
    local path="$1"
    load_project "$path" || return 1
    is_next && { info "Maintenance mode is a Laravel feature. For Next.js, nginx shows a friendly page automatically while the container restarts."; return 0; }
    container_running "$CONTAINER_NAME" || { err "The project container is not running."; return 1; }
    if [ -f "$path/storage/framework/down" ]; then
        warn "The site is in MAINTENANCE mode (visitors cannot use it)."
        confirm "Bring it back online?" y && artisan up && ok "The site is online."
    else
        ok "The site is ONLINE."
        if confirm "Put it in maintenance mode?" n; then
            { artisan down --retry=60 --refresh=15 2>/dev/null || artisan down; } && ok "Maintenance mode is ON."
        fi
    fi
}

nginx_refresh_project() {
    local path="$1" domain mode
    load_project "$path" || return 1
    domain="$(basename "$path")"
    if [ -d "$NGINX_DIR/letsencrypt/live/$domain" ]; then mode="https"; else mode="http"; fi
    if apply_vhost "$domain" "$CONTAINER_NAME" "$mode" "${PROJECT_TYPE:-laravel}"; then ok "$domain: nginx configuration refreshed ($mode)."; else err "$domain: could not refresh nginx."; return 1; fi
}

nginx_refresh_all() {
    section "Refresh nginx configuration of all projects"
    explain "Use this after updating HiDeploy, so existing sites get the newest nginx settings (for example the friendly maintenance page)."
    local p found=0
    while IFS= read -r p; do
        found=1; nginx_refresh_project "$p"
    done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null | sort)
    [ "$found" -eq 1 ] || info "No projects yet."
}

project_deploy_menu() {
    local path="$1" c
    while true; do
        load_project "$path" || return
        clear; banner "Deployments: $(basename "$path")" "$C_MAGENTA"
        if [ -f "$path/storage/framework/down" ]; then printf '  Site status: %sMAINTENANCE MODE%s\n\n' "$C_YELLOW" "$C_RESET"; else printf '  Site status: %sonline%s\n\n' "$C_GREEN" "$C_RESET"; fi
        echo " 1) Deployment history"
        echo " 2) Roll back to an earlier version"
        echo " 3) Maintenance mode on / off"
        echo " 4) Refresh this project's nginx configuration"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) project_deploy_history "$path"; pause ;;
            2) project_rollback "$path"; pause ;;
            3) project_maintenance_toggle "$path"; pause ;;
            4) nginx_refresh_project "$path"; pause ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# NEXT.JS PROJECTS
# ============================================================================
# A Next.js project is one container running the compiled "standalone" app (node server.js).
# nginx forwards the domain to it over HTTP (container name + port). The code lives INSIDE the
# image (built from your repo), so deployments build a new image while the old one keeps serving.
# Laravel projects are unaffected: PROJECT_TYPE in .deploy.env defaults to "laravel".

is_next() { [ "${PROJECT_TYPE:-laravel}" = "nextjs" ]; }

urlencode() {
    local s="$1" out="" i c
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in [A-Za-z0-9._~-]) out+="$c" ;; *) out+="$(printf '%%%02X' "'$c")" ;; esac
    done
    printf '%s' "$out"
}

detect_pm() {
    local d="$1"
    if   [ -f "$d/pnpm-lock.yaml" ];    then echo pnpm
    elif [ -f "$d/yarn.lock" ];         then echo yarn
    elif [ -f "$d/package-lock.json" ]; then echo npm
    else echo none; fi
}

tpl_next_dockerfile() {
    local pm="${1:-pnpm}" setup lock install build cache
    case "$pm" in
        pnpm) setup=$'ENV PNPM_HOME=/pnpm\nENV PATH=$PNPM_HOME:$PATH\nENV npm_config_store_dir=/pnpm/store\nRUN corepack enable'
              lock="pnpm-lock.yaml* .npmrc*"; install="pnpm install --frozen-lockfile"; build="pnpm run build"; cache="/pnpm/store" ;;
        yarn) setup="RUN corepack enable"
              lock="yarn.lock* .yarnrc* .yarnrc.yml*"; install="yarn install --frozen-lockfile"; build="yarn build"; cache="/usr/local/share/.cache/yarn" ;;
        *)    pm="npm"; setup="# npm comes with the Node image"
              lock="package-lock.json* .npmrc*"; install="npm ci --no-audit --no-fund"; build="npm run build"; cache="/root/.npm" ;;
    esac
    cat <<EOF
# Generated by HiDeploy (Next.js) — safe to edit, commit it in your repo.
# Multi-stage build: the final image only holds the compiled app (Next.js "standalone" output).
# Requires   output: 'standalone'   in next.config.js / next.config.mjs / next.config.ts
# Package manager: ${pm}
FROM node:22-alpine AS base
ENV NEXT_TELEMETRY_DISABLED=1 COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN apk add --no-cache libc6-compat
WORKDIR /app

# 1) dependencies (cached between builds)
FROM base AS deps
${setup}
COPY package.json ${lock} ./
RUN --mount=type=cache,id=hideploy-${pm},target=${cache} ${install}

# 2) build. The project's .env is part of the build context, so NEXT_PUBLIC_* values are baked in here.
FROM base AS build
${setup}
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN mkdir -p public
RUN ${build}

# 3) small runtime image
FROM node:22-alpine AS runner
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 HOSTNAME=0.0.0.0
RUN apk add --no-cache libc6-compat \\
    && addgroup -S -g 1001 nodejs && adduser -S -u 1001 -G nodejs nextjs
WORKDIR /app
COPY --from=build --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=build --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=build --chown=nextjs:nodejs /app/public ./public
USER nextjs
EXPOSE 3000
CMD ["node", "server.js"]
EOF
}

tpl_next_compose() {
    cat <<'EOF'
# Generated by HiDeploy (Next.js) — generic file, identical for every Next.js project.
# Server-specific values come from ".deploy.env"; runtime secrets come from ".env" (both live on the server, not in git).
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ${CONTAINER_NAME:?CONTAINER_NAME missing in .deploy.env}
    restart: unless-stopped
    init: true
    env_file:
      - .env
    environment:
      PORT: ${APP_PORT:-3000}
      NODE_OPTIONS: "--max-old-space-size=${NODE_HEAP_MB:-384}"
    networks:
      - web_network
    mem_limit: ${MEM_LIMIT:-512m}
    stop_grace_period: 30s
    healthcheck:
      test: ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:' + (process.env.PORT || 3000)).then(r => process.exit(r.status < 500 ? 0 : 1)).catch(() => process.exit(1))\""]
      interval: 5s
      timeout: 3s
      retries: 12
      start_period: 10s

networks:
  web_network:
    external: true
EOF
}

tpl_next_dockerignore() {
    cat <<'EOF'
# Keeps the Docker build small. NOTE: .env is NOT excluded on purpose (Next.js needs NEXT_PUBLIC_* at build time).
node_modules
.next
.git
.gitlab-ci.yml
docker-compose.prod.yml
Dockerfile
.dockerignore
.deploy.env
.deploy.history
npm-debug.log*
*.md
EOF
}

tpl_next_ci() {
    cat <<'EOF'
# Generated by HiDeploy (Next.js).
# Runs on the production server through the GitLab Runner (shell executor).
stages:
  - deploy

deploy_production:
  stage: deploy
  tags:
    - __TAG__
  resource_group: production
  rules:
    - if: '$CI_COMMIT_BRANCH == "__BRANCH__"'
  variables:
    GIT_STRATEGY: none
    DEPLOY_PATH: "__DEPLOY_PATH__"
  script:
    - |
      set -euo pipefail
      cd "$DEPLOY_PATH"
      set -a; . ./.deploy.env; set +a

      dc()     { docker compose -p "$CONTAINER_NAME" --env-file .deploy.env -f docker-compose.prod.yml "$@"; }
      record() {
        echo "$(date -Is) $(git rev-parse --short HEAD 2>/dev/null || echo unknown) $1 $(git log -1 --format=%s 2>/dev/null | tr -d '\r\n' | cut -c1-80)" >> .deploy.history
        tail -n 200 .deploy.history > .deploy.history.tmp && mv .deploy.history.tmp .deploy.history
        grep -qxF ".deploy.history" .git/info/exclude 2>/dev/null || echo ".deploy.history" >> .git/info/exclude
      }
      trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo; echo "!! Deployment FAILED. If the build failed, the previous version is still running."; echo "!! Fix the problem and push again, or roll back: sudo hideploy -> 5) Manage Projects -> this project -> Deployments -> Roll back."; record failed || true; fi' EXIT

      echo "==> Updating code"
      git fetch origin "$CI_COMMIT_BRANCH"
      git reset --hard "origin/$CI_COMMIT_BRANCH"

      echo "==> Building the image (the current version keeps serving until the new one is ready)"
      dc up -d --build

      echo "==> Waiting for the new container to become healthy"
      status=none
      for i in $(seq 1 60); do
        status="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo none)"
        [ "$status" = "healthy" ] && break
        sleep 2
      done
      if [ "$status" != "healthy" ]; then
        echo "The container did not become healthy (status: $status). Last log lines:"
        docker logs --tail 40 "$CONTAINER_NAME" || true
        exit 1
      fi
      docker image prune -f >/dev/null 2>&1 || true

      echo "==> Health check (informational)"
      curl -s -o /dev/null -w "HTTPS status: %{http_code}\n" -k --max-time 15 \
        --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" || true

      record ok
      trap - EXIT
      echo "Deployment finished successfully."
EOF
}

# validate_next_files DIR DOMAIN -> prints problems, returns the number of problems
validate_next_files() {
    local dir="$1" domain="$2" problems=0 f pm_df pm_lock
    for f in Dockerfile docker-compose.prod.yml .dockerignore .gitlab-ci.yml; do
        if [ ! -f "$dir/$f" ]; then err "Missing file: $f"; problems=$((problems+1)); fi
    done
    if [ -f "$dir/docker-compose.prod.yml" ]; then
        grep -qE '^  app:' "$dir/docker-compose.prod.yml"       || { err "docker-compose.prod.yml: the service must be named 'app'."; problems=$((problems+1)); }
        grep -q 'web_network' "$dir/docker-compose.prod.yml"    || { err "docker-compose.prod.yml: must join the external network 'web_network'."; problems=$((problems+1)); }
        grep -q 'CONTAINER_NAME' "$dir/docker-compose.prod.yml" || { err "docker-compose.prod.yml: use container_name: \${CONTAINER_NAME}."; problems=$((problems+1)); }
        grep -q 'env_file' "$dir/docker-compose.prod.yml"       || warn "docker-compose.prod.yml: no env_file: the server's .env will not reach the app at runtime."
        grep -q 'healthcheck' "$dir/docker-compose.prod.yml"    || warn "docker-compose.prod.yml: no healthcheck: deployments cannot confirm that the new version started."
    fi
    if [ -f "$dir/Dockerfile" ]; then
        grep -q '.next/standalone' "$dir/Dockerfile"            || { err "Dockerfile: it must copy .next/standalone (Next.js standalone output)."; problems=$((problems+1)); }
        pm_df="npm"
        grep -q 'pnpm install' "$dir/Dockerfile" && pm_df="pnpm"
        grep -q 'yarn install' "$dir/Dockerfile" && pm_df="yarn"
        case "$pm_df" in pnpm) pm_lock="pnpm-lock.yaml" ;; yarn) pm_lock="yarn.lock" ;; *) pm_lock="package-lock.json" ;; esac
        if [ -f "$dir/package.json" ] && [ ! -f "$dir/$pm_lock" ]; then
            err "The Dockerfile uses $pm_df but the project has no $pm_lock. Create it locally and commit it (for pnpm: 'pnpm install' or 'pnpm import')."
            problems=$((problems+1))
        fi
    fi
    if [ -f "$dir/.gitlab-ci.yml" ]; then
        grep -q '.deploy.env' "$dir/.gitlab-ci.yml"             || { err ".gitlab-ci.yml: should load .deploy.env on the server."; problems=$((problems+1)); }
        grep -q "$PROJECTS_DIR/$domain" "$dir/.gitlab-ci.yml"   || warn ".gitlab-ci.yml: DEPLOY_PATH is not '$PROJECTS_DIR/$domain'."
    fi
    if [ -f "$dir/package.json" ]; then
        grep -q '"next"' "$dir/package.json" || { err "package.json does not list 'next': is this a Next.js project?"; problems=$((problems+1)); }
        if ! grep -qs 'standalone' "$dir"/next.config.* 2>/dev/null; then
            err "next.config.* must contain  output: 'standalone'  (needed for the small production image)."
            problems=$((problems+1))
        fi
    fi
    return "$problems"
}

wait_healthy() {
    local i status="none"
    info "Waiting for the new container to become healthy..."
    for i in $(seq 1 60); do
        status="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo none)"
        [ "$status" = "healthy" ] && return 0
        sleep 2
    done
    err "The container did not become healthy (status: $status). Last log lines:"
    docker logs --tail 30 "$CONTAINER_NAME" 2>&1 | sed 's/^/    /'
    return 1
}

# write_db_env_next PATH — database settings for a Next.js project (uses PROV_DB / PROV_USER / PROV_PASS)
write_db_env_next() {
    local path="$1" pass_enc
    pass_enc="$(urlencode "$PROV_PASS")"
    env_set "$path/.env" DB_HOST "$DB_CONTAINER"
    env_set "$path/.env" DB_PORT 3306
    env_set "$path/.env" DB_DATABASE "$PROV_DB"
    env_set "$path/.env" DB_USERNAME "$PROV_USER"
    if [[ "$PROV_PASS" == *"'"* ]]; then
        warn "The password contains a quote, so only DATABASE_URL is written (use that in your app)."
    else
        env_set "$path/.env" DB_PASSWORD "'$PROV_PASS'"
    fi
    env_set "$path/.env" DATABASE_URL "mysql://$PROV_USER:$pass_enc@$DB_CONTAINER:3306/$PROV_DB"
}

# ---------- nginx vhost for Next.js (reverse proxy over HTTP) ----------------

tpl_next_common() {
    cat <<'EOF'
    client_max_body_size 50M;

    # Docker's internal DNS. Using a variable below means nginx still starts
    # (and other sites keep working) even if this project's container is stopped.
    resolver 127.0.0.11 valid=10s ipv6=off;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Shown by nginx itself while the container is restarting during a deployment
    error_page 502 504 =503 /hideploy-maintenance.html;
    location = /hideploy-maintenance.html {
        internal;
        root /etc/nginx/conf.d;
        add_header Retry-After 30 always;
        add_header Cache-Control "no-store" always;
    }
EOF
    perf_next_static
    cat <<'EOF'

    location / {
        set $next_upstream "http://__CONTAINER__:__PORT__";
        proxy_pass $next_upstream;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_read_timeout 60s;
    }
EOF
}

# write_next_vhost DOMAIN CONTAINER MODE(http|https)
write_next_vhost() {
    local domain="$1" container="$2" mode="$3" out="$NGINX_DIR/conf.d/$1.conf" port
    port="$(kv_get "$PROJECTS_DIR/$domain/.deploy.env" APP_PORT)"; port="${port:-3000}"
    ensure_maintenance_page
    {
        if [ "$mode" = "http" ]; then
            echo "server {"
            echo "    listen 80;"
            echo "    server_name __DOMAIN__;"
            perf_server_extras http
            tpl_next_common
            echo "}"
        else
            echo "server {"
            echo "    listen 80;"
            echo "    server_name __DOMAIN__;"
            echo "    location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; }"
            echo "    location / { return 301 https://\$host\$request_uri; }"
            echo "}"
            echo ""
            echo "server {"
            echo "    listen 443 ssl;"
            echo "    http2 on;"
            echo "    server_name __DOMAIN__;"
            echo "    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;"
            echo "    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;"
            echo "    ssl_protocols TLSv1.2 TLSv1.3;"
            echo "    ssl_session_cache shared:SSL:10m;"
            perf_server_extras https
            tpl_next_common
            echo "}"
        fi
    } | sed -e "s|__DOMAIN__|$domain|g" -e "s|__CONTAINER__|$container|g" -e "s|__PORT__|$port|g" > "$out"
}

# ---------- project menu ---------------------------------------------------

menu_project_next() {
    local path="$1" c cmd domain
    domain="$(basename "$path")"
    while true; do
        load_project "$path" || return
        clear; banner "Next.js project: $domain" "$C_GREEN"
        printf '  Container: %s (%s)   Port: %s   Path: %s\n\n' "$CONTAINER_NAME" \
            "$(container_running "$CONTAINER_NAME" && echo running || echo stopped)" "${APP_PORT:-3000}" "$APP_PATH"
        echo " 1) Manual deploy (pull + build image + start)"
        echo " 2) View logs (container / nginx)"
        echo " 3) Show running processes"
        echo " 4) Edit .env (then restart the container)"
        echo " 5) Open a shell inside the container"
        echo " 6) Restart container"
        echo " 7) Backup database"
        echo " 8) Setup / re-issue SSL for this domain"
        echo " 9) Add a database to this project"
        echo "10) Restore database from a .sql / .sql.gz file"
        echo "11) Deployments: history, rollback"
        echo "12) Remove this project"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) deploy_project "$path" yes; pause ;;
            2) echo " a) Container log (last 100)   b) nginx error log (last 50)   c) Follow container log"
               read -r -p "Select: " cmd
               case "$cmd" in
                   a) docker logs --tail 100 "$CONTAINER_NAME" ;;
                   b) docker logs --tail 50 "$NGINX_CONTAINER" 2>&1 | grep -i "$domain\|error" || info "Nothing relevant." ;;
                   c) info "Press Ctrl-C to stop following."; follow_cmd docker logs -f --tail 20 "$CONTAINER_NAME" ;;
               esac
               pause ;;
            3) docker exec "$CONTAINER_NAME" ps; pause ;;
            4) nano "$path/.env"
               explain "Runtime variables are read when the container starts. Variables starting with NEXT_PUBLIC_ are baked in at BUILD time: use 'Manual deploy' for those."
               if confirm "Recreate the container now so it reads the new .env?" y; then
                   dc up -d --force-recreate && wait_healthy && ok "Container restarted with the new .env."
               fi
               pause ;;
            5) info "Type 'exit' to leave the container."; docker exec -it "$CONTAINER_NAME" sh ;;
            6) dc restart && ok "Restarted."; pause ;;
            7) project_backup "$path"; pause ;;
            8) ssl_setup "$domain" "$CONTAINER_NAME" nextjs; pause ;;
            9) project_add_database "$path"; pause ;;
            10) project_restore_db "$path"; pause ;;
            11) project_deploy_menu "$path" ;;
            12) project_remove "$path"; pause; return ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ---------- deployment wizard ----------------------------------------------

deploy_wizard_nextjs() {
    local domain repo branch tag path container mem mem_norm uid gid grp ssl_ok=0 skip_ssl=0 c
    local use_db port heap detected pm ip sqlfile db_line scheme dp_ok ram
    PROV_DB=""; PROV_USER=""; PROV_PASS=""
    explain \
        "Next.js wizard: DNS check -> clone -> settings -> project files -> database -> .env -> build -> nginx -> SSL -> CI/CD guide" \
        "The site is built into a small Docker image (standalone output). pnpm is recommended and used by default."
    echo ""

    section "Step 1/10 · Domain"
    while true; do ask "Project domain (e.g. www.example.com)" "" domain; domain="${domain,,}"; valid_domain "$domain" && break; err "Invalid domain."; done
    path="$PROJECTS_DIR/$domain"

    section "Step 2/10 · DNS check"
    explain "The domain's A record must point to this server before an SSL certificate can be issued."
    if dns_check "$domain"; then
        ok "DNS is correct."
    else
        warn "DNS does not point to this server yet."
        explain "Fix it at your DNS provider (A record -> this server's IP). DNS changes can take a few minutes."
        if ! confirm "Continue now and set up SSL later?" n; then info "Stopped. Re-run this wizard after DNS is ready."; pause; return; fi
        skip_ssl=1
    fi

    section "Step 3/10 · Git repository"
    ask "Git branch to deploy" "main" branch
    while true; do
        ask "Git SSH URL (e.g. git@gitlab.com:group/project.git)" "" repo
        [[ "$repo" =~ ^(git@|ssh://) ]] && break
        err "Please use the SSH URL (starts with git@ or ssh://)."
    done
    ensure_runner_key
    trust_git_host "$(repo_host "$repo")"
    while ! as_runner git ls-remote --exit-code "$repo" HEAD >/dev/null 2>&1; do
        err "The server cannot read this repository yet."
        explain \
            "This server uses ONE SSH key for all projects. Give it read-only access to this repository:" \
            "" \
            "  First project that uses this key:" \
            "    GitLab project -> Settings -> Repository -> Deploy keys -> 'Add new key'," \
            "    paste the key below and leave 'Grant write permissions' OFF." \
            "" \
            "  Next projects (GitLab says 'Fingerprint has already been taken'):" \
            "    Do NOT add the key again. Open Settings -> Repository -> Deploy keys," \
            "    switch to the 'Privately accessible deploy keys' tab, find 'gitlab-runner@...' and click 'Enable'."
        show_runner_pubkey
        confirm "I added the key: test again?" y || { info "Stopped."; pause; return; }
    done
    ok "Repository is reachable."

    section "Step 4/10 · Clone"
    uid="$(id -u "$RUNNER_USER")"; gid="$(id -g "$RUNNER_USER")"; grp="$(id -gn "$RUNNER_USER")"
    if [ -d "$path/.git" ]; then
        ok "Project folder already exists: using it."
    else
        install -d -o "$RUNNER_USER" -g "$grp" "$path"
        as_runner git clone --branch "$branch" "$repo" "$path" || { err "Clone failed."; pause; return; }
        ok "Cloned into $path"
    fi
    as_runner git -C "$path" config core.fileMode false
    [ -f "$path/package.json" ] && grep -q '"next"' "$path/package.json" \
        || { err "This does not look like a Next.js project (package.json with 'next' is missing)."; pause; return; }

    section "Step 5/10 · Server settings (.deploy.env)"
    explain "These values are specific to THIS server, so they are stored outside git, in $path/.deploy.env"
    ask "Container name" "${domain//./-}" container
    [[ "$container" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || { err "Invalid container name."; pause; return; }
    ram="$(free -m | awk '/^Mem:/{print $2}')"
    explain "This server has ${ram} MB of RAM. A Next.js app usually needs 256-512 MB at runtime. The BUILD needs about 1 GB (add swap: Prepare Server -> Swap)."
    while true; do
        ask "Memory limit for this container (e.g. 512m or 1g)" "512m" mem
        [[ "$mem" =~ ^[0-9]+$ ]] && info "No unit given: using ${mem}m (m = megabytes)."
        mem_norm="$(normalize_mem "$mem")" || { err "Invalid value. Use a number with a unit, like 512m or 1g."; continue; }
        mem="$mem_norm"
        if [ "$(mem_to_mb "$mem")" -lt 256 ]; then
            warn "$mem is very low for Next.js."
            confirm "Use $mem anyway?" n || continue
        fi
        break
    done
    heap=$(( $(mem_to_mb "$mem") * 70 / 100 ))
    while true; do ask "Port the app listens on inside the container" "3000" port; [[ "$port" =~ ^[0-9]{2,5}$ ]] && break; err "Invalid port."; done
    if confirm "Does this project use a MariaDB database right now? (you can add one later)" n; then use_db="yes"; else use_db="no"; fi
    ask "GitLab runner tag used in .gitlab-ci.yml" "$(cfg_get RUNNER_TAG || true)" tag
    tag="${tag:-production}"; cfg_set RUNNER_TAG "$tag"
    cat > "$path/.deploy.env" <<EOF
# Server-specific settings (not in git). Used by docker-compose.prod.yml and the CI pipeline.
PROJECT_TYPE=nextjs
DOMAIN=$domain
BRANCH=$branch
CONTAINER_NAME=$container
APP_PATH=$path
APP_UID=$uid
APP_GID=$gid
APP_PORT=$port
MEM_LIMIT=$mem
NODE_HEAP_MB=$heap
USE_DATABASE=$use_db
EOF
    chown "$uid:$gid" "$path/.deploy.env"; chmod 640 "$path/.deploy.env"
    grep -qxF '.deploy.env' "$path/.git/info/exclude" 2>/dev/null || echo '.deploy.env' >> "$path/.git/info/exclude"
    ok ".deploy.env written."

    section "Step 6/10 · Project files check"
    detected="$(detect_pm "$path")"
    pm="pnpm"; [ "$detected" = "none" ] || pm="$detected"
    if [ "$detected" = "none" ]; then
        warn "No lock file found (pnpm-lock.yaml / package-lock.json / yarn.lock). Create one locally and commit it, e.g. 'pnpm install'."
    elif [ "$detected" != "pnpm" ]; then
        explain "Your project uses $detected. To switch to pnpm (faster): run 'pnpm import' locally, commit pnpm-lock.yaml and delete the old lock file."
    fi
    while true; do ask "Package manager for the build (pnpm / npm / yarn)" "$pm" pm; pm="${pm,,}"; [[ "$pm" =~ ^(pnpm|npm|yarn)$ ]] && break; err "Choose pnpm, npm or yarn."; done
    while true; do
        if validate_next_files "$path" "$domain"; then ok "All project files look good."; break; fi
        echo ""
        echo " 1) I will add/fix them from my computer (recommended: keeps your repo as the source of truth)"
        echo " 2) Create the missing files here on the server (they will NOT be in git until you commit them)"
        echo " 3) Continue anyway"
        echo " 4) Abort"
        read -r -p "Select: " c
        case "$c" in
            1) generate_project_files "$TEMPLATES_DIR/$domain" "$domain" "$branch" "$tag" yes nextjs "$pm"
               ip="$(server_ip || echo SERVER_IP)"
               info "On your computer, inside the project folder, run:"
               printf '\n   %sscp -r root@%s:%s/. .%s\n   git add . && git commit -m "Add deployment files" && git push origin %s\n\n' "$C_GREEN" "$ip" "$TEMPLATES_DIR/$domain" "$C_RESET" "$branch"
               explain "Also make sure next.config has  output: 'standalone'  and the lock file is committed."
               read -r -p "${C_MAGENTA}Press [Enter] after you pushed...${C_RESET}" _
               git_sync "$path" "$branch" || warn "Could not update the server copy. Fix the problem shown above, then choose option 1 again." ;;
            2) generate_project_files "$path" "$domain" "$branch" "$tag" no nextjs "$pm"
               chown "$uid:$gid" "$path"/Dockerfile "$path"/docker-compose.prod.yml "$path"/.dockerignore "$path"/.gitlab-ci.yml 2>/dev/null || true ;;
            3) warn "Continuing with problems: the build may fail."; break ;;
            *) info "Aborted."; pause; return ;;
        esac
    done

    section "Step 7/10 · Database"
    if [ "$use_db" = "yes" ]; then
        explain "Press Enter to accept a suggestion, or type your own value."
        db_provision "$domain" || { pause; return; }
        if confirm "Restore an existing SQL backup into this database now?" n; then
            if pick_sql_file sqlfile; then
                db_import_file "$PROV_DB" "$sqlfile" || warn "Import failed. You can retry later: Manage Projects -> your project -> Restore database."
            fi
        fi
    else
        info "No database for this project. Add one later: Manage Projects -> your project -> Add a database."
    fi

    section "Step 8/10 · Environment variables (.env)"
    if [ ! -f "$path/.env" ]; then
        if [ -f "$path/.env.example" ]; then cp "$path/.env.example" "$path/.env"; ok ".env created from .env.example."
        else : > "$path/.env"; ok "Empty .env created."; fi
    else
        ok ".env already exists: keeping it."
    fi
    [ "$use_db" = "yes" ] && write_db_env_next "$path"
    chown "$uid:$gid" "$path/.env"; chmod 640 "$path/.env"
    explain \
        "The .env file stays on the server (never in git). The container reads it when it starts." \
        "Variables starting with NEXT_PUBLIC_ are baked into the JavaScript at BUILD time, so set them BEFORE the build." \
        "Tip: in values, write a literal dollar sign as \$\$ (Docker Compose treats \$ specially)."
    if confirm "Open .env in the editor now (set API URLs, secrets, NEXT_PUBLIC_* values)?" "$([ -s "$path/.env" ] && echo y || echo n)"; then nano "$path/.env"; fi

    section "Step 9/10 · Build and start"
    explain "The first build downloads Node and your dependencies and can take several minutes."
    dp_ok="yes"
    deploy_project "$path" no || dp_ok="no"
    [ "$dp_ok" = "yes" ] || {
        err "Deployment stopped. Fix the problem, then use: Manage Projects -> your project -> Manual deploy."
        pause; return
    }

    section "Step 10/10 · nginx and SSL"
    if apply_vhost "$domain" "$container" http nextjs; then
        ok "nginx now serves http://$domain"
    else
        err "Could not configure nginx."; pause; return
    fi
    if [ "$skip_ssl" -eq 0 ] && confirm "Issue a free Let's Encrypt SSL certificate now?" y; then
        ssl_setup "$domain" "$container" nextjs && ssl_ok=1
    else
        info "SSL skipped. Later: Manage Projects -> your project -> Setup / re-issue SSL."
    fi

    scheme="http"; [ "$ssl_ok" -eq 1 ] && scheme="https"
    echo ""; banner "Deployment complete" "$C_GREEN"
    db_line="none (add one later: Manage Projects -> your project -> Add a database)"
    [ "$use_db" = "yes" ] && db_line="$PROV_DB (user $PROV_USER)"
    printf '  Site:        %s://%s\n  Code:        %s\n  Container:   %s (port %s, memory %s)\n  Package mgr: %s\n  Database:    %s\n  Config:      %s/.env  and  %s/.deploy.env\n' \
        "$scheme" "$domain" "$path" "$container" "$port" "$mem" "$pm" "$db_line" "$path" "$path"
    echo ""
    printf '%s━━ AUTOMATIC DEPLOYMENT (CI/CD): what you still need to do ━━%s\n' "$C_BOLD" "$C_RESET"
    cat <<EOF
 1. Runner: in GitLab open  Settings -> CI/CD -> Runners  and make sure a runner with the
    tag "$tag" is enabled for this project (main menu 1 -> Register GitLab Runner if needed).
 2. Deploy key: already working (the server can pull the repo). Keep it read-only.
 3. Repository files: Dockerfile, docker-compose.prod.yml, .dockerignore and .gitlab-ci.yml
    must be committed on branch "$branch". (Template copies: $TEMPLATES_DIR/$domain)
 4. No GitLab CI/CD variables are required: server settings live in $path/.deploy.env,
    runtime secrets in $path/.env.
 5. Deploy from your computer, from now on, with just:
        git add . && git commit -m "Your message" && git push origin $branch
 6. The pipeline pulls the code, builds a new image while the current version keeps serving,
    and switches over when the new container is healthy.
EOF
    next_steps \
        "Open $scheme://$domain and check it loads." \
        "Do a first test push, then watch the pipeline." \
        "Faster pages: main menu 7) Performance tuning (nginx static cache and more)."
    pause
}

choose_project() {
    local -a paths=()
    mapfile -t paths < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null | sort)
    if [ "${#paths[@]}" -eq 0 ]; then err "No projects deployed yet."; return 1; fi
    local i=1 p dom state days typ
    printf '\n%-4s %-34s %-8s %-12s %-10s\n' "#" "DOMAIN" "TYPE" "CONTAINER" "SSL DAYS"
    for p in "${paths[@]}"; do
        dom="$(basename "$p")"
        if ( . "$p/.deploy.env"; container_running "$CONTAINER_NAME" ); then state="${C_GREEN}running${C_RESET}"; else state="${C_RED}stopped${C_RESET}"; fi
        days="$(cert_days "$dom")"
        typ="$( . "$p/.deploy.env" 2>/dev/null; echo "${PROJECT_TYPE:-laravel}" )"
        printf '%-4s %-34s %-8s %-21s %-10s\n' "$i" "$dom" "$typ" "$state" "${days:--}"
        i=$((i+1))
    done
    local n; read -r -p "${C_YELLOW}Select project number (0 = back): ${C_RESET}" n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#paths[@]}" ] || return 1
    PROJECT_PATH="${paths[$((n-1))]}"
}

latest_laravel_log() { ls -t "$1"/storage/logs/*.log 2>/dev/null | head -n1; }

project_backup() {
    local path="$1" db file
    load_project "$path" || return 1
    if [ "$USE_DATABASE" != "yes" ]; then warn "This project has no database — nothing to back up."; return 0; fi
    db="$(env_get "$path/.env" DB_DATABASE)"
    [ -n "$db" ] || { err "DB_DATABASE not found in $path/.env"; return 1; }
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    file="$BACKUP_DIR/${db}-$(date +%F_%H%M%S).sql.gz"
    info "Dumping database '$db'..."
    docker exec "$DB_CONTAINER" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --routines --databases "$1"' _ "$db" | gzip > "$file"
    if [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "$file" ]; then
        ok "Backup saved: $file ($(du -h "$file" | cut -f1))"
    else
        rm -f "$file"; err "Backup failed."; return 1
    fi
}

project_remove() {
    local path="$1" domain db dbuser typed
    domain="$(basename "$path")"
    load_project "$path" || return 1
    db="$(env_get "$path/.env" DB_DATABASE)"; dbuser="$(env_get "$path/.env" DB_USERNAME)"
    [ "$USE_DATABASE" = "yes" ] || { db=""; dbuser=""; }
    warn "This will stop the container, delete the nginx config and delete the folder $path"
    read -r -p "${C_RED}Type the domain name to confirm ($domain): ${C_RESET}" typed
    [ "$typed" = "$domain" ] || { info "Cancelled."; return 0; }
    [ "$USE_DATABASE" = "yes" ] && confirm "Make a database backup first?" y && project_backup "$path"
    dc down --remove-orphans 2>/dev/null || docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    rm -f "$NGINX_DIR/conf.d/$domain.conf"; nginx_test_reload >/dev/null 2>&1
    if [ -d "$NGINX_DIR/letsencrypt/live/$domain" ] && confirm "Delete the SSL certificate for $domain?" y; then
        certbot_run delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 && ok "Certificate deleted."
    fi
    if [ -n "$db" ] && valid_ident "$db" && confirm "DROP database '$db' and user '$dbuser' permanently?" n; then
        printf "DROP DATABASE IF EXISTS \`%s\`;\nDROP USER IF EXISTS '%s'@'%%';\n" "$db" "$(sql_escape "$dbuser")" | db_sql && ok "Database and user dropped."
    fi
    cd / && rm -rf "$path" && ok "Project folder removed."
    next_steps "Remove the project's Deploy Key and pipeline in GitLab if you no longer need them."
}

menu_project() {
    local path="$1" c cmd domain f
    domain="$(basename "$path")"
    while true; do
        load_project "$path" || return
        if is_next; then menu_project_next "$path"; return; fi
        clear; banner "Project: $domain" "$C_GREEN"
        printf '  Container: %s (%s)   Path: %s\n\n' "$CONTAINER_NAME" "$(container_running "$CONTAINER_NAME" && echo running || echo stopped)" "$APP_PATH"
        echo " 1) Manual deploy (pull + build + composer + migrate + cache)"
        echo " 2) View logs (Laravel / container / nginx)"
        echo " 3) Show running processes (php-fpm, queue, scheduler)"
        echo " 4) Edit .env (then refresh caches + restart queue)"
        echo " 5) Run an artisan command"
        echo " 6) Open a shell inside the container"
        echo " 7) Restart container"
        echo " 8) Backup database"
        echo " 9) Setup / re-issue SSL for this domain"
        echo "10) Frontend assets (build now / enable in deployments)"
        echo "11) Add a database to this project"
        echo "12) Restore database from a .sql / .sql.gz file"
        echo "13) Deployments: history, rollback, maintenance mode"
        echo "14) Remove this project"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) deploy_project "$path" yes; pause ;;
            2) echo " a) Laravel log (last 100 lines)   b) Container log (last 100)   c) nginx error log (last 50)   d) Follow container log"
               read -r -p "Select: " cmd
               case "$cmd" in
                   a) f="$(latest_laravel_log "$path")"; [ -n "$f" ] && tail -n 100 "$f" || warn "No Laravel log files yet." ;;
                   b) docker logs --tail 100 "$CONTAINER_NAME" ;;
                   c) docker logs --tail 50 "$NGINX_CONTAINER" 2>&1 | grep -i "$domain\|error" || info "Nothing relevant." ;;
                   d) info "Press Ctrl-C to stop following."; follow_cmd docker logs -f --tail 20 "$CONTAINER_NAME" ;;
               esac
               pause ;;
            3) docker exec "$CONTAINER_NAME" ps; pause ;;
            4) nano "$path/.env"
               if confirm "Refresh caches and restart queue workers now?" y; then
                   artisan optimize:clear >/dev/null && artisan optimize && artisan queue:restart && ok "Done."
               fi
               pause ;;
            5) read -r -p "${C_YELLOW}php artisan ${C_RESET}" cmd
               [ -n "$cmd" ] && dexec sh -c "php artisan $cmd"; pause ;;
            6) info "Type 'exit' to leave the container."; docker exec -it -u "$APP_UID:$APP_GID" -w "$APP_PATH" "$CONTAINER_NAME" sh; ;;
            7) dc restart && ok "Restarted."; pause ;;
            8) project_backup "$path"; pause ;;
            9) ssl_setup "$domain" "$CONTAINER_NAME" && [ -f "$path/.env" ] && {
                   env_set "$path/.env" APP_URL "https://$domain"; artisan optimize >/dev/null 2>&1 || true; }
               pause ;;
            10) project_frontend_menu "$path" ;;
            11) project_add_database "$path"; pause ;;
            12) project_restore_db "$path"; pause ;;
            13) project_deploy_menu "$path" ;;
            14) project_remove "$path"; pause; return ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

menu_manage() {
    local c
    while true; do
        clear; banner "5) Manage Projects" "$C_GREEN"
        echo " 1) Projects (list, deploy, logs, backup, SSL, remove)"
        echo " 2) SSL management (all certificates)"
        echo " 3) Shared services (status / restart / logs)"
        echo " 4) Disk usage and cleanup"
        echo " 5) Refresh nginx configuration of ALL projects (after updating HiDeploy)"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) if choose_project; then menu_project "$PROJECT_PATH"; else pause; fi ;;
            2) menu_ssl ;;
            3) services_status
               echo ""; echo " a) Reload nginx config   b) Restart nginx   c) Restart MariaDB   d) nginx logs   e) MariaDB logs   (Enter = back)"
               read -r -p "Select: " c
               case "$c" in
                   a) nginx_test_reload && ok "nginx reloaded." ;;
                   b) docker restart "$NGINX_CONTAINER" ;;
                   c) docker restart "$DB_CONTAINER" ;;
                   d) docker logs --tail 80 "$NGINX_CONTAINER" ;;
                   e) docker logs --tail 80 "$DB_CONTAINER" ;;
               esac
               pause ;;
            4) menu_disk ;;
            5) nginx_refresh_all; pause ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# DEPLOY NEW LARAVEL PROJECT (wizard)
# ============================================================================

# db_provision DOMAIN  -> sets PROV_DB, PROV_USER, PROV_PASS
db_provision() {
    local domain="$1" base def_db def_user def_pass pass pass2 exists_db exists_user
    base="$(printf '%s' "$domain" | tr '.-' '__' | tr -cd 'A-Za-z0-9_')"
    def_db="${base:0:64}"; def_user="${base:0:32}"; def_pass="$(gen_password)"

    while true; do
        ask "Database name" "$def_db" PROV_DB
        valid_ident "$PROV_DB" || { err "Use only letters, digits and underscore (max 64)."; continue; }
        exists_db="$(printf "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='%s';\n" "$PROV_DB" | db_sql)"
        if [ "${exists_db:-0}" != "0" ]; then
            warn "Database '$PROV_DB' already exists."
            confirm "Reuse it (data is kept)?" n && break
            continue
        fi
        break
    done
    while true; do
        ask "Database user" "$def_user" PROV_USER
        valid_ident "$PROV_USER" || { err "Use only letters, digits and underscore."; continue; }
        exists_user="$(printf "SELECT COUNT(*) FROM mysql.user WHERE User='%s';\n" "$PROV_USER" | db_sql)"
        if [ "${exists_user:-0}" != "0" ]; then
            warn "User '$PROV_USER' already exists."
            confirm "Reuse it and set a NEW password for it?" n && break
            continue
        fi
        break
    done
    while true; do
        ask_secret "Password (Enter = auto-generate a strong one)" pass
        if [ -z "$pass" ]; then PROV_PASS="$def_pass"; info "Generated a random password."; break; fi
        ask_secret "Repeat password" pass2
        [ "$pass" = "$pass2" ] && { PROV_PASS="$pass"; break; }
        err "Passwords do not match."
    done

    printf "CREATE DATABASE IF NOT EXISTS \`%s\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\nCREATE USER IF NOT EXISTS '%s'@'%%' IDENTIFIED BY '%s';\nALTER USER '%s'@'%%' IDENTIFIED BY '%s';\nGRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%%';\nFLUSH PRIVILEGES;\n" \
        "$PROV_DB" "$PROV_USER" "$(sql_escape "$PROV_PASS")" "$PROV_USER" "$(sql_escape "$PROV_PASS")" "$PROV_DB" "$PROV_USER" | db_sql \
        || { err "Database provisioning failed."; return 1; }
    ok "Database '$PROV_DB' and user '$PROV_USER' are ready."
}

prepare_storage() {
    local path="$1" uid="$2" gid="$3"
    mkdir -p "$path/storage/framework/cache/data" "$path/storage/framework/sessions" "$path/storage/framework/views" \
             "$path/storage/logs" "$path/storage/app/public" "$path/bootstrap/cache"
    chown -R "$uid:$gid" "$path/storage" "$path/bootstrap/cache"
    chmod -R ug+rwX "$path/storage" "$path/bootstrap/cache"
}

deploy_wizard() {
    clear; banner "4) Deploy New Project" "$C_MAGENTA"
    explain \
        "This wizard does everything for ONE project, step by step:" \
        "  DNS check → clone → settings → project files → database → .env → build → nginx → SSL → CI/CD guide" \
        "You can stop at any prompt with Ctrl-C and re-run it later; finished steps are detected and skipped."
    echo ""
    require_stack || { pause; return; }

    local ptype_choice
    echo " Project type:"
    echo "  1) Laravel (PHP)"
    echo "  2) Next.js (Node; built with pnpm, npm or yarn)"
    read -r -p "Select [1]: " ptype_choice
    if [ "$ptype_choice" = "2" ]; then deploy_wizard_nextjs; return; fi

    local domain repo branch tag path container mem mem_norm uid gid grp ssl_ok=0 skip_ssl=0 queue_conn c fe fe_default use_db qdefault db_line dp_ok sqlfile
    PROV_DB=""; PROV_USER=""; PROV_PASS=""

    # ---- 1. Domain ------------------------------------------------------
    section "Step 1/11 · Domain"
    while true; do ask "Project domain (e.g. api.example.com)" "" domain; domain="${domain,,}"; valid_domain "$domain" && break; err "Invalid domain."; done
    path="$PROJECTS_DIR/$domain"

    # ---- 2. DNS ---------------------------------------------------------
    section "Step 2/11 · DNS check"
    explain "The domain's A record must point to this server before an SSL certificate can be issued."
    if dns_check "$domain"; then
        ok "DNS is correct."
    else
        warn "DNS does not point to this server yet."
        explain "Fix it at your DNS provider (A record → this server's IP). DNS changes can take a few minutes."
        if ! confirm "Continue now and set up SSL later?" n; then info "Stopped. Re-run this wizard after DNS is ready."; pause; return; fi
        skip_ssl=1
    fi

    # ---- 3. Repository --------------------------------------------------
    section "Step 3/11 · Git repository"
    ask "Git branch to deploy" "main" branch
    while true; do
        ask "Git SSH URL (e.g. git@gitlab.com:group/project.git)" "" repo
        [[ "$repo" =~ ^(git@|ssh://) ]] && break
        err "Please use the SSH URL (starts with git@ or ssh://)."
    done
    ensure_runner_key
    trust_git_host "$(repo_host "$repo")"
    while ! as_runner git ls-remote --exit-code "$repo" HEAD >/dev/null 2>&1; do
        err "The server cannot read this repository yet."
        explain \
            "This server uses ONE SSH key for all projects. Give it read-only access to this repository:" \
            "" \
            "  First project that uses this key:" \
            "    GitLab project → Settings → Repository → Deploy keys → 'Add new key'," \
            "    paste the key below and leave 'Grant write permissions' OFF." \
            "" \
            "  Next projects (GitLab says 'Fingerprint has already been taken'):" \
            "    Do NOT add the key again. Open Settings → Repository → Deploy keys," \
            "    switch to the 'Privately accessible deploy keys' tab, find 'gitlab-runner@...' and click 'Enable'."
        show_runner_pubkey
        confirm "I added the key — test again?" y || { info "Stopped."; pause; return; }
    done
    ok "Repository is reachable."

    # ---- 4. Clone -------------------------------------------------------
    section "Step 4/11 · Clone"
    uid="$(id -u "$RUNNER_USER")"; gid="$(id -g "$RUNNER_USER")"; grp="$(id -gn "$RUNNER_USER")"
    if [ -d "$path/.git" ]; then
        ok "Project folder already exists — using it."
    else
        install -d -o "$RUNNER_USER" -g "$grp" "$path"
        as_runner git clone --branch "$branch" "$repo" "$path" || { err "Clone failed."; pause; return; }
        ok "Cloned into $path"
    fi
    as_runner git -C "$path" config core.fileMode false
    [ -f "$path/artisan" ] && [ -f "$path/composer.json" ] || { err "This does not look like a Laravel project (artisan/composer.json missing)."; pause; return; }

    # ---- 5. Server settings --------------------------------------------
    section "Step 5/11 · Server settings (.deploy.env)"
    explain "These values are specific to THIS server, so they are stored outside git, in $path/.deploy.env"
    ask "Container name" "${domain//./-}" container
    [[ "$container" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || { err "Invalid container name."; pause; return; }
    while true; do
        ask "Memory limit for this container (e.g. 512m or 1g)" "512m" mem
        [[ "$mem" =~ ^[0-9]+$ ]] && info "No unit given — using ${mem}m (m = megabytes)."
        mem_norm="$(normalize_mem "$mem")" || { err "Invalid value. Use a number with a unit, like 512m or 1g."; continue; }
        mem="$mem_norm"
        if [ "$(mem_to_mb "$mem")" -lt 384 ]; then
            warn "$mem is very low: php-fpm + queue worker + 'composer install' usually need 512m or more."
            confirm "Use $mem anyway?" n || continue
        fi
        break
    done
    fe_default="n"
    if [ -f "$path/package.json" ] && grep -q '"build"' "$path/package.json"; then fe_default="y"; fi
    explain "Frontend: if the project has a package.json with a build script (Vite/Mix), assets are built on the server during deployment."
    if confirm "Does this project build frontend assets (npm/pnpm/yarn run build)?" "$fe_default"; then fe="yes"; else fe="no"; fi
    if confirm "Does this project use a database right now? (you can add one later)" y; then use_db="yes"; else use_db="no"; fi
    ask "GitLab runner tag used in .gitlab-ci.yml" "$(cfg_get RUNNER_TAG || true)" tag
    tag="${tag:-production}"; cfg_set RUNNER_TAG "$tag"
    cat > "$path/.deploy.env" <<EOF
# Server-specific settings (not in git). Used by docker-compose.prod.yml and the CI pipeline.
DOMAIN=$domain
BRANCH=$branch
CONTAINER_NAME=$container
APP_PATH=$path
APP_UID=$uid
APP_GID=$gid
MEM_LIMIT=$mem
FRONTEND_BUILD=$fe
NODE_IMAGE=$DEFAULT_NODE_IMAGE
USE_DATABASE=$use_db
EOF
    chown "$uid:$gid" "$path/.deploy.env"; chmod 640 "$path/.deploy.env"
    grep -qxF '.deploy.env' "$path/.git/info/exclude" 2>/dev/null || echo '.deploy.env' >> "$path/.git/info/exclude"
    ok ".deploy.env written."

    # ---- 6. Project files ----------------------------------------------
    section "Step 6/11 · Project files check"
    while true; do
        if validate_project_files "$path" "$domain"; then ok "All project files look good."; break; fi
        echo ""
        echo " 1) I will add them from my computer (recommended — keeps your repo as the source of truth)"
        echo " 2) Create the missing files here on the server (they will NOT be in git until you commit them)"
        echo " 3) Continue anyway"
        echo " 4) Abort"
        read -r -p "Select: " c
        case "$c" in
            1) generate_project_files "$TEMPLATES_DIR/$domain" "$domain" "$branch" "$tag" yes
               local ip; ip="$(server_ip || echo SERVER_IP)"
               info "On your computer, inside the project folder, run:"
               printf '\n   %sscp -r root@%s:%s/. .%s\n   git add . && git commit -m "Add deployment files" && git push origin %s\n\n' "$C_GREEN" "$ip" "$TEMPLATES_DIR/$domain" "$C_RESET" "$branch"
               read -r -p "${C_MAGENTA}Press [Enter] after you pushed...${C_RESET}" _
               git_sync "$path" "$branch" || warn "Could not update the server copy. Fix the problem shown above, then choose option 1 again." ;;
            2) generate_project_files "$path" "$domain" "$branch" "$tag" no
               chown "$uid:$gid" "$path"/Dockerfile "$path"/docker-compose.prod.yml "$path"/.dockerignore "$path"/.gitlab-ci.yml 2>/dev/null || true ;;
            3) warn "Continuing with problems — the build may fail."; break ;;
            *) info "Aborted."; pause; return ;;
        esac
    done

    # ---- 7. Database ----------------------------------------------------
    section "Step 7/11 · Database in the central MariaDB"
    if [ "$use_db" = "yes" ]; then
        explain "Press Enter to accept a suggestion, or type your own value."
        db_provision "$domain" || { pause; return; }
        if confirm "Restore an existing SQL backup into this database now?" n; then
            if pick_sql_file sqlfile; then
                db_import_file "$PROV_DB" "$sqlfile" || warn "Import failed. You can retry later: Manage Projects → your project → Restore database."
            fi
        fi
    else
        info "No database for this project. Add one later: Manage Projects → your project → Add a database."
    fi

    # ---- 8. .env --------------------------------------------------------
    section "Step 8/11 · Laravel .env"
    if [ ! -f "$path/.env" ]; then
        if [ -f "$path/.env.example" ]; then cp "$path/.env.example" "$path/.env"; else : > "$path/.env"; fi
        ok ".env created."
    else
        ok ".env already exists — updating the relevant values only."
    fi
    qdefault="database"; [ "$use_db" = "yes" ] || qdefault="sync"
    ask "Queue connection (database / sync / redis)" "$qdefault" queue_conn
    env_set "$path/.env" APP_ENV production
    env_set "$path/.env" APP_DEBUG false
    env_set "$path/.env" APP_URL "http://$domain"
    if [ "$use_db" = "yes" ]; then
        write_db_env "$path"
    else
        info "No database: sessions and cache are set to 'file' so the site works without one."
        env_set "$path/.env" SESSION_DRIVER file
        env_set "$path/.env" CACHE_STORE file
        env_set "$path/.env" CACHE_DRIVER file
        [ "$queue_conn" = "database" ] && warn "Queue 'database' needs a database. Use 'sync' until you add one."
    fi
    env_set "$path/.env" QUEUE_CONNECTION "$queue_conn"
    chown "$uid:$gid" "$path/.env"; chmod 640 "$path/.env"
    prepare_storage "$path" "$uid" "$gid"
    ok ".env updated (DB host is '$DB_CONTAINER'). View it any time: nano $path/.env"
    [ "$queue_conn" = "database" ] && explain "Queue 'database' needs the jobs table — it is included in migrations of Laravel 11+ (older: php artisan queue:table)."

    # ---- 9. Passport ----------------------------------------------------
    section "Step 9/11 · Laravel Passport (optional)"
    if grep -q '"laravel/passport"' "$path/composer.json"; then
        info "laravel/passport detected in composer.json."
        if [ ! -f "$path/storage/oauth-private.key" ]; then
            openssl genrsa -out "$path/storage/oauth-private.key" 4096 2>/dev/null \
                && openssl rsa -in "$path/storage/oauth-private.key" -pubout -out "$path/storage/oauth-public.key" 2>/dev/null \
                && chown "$uid:$gid" "$path"/storage/oauth-*.key && chmod 600 "$path"/storage/oauth-*.key \
                && ok "Passport RSA keys generated in storage/."
        else
            ok "Passport keys already exist."
        fi
    else
        info "Passport not used — skipped."
    fi

    # ---- 10. Build and start -------------------------------------------
    section "Step 10/11 · Build, install and migrate"
    DEPLOY_MIGRATE="no"
    if [ "$use_db" = "yes" ] && confirm "Run database migrations during this first deploy?" y; then DEPLOY_MIGRATE="yes"; fi
    dp_ok="yes"
    deploy_project "$path" no || dp_ok="no"
    unset DEPLOY_MIGRATE
    [ "$dp_ok" = "yes" ] || {
        err "Deployment stopped. Fix the problem, then use: Manage Projects → your project → Manual deploy."
        pause; return
    }

    # ---- 11. nginx + SSL ------------------------------------------------
    section "Step 11/11 · nginx and SSL"
    if apply_vhost "$domain" "$container" http; then
        ok "nginx now serves http://$domain"
    else
        err "Could not configure nginx."; pause; return
    fi
    if [ "$skip_ssl" -eq 0 ] && confirm "Issue a free Let's Encrypt SSL certificate now?" y; then
        if ssl_setup "$domain" "$container"; then
            ssl_ok=1
            env_set "$path/.env" APP_URL "https://$domain"
            ( load_project "$path" && artisan optimize >/dev/null 2>&1 ) || true
        fi
    else
        info "SSL skipped. Later: Manage Projects → your project → Setup / re-issue SSL."
    fi

    # ---- Summary + CI/CD guide -----------------------------------------
    local scheme="http"; [ "$ssl_ok" -eq 1 ] && scheme="https"
    echo ""; banner "Deployment complete" "$C_GREEN"
    db_line="none (add one later: Manage Projects → your project → Add a database)"
    [ "$use_db" = "yes" ] && db_line="$PROV_DB (user $PROV_USER)"
    printf '  Site:        %s://%s\n  Code:        %s\n  Container:   %s\n  Database:    %s\n  Frontend:    build on deploy = %s\n  Config:      %s/.env  and  %s/.deploy.env\n' \
        "$scheme" "$domain" "$path" "$container" "$db_line" "$fe" "$path" "$path"
    echo ""
    printf '%s━━ AUTOMATIC DEPLOYMENT (CI/CD) — what you still need to do ━━%s\n' "$C_BOLD" "$C_RESET"
    cat <<EOF
 1. Runner: in GitLab open  Settings → CI/CD → Runners  and make sure a runner with the
    tag "$tag" is enabled for this project (create it with 'New project runner' if needed,
    then register it on this server: main menu 1 → Register GitLab Runner).
 2. Deploy key: already working (the server can pull the repo). Keep it read-only.
 3. Repository files: Dockerfile, docker-compose.prod.yml, .dockerignore and .gitlab-ci.yml
    must be committed on branch "$branch". (Template copies: $TEMPLATES_DIR/$domain)
 4. No GitLab CI/CD variables are required: everything server-specific lives in $path/.deploy.env.
 5. Deploy from your computer, from now on, with just:
        git add . && git commit -m "Your message" && git push origin $branch
 6. Watch it in GitLab → Build → Pipelines. The job pulls code, rebuilds, runs composer,
    builds frontend assets (if enabled), runs migrations (if the project has a database),
    refreshes caches and restarts the queue workers automatically.
EOF
    next_steps \
        "Open $scheme://$domain and check it loads." \
        "Do a first test push, then watch the pipeline." \
        "Logs, backups, SSL dates: main menu 5) Manage Projects."
    pause
}

# ============================================================================
# BACKUPS — automatic, encrypted, copied to an SSH server and/or an S3 bucket
# ============================================================================
# Every night (cron) "hideploy backup-run" creates one encrypted "run" folder:
#   db-<database>.sql.gz.gpg      one per project database
#   files-<domain>.tar.gz.gpg     .env, .deploy.env, storage/app, Passport keys
#   server-config.tar.gz.gpg      nginx config, SSL certificates, runner config, hideploy settings
#   SHA256SUMS                    integrity check of the files above
# and sends it to every configured destination. Old runs are pruned automatically.

kv_get() { [ -f "$1" ] || return 0; grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2-; }
kv_set() {
    local f="$1" tmp
    mkdir -p "$(dirname "$f")"; touch "$f"; chmod 600 "$f"
    tmp="$(mktemp)"
    grep -v "^$2=" "$f" > "$tmp" || true
    printf '%s=%s\n' "$2" "$3" >> "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
}
bk_get() { kv_get "$BK_CONF" "$1"; }
bk_set() { kv_set "$BK_CONF" "$1" "$2"; }
bk_val() { local v; v="$(bk_get "$1")"; printf '%s' "${v:-$2}"; }
bk_enabled()  { [ -f "$BK_CRON" ]; }
bk_has_pass() { [ -s "$BK_PASS" ]; }
bk_dest_ssh() { [ "$(bk_get SSH_ENABLED)" = "yes" ]; }
bk_dest_s3()  { [ "$(bk_get S3_ENABLED)" = "yes" ]; }
bk_host()     { printf '%s' "${BK_HOST_OVERRIDE:-$(hostname -s)}"; }

bk_status_row() {
    if ! bk_enabled; then
        if [ "$(project_count)" -gt 0 ]; then
            status_row "Backups" warn "DISABLED" "no automatic backups yet: main menu 6"
        else
            status_row "Backups" dim "NOT SET UP" "main menu 6"
        fi
        return 0
    fi
    local res when
    res="$(kv_get "$BK_DIR/last_run.txt" RESULT)"; when="$(kv_get "$BK_DIR/last_run.txt" TIME)"
    case "$res" in
        ok)     status_row "Backups" good "ENABLED" "last run: ${when:-?} (ok)" ;;
        failed) status_row "Backups" bad  "LAST FAILED" "last run: ${when:-?} - see $BK_LOG" ;;
        *)      status_row "Backups" good "ENABLED" "no run yet (first run at $(bk_val TIME 02:30))" ;;
    esac
}

# ---------- encryption ----------------------------------------------------

bk_setup_passphrase() {
    section "Backup encryption passphrase"
    explain \
        "Backups contain your databases, .env files and certificates, so every backup file is encrypted (AES-256)" \
        "BEFORE it leaves this server. Without the passphrase nobody can open a backup, including you." \
        "" \
        "IMPORTANT: if this server dies, the passphrase stored on it dies too. Keep a copy somewhere else" \
        "(a password manager, or a note on your own computer)."
    mkdir -p "$BK_DIR"; chmod 700 "$BK_DIR"
    if bk_has_pass; then
        ok "A passphrase is already set."
        if confirm "Show it again so you can copy it?" n; then printf '\n  %s%s%s\n\n' "$C_GREEN" "$(cat "$BK_PASS")" "$C_RESET"; fi
        return 0
    fi
    has_cmd gpg || { info "Installing gnupg..."; apt-get install -y gnupg >/dev/null 2>&1 || { err "Could not install gnupg."; return 1; }; }
    local pass typed typed2
    pass="$(openssl rand -base64 33 | tr -d '\n')"
    ask_secret "Passphrase (Enter = use a strong generated one; if you type your own, min 16 characters)" typed
    if [ -n "$typed" ]; then
        [ "${#typed}" -ge 16 ] || { err "Too short (minimum 16 characters)."; return 1; }
        ask_secret "Repeat passphrase" typed2
        [ "$typed" = "$typed2" ] || { err "Passphrases do not match."; return 1; }
        pass="$typed"
    fi
    printf '%s' "$pass" > "$BK_PASS"; chmod 600 "$BK_PASS"
    echo ""; banner "YOUR BACKUP PASSPHRASE" "$C_YELLOW"
    printf '  %s%s%s\n\n' "$C_GREEN" "$pass" "$C_RESET"
    warn "Save it NOW outside this server. If you lose it, your backups can never be opened."
    while ! confirm "I have saved the passphrase in a safe place" n; do warn "Please save it first."; done
    ok "Passphrase set."
    next_steps "Add a destination: option 3 (SSH server) and/or option 4 (S3 bucket)."
}

# stdin -> encrypted file ($1)
bk_encrypt() {
    gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$BK_PASS" \
        --symmetric --cipher-algo AES256 -z 0 -o "$1"
}

# bk_decrypt IN OUT  (asks for the passphrase if this server does not have it, e.g. a new server)
bk_decrypt() {
    local pf="$BK_PASS" tmp_pf="" rc pass
    if [ ! -s "$pf" ]; then
        ask_secret "Backup passphrase" pass
        tmp_pf="$(mktemp)"; printf '%s' "$pass" > "$tmp_pf"; pf="$tmp_pf"
    fi
    ( umask 077; gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$pf" --decrypt -o "$2" "$1" )
    rc=$?
    [ -z "$tmp_pf" ] || rm -f "$tmp_pf"
    return "$rc"
}

# ---------- SSH destination ----------------------------------------------

bk_ssh() {
    ssh -i "$BK_SSH_KEY" -p "$(bk_get SSH_PORT)" -o BatchMode=yes -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$BK_KNOWN" \
        "$(bk_get SSH_USER)@$(bk_get SSH_HOST)" "$@"
}
bk_ssh_e() {
    printf 'ssh -i %s -p %s -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=%s' \
        "$BK_SSH_KEY" "$(bk_get SSH_PORT)" "$BK_KNOWN"
}
bk_ssh_parent() { printf '%s' "$(bk_get SSH_PATH)"; }
bk_ssh_base()   { printf '%s/%s' "$(bk_get SSH_PATH)" "$(bk_host)"; }

bk_test_ssh() {
    local out base
    base="$(bk_ssh_base)"
    out="$(bk_ssh "mkdir -p '$base' && command -v rsync >/dev/null && echo hideploy-ok" 2>&1)"
    if printf '%s' "$out" | grep -q 'hideploy-ok'; then return 0; fi
    printf '%s\n' "$out"
    return 1
}

bk_upload_ssh() {
    local dir="$1" run="$2" base target
    base="$(bk_ssh_base)"
    target="$(bk_get SSH_USER)@$(bk_get SSH_HOST)"
    bk_ssh "mkdir -p '$base'" || return 1
    # upload under a temporary name, then rename: a half-uploaded run never looks complete
    rsync -a --partial -e "$(bk_ssh_e)" "$dir/" "$target:$base/.partial-$run/" || return 1
    bk_ssh "rm -rf '$base/$run' && mv '$base/.partial-$run' '$base/$run'"
}

bk_list_ssh() { bk_ssh "ls -1 '$(bk_ssh_base)' 2>/dev/null" </dev/null; }

bk_download_ssh() {
    local run="$1" dest="$BK_LOCAL_DIR/$1"
    mkdir -p "$dest"; chmod 700 "$dest"
    rsync -a -e "$(bk_ssh_e)" "$(bk_get SSH_USER)@$(bk_get SSH_HOST):$(bk_ssh_base)/$run/" "$dest/"
}

bk_prune_ssh() {
    local days n base
    days="$(bk_val REMOTE_KEEP_DAYS 30)"; base="$(bk_ssh_base)"
    bk_list_ssh | bk_prune_candidates "$days" | while IFS= read -r n; do
        bk_ssh "rm -rf -- '$base/$n'" </dev/null && echo "  pruned on SSH server: $n"
    done
}

bk_cfg_ssh() {
    section "Backup destination: another server over SSH"
    explain \
        "Backups are copied with rsync over SSH to a second server (ideally in another data center)." \
        "HiDeploy creates a dedicated SSH key; you only paste its public part on the backup server." \
        "The backup server needs: SSH access, the 'rsync' package, and free disk space."
    local host port user path pub
    while true; do ask "Backup server address (IP or domain)" "$(bk_get SSH_HOST)" host; [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] && break; err "Invalid address."; done
    while true; do ask "SSH port" "$(bk_val SSH_PORT 22)" port; [[ "$port" =~ ^[0-9]{1,5}$ ]] && break; err "Invalid port."; done
    while true; do ask "SSH user on the backup server (a dedicated user is recommended)" "$(bk_val SSH_USER backup)" user; [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] && break; err "Invalid user name."; done
    while true; do ask "Folder on the backup server (relative to its home, or absolute)" "$(bk_val SSH_PATH hideploy-backups)" path; [[ "$path" =~ ^[A-Za-z0-9._/~-]+$ ]] && break; err "Use only letters, digits and . _ / ~ -"; done
    has_cmd rsync || { info "Installing rsync..."; apt-get install -y rsync >/dev/null 2>&1 || { err "Could not install rsync."; return 1; }; }
    mkdir -p "$BK_DIR"; chmod 700 "$BK_DIR"
    [ -f "$BK_SSH_KEY" ] || ssh-keygen -t ed25519 -N "" -C "hideploy-backup@$(hostname -s)" -f "$BK_SSH_KEY" >/dev/null
    [ -s "$BK_SSH_KEY.pub" ] || { err "Could not create the SSH key (is openssh-client installed?)."; return 1; }
    pub="$(cat "$BK_SSH_KEY.pub")"
    bk_set SSH_HOST "$host"; bk_set SSH_PORT "$port"; bk_set SSH_USER "$user"; bk_set SSH_PATH "$path"
    echo ""
    info "Run these commands ON THE BACKUP SERVER as root (copy and paste them as a block):"
    printf '%s\n' "$C_GREEN"
    cat <<EOF
id -u ${user} >/dev/null 2>&1 || adduser --disabled-password --gecos '' ${user}
apt-get install -y rsync
install -d -m 700 -o ${user} -g ${user} /home/${user}/.ssh
echo '${pub}' >> /home/${user}/.ssh/authorized_keys
chown ${user}:${user} /home/${user}/.ssh/authorized_keys && chmod 600 /home/${user}/.ssh/authorized_keys
EOF
    printf '%s\n' "$C_RESET"
    while true; do
        confirm "Done? Test the connection now" y || { bk_set SSH_ENABLED no; warn "Saved but NOT enabled. Run option 3 again when ready."; return 0; }
        if bk_test_ssh; then
            bk_set SSH_ENABLED yes
            ok "Connection works. Backups will be copied to ${user}@${host}:${path}/$(bk_host)/"
            next_steps "Set the schedule (option 5), run a test backup (option 6), then turn the nightly backup on (option 7)."
            return 0
        fi
        err "Could not connect or rsync is missing on the backup server (see the message above)."
    done
}

# ---------- S3 destination (rclone in a temporary container) --------------

bk_rc() { docker run --rm --env-file "$BK_RCLONE_ENV" "$@"; }

bk_write_rclone_env() {
    ( umask 077
      {
        echo "RCLONE_CONFIG_HD_TYPE=s3"
        echo "RCLONE_CONFIG_HD_PROVIDER=$(bk_val S3_PROVIDER Other)"
        echo "RCLONE_CONFIG_HD_ACCESS_KEY_ID=$(bk_get S3_ACCESS_KEY)"
        echo "RCLONE_CONFIG_HD_SECRET_ACCESS_KEY=$(bk_get S3_SECRET_KEY)"
        echo "RCLONE_CONFIG_HD_ENDPOINT=$(bk_get S3_ENDPOINT)"
        [ -z "$(bk_get S3_REGION)" ] || echo "RCLONE_CONFIG_HD_REGION=$(bk_get S3_REGION)"
        echo "RCLONE_CONFIG_HD_ACL=private"
        echo "RCLONE_CONFIG_HD_NO_CHECK_BUCKET=true"
      } > "$BK_RCLONE_ENV" )
    chmod 600 "$BK_RCLONE_ENV"
}

bk_s3_parent() {
    local pre; pre="$(bk_get S3_PREFIX)"
    printf 'hd:%s%s' "$(bk_get S3_BUCKET)" "${pre:+/$pre}"
}
bk_s3_base() { printf '%s/%s' "$(bk_s3_parent)" "$(bk_host)"; }

bk_test_s3() {
    local t base rc
    bk_write_rclone_env
    t="$(mktemp)"; echo "hideploy test $(date -Is)" > "$t"
    base="$(bk_s3_base)"
    bk_rc -v "$t:/test.txt:ro" "$RCLONE_IMAGE" copyto /test.txt "$base/.hideploy-test.txt" \
        && bk_rc "$RCLONE_IMAGE" deletefile "$base/.hideploy-test.txt"
    rc=$?
    rm -f "$t"
    return "$rc"
}

bk_upload_s3() {
    local dir="$1" run="$2" base
    bk_write_rclone_env
    base="$(bk_s3_base)/$run"
    bk_rc -v "$dir:/src:ro" "$RCLONE_IMAGE" copy /src "$base" --exclude SHA256SUMS --retries 3 --low-level-retries 5 || return 1
    # the checksum file goes last: it acts as the "this run is complete" marker
    bk_rc -v "$dir:/src:ro" "$RCLONE_IMAGE" copyto /src/SHA256SUMS "$base/SHA256SUMS" --retries 3
}

bk_list_s3() {
    bk_write_rclone_env
    bk_rc "$RCLONE_IMAGE" lsf --dirs-only "$(bk_s3_base)/" 2>/dev/null </dev/null | sed 's#/$##'
}

bk_download_s3() {
    local run="$1" dest="$BK_LOCAL_DIR/$1"
    bk_write_rclone_env
    mkdir -p "$dest"; chmod 700 "$dest"
    bk_rc -v "$dest:/dst" "$RCLONE_IMAGE" copy "$(bk_s3_base)/$run" /dst
}

bk_prune_s3() {
    local days n
    days="$(bk_val REMOTE_KEEP_DAYS 30)"
    bk_list_s3 | bk_prune_candidates "$days" | while IFS= read -r n; do
        bk_rc "$RCLONE_IMAGE" purge "$(bk_s3_base)/$n" </dev/null && echo "  pruned in S3: $n"
    done
}

bk_cfg_s3() {
    section "Backup destination: S3 bucket"
    explain \
        "Works with Arvan Cloud Object Storage and any S3-compatible service." \
        "In the Arvan panel: Object Storage -> create a PRIVATE bucket, then create an access key (Access Key + Secret Key)." \
        "Use a bucket only for backups. Files are already encrypted before upload."
    local choice provider endpoint region bucket prefix ak sk
    echo " 1) Arvan Cloud - Iran Central, Standard          (s3.ir-central1.arvanstorage.ir)"
    echo " 2) Arvan Cloud - Iran Central, HiOps (SSD)      (hot.ir-central1.arvanstorage.ir)"
    echo " 3) Arvan Cloud - Iran North-West, Standard      (s3.ir-northwest1.arvanstorage.ir)"
    echo " 4) Arvan Cloud - Western Europe, Standard       (s3.eu-west1.arvanstorage.ir)"
    echo " 5) Other S3-compatible service (custom endpoint)"
    explain "The endpoint must match the region where you created the bucket. Standard is the right choice for backups (HiOps SSD costs more)."
    read -r -p "Select: " choice
    case "$choice" in
        1) provider="ArvanCloud"; endpoint="https://s3.ir-central1.arvanstorage.ir"; region="" ;;
        2) provider="ArvanCloud"; endpoint="https://hot.ir-central1.arvanstorage.ir"; region="" ;;
        3) provider="ArvanCloud"; endpoint="https://s3.ir-northwest1.arvanstorage.ir"; region="" ;;
        4) provider="ArvanCloud"; endpoint="https://s3.eu-west1.arvanstorage.ir"; region="" ;;
        5) provider="Other"
           while true; do ask "Endpoint URL (e.g. https://s3.example.com)" "$(bk_get S3_ENDPOINT)" endpoint; [[ "$endpoint" =~ ^https?://[A-Za-z0-9._:-]+$ ]] && break; err "Invalid endpoint."; done
           ask "Region (Enter = none)" "$(bk_get S3_REGION)" region ;;
        *) info "Cancelled."; return 0 ;;
    esac
    while true; do ask "Bucket name" "$(bk_get S3_BUCKET)" bucket; [[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] && break; err "Invalid bucket name (lowercase letters, digits, dot, dash)."; done
    while true; do ask "Folder inside the bucket (Enter = none)" "$(bk_val S3_PREFIX hideploy)" prefix; [ -z "$prefix" ] || [[ "$prefix" =~ ^[A-Za-z0-9._/-]+$ ]] && break; err "Invalid folder."; done
    ask "Access key" "$(bk_get S3_ACCESS_KEY)" ak
    ask_secret "Secret key (hidden)" sk
    [ -n "$sk" ] || sk="$(bk_get S3_SECRET_KEY)"
    [ -n "$ak" ] && [ -n "$sk" ] || { err "Access key and secret key are required."; return 1; }
    [[ "$ak$sk" =~ ^[A-Za-z0-9+/=._-]+$ ]] || { err "Keys contain unexpected characters."; return 1; }
    mkdir -p "$BK_DIR"; chmod 700 "$BK_DIR"
    bk_set S3_PROVIDER "$provider"; bk_set S3_ENDPOINT "$endpoint"; bk_set S3_REGION "$region"
    bk_set S3_BUCKET "$bucket"; bk_set S3_PREFIX "$prefix"; bk_set S3_ACCESS_KEY "$ak"; bk_set S3_SECRET_KEY "$sk"
    docker_ready || { err "Docker is not ready."; return 1; }
    info "Preparing the upload tool (rclone, downloaded once)..."
    docker pull "$RCLONE_IMAGE" >/dev/null 2>&1 || warn "Could not pre-download rclone; the test below will try again."
    info "Testing: writing and deleting a small test file in the bucket..."
    if bk_test_s3; then
        bk_set S3_ENABLED yes
        ok "S3 works. Backups will go to: $bucket/${prefix:+$prefix/}$(bk_host)/"
        next_steps "Set the schedule (option 5), run a test backup (option 6), then turn the nightly backup on (option 7)."
    else
        bk_set S3_ENABLED no
        err "The test failed. Check: bucket exists, keys are correct, the endpoint matches the bucket's region, the key may write to the bucket."
        return 1
    fi
}

# ---------- retention ----------------------------------------------------

# stdin: run names; prints the ones older than N days. The newest 3 runs are never listed.
bk_prune_candidates() {
    local days="$1" cutoff
    cutoff="$(date -d "-${days} days" +%F_%H%M%S)"
    grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sort | head -n -3 | awk -v c="$cutoff" '$0 < c'
}

bk_prune_local() {
    local days n
    days="$(bk_val LOCAL_KEEP_DAYS 7)"
    ls -1 "$BK_LOCAL_DIR" 2>/dev/null | bk_prune_candidates "$days" | while IFS= read -r n; do
        rm -rf -- "${BK_LOCAL_DIR:?}/$n" && echo "  pruned local copy: $n"
    done
}

# ---------- the backup itself --------------------------------------------

bk_run_inner() {
    local run dir fail=0 p dom db use_db f rh size ssh_state="off" s3_state="off"
    local -a items extras
    run="$(date +%F_%H%M%S)"; dir="$BK_LOCAL_DIR/$run"
    mkdir -p "$dir"; chmod 700 "$dir"
    echo "[$(date -Is)] Backup $run started (HiDeploy $HIDEPLOY_VERSION)"

    # 1) every project: database dump + files
    while IFS= read -r p; do
        dom="$(basename "$p")"
        use_db="$( . "$p/.deploy.env" 2>/dev/null; echo "${USE_DATABASE:-yes}" )"
        db="$(env_get "$p/.env" DB_DATABASE)"
        if [ "$use_db" = "yes" ] && valid_ident "$db"; then
            if docker exec "$DB_CONTAINER" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --routines --events --databases "$1"' _ "$db" \
                    | gzip -c | bk_encrypt "$dir/db-$db.sql.gz.gpg"; then
                echo "  database $db: ok"
            else
                echo "  database $db: FAILED"; fail=$((fail+1)); rm -f "$dir/db-$db.sql.gz.gpg"
            fi
        fi
        if [ "$(bk_val INCLUDE_FILES yes)" = "yes" ]; then
            items=()
            for f in .env .deploy.env storage/app; do [ -e "$p/$f" ] && items+=("$f"); done
            for f in "$p"/storage/oauth-*.key; do [ -e "$f" ] && items+=("storage/$(basename "$f")"); done
            if [ "${#items[@]}" -gt 0 ]; then
                if { tar -C "$p" -czf - "${items[@]}" 2>/dev/null || [ $? -eq 1 ]; } | bk_encrypt "$dir/files-$dom.tar.gz.gpg"; then
                    echo "  files $dom: ok"
                else
                    echo "  files $dom: FAILED"; fail=$((fail+1)); rm -f "$dir/files-$dom.tar.gz.gpg"
                fi
            fi
        fi
    done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null | sort)

    # 2) server configuration (the passphrase and destination keys are deliberately NOT included)
    extras=()
    rh="$(runner_home 2>/dev/null || true)"; rh="${rh#/}"
    for f in etc/gitlab-runner "${rh:+$rh/.ssh}" usr/local/bin/hideploy-renew-ssl etc/cron.d/hideploy-ssl-renew etc/cron.d/hideploy-backup etc/logrotate.d/hideploy; do
        [ -n "$f" ] && [ -e "/$f" ] && extras+=("$f")
    done
    if [ -d "$INFRA_DIR" ]; then
        if { tar -C / --exclude="${INFRA_DIR#/}/backup" -czf - "${INFRA_DIR#/}" "${extras[@]}" 2>/dev/null || [ $? -eq 1 ]; } \
                | bk_encrypt "$dir/server-config.tar.gz.gpg"; then
            echo "  server configuration: ok"
        else
            echo "  server configuration: FAILED"; fail=$((fail+1)); rm -f "$dir/server-config.tar.gz.gpg"
        fi
    fi

    if ! ls "$dir"/*.gpg >/dev/null 2>&1; then
        echo "  nothing was backed up"; fail=$((fail+1))
    else
        ( cd "$dir" && sha256sum -- *.gpg > SHA256SUMS )
    fi
    size="$(du -sh "$dir" 2>/dev/null | cut -f1)"

    # 3) copy to the destinations
    if bk_dest_ssh; then
        if bk_upload_ssh "$dir" "$run"; then ssh_state="ok"; echo "  SSH server upload: ok"
        else ssh_state="FAILED"; fail=$((fail+1)); echo "  SSH server upload: FAILED"; fi
    fi
    if bk_dest_s3; then
        if bk_upload_s3 "$dir" "$run"; then s3_state="ok"; echo "  S3 upload: ok"
        else s3_state="FAILED"; fail=$((fail+1)); echo "  S3 upload: FAILED"; fi
    fi
    if [ "$ssh_state" = "off" ] && [ "$s3_state" = "off" ]; then
        echo "  NOTE: no remote destination is configured, so this backup exists only on this server."
    fi

    # 4) retention
    bk_prune_local
    if [ "$ssh_state" = "ok" ]; then bk_prune_ssh; fi
    if [ "$s3_state" = "ok" ]; then bk_prune_s3; fi

    {
        echo "TIME=$(date '+%F %H:%M')"; echo "RUN=$run"
        if [ "$fail" -eq 0 ]; then echo "RESULT=ok"; else echo "RESULT=failed"; fi
        echo "SIZE=$size"; echo "SSH=$ssh_state"; echo "S3=$s3_state"
    } > "$BK_DIR/last_run.txt"
    chmod 600 "$BK_DIR/last_run.txt"
    echo "[$(date -Is)] Backup $run finished: $([ "$fail" -eq 0 ] && echo SUCCESS || echo "FAILED ($fail problem(s))") - $size"
    [ "$fail" -eq 0 ]
}

# Non-interactive entry point (cron calls:  hideploy backup-run)
backup_run() {
    [ -s "$BK_PASS" ] || { echo "[backup] No passphrase yet. Open: sudo hideploy -> 6) Backups -> 2"; return 1; }
    has_cmd gpg      || { echo "[backup] gpg is missing: apt-get install -y gnupg"; return 1; }
    docker_ready     || { echo "[backup] Docker is not running."; return 1; }
    mkdir -p "$BK_LOCAL_DIR" "$BK_DIR"; chmod 700 "$BACKUP_DIR" "$BK_LOCAL_DIR" 2>/dev/null
    ( flock -n 9 || { echo "[backup] Another backup is already running."; exit 1; }; bk_run_inner ) 9>"$BK_DIR/.lock"
}

# ---------- schedule, status, on/off --------------------------------------

bk_write_cron() {
    local t hh mm self
    t="$(bk_val TIME 02:30)"; hh="${t%%:*}"; mm="${t##*:}"
    hh=$((10#$hh)); mm=$((10#$mm))
    self="$(command -v hideploy 2>/dev/null || true)"; [ -n "$self" ] || self="/usr/local/bin/hideploy"
    [ -x "$self" ] || { err "hideploy is not installed at $self. Install it first with install.sh."; return 1; }
    printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n%s %s * * * root %s backup-run >> %s 2>&1\n' \
        "$mm" "$hh" "$self" "$BK_LOG" > "$BK_CRON"
    chmod 644 "$BK_CRON"
    write_logrotate
}

bk_cfg_schedule() {
    section "Schedule and retention"
    local t lk rk inc incdef
    while true; do ask "Daily backup time (24h HH:MM, server time)" "$(bk_val TIME 02:30)" t; [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break; err "Use HH:MM, for example 02:30."; done
    while true; do ask "Keep copies ON THIS SERVER for how many days" "$(bk_val LOCAL_KEEP_DAYS 7)" lk; [[ "$lk" =~ ^[0-9]+$ ]] && [ "$lk" -ge 1 ] && break; err "Enter a number of days (1 or more)."; done
    while true; do ask "Keep copies on the REMOTE destinations for how many days" "$(bk_val REMOTE_KEEP_DAYS 30)" rk; [[ "$rk" =~ ^[0-9]+$ ]] && [ "$rk" -ge 1 ] && break; err "Enter a number of days (1 or more)."; done
    if [ "$(bk_val INCLUDE_FILES yes)" = "yes" ]; then incdef="y"; else incdef="n"; fi
    explain "Databases, SSL certificates and server settings are always included. The newest 3 backups are never deleted."
    if confirm "Also back up project files (.env, uploaded files in storage/app, Passport keys)?" "$incdef"; then inc="yes"; else inc="no"; fi
    bk_set TIME "$t"; bk_set LOCAL_KEEP_DAYS "$lk"; bk_set REMOTE_KEEP_DAYS "$rk"; bk_set INCLUDE_FILES "$inc"
    if bk_enabled; then bk_write_cron && ok "Schedule updated."; else ok "Saved."; fi
}

bk_toggle() {
    section "Nightly backup on/off"
    if bk_enabled; then
        ok "The nightly backup is ON (every day at $(bk_val TIME 02:30))."
        if confirm "Turn it OFF?" n; then rm -f "$BK_CRON"; warn "Nightly backup is OFF. Your data is no longer being backed up automatically."; fi
        return 0
    fi
    bk_has_pass || { err "Set the encryption passphrase first (option 2)."; return 1; }
    if ! bk_dest_ssh && ! bk_dest_s3; then
        warn "No remote destination is configured. Backups would stay on THIS server only, so a server failure would lose everything."
        confirm "Turn it on anyway?" n || return 0
    fi
    bk_write_cron || return 1
    ok "The nightly backup is ON: every day at $(bk_val TIME 02:30). Log: $BK_LOG"
    next_steps "Run option 6 once now to confirm everything works end to end."
}

bk_status() {
    section "Backup status"
    local n size pre
    n="$(ls -1 "$BK_LOCAL_DIR" 2>/dev/null | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$')"
    size="$(du -sh "$BK_LOCAL_DIR" 2>/dev/null | cut -f1)"
    printf '  Nightly backup:      %s\n' "$(bk_enabled && echo "ON, every day at $(bk_val TIME 02:30)" || echo OFF)"
    printf '  Encryption:          %s\n' "$(bk_has_pass && echo "passphrase is set" || echo "NOT SET (option 2)")"
    printf '  Local copies:        %s backup(s), %s, kept %s days (%s)\n' "${n:-0}" "${size:-0}" "$(bk_val LOCAL_KEEP_DAYS 7)" "$BK_LOCAL_DIR"
    if bk_dest_ssh; then printf '  SSH server:          %s@%s:%s/%s/  (kept %s days)\n' "$(bk_get SSH_USER)" "$(bk_get SSH_HOST)" "$(bk_get SSH_PATH)" "$(bk_host)" "$(bk_val REMOTE_KEEP_DAYS 30)"
    else printf '  SSH server:          not configured\n'; fi
    if bk_dest_s3 && [[ "$(bk_get S3_ENDPOINT)" == *ir-thr-at1* || "$(bk_get S3_ENDPOINT)" == *ir-tbz-sh1* ]]; then
        warn "Your S3 endpoint ($(bk_get S3_ENDPOINT)) is being retired by Arvan Cloud. Move to a new region: option 4 in this menu."
    fi
    if bk_dest_s3; then
        pre="$(bk_get S3_PREFIX)"
        printf '  S3 bucket:           %s/%s%s/  (kept %s days)\n' "$(bk_get S3_BUCKET)" "${pre:+$pre/}" "$(bk_host)" "$(bk_val REMOTE_KEEP_DAYS 30)"
    else printf '  S3 bucket:           not configured\n'; fi
    printf '  Project files:       %s\n' "$([ "$(bk_val INCLUDE_FILES yes)" = yes ] && echo "included" || echo "not included")"
    if [ -f "$BK_DIR/last_run.txt" ]; then
        printf '  Last run:            %s - %s (%s, SSH: %s, S3: %s)\n' "$(kv_get "$BK_DIR/last_run.txt" TIME)" \
            "$(kv_get "$BK_DIR/last_run.txt" RESULT)" "$(kv_get "$BK_DIR/last_run.txt" SIZE)" \
            "$(kv_get "$BK_DIR/last_run.txt" SSH)" "$(kv_get "$BK_DIR/last_run.txt" S3)"
    else
        printf '  Last run:            never\n'
    fi
    [ -f "$BK_LOG" ] && { echo ""; echo "  Last log lines ($BK_LOG):"; tail -n 6 "$BK_LOG" | sed 's/^/    /'; }
    return 0
}

# ---------- restore -------------------------------------------------------

# bk_pick_from_list VARNAME "NAMES (one per line)" — choose one backup run
bk_pick_from_list() {
    local __var="$1" choice i=1 n
    local -a names=()
    mapfile -t names < <(printf '%s\n' "$2" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sort -r)
    if [ "${#names[@]}" -eq 0 ]; then err "No backups found here."; return 1; fi
    echo ""
    for n in "${names[@]}"; do printf '   %2d) %s\n' "$i" "$n"; i=$((i+1)); done
    echo "    0) Cancel"
    while true; do
        read -r -p "${C_YELLOW}Select a backup: ${C_RESET}" choice
        [ "$choice" = "0" ] && return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#names[@]}" ]; then
            printf -v "$__var" '%s' "${names[$((choice-1))]}"; return 0
        fi
        err "Invalid selection."
    done
}

# Let the user choose which server's backup folder to read (needed on a NEW server)
bk_choose_source_host() {
    local kind="$1" hosts
    if [ "$kind" = "ssh" ]; then
        hosts="$(bk_ssh "ls -1 '$(bk_ssh_parent)' 2>/dev/null" </dev/null | tr '\n' ' ')"
    else
        bk_write_rclone_env
        hosts="$(bk_rc "$RCLONE_IMAGE" lsf --dirs-only "$(bk_s3_parent)/" 2>/dev/null </dev/null | sed 's#/$##' | tr '\n' ' ')"
    fi
    explain "Backup folders found at the destination: ${hosts:-<none>}" \
            "Each server stores its backups in a folder named after its hostname."
    ask "Which folder do you want to restore from" "$(hostname -s)" BK_HOST_OVERRIDE
}

bk_restore_from_run() {
    local run="$1" dir="$BK_LOCAL_DIR/$1" f dbname proj p tmp choice i=1
    local -a dbs=() projs=()
    if [ -f "$dir/SHA256SUMS" ]; then
        if ( cd "$dir" && sha256sum -c SHA256SUMS --quiet ); then ok "Integrity check passed."; else err "Integrity check FAILED: this backup is damaged."; return 1; fi
    else
        warn "No SHA256SUMS file: cannot verify integrity."
    fi
    mapfile -t dbs < <(cd "$dir" && ls -1 db-*.sql.gz.gpg 2>/dev/null)
    if [ "${#dbs[@]}" -eq 0 ]; then warn "This backup contains no database."; return 0; fi
    echo ""; echo "  Databases in this backup:"
    for f in "${dbs[@]}"; do printf '   %2d) %s\n' "$i" "$f"; i=$((i+1)); done
    echo "    0) Cancel"
    read -r -p "${C_YELLOW}Select a database to restore: ${C_RESET}" choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#dbs[@]}" ] || { info "Cancelled."; return 0; }
    f="${dbs[$((choice-1))]}"; dbname="${f#db-}"; dbname="${dbname%.sql.gz.gpg}"
    proj=""
    mapfile -t projs < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null | sort)
    for p in "${projs[@]}"; do
        if [ "$(env_get "$p/.env" DB_DATABASE)" = "$dbname" ]; then proj="$p"; break; fi
    done
    if [ -z "$proj" ]; then
        warn "No project on this server uses the database '$dbname'."
        explain "Deploy the project first (main menu 4, choose 'restore a backup' when asked), or decrypt the file with option 9."
        return 0
    fi
    info "This database belongs to project: $(basename "$proj")"
    tmp="$(mktemp -d -p "$BACKUP_DIR")"; chmod 700 "$tmp"
    info "Decrypting..."
    if ! bk_decrypt "$dir/$f" "$tmp/restore.sql.gz"; then
        err "Decryption failed (wrong passphrase, or the file is damaged)."; rm -rf "$tmp"; return 1
    fi
    project_restore_db "$proj" "$tmp/restore.sql.gz"
    rm -rf "$tmp"
}

bk_restore_menu() {
    section "Restore from a backup"
    explain \
        "Restoring a DATABASE is guided here. Project files and server config can be decrypted with option 9." \
        "On a brand-new server: set up Docker/nginx/MariaDB first, then add the SSH or S3 destination (same settings," \
        "same bucket), then come back here and choose that destination."
    echo " 1) A backup stored on THIS server"
    echo " 2) Download from the SSH server"
    echo " 3) Download from the S3 bucket"
    echo " 0) Cancel"
    local c run
    read -r -p "Select: " c
    case "$c" in
        1) bk_pick_from_list run "$(ls -1 "$BK_LOCAL_DIR" 2>/dev/null)" || return 0 ;;
        2) bk_dest_ssh || { err "The SSH destination is not configured (option 3)."; return 1; }
           bk_choose_source_host ssh
           bk_pick_from_list run "$(bk_list_ssh)" || { unset BK_HOST_OVERRIDE; return 0; }
           info "Downloading $run ..."
           bk_download_ssh "$run" || { err "Download failed."; unset BK_HOST_OVERRIDE; return 1; }
           unset BK_HOST_OVERRIDE ;;
        3) bk_dest_s3 || { err "The S3 destination is not configured (option 4)."; return 1; }
           bk_choose_source_host s3
           bk_pick_from_list run "$(bk_list_s3)" || { unset BK_HOST_OVERRIDE; return 0; }
           info "Downloading $run ..."
           bk_download_s3 "$run" || { err "Download failed."; unset BK_HOST_OVERRIDE; return 1; }
           unset BK_HOST_OVERRIDE ;;
        *) info "Cancelled."; return 0 ;;
    esac
    bk_restore_from_run "$run"
}

bk_decrypt_menu() {
    section "Decrypt a backup file"
    explain \
        "Use this to restore project files or the server configuration by hand." \
        "The decrypted file is placed in /root/hideploy-restore/<backup>/ (readable only by root)." \
        "Delete it when you are finished: it is NOT encrypted."
    local run dir f out choice i=1
    local -a files=()
    bk_pick_from_list run "$(ls -1 "$BK_LOCAL_DIR" 2>/dev/null)" || return 0
    dir="$BK_LOCAL_DIR/$run"
    mapfile -t files < <(cd "$dir" && ls -1 ./*.gpg 2>/dev/null | sed 's#^\./##')
    [ "${#files[@]}" -gt 0 ] || { err "No encrypted files in this backup."; return 1; }
    echo ""
    for f in "${files[@]}"; do printf '   %2d) %s\n' "$i" "$f"; i=$((i+1)); done
    echo "    0) Cancel"
    read -r -p "${C_YELLOW}Select a file: ${C_RESET}" choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ] || { info "Cancelled."; return 0; }
    f="${files[$((choice-1))]}"
    out="/root/hideploy-restore/$run"; mkdir -p "$out"; chmod 700 /root/hideploy-restore "$out"
    if bk_decrypt "$dir/$f" "$out/${f%.gpg}"; then
        ok "Decrypted to: $out/${f%.gpg}"
        case "$f" in
            files-*) explain "To restore the files of a project (this OVERWRITES its .env and uploads):" \
                             "  tar -xzf $out/${f%.gpg} -C /var/www/projects/<domain>" ;;
            server-config*) explain "Contents: nginx config, SSL certificates, runner config, hideploy settings (paths start without a leading slash)." \
                                    "Only on a rebuilt server, to bring everything back:  tar -xzf $out/${f%.gpg} -C /" ;;
            db-*) explain "A database dump: restore it through the project menu (Manage Projects -> project -> Restore database) or option 8." ;;
        esac
        warn "Remember to delete $out when you are done."
    else
        err "Decryption failed (wrong passphrase, or the file is damaged)."
        return 1
    fi
}

# ---------- menus ---------------------------------------------------------

bk_menu_dest() {  # ssh | s3
    local kind="$1" c
    echo ""
    echo " 1) Configure / change"
    echo " 2) Test the connection now"
    echo " 3) Disable this destination"
    echo " 0) Back"
    read -r -p "Select: " c
    case "$c" in
        1) if [ "$kind" = "ssh" ]; then bk_cfg_ssh; else bk_cfg_s3; fi ;;
        2) if [ "$kind" = "ssh" ]; then
               if bk_dest_ssh || [ -n "$(bk_get SSH_HOST)" ]; then bk_test_ssh && ok "SSH destination works." || err "SSH test failed."; else err "Not configured."; fi
           else
               if [ -n "$(bk_get S3_BUCKET)" ]; then bk_test_s3 && ok "S3 destination works." || err "S3 test failed."; else err "Not configured."; fi
           fi ;;
        3) if [ "$kind" = "ssh" ]; then bk_set SSH_ENABLED no; else bk_set S3_ENABLED no; fi; ok "Disabled (settings are kept)." ;;
        *) return 0 ;;
    esac
}

menu_backups() {
    local c
    while true; do
        clear; banner "6) Backups (automatic, encrypted, off-server)" "$C_CYAN"
        bk_status_row; echo ""
        explain "Recommended order: 2 (passphrase) -> 3 and/or 4 (where to send) -> 5 (schedule) -> 6 (test) -> 7 (turn on)"
        echo ""
        echo " 1) Show backup status"
        echo " 2) Encryption passphrase (do this first)"
        echo " 3) Destination: another server over SSH"
        echo " 4) Destination: S3 bucket (Arvan Cloud or any S3-compatible)"
        echo " 5) Schedule and retention"
        echo " 6) Run a backup NOW"
        echo " 7) Turn the nightly backup ON / OFF"
        echo " 8) Restore a database from a backup"
        echo " 9) Decrypt a backup file (project files / server config)"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item bk_status ;;
            2) run_item bk_setup_passphrase ;;
            3) bk_menu_dest ssh; pause ;;
            4) bk_menu_dest s3; pause ;;
            5) run_item bk_cfg_schedule ;;
            6) if bk_has_pass; then backup_run; else err "Set the encryption passphrase first (option 2)."; fi; pause ;;
            7) run_item bk_toggle ;;
            8) run_item bk_restore_menu ;;
            9) run_item bk_decrypt_menu ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# DISK: usage warning and safe cleanup
# ============================================================================
# Cleanup NEVER touches Docker volumes (your databases live there), running containers, project code or .env files.

disk_pct() { df --output=pcent / 2>/dev/null | tail -n1 | tr -dc '0-9'; }

disk_row() {
    local p; p="$(disk_pct)"
    [ -n "$p" ] || return 0
    if   [ "$p" -ge 90 ]; then status_row "Disk space" bad  "${p}% USED" "almost full: Manage Projects -> Disk usage and cleanup"
    elif [ "$p" -ge 80 ]; then status_row "Disk space" warn "${p}% USED" "getting full: consider a cleanup"
    else status_row "Disk space" good "${p}% USED" "$(df -h --output=avail / | tail -n1 | tr -d ' ') free"; fi
}

hideploy_self() { local s; s="$(command -v hideploy 2>/dev/null || true)"; printf '%s' "${s:-/usr/local/bin/hideploy}"; }

write_logrotate() {
    cat > /etc/logrotate.d/hideploy <<EOF
$BK_LOG $RENEW_LOG $CLEANUP_LOG {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
}

cleanup_enabled() { [ -f "$CLEANUP_CRON" ]; }

cleanup_used_bytes() { df --output=used -B1 / | tail -n1 | tr -dc '0-9'; }

# The safe cleanup (also what the weekly job runs)
cleanup_safe() {
    local before after freed p
    before="$(cleanup_used_bytes)"
    echo "[$(date -Is)] Safe cleanup started (disk $(disk_pct)% used)"
    if docker_ready; then
        info "Docker: removing unused (dangling) images..."
        docker image prune -f 2>&1 | tail -n 1
        info "Docker: removing build cache older than 7 days..."
        docker builder prune -f --filter "until=168h" 2>&1 | tail -n 1
    fi
    if has_cmd journalctl; then
        info "System logs: keeping at most 200 MB..."
        journalctl --vacuum-size=200M 2>&1 | tail -n 1
    fi
    info "Package download cache..."
    apt-get clean
    info "Laravel log files older than 14 days..."
    while IFS= read -r p; do
        find "$p/storage/logs" -type f -name '*.log' -mtime +14 -print -delete 2>/dev/null | sed 's/^/  deleted /'
    done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null)
    after="$(cleanup_used_bytes)"
    freed=$(( (${before:-0} - ${after:-0}) / 1024 / 1024 ))
    [ "$freed" -ge 0 ] || freed=0
    ok "Cleanup finished: freed about ${freed} MB. Disk is now $(disk_pct)% used."
}

cleanup_deep() {
    warn "Deep cleanup removes ALL Docker images that no container uses, and the whole build cache."
    explain \
        "Running and stopped containers keep their images. Volumes (databases) are never touched." \
        "Cost: the next deploy or backup may be slower, because tools (Node, rclone) are downloaded again."
    confirm "Continue with the deep cleanup?" n || { info "Cancelled."; return 0; }
    local before after
    before="$(cleanup_used_bytes)"
    docker image prune -a -f 2>&1 | tail -n 1
    docker builder prune -a -f 2>&1 | tail -n 1
    after="$(cleanup_used_bytes)"
    ok "Freed about $(( (${before:-0} - ${after:-0}) / 1024 / 1024 )) MB."
}

cleanup_big_logs() {
    section "Large log files"
    local f size found=0
    while IFS= read -r f; do
        found=1
        size="$(du -h "$f" | cut -f1)"
        if confirm "Empty $f ($size)?" n; then : > "$f" && ok "Emptied."; fi
    done < <(find "$PROJECTS_DIR"/*/storage/logs /var/log -type f -name '*.log' -size +100M 2>/dev/null)
    [ "$found" -eq 1 ] || info "No log file is larger than 100 MB."
}

cleanup_old_manual_backups() {
    section "Old manual database backups"
    local f found=0
    local -a list=()
    mapfile -t list < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sql.gz' \) -mtime +30 2>/dev/null)
    if [ "${#list[@]}" -eq 0 ]; then info "No manual backups older than 30 days in $BACKUP_DIR."; return 0; fi
    for f in "${list[@]}"; do printf '   %s (%s)\n' "$f" "$(du -h "$f" | cut -f1)"; found=1; done
    explain "These are the one-off backups made from the project menu. Automatic backups are cleaned by their own schedule."
    if confirm "Delete these ${#list[@]} file(s)?" n; then rm -f -- "${list[@]}" && ok "Deleted."; fi
}

cleanup_toggle() {
    local self
    if cleanup_enabled; then
        ok "Weekly automatic safe cleanup is ON (Sundays 04:10)."
        confirm "Turn it OFF?" n && { rm -f "$CLEANUP_CRON"; ok "Turned off."; }
        return 0
    fi
    explain "Runs the SAFE cleanup (option 1) every Sunday at 04:10 and writes a log to $CLEANUP_LOG."
    confirm "Turn on the weekly automatic cleanup?" y || return 0
    self="$(hideploy_self)"
    [ -x "$self" ] || { err "hideploy is not installed at $self. Install it first with install.sh."; return 1; }
    printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n10 4 * * 0 root %s cleanup-run >> %s 2>&1\n' "$self" "$CLEANUP_LOG" > "$CLEANUP_CRON"
    chmod 644 "$CLEANUP_CRON"
    write_logrotate
    ok "Weekly automatic cleanup is ON."
}

disk_overview() {
    section "Disk usage"
    df -h / | sed 's/^/  /'
    echo ""
    if docker_ready; then docker system df 2>/dev/null | sed 's/^/  /'; echo ""; fi
    printf '  Automatic backups on this server: %s\n' "$(du -sh "$BK_LOCAL_DIR" 2>/dev/null | cut -f1)"
    printf '  Manual backups:                   %s\n' "$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
    printf '  System logs (/var/log):           %s\n' "$(du -sh /var/log 2>/dev/null | cut -f1)"
}

menu_disk() {
    local c
    while true; do
        clear; banner "Disk usage and cleanup" "$C_GREEN"
        disk_row; echo ""
        disk_overview; echo ""
        echo " 1) Safe cleanup now (recommended)"
        echo " 2) Deep cleanup: remove ALL unused Docker images and build cache"
        echo " 3) Find large log files and empty them"
        echo " 4) Delete manual database backups older than 30 days"
        echo " 5) Weekly automatic safe cleanup: on / off"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) cleanup_safe; pause ;;
            2) cleanup_deep; pause ;;
            3) cleanup_big_logs; pause ;;
            4) cleanup_old_manual_backups; pause ;;
            5) cleanup_toggle; pause ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# PERFORMANCE TUNING (main menu 7)
# ============================================================================
# Nothing here is applied automatically. Until you apply a profile, nginx configuration and
# containers stay exactly as they were. Suggested values come from a scan of this server.

perf_get()     { kv_get "$PERF_CONF" "$1"; }
perf_set()     { kv_set "$PERF_CONF" "$1" "$2"; }
perf_val()     { local v; v="$(perf_get "$1")"; printf '%s' "${v:-$2}"; }
perf_applied() { [ "$(perf_get APPLIED)" = "yes" ]; }

# ---------- hooks used when vhosts are written (silent unless tuning is applied) ----------

perf_server_extras() {   # $1 = http | https
    perf_applied || return 0
    echo "    keepalive_timeout $(perf_val KEEPALIVE 30)s;"
    if [ "$1" = "https" ]; then echo "    ssl_session_timeout 1d;"; fi
    return 0
}

perf_laravel_static() {
    perf_applied || return 0
    local exp; exp="$(perf_val STATIC_EXPIRES 7d)"
    [ "$exp" != "off" ] || return 0
    cat <<'EOF' | sed "s|__EXP__|$exp|g"

    # Browser caching for static files (added by HiDeploy performance tuning)
    location ^~ /build/ {
        try_files $uri =404;
        add_header Cache-Control "public, max-age=31536000, immutable";
        access_log off;
    }

    location ~* \.(?:css|js|mjs|woff2?|ttf|otf|eot|svg|png|jpe?g|gif|webp|avif|ico)$ {
        try_files $uri /index.php?$query_string;
        expires __EXP__;
        access_log off;
    }
EOF
}

perf_next_static() {
    perf_applied || return 0
    cat <<'EOF'

    # Cached copy of the hashed, immutable build files: fast, and still served while the container restarts
    location ^~ /_next/static/ {
        set $next_static_upstream "http://__CONTAINER__:__PORT__";
        proxy_pass $next_static_upstream;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_cache hd_static;
        proxy_cache_valid 200 7d;
        proxy_cache_lock on;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        add_header X-Cache-Status $upstream_cache_status;
    }
EOF
}

# ---------- server scan and suggestions ----------

perf_scan() {
    local src dev rota p t
    PS_CORES="$(nproc 2>/dev/null || echo 1)"
    PS_RAM_MB="$(free -m | awk '/^Mem:/{print $2}')"
    PS_AVAIL_MB="$(free -m | awk '/^Mem:/{print $7}')"
    PS_SWAP_MB="$(free -m | awk '/^Swap:/{print $2}')"
    PS_DISK="unknown"
    src="$(findmnt -no SOURCE / 2>/dev/null)"
    dev="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)"
    [ -n "$dev" ] || dev="$(basename "${src:-x}")"
    rota="$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null)"
    case "$rota" in 0) PS_DISK="SSD / NVMe" ;; 1) PS_DISK="HDD (or a virtual disk reported as rotational)" ;; esac
    PS_LARAVEL=0; PS_NEXT=0; PS_PROJ_MEM_MB=0
    while IFS= read -r p; do
        t="$( . "$p/.deploy.env" 2>/dev/null; echo "${PROJECT_TYPE:-laravel} ${MEM_LIMIT:-512m}" )"
        if [ "${t%% *}" = "nextjs" ]; then PS_NEXT=$((PS_NEXT+1)); else PS_LARAVEL=$((PS_LARAVEL+1)); fi
        PS_PROJ_MEM_MB=$(( PS_PROJ_MEM_MB + $(mem_to_mb "$(normalize_mem "${t#* }" 2>/dev/null || echo 512m)") ))
    done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null)
}

perf_suggest() {
    local bp
    if   [ "$PS_RAM_MB" -lt 1500 ]; then PS_TIER="small  (under 1.5 GB RAM)"; SG_KEEPALIVE=20; SG_PCACHE="128m"; SG_BP="128M"; SG_MAXCONN=40
    elif [ "$PS_RAM_MB" -lt 3500 ]; then PS_TIER="medium (1.5 - 3.5 GB RAM)"; SG_KEEPALIVE=30; SG_PCACHE="256m"; SG_BP="256M"; SG_MAXCONN=80
    else                                 PS_TIER="large  (3.5 GB RAM or more)"; SG_KEEPALIVE=30; SG_PCACHE="512m"
        bp=$(( PS_RAM_MB / 4 )); [ "$bp" -gt 1024 ] && bp=1024; bp=$(( bp / 64 * 64 )); SG_BP="${bp}M"; SG_MAXCONN=150
    fi
    if   [ "$PS_CORES" -ge 4 ]; then SG_GZIP=6; elif [ "$PS_CORES" -ge 2 ]; then SG_GZIP=5; else SG_GZIP=4; fi
    SG_STATIC="7d"; SG_OFC="yes"
}

# perf_fpm_suggest MEM_MB -> SG_FPM_*
perf_fpm_suggest() {
    local m="$1" max
    max=$(( (m - 100) / 50 )); [ "$max" -lt 2 ] && max=2; [ "$max" -gt 30 ] && max=30
    SG_FPM_MAX="$max"
    if [ "$m" -ge 384 ] && [ "${PS_RAM_MB:-0}" -ge 1500 ] && [ "$max" -ge 3 ]; then
        SG_FPM_PM="dynamic"; SG_FPM_START=2; SG_FPM_MIN=1
        SG_FPM_MAXS=$(( max / 2 )); [ "$SG_FPM_MAXS" -lt 3 ] && SG_FPM_MAXS=3; [ "$SG_FPM_MAXS" -gt "$max" ] && SG_FPM_MAXS="$max"
    else
        SG_FPM_PM="ondemand"; SG_FPM_START=2; SG_FPM_MIN=1; SG_FPM_MAXS=3
    fi
}

perf_show_scan() {
    perf_scan; perf_suggest
    section "This server"
    printf '  CPU cores:         %s\n' "$PS_CORES"
    printf '  RAM:               %s MB total, %s MB available now\n' "$PS_RAM_MB" "$PS_AVAIL_MB"
    printf '  Swap:              %s MB\n' "$PS_SWAP_MB"
    printf '  Disk type:         %s\n' "$PS_DISK"
    printf '  Projects:          %s Laravel, %s Next.js (their memory limits add up to %s MB)\n' "$PS_LARAVEL" "$PS_NEXT" "$PS_PROJ_MEM_MB"
    printf '  Server size:       %s\n' "$PS_TIER"
    section "Suggested settings for this server"
    printf '  %-34s %s\n' "Compression level" "$SG_GZIP   (current: $(perf_val GZIP_LEVEL "not applied"))"
    printf '  %-34s %s\n' "Keep-alive seconds" "$SG_KEEPALIVE   (current: $(perf_val KEEPALIVE "not applied"))"
    printf '  %-34s %s\n' "Static file browser cache" "$SG_STATIC   (current: $(perf_val STATIC_EXPIRES "not applied"))"
    printf '  %-34s %s\n' "Next.js static cache size" "$SG_PCACHE   (current: $(perf_val PROXY_CACHE "not applied"))"
    printf '  %-34s %s\n' "MariaDB buffer pool" "$SG_BP   (current: $(perf_db_current bp))"
    printf '  %-34s %s\n' "MariaDB max connections" "$SG_MAXCONN   (current: $(perf_db_current mc))"
    echo ""
    if [ "$PS_PROJ_MEM_MB" -gt $(( PS_RAM_MB * 80 / 100 )) ]; then
        warn "The memory limits of all projects (${PS_PROJ_MEM_MB} MB) are more than 80% of the server's RAM (${PS_RAM_MB} MB)."
        explain "That is fine while the apps use less than their limit, but under heavy load the server may start swapping or killing processes."
    fi
    if [ "$PS_SWAP_MB" -eq 0 ] && [ "$PS_RAM_MB" -lt 3000 ]; then
        warn "No swap file: builds and 'composer install' can be killed on a small server. Add one: Prepare Server -> Swap."
    fi
}

# ---------- nginx ----------

perf_write_nginx_conf() {
    local gz ofc pc
    gz="$(perf_val GZIP_LEVEL 5)"; ofc="$(perf_val OPEN_FILE_CACHE yes)"; pc="$(perf_val PROXY_CACHE 256m)"
    {
        echo "# Managed by HiDeploy (main menu 7: Performance tuning). Change it through the menu, not by hand."
        echo "tcp_nopush on;"
        echo "tcp_nodelay on;"
        echo "keepalive_requests 1000;"
        echo "server_names_hash_bucket_size 128;"
        echo "gzip_comp_level $gz;"
        echo "gzip_min_length 1024;"
        echo "gzip_vary on;"
        echo "gzip_proxied any;"
        echo "gzip_types application/xml application/rss+xml application/atom+xml application/manifest+json font/ttf font/otf application/vnd.ms-fontobject image/x-icon text/javascript;"
        if [ "$ofc" = "yes" ]; then
            echo "open_file_cache max=2000 inactive=30s;"
            echo "open_file_cache_valid 60s;"
            echo "open_file_cache_min_uses 2;"
            echo "open_file_cache_errors on;"
        fi
        echo "fastcgi_buffers 16 16k;"
        echo "fastcgi_buffer_size 32k;"
        echo "proxy_cache_path /var/cache/nginx/hd_static levels=1:2 keys_zone=hd_static:10m max_size=$pc inactive=7d use_temp_path=off;"
    } > "$PERF_NGINX_CONF"
}

perf_apply_nginx() {
    section "Nginx tuning"
    container_running "$NGINX_CONTAINER" || { err "The nginx container is not running."; return 1; }
    perf_scan; perf_suggest
    explain \
        "Press Enter to accept the value suggested for THIS server, or type your own." \
        "A wrong value cannot break your sites: nginx tests the new configuration first and keeps the old one if it is rejected."
    local gz ka ofc exp pc prev_applied backup=""
    while true; do ask "Compression level 1-9 (higher = smaller files, more CPU; $PS_CORES core(s) here)" "$(perf_val GZIP_LEVEL "$SG_GZIP")" gz; [[ "$gz" =~ ^[1-9]$ ]] && break; err "Enter a number from 1 to 9."; done
    while true; do ask "Keep-alive seconds (how long a browser may reuse a connection)" "$(perf_val KEEPALIVE "$SG_KEEPALIVE")" ka; [[ "$ka" =~ ^[0-9]+$ ]] && [ "$ka" -ge 5 ] && [ "$ka" -le 300 ] && break; err "Enter a number from 5 to 300."; done
    if confirm "Cache file information to speed up static files (open_file_cache)?" "$([ "$(perf_val OPEN_FILE_CACHE "$SG_OFC")" = yes ] && echo y || echo n)"; then ofc="yes"; else ofc="no"; fi
    while true; do ask "Browser cache for Laravel static files (off / 1d / 7d / 30d)" "$(perf_val STATIC_EXPIRES "$SG_STATIC")" exp; exp="${exp,,}"; [[ "$exp" =~ ^(off|1d|7d|30d)$ ]] && break; err "Choose off, 1d, 7d or 30d."; done
    while true; do ask "Size of the nginx cache for Next.js static files (e.g. 128m, 1g)" "$(perf_val PROXY_CACHE "$SG_PCACHE")" pc; pc="${pc,,}"; [[ "$pc" =~ ^[1-9][0-9]*[mg]$ ]] && break; err "Use a number with m or g."; done
    echo ""
    printf '  Compression %s · keep-alive %ss · open_file_cache %s · static cache %s · Next.js cache %s\n\n' "$gz" "$ka" "$ofc" "$exp" "$pc"
    confirm "Apply these settings now? (sites keep running, nginx is reloaded)" y || { info "Cancelled."; return 0; }
    prev_applied="$(perf_get APPLIED)"
    if [ -f "$PERF_NGINX_CONF" ]; then backup="$(mktemp)"; cp "$PERF_NGINX_CONF" "$backup"; fi
    perf_set GZIP_LEVEL "$gz"; perf_set KEEPALIVE "$ka"; perf_set OPEN_FILE_CACHE "$ofc"; perf_set STATIC_EXPIRES "$exp"; perf_set PROXY_CACHE "$pc"
    perf_write_nginx_conf
    if ! nginx_test_reload; then
        err "nginx rejected the new settings; the previous state was restored."
        if [ -n "$backup" ]; then cp "$backup" "$PERF_NGINX_CONF"; else rm -f "$PERF_NGINX_CONF"; fi
        rm -f "$backup"; nginx_test_reload >/dev/null 2>&1 || true
        return 1
    fi
    rm -f "$backup"
    perf_set APPLIED yes
    info "Updating every project's nginx configuration..."
    nginx_refresh_all
    ok "Nginx tuning applied."
    next_steps \
        "Open a site and check it loads normally (press Ctrl+F5 once to bypass the old browser cache)." \
        "If a site shows old images or files after you replace them, use a different file name or set the static cache to 1d/off here." \
        "To undo everything: Performance tuning -> option 6."
}

perf_disable_nginx() {
    section "Turn Nginx tuning off"
    perf_applied || [ -f "$PERF_NGINX_CONF" ] || { info "Nginx tuning is not applied."; return 0; }
    confirm "Remove the tuning and go back to the original nginx settings?" n || return 0
    perf_set APPLIED no
    nginx_refresh_all
    rm -f "$PERF_NGINX_CONF"
    nginx_test_reload && ok "Nginx tuning is off."
}

# ---------- MariaDB ----------

perf_db_current() {   # bp | mc | skip
    local f="$DB_DIR/docker-compose.yml"
    [ -f "$f" ] || { printf 'n/a'; return 0; }
    case "$1" in
        bp)   sed -n 's/.*--innodb-buffer-pool-size=\(.*\)$/\1/p' "$f" | head -n1 ;;
        mc)   sed -n 's/.*--max-connections=\(.*\)$/\1/p' "$f" | head -n1 ;;
        skip) grep -q -- '--skip-name-resolve' "$f" && echo yes || echo no ;;
    esac
}

mariadb_write_compose() {   # BUFFER_POOL MAX_CONNECTIONS SKIP_NAME_RESOLVE(yes|no)
    local bp="$1" mc="$2" skip="$3" skip_line=""
    [ "$skip" = "yes" ] && skip_line="      - --skip-name-resolve"
    cat > "$DB_DIR/docker-compose.yml" <<EOF
services:
  mariadb:
    image: ${MARIADB_IMAGE}
    container_name: ${DB_CONTAINER}
    restart: always
    environment:
      MARIADB_ROOT_PASSWORD: \${MARIADB_ROOT_PASSWORD}
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --innodb-buffer-pool-size=${bp}
      - --max-connections=${mc}
${skip_line}
    volumes:
      - mariadb_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - ${NETWORK}

networks:
  ${NETWORK}:
    external: true

volumes:
  mariadb_data:
EOF
}

perf_wait_db() {
    local i status=""
    for i in $(seq 1 40); do
        status="$(docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER" 2>/dev/null)"
        [ "$status" = "healthy" ] && return 0
        sleep 3
    done
    return 1
}

perf_apply_mariadb() {
    section "MariaDB tuning"
    [ -f "$DB_DIR/docker-compose.yml" ] || { err "MariaDB was not installed by HiDeploy (compose file not found)."; return 1; }
    container_running "$DB_CONTAINER" || { err "The MariaDB container is not running."; return 1; }
    perf_scan; perf_suggest
    explain \
        "Memory for caching data and the number of simultaneous connections, sized for this server." \
        "'skip-name-resolve' stops MariaDB from doing a reverse-DNS lookup for every new connection, a classic cause of" \
        "multi-second delays on the first request. It is safe here: HiDeploy users are created for any host ('%')."
    local bp mc skip old_bp old_mc old_skip backup
    old_bp="$(perf_db_current bp)"; old_mc="$(perf_db_current mc)"; old_skip="$(perf_db_current skip)"
    while true; do ask "InnoDB buffer pool (e.g. 128M, 256M, 1G; about 25% of RAM is typical)" "$SG_BP" bp; bp="${bp^^}"; [[ "$bp" =~ ^[1-9][0-9]*[MG]$ ]] && break; err "Use a number with M or G."; done
    while true; do ask "Maximum simultaneous connections" "$SG_MAXCONN" mc; [[ "$mc" =~ ^[0-9]+$ ]] && [ "$mc" -ge 20 ] && [ "$mc" -le 1000 ] && break; err "Enter a number from 20 to 1000."; done
    if confirm "Enable skip-name-resolve (faster connections)?" y; then skip="yes"; else skip="no"; fi
    echo ""
    printf '  Buffer pool: %s -> %s   Connections: %s -> %s   skip-name-resolve: %s -> %s\n\n' "$old_bp" "$bp" "$old_mc" "$mc" "$old_skip" "$skip"
    warn "MariaDB restarts (about 10-30 seconds). During that time all sites that use a database show errors."
    explain "Your data is not touched. Safest: make a backup first (main menu 6 -> Run a backup NOW)."
    confirm "Restart MariaDB with these settings now?" n || { info "Cancelled."; return 0; }
    backup="$DB_DIR/docker-compose.yml.bak-$(date +%F_%H%M%S)"
    cp "$DB_DIR/docker-compose.yml" "$backup"
    mariadb_write_compose "$bp" "$mc" "$skip"
    info "Restarting MariaDB..."
    docker compose -f "$DB_DIR/docker-compose.yml" up -d >/dev/null 2>&1
    if perf_wait_db; then
        perf_set DB_BP "$bp"; perf_set DB_MAXCONN "$mc"; perf_set DB_SKIP_NAME_RESOLVE "$skip"
        ok "MariaDB is healthy with the new settings."
    else
        err "MariaDB did not become healthy. Restoring the previous settings..."
        cp "$backup" "$DB_DIR/docker-compose.yml"
        docker compose -f "$DB_DIR/docker-compose.yml" up -d >/dev/null 2>&1
        perf_wait_db && ok "Previous settings restored; MariaDB is healthy." || err "Check: docker logs $DB_CONTAINER"
        return 1
    fi
}

# ---------- PHP-FPM (Laravel) ----------

perf_apply_fpm() {
    section "PHP-FPM tuning (Laravel project)"
    explain \
        "'ondemand' starts a PHP worker only when a visitor arrives and stops it after 10 idle seconds: very light on RAM," \
        "but the first visit after a quiet moment must wait for a worker (and Laravel) to start." \
        "'dynamic' keeps a few workers ready, so the first visit is fast. It uses a bit more RAM."
    choose_project || { info "Cancelled."; return 0; }
    local path="$PROJECT_PATH" mem_mb pm max start mins maxs idle cur_pm cur_max
    load_project "$path" || return 1
    if is_next; then info "This is a Next.js project: PHP-FPM does not apply."; return 0; fi
    if ! grep -q 'FPM_PM' "$APP_PATH/docker-compose.prod.yml" 2>/dev/null; then
        warn "This project uses an older template without PHP-FPM tuning."
        explain "Regenerate the project files (main menu 3), copy them into your project, commit and push, then come back."
        return 1
    fi
    mem_mb="$(mem_to_mb "$(normalize_mem "${MEM_LIMIT:-512m}" 2>/dev/null || echo 512m)")"
    perf_scan; perf_fpm_suggest "$mem_mb"
    cur_pm="$(kv_get "$APP_PATH/.deploy.env" FPM_PM)"; cur_max="$(kv_get "$APP_PATH/.deploy.env" FPM_MAX_CHILDREN)"
    printf '\n  Project memory limit: %s MB   Current: %s, max workers %s\n' "$mem_mb" "${cur_pm:-ondemand (default)}" "${cur_max:-5 (default)}"
    while true; do ask "Process manager (ondemand / dynamic / static)" "${cur_pm:-$SG_FPM_PM}" pm; pm="${pm,,}"; [[ "$pm" =~ ^(ondemand|dynamic|static)$ ]] && break; err "Choose ondemand, dynamic or static."; done
    while true; do ask "Maximum PHP workers (about 50 MB each)" "${cur_max:-$SG_FPM_MAX}" max; [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -ge 1 ] && [ "$max" -le 100 ] && break; err "Enter a number from 1 to 100."; done
    start="$SG_FPM_START"; mins="$SG_FPM_MIN"; maxs="$SG_FPM_MAXS"; idle="10s"
    if [ "$pm" = "dynamic" ]; then
        [ "$maxs" -gt "$max" ] && maxs="$max"; [ "$start" -gt "$maxs" ] && start="$maxs"; [ "$mins" -gt "$start" ] && mins="$start"
        while true; do
            ask "Workers started at boot" "$start" start
            ask "Minimum idle workers kept ready" "$mins" mins
            ask "Maximum idle workers" "$maxs" maxs
            if [[ "$start$mins$maxs" =~ ^[0-9]+$ ]] && [ "$mins" -ge 1 ] && [ "$mins" -le "$start" ] && [ "$start" -le "$maxs" ] && [ "$maxs" -le "$max" ]; then break; fi
            err "Rule: 1 <= minimum idle <= started <= maximum idle <= maximum workers ($max)."
        done
    fi
    if [ $(( max * 50 + 100 )) -gt "$mem_mb" ]; then
        warn "$max workers could need about $(( max * 50 + 100 )) MB but the container limit is ${mem_mb} MB. Lower the workers or raise the memory limit."
        confirm "Apply anyway?" n || { info "Cancelled."; return 0; }
    fi
    env_set "$APP_PATH/.deploy.env" FPM_PM "$pm"
    env_set "$APP_PATH/.deploy.env" FPM_MAX_CHILDREN "$max"
    env_set "$APP_PATH/.deploy.env" FPM_START_SERVERS "$start"
    env_set "$APP_PATH/.deploy.env" FPM_MIN_SPARE "$mins"
    env_set "$APP_PATH/.deploy.env" FPM_MAX_SPARE "$maxs"
    env_set "$APP_PATH/.deploy.env" FPM_IDLE_TIMEOUT "$idle"
    info "Recreating the container with the new settings (a few seconds; visitors see the friendly page)..."
    dc up -d || { err "Could not recreate the container."; return 1; }
    wait_container && ok "PHP-FPM tuning applied: $pm, up to $max workers."
}

# ---------- diagnosis ----------

perf_diagnose() {
    section "Why is the first load slow? (diagnosis)"
    explain \
        "For each site: three requests straight to nginx on this server, then one through the public internet." \
        "Tip: run it after the sites were idle for a minute, so run 1 shows the 'cold' behaviour."
    local p dom scheme i out dns conn tls ttfb total code t1 t2 t3 pub dbms
    local found=0
    while IFS= read -r p; do
        found=1
        dom="$(basename "$p")"; load_project "$p" || continue
        scheme="http"; [ -d "$NGINX_DIR/letsencrypt/live/$dom" ] && scheme="https"
        printf '\n  %s%s%s (%s)\n' "$C_BOLD" "$dom" "$C_RESET" "${PROJECT_TYPE:-laravel}"
        t1=0; t2=0; t3=0
        for i in 1 2 3; do
            out="$(curl -o /dev/null -s -k --max-time 40 --resolve "$dom:443:127.0.0.1" --resolve "$dom:80:127.0.0.1" \
                -w '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{http_code}' "$scheme://$dom/" 2>/dev/null)"
            read -r dns conn tls ttfb total code <<< "${out:-0 0 0 0 0 000}"
            printf '    run %s (nginx on this server): first byte %.2fs, total %.2fs, HTTP %s\n' "$i" "$ttfb" "$total" "$code"
            case "$i" in 1) t1="$ttfb" ;; 2) t2="$ttfb" ;; 3) t3="$ttfb" ;; esac
        done
        out="$(curl -o /dev/null -s --max-time 40 -w '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{http_code}' "$scheme://$dom/" 2>/dev/null)"
        read -r dns conn tls ttfb total code <<< "${out:-0 0 0 0 0 000}"
        pub="$ttfb"
        printf '    public internet:               DNS %.2fs, connect %.2fs, first byte %.2fs, HTTP %s\n' "$dns" "$conn" "$ttfb" "$code"
        if ! is_next && [ "${USE_DATABASE:-yes}" = "yes" ] && container_running "$CONTAINER_NAME"; then
            dbms="$(docker exec -u "$APP_UID:$APP_GID" -w "$APP_PATH" "$CONTAINER_NAME" php -r '$e=@parse_ini_file(".env"); if(!$e||empty($e["DB_HOST"])){echo "unknown";exit;} $t=microtime(true); try{ new PDO("mysql:host=".$e["DB_HOST"].";port=".($e["DB_PORT"]??3306).";dbname=".$e["DB_DATABASE"],$e["DB_USERNAME"],$e["DB_PASSWORD"],[PDO::ATTR_TIMEOUT=>10]); echo round((microtime(true)-$t)*1000);}catch(Throwable $x){echo "error";}' 2>/dev/null)"
            printf '    database connection from the app: %s\n' "$( [[ "$dbms" =~ ^[0-9]+$ ]] && echo "${dbms} ms" || echo "${dbms:-unknown}" )"
        else
            dbms=""
        fi
        # interpretation
        if awk -v a="$t1" -v b="$t2" 'BEGIN{exit !(a>1.5 && b<a/2)}'; then
            echo "    -> COLD START: the first request after a quiet moment is slow, the next ones are fast."
            if is_next; then echo "       Next.js starts instantly once running; check that the container is not being restarted (docker ps)."
            else echo "       Laravel: keep PHP workers ready (Performance tuning -> option 4, 'dynamic')."; fi
        elif awk -v a="$t1" -v b="$t2" -v c="$t3" 'BEGIN{exit !(a>1.5 && b>1.5 && c>1.5)}'; then
            echo "    -> EVERY request is slow on the server itself: heavy code, slow database, or too little RAM."
        elif awk -v a="$t2" -v b="$pub" 'BEGIN{exit !(b>1.5 && b>a*3)}'; then
            echo "    -> The server answers fast, but the public path is slow: DNS, IPv6 (an AAAA record that does not reach this server) or the network."
        else
            echo "    -> Response times look healthy."
        fi
        if [[ "${dbms:-}" =~ ^[0-9]+$ ]] && [ "$dbms" -gt 1000 ]; then
            echo "    -> The database connection is slow (${dbms} ms): MariaDB tuning (option 3, skip-name-resolve) usually fixes this."
        fi
    done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null | sort)
    [ "$found" -eq 1 ] || info "No projects yet."
}

menu_perf() {
    local c
    while true; do
        clear; banner "7) Performance tuning" "$C_BLUE"
        explain "Nothing is changed until you apply it. Suggested values are based on a scan of this server." ""
        if perf_applied; then printf '  Nginx tuning: %sAPPLIED%s\n\n' "$C_GREEN" "$C_RESET"; else printf '  Nginx tuning: not applied (sites use the original settings)\n\n'; fi
        echo " 1) Scan this server and show suggested settings"
        echo " 2) Nginx tuning (compression, keep-alive, static file caching)"
        echo " 3) MariaDB tuning (memory, connections, faster connections)"
        echo " 4) PHP-FPM tuning for a Laravel project (keep workers warm)"
        echo " 5) Find out why a site is slow on first load (diagnosis)"
        echo " 6) Turn Nginx tuning off (back to the original settings)"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item perf_show_scan ;;
            2) run_item perf_apply_nginx ;;
            3) run_item perf_apply_mariadb ;;
            4) run_item perf_apply_fpm ;;
            5) run_item perf_diagnose ;;
            6) run_item perf_disable_nginx ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# MAIN MENUS
# ============================================================================

run_item() { echo ""; "$@"; pause; }

menu_prepare() {
    local c
    while true; do
        clear; banner "1) Prepare Server (run once per server)" "$C_CYAN"
        show_status; echo ""
        echo " 1) Update system & install essential tools"
        echo " 2) Install Docker + Compose plugin"
        echo " 3) Create shared network '$NETWORK'"
        echo " 4) Install GitLab Runner"
        echo " 5) Register GitLab Runner"
        echo " 6) Runner access (docker group + SSH key)"
        echo " 7) Firewall (optional)"
        echo " 8) Swap file (optional)"
        echo " A) Run ALL of the above in order"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item step_essentials ;;      2) run_item step_docker ;;
            3) run_item step_network ;;         4) run_item step_runner_install ;;
            5) run_item step_runner_register ;; 6) run_item step_runner_access ;;
            7) run_item step_firewall ;;        8) run_item step_swap ;;
            [Aa]) run_item run_all_prepare ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

menu_services() {
    local c
    while true; do
        clear; banner "2) Shared Services (run once per server)" "$C_BLUE"
        show_status; echo ""
        echo " 1) Install nginx container (receives all web traffic)"
        echo " 2) Install MariaDB container (stores all databases)"
        echo " 3) Enable SSL auto-renew"
        echo " 4) Show status"
        echo " 5) phpMyAdmin (optional: web UI for your databases, on its own domain)"
        echo " A) Run ALL of the above in order"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item step_nginx_install ;;   2) run_item step_mariadb_install ;;
            3) run_item step_renew_enable ;;    4) run_item services_status ;;
            5) menu_phpmyadmin ;;
            [Aa]) run_item run_all_services ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

usage() {
    cat <<EOF
HiDeploy $HIDEPLOY_VERSION — deploy Laravel and Next.js projects from GitLab to your own server

Usage:
  sudo hideploy            open the interactive menu
  hideploy --version       show the installed version
  hideploy --help          show this help
  sudo hideploy update     install the latest version from GitHub (${HIDEPLOY_REPO})
  sudo hideploy backup-run run one backup now (this is what the nightly job calls)
  sudo hideploy cleanup-run run the safe disk cleanup now (the weekly job calls this)
EOF
}

main() {
    case "${1:-}" in
        -v|--version|version) echo "HiDeploy $HIDEPLOY_VERSION"; exit 0 ;;
        -h|--help|help)       usage; exit 0 ;;
        update)
            [ "$EUID" -eq 0 ] || { err "Run as root: sudo hideploy update"; exit 1; }
            curl -fsSL "https://raw.githubusercontent.com/${HIDEPLOY_REPO}/main/install.sh" | bash
            exit $? ;;
        backup-run)
            [ "$EUID" -eq 0 ] || { echo "Run as root: sudo hideploy backup-run" >&2; exit 1; }
            backup_run
            exit $? ;;
        cleanup-run)
            [ "$EUID" -eq 0 ] || { echo "Run as root: sudo hideploy cleanup-run" >&2; exit 1; }
            cleanup_safe
            exit 0 ;;
        "") ;;
        *) err "Unknown command: $1"; usage; exit 1 ;;
    esac
    if [ "$EUID" -ne 0 ]; then err "Please run as root:  sudo $0"; exit 1; fi
    if [ -r /etc/os-release ] && ! grep -qiE 'ubuntu|debian' /etc/os-release; then
        warn "This script is designed for Ubuntu/Debian. Other systems are not supported."
    fi
    local c
    while true; do
        clear; banner "HiDeploy $HIDEPLOY_VERSION" "$C_BOLD"
        show_status; echo ""
        echo " 1) Prepare Server              (once per server: Docker, runner, network)"
        echo " 2) Shared Services             (once per server: nginx + MariaDB + SSL auto-renew)"
        echo " 3) Generate Project Files      (Dockerfile, compose, CI for your repository)"
        echo " 4) Deploy New Project  (for every new site)"
        echo " 5) Manage Projects             (deploy, logs, backup, SSL, remove)"
        echo " 6) Backups                     (automatic, encrypted, copied off the server)"
        echo " 7) Performance tuning          (nginx, MariaDB, PHP-FPM: faster pages, less cold start)"
        echo " 0) Exit"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) menu_prepare ;;
            2) menu_services ;;
            3) menu_generate_files ;;
            4) deploy_wizard ;;
            5) menu_manage ;;
            6) menu_backups ;;
            7) menu_perf ;;
            0) ok "Bye."; exit 0 ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# Run the menu only when executed directly (allows sourcing for tests)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
