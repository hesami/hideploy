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

HIDEPLOY_VERSION="1.0.0"
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
    if [ "$(project_count)" -eq 0 ];     then echo "Choose 3) Generate Project Files, then 4) Deploy New Laravel Project"; return; fi
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

# PHP-FPM pool (low-memory friendly)
RUN printf '%s\n' \
      '[www]' \
      'user = app' \
      'group = app' \
      'pm = ondemand' \
      'pm.max_children = 5' \
      'pm.process_idle_timeout = 10s' \
      'pm.max_requests = 500' \
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

      echo "==> Health check (informational)"
      curl -s -o /dev/null -w "HTTPS status: %{http_code}\n" -k --max-time 15 \
        --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/up" || true

      echo "Deployment finished successfully."
EOF
}

# generate_project_files DIR DOMAIN BRANCH TAG OVERWRITE(yes|no)
generate_project_files() {
    local dir="$1" domain="$2" branch="$3" tag="$4" overwrite="$5" tmp f
    tmp="$(mktemp -d)"
    tpl_dockerfile   > "$tmp/Dockerfile"
    tpl_compose      > "$tmp/docker-compose.prod.yml"
    tpl_dockerignore > "$tmp/.dockerignore"
    tpl_ci | sed -e "s|__TAG__|$tag|g" -e "s|__BRANCH__|$branch|g" \
                 -e "s|__DEPLOY_PATH__|$PROJECTS_DIR/$domain|g" > "$tmp/.gitlab-ci.yml"
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
    local domain branch tag outdir
    while true; do ask "Project domain (e.g. api.example.com)" "" domain; domain="${domain,,}"; valid_domain "$domain" && break; err "Invalid domain."; done
    ask "Git branch that triggers deployment" "main" branch
    ask "GitLab runner tag" "$(cfg_get RUNNER_TAG || true)" tag
    tag="${tag:-production}"
    cfg_set RUNNER_TAG "$tag"
    outdir="$TEMPLATES_DIR/$domain"
    echo ""
    generate_project_files "$outdir" "$domain" "$branch" "$tag" yes
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
        "Then come back and choose 4) Deploy New Laravel Project."
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
    root="$PROJECTS_DIR/$domain/public"
    {
        if [ "$mode" = "http" ]; then
            echo "server {"
            echo "    listen 80;"
            echo "    server_name __DOMAIN__;"
            tpl_vhost_common
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
            tpl_vhost_common
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
    FRONTEND_BUILD="no"; USE_DATABASE="yes"; NODE_IMAGE="$DEFAULT_NODE_IMAGE"
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

# deploy_project PATH [pull yes|no]  — same steps as the CI pipeline
deploy_project() {
    local path="$1" pull="${2:-yes}"
    load_project "$path" || return 1
    cd "$path" || return 1
    if [ "$pull" = "yes" ]; then
        info "Pulling latest code from origin/$BRANCH"
        git_sync "$path" "$BRANCH" || { err "git update failed."; return 1; }
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
        info "This project has no database — skipping migrations."
    fi
    artisan storage:link >/dev/null 2>&1 || true
    info "Refreshing caches and restarting queue workers"
    artisan optimize:clear >/dev/null && artisan optimize && artisan queue:restart
    ok "Deployment finished."
}

# git_sync PATH BRANCH — update the server copy; handles a stale/in-use .git/index.lock safely
git_sync() {
    local path="$1" branch="$2" lock="$1/.git/index.lock" i
    for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$lock" ] || break; sleep 1; done
    if [ -f "$lock" ]; then
        if pgrep -u "$RUNNER_USER" -x git >/dev/null 2>&1; then
            err "Another git process is still running in $path. Wait until it finishes, then try again."
            return 1
        fi
        warn "Removing a stale git lock file: $lock"
        rm -f "$lock"
    fi
    as_runner git -C "$path" fetch origin "$branch" && as_runner git -C "$path" reset --hard "origin/$branch"
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
    local path="$1" db dbuser file mode typed tables maint="no" rc=0
    load_project "$path" || return 1
    section "Restore database — $(basename "$path")"
    [ "$USE_DATABASE" = "yes" ] || { err "This project has no database. Use 'Add a database' first."; return 1; }
    container_running "$DB_CONTAINER" || { err "The MariaDB container is not running."; return 1; }
    db="$(env_get "$path/.env" DB_DATABASE)"; dbuser="$(env_get "$path/.env" DB_USERNAME)"
    valid_ident "$db" || { err "DB_DATABASE is missing or invalid in $path/.env"; return 1; }
    explain \
        "Target database: $db" \
        "Supports .sql and .sql.gz files. Dumps from MySQL 8 are converted automatically if needed."
    pick_sql_file file || { info "Cancelled."; return 0; }
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
    if container_running "$CONTAINER_NAME" && confirm "Put the site in maintenance mode during the restore?" y; then
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
    if confirm "Run pending migrations now (needed if your code is newer than the backup)?" y; then
        artisan migrate --force || warn "Migration reported an error."
    fi
    artisan optimize:clear >/dev/null 2>&1 && artisan optimize >/dev/null 2>&1; artisan queue:restart >/dev/null 2>&1
    ok "Restore complete. Check the site in your browser."
}

choose_project() {
    local -a paths=()
    mapfile -t paths < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null | sort)
    if [ "${#paths[@]}" -eq 0 ]; then err "No projects deployed yet."; return 1; fi
    local i=1 p dom state days
    printf '\n%-4s %-34s %-12s %-10s\n' "#" "DOMAIN" "CONTAINER" "SSL DAYS"
    for p in "${paths[@]}"; do
        dom="$(basename "$p")"
        if ( . "$p/.deploy.env"; container_running "$CONTAINER_NAME" ); then state="${C_GREEN}running${C_RESET}"; else state="${C_RED}stopped${C_RESET}"; fi
        days="$(cert_days "$dom")"
        printf '%-4s %-34s %-21s %-10s\n' "$i" "$dom" "$state" "${days:--}"
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
        echo "13) Remove this project"
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
            13) project_remove "$path"; pause; return ;;
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
    clear; banner "4) Deploy New Laravel Project" "$C_MAGENTA"
    explain \
        "This wizard does everything for ONE project, step by step:" \
        "  DNS check → clone → settings → project files → database → .env → build → nginx → SSL → CI/CD guide" \
        "You can stop at any prompt with Ctrl-C and re-run it later; finished steps are detected and skipped."
    echo ""
    require_stack || { pause; return; }

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
HiDeploy $HIDEPLOY_VERSION — deploy Laravel projects from GitLab to your own server

Usage:
  sudo hideploy            open the interactive menu
  hideploy --version       show the installed version
  hideploy --help          show this help
  sudo hideploy update     install the latest version from GitHub (${HIDEPLOY_REPO})
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
        echo " 4) Deploy New Laravel Project  (for every new site)"
        echo " 5) Manage Projects             (deploy, logs, backup, SSL, remove)"
        echo " 0) Exit"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) menu_prepare ;;
            2) menu_services ;;
            3) menu_generate_files ;;
            4) deploy_wizard ;;
            5) menu_manage ;;
            0) ok "Bye."; exit 0 ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# Run the menu only when executed directly (allows sourcing for tests)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
