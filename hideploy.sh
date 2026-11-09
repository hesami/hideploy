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
#   8) Security (firewall with lockout guard, fail2ban, automatic security updates, SSH, checks)
#   9) Email (own mail server for all your domains: mailboxes, DKIM/SPF/DMARC help, optional webmail)
#  10) Notifications (email + Telegram alerts: deployments, backups, stopped services, disk, certificates)
#  Databases: MariaDB or PostgreSQL per project (Laravel and Next.js).  nginx: optional Brotli compression (Shared Services).
#  11) Updates and versions (every version is suggested and chosen by you; update center with backup + automatic roll-back;
#      guided major upgrades for MariaDB / PostgreSQL / Redis; PHP and Node version per project)
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

HIDEPLOY_VERSION="1.9.0"
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
MARIADB_IMAGE="mariadb:12.3"           # default for NEW installs only (the installer asks); installed servers keep the image of their compose file
PMA_IMAGE="phpmyadmin:5-apache"
CERTBOT_IMAGE="certbot/certbot"
DEFAULT_NODE_VERSION="26"                # suggestion for Node.js (frontend builds, Next.js); every project can choose its own
DEFAULT_NODE_IMAGE="node:${DEFAULT_NODE_VERSION}-alpine"   # used for temporary frontend-build containers

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

# Redis (optional shared service)
REDIS_CONTAINER="global-redis"
REDIS_DIR="$INFRA_DIR/redis"
REDIS_IMAGE="redis:8-alpine"

# Email (optional shared service: own mail server + optional webmail, main menu 9)
MAIL_CONTAINER="global-mailserver"
MAIL_DIR="$INFRA_DIR/mail"                 # config/ = accounts, aliases, DKIM keys (in every backup); data/ = messages
MAIL_IMAGE="ghcr.io/docker-mailserver/docker-mailserver:latest"
MAIL_DKIM_SELECTOR="mail"
MAIL_PORTS="25 465 587 993"
MAILWEB_CONTAINER="global-webmail"
MAILWEB_DIR="$INFRA_DIR/webmail"
MAILWEB_IMAGE="roundcube/roundcubemail:latest-apache"
MAILWEB_HTPASSWD="$NGINX_DIR/conf.d/webmail.htpasswd"

# Notifications (email + Telegram, main menu 10)
NOTIFY_DIR="$INFRA_DIR/notify"             # settings and secrets (root only)
NOTIFY_CONF="$NOTIFY_DIR/notify.env"
NOTIFY_STATE="$NOTIFY_DIR/state"
NOTIFY_LOCK="$NOTIFY_DIR/.lock"
NOTIFY_SPOOL="/var/spool/hideploy-notify"  # pipelines drop small event files here (no secrets in it)
NOTIFY_CRON="/etc/cron.d/hideploy-notify"
NOTIFY_LOG="/var/log/hideploy-notify.log"
TG_API_BASE="https://api.telegram.org"

# PostgreSQL (optional second database server, chosen per project)
PG_DIR="$INFRA_DIR/postgres"
PG_CONTAINER="global-postgres"
POSTGRES_IMAGE="postgres:18-bookworm"      # default for NEW installs; a major upgrade (17 -> 18) is a guided dump and restore: main menu 11

# Brotli (optional: nginx image with the Brotli modules, built from source on this server)
NGINX_BROTLI_DIR="$NGINX_DIR/brotli-build"
NGINX_BROTLI_TAG="hideploy-nginx-brotli"
NGX_BROTLI_REF="master"                    # a branch or tag of github.com/google/ngx_brotli; "master" = the newest
BROTLI_CONF="$NGINX_DIR/conf.d/01-brotli.conf"

# Security (main menu 8)
SEC_DIR="$INFRA_DIR/security"              # settings and SSH backups (no secrets)
SEC_CONF="$SEC_DIR/security.env"
SEC_GUARD_SECS=120                         # how long you have to confirm a firewall / SSH change before it is undone

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
# Database engines: MariaDB (MySQL-compatible) and PostgreSQL
# ----------------------------------------------------------------------------
# Each project records its engine in .deploy.env (DB_ENGINE=mariadb|postgres). A project WITHOUT that key is a
# MariaDB project, so everything created before PostgreSQL support existed keeps working exactly as before.
# Both servers are shared containers on the internal network and are never exposed to the internet.

db_engine_of()    { local e; e="$(kv_get "$1/.deploy.env" DB_ENGINE)"; if [ "$e" = "postgres" ]; then echo postgres; else echo mariadb; fi; }
db_engine_label() { if [ "$1" = "postgres" ]; then echo "PostgreSQL"; else echo "MariaDB"; fi; }
db_container_of() { if [ "$1" = "postgres" ]; then echo "$PG_CONTAINER"; else echo "$DB_CONTAINER"; fi; }
db_port_of()      { if [ "$1" = "postgres" ]; then echo 5432; else echo 3306; fi; }
db_running()      { container_running "$(db_container_of "$1")"; }

# PostgreSQL names are always double-quoted below, so letters/digits/_ are safe; these extra rules avoid reserved names
valid_pg_name() { valid_ident "$1" && [ "${#1}" -le 63 ] && [[ "$1" != pg_* ]]; }
valid_db_name() { if [ "$1" = "postgres" ]; then valid_pg_name "$2" && [ "$2" != "postgres" ] && [ "$2" != "template0" ] && [ "$2" != "template1" ]; else valid_ident "$2"; fi; }
valid_db_user() { if [ "$1" = "postgres" ]; then valid_pg_name "$2" && [ "$2" != "postgres" ]; else valid_ident "$2"; fi; }

# PostgreSQL quoting: literal 'it''s' and identifier "name"
pg_lit()   { local q="'" s="$1"; s="${s//$q/$q$q}"; printf "'%s'" "$s"; }
pg_ident() { local q='"' s="$1"; s="${s//$q/$q$q}"; printf '"%s"' "$s"; }

# Run SQL (from stdin) as the PostgreSQL superuser inside the shared container (local socket: no password on any command line)
# usage:  printf '...' | pg_sql [-d DATABASE]
pg_sql() { docker exec -i "$PG_CONTAINER" psql -U postgres -X -q -At -v ON_ERROR_STOP=1 "$@"; }

dbx_db_exists() {   # ENGINE DB -> prints 0 or 1
    if [ "$1" = "postgres" ]; then printf 'SELECT count(*) FROM pg_database WHERE datname=%s;\n' "$(pg_lit "$2")" | pg_sql
    else printf "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='%s';\n" "$2" | db_sql; fi
}

dbx_user_exists() {   # ENGINE USER -> prints 0 or 1
    if [ "$1" = "postgres" ]; then printf 'SELECT count(*) FROM pg_roles WHERE rolname=%s;\n' "$(pg_lit "$2")" | pg_sql
    else printf "SELECT COUNT(*) FROM mysql.user WHERE User='%s';\n" "$2" | db_sql; fi
}

# dbx_provision ENGINE DB USER PASS — creates (or reuses) the database and the user, and sets the password.
dbx_provision() {
    local e="$1" db="$2" user="$3" pass="$4"
    if [ "$e" = "postgres" ]; then
        {
            printf 'DO $do$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = %s) THEN CREATE ROLE %s LOGIN PASSWORD %s; ELSE ALTER ROLE %s WITH LOGIN PASSWORD %s; END IF; END $do$;\n' \
                "$(pg_lit "$user")" "$(pg_ident "$user")" "$(pg_lit "$pass")" "$(pg_ident "$user")" "$(pg_lit "$pass")"
            # CREATE DATABASE cannot run inside a function: psql's \gexec runs the generated statement
            printf "SELECT 'CREATE DATABASE %s OWNER %s ENCODING ''UTF8'' TEMPLATE template0' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = %s)\\\\gexec\n" \
                "$(pg_ident "$db")" "$(pg_ident "$user")" "$(pg_lit "$db")"
            printf 'ALTER DATABASE %s OWNER TO %s;\n' "$(pg_ident "$db")" "$(pg_ident "$user")"
            # other projects' users must not even be able to connect to this database
            printf 'REVOKE ALL ON DATABASE %s FROM PUBLIC;\nGRANT ALL ON DATABASE %s TO %s;\n' "$(pg_ident "$db")" "$(pg_ident "$db")" "$(pg_ident "$user")"
        } | pg_sql
    else
        printf "CREATE DATABASE IF NOT EXISTS \`%s\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\nCREATE USER IF NOT EXISTS '%s'@'%%' IDENTIFIED BY '%s';\nALTER USER '%s'@'%%' IDENTIFIED BY '%s';\nGRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%%';\nFLUSH PRIVILEGES;\n" \
            "$db" "$user" "$(sql_escape "$pass")" "$user" "$(sql_escape "$pass")" "$db" "$user" | db_sql
    fi
}

# dbx_drop ENGINE DB USER — removes the database and its user
dbx_drop() {
    local e="$1" db="$2" user="$3"
    if [ "$e" = "postgres" ]; then
        printf 'DROP DATABASE IF EXISTS %s WITH (FORCE);\n' "$(pg_ident "$db")" | pg_sql || return 1
        printf 'DROP ROLE IF EXISTS %s;\n' "$(pg_ident "$user")" | pg_sql
    else
        printf "DROP DATABASE IF EXISTS \`%s\`;\nDROP USER IF EXISTS '%s'@'%%';\n" "$db" "$(sql_escape "$user")" | db_sql
    fi
}

# dbx_recreate ENGINE DB USER — an empty database with the same name and owner (used before a REPLACE restore)
dbx_recreate() {
    local e="$1" db="$2" user="$3"
    if [ "$e" = "postgres" ]; then
        {
            printf 'DROP DATABASE IF EXISTS %s WITH (FORCE);\n' "$(pg_ident "$db")"
            printf 'CREATE DATABASE %s OWNER %s ENCODING %s TEMPLATE template0;\n' "$(pg_ident "$db")" "$(pg_ident "$user")" "$(pg_lit UTF8)"
            printf 'REVOKE ALL ON DATABASE %s FROM PUBLIC;\nGRANT ALL ON DATABASE %s TO %s;\n' "$(pg_ident "$db")" "$(pg_ident "$db")" "$(pg_ident "$user")"
        } | pg_sql
    else
        printf "DROP DATABASE IF EXISTS \`%s\`;\nCREATE DATABASE \`%s\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\nGRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%%';\nFLUSH PRIVILEGES;\n" \
            "$db" "$db" "$db" "$(sql_escape "$user")" | db_sql
    fi
}

dbx_table_count() {   # ENGINE DB -> number of tables (0 when the database does not exist)
    local n
    if [ "$1" = "postgres" ]; then
        n="$(printf "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');\n" | pg_sql -d "$2" 2>/dev/null)"
    else
        n="$(printf "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='%s';\n" "$2" | db_sql 2>/dev/null)"
    fi
    printf '%s' "${n:-0}"
}

# dbx_dump ENGINE DB [extra mariadb-dump options] — plain SQL on stdout
dbx_dump() {
    local e="$1" db="$2"; shift 2
    if [ "$e" = "postgres" ]; then
        docker exec "$PG_CONTAINER" pg_dump -U postgres --no-owner --no-acl "$db"
    else
        docker exec "$DB_CONTAINER" sh -c 'db="$1"; shift; MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --routines "$@" --databases "$db"' _ "$db" "$@"
    fi
}

# After an import the objects belong to the superuser: hand them to the owner of the database
pg_fix_owner() {   # DB
    pg_sql -d "$1" <<'SQL'
DO $fix$
DECLARE r record; o text;
BEGIN
  SELECT pg_catalog.pg_get_userbyid(datdba) INTO o FROM pg_database WHERE datname = current_database();
  FOR r IN SELECT schemaname AS s, tablename AS n FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') LOOP
    EXECUTE format('ALTER TABLE %I.%I OWNER TO %I', r.s, r.n, o);
  END LOOP;
  FOR r IN SELECT schemaname AS s, viewname AS n FROM pg_views WHERE schemaname NOT IN ('pg_catalog','information_schema') LOOP
    EXECUTE format('ALTER VIEW %I.%I OWNER TO %I', r.s, r.n, o);
  END LOOP;
  FOR r IN SELECT schemaname AS s, matviewname AS n FROM pg_matviews WHERE schemaname NOT IN ('pg_catalog','information_schema') LOOP
    EXECUTE format('ALTER MATERIALIZED VIEW %I.%I OWNER TO %I', r.s, r.n, o);
  END LOOP;
  FOR r IN SELECT schemaname AS s, sequencename AS n FROM pg_sequences WHERE schemaname NOT IN ('pg_catalog','information_schema') LOOP
    BEGIN
      EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO %I', r.s, r.n, o);
    EXCEPTION WHEN OTHERS THEN NULL;   -- sequences that belong to a table column follow the table automatically
    END;
  END LOOP;
END $fix$;
SQL
}

# pg_import_file DB FILE — .sql or .sql.gz (a pg_dump in plain format) into an EXISTING database
pg_import_file() {
    local db="$1" file="$2" rc head_txt
    local -a reader
    valid_pg_name "$db" || { err "Invalid database name."; return 1; }
    [ -f "$file" ] && [ -s "$file" ] || { err "File not found or empty: $file"; return 1; }
    case "$file" in
        *.gz) gzip -t "$file" 2>/dev/null || { err "This is not a valid .gz file."; return 1; }
              reader=(gzip -dc -- "$file") ;;
        *)    reader=(cat -- "$file") ;;
    esac
    head_txt="$("${reader[@]}" 2>/dev/null | head -c 4096)"
    if grep -qE 'MySQL dump|MariaDB dump|ENGINE=InnoDB' <<<"$head_txt"; then
        err "This looks like a MySQL/MariaDB dump. A PostgreSQL database needs a PostgreSQL dump (pg_dump, plain SQL format)."
        return 1
    fi
    info "Importing $(du -h "$file" | cut -f1) into '$db' (all or nothing: one transaction) — large files can take several minutes..."
    # Lines that would create/rename databases, roles, owners or privileges are dropped so the data always lands in THIS
    # project's database. Rows inside COPY blocks are never touched.
    "${reader[@]}" | awk '
        BEGIN { c = 0 }
        { if (c) { print; if ($0 == "\\.") c = 0; next }
          if ($0 ~ /^COPY .* FROM stdin;$/) { c = 1; print; next }
          if ($0 ~ /^(CREATE|DROP|ALTER) DATABASE / || $0 ~ /^\\connect / || $0 ~ /^ALTER .* OWNER TO / || $0 ~ /^(GRANT|REVOKE) / \
              || $0 ~ /^(CREATE|ALTER|DROP) ROLE / || $0 ~ /^COMMENT ON DATABASE /) next
          print }' \
        | docker exec -i "$PG_CONTAINER" psql -U postgres -X -q -d "$db" -v ON_ERROR_STOP=1 --single-transaction >/dev/null
    rc="${PIPESTATUS[2]}"
    if [ "$rc" -ne 0 ]; then
        err "Import failed (see the SQL error above). Nothing was imported: the database is unchanged."
        return 1
    fi
    pg_fix_owner "$db" || warn "Imported, but the ownership of the tables could not be adjusted."
    ok "Import finished."
}

# ---------- choosing and preparing an engine for a project --------------------------------

db_engine_state() {   # ENGINE -> short status text
    local c; c="$(db_container_of "$1")"
    case "$(container_state "$c")" in
        running) printf 'running' ;;
        stopped) printf 'installed, stopped' ;;
        *)       printf 'not installed yet: it will be installed for you' ;;
    esac
}

# db_ensure_engine ENGINE — make sure the database server exists and runs (offers to install it)
db_ensure_engine() {
    local e="$1" c; c="$(db_container_of "$e")"
    db_running "$e" && return 0
    case "$(container_state "$c")" in
        stopped) info "Starting $(db_engine_label "$e")..."; docker start "$c" >/dev/null 2>&1; sleep 3
                 db_running "$e" && return 0
                 err "$(db_engine_label "$e") would not start. Check: docker logs $c"; return 1 ;;
        missing) confirm "$(db_engine_label "$e") is not installed on this server yet. Install it now?" y || return 1
                 if [ "$e" = "postgres" ]; then step_postgres_install; else step_mariadb_install; fi
                 db_running "$e" ;;
        *)       err "Docker is not ready."; return 1 ;;
    esac
}

# db_choose_engine TYPE(laravel|nextjs) — asks which database server a project uses; sets PROV_ENGINE
db_choose_engine() {
    local kind="$1" def=1 choice eng
    [ "$kind" = "nextjs" ] && def=2
    echo ""
    echo " Which database server should this project use?"
    printf '  1) MariaDB (MySQL-compatible)   %s(%s)%s\n' "$C_DIM" "$(db_engine_state mariadb)" "$C_RESET"
    printf '  2) PostgreSQL                   %s(%s)%s\n' "$C_DIM" "$(db_engine_state postgres)" "$C_RESET"
    explain "Both work with Laravel. Next.js tools (Prisma, Drizzle, TypeORM ...) usually feel most at home with PostgreSQL." \
            "Both servers can run side by side; every project picks one. The choice is fixed per project (data is not moved between engines)."
    while true; do
        read -r -p "Select [$def]: " choice; choice="${choice:-$def}"
        case "$choice" in 1) eng="mariadb"; break ;; 2) eng="postgres"; break ;; *) err "Choose 1 or 2." ;; esac
    done
    db_ensure_engine "$eng" || return 1
    PROV_ENGINE="$eng"
}

# Laravel needs the pdo_pgsql PHP extension for PostgreSQL; projects created by older HiDeploy versions do not have it
laravel_pg_ready() {   # PATH -> 0 when the Dockerfile (or the running container) has pdo_pgsql
    local path="$1"
    if container_running "${CONTAINER_NAME:-}" && docker exec "$CONTAINER_NAME" php -m 2>/dev/null | grep -qi '^pdo_pgsql$'; then return 0; fi
    grep -qs 'pdo_pgsql' "$path/Dockerfile"
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
    local mst pst; mst="$(container_state "$DB_CONTAINER")"; pst="$(container_state "$PG_CONTAINER")"
    if [ "$mst" = "missing" ] && [ "$pst" = "missing" ]; then echo "Choose 2) Shared Services -> Install MariaDB (or PostgreSQL)"; return; fi
    if [ "$mst" = "stopped" ]; then echo "MariaDB is stopped: docker start $DB_CONTAINER"; return; fi
    if [ "$pst" = "stopped" ]; then echo "PostgreSQL is stopped: docker start $PG_CONTAINER"; return; fi
    if ! renew_enabled;                  then echo "Choose 2) Shared Services -> Enable SSL auto-renew"; return; fi
    if [ "$(project_count)" -eq 0 ];     then echo "Choose 3) Generate Project Files, then 4) Deploy New Project"; return; fi
    if ! bk_enabled;                     then echo "Choose 6) Backups -> set up automatic, encrypted backups"; return; fi
    if [ "$(sec_fw_state)" != "active" ];   then echo "Choose 8) Security -> Firewall (with lockout protection)"; return; fi
    if [ "$(sec_f2b_state)" != "active" ];  then echo "Choose 8) Security -> fail2ban"; return; fi
    if [ "$(sec_auto_state)" != "on" ];     then echo "Choose 8) Security -> Automatic security updates"; return; fi
    if sec_reboot_needed;                   then echo "The server needs a reboot to finish updates: sudo reboot"; return; fi
    if ! nf_configured;                     then echo "Choose 10) Notifications -> get alerts by email or Telegram (deployments, backups, stopped services)"; return; fi
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
    pg_status_row
    brotli_status_row
    if renew_enabled; then status_row "SSL auto-renew" good "ENABLED"; else status_row "SSL auto-renew" warn "DISABLED"; fi
    pma_status_row
    redis_status_row
    mail_status_row
    mailweb_status_row
    nf_status_row
    bk_status_row
    sec_status_rows
    disk_row
    upd_status_row
    printf '  %-20s %s\n' "Deployed projects" "$(project_count)"
    printf '\n%sRecommended next step:%s %s\n' "$C_YELLOW" "$C_RESET" "$(suggest_next)"
}

require_stack() {
    local missing=0
    if ! docker_ready;                         then err "Docker is not ready.            → Main menu 1) Prepare Server"; missing=1; fi
    if docker_ready && ! net_exists;           then err "Network '$NETWORK' is missing.  → Main menu 1) Prepare Server"; missing=1; fi
    if ! id "$RUNNER_USER" >/dev/null 2>&1;    then err "GitLab Runner is not installed. → Main menu 1) Prepare Server"; missing=1; fi
    if docker_ready && ! container_running "$NGINX_CONTAINER"; then err "nginx container is not running. → Main menu 2) Shared Services"; missing=1; fi
    if docker_ready && ! container_running "$DB_CONTAINER" && ! container_running "$PG_CONTAINER"; then err "No database server is running (MariaDB or PostgreSQL). → Main menu 2) Shared Services"; missing=1; fi
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

step_firewall() { sec_firewall_enable; }   # guarded version: see "SECURITY" below

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
    if [ -f "$NGINX_DIR/docker-compose.yml" ]; then
        info "nginx is installed but stopped: starting it with its existing settings."
        docker compose -f "$NGINX_DIR/docker-compose.yml" up -d >/dev/null 2>&1; sleep 2
        container_running "$NGINX_CONTAINER" && { ok "nginx is running."; return 0; }
        err "nginx did not start. See: docker logs $NGINX_CONTAINER"; return 1
    fi

    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq ':(80|443)$'; then
        err "Port 80 or 443 is already in use on this server:"
        ss -ltnp | grep -E ':(80|443)\s' || true
        explain "Stop that service first (e.g. 'systemctl disable --now apache2 nginx'), then run this again."
        return 1
    fi

    pick_nginx_image || { err "Cancelled."; return 1; }
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
    image: $(nginx_image_current)
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
    if [ -f "$DB_DIR/docker-compose.yml" ]; then
        info "MariaDB is installed but stopped: starting it with its existing settings and data."
        docker compose -f "$DB_DIR/docker-compose.yml" up -d >/dev/null 2>&1
        perf_wait_db && { ok "MariaDB is healthy."; return 0; }
        err "MariaDB did not become healthy. Check: docker logs $DB_CONTAINER"; return 1
    fi

    pick_mariadb_image || { err "Cancelled."; return 1; }
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
      MARIADB_AUTO_UPGRADE: "1"
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
if [ "$rc" -ne 0 ] && [ -d __NOTIFY_SPOOL__ ]; then
    f="__NOTIFY_SPOOL__/$(date +%s%N)-$$.evt"
    { echo "EVENT=ssl_fail"; echo "DETAIL=certbot renew ended with exit code $rc (log: __RENEW_LOG__)"; } > "$f.tmp" && mv "$f.tmp" "$f"
fi
if docker exec __NGINX_CONTAINER__ nginx -s reload >/dev/null 2>&1; then echo "nginx reloaded"; fi
if docker inspect __MAIL_CONTAINER__ >/dev/null 2>&1; then
    if docker exec __MAIL_CONTAINER__ sh -c 'postfix reload >/dev/null 2>&1; doveadm reload >/dev/null 2>&1'; then echo "mail server reloaded"; fi
fi
echo "[$(date -Is)] Finished (certbot exit code: $rc)"
exit $rc
EOF
    sed -i -e "s|__NGINX_DIR__|$NGINX_DIR|g" -e "s|__CERTBOT_IMAGE__|$CERTBOT_IMAGE|g" \
           -e "s|__NGINX_CONTAINER__|$NGINX_CONTAINER|g" -e "s|__MAIL_CONTAINER__|$MAIL_CONTAINER|g" \
           -e "s|__NOTIFY_SPOOL__|$NOTIFY_SPOOL|g" -e "s|__RENEW_LOG__|$RENEW_LOG|g" "$RENEW_SCRIPT"
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
    docker ps -a --filter "name=$NGINX_CONTAINER" --filter "name=$DB_CONTAINER" --filter "name=$PG_CONTAINER" \
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
# PHP version: change PHP_VERSION in .deploy.env on the server (main menu 11 -> Projects), or the default on the ARG line below.
# (From PHP 8.5 on, OPcache is part of PHP itself, so it is only installed for older versions.)
ARG PHP_VERSION=__PHP_VERSION__
FROM php:${PHP_VERSION}-fpm-alpine

# Same UID/GID as the server's gitlab-runner user => no permission conflicts, no chmod 777
ARG APP_UID=1000
ARG APP_GID=1000

RUN apk add --no-cache git curl zip unzip supervisor \
        libpng-dev libjpeg-turbo-dev freetype-dev libzip-dev oniguruma-dev libxml2-dev icu-dev postgresql-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && EXTS="pdo_mysql pdo_pgsql mbstring exif pcntl bcmath gd zip intl" \
    && if php -r 'exit(PHP_VERSION_ID < 80500 ? 0 : 1);'; then EXTS="$EXTS opcache"; fi \
    && docker-php-ext-install -j"$(nproc)" $EXTS

RUN set -eu; \
    u="$(getent passwd "${APP_UID}" | cut -d: -f1 || true)"; [ -z "$u" ] || deluser "$u"; \
    g="$(getent group "${APP_GID}" | cut -d: -f1 || true)"; [ -z "$g" ] || delgroup "$g"; \
    addgroup -g "${APP_GID}" app; \
    adduser -D -u "${APP_UID}" -G app app

# PHP-FPM pool. The values come from environment variables: the defaults below are low-memory friendly and the
# server can change them (main menu 7 -> Performance tuning) through docker-compose.prod.yml and .deploy.env.
ENV FPM_PM=ondemand FPM_MAX_CHILDREN=5 FPM_START_SERVERS=2 FPM_MIN_SPARE=1 FPM_MAX_SPARE=3 FPM_IDLE_TIMEOUT=10s FPM_MAX_REQUESTS=500 PHP_UPLOAD_MAX=50M
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
      'php_admin_value[upload_max_filesize] = ${PHP_UPLOAD_MAX}' \
      'php_admin_value[post_max_size] = ${PHP_UPLOAD_MAX}' \
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
        PHP_VERSION: ${PHP_VERSION:-__PHP_VERSION__}
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
      PHP_UPLOAD_MAX: ${UPLOAD_MAX:-50M}
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
    -v "$APP_PATH:/app" -w /app "${NODE_IMAGE:-node:26-alpine}" \
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
      T0="$(date +%s)"
      notify_event() {   # HiDeploy notifications: leaves a small event file, the server sends it within a minute
        local d="__NOTIFY_SPOOL__" ev f
        case "$1" in ok) ev=deploy_ok ;; failed) ev=deploy_fail ;; *) return 0 ;; esac
        [ -d "$d" ] && [ -w "$d" ] || return 0
        f="$d/$(date +%s%N)-$$.evt"
        {
          echo "EVENT=$ev"; echo "MODE=pipeline"; echo "DOMAIN=${DOMAIN:-}"
          echo "COMMIT=${CI_COMMIT_SHORT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
          echo "MESSAGE=$(printf '%s' "${CI_COMMIT_TITLE:-}" | tr -d '\r\n' | cut -c1-120)"
          echo "AUTHOR=$(printf '%s' "${GITLAB_USER_NAME:-}" | tr -d '\r\n' | cut -c1-60)"
          echo "BRANCH=${CI_COMMIT_BRANCH:-}"
          echo "PIPELINE_URL=${CI_PIPELINE_URL:-}"; echo "JOB_URL=${CI_JOB_URL:-}"
          echo "SECONDS=$(( $(date +%s) - T0 ))"
        } > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null || true
      }
      record()  {
        echo "$(date -Is) $(git rev-parse --short HEAD 2>/dev/null || echo unknown) $1 $(git log -1 --format=%s 2>/dev/null | tr -d '\r\n' | cut -c1-80)" >> .deploy.history
        tail -n 200 .deploy.history > .deploy.history.tmp && mv .deploy.history.tmp .deploy.history
        grep -qxF ".deploy.history" .git/info/exclude 2>/dev/null || echo ".deploy.history" >> .git/info/exclude
        notify_event "$1" || true
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
    # Versions: GEN_PHP / GEN_NODE (set by the caller after asking the user), else the project's own, else the suggestion
    local php="${GEN_PHP:-${PHP_VERSION:-$DEFAULT_PHP_VERSION}}" node="${GEN_NODE:-${NODE_VERSION:-$DEFAULT_NODE_VERSION}}"
    tmp="$(mktemp -d)"
    if [ "$type" = "nextjs" ]; then
        tpl_next_dockerfile "$pm" | sed "s|__NODE_VERSION__|$node|g" > "$tmp/Dockerfile"
        tpl_next_compose          | sed "s|__NODE_VERSION__|$node|g" > "$tmp/docker-compose.prod.yml"
        tpl_next_dockerignore     > "$tmp/.dockerignore"
        tpl_next_ci | sed -e "s|__TAG__|$tag|g" -e "s|__BRANCH__|$branch|g" \
                          -e "s|__DEPLOY_PATH__|$PROJECTS_DIR/$domain|g" -e "s|__NOTIFY_SPOOL__|$NOTIFY_SPOOL|g" > "$tmp/.gitlab-ci.yml"
    else
        tpl_dockerfile   | sed "s|__PHP_VERSION__|$php|g" > "$tmp/Dockerfile"
        tpl_compose      | sed "s|__PHP_VERSION__|$php|g" > "$tmp/docker-compose.prod.yml"
        tpl_dockerignore > "$tmp/.dockerignore"
        tpl_ci | sed -e "s|__TAG__|$tag|g" -e "s|__BRANCH__|$branch|g" \
                     -e "s|__DEPLOY_PATH__|$PROJECTS_DIR/$domain|g" -e "s|__NOTIFY_SPOOL__|$NOTIFY_SPOOL|g" > "$tmp/.gitlab-ci.yml"
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
        if [ "$(db_engine_of "$PROJECTS_DIR/$domain")" = "postgres" ] && ! grep -q 'pdo_pgsql' "$dir/Dockerfile"; then
            err "Dockerfile: no 'pdo_pgsql' (the PHP driver for PostgreSQL). Regenerate the files: main menu 3), then copy the new Dockerfile into your repository."; problems=$((problems+1))
        fi
        grep -q 'ARG APP_UID' "$dir/Dockerfile"                    || { err "Dockerfile: missing 'ARG APP_UID' / 'ARG APP_GID'."; problems=$((problems+1)); }
        check_php_fit "$dir" || true
        if grep -qE '^FROM php:8\.[5-9]' "$dir/Dockerfile" && grep -qE 'docker-php-ext-install.*[[:space:]]opcache' "$dir/Dockerfile"; then
            err "Dockerfile: PHP 8.5 and newer already contain OPcache, so 'docker-php-ext-install ... opcache' fails. Regenerate the files: main menu 3."; problems=$((problems+1))
        fi
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
    local domain branch tag outdir ptype="laravel" pm="pnpm" tchoice nreq preq lvq
    local -a nitems pitems
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
    GEN_PHP=""; GEN_NODE=""
    if [ "$ptype" = "nextjs" ]; then
        explain "The project is on your computer, so HiDeploy cannot read its package.json. If you know it, type the 'engines.node' value (for example >=20); otherwise just press Enter."
        ask "Node requirement from package.json (Enter = none)" "" nreq
        suggest_node_from "$nreq"
        mapfile -t nitems < <(node_menu_items)
        choose_tag "Node.js" "$SUG_NODE" "$SUG_REASON" '^[0-9]{2}(\.[0-9]+)*$' "${nitems[@]}" || { info "Cancelled."; pause; return; }
        GEN_NODE="$CHOSEN_TAG"; verify_image "node:${GEN_NODE}-alpine" || { pause; return; }
    else
        explain "The project is on your computer, so HiDeploy cannot read its composer.json. If you know them, type the 'php' requirement (for example ^8.2) and the Laravel version (for example 12); otherwise just press Enter."
        ask "PHP requirement from composer.json (Enter = none)" "" preq
        ask "Laravel major version (Enter = unknown)" "" lvq
        suggest_php_from "$preq" "$lvq"
        mapfile -t pitems < <(php_menu_items)
        choose_tag "PHP" "$SUG_PHP" "$SUG_REASON" '^[0-9]+\.[0-9]+(\.[0-9]+)?$' "${pitems[@]}" || { info "Cancelled."; pause; return; }
        GEN_PHP="$CHOSEN_TAG"; verify_image "php:${GEN_PHP}-fpm-alpine" || { pause; return; }
    fi
    outdir="$TEMPLATES_DIR/$domain"
    echo ""
    generate_project_files "$outdir" "$domain" "$branch" "$tag" yes "$ptype" "$pm"
    GEN_PHP=""; GEN_NODE=""
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
    if [ "${4:-laravel}" = "mailweb" ]; then write_mailweb_vhost "$domain" "$mode"; return; fi
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
    vhost_postprocess "$out" "$domain" "$mode"
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
    local -a dargs=(-d "$domain"); local al
    for al in $(kv_get "$PROJECTS_DIR/$domain/.deploy.env" ALIASES); do dargs+=(-d "$al"); done
    if certbot_run certonly --webroot -w /var/www/certbot "${dargs[@]}" --expand \
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
    FRONTEND_BUILD="no"; USE_DATABASE="yes"; NODE_IMAGE="$DEFAULT_NODE_IMAGE"; PROJECT_TYPE="laravel"; APP_PORT="3000"; DB_ENGINE="mariadb"
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
    local path="$1" pull="${2:-yes}" target="${3:-}" rc status="ok" t0 ev
    load_project "$path" || return 1
    cd "$path" || return 1
    t0="$(date +%s)"
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
        ev="deploy_ok"; [ -z "$target" ] || ev="rollback"
    else
        ev="deploy_fail"
        deploy_record "$path" failed
        if [ "$DEPLOY_MAINT_ON" = "yes" ]; then
            warn "The site was left in maintenance mode on purpose: half-updated code can break pages or data."
            explain "Fix the problem and deploy again, or roll back: Manage Projects -> this project -> Deployments -> Roll back."
        fi
    fi
    nf_emit_deploy "$ev" "$path" $(( $(date +%s) - t0 ))
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
    local path="$1" e="${PROV_ENGINE:-mariadb}"
    if [ "$e" = "postgres" ]; then env_set "$path/.env" DB_CONNECTION pgsql; else env_set "$path/.env" DB_CONNECTION mysql; fi
    env_set "$path/.env" DB_HOST "$(db_container_of "$e")"
    env_set "$path/.env" DB_PORT "$(db_port_of "$e")"
    env_set "$path/.env" DB_DATABASE "$PROV_DB"
    env_set "$path/.env" DB_USERNAME "$PROV_USER"
    env_set "$path/.env" DB_PASSWORD "$(env_quote "$PROV_PASS")"
}

project_add_database() {
    local path="$1"
    load_project "$path" || return 1
    section "Add a database to $(basename "$path")"
    if [ "$USE_DATABASE" = "yes" ] && [ -n "$(env_get "$path/.env" DB_DATABASE)" ]; then
        warn "This project already has a database configured ($(env_get "$path/.env" DB_DATABASE), $(db_engine_label "$(db_engine_of "$path")"))."
        confirm "Configure another one anyway?" n || return 0
    fi
    local kind="laravel"; is_next && kind="nextjs"
    PROV_ENGINE=""
    db_choose_engine "$kind" || return 1
    if [ "$PROV_ENGINE" = "postgres" ] && ! is_next && ! laravel_pg_ready "$path"; then
        warn "This project's PHP image has no PostgreSQL driver (pdo_pgsql): its Dockerfile was made by an older HiDeploy."
        explain "Fix: main menu 3) Generate Project Files, copy the new Dockerfile into your repository, push, and let the pipeline rebuild."                 "Until then the site cannot connect to PostgreSQL."
        confirm "Continue anyway (the database and .env are prepared now)?" n || return 0
    fi
    explain "Press Enter to accept a suggestion, or type your own value."
    db_provision "$(basename "$path")" || return 1
    env_set "$path/.deploy.env" DB_ENGINE "$PROV_ENGINE"
    DB_ENGINE="$PROV_ENGINE"
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
    local db="$1" file="$2" eng="${3:-mariadb}" fix=0 rc
    local -a reader
    if [ "$eng" = "postgres" ]; then pg_import_file "$db" "$file"; return; fi
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
    local path="$1" preset="${2:-}" db dbuser file mode typed tables maint="no" rc=0 eng
    load_project "$path" || return 1
    section "Restore database — $(basename "$path")"
    [ "$USE_DATABASE" = "yes" ] || { err "This project has no database. Use 'Add a database' first."; return 1; }
    eng="$(db_engine_of "$path")"
    db_running "$eng" || { err "The $(db_engine_label "$eng") container is not running."; return 1; }
    db="$(env_get "$path/.env" DB_DATABASE)"; dbuser="$(env_get "$path/.env" DB_USERNAME)"
    valid_db_name "$eng" "$db" || { err "DB_DATABASE is missing or invalid in $path/.env"; return 1; }
    if [ "$eng" = "postgres" ]; then
        explain "Target database: $db (PostgreSQL)" "Supports .sql and .sql.gz files made by pg_dump (plain SQL format)."
    else
        explain "Target database: $db (MariaDB)" "Supports .sql and .sql.gz files. Dumps from MySQL 8 are converted automatically if needed."
    fi
    if [ -n "$preset" ]; then file="$preset"; else pick_sql_file file || { info "Cancelled."; return 0; }; fi
    tables="$(dbx_table_count "$eng" "$db")"
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
        dbx_recreate "$eng" "$db" "$dbuser" || { err "Could not recreate the database."; rc=1; }
    fi
    if [ "$rc" -eq 0 ]; then db_import_file "$db" "$file" "$eng" || rc=1; fi
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
# Node version: change NODE_VERSION in .deploy.env on the server (main menu 11 -> Projects), or the default on the ARG line below.
ARG NODE_VERSION=__NODE_VERSION__
FROM node:\${NODE_VERSION}-alpine AS base
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
FROM node:\${NODE_VERSION}-alpine AS runner
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
      args:
        NODE_VERSION: ${NODE_VERSION:-__NODE_VERSION__}
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
      T0="$(date +%s)"
      notify_event() {   # HiDeploy notifications: leaves a small event file, the server sends it within a minute
        local d="__NOTIFY_SPOOL__" ev f
        case "$1" in ok) ev=deploy_ok ;; failed) ev=deploy_fail ;; *) return 0 ;; esac
        [ -d "$d" ] && [ -w "$d" ] || return 0
        f="$d/$(date +%s%N)-$$.evt"
        {
          echo "EVENT=$ev"; echo "MODE=pipeline"; echo "DOMAIN=${DOMAIN:-}"
          echo "COMMIT=${CI_COMMIT_SHORT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
          echo "MESSAGE=$(printf '%s' "${CI_COMMIT_TITLE:-}" | tr -d '\r\n' | cut -c1-120)"
          echo "AUTHOR=$(printf '%s' "${GITLAB_USER_NAME:-}" | tr -d '\r\n' | cut -c1-60)"
          echo "BRANCH=${CI_COMMIT_BRANCH:-}"
          echo "PIPELINE_URL=${CI_PIPELINE_URL:-}"; echo "JOB_URL=${CI_JOB_URL:-}"
          echo "SECONDS=$(( $(date +%s) - T0 ))"
        } > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null || true
      }
      record() {
        echo "$(date -Is) $(git rev-parse --short HEAD 2>/dev/null || echo unknown) $1 $(git log -1 --format=%s 2>/dev/null | tr -d '\r\n' | cut -c1-80)" >> .deploy.history
        tail -n 200 .deploy.history > .deploy.history.tmp && mv .deploy.history.tmp .deploy.history
        grep -qxF ".deploy.history" .git/info/exclude 2>/dev/null || echo ".deploy.history" >> .git/info/exclude
        notify_event "$1" || true
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
    local path="$1" pass_enc e="${PROV_ENGINE:-mariadb}" scheme=mysql
    [ "$e" = "postgres" ] && scheme=postgresql
    pass_enc="$(urlencode "$PROV_PASS")"
    env_set "$path/.env" DB_HOST "$(db_container_of "$e")"
    env_set "$path/.env" DB_PORT "$(db_port_of "$e")"
    env_set "$path/.env" DB_DATABASE "$PROV_DB"
    env_set "$path/.env" DB_USERNAME "$PROV_USER"
    if [[ "$PROV_PASS" == *"'"* ]]; then
        warn "The password contains a quote, so only DATABASE_URL is written (use that in your app)."
    else
        env_set "$path/.env" DB_PASSWORD "'$PROV_PASS'"
    fi
    env_set "$path/.env" DATABASE_URL "$scheme://$PROV_USER:$pass_enc@$(db_container_of "$e"):$(db_port_of "$e")/$PROV_DB"
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
        __AE__
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
    } | sed -e "s|__DOMAIN__|$domain|g" -e "s|__CONTAINER__|$container|g" -e "s|__PORT__|$port|g" -e "s|__AE__|$(brotli_ae_line)|g" > "$out"
    vhost_postprocess "$out" "$domain" "$mode"
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
        echo "13) Project settings: domains, memory, Redis, upload size"
        echo "14) Email for this project (mailboxes, send mail through your own server)"
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
            13) project_settings_menu "$path" ;;
            14) project_mail_menu "$path" ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ---------- deployment wizard ----------------------------------------------

deploy_wizard_nextjs() {
    local domain repo branch tag path container mem mem_norm uid gid grp ssl_ok=0 skip_ssl=0 c
    local use_db port heap detected pm ip sqlfile db_line scheme dp_ok ram
    PROV_DB=""; PROV_USER=""; PROV_PASS=""; PROV_ENGINE=""
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
    PICK_NODE="$(dockerfile_node_version "$path")"
    if dockerfile_has_arg "$path" NODE_VERSION; then
        pick_node "$path" "$PICK_NODE" || { info "Stopped."; pause; return; }
    else
        PICK_NODE="${PICK_NODE:-$DEFAULT_NODE_VERSION}"
        info "Node version: the Dockerfile in your repository builds Node $PICK_NODE (written into the file; to choose another one use main menu 3, then commit)."
    fi
    if confirm "Does this project use a database right now? (you can add one later)" n; then
        use_db="yes"; db_choose_engine nextjs || { pause; return; }
    else use_db="no"; fi
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
NODE_VERSION=$PICK_NODE
USE_DATABASE=$use_db
DB_ENGINE=${PROV_ENGINE:-mariadb}
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
                db_import_file "$PROV_DB" "$sqlfile" "$PROV_ENGINE" || warn "Import failed. You can retry later: Manage Projects -> your project -> Restore database."
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
    [ "$use_db" = "yes" ] && db_line="$PROV_DB (user $PROV_USER, $(db_engine_label "$PROV_ENGINE"))"
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
    local path="$1" db file eng
    load_project "$path" || return 1
    if [ "$USE_DATABASE" != "yes" ]; then warn "This project has no database — nothing to back up."; return 0; fi
    eng="$(db_engine_of "$path")"
    db="$(env_get "$path/.env" DB_DATABASE)"
    [ -n "$db" ] || { err "DB_DATABASE not found in $path/.env"; return 1; }
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    file="$BACKUP_DIR/${db}-$(date +%F_%H%M%S).sql.gz"
    # never overwrite an existing dump (for example the very file that is about to be restored)
    [ ! -e "$file" ] || file="$BACKUP_DIR/${db}-$(date +%F_%H%M%S)-$$.sql.gz"
    info "Dumping database '$db'..."
    dbx_dump "$eng" "$db" | gzip > "$file"
    if [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "$file" ]; then
        ok "Backup saved: $file ($(du -h "$file" | cut -f1))"
    else
        rm -f "$file"; err "Backup failed."; return 1
    fi
}

project_remove() {
    local path="$1" domain db dbuser typed eng
    domain="$(basename "$path")"
    load_project "$path" || return 1
    eng="$(db_engine_of "$path")"
    db="$(env_get "$path/.env" DB_DATABASE)"; dbuser="$(env_get "$path/.env" DB_USERNAME)"
    [ "$USE_DATABASE" = "yes" ] || { db=""; dbuser=""; }
    local mdom; mdom="$(kv_get "$path/.deploy.env" MAIL_DOMAIN)"
    warn "This will stop the container, delete the nginx config and delete the folder $path"
    read -r -p "${C_RED}Type the domain name to confirm ($domain): ${C_RESET}" typed
    [ "$typed" = "$domain" ] || { info "Cancelled."; return 0; }
    [ "$USE_DATABASE" = "yes" ] && confirm "Make a database backup first?" y && project_backup "$path"
    dc down --remove-orphans 2>/dev/null || docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    rm -f "$NGINX_DIR/conf.d/$domain.conf"; nginx_test_reload >/dev/null 2>&1
    if [ -d "$NGINX_DIR/letsencrypt/live/$domain" ] && confirm "Delete the SSL certificate for $domain?" y; then
        certbot_run delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 && ok "Certificate deleted."
    fi
    if [ -n "$db" ] && valid_db_name "$eng" "$db" && valid_db_user "$eng" "$dbuser" && confirm "DROP database '$db' and user '$dbuser' ($(db_engine_label "$eng")) permanently?" n; then
        dbx_drop "$eng" "$db" "$dbuser" && ok "Database and user dropped."
    fi
    cd / && rm -rf "$path" && ok "Project folder removed."
    if [ -n "$mdom" ] && mail_installed && mail_domain_registered "$mdom"; then
        warn "The mail domain $mdom (and its mailboxes) still exists on the mail server. Remove it in main menu 9) Email -> Mail domains if you no longer need it."
    fi
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
        echo "15) Project settings: domains, memory, Redis, upload size"
        echo "16) Email for this project (mailboxes, send mail through your own server)"
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
            15) project_settings_menu "$path" ;;
            16) project_mail_menu "$path" ;;
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
               echo ""; echo " a) Reload nginx config   b) Restart nginx   c) Restart MariaDB   d) nginx logs   e) MariaDB logs"
               pg_installed && echo " f) Restart PostgreSQL   g) PostgreSQL logs"
               echo " (Enter = back)"
               read -r -p "Select: " c
               case "$c" in
                   a) nginx_test_reload && ok "nginx reloaded." ;;
                   b) docker restart "$NGINX_CONTAINER" ;;
                   c) docker restart "$DB_CONTAINER" ;;
                   d) docker logs --tail 80 "$NGINX_CONTAINER" ;;
                   e) docker logs --tail 80 "$DB_CONTAINER" ;;
                   f) pg_installed && docker restart "$PG_CONTAINER" ;;
                   g) pg_installed && docker logs --tail 80 "$PG_CONTAINER" ;;
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
    local domain="$1" base def_db def_user def_pass pass pass2 exists_db exists_user e="${PROV_ENGINE:-mariadb}"
    base="$(printf '%s' "$domain" | tr '.-' '__' | tr -cd 'A-Za-z0-9_')"
    def_db="${base:0:63}"; def_user="${base:0:32}"; def_pass="$(gen_password)"
    [ "$e" = "postgres" ] && [[ "$def_db" == pg_* ]] && def_db="db_$def_db"

    while true; do
        ask "Database name" "$def_db" PROV_DB
        valid_db_name "$e" "$PROV_DB" || { err "Use only letters, digits and underscore (max 63; not 'postgres' or starting with 'pg_' on PostgreSQL)."; continue; }
        exists_db="$(dbx_db_exists "$e" "$PROV_DB")"
        if [ "${exists_db:-0}" != "0" ]; then
            warn "Database '$PROV_DB' already exists."
            confirm "Reuse it (data is kept)?" n && break
            continue
        fi
        break
    done
    while true; do
        ask "Database user" "$def_user" PROV_USER
        valid_db_user "$e" "$PROV_USER" || { err "Use only letters, digits and underscore (not 'postgres' or starting with 'pg_' on PostgreSQL)."; continue; }
        exists_user="$(dbx_user_exists "$e" "$PROV_USER")"
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

    dbx_provision "$e" "$PROV_DB" "$PROV_USER" "$PROV_PASS" \
        || { err "Database provisioning failed."; return 1; }
    ok "Database '$PROV_DB' and user '$PROV_USER' are ready ($(db_engine_label "$e"))."
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

    local domain repo branch tag path container mem mem_norm uid gid grp ssl_ok=0 skip_ssl=0 queue_conn c fe fe_default use_db qdefault db_line dp_ok sqlfile node_img="$DEFAULT_NODE_IMAGE"
    PROV_DB=""; PROV_USER=""; PROV_PASS=""; PROV_ENGINE=""

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
    if confirm "Does this project use a database right now? (you can add one later)" y; then
        use_db="yes"; db_choose_engine laravel || { pause; return; }
    else use_db="no"; fi
    # Runtime versions: suggested from composer.json / package.json, you decide
    PICK_PHP="$(dockerfile_php_version "$path")"
    if dockerfile_has_arg "$path" PHP_VERSION; then
        pick_php "$path" "$PICK_PHP" || { info "Stopped."; pause; return; }
    else
        PICK_PHP="${PICK_PHP:-$DEFAULT_PHP_VERSION}"
        info "PHP version: the Dockerfile in your repository builds PHP $PICK_PHP (written into the file; to choose another one use main menu 3, then commit)."
        check_php_fit "$path" || true
    fi
    if [ "$fe" = "yes" ]; then
        if pick_node "$path" ""; then node_img="node:${PICK_NODE}-alpine"; fi
    fi
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
NODE_IMAGE=$node_img
PHP_VERSION=$PICK_PHP
USE_DATABASE=$use_db
DB_ENGINE=${PROV_ENGINE:-mariadb}
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
    section "Step 7/11 · Database"
    if [ "$use_db" = "yes" ]; then
        explain "Press Enter to accept a suggestion, or type your own value."
        db_provision "$domain" || { pause; return; }
        if confirm "Restore an existing SQL backup into this database now?" n; then
            if pick_sql_file sqlfile; then
                db_import_file "$PROV_DB" "$sqlfile" "$PROV_ENGINE" || warn "Import failed. You can retry later: Manage Projects → your project → Restore database."
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
    ok ".env updated (DB host is '$(db_container_of "$PROV_ENGINE")'). View it any time: nano $path/.env"
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
    [ "$use_db" = "yes" ] && db_line="$PROV_DB (user $PROV_USER, $(db_engine_label "$PROV_ENGINE"))"
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
    local run dir fail=0 p dom db use_db f rh size ssh_state="off" s3_state="off" eng dbfile
    local -a items extras
    run="$(date +%F_%H%M%S)"; dir="$BK_LOCAL_DIR/$run"
    mkdir -p "$dir"; chmod 700 "$dir"
    echo "[$(date -Is)] Backup $run started (HiDeploy $HIDEPLOY_VERSION)"

    # 1) every project: database dump + files
    while IFS= read -r p; do
        dom="$(basename "$p")"
        use_db="$( . "$p/.deploy.env" 2>/dev/null; echo "${USE_DATABASE:-yes}" )"
        db="$(env_get "$p/.env" DB_DATABASE)"
        eng="$(db_engine_of "$p")"
        dbfile="db-$db.sql.gz.gpg"; [ "$eng" = "postgres" ] && dbfile="db-pg-$db.sql.gz.gpg"
        if [ "$use_db" = "yes" ] && valid_db_name "$eng" "$db"; then
            if dbx_dump "$eng" "$db" --events | gzip -c | bk_encrypt "$dir/$dbfile"; then
                echo "  database $db ($(db_engine_label "$eng")): ok"
            else
                echo "  database $db ($(db_engine_label "$eng")): FAILED"; fail=$((fail+1)); rm -f "$dir/$dbfile"
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
        if { tar -C / --exclude="${INFRA_DIR#/}/backup" --exclude="${INFRA_DIR#/}/mail/data" -czf - "${INFRA_DIR#/}" "${extras[@]}" 2>/dev/null || [ $? -eq 1 ]; } \
                | bk_encrypt "$dir/server-config.tar.gz.gpg"; then
            echo "  server configuration: ok"
        else
            echo "  server configuration: FAILED"; fail=$((fail+1)); rm -f "$dir/server-config.tar.gz.gpg"
        fi
    fi

    # 2b) mailboxes: the messages (accounts, passwords and DKIM keys are already inside the server configuration above)
    if mail_installed && [ "$(bk_val INCLUDE_MAIL yes)" = "yes" ] && [ -d "$MAIL_DIR/data/mail-data" ]; then
        if { tar -C "$MAIL_DIR/data" -czf - mail-data 2>/dev/null || [ $? -eq 1 ]; } | bk_encrypt "$dir/mail-data.tar.gz.gpg"; then
            echo "  mailboxes: ok"
        else
            echo "  mailboxes: FAILED"; fail=$((fail+1)); rm -f "$dir/mail-data.tar.gz.gpg"
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
    local rc
    backup_run_core; rc=$?
    nf_emit_backup "$rc"
    return "$rc"
}

backup_run_core() {
    [ -s "$BK_PASS" ] || { echo "[backup] No passphrase yet. Open: sudo hideploy -> 6) Backups -> 2"; return 1; }
    has_cmd gpg      || { echo "[backup] gpg is missing: apt-get install -y gnupg"; return 1; }
    docker_ready     || { echo "[backup] Docker is not running."; return 1; }
    mkdir -p "$BK_LOCAL_DIR" "$BK_DIR"; chmod 700 "$BACKUP_DIR" "$BK_LOCAL_DIR" 2>/dev/null
    ( flock -n 9 || { echo "[backup] Another backup is already running."; exit 75; }; bk_run_inner ) 9>"$BK_DIR/.lock"
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
    if mail_installed; then printf '  Mailboxes:           %s\n' "$([ "$(bk_val INCLUDE_MAIL yes)" = yes ] && echo "included" || echo "not included (Email menu, option 9)")"; fi
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
            mail-data*) explain "The messages of all mailboxes. To restore them (stop the mail server first: docker stop $MAIL_CONTAINER):" \
                                "  tar -xzf $out/${f%.gpg} -C $MAIL_DIR/data   then   docker start $MAIL_CONTAINER" ;;
            db-pg-*) explain "A PostgreSQL database dump: restore it through the project menu (Manage Projects -> project -> Restore database) or option 8." ;;
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
$BK_LOG $RENEW_LOG $CLEANUP_LOG $NOTIFY_LOG {
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
        __AE__
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

mariadb_write_compose() {   # BUFFER_POOL MAX_CONNECTIONS SKIP_NAME_RESOLVE(yes|no) [DATA_VOLUME_KEY]
    local bp="$1" mc="$2" skip="$3" vol="${4:-}" skip_line=""
    [ "$skip" = "yes" ] && skip_line="      - --skip-name-resolve"
    # keep the data volume the server already uses (a major upgrade gives it a new name)
    [ -n "$vol" ] || vol="$(sed -n 's#^      - \([A-Za-z0-9_.-]*\):/var/lib/mysql$#\1#p' "$DB_DIR/docker-compose.yml" 2>/dev/null | head -n1)"
    vol="${vol:-mariadb_data}"
    cat > "$DB_DIR/docker-compose.yml" <<EOF
services:
  mariadb:
    image: ${MARIADB_IMAGE}
    container_name: ${DB_CONTAINER}
    restart: always
    environment:
      MARIADB_ROOT_PASSWORD: \${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --innodb-buffer-pool-size=${bp}
      - --max-connections=${mc}
${skip_line}
    volumes:
      - ${vol}:/var/lib/mysql
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
  ${vol}:
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
            dbms="$(docker exec -u "$APP_UID:$APP_GID" -w "$APP_PATH" "$CONTAINER_NAME" php -r '$e=@parse_ini_file(".env"); if(!$e||empty($e["DB_HOST"])){echo "unknown";exit;} $t=microtime(true); try{ new PDO((($e["DB_CONNECTION"]??"mysql")=="pgsql"?"pgsql":"mysql").":host=".$e["DB_HOST"].";port=".($e["DB_PORT"]??3306).";dbname=".$e["DB_DATABASE"],$e["DB_USERNAME"],$e["DB_PASSWORD"],[PDO::ATTR_TIMEOUT=>10]); echo round((microtime(true)-$t)*1000);}catch(Throwable $x){echo "error";}' 2>/dev/null)"
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
            if [ "${DB_ENGINE:-mariadb}" = "postgres" ]; then echo "    -> The database connection is slow (${dbms} ms): check the PostgreSQL container (docker logs $PG_CONTAINER) and the server load."
            else echo "    -> The database connection is slow (${dbms} ms): MariaDB tuning (option 3, skip-name-resolve) usually fixes this."; fi
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
# PROJECT SETTINGS (after deployment): memory, extra domains, main domain, Redis, upload size
# ============================================================================

env_unset() { [ -f "$1" ] && sed -i "/^$2=/d" "$1"; return 0; }

# Called at the end of write_vhost / write_next_vhost: applies per-project extra domains and upload size.
# Does nothing (the vhost stays byte-for-byte the same) when the project has neither.
vhost_postprocess() {   # FILE DOMAIN MODE
    local f="$1" domain="$2" mode="$3" env="$PROJECTS_DIR/$2/.deploy.env" aliases maxb
    aliases="$(kv_get "$env" ALIASES)"; maxb="$(kv_get "$env" UPLOAD_MAX)"
    if [ -n "$maxb" ] && [ "$maxb" != "50M" ]; then sed -i "s/client_max_body_size 50M;/client_max_body_size ${maxb};/" "$f"; fi
    [ -n "$aliases" ] || return 0
    awk -v d="$domain" -v a="$aliases" 'BEGIN { done = 0 } { if (!done && $0 == "    server_name " d ";") { print "    server_name " d " " a ";"; done = 1 } else print }' "$f" > "$f.tmp" \
        && cat "$f.tmp" > "$f"; rm -f "$f.tmp"
    if [ "$mode" = "https" ]; then
        {
            echo ""
            echo "# Extra domains: permanent redirect to the main domain"
            echo "server {"
            echo "    listen 443 ssl;"
            echo "    http2 on;"
            echo "    server_name $aliases;"
            echo "    ssl_certificate     /etc/letsencrypt/live/$domain/fullchain.pem;"
            echo "    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;"
            echo "    ssl_protocols TLSv1.2 TLSv1.3;"
            echo "    ssl_session_cache shared:SSL:10m;"
            echo '    return 301 https://'"$domain"'$request_uri;'
            echo "}"
        } >> "$f"
    fi
}

project_overview() {
    local path="$1" domain env aliases db redis
    load_project "$path" || return 1
    domain="$(basename "$path")"; env="$path/.deploy.env"
    aliases="$(kv_get "$env" ALIASES)"
    db="$(env_get "$path/.env" DB_DATABASE)"
    if [ "$(env_get "$path/.env" REDIS_HOST)" = "$REDIS_CONTAINER" ] || [[ "$(env_get "$path/.env" REDIS_URL)" == *"$REDIS_CONTAINER"* ]]; then redis="yes"; else redis="no"; fi
    section "Settings: $domain"
    printf '  %-22s %s\n' "Type" "${PROJECT_TYPE:-laravel}"
    printf '  %-22s %s\n' "Main domain" "$domain"
    printf '  %-22s %s\n' "Extra domains" "${aliases:-none}"
    printf '  %-22s %s\n' "Git branch" "${BRANCH:-main}"
    printf '  %-22s %s (%s)\n' "Container" "$CONTAINER_NAME" "$(container_running "$CONTAINER_NAME" && echo running || echo stopped)"
    printf '  %-22s %s\n' "Memory limit" "${MEM_LIMIT:-512m}"
    printf '  %-22s %s\n' "Upload size limit" "$(kv_get "$env" UPLOAD_MAX | sed 's/^$/50M (default)/')"
    printf '  %-22s %s\n' "Database" "$([ "${USE_DATABASE:-yes}" = yes ] && echo "${db:-configured} ($(db_engine_label "${DB_ENGINE:-mariadb}"))" || echo none)"
    printf '  %-22s %s\n' "Shared Redis" "$redis"
    printf '  %-22s %s\n' "Mail domain" "$(kv_get "$env" MAIL_DOMAIN | head -n1 | grep . || echo 'not enabled (menu: Email for this project)')"
    if ! is_next; then
        printf '  %-22s %s\n' "PHP-FPM" "$(kv_get "$env" FPM_PM | sed 's/^$/ondemand (default)/'), max workers $(kv_get "$env" FPM_MAX_CHILDREN | sed 's/^$/5 (default)/')"
        printf '  %-22s %s\n' "Frontend build" "${FRONTEND_BUILD:-no}"
    fi
}

project_set_memory() {
    local path="$1" cur new nm mb min total fm
    load_project "$path" || return 1
    section "Memory limit"
    cur="${MEM_LIMIT:-512m}"
    min=384; is_next && min=256
    perf_scan
    explain "The container is restarted with the new limit (a few seconds; visitors see the friendly page)." \
            "Current limit: $cur. This server has ${PS_RAM_MB} MB of RAM; all project limits together: ${PS_PROJ_MEM_MB} MB."
    while true; do
        ask "New memory limit (e.g. 512m or 1g)" "$cur" new
        [[ "$new" =~ ^[0-9]+$ ]] && info "No unit given: using ${new}m (m = megabytes)."
        nm="$(normalize_mem "$new")" || { err "Use a number with a unit, like 512m or 1g."; continue; }
        mb="$(mem_to_mb "$nm")"
        if [ "$mb" -lt "$min" ]; then warn "$nm is low for this kind of project (about $min MB or more is comfortable)."; confirm "Use $nm anyway?" n || continue; fi
        break
    done
    total=$(( PS_PROJ_MEM_MB - $(mem_to_mb "$(normalize_mem "$cur" 2>/dev/null || echo 512m)") + mb ))
    if [ "$total" -gt $(( PS_RAM_MB * 80 / 100 )) ]; then warn "All project limits together would be ${total} MB, more than 80% of this server's RAM (${PS_RAM_MB} MB)."; fi
    if ! is_next; then
        fm="$(kv_get "$path/.deploy.env" FPM_MAX_CHILDREN)"
        if [ -n "$fm" ] && [ $(( fm * 50 + 100 )) -gt "$mb" ]; then warn "$fm PHP workers may need about $(( fm * 50 + 100 )) MB: lower them in Performance tuning -> option 4."; fi
    fi
    confirm "Apply $nm now?" y || { info "Cancelled."; return 0; }
    env_set "$path/.deploy.env" MEM_LIMIT "$nm"
    is_next && env_set "$path/.deploy.env" NODE_HEAP_MB "$(( mb * 70 / 100 ))"
    dc up -d || { err "Could not recreate the container."; return 1; }
    if is_next; then wait_healthy; else wait_container; fi && ok "Memory limit is now $nm."
}

project_alias_add() {
    local path="$1" domain kind list alias sug mode email a
    local -a dargs
    load_project "$path" || return 1
    domain="$(basename "$path")"; kind="${PROJECT_TYPE:-laravel}"
    list="$(kv_get "$path/.deploy.env" ALIASES)"
    section "Add an extra domain"
    explain \
        "Visitors of the extra domain are redirected permanently to the main domain ($domain)." \
        "Typical use: www.$domain -> $domain. The SSL certificate is extended to cover the new name."
    if [[ "$domain" == www.* ]]; then sug="${domain#www.}"; else sug="www.$domain"; fi
    while true; do ask "Extra domain" "$sug" alias; alias="${alias,,}"; valid_domain "$alias" && break; err "Invalid domain."; done
    [ "$alias" != "$domain" ] || { err "That is the main domain."; return 1; }
    [[ " $list " != *" $alias "* ]] || { err "$alias is already added."; return 1; }
    [ ! -f "$NGINX_DIR/conf.d/$alias.conf" ] || { err "$alias is already used by another site on this server."; return 1; }
    explain "Create an A record for $alias pointing to this server first."
    if ! dns_check "$alias"; then warn "DNS for $alias does not point to this server yet."; confirm "Continue anyway? (the certificate will fail until DNS is correct)" n || return 1; fi
    list="${list:+$list }$alias"
    if [ -d "$NGINX_DIR/letsencrypt/live/$domain" ]; then
        email="$(cfg_get ADMIN_EMAIL || true)"
        [ -n "$email" ] || { err "No admin email is saved yet. Run 'Setup / re-issue SSL' once first."; return 1; }
        dargs=(-d "$domain"); for a in $list; do dargs+=(-d "$a"); done
        info "Extending the SSL certificate to cover $alias ..."
        certbot_run certonly --webroot -w /var/www/certbot "${dargs[@]}" --cert-name "$domain" --expand \
            --email "$email" --agree-tos --no-eff-email --non-interactive \
            || { err "The certificate request failed. Nothing was changed."; return 1; }
        mode="https"
    else
        mode="http"
    fi
    env_set "$path/.deploy.env" ALIASES "$list"
    apply_vhost "$domain" "$CONTAINER_NAME" "$mode" "$kind" || { err "nginx rejected the configuration."; env_set "$path/.deploy.env" ALIASES "$(kv_get "$path/.deploy.env" ALIASES | sed "s/ *$alias//")"; return 1; }
    ok "$alias now redirects to $domain."
}

project_alias_remove() {
    local path="$1" domain kind list a i=1 choice mode newlist=""
    local -a items=()
    load_project "$path" || return 1
    domain="$(basename "$path")"; kind="${PROJECT_TYPE:-laravel}"
    list="$(kv_get "$path/.deploy.env" ALIASES)"
    [ -n "$list" ] || { info "This project has no extra domains."; return 0; }
    for a in $list; do items+=("$a"); printf '   %d) %s\n' "$i" "$a"; i=$((i+1)); done
    read -r -p "Remove which one? (number, 0 = cancel): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#items[@]}" ] || { info "Cancelled."; return 0; }
    for a in "${items[@]}"; do [ "$a" = "${items[$((choice-1))]}" ] || newlist="${newlist:+$newlist }$a"; done
    env_set "$path/.deploy.env" ALIASES "$newlist"
    if [ -d "$NGINX_DIR/letsencrypt/live/$domain" ]; then mode="https"; else mode="http"; fi
    apply_vhost "$domain" "$CONTAINER_NAME" "$mode" "$kind" && ok "${items[$((choice-1))]} was removed."
    explain "The SSL certificate keeps listing the old name until its next re-issue. That is harmless."
}

project_change_domain() {
    local path="$1" old new newpath kind pm tag typed
    load_project "$path" || return 1
    old="$(basename "$path")"; kind="${PROJECT_TYPE:-laravel}"
    section "Change the main domain"
    warn "This renames the project folder, moves nginx and SSL to the new name and restarts the container."
    explain \
        "Before you start: create an A record for the NEW domain pointing to this server." \
        "After it finishes you must commit the NEW .gitlab-ci.yml (it contains the folder path), otherwise pipelines will fail." \
        "Extra domains of this project are cleared; add them again afterwards (including the old domain, if you want it to redirect)."
    while true; do ask "New main domain" "" new; new="${new,,}"; valid_domain "$new" && break; err "Invalid domain."; done
    [ "$new" != "$old" ] || { err "That is the current domain."; return 1; }
    newpath="$PROJECTS_DIR/$new"
    { [ ! -e "$newpath" ] && [ ! -f "$NGINX_DIR/conf.d/$new.conf" ]; } || { err "$new is already used on this server."; return 1; }
    if ! dns_check "$new"; then warn "DNS for $new does not point to this server yet."; confirm "Continue anyway? (SSL will fail until DNS is correct)" n || return 1; fi
    read -r -p "${C_RED}Type the NEW domain to confirm ($new): ${C_RESET}" typed
    [ "$typed" = "$new" ] || { info "Cancelled."; return 0; }
    if [ "${USE_DATABASE:-yes}" = "yes" ] && confirm "Back up the database first (recommended)?" y; then project_backup "$path" || { err "Backup failed; cancelled."; return 1; }; fi
    info "Stopping the container..."
    dc down >/dev/null 2>&1 || { err "Could not stop the container."; return 1; }
    if ! mv "$path" "$newpath"; then err "Could not rename the folder."; dc up -d >/dev/null 2>&1; return 1; fi
    env_set "$newpath/.deploy.env" DOMAIN "$new"
    env_set "$newpath/.deploy.env" APP_PATH "$newpath"
    env_set "$newpath/.deploy.env" ALIASES ""
    rm -f "$NGINX_DIR/conf.d/$old.conf"
    load_project "$newpath" || return 1
    apply_vhost "$new" "$CONTAINER_NAME" http "$kind" || warn "nginx could not be configured for $new yet."
    info "Starting the container from the new folder..."
    dc up -d || { err "The container did not start. Folder is now $newpath; check: docker logs $CONTAINER_NAME"; return 1; }
    if is_next; then wait_healthy; else wait_container; fi
    if [ "$kind" = "laravel" ]; then env_set "$newpath/.env" APP_URL "http://$new"; fi
    if confirm "Issue the SSL certificate for $new now?" y; then
        if ssl_setup "$new" "$CONTAINER_NAME" "$kind" && [ "$kind" = "laravel" ]; then env_set "$newpath/.env" APP_URL "https://$new"; fi
    fi
    if [ "$kind" = "laravel" ]; then artisan optimize:clear >/dev/null 2>&1; artisan optimize >/dev/null 2>&1; fi
    if [ -d "$NGINX_DIR/letsencrypt/live/$old" ] && confirm "Delete the SSL certificate of the old domain ($old)?" y; then
        certbot_run delete --cert-name "$old" --non-interactive >/dev/null 2>&1 && ok "Old certificate deleted."
    fi
    tag="$(cfg_get RUNNER_TAG || true)"; tag="${tag:-production}"; pm="pnpm"
    grep -q 'yarn install' "$newpath/Dockerfile" 2>/dev/null && pm="yarn"
    grep -q 'npm ci' "$newpath/Dockerfile" 2>/dev/null && pm="npm"
    generate_project_files "$TEMPLATES_DIR/$new" "$new" "${BRANCH:-main}" "$tag" yes "$kind" "$pm" >/dev/null
    ok "The main domain is now $new."
    next_steps \
        "Copy the new .gitlab-ci.yml into your project and push it:   scp root@SERVER_IP:$TEMPLATES_DIR/$new/.gitlab-ci.yml .   then   git add .gitlab-ci.yml && git commit -m 'New domain' && git push" \
        "Update APP_URL / NEXT_PUBLIC_* values that mention the old domain (Edit .env)." \
        "Re-add the old domain as an extra domain if you want it to redirect (Project settings -> Extra domains)."
}

project_set_upload() {
    local path="$1" cur size
    load_project "$path" || return 1
    section "Upload size limit"
    cur="$(kv_get "$path/.deploy.env" UPLOAD_MAX)"; cur="${cur:-50M}"
    explain "The largest file or form a visitor may send (nginx and, for Laravel, PHP). Current: $cur."
    while true; do ask "New limit (e.g. 10M, 50M, 200M, 1G)" "$cur" size; size="${size^^}"; [[ "$size" =~ ^[1-9][0-9]*[MG]$ ]] && break; err "Use a number with M or G."; done
    env_set "$path/.deploy.env" UPLOAD_MAX "$size"
    nginx_refresh_project "$path" || return 1
    if is_next; then
        explain "Next.js also has its own body limits inside the app (for example serverActions.bodySizeLimit); nginx now allows $size."
    elif grep -q 'PHP_UPLOAD_MAX' "$path/docker-compose.prod.yml" 2>/dev/null; then
        dc up -d >/dev/null 2>&1 && wait_container && ok "nginx and PHP now allow $size."
    else
        warn "nginx now allows $size, but PHP still uses the old limit: this project uses an older template."
        explain "Regenerate the project files (main menu 3), copy them into your project, push and deploy to change PHP too."
    fi
}

# ---------- shared Redis ----------

redis_pass() { kv_get "$REDIS_DIR/.env" REDIS_PASSWORD; }

redis_status_row() {
    if [ ! -f "$REDIS_DIR/docker-compose.yml" ]; then status_row "Redis" dim "NOT SET UP" "optional: Shared Services -> Redis"
    elif container_running "$REDIS_CONTAINER"; then status_row "Redis" good "RUNNING" "$REDIS_CONTAINER"
    else status_row "Redis" warn "STOPPED" "start it: docker start $REDIS_CONTAINER"; fi
}

redis_install() {
    section "Install shared Redis"
    explain "One Redis container for ALL projects (cache, sessions, queues). It is password protected, not reachable from the internet, and keeps its data on disk."
    docker_ready && net_exists || { err "Docker/network not ready. Use main menu 1) first."; return 1; }
    if container_running "$REDIS_CONTAINER"; then ok "Redis is already running."; return 0; fi
    if [ -f "$REDIS_DIR/docker-compose.yml" ]; then
        info "Redis is installed but stopped: starting it with its existing settings and data."
        docker compose -f "$REDIS_DIR/docker-compose.yml" up -d >/dev/null 2>&1; sleep 3
        container_running "$REDIS_CONTAINER" && { ok "Redis is running."; return 0; }
        err "Redis did not start. Check: docker logs $REDIS_CONTAINER"; return 1
    fi
    pick_redis_image || { err "Cancelled."; return 1; }
    perf_scan
    local def mb pass i status=""
    if [ "$PS_RAM_MB" -lt 1500 ]; then def=64; elif [ "$PS_RAM_MB" -lt 3500 ]; then def=128; else def=256; fi
    while true; do ask "Memory Redis may use for data, in MB (suggested for this server)" "$def" mb; [[ "$mb" =~ ^[0-9]+$ ]] && [ "$mb" -ge 16 ] && [ "$mb" -le 4096 ] && break; err "Enter a number from 16 to 4096."; done
    pass="$(gen_password)"
    mkdir -p "$REDIS_DIR"; printf 'REDIS_PASSWORD=%s\n' "$pass" > "$REDIS_DIR/.env"; chmod 600 "$REDIS_DIR/.env"
    cat > "$REDIS_DIR/docker-compose.yml" <<EOF
services:
  redis:
    image: ${REDIS_IMAGE}
    container_name: ${REDIS_CONTAINER}
    restart: always
    command: ["redis-server", "--requirepass", "\${REDIS_PASSWORD}", "--maxmemory", "${mb}mb", "--maxmemory-policy", "volatile-lru", "--appendonly", "yes", "--appendfsync", "everysec"]
    environment:
      REDIS_PASSWORD: \${REDIS_PASSWORD}
    volumes:
      - redis_data:/data
    mem_limit: $(( mb + 64 ))m
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"\$\$REDIS_PASSWORD\" ping 2>/dev/null | grep -q PONG"]
      interval: 10s
      timeout: 5s
      retries: 6
    networks:
      - ${NETWORK}

networks:
  ${NETWORK}:
    external: true

volumes:
  redis_data:
EOF
    docker compose -f "$REDIS_DIR/docker-compose.yml" up -d || { err "Redis failed to start."; return 1; }
    for i in $(seq 1 20); do
        status="$(docker inspect -f '{{.State.Health.Status}}' "$REDIS_CONTAINER" 2>/dev/null)"
        [ "$status" = "healthy" ] && break
        sleep 3
    done
    [ "$status" = "healthy" ] || { err "Redis is not healthy. Check: docker logs $REDIS_CONTAINER"; return 1; }
    ok "Redis is running (data limit ${mb} MB, eviction only of keys that have an expiry, so queue jobs are never evicted)."
    next_steps "Use it in a project: Manage Projects -> project -> Project settings -> Redis."
}

redis_remove() {
    [ -f "$REDIS_DIR/docker-compose.yml" ] || { err "Redis is not installed."; return 1; }
    warn "Projects that use Redis for cache, sessions or queues will fail until you switch them back."
    confirm "Remove the Redis container?" n || return 0
    if confirm "Also delete its stored data (queued jobs, cache)?" n; then docker compose -f "$REDIS_DIR/docker-compose.yml" down -v >/dev/null 2>&1; else docker compose -f "$REDIS_DIR/docker-compose.yml" down >/dev/null 2>&1; fi
    rm -rf "$REDIS_DIR/docker-compose.yml"
    ok "Redis removed."
}

menu_redis() {
    local c
    while true; do
        clear; banner "Redis (optional)" "$C_BLUE"
        redis_status_row; echo ""
        echo " 1) Install shared Redis"
        echo " 2) Show status"
        echo " 3) Remove Redis"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item redis_install ;;
            2) run_item docker ps -a --filter "name=$REDIS_CONTAINER" --format 'table {{.Names}}\t{{.Status}}' ;;
            3) run_item redis_remove ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

project_redis_enable() {
    local path="$1" pass client enc
    load_project "$path" || return 1
    container_running "$REDIS_CONTAINER" || { err "The shared Redis is not running. Install it first: Shared Services -> Redis."; return 1; }
    pass="$(redis_pass)"
    if is_next; then
        enc="$(urlencode "$pass")"
        env_set "$path/.env" REDIS_URL "redis://:${enc}@${REDIS_CONTAINER}:6379/0"
        ok "REDIS_URL was added to .env."
        dc up -d --force-recreate >/dev/null 2>&1 && wait_healthy
        return 0
    fi
    if dexec php -m 2>/dev/null | grep -qix 'redis'; then client="phpredis"
    elif [ -d "$APP_PATH/vendor/predis" ]; then client="predis"
    else
        err "Your Laravel app has no Redis client yet."
        explain "On your computer, in the project:  composer require predis/predis   then commit, push and deploy. After that, come back here."
        return 1
    fi
    env_set "$path/.env" REDIS_CLIENT "$client"
    env_set "$path/.env" REDIS_HOST "$REDIS_CONTAINER"
    env_set "$path/.env" REDIS_PASSWORD "$(env_quote "$pass")"
    env_set "$path/.env" REDIS_PORT 6379
    env_set "$path/.env" REDIS_PREFIX "${CONTAINER_NAME}_"
    if confirm "Use Redis for the cache?" y; then env_set "$path/.env" CACHE_STORE redis; env_set "$path/.env" CACHE_DRIVER redis; env_set "$path/.env" CACHE_PREFIX "${CONTAINER_NAME}_cache_"; fi
    if confirm "Use Redis for sessions? (everyone is logged out once)" n; then env_set "$path/.env" SESSION_DRIVER redis; fi
    if confirm "Use Redis for queues? (jobs waiting in the old queue are NOT moved)" n; then env_set "$path/.env" QUEUE_CONNECTION redis; fi
    artisan optimize:clear >/dev/null 2>&1; artisan optimize >/dev/null 2>&1; artisan queue:restart >/dev/null 2>&1
    ok "Redis is configured for $(basename "$path") (client: $client)."
}

project_redis_disable() {
    local path="$1" k
    load_project "$path" || return 1
    if is_next; then env_unset "$path/.env" REDIS_URL; dc up -d --force-recreate >/dev/null 2>&1 && wait_healthy; ok "REDIS_URL removed."; return 0; fi
    for k in CACHE_STORE CACHE_DRIVER; do [ "$(env_get "$path/.env" "$k")" = "redis" ] && env_set "$path/.env" "$k" file; done
    [ "$(env_get "$path/.env" SESSION_DRIVER)" = "redis" ] && env_set "$path/.env" SESSION_DRIVER file
    if [ "$(env_get "$path/.env" QUEUE_CONNECTION)" = "redis" ]; then
        if [ "${USE_DATABASE:-yes}" = "yes" ]; then env_set "$path/.env" QUEUE_CONNECTION database; else env_set "$path/.env" QUEUE_CONNECTION sync; fi
        warn "Jobs still waiting in Redis are not moved to the new queue."
    fi
    artisan optimize:clear >/dev/null 2>&1; artisan optimize >/dev/null 2>&1; artisan queue:restart >/dev/null 2>&1
    ok "The project no longer uses Redis."
}

project_redis_menu() {
    local path="$1"
    load_project "$path" || return 1
    if [ "$(env_get "$path/.env" REDIS_HOST)" = "$REDIS_CONTAINER" ] || [[ "$(env_get "$path/.env" REDIS_URL)" == *"$REDIS_CONTAINER"* ]]; then
        ok "This project uses the shared Redis."
        confirm "Stop using Redis in this project?" n && project_redis_disable "$path"
    else
        info "This project does not use Redis yet."
        confirm "Use the shared Redis in this project?" y && project_redis_enable "$path"
    fi
}

project_settings_menu() {
    local path="$1" c
    while true; do
        load_project "$path" || return
        clear; banner "Project settings: $(basename "$path")" "$C_MAGENTA"
        echo " 1) Show the project's settings"
        echo " 2) Memory limit"
        echo " 3) Extra domains (www and others, redirect to the main domain)"
        echo " 4) Remove an extra domain"
        echo " 5) Change the main domain"
        echo " 6) Redis (use the shared Redis, or stop using it)"
        echo " 7) Upload size limit"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) project_overview "$path"; pause ;;
            2) project_set_memory "$path"; pause ;;
            3) project_alias_add "$path"; pause ;;
            4) project_alias_remove "$path"; pause ;;
            5) project_change_domain "$path"; pause; return ;;
            6) project_redis_menu "$path"; pause ;;
            7) project_set_upload "$path"; pause ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# SECURITY (main menu 8): firewall, fail2ban, automatic security updates, SSH hardening
# ============================================================================
# Nothing here changes anything until you confirm. The two risky steps (firewall, SSH login)
# have a lockout guard: a timer undoes the change by itself if you do not confirm that you
# can still log in. Nothing in this part touches Docker, your projects or your databases.

sec_get() { kv_get "$SEC_CONF" "$1"; }
sec_set() { mkdir -p "$SEC_DIR"; chmod 700 "$SEC_DIR"; kv_set "$SEC_CONF" "$1" "$2"; }
sec_val() { local v; v="$(sec_get "$1")"; printf '%s' "${v:-$2}"; }

sec_apt_install() {   # PACKAGE...
    export DEBIAN_FRONTEND=noninteractive
    info "Installing: $*"
    apt-get update -y >/dev/null 2>&1 || warn "apt update reported a problem; trying to install anyway."
    apt-get install -y "$@"
}

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]; }

# "22, 2222 22" -> "22 2222"   (fails when something is not a valid port)
sec_parse_ports() {
    local t="${1//,/ }" p out=""
    for p in $t; do valid_port "$p" || return 1; out+="$((10#$p)) "; done
    [ -n "$out" ] || return 1
    printf '%s\n' $out | sort -un | tr '\n' ' ' | sed 's/ $//'
}

# "host:port" / "[v6]:port" / "*:port" -> SEC_H (host) and SEC_P (port)
sec_split_addr() {
    local a="$1"
    SEC_P="${a##*:}"; SEC_H="${a%:*}"
    SEC_H="${SEC_H#[}"; SEC_H="${SEC_H%]}"; SEC_H="${SEC_H#::ffff:}"; SEC_H="${SEC_H%%\%*}"
}

# Who is running this menu? Sets SEC_CLIENT_IP, SEC_SESSION_PORT (the SSH port of THIS connection)
# and SEC_SERVER_IP. Works under sudo too (it follows the process tree up to the sshd session).
sec_session_info() {
    SEC_CLIENT_IP=""; SEC_SESSION_PORT=""; SEC_SERVER_IP=""
    if [ -n "${SSH_CONNECTION:-}" ]; then
        read -r SEC_CLIENT_IP _ SEC_SERVER_IP SEC_SESSION_PORT <<<"$SSH_CONNECTION"
        return 0
    fi
    local pid=$$ comm line loc peer
    while [ "${pid:-0}" -gt 1 ] 2>/dev/null; do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
        if [ "$comm" = "sshd" ]; then
            line="$(ss -H -tnp 2>/dev/null | grep -E "pid=${pid}[,)]" | head -n1)"
            if [ -n "$line" ]; then
                loc="$(awk '{print $4}' <<<"$line")"; peer="$(awk '{print $5}' <<<"$line")"
                sec_split_addr "$loc";  SEC_SERVER_IP="$SEC_H"; SEC_SESSION_PORT="$SEC_P"
                sec_split_addr "$peer"; SEC_CLIENT_IP="$SEC_H"
                return 0
            fi
        fi
        pid="$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
    done
    return 0
}

# The real SSH port(s): sshd configuration + what sshd listens on + the port of this very session
sec_ssh_ports() {
    local list=""
    list="$(sshd -T 2>/dev/null | awk '/^port /{print $2}')"
    list+=$'\n'"$(ss -H -tlnp 2>/dev/null | grep '"sshd"' | awk '{n=split($4,a,":"); print a[n]}')"
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        list+=$'\n'"$(systemctl show ssh.socket -p Listen 2>/dev/null | sed -nE 's/^Listen=.*:([0-9]+) \(Stream\).*/\1/p')"
    fi
    sec_session_info
    [ -n "$SEC_SESSION_PORT" ] && list+=$'\n'"$SEC_SESSION_PORT"
    printf '%s\n' "$list" | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ' | sed 's/ $//'
}

# ---------- lockout guard: undo a risky change automatically ---------------

sec_guard_cancel() {   # NAME
    local u="hideploy-guard-$1" pidf="$SEC_DIR/guard-$1.pid" pid
    systemctl stop "$u.timer" "$u.service" >/dev/null 2>&1 || true
    systemctl reset-failed "$u.service" "$u.timer" >/dev/null 2>&1 || true
    if [ -f "$pidf" ]; then
        pid="$(cat "$pidf" 2>/dev/null)"
        if [[ "$pid" =~ ^[0-9]+$ ]]; then pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; fi
        rm -f "$pidf"
    fi
    return 0
}

# Run COMMAND after SECONDS unless the guard is cancelled first. Survives a closed terminal
# and a dropped SSH connection (systemd timer; a detached background shell as a fallback).
sec_guard_start() {   # NAME SECONDS COMMAND [ARGS...]
    local n="$1" secs="$2"; shift 2
    sec_guard_cancel "$n"
    mkdir -p "$SEC_DIR"; chmod 700 "$SEC_DIR"
    if has_cmd systemd-run && [ -d /run/systemd/system ]; then
        systemd-run --quiet --unit="hideploy-guard-$n" --on-active="${secs}s" --timer-property=AccuracySec=1s "$@" >/dev/null 2>&1 && return 0
    fi
    ( nohup bash -c 'echo $$ > "$1"; s="$2"; shift 2; sleep "$s"; exec "$@"' _ "$SEC_DIR/guard-$n.pid" "$secs" "$@" >/dev/null 2>&1 & )
    sleep 0.3
    [ -s "$SEC_DIR/guard-$n.pid" ]
}

# Wait up to SECONDS for the user to type "yes". Returns 1 on "no", on timeout and on end of input.
sec_wait_confirm() {   # SECONDS
    local end=$(( $(date +%s) + $1 )) left reply
    while true; do
        left=$(( end - $(date +%s) ))
        [ "$left" -gt 0 ] || { echo ""; return 1; }
        if read -r -t "$left" -p "${C_YELLOW}Type yes to keep this change, no to undo it (${left}s left): ${C_RESET}" reply; then
            case "${reply,,}" in yes) return 0 ;; no) return 1 ;; esac
        else
            echo ""; return 1
        fi
    done
}

# ---------- state checks (cheap: also used by the main status table) -------

sec_fw_state() {   # active | inactive | missing
    has_cmd ufw || { echo missing; return; }
    local out; out="$(ufw status 2>/dev/null)"      # captured first: "| grep -q" can break a pipe under pipefail
    case "${out,,}" in "status: active"*) echo active ;; *) echo inactive ;; esac
}

sec_f2b_state() {  # active | nojail | inactive | missing
    has_cmd fail2ban-client || { echo missing; return; }
    systemctl is-active --quiet fail2ban 2>/dev/null || { echo inactive; return; }
    if timeout 5 fail2ban-client status sshd >/dev/null 2>&1; then echo active; else echo nojail; fi
}

sec_auto_state() { # on | off | missing
    local st cfg
    st="$(dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null)"
    [[ "$st" == *"install ok installed"* ]] || { echo missing; return; }
    cfg="$(apt-config dump 2>/dev/null)"            # captured first: "| grep -q" can break a pipe under pipefail
    if grep -qE '^APT::Periodic::Unattended-Upgrade "[1-9][0-9]*";' <<<"$cfg"; then echo on; else echo off; fi
}

# Non-security origins that unattended-upgrades is allowed to install from (empty = security only)
sec_auto_extra_origins() {
    apt-config dump 2>/dev/null | grep -E '^Unattended-Upgrade::Allowed-Origins::' | grep -E -- '-(updates|proposed|backports)' || true
}

sec_reboot_needed() { [ -f /var/run/reboot-required ]; }

sshd_val() { sshd -T 2>/dev/null | awk -v k="$1" '$1==k{print $2; exit}'; }

# 0 when sshd's effective settings could be read at all (sshd -T works)
sec_ssh_known() { [ -n "$(sshd_val passwordauthentication)" ]; }

# 0 only when the settings are readable AND password login is really closed
sec_ssh_password_closed() { sec_ssh_known && ! sec_ssh_password_open; }

# 0 when somebody can still log in with a password (plain or through PAM keyboard-interactive)
sec_ssh_password_open() {
    local pa ki pam
    pa="$(sshd_val passwordauthentication)"
    ki="$(sshd_val kbdinteractiveauthentication)"; [ -n "$ki" ] || ki="$(sshd_val challengeresponseauthentication)"
    pam="$(sshd_val usepam)"
    [ "$pa" = "yes" ] || { [ "$ki" = "yes" ] && [ "$pam" = "yes" ]; }
}

# ---------- main status table (menu top) -----------------------------------

sec_status_rows() {
    case "$(sec_fw_state)" in
        active)  status_row "Firewall (UFW)" good "ON" "incoming traffic blocked except the allowed ports" ;;
        missing) status_row "Firewall (UFW)" warn "NOT SET UP" "main menu 8) Security" ;;
        *)       status_row "Firewall (UFW)" warn "OFF" "all ports are open: main menu 8) Security" ;;
    esac
    case "$(sec_f2b_state)" in
        active)   status_row "fail2ban (SSH)" good "ON" "repeated wrong passwords are banned" ;;
        nojail)   status_row "fail2ban (SSH)" warn "NO SSH JAIL" "main menu 8) Security" ;;
        inactive) status_row "fail2ban (SSH)" warn "OFF" "installed but not running: main menu 8) Security" ;;
        *)        status_row "fail2ban (SSH)" warn "NOT SET UP" "main menu 8) Security" ;;
    esac
    case "$(sec_auto_state)" in
        on)
            if [ "$(sec_val AUTO_REBOOT no)" = "yes" ]; then
                status_row "Auto updates" good "ON" "automatic reboot at $(sec_val AUTO_REBOOT_TIME 04:30)"
            else
                status_row "Auto updates" good "ON" "no automatic reboot"
            fi ;;
        *) status_row "Auto updates" warn "OFF" "main menu 8) Security" ;;
    esac
    if has_cmd sshd && sec_ssh_known; then
        if [ "$(sshd_val permitrootlogin)" = "yes" ] && sec_ssh_password_open; then
            status_row "SSH login" bad "ROOT+PASSWORD" "root can log in with a password: main menu 8) Security"
        elif sec_ssh_password_open; then
            status_row "SSH login" warn "PASSWORD OPEN" "key-only login is safer: main menu 8) Security"
        else
            status_row "SSH login" good "KEY ONLY" "password login is closed"
        fi
    fi
    if sec_reboot_needed; then status_row "Server reboot" warn "NEEDED" "updates are waiting for a reboot: sudo reboot (containers start again by themselves)"; fi
}

# ---------- check helpers for the full report ------------------------------

SEC_ISSUES=0; SEC_WARNS=0; SEC_TODO=()
sec_row()  {   # KIND LABEL TEXT [HINT]
    case "$1" in bad) SEC_ISSUES=$((SEC_ISSUES+1)) ;; warn) SEC_WARNS=$((SEC_WARNS+1)) ;; esac
    status_row "$2" "$1" "$3" "${4:-}"
}
sec_todo() { SEC_TODO+=("$1"); }

sec_lists_age_days() {
    local f=/var/lib/apt/periodic/update-success-stamp t
    [ -e "$f" ] || f=/var/lib/apt/lists
    t="$(stat -c %Y "$f" 2>/dev/null)" || return 1
    echo $(( ( $(date +%s) - t ) / 86400 ))
}

# Counts what is waiting, using the package list that is already on the server (no network)
sec_pending_counts() {
    SEC_PEND_TOTAL=0; SEC_PEND_SEC=0
    local out
    out="$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep '^Inst ' || true)"
    [ -n "$out" ] || return 0
    SEC_PEND_TOTAL="$(grep -c '' <<<"$out")"
    SEC_PEND_SEC="$(grep -c -- '-security' <<<"$out" || true)"
}

# Users that can log in over SSH and have a public key on the server
sec_users_with_keys() {
    local u home files f n out="" cand
    files="$(sshd -T 2>/dev/null | awk '/^authorizedkeysfile /{$1=""; print}')"
    files="${files:-.ssh/authorized_keys .ssh/authorized_keys2}"
    cand="root ${SUDO_USER:-}"
    sec_session_info
    cand+=" $(logname 2>/dev/null || true) $(who -m 2>/dev/null | awk '{print $1}')"
    for u in $cand; do
        [ -n "$u" ] || continue
        case " $out " in *" $u "*) continue ;; esac
        id "$u" >/dev/null 2>&1 || continue
        home="$(getent passwd "$u" | cut -d: -f6)"
        n=0
        for f in $files; do
            f="${f//%h/$home}"; f="${f//%u/$u}"; f="${f//%U/$(id -u "$u")}"
            [[ "$f" == /* ]] || f="$home/$f"
            [ -r "$f" ] || continue
            n=$(( n + $(grep -Ev '^[[:space:]]*(#|$)' "$f" 2>/dev/null | grep -Ec '(ssh-(rsa|ed25519|dss)|ecdsa-sha2|sk-(ssh|ecdsa))' || true) ))
        done
        [ "$n" -gt 0 ] && out+="$u "
    done
    printf '%s' "${out% }"
}

# Sensitive files and folders that are readable by other users. Fills SEC_BAD_FILES with "path|mode|kind"
#   priv = nobody except the owner may touch it     env = "others" must have no access
sec_file_issues() {
    SEC_BAD_FILES=()
    local f m p
    for f in "$BK_DIR" "$BK_PASS" "$BK_SSH_KEY" "$BK_CONF" "$BK_RCLONE_ENV" "$CONFIG_FILE" "$DB_DIR/.env" "$PG_DIR/.env" "$REDIS_DIR/.env" "$BACKUP_DIR" "$BK_LOCAL_DIR" "$SEC_DIR" "$MAIL_DIR/config/postfix-accounts.cf" "$NOTIFY_DIR" "$NOTIFY_CONF"; do
        [ -e "$f" ] || continue
        m="$(stat -c %a "$f" 2>/dev/null)" || continue
        if (( (8#$m & 077) != 0 )); then SEC_BAD_FILES+=("$f|$m|priv"); fi
    done
    for p in "$PROJECTS_DIR"/*/; do
        p="${p%/}"
        [ -f "$p/.deploy.env" ] || continue
        for f in "$p/.env" "$p/.deploy.env"; do
            [ -e "$f" ] || continue
            m="$(stat -c %a "$f" 2>/dev/null)" || continue
            if (( (8#$m & 007) != 0 )); then SEC_BAD_FILES+=("$f|$m|env"); fi
        done
        for f in "$p"/storage/oauth-*.key; do
            [ -e "$f" ] || continue
            m="$(stat -c %a "$f" 2>/dev/null)" || continue
            if (( (8#$m & 077) != 0 )); then SEC_BAD_FILES+=("$f|$m|priv"); fi
        done
    done
    return 0
}

sec_files_fix() {
    section "Permissions of sensitive files"
    explain "Secrets (.env, .deploy.env, backup passphrase and keys, database password) must not be readable by other users."
    sec_file_issues
    if [ "${#SEC_BAD_FILES[@]}" -eq 0 ]; then ok "All sensitive files have safe permissions."; return 0; fi
    local e path mode kind
    for e in "${SEC_BAD_FILES[@]}"; do IFS='|' read -r path mode kind <<<"$e"; printf '  %s  (mode %s)\n' "$path" "$mode"; done
    explain "" "Fix: project .env / .deploy.env become owner:group of the project user with mode 640 (what HiDeploy itself creates);" \
        "everything else becomes owner-only (go-rwx). Containers keep working, because they run as the project user."
    confirm "Fix these ${#SEC_BAD_FILES[@]} item(s)?" y || { info "Skipped."; return 0; }
    local dir uid gid
    for e in "${SEC_BAD_FILES[@]}"; do
        IFS='|' read -r path mode kind <<<"$e"
        if [ "$kind" = "env" ]; then
            dir="$(dirname "$path")"
            uid="$(kv_get "$dir/.deploy.env" APP_UID)"; gid="$(kv_get "$dir/.deploy.env" APP_GID)"
            if [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]]; then chown "$uid:$gid" "$path" 2>/dev/null || true; fi
            chmod o-rwx "$path"
        else
            chmod go-rwx "$path"
        fi
    done
    ok "Permissions fixed."
}

# Prints one row per port that listens on a non-loopback address, and says whether it is expected
sec_report_ports() {
    local ssh_ports ufw_on=0 ufw_txt="" dpub="" proto la pn proc key seen=" " bypass allowed name hint sev found=0
    ssh_ports=" $(sec_ssh_ports) "
    if [ "$(sec_fw_state)" = "active" ]; then ufw_on=1; ufw_txt="$(ufw status 2>/dev/null)"; fi
    if docker_ready; then
        dpub="$(docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' \
            | grep -oE '(0\.0\.0\.0|\[::\]):[0-9]+->[0-9]+/(tcp|udp)' \
            | sed -E 's#^.*:([0-9]+)->.*/(tcp|udp)$#\1/\2#' | sort -u)"
    fi
    while read -r proto _ _ _ la _ rest; do
        sec_split_addr "$la"
        case "$SEC_H" in 127.*|::1) continue ;; esac
        pn="$SEC_P"
        [[ "$pn" =~ ^[0-9]+$ ]] || continue
        if [ "$proto" = "udp" ]; then case "$pn" in 68|546) continue ;; esac; fi
        key="$pn/$proto"
        case "$seen" in *" $key "*) continue ;; esac
        seen+="$key "
        found=$((found+1))
        proc="$(sed -nE 's/.*\(\("([^"]+)".*/\1/p' <<<"$rest")"
        bypass=0; [ "$proc" = "docker-proxy" ] && bypass=1
        if [ -n "$dpub" ] && grep -qx "$key" <<<"$dpub"; then bypass=1; fi
        allowed=0
        if [ "$ufw_on" -eq 1 ] && grep -qE "^${pn}(/${proto})?([[:space:]]|\$).*ALLOW" <<<"$ufw_txt"; then allowed=1; fi

        name=""
        if [ "$proto" = "tcp" ]; then
            if   [[ "$ssh_ports" == *" $pn "* ]]; then name="SSH"
            elif [ "$pn" = "80" ];  then name="HTTP"
            elif [ "$pn" = "443" ]; then name="HTTPS"
            elif mail_installed && [[ " $MAIL_PORTS " == *" $pn "* ]]; then
                case "$pn" in 25) name="Mail (SMTP)" ;; 465) name="Mail (SMTPS)" ;; 587) name="Mail (submission)" ;; *) name="Mail (IMAPS)" ;; esac
            fi
        elif [ "$proto" = "udp" ] && [ "$pn" = "443" ]; then name="HTTPS (HTTP/3)"; fi

        if [ -n "$name" ]; then
            if [ "$ufw_on" -eq 1 ] && [ "$bypass" -eq 0 ] && [ "$allowed" -eq 0 ]; then
                sec_row warn "Port $key" "BLOCKED BY FW" "$name is expected, but the firewall blocks it: Security -> Firewall"
                sec_todo "Port $key ($name) is blocked by the firewall: Security -> Firewall -> enable (it adds the rules)"
            else
                sec_row good "Port $key" "EXPECTED" "$name"
            fi
        elif [ "$ufw_on" -eq 1 ] && [ "$bypass" -eq 0 ] && [ "$allowed" -eq 0 ]; then
            sec_row good "Port $key" "BLOCKED" "${proc:-service} listens, but the firewall blocks it"
        else
            sev=warn
            case "$pn" in 1433|2375|2376|3306|3307|5432|5984|6379|9200|11211|27017) sev=bad ;; esac
            if   [ "$bypass" -eq 1 ]; then hint="published by Docker (UFW does not filter it): remove the port mapping or bind it to 127.0.0.1"
            elif [ "$ufw_on" -eq 1 ]; then hint="the firewall allows it: remove the rule (ufw delete allow $pn) if you do not need it"
            else hint="reachable from the internet: turn on the firewall, or stop the service"; fi
            sec_row "$sev" "Port $key" "OPEN" "${proc:-service}: $hint"
            sec_todo "Port $key (${proc:-service}) is open to the internet; close it unless you need it"
        fi
    done < <(ss -H -tulnp 2>/dev/null)
    if [ "$found" -eq 0 ]; then sec_row dim "Open ports" "UNKNOWN" "could not read the listening ports (ss)"; fi
}

# ---------- the full report (menu 8 -> 1, and: hideploy security-check) ----

sec_report() {
    SEC_ISSUES=0; SEC_WARNS=0; SEC_TODO=()
    local st n age users root_mode e path mode kind

    section "Protection"
    case "$(sec_fw_state)" in
        active)  sec_row good "Firewall (UFW)" "ON" "incoming traffic is blocked except the allowed ports" ;;
        missing) sec_row warn "Firewall (UFW)" "NOT SET UP" "ufw is not installed"; sec_todo "Turn on the firewall: Security -> Firewall" ;;
        *)       sec_row warn "Firewall (UFW)" "OFF" "every port that has a service behind it is reachable"; sec_todo "Turn on the firewall: Security -> Firewall" ;;
    esac
    st="$(sec_f2b_state)"
    case "$st" in
        active)
            n="$(timeout 5 fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/{gsub(/[ \t]/,"",$2); print $2}')"
            sec_row good "fail2ban (SSH)" "ON" "${n:-0} address(es) banned right now" ;;
        nojail)   sec_row warn "fail2ban (SSH)" "NO SSH JAIL" "running, but it does not watch SSH"; sec_todo "Set up fail2ban for SSH: Security -> fail2ban" ;;
        inactive) sec_row warn "fail2ban (SSH)" "OFF" "installed but not running"; sec_todo "Start fail2ban: Security -> fail2ban" ;;
        *)        sec_row warn "fail2ban (SSH)" "NOT SET UP" "nobody blocks repeated wrong passwords"; sec_todo "Set up fail2ban for SSH: Security -> fail2ban" ;;
    esac
    if [ "$(sec_auto_state)" = "on" ]; then
        if [ "$(sec_val AUTO_REBOOT no)" = "yes" ]; then
            sec_row good "Auto updates" "ON" "automatic reboot at $(sec_val AUTO_REBOOT_TIME 04:30)"
        else
            sec_row good "Auto updates" "ON" "security patches only, no automatic reboot"
        fi
        e="$(sec_auto_extra_origins)"
        if [ -n "$e" ]; then sec_row warn "Update sources" "NOT ONLY SEC." "other updates are also installed automatically ($(awk -F'"' '{print $2}' <<<"$e" | head -n2 | tr '\n' ' '))"; fi
    else
        sec_row warn "Auto updates" "OFF" "patches are installed only when you do it yourself"
        sec_todo "Turn on automatic security updates: Security -> Automatic security updates"
    fi

    section "Updates"
    sec_pending_counts
    if [ "$SEC_PEND_TOTAL" -eq 0 ]; then
        sec_row good "Waiting packages" "NONE" "nothing is waiting to be installed"
    elif [ "$SEC_PEND_SEC" -gt 0 ]; then
        sec_row bad "Waiting packages" "${SEC_PEND_SEC} SECURITY" "$SEC_PEND_TOTAL package(s) waiting, ${SEC_PEND_SEC} of them security fixes"
        sec_todo "Install the security updates: Security -> Automatic security updates -> install now"
    else
        sec_row warn "Waiting packages" "$SEC_PEND_TOTAL WAITING" "no security fixes among them"
    fi
    age="$(sec_lists_age_days || true)"
    if [ -n "$age" ] && [ "$age" -ge 3 ]; then
        sec_row warn "Package list" "${age} DAYS OLD" "the numbers above may be out of date: apt update"
    fi
    if sec_reboot_needed; then
        sec_row warn "Server reboot" "NEEDED" "waiting for a reboot: $(tr '\n' ' ' </var/run/reboot-required.pkgs 2>/dev/null | cut -c1-60)"
        sec_todo "Reboot the server when it is convenient: sudo reboot (containers start again by themselves)"
    else
        sec_row good "Server reboot" "NOT NEEDED"
    fi

    section "SSH login"
    if has_cmd sshd && ! sec_ssh_known; then
        sec_row dim "SSH login" "UNKNOWN" "could not read the effective settings (sshd -T)"
    elif has_cmd sshd; then
        if sec_ssh_password_open; then
            sec_row warn "SSH password login" "OPEN" "anyone can try passwords (fail2ban slows them down)"
            sec_todo "Switch SSH to keys only: Security -> Harden SSH"
        else
            sec_row good "SSH password login" "CLOSED" "keys only"
        fi
        root_mode="$(sshd_val permitrootlogin)"
        case "$root_mode" in
            yes) if sec_ssh_password_open; then
                     sec_row bad "SSH root login" "PASSWORD OPEN" "root can log in with a password"
                     sec_todo "Close root password login: Security -> Harden SSH"
                 else sec_row good "SSH root login" "KEY ONLY" "root can log in with a key only"; fi ;;
            prohibit-password|without-password|forced-commands-only) sec_row good "SSH root login" "KEY ONLY" "root can log in with a key only" ;;
            no) sec_row good "SSH root login" "CLOSED" ;;
            *)  sec_row dim "SSH root login" "UNKNOWN" "could not read the setting" ;;
        esac
        users="$(sec_users_with_keys)"
        if [ -n "$users" ]; then sec_row good "SSH keys on server" "FOUND" "for: $users"
        else sec_row dim "SSH keys on server" "NONE FOUND" "needed before keys-only login: add yours with ssh-copy-id"; fi
        explain "SSH port(s): $(sec_ssh_ports)"
    else
        sec_row dim "SSH server" "NOT FOUND" "sshd is not installed on this machine"
    fi

    section "Ports reachable from outside (expected: SSH, 80, 443, and the mail ports if the mail server is installed)"
    sec_report_ports

    section "Sensitive files"
    sec_file_issues
    if [ "${#SEC_BAD_FILES[@]}" -eq 0 ]; then
        sec_row good ".env, backup secrets" "SAFE" "not readable by other users"
    else
        for e in "${SEC_BAD_FILES[@]}"; do
            IFS='|' read -r path mode kind <<<"$e"
            sec_row bad "File permissions" "TOO OPEN" "$path (mode $mode)"
        done
        sec_todo "Fix file permissions: Security -> Fix permissions of sensitive files"
    fi

    echo ""
    if [ "$SEC_ISSUES" -eq 0 ] && [ "$SEC_WARNS" -eq 0 ]; then
        ok "All checks passed."
    else
        printf '%s%d problem(s), %d warning(s).%s\n' "$C_BOLD" "$SEC_ISSUES" "$SEC_WARNS" "$C_RESET"
        if [ "${#SEC_TODO[@]}" -gt 0 ]; then next_steps "${SEC_TODO[@]}"; fi
    fi
    return 0
}

# ============================================================================
# FIREWALL (UFW) with lockout protection
# ============================================================================

sec_firewall_enable() {
    section "Firewall (UFW) with lockout protection"
    explain \
        "Allows only SSH, HTTP (80) and HTTPS (443), plus the mail ports if the mail server is installed. Every other incoming connection is blocked." \
        "Safety net: right after the firewall is switched on you must confirm that you can still reach this server." \
        "If you do not confirm within about $((SEC_GUARD_SECS / 60)) minutes (or your connection drops), the firewall switches itself off again."
    local state ssh_in ssh_ports p ufw_bin existing
    state="$(sec_fw_state)"
    ssh_in="$(sec_ssh_ports)"; ssh_in="${ssh_in:-22}"
    sec_session_info
    info "SSH port(s) detected: $ssh_in"
    if [ -n "$SEC_SESSION_PORT" ]; then info "Your current connection uses port $SEC_SESSION_PORT (your IP: ${SEC_CLIENT_IP:-?})."; fi
    while true; do
        ask "SSH port(s) to keep open" "$ssh_in" p
        ssh_ports="$(sec_parse_ports "$p")" && break
        err "Enter port numbers (1-65535) separated by spaces or commas."
    done
    if [ -n "$SEC_SESSION_PORT" ] && [[ " $ssh_ports " != *" $SEC_SESSION_PORT "* ]]; then
        warn "Your current session uses port $SEC_SESSION_PORT, which was not in the list: adding it."
        ssh_ports="$(sec_parse_ports "$ssh_ports $SEC_SESSION_PORT")"
    fi

    echo ""
    printf '%sThe firewall will be set up like this:%s\n' "$C_BOLD" "$C_RESET"
    echo "   incoming   BLOCK everything except the ports below"
    echo "   outgoing   allow"
    for p in $ssh_ports; do echo "   allow      ${p}/tcp    SSH"; done
    echo "   allow      80/tcp     HTTP (websites, Let's Encrypt)"
    echo "   allow      443/tcp    HTTPS"
    if mail_installed; then for p in $MAIL_PORTS; do echo "   allow      ${p}/tcp    Mail"; done; fi
    if has_cmd ufw; then
        existing="$(ufw show added 2>/dev/null | grep '^ufw ' || true)"
        if [ -n "$existing" ]; then
            echo ""; echo "   Rules that already exist (kept):"; sed 's/^/      /' <<<"$existing"
        fi
    fi
    echo ""
    explain \
        "Docker note: ports that Docker publishes (80 and 443 here) bypass UFW by design; UFW protects everything else." \
        "MariaDB and Redis are not published, so they stay private either way."
    if [ "$state" = "active" ]; then info "UFW is already ON: these rules are added without turning it off."; fi
    confirm "Apply this?" n || { info "Skipped. Nothing was changed."; return 0; }

    has_cmd ufw || sec_apt_install ufw || { err "Could not install ufw."; return 1; }
    ufw_bin="$(command -v ufw)"
    for p in $ssh_ports; do ufw allow "${p}/tcp" >/dev/null || { err "Could not add the rule for port $p."; return 1; }; done
    ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null || { err "Could not add the web rules."; return 1; }
    if mail_installed; then for p in $MAIL_PORTS; do ufw allow "${p}/tcp" >/dev/null || { err "Could not add the rule for mail port $p."; return 1; }; done; fi
    ufw default deny incoming >/dev/null 2>&1; ufw default allow outgoing >/dev/null 2>&1
    sec_set SSH_PORTS "$ssh_ports"

    if [ "$state" = "active" ]; then ok "Rules added. The firewall stays ON."; return 0; fi

    sec_guard_start firewall $((SEC_GUARD_SECS + 15)) "$ufw_bin" --force disable \
        || { err "Could not start the safety timer, so the firewall was NOT enabled."; return 1; }
    if ! ufw --force enable; then
        sec_guard_cancel firewall
        err "ufw could not be enabled. Nothing is blocked."
        return 1
    fi
    echo ""
    ok "Firewall is ON for now."
    echo "  ${C_BOLD}Open a SECOND terminal window and log in to this server again.${C_RESET}"
    echo "  If that works, come back here and type yes. If not, type no (or wait): the firewall switches itself off."
    echo ""
    if sec_wait_confirm "$SEC_GUARD_SECS"; then
        sec_guard_cancel firewall
        ok "Confirmed. The firewall is ON and stays on after a reboot."
        next_steps "Next: Security -> fail2ban, then automatic security updates."
    else
        sec_guard_cancel firewall
        ufw --force disable >/dev/null 2>&1
        warn "Not confirmed: the firewall was switched OFF again. Nothing is blocked."
        explain "Common reasons: SSH runs on another port than the one entered, or the second login was blocked by something outside this server (cloud firewall)."
    fi
}

sec_firewall_show() {
    section "Firewall rules"
    if [ "$(sec_fw_state)" = "missing" ]; then info "ufw is not installed."; return 0; fi
    ufw status verbose 2>/dev/null | sed 's/^/  /'
}

sec_firewall_open_port() {
    section "Open another port"
    has_cmd ufw || { err "ufw is not installed: enable the firewall first."; return 1; }
    explain "Opens one more incoming port to the whole internet. Only do this for a service you really run."
    local port proto
    ask "Port number" "" port
    valid_port "$port" || { err "Not a valid port."; return 1; }
    ask "Protocol (tcp or udp)" "tcp" proto
    [[ "$proto" == tcp || "$proto" == udp ]] || { err "Use tcp or udp."; return 1; }
    confirm "Allow $((10#$port))/$proto from anywhere?" n || { info "Skipped."; return 0; }
    ufw allow "$((10#$port))/$proto" && ok "Rule added."
}

sec_firewall_disable() {
    section "Turn the firewall off"
    [ "$(sec_fw_state)" = "active" ] || { info "The firewall is already off."; return 0; }
    warn "All ports with a service behind them become reachable from the internet."
    confirm "Turn the firewall off?" n || return 0
    ufw --force disable >/dev/null && ok "Firewall is OFF. Your rules are kept; enabling it again restores them."
}

menu_sec_firewall() {
    local c
    while true; do
        clear; banner "Firewall (UFW)" "$C_RED"
        status_row "Firewall (UFW)" "$([ "$(sec_fw_state)" = active ] && echo good || echo warn)" "$([ "$(sec_fw_state)" = active ] && echo ON || echo OFF)"
        echo ""
        echo " 1) Turn on with lockout protection (SSH + 80 + 443)"
        echo " 2) Show current rules"
        echo " 3) Open another port"
        echo " 4) Turn the firewall off"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item sec_firewall_enable ;;
            2) run_item sec_firewall_show ;;
            3) run_item sec_firewall_open_port ;;
            4) run_item sec_firewall_disable ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# fail2ban for SSH
# ============================================================================

F2B_JAIL="/etc/fail2ban/jail.d/hideploy-sshd.local"

sec_valid_time() { [[ "$1" =~ ^[0-9]+[smhdw]?$ ]]; }

sec_f2b_setup() {
    section "fail2ban for SSH"
    explain \
        "Somebody who fails to log in several times is blocked for a while (default: 5 failures in 10 minutes = 1 hour ban)." \
        "Your current IP is put on the allow-list so you can never lock yourself out with a typo."
    local ports maxretry findtime bantime ignore backend extra a
    sec_session_info
    ports="$(sec_ssh_ports)"; ports="${ports:-22}"
    info "SSH port(s) watched: $ports"
    while true; do ask "Failures before a ban" "$(sec_val F2B_MAXRETRY 5)" maxretry; [[ "$maxretry" =~ ^[0-9]+$ ]] && [ "$maxretry" -ge 1 ] && break; err "Enter a number."; done
    while true; do ask "Within how long (e.g. 10m)" "$(sec_val F2B_FINDTIME 10m)" findtime; sec_valid_time "$findtime" && break; err "Use a number with s, m, h or d (e.g. 10m)."; done
    while true; do ask "Ban for how long (e.g. 1h, 1d)" "$(sec_val F2B_BANTIME 1h)" bantime; sec_valid_time "$bantime" && break; err "Use a number with s, m, h, d or w (e.g. 1h)."; done

    ignore="$(sec_val F2B_IGNORE "127.0.0.1/8 ::1")"
    if [ -n "$SEC_CLIENT_IP" ] && [[ " $ignore " != *" $SEC_CLIENT_IP "* ]]; then ignore="$ignore $SEC_CLIENT_IP"; info "Your current IP $SEC_CLIENT_IP was added to the allow-list."; fi
    while true; do
        ask "Never-ban list (IPs or ranges, space separated)" "$ignore" extra
        ignore="$extra"
        local bad=0; for a in $ignore; do [[ "$a" =~ ^[A-Za-z0-9:./_-]+$ ]] || bad=1; done
        [ "$bad" -eq 0 ] && [ -n "$ignore" ] && break
        err "That list contains characters that are not allowed."
    done
    if [ -n "$SEC_CLIENT_IP" ] && [[ " $ignore " != *" $SEC_CLIENT_IP "* ]]; then
        warn "Your current IP ($SEC_CLIENT_IP) is not on the never-ban list: a few wrong passwords from it would ban you."
    fi

    if [ -s /var/log/auth.log ]; then backend="auto"; else backend="systemd"; fi
    has_cmd fail2ban-client || { sec_apt_install fail2ban || { err "Could not install fail2ban."; return 1; }; }
    if [ "$backend" = "systemd" ]; then sec_apt_install python3-systemd >/dev/null 2>&1 || warn "python3-systemd could not be installed; fail2ban will try to cope."; fi

    mkdir -p /etc/fail2ban/jail.d
    [ -f "$F2B_JAIL" ] && cp -a "$F2B_JAIL" "$F2B_JAIL.bak"
    cat > "$F2B_JAIL" <<EOF
# Managed by HiDeploy (main menu 8 -> fail2ban). Change the values from the menu, or edit this file.
[DEFAULT]
ignoreip = $ignore
bantime  = $bantime
findtime = $findtime
maxretry = $maxretry

[sshd]
enabled = true
port    = ${ports// /,}
backend = $backend
EOF
    if ! fail2ban-client -t >/dev/null 2>&1; then
        err "fail2ban rejected the configuration:"; fail2ban-client -t 2>&1 | tail -n 8 | sed 's/^/    /'
        if [ -f "$F2B_JAIL.bak" ]; then mv -f "$F2B_JAIL.bak" "$F2B_JAIL"; else rm -f "$F2B_JAIL"; fi
        return 1
    fi
    rm -f "$F2B_JAIL.bak"
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true
    local i
    for i in 1 2 3 4 5 6 7 8; do
        [ "$(sec_f2b_state)" = "active" ] && break
        sleep 1
    done
    if [ "$(sec_f2b_state)" = "active" ]; then
        sec_set F2B_MAXRETRY "$maxretry"; sec_set F2B_FINDTIME "$findtime"; sec_set F2B_BANTIME "$bantime"; sec_set F2B_IGNORE "$ignore"
        ok "fail2ban is watching SSH (port ${ports// /,}): $maxretry failures in $findtime = banned for $bantime."
    else
        err "fail2ban started, but the SSH jail is not active. Last log lines:"
        journalctl -u fail2ban -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
        return 1
    fi
}

sec_f2b_status() {
    section "fail2ban status"
    case "$(sec_f2b_state)" in
        missing) info "fail2ban is not installed."; return 0 ;;
        inactive) warn "fail2ban is installed but not running."; return 0 ;;
        nojail) warn "fail2ban is running, but the SSH jail is not active."; return 0 ;;
    esac
    timeout 5 fail2ban-client status sshd 2>/dev/null | sed 's/^/  /'
    echo ""
    explain "Never banned: $(sec_val F2B_IGNORE '127.0.0.1/8 ::1')"
}

sec_f2b_unban() {
    section "Unban an address"
    [ "$(sec_f2b_state)" = "active" ] || { info "fail2ban is not active."; return 0; }
    local ip
    ask "IP address to unban" "" ip
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || { err "That is not an IP address."; return 1; }
    fail2ban-client set sshd unbanip "$ip" && ok "$ip was unbanned."
}

sec_f2b_off() {
    section "Turn fail2ban off"
    [ "$(sec_f2b_state)" = "missing" ] && { info "fail2ban is not installed."; return 0; }
    confirm "Stop fail2ban and keep it off after a reboot?" n || return 0
    systemctl disable --now fail2ban >/dev/null 2>&1 && ok "fail2ban is OFF (the configuration is kept)."
}

menu_sec_f2b() {
    local c
    while true; do
        clear; banner "fail2ban (SSH)" "$C_RED"
        sec_status_rows | grep 'fail2ban'; echo ""
        echo " 1) Set up / change settings (safe defaults, your IP is allow-listed)"
        echo " 2) Show status and banned addresses"
        echo " 3) Unban an address"
        echo " 4) Turn fail2ban off"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item sec_f2b_setup ;;
            2) run_item sec_f2b_status ;;
            3) run_item sec_f2b_unban ;;
            4) run_item sec_f2b_off ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# Automatic security updates
# ============================================================================

SEC_AUTO_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
SEC_AUTO_LOCAL="/etc/apt/apt.conf.d/52hideploy-unattended"

sec_auto_write_local() {
    local time; time="$(sec_val AUTO_REBOOT_TIME 04:30)"
    {
        echo "// Managed by HiDeploy (main menu 8). Only the origins in 50unattended-upgrades are used (security updates)."
        if [ "$(sec_val AUTO_REBOOT no)" = "yes" ]; then
            echo 'Unattended-Upgrade::Automatic-Reboot "true";'
            echo "Unattended-Upgrade::Automatic-Reboot-Time \"$time\";"
        else
            echo 'Unattended-Upgrade::Automatic-Reboot "false";'
        fi
    } > "$SEC_AUTO_LOCAL"
}

sec_auto_enable() {
    section "Automatic security updates"
    explain \
        "Installs security patches by itself every day. Other updates are left alone, and Docker's own packages are never touched." \
        "The server is NOT rebooted automatically (you can switch that on separately). If a reboot is needed, the menu tells you."
    if [ "$(sec_auto_state)" = "on" ]; then ok "Automatic security updates are already ON."; return 0; fi
    confirm "Turn on automatic security updates?" y || { info "Skipped."; return 0; }
    sec_apt_install unattended-upgrades || { err "Could not install unattended-upgrades."; return 1; }
    mkdir -p /etc/apt/apt.conf.d
    cat > "$SEC_AUTO_FILE" <<'EOF'
// Managed by HiDeploy (main menu 8).
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    sec_auto_write_local
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
    if [ "$(sec_auto_state)" = "on" ]; then
        ok "Automatic security updates are ON."
        local e; e="$(sec_auto_extra_origins)"
        [ -z "$e" ] || warn "This server is also set to install non-security updates (see /etc/apt/apt.conf.d/50unattended-upgrades)."
    else
        err "The setting did not take effect. Check $SEC_AUTO_FILE."
        return 1
    fi
}

sec_auto_disable() {
    section "Turn off automatic security updates"
    [ "$(sec_auto_state)" = "on" ] || { info "They are already off."; return 0; }
    warn "Security patches will then be installed only when you do it yourself."
    confirm "Turn them off?" n || return 0
    cat > "$SEC_AUTO_FILE" <<'EOF'
// Managed by HiDeploy (main menu 8).
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "0";
EOF
    ok "Automatic security updates are OFF."
}

sec_auto_reboot_toggle() {
    section "Automatic reboot after updates"
    if [ "$(sec_val AUTO_REBOOT no)" = "yes" ]; then
        ok "Automatic reboot is ON (at $(sec_val AUTO_REBOOT_TIME 04:30), only when an update needs it)."
        if confirm "Turn it OFF?" n; then sec_set AUTO_REBOOT no; sec_auto_write_local; ok "Automatic reboot is OFF."; fi
        return 0
    fi
    explain \
        "Kernel and some library updates only take effect after a reboot. With this ON the server reboots by itself," \
        "at the chosen time, but only when an update really needs it." \
        "Sites are down for about a minute. Containers start again by themselves (restart policy), except phpMyAdmin, which stays closed on purpose."
    [ "$(sec_auto_state)" = "on" ] || { warn "Turn on automatic security updates first."; return 1; }
    confirm "Turn on automatic reboot?" n || return 0
    local t
    while true; do ask "Reboot time (HH:MM, server time; pick a quiet hour and not during the backup)" "$(sec_val AUTO_REBOOT_TIME 04:30)" t
        [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break; err "Use HH:MM, e.g. 04:30."; done
    sec_set AUTO_REBOOT yes; sec_set AUTO_REBOOT_TIME "$t"; sec_auto_write_local
    ok "Automatic reboot is ON at $t."
}

sec_auto_run_now() {
    section "Install pending security updates now"
    has_cmd unattended-upgrade || { err "Turn on automatic security updates first (it installs the tool)."; return 1; }
    explain "Refreshes the package list and installs the security updates that are waiting. Nothing else is installed."
    confirm "Run it now?" y || return 0
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || warn "apt update reported a problem."
    unattended-upgrade -v 2>&1 | tail -n 25 | sed 's/^/  /'
    if sec_reboot_needed; then warn "A reboot is needed to finish: sudo reboot (containers start again by themselves)."; else ok "Done. No reboot needed."; fi
}

sec_auto_log() {
    section "Recent automatic update activity"
    local f=/var/log/unattended-upgrades/unattended-upgrades.log
    [ -f "$f" ] || { info "No log yet."; return 0; }
    tail -n 25 "$f" | sed 's/^/  /'
}

menu_sec_auto() {
    local c
    while true; do
        clear; banner "Automatic security updates" "$C_RED"
        sec_status_rows | grep -E 'Auto updates|Server reboot'; echo ""
        echo " 1) Turn on (security patches only)"
        echo " 2) Turn off"
        echo " 3) Automatic reboot when an update needs it: on / off"
        echo " 4) Install the waiting security updates now"
        echo " 5) Show recent activity"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item sec_auto_enable ;;
            2) run_item sec_auto_disable ;;
            3) run_item sec_auto_reboot_toggle ;;
            4) run_item sec_auto_run_now ;;
            5) run_item sec_auto_log ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# Harder SSH: keys only (optional)
# ============================================================================

SEC_SSH_MAIN="/etc/ssh/sshd_config"
SEC_SSH_DROPIN="/etc/ssh/sshd_config.d/00-hideploy-hardening.conf"
SEC_SSH_BACKUP="$SEC_DIR/ssh-backup"
SEC_SSH_ROLLBACK="$SEC_DIR/ssh-rollback.sh"
SEC_SSH_BEGIN="# BEGIN hideploy ssh hardening"
SEC_SSH_END="# END hideploy ssh hardening"

sec_ssh_reload() { systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || service ssh reload >/dev/null 2>&1; }

sec_ssh_hardened() { [ -f "$SEC_SSH_DROPIN" ] || grep -qF "$SEC_SSH_BEGIN" "$SEC_SSH_MAIN" 2>/dev/null; }

# The settings we add. PermitRootLogin only changes when it is "yes" (root keeps working with a key).
sec_ssh_directives() {
    local ki="KbdInteractiveAuthentication" cur
    cur="$(sshd -T 2>/dev/null)"
    grep -q '^kbdinteractiveauthentication ' <<<"$cur" || ki="ChallengeResponseAuthentication"
    echo "PasswordAuthentication no"
    echo "$ki no"
    echo "PubkeyAuthentication yes"
    if [ "$(sshd_val permitrootlogin)" = "yes" ]; then echo "PermitRootLogin prohibit-password"; fi
}

sec_ssh_write_rollback() {
    cat > "$SEC_SSH_ROLLBACK" <<EOF
#!/bin/bash
# Written by HiDeploy: puts the SSH settings back the way they were before "Harden SSH".
rm -f "$SEC_SSH_DROPIN"
[ -f "$SEC_SSH_BACKUP/sshd_config.original" ] && cp -a "$SEC_SSH_BACKUP/sshd_config.original" "$SEC_SSH_MAIN"
if sshd -t; then systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null; fi
EOF
    chmod 700 "$SEC_SSH_ROLLBACK"
}

# Evidence that key logins work: recent successful public-key logins from the logs
sec_ssh_key_logins() {
    { journalctl -q --no-pager --since "30 days ago" -u ssh -u sshd 2>/dev/null; cat /var/log/auth.log 2>/dev/null; } \
        | grep 'Accepted publickey' | tail -n 3
}

sec_ssh_harden() {
    section "Harden SSH: keys only"
    explain \
        "Closes password login, so only people with an SSH key can log in (root keeps working with a key)." \
        "This is the single most effective protection against password guessing, but a mistake would lock you out." \
        "So: it checks that a key exists on this server, asks you to test a key login in a SECOND window first," \
        "backs up the settings, tests the configuration (sshd -t), and then undoes itself if you cannot confirm."
    has_cmd sshd || { err "sshd is not installed on this machine."; return 1; }
    if sec_ssh_hardened; then ok "SSH is already hardened by HiDeploy. Use 'Undo' in the SSH menu to go back."; return 0; fi
    sec_ssh_known || { err "Could not read the effective SSH settings (sshd -T failed), so it is not safe to change them."; return 1; }
    if ! sec_ssh_password_open && [ "$(sshd_val permitrootlogin)" != "yes" ]; then ok "Password login is already closed on this server."; return 0; fi

    # 1) a key must exist
    local users ports port target ip
    users="$(sec_users_with_keys)"
    if [ -z "$users" ]; then
        err "No SSH public key was found on this server (checked root, ${SUDO_USER:-your sudo user} and your login user)."
        explain "Add your key first, from your own computer:  ssh-copy-id -p <port> <user>@<this-server>" "Then run this again."
        return 1
    fi
    ok "SSH key(s) found for: $users"

    # 2) second-window test
    sec_session_info
    ports="$(sec_ssh_ports)"; port="${SEC_SESSION_PORT:-${ports%% *}}"; port="${port:-22}"
    target="${users%% *}"
    ip="${SEC_SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    echo ""
    local logins; logins="$(sec_ssh_key_logins || true)"
    if [ -n "$logins" ]; then
        info "Recent successful key logins on this server:"; sed 's/^/    /' <<<"$logins"
    else
        warn "No successful key login was found in the logs. Do not skip the test below."
    fi
    echo ""
    echo "  ${C_BOLD}Open a SECOND terminal window on your computer and run exactly this:${C_RESET}"
    echo "    ssh -p ${port} -o PreferredAuthentications=publickey -o PasswordAuthentication=no ${target}@${ip:-<server-ip>}"
    echo "  If you get a shell without being asked for a password, the key login works."
    echo ""
    local ans; ask "Type TESTED when the key login worked in the second window (anything else cancels)" "" ans
    [ "${ans^^}" = "TESTED" ] || { info "Cancelled. Nothing was changed."; return 0; }

    echo ""; printf '%sThese settings will be added:%s\n' "$C_BOLD" "$C_RESET"; sec_ssh_directives | sed 's/^/   /'
    confirm "Apply them now?" n || { info "Cancelled. Nothing was changed."; return 0; }

    # 3) backup, write, test, verify
    mkdir -p "$SEC_SSH_BACKUP"; chmod 700 "$SEC_SSH_BACKUP"
    cp -a "$SEC_SSH_MAIN" "$SEC_SSH_BACKUP/sshd_config.$(date +%Y%m%d-%H%M%S)"
    cp -a "$SEC_SSH_MAIN" "$SEC_SSH_BACKUP/sshd_config.original"
    sec_ssh_write_rollback
    ok "Backup of the SSH settings saved in $SEC_SSH_BACKUP"

    local directives; directives="$(sec_ssh_directives)"
    local done_ok=0 tmp
    if grep -qiE "^[[:space:]]*Include[[:space:]]+$(dirname "$SEC_SSH_DROPIN")/" "$SEC_SSH_MAIN" 2>/dev/null; then
        mkdir -p "$(dirname "$SEC_SSH_DROPIN")"
        { echo "# Managed by HiDeploy (main menu 8 -> Harden SSH). Undo from that menu, or delete this file and reload ssh."; echo "$directives"; } > "$SEC_SSH_DROPIN"
        if sshd -t 2>/dev/null && sec_ssh_password_closed; then done_ok=1; else rm -f "$SEC_SSH_DROPIN"; fi
    fi
    if [ "$done_ok" -eq 0 ]; then
        tmp="$(mktemp)"
        { echo "$SEC_SSH_BEGIN"; echo "$directives"; echo "$SEC_SSH_END"; echo ""; cat "$SEC_SSH_BACKUP/sshd_config.original"; } > "$tmp"
        cat "$tmp" > "$SEC_SSH_MAIN"; rm -f "$tmp"
        if sshd -t 2>/dev/null && sec_ssh_password_closed; then done_ok=1; fi
    fi
    if [ "$done_ok" -eq 0 ]; then
        err "The new settings were rejected by 'sshd -t' or did not take effect. Restoring the original."
        sshd -t 2>&1 | head -n 5 | sed 's/^/    /'
        bash "$SEC_SSH_ROLLBACK" >/dev/null 2>&1
        return 1
    fi
    ok "sshd -t passed and the settings are effective."

    # 4) reload with a guard
    sec_guard_start ssh $((SEC_GUARD_SECS + 15)) /bin/bash "$SEC_SSH_ROLLBACK" \
        || { err "Could not start the safety timer, so nothing was applied."; bash "$SEC_SSH_ROLLBACK" >/dev/null 2>&1; return 1; }
    if ! sec_ssh_reload; then
        sec_guard_cancel ssh; bash "$SEC_SSH_ROLLBACK" >/dev/null 2>&1
        err "ssh could not be reloaded. The original settings were restored."
        return 1
    fi
    echo ""
    ok "SSH reloaded: password login is now closed. Your current session stays open."
    echo "  ${C_BOLD}In a NEW window, log in with your key once more to prove it still works.${C_RESET}"
    echo "  If you cannot, type no (or wait): the old settings come back by themselves."
    echo ""
    if sec_wait_confirm "$SEC_GUARD_SECS"; then
        sec_guard_cancel ssh
        ok "Confirmed. SSH accepts keys only."
        explain "To go back: Security -> Harden SSH -> Undo. Backups: $SEC_SSH_BACKUP"
    else
        sec_guard_cancel ssh
        bash "$SEC_SSH_ROLLBACK" >/dev/null 2>&1
        warn "Not confirmed: the original SSH settings were restored."
    fi
}

sec_ssh_undo() {
    section "Undo SSH hardening"
    if ! sec_ssh_hardened; then info "HiDeploy has not hardened SSH on this server (nothing to undo)."; return 0; fi
    [ -f "$SEC_SSH_ROLLBACK" ] || sec_ssh_write_rollback
    confirm "Restore the SSH settings from before the hardening (password login comes back)?" n || return 0
    bash "$SEC_SSH_ROLLBACK" && ok "Original SSH settings restored."
}

sec_ssh_show() {
    section "Effective SSH settings"
    has_cmd sshd || { info "sshd is not installed."; return 0; }
    sshd -T 2>/dev/null | grep -E '^(port|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitrootlogin|pubkeyauthentication|usepam|authorizedkeysfile) ' | sed 's/^/  /'
}

menu_sec_ssh() {
    local c
    while true; do
        clear; banner "Harden SSH (keys only)" "$C_RED"
        sec_status_rows | grep 'SSH login'; echo ""
        echo " 1) Switch to keys only (with checks, backup and automatic undo)"
        echo " 2) Undo: restore the previous SSH settings"
        echo " 3) Show the effective SSH settings"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item sec_ssh_harden ;;
            2) run_item sec_ssh_undo ;;
            3) run_item sec_ssh_show ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# Menu 8
# ============================================================================

menu_security() {
    local c
    while true; do
        clear; banner "8) Security" "$C_RED"
        explain "Basic server protection. Nothing changes until you confirm, and risky steps undo themselves if you lose access." ""
        sec_status_rows; echo ""
        echo " 1) Security check (full report: what is fine, what to fix)"
        echo " 2) Firewall (UFW) with lockout protection"
        echo " 3) fail2ban (blocks repeated wrong SSH passwords)"
        echo " 4) Automatic security updates"
        echo " 5) Harden SSH (keys only)  - optional"
        echo " 6) Fix permissions of sensitive files"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item sec_report ;;
            2) menu_sec_firewall ;;
            3) menu_sec_f2b ;;
            4) menu_sec_auto ;;
            5) menu_sec_ssh ;;
            6) run_item sec_files_fix ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# EMAIL (main menu 9): your own mail server, mailboxes for every domain, optional webmail
# ============================================================================
# ONE shared mail server (docker-mailserver: Postfix + Dovecot + Rspamd) serves ALL your domains,
# exactly like the shared nginx and MariaDB. A domain becomes a "mail domain" when you add it;
# a mailbox (info@example.com, noreply@example.com, ...) is then created inside it.
#
# How the pieces connect:
#   * The mail server gets the Docker network alias <mail hostname>, so your project containers and the
#     webmail reach it by the SAME name as the outside world, and the Let's Encrypt certificate matches.
#   * Mailboxes are plain lines in  $MAIL_DIR/config/postfix-accounts.cf  (password = SHA512-CRYPT hash),
#     so a password never appears on a command line ("ps").
#   * Webmail (Roundcube) is optional and closed by default: you open it when you need it, like phpMyAdmin.

valid_mail_local() { [[ "$1" =~ ^[a-z0-9]([a-z0-9._+-]{0,62}[a-z0-9])?$ ]]; }
valid_email() {
    [[ "$1" == *@* ]] && [[ "$1" != *@*@* ]] || return 1
    valid_mail_local "${1%@*}" && valid_domain "${1#*@}"
}
valid_mail_pass() { local re='^[A-Za-z0-9._%+=!@^*~-]{10,64}$'; [[ "$1" =~ $re ]]; }

mail_installed() { [ -f "$MAIL_DIR/docker-compose.yml" ] && [ -n "$(cfg_get MAIL_FQDN || true)" ]; }
mail_up()        { container_running "$MAIL_CONTAINER"; }
mail_dc()        { docker compose -f "$MAIL_DIR/docker-compose.yml" "$@"; }
mail_cmd()       { docker exec "$MAIL_CONTAINER" "$@"; }
mail_accounts_file() { printf '%s/config/postfix-accounts.cf' "$MAIL_DIR"; }
mail_virtual_file()  { printf '%s/config/postfix-virtual.cf' "$MAIL_DIR"; }

mail_status_row() {
    local f; f="$(cfg_get MAIL_FQDN || true)"
    if ! mail_installed; then
        status_row "Mail server" dim "NOT SET UP" "optional: main menu 9) Email"
    elif mail_up; then
        status_row "Mail server" good "RUNNING" "$f - $(mail_domains | wc -l) domain(s), $(mail_boxes | wc -l) mailbox(es)"
    else
        status_row "Mail server" bad "STOPPED" "start it: main menu 9) Email -> Start / stop"
    fi
}

mailweb_configured() { [ -f "$MAILWEB_DIR/docker-compose.yml" ] && [ -n "$(cfg_get MAILWEB_DOMAIN || true)" ]; }
mailweb_dc()         { docker compose -f "$MAILWEB_DIR/docker-compose.yml" "$@"; }

mailweb_status_row() {
    local d; d="$(cfg_get MAILWEB_DOMAIN || true)"
    mail_installed || return 0
    if [ -z "$d" ]; then
        status_row "Webmail" dim "NOT SET UP" "optional: main menu 9) Email -> Webmail"
    elif container_running "$MAILWEB_CONTAINER"; then
        status_row "Webmail" warn "OPEN" "public at https://$d - close it when you are done"
    else
        status_row "Webmail" good "CLOSED" "https://$d (stopped, not reachable)"
    fi
}

# ---------- registry of mail domains and mailboxes ---------------------------------------

mail_domains() {
    local -a arr=(); local d
    IFS=',' read -ra arr <<< "$(cfg_get MAIL_DOMAINS || true)"
    for d in "${arr[@]}"; do [ -n "$d" ] && printf '%s\n' "$d"; done
    return 0
}
mail_domain_registered() { grep -qx -- "$1" <<<"$(mail_domains)"; }
mail_domain_register() {
    local cur
    mail_domain_registered "$1" && return 0
    cur="$(cfg_get MAIL_DOMAINS || true)"
    cfg_set MAIL_DOMAINS "${cur:+$cur,}$1"
}
mail_domain_unregister() {
    local d out=""
    while read -r d; do [ -n "$d" ] && [ "$d" != "$1" ] && out+="${out:+,}$d"; done < <(mail_domains)
    if [ -n "$out" ]; then cfg_set MAIL_DOMAINS "$out"; else cfg_unset MAIL_DOMAINS; fi
}

# mail_boxes [DOMAIN] -> one address per line
mail_boxes() {
    local f; f="$(mail_accounts_file)"; [ -f "$f" ] || return 0
    awk -F'|' -v d="${1:-}" '{ n = split($1, a, "@"); if (n == 2 && (d == "" || a[2] == d)) print $1 }' "$f" | sort
}
mail_box_exists() { grep -qx -- "$1" <<<"$(mail_boxes)"; }

# mail_aliases [DOMAIN] -> "alias target" per line
mail_aliases() {
    local f; f="$(mail_virtual_file)"; [ -f "$f" ] || return 0
    awk -v d="${1:-}" 'NF >= 2 && $1 !~ /^#/ { n = split($1, a, "@"); if (n == 2 && (d == "" || a[2] == d)) print $1, $2 }' "$f" | sort
}

# mail_pick_domain VAR  -> choose one of the registered mail domains
# (the local names start with __ on purpose: the caller's variable name must never collide with them)
mail_pick_domain() {
    local __var="$1" __c __i=1 __d
    local -a __list=()
    mapfile -t __list < <(mail_domains)
    if [ "${#__list[@]}" -eq 0 ]; then err "No mail domain yet. Add one first (Email -> Mail domains)."; return 1; fi
    if [ "${#__list[@]}" -eq 1 ]; then printf -v "$__var" '%s' "${__list[0]}"; return 0; fi
    echo ""
    for __d in "${__list[@]}"; do printf '   %2d) %s\n' "$__i" "$__d"; __i=$((__i+1)); done
    echo "    0) Cancel"
    while true; do
        read -r -p "${C_YELLOW}Select a domain: ${C_RESET}" __c
        [ "$__c" = "0" ] && return 1
        if [[ "$__c" =~ ^[0-9]+$ ]] && [ "$__c" -ge 1 ] && [ "$__c" -le "${#__list[@]}" ]; then
            printf -v "$__var" '%s' "${__list[$((__c-1))]}"; return 0
        fi
        err "Invalid selection."
    done
}

# mail_pick_box VAR [DOMAIN] -> choose one existing mailbox
mail_pick_box() {
    local __var="$1" __c __i=1 __b
    local -a __list=()
    mapfile -t __list < <(mail_boxes "${2:-}")
    if [ "${#__list[@]}" -eq 0 ]; then err "There is no mailbox${2:+ for $2} yet."; return 1; fi
    echo ""
    for __b in "${__list[@]}"; do printf '   %2d) %s\n' "$__i" "$__b"; __i=$((__i+1)); done
    echo "    0) Cancel"
    while true; do
        read -r -p "${C_YELLOW}Select a mailbox: ${C_RESET}" __c
        [ "$__c" = "0" ] && return 1
        if [[ "$__c" =~ ^[0-9]+$ ]] && [ "$__c" -ge 1 ] && [ "$__c" -le "${#__list[@]}" ]; then
            printf -v "$__var" '%s' "${__list[$((__c-1))]}"; return 0
        fi
        err "Invalid selection."
    done
}

# ---------- passwords and accounts -------------------------------------------------------

# Sets MAIL_NEW_PASS / MAIL_PASS_GENERATED
mail_ask_pass() {
    local pass pass2
    MAIL_NEW_PASS=""; MAIL_PASS_GENERATED="no"
    while true; do
        ask_secret "Password (Enter = generate a strong one; or 10-64 characters: letters, digits, . _ % + = ! @ ^ * ~ -)" pass
        if [ -z "$pass" ]; then MAIL_NEW_PASS="$(gen_password)"; MAIL_PASS_GENERATED="yes"; return 0; fi
        valid_mail_pass "$pass" || { err "Use 10-64 characters from: letters, digits and . _ % + = ! @ ^ * ~ -  (no spaces, quotes or \$)."; continue; }
        ask_secret "Repeat password" pass2
        [ "$pass" = "$pass2" ] && { MAIL_NEW_PASS="$pass"; return 0; }
        err "Passwords do not match."
    done
}

# mail_account_write ADDRESS PASSWORD — adds the mailbox or replaces its password.
# The hash is made by openssl reading the password from stdin, so it never shows up in "ps".
mail_account_write() {
    local addr="$1" pass="$2" f hash tmp
    f="$(mail_accounts_file)"
    mkdir -p "$(dirname "$f")"; touch "$f"; chmod 600 "$f"
    hash="$(printf '%s' "$pass" | openssl passwd -6 -stdin 2>/dev/null)" || return 1
    [[ "$hash" == '$6$'* ]] || return 1
    tmp="$(mktemp)"
    awk -F'|' -v a="$addr" '$1 != a' "$f" > "$tmp"
    printf '%s|{SHA512-CRYPT}%s\n' "$addr" "$hash" >> "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
}

# mail_smtp_py MODE USER PASS [TO SUBJECT BODY [auto]] — talks to the local mail server on port 587 (STARTTLS).
#   MODE login: only checks that the login works.   MODE send: sends one message.
# Values travel in environment variables, never on a command line. Returns 2 when python3 is missing.
mail_smtp_py() {
    has_cmd python3 || return 2
    MS_MODE="$1" MS_USER="$2" MS_PASS="$3" MS_TO="${4:-}" MS_SUBJECT="${5:-}" MS_BODY="${6:-}" MS_AUTO="${7:-}" python3 - <<'PY'
import os, smtplib, ssl, sys
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
u = os.environ["MS_USER"]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE          # we talk to 127.0.0.1: only the login and delivery are tested here
try:
    with smtplib.SMTP("127.0.0.1", 587, timeout=30) as s:
        s.starttls(context=ctx)
        s.login(u, os.environ["MS_PASS"])
        if os.environ["MS_MODE"] == "send":
            m = EmailMessage()
            m["From"] = u
            m["To"] = os.environ["MS_TO"]
            m["Subject"] = os.environ["MS_SUBJECT"]
            m["Date"] = formatdate(localtime=True)
            m["Message-ID"] = make_msgid(domain=u.split("@")[1])
            if os.environ.get("MS_AUTO"):
                m["Auto-Submitted"] = "auto-generated"
                m["X-Auto-Response-Suppress"] = "All"
            m.set_content(os.environ["MS_BODY"])
            s.send_message(m)
except Exception as e:
    print("SMTP error:", e)
    sys.exit(1)
PY
}

# mail_wait_login ADDRESS PASSWORD — the mail server picks up account changes within a few seconds
mail_wait_login() {
    local addr="$1" pass="$2" i rc
    info "Waiting for the mail server to pick up the change (up to about 40 seconds)..."
    for i in $(seq 1 20); do
        mail_smtp_py login "$addr" "$pass" >/dev/null 2>&1; rc=$?
        [ "$rc" -eq 0 ] && return 0
        if [ "$rc" -eq 2 ]; then sleep 15; return 0; fi    # no python3: cannot verify, just give it time
        sleep 2
    done
    return 1
}

# ---------- DNS helpers ------------------------------------------------------------------

mail_dig_ready() {
    has_cmd dig && return 0
    info "Installing the 'dig' DNS tool (package dnsutils)..."
    sec_apt_install dnsutils >/dev/null 2>&1
    has_cmd dig
}

# mail_dig TYPE NAME -> answers, one per line (asks a public resolver first, then the system resolver)
mail_dig() {
    local out
    out="$(dig +short +time=3 +tries=1 "$2" "$1" @1.1.1.1 2>/dev/null)"
    [ -n "$out" ] || out="$(dig +short +time=3 +tries=1 "$2" "$1" 2>/dev/null)"
    printf '%s\n' "$out" | sed '/^$/d'
}
# TXT answers with the quotes and the 255-character splitting removed
mail_dig_txt() { mail_dig TXT "$1" | sed -e 's/" "//g' -e 's/"//g'; }

# DKIM: the key files are made by docker-mailserver; we only read the public part
mail_dkim_dns_file() {
    local d="$1" f
    for f in "$MAIL_DIR"/config/rspamd/dkim/*"${MAIL_DKIM_SELECTOR}-${d}.public.dns.txt" \
             "$MAIL_DIR/config/opendkim/keys/$d/${MAIL_DKIM_SELECTOR}.txt"; do
        [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
    return 0
}

# mail_dkim_record DOMAIN -> "v=DKIM1; k=rsa; p=..." on one line (empty when there is no key)
mail_dkim_record() {
    local d="$1" f rec pub
    f="$(mail_dkim_dns_file "$d")"
    if [ -n "$f" ]; then
        rec="$(grep -o '"[^"]*"' "$f" | tr -d '"\n \t')"
        if [[ "$rec" == *p=* ]]; then printf '%s' "$rec" | sed -e 's/;/; /g' -e 's/; $//'; return 0; fi
    fi
    for f in "$MAIL_DIR"/config/rspamd/dkim/*"${MAIL_DKIM_SELECTOR}-${d}.public.txt"; do
        [ -f "$f" ] || continue
        pub="$(grep -v '^-' "$f" | tr -d '\n \t')"
        [ -n "$pub" ] && { printf 'v=DKIM1; k=rsa; p=%s' "$pub"; return 0; }
    done
    return 0
}

mail_wait_ready() {
    local i
    for i in $(seq 1 60); do
        if mail_cmd sh -c 'supervisorctl status postfix dovecot 2>/dev/null | grep -c RUNNING | grep -qx 2'; then return 0; fi
        sleep 3
    done
    return 1
}

# mail_dkim_ensure DOMAIN — create the DKIM key once; reuse it afterwards
mail_dkim_ensure() {
    local d="$1" out
    if [ -n "$(mail_dkim_dns_file "$d")" ]; then return 0; fi
    info "Creating a 2048-bit DKIM key for $d ..."
    if ! out="$(mail_cmd setup config dkim keysize 2048 selector "$MAIL_DKIM_SELECTOR" domain "$d" 2>&1)"; then
        err "Could not create the DKIM key:"; printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /'
        return 1
    fi
    info "Restarting the mail server so it starts signing with the new key (about 30 seconds)..."
    docker restart "$MAIL_CONTAINER" >/dev/null 2>&1
    mail_wait_ready || warn "The mail server is slow to come back. Check: docker logs $MAIL_CONTAINER"
    [ -n "$(mail_dkim_dns_file "$d")" ] || { err "The DKIM key file was not found after creation."; return 1; }
    ok "DKIM key created."
}

mail_dns_row() {   # NUMBER TYPE NAME VALUE
    printf '\n  %s) %s record\n     Name:  %s\n     Value: %s\n' "$1" "$2" "$3" "$4"
}

# Records that belong to the mail SERVER (once per server)
mail_dns_server_show() {
    local fqdn ip; fqdn="$(cfg_get MAIL_FQDN)"; ip="$(server_ip)"
    section "DNS records for the mail server itself ($fqdn)"
    explain "Create these once, at the company that hosts the DNS of the domain that contains $fqdn."
    mail_dns_row 1 A   "$fqdn" "${ip:-<server IP>}"
    mail_dns_row 2 TXT "$fqdn" "v=spf1 a -all"
    printf '\n  3) Reverse DNS (PTR) for %s  ->  %s\n' "${ip:-<server IP>}" "$fqdn"
    explain "     This one is NOT in your DNS panel: only the company that owns the IP (your server provider) can set it." \
            "     Look for 'reverse DNS' / 'PTR' in their panel, or ask their support. Many big mail providers distrust mail without it."
    explain "" "Create ONLY an A record for $fqdn (no AAAA/IPv6 record): Docker does not pass the real IPv6 address of senders to the mail server."
}

# Records that belong to ONE mail domain
mail_dns_show() {
    local d="$1" fqdn dkim; fqdn="$(cfg_get MAIL_FQDN)"
    dkim="$(mail_dkim_record "$d")"
    section "DNS records for $d"
    explain "Create these at the company that hosts the DNS of $d. 'Name @' (or empty) means the domain itself." \
            "Mail records must be 'DNS only': if you use Cloudflare, the grey cloud, never the orange one."
    mail_dns_row 1 MX  "$d" "priority 10, mail server ${fqdn}."
    mail_dns_row 2 TXT "$d" "v=spf1 mx ~all"
    mail_dns_row 3 TXT "${MAIL_DKIM_SELECTOR}._domainkey.$d" "${dkim:-<no DKIM key yet: use 'Add / enable' first>}"
    mail_dns_row 4 TXT "_dmarc.$d" "v=DMARC1; p=none"
    echo ""
    explain "SPF: '~all' accepts other senders with a warning. If this domain also sends through another service, add its 'include:' to the SPF record." \
            "DMARC: 'p=none' only reports. After a few weeks of correct mail, you can change it to 'p=quarantine'."
}

# mail_dns_check DOMAIN — compares what the internet answers with what is expected
mail_dns_check() {
    local d="$1" fqdn ip mx spf dkim_expect dkim_got p dmarc bad=0
    fqdn="$(cfg_get MAIL_FQDN)"; ip="$(server_ip)"
    mail_dig_ready || { err "The 'dig' tool is missing and could not be installed."; return 1; }
    section "DNS check: $d (answers of a public resolver)"
    mx="$(mail_dig MX "$d" | tr 'A-Z' 'a-z')"
    if grep -qF -- " ${fqdn}." <<<"$mx"; then status_row "MX" good "OK" "points to $fqdn"
    elif [ -n "$mx" ]; then status_row "MX" bad "DIFFERENT" "answers: $(tr '\n' ' ' <<<"$mx")"; bad=$((bad+1))
    else status_row "MX" bad "MISSING" "no MX record: nobody can send mail to $d"; bad=$((bad+1)); fi

    spf="$(mail_dig_txt "$d" | grep -i '^v=spf1' | head -n1)"
    if [ -z "$spf" ]; then status_row "SPF" bad "MISSING" "add the TXT record: v=spf1 mx ~all"; bad=$((bad+1))
    elif [[ "$spf" == *" mx"* || "$spf" == *"ip4:$ip"* || "$spf" == *"a:$fqdn"* ]]; then status_row "SPF" good "OK" "$spf"
    else status_row "SPF" warn "CHECK" "exists, but does not mention this server (mx or $ip): $spf"; bad=$((bad+1)); fi

    dkim_expect="$(mail_dkim_record "$d")"
    dkim_got="$(mail_dig_txt "${MAIL_DKIM_SELECTOR}._domainkey.$d" | tr -d ' ' | head -n1)"
    p="${dkim_expect##*p=}"; p="${p// /}"
    if [ -z "$dkim_expect" ]; then status_row "DKIM" warn "NO KEY" "this server has no DKIM key for $d yet (Mail domains -> Add / enable)"; bad=$((bad+1))
    elif [ -z "$dkim_got" ]; then status_row "DKIM" bad "MISSING" "add the TXT record ${MAIL_DKIM_SELECTOR}._domainkey.$d"; bad=$((bad+1))
    elif [[ "$dkim_got" == *"$p"* ]]; then status_row "DKIM" good "OK" "public key matches"
    else status_row "DKIM" bad "DIFFERENT" "the published key is not the key of this server"; bad=$((bad+1)); fi

    dmarc="$(mail_dig_txt "_dmarc.$d" | grep -i '^v=DMARC1' | head -n1)"
    if [ -n "$dmarc" ]; then status_row "DMARC" good "OK" "$dmarc"
    else status_row "DMARC" warn "MISSING" "recommended: TXT _dmarc.$d = v=DMARC1; p=none"; bad=$((bad+1)); fi
    echo ""
    if [ "$bad" -eq 0 ]; then ok "All DNS records of $d look right."
    else warn "$bad record(s) need attention. DNS changes can take from minutes up to a few hours to spread."; fi
    return 0
}

mail_port25_out() { timeout 8 bash -c '</dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null; }

mail_blacklist_check() {
    local ip="$1" rev zone res
    rev="$(awk -F. '{print $4"."$3"."$2"."$1}' <<<"$ip")"
    for zone in zen.spamhaus.org bl.spamcop.net; do
        res="$(dig +short +time=3 +tries=1 "$rev.$zone" A 2>/dev/null | head -n1)"
        if   [[ "$res" == 127.255.255.* ]]; then status_row "$zone" dim "UNKNOWN" "this list refuses queries from shared resolvers"
        elif [[ "$res" == 127.* ]];          then status_row "$zone" bad "LISTED" "your IP is on this blacklist: mail will be rejected or go to spam"
        else status_row "$zone" good "NOT LISTED"; fi
    done
}

# The full deliverability report (server level + every mail domain)
mail_check() {
    local fqdn ip ptr a aaaa days d p listen
    mail_installed || { err "The mail server is not installed yet (Email -> Install)."; return 1; }
    mail_dig_ready || { err "The 'dig' tool is missing and could not be installed."; return 1; }
    fqdn="$(cfg_get MAIL_FQDN)"; ip="$(server_ip)"
    section "Mail server check: $fqdn"
    printf '  Server IP: %s\n\n' "${ip:-unknown}"
    if container_running "$MAIL_CONTAINER"; then status_row "Mail container" good "RUNNING"; else status_row "Mail container" bad "STOPPED" "start it: Email -> Start / stop"; fi
    listen="$(ss -ltnH 2>/dev/null | awk '{print $4}')"
    for p in $MAIL_PORTS; do
        if grep -Eq ":${p}\$" <<<"$listen"; then status_row "Port $p" good "LISTENING"
        else status_row "Port $p" bad "NOT LISTENING" "the mail server does not answer on this port"; fi
    done
    if mail_port25_out; then status_row "Outgoing port 25" good "OPEN" "this server can reach other mail servers"
    else status_row "Outgoing port 25" bad "BLOCKED" "your provider blocks it: you can receive mail, but sending needs them to unblock port 25"; fi
    a="$(mail_dig A "$fqdn" | head -n1)"; aaaa="$(mail_dig AAAA "$fqdn" | head -n1)"
    if [ -n "$ip" ] && [ "$a" = "$ip" ]; then status_row "A record" good "OK" "$fqdn -> $a"
    else status_row "A record" bad "WRONG" "$fqdn answers '${a:-nothing}', this server is ${ip:-unknown}"; fi
    if [ -n "$aaaa" ]; then status_row "AAAA record" warn "REMOVE IT" "$fqdn has an IPv6 address ($aaaa); remove it (Docker hides the real IPv6 of senders)"; fi
    ptr="$(getent hosts "$ip" 2>/dev/null | awk '{print tolower($2)}' | head -n1)"
    if [ "$ptr" = "${fqdn,,}" ]; then status_row "Reverse DNS (PTR)" good "OK" "$ip -> $ptr"
    elif [ -n "$ptr" ]; then status_row "Reverse DNS (PTR)" warn "DIFFERENT" "$ip -> $ptr (should be $fqdn): ask your server provider"
    else status_row "Reverse DNS (PTR)" warn "MISSING" "ask your server provider to set the PTR of $ip to $fqdn"; fi
    days="$(cert_days "$fqdn")"
    if [ -z "$days" ]; then status_row "Certificate" bad "MISSING" "no certificate for $fqdn"
    elif [ "$days" -lt 10 ]; then status_row "Certificate" warn "EXPIRES SOON" "$days days left"
    else status_row "Certificate" good "OK" "$days days left"; fi
    mail_blacklist_check "$ip"
    explain "" "Port 25 from the OUTSIDE cannot be tested from this server. From another computer run:  telnet $fqdn 25   (you should see a 220 greeting)."
    while read -r d; do [ -n "$d" ] && mail_dns_check "$d"; done < <(mail_domains)
    return 0
}

# ---------- installation -----------------------------------------------------------------

mail_write_compose() {
    local fqdn mem; fqdn="$(cfg_get MAIL_FQDN)"; mem="$(cfg_get MAIL_MEM || true)"; mem="${mem:-1g}"
    mkdir -p "$MAIL_DIR/config" "$MAIL_DIR/data/mail-data" "$MAIL_DIR/data/mail-state" "$MAIL_DIR/data/mail-logs"
    cat > "$MAIL_DIR/docker-compose.yml" <<EOF
services:
  mailserver:
    image: ${MAIL_IMAGE}
    container_name: ${MAIL_CONTAINER}
    hostname: ${fqdn}
    restart: always
    stop_grace_period: 1m
    cap_add:
      - NET_ADMIN              # needed by fail2ban inside the mail server
    ports:
      - "25:25"                # incoming mail from other servers
      - "465:465"              # sending (SSL/TLS)
      - "587:587"              # sending (STARTTLS)
      - "993:993"              # reading (IMAP over SSL/TLS)
    volumes:
      - ./data/mail-data:/var/mail
      - ./data/mail-state:/var/mail-state
      - ./data/mail-logs:/var/log/mail
      - ./config:/tmp/docker-mailserver
      - ${NGINX_DIR}/letsencrypt:/etc/letsencrypt:ro
      - /etc/localtime:/etc/localtime:ro
    environment:
      SSL_TYPE: "letsencrypt"
      ENABLE_RSPAMD: "1"          # spam filter + DKIM signing
      ENABLE_OPENDKIM: "0"
      ENABLE_OPENDMARC: "0"
      ENABLE_POLICYD_SPF: "0"
      ENABLE_AMAVIS: "0"
      ENABLE_SPAMASSASSIN: "0"
      ENABLE_CLAMAV: "0"          # antivirus needs about 1.5 GB of RAM: off
      ENABLE_FAIL2BAN: "1"
      ENABLE_POP3: "0"
      ENABLE_UPDATE_CHECK: "0"
      SPOOF_PROTECTION: "1"       # a mailbox may only send as itself (or its aliases)
      PERMIT_DOCKER: "none"       # containers must log in like everybody else
      POSTFIX_MESSAGE_SIZE_LIMIT: "26214400"
      POSTFIX_INET_PROTOCOLS: "ipv4"
      DOVECOT_INET_PROTOCOLS: "ipv4"
    mem_limit: ${mem}
    networks:
      ${NETWORK}:
        aliases:
          - ${fqdn}            # projects and webmail reach the mail server by its real name (certificate matches)

networks:
  ${NETWORK}:
    external: true
EOF
}

# Docker network addresses must never be banned by the mail server's fail2ban (webmail and projects live there)
mail_write_fail2ban() {
    local subnets
    subnets="$(docker network inspect "$NETWORK" -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)"
    mkdir -p "$MAIL_DIR/config"
    cat > "$MAIL_DIR/config/fail2ban-jail.cf" <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 ${subnets}
EOF
}

mail_fw_open() {
    local p
    [ "$(sec_fw_state)" = "active" ] || return 0
    for p in $MAIL_PORTS; do ufw allow "${p}/tcp" >/dev/null 2>&1; done
    ok "Firewall: mail ports $MAIL_PORTS opened."
}

mail_install() {
    section "Install the shared mail server"
    explain \
        "One mail server (Postfix + Dovecot + Rspamd spam filter, in one container) serves ALL your domains." \
        "It sends and receives mail by itself: no outside SMTP/API service is needed." \
        "You need: a hostname for the mail server (e.g. mail.example.com) with an A record pointing to this server," \
        "and open ports 25, 465, 587, 993. Memory: expect roughly 600-900 MB of RAM in use."
    docker_ready && net_exists && container_running "$NGINX_CONTAINER" \
        || { err "Docker, the network and nginx must be ready first (main menu 1 and 2)."; return 1; }
    if mail_installed; then ok "The mail server is already installed ($(cfg_get MAIL_FQDN))."; return 0; fi

    local busy ram fqdn email mem
    busy="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(25|465|587|993)$' || true)"
    if [ -n "$busy" ]; then
        err "These mail ports are already in use on this server:"; sed 's/^/    /' <<<"$busy"
        explain "Stop that service first (for example: systemctl disable --now postfix exim4), then run this again."
        return 1
    fi
    ram="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    if [ -n "$ram" ] && [ "$ram" -lt 1800 ]; then
        warn "This server has only about ${ram} MB of RAM. A mail server with spam filter needs 600-900 MB on top of your sites."
        confirm "Continue anyway?" n || return 0
    fi
    if mail_port25_out; then ok "Outgoing port 25 is open: this server can send mail to other servers."
    else
        warn "Outgoing port 25 is BLOCKED by your server provider. You can still RECEIVE mail, but sending to other servers will not work"
        warn "until they unblock it (ask their support, many do it on request)."
        confirm "Continue anyway?" n || return 0
    fi

    while true; do
        ask "Mail server hostname (e.g. mail.example.com)" "$(cfg_get MAIL_FQDN || true)" fqdn
        fqdn="${fqdn,,}"; valid_domain "$fqdn" && break; err "Invalid hostname."
    done
    explain "" "Create an A record  $fqdn  ->  this server's IP first (and NO AAAA record)."
    if ! dns_check "$fqdn"; then
        warn "DNS does not point to this server yet; the certificate cannot be issued until it does."
        confirm "Try anyway?" n || return 0
    fi

    ask "Email for certificate expiry notices" "$(cfg_get ADMIN_EMAIL || true)" email
    [ -n "$email" ] || { err "Email is required."; return 1; }
    cfg_set ADMIN_EMAIL "$email"
    info "Requesting a certificate for $fqdn ..."
    if ! certbot_run certonly --webroot -w /var/www/certbot -d "$fqdn" --email "$email" \
            --agree-tos --no-eff-email --non-interactive --keep-until-expiring; then
        err "Certificate request failed. Check that the A record is correct and port 80 is reachable."
        return 1
    fi
    ok "Certificate ready for $fqdn."

    ask "Memory limit for the mail server" "1g" mem
    [[ "$mem" =~ ^[0-9]+[mg]$ ]] || mem="1g"
    cfg_set MAIL_FQDN "$fqdn"; cfg_set MAIL_MEM "$mem"
    mail_write_compose
    mail_write_fail2ban
    chmod 700 "$MAIL_DIR/config" "$MAIL_DIR/data" 2>/dev/null || true
    info "Starting the mail server (the first start downloads the image, about 1-2 minutes)..."
    if ! mail_dc up -d; then err "The mail server could not be started."; cfg_unset MAIL_FQDN; return 1; fi
    if mail_wait_ready; then ok "The mail server is running."
    else warn "It is still starting. Check in a minute: docker logs $MAIL_CONTAINER"; fi
    mail_fw_open
    if renew_enabled; then step_renew_enable >/dev/null 2>&1; fi   # refreshes the renewal job: it now also reloads the mail server
    mail_dns_server_show
    next_steps \
        "Create the A record (and ask your provider for the reverse DNS / PTR) shown above." \
        "Add your first mail domain: Email -> Mail domains -> Add / enable." \
        "Then create mailboxes (Email -> Mailboxes) and check everything with Email -> Deliverability check." \
        "Turn on the nightly backup of mailboxes if you have not: Email -> Include mailboxes in the nightly backup."
}

mail_remove() {
    mail_installed || { err "The mail server is not installed."; return 1; }
    local typed
    warn "This stops and removes the mail server container (and the webmail, if set up)."
    warn "Your mailboxes and messages stay on disk in $MAIL_DIR/data unless you delete them in the next question."
    read -r -p "${C_RED}Type REMOVE to confirm: ${C_RESET}" typed
    [ "$typed" = "REMOVE" ] || { info "Cancelled."; return 0; }
    if mailweb_configured; then mailweb_remove_quiet; fi
    mail_dc down >/dev/null 2>&1
    if confirm "ALSO delete all mailboxes, messages, accounts and DKIM keys? (cannot be undone)" n; then
        rm -rf "$MAIL_DIR"; cfg_unset MAIL_DOMAINS
        ok "Mail data deleted."
    else
        rm -f "$MAIL_DIR/docker-compose.yml"
        info "Data kept in $MAIL_DIR (installing the mail server again with the same hostname brings it back)."
    fi
    cfg_unset MAIL_FQDN; cfg_unset MAIL_MEM
    ok "Mail server removed. Firewall rules for the mail ports were left in place (remove them with: ufw delete allow <port>/tcp)."
}

mail_start_stop() {
    mail_installed || { err "The mail server is not installed."; return 1; }
    local c
    echo " 1) Start"; echo " 2) Stop"; echo " 3) Restart"; echo " 0) Cancel"
    read -r -p "Select: " c
    case "$c" in
        1) mail_dc up -d && mail_wait_ready && ok "The mail server is running." ;;
        2) confirm "Stop the mail server? (incoming mail will be retried by the senders for a few days)" n && mail_dc stop && ok "Stopped." ;;
        3) docker restart "$MAIL_CONTAINER" >/dev/null && mail_wait_ready && ok "Restarted." ;;
        *) info "Cancelled." ;;
    esac
}

mail_logs() {
    mail_installed || { err "The mail server is not installed."; return 1; }
    local c lines
    echo " 1) Recent mail activity (delivered, deferred, rejected)"
    echo " 2) Container log (last 80 lines)"
    echo " 3) Follow the mail log live (Ctrl-C to stop)"
    echo " 4) Banned addresses (fail2ban)"
    echo " 0) Cancel"
    read -r -p "Select: " c
    case "$c" in
        1) lines="$(mail_cmd sh -c 'tail -n 600 /var/log/mail/mail.log 2>/dev/null' | grep -E 'status=|NOQUEUE|reject|warning:|SASL' | tail -n 30)"
           if [ -n "$lines" ]; then printf '%s\n' "$lines" | cut -c1-200; else info "Nothing to show yet."; fi ;;
        2) docker logs --tail 80 "$MAIL_CONTAINER" 2>&1 ;;
        3) info "Press Ctrl-C to stop."; follow_cmd docker exec "$MAIL_CONTAINER" tail -n 20 -f /var/log/mail/mail.log ;;
        4) mail_cmd setup fail2ban status 2>&1 | head -n 40
           explain "" "Unban an address:  docker exec $MAIL_CONTAINER setup fail2ban unban <ip>" ;;
        *) info "Cancelled." ;;
    esac
}

mail_toggle_backup() {
    local cur; cur="$(bk_val INCLUDE_MAIL yes)"
    printf '  Mailboxes in the nightly backup: %s\n' "$([ "$cur" = yes ] && echo INCLUDED || echo "NOT included")"
    explain "The mail ACCOUNTS, passwords (hashes) and DKIM keys are always part of the server-configuration backup." \
            "This switch controls the MESSAGES: a separate encrypted file 'mail-data' per run. Large mailboxes make backups bigger."
    if [ "$cur" = "yes" ]; then confirm "Stop including the messages?" n && bk_set INCLUDE_MAIL no && ok "Messages are no longer backed up."
    else confirm "Include the messages in the nightly backup?" y && bk_set INCLUDE_MAIL yes && ok "Messages will be included."; fi
}

# ---------- mail domains -----------------------------------------------------------------

# mail_domain_enable DOMAIN — register the domain, create its DKIM key and show the DNS records
mail_domain_enable() {
    local d="$1"
    mail_installed || { err "The mail server is not installed yet: main menu 9) Email -> Install."; return 1; }
    mail_up || { err "The mail server is not running."; return 1; }
    valid_domain "$d" || { err "Invalid domain: $d"; return 1; }
    mail_domain_register "$d"
    mail_dkim_ensure "$d" || return 1
    ok "$d is a mail domain now."
    mail_dns_show "$d"
    explain "" "The domain starts receiving mail after its MX record is published AND at least one mailbox exists."
    if [ -z "$(mail_boxes "$d")" ] && confirm "Create the first mailbox for $d now?" y; then mail_box_add "$d"; fi
    next_steps "Publish the DNS records above, wait a little, then run: Email -> Mail domains -> Check DNS."
}

mail_domain_add_menu() {
    local d
    section "Add / enable a mail domain"
    explain "Any domain you control can be a mail domain; it does not have to be one of your deployed projects." \
            "Example: example.com  (mailboxes will look like info@example.com)"
    while true; do ask "Domain" "" d; d="${d,,}"; valid_domain "$d" && break; err "Invalid domain."; done
    mail_domain_enable "$d"
}

mail_domain_remove() {
    local d="$1" typed b
    mail_domain_registered "$d" || { err "$d is not a mail domain."; return 1; }
    warn "This deletes ALL mailboxes and aliases of $d from the mail server."
    printf '  Mailboxes: %s\n' "$(mail_boxes "$d" | tr '\n' ' ')"
    read -r -p "${C_RED}Type the domain to confirm ($d): ${C_RESET}" typed
    [ "$typed" = "$d" ] || { info "Cancelled."; return 0; }
    local f tmp
    f="$(mail_accounts_file)"
    if [ -f "$f" ]; then
        tmp="$(mktemp)"; awk -F'|' -v d="$d" '{ n = split($1, a, "@"); if (!(n == 2 && a[2] == d)) print }' "$f" > "$tmp"; cat "$tmp" > "$f"; rm -f "$tmp"
    fi
    f="$(mail_virtual_file)"
    if [ -f "$f" ]; then
        tmp="$(mktemp)"; awk -v d="$d" '{ n = split($1, a, "@"); if (!(n == 2 && a[2] == d)) print }' "$f" > "$tmp"; cat "$tmp" > "$f"; rm -f "$tmp"
    fi
    if confirm "Also delete the stored messages of $d? (cannot be undone)" n && valid_domain "$d"; then
        rm -rf "$MAIL_DIR/data/mail-data/$d"; ok "Messages deleted."
    fi
    mail_domain_unregister "$d"
    ok "$d was removed from the mail server. Its DKIM key is kept (adding the domain again reuses it)."
    explain "Remember to delete the MX / SPF / DKIM / DMARC records at your DNS provider."
}

menu_mail_domains() {
    local c d
    while true; do
        clear; banner "Mail domains" "$C_BLUE"
        mail_status_row
        printf '\n  Domains: %s\n\n' "$(mail_domains | tr '\n' ' ' | sed 's/^$/none/')"
        echo " 1) Add / enable a mail domain (creates the DKIM key and shows the DNS records)"
        echo " 2) Show the DNS records of a domain"
        echo " 3) Check the DNS of a domain"
        echo " 4) Show the DNS records of the mail server itself (A, PTR)"
        echo " 5) Remove a mail domain"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) if mail_installed; then mail_domain_add_menu; else err "Install the mail server first."; fi; pause ;;
            2) if mail_installed && mail_pick_domain d; then mail_dns_show "$d"; fi; pause ;;
            3) if mail_installed && mail_pick_domain d; then mail_dns_check "$d"; fi; pause ;;
            4) if mail_installed; then mail_dns_server_show; else err "Install the mail server first."; fi; pause ;;
            5) if mail_installed && mail_pick_domain d; then mail_domain_remove "$d"; fi; pause ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ---------- mailboxes and aliases --------------------------------------------------------

mail_client_settings() {   # ADDRESS
    local fqdn; fqdn="$(cfg_get MAIL_FQDN)"
    printf '\n  Settings for mail programs and phones:\n'
    printf '    Username:        %s   (the full address)\n' "$1"
    printf '    Incoming (IMAP): %s   port 993, SSL/TLS\n' "$fqdn"
    printf '    Outgoing (SMTP): %s   port 587 STARTTLS  (or port 465 SSL/TLS)\n' "$fqdn"
}

mail_box_add() {
    local domain="${1:-}" lp addr
    mail_installed && mail_up || { err "The mail server is not running."; return 1; }
    if [ -z "$domain" ]; then mail_pick_domain domain || return 1; fi
    mail_domain_registered "$domain" || { err "$domain is not a mail domain yet (Mail domains -> Add)."; return 1; }
    while true; do
        ask "Mailbox name before the @ (e.g. info, noreply, support)" "" lp; lp="${lp,,}"
        valid_mail_local "$lp" && break
        err "Use letters, digits and . _ + - (start and end with a letter or digit)."
    done
    addr="$lp@$domain"
    mail_box_exists "$addr" && { err "$addr already exists."; return 1; }
    mail_ask_pass
    mail_account_write "$addr" "$MAIL_NEW_PASS" || { err "Could not create the account."; return 1; }
    if mail_wait_login "$addr" "$MAIL_NEW_PASS"; then ok "Mailbox $addr is ready."
    else warn "The mailbox was created but the login is not confirmed yet. Give it a minute, then try a test email."; fi
    printf '\n  Address:  %s\n' "$addr"
    if [ "$MAIL_PASS_GENERATED" = "yes" ]; then printf '  Password: %s   (shown only now, save it)\n' "$MAIL_NEW_PASS"
    else printf '  Password: the one you typed\n'; fi
    mail_client_settings "$addr"
    explain "" "Read and send in a browser: Email -> Webmail.  Use it from a project: Project menu -> Email for this project."
}

mail_box_password() {
    local addr="$1"
    mail_box_exists "$addr" || { err "$addr does not exist."; return 1; }
    warn "Everything that logs in as $addr (phones, projects) must be updated afterwards."
    mail_ask_pass
    mail_account_write "$addr" "$MAIL_NEW_PASS" || { err "Could not change the password."; return 1; }
    mail_wait_login "$addr" "$MAIL_NEW_PASS" && ok "Password changed." || warn "Not confirmed yet; give it a minute."
    if [ "$MAIL_PASS_GENERATED" = "yes" ]; then printf '  New password: %s   (shown only now, save it)\n' "$MAIL_NEW_PASS"; fi
}

mail_box_delete() {
    local addr="$1" typed f tmp d lp
    mail_box_exists "$addr" || { err "$addr does not exist."; return 1; }
    warn "This deletes the mailbox $addr (and the aliases that point to it)."
    read -r -p "${C_RED}Type the address to confirm ($addr): ${C_RESET}" typed
    [ "$typed" = "$addr" ] || { info "Cancelled."; return 0; }
    f="$(mail_accounts_file)"; tmp="$(mktemp)"
    awk -F'|' -v a="$addr" '$1 != a' "$f" > "$tmp"; cat "$tmp" > "$f"; rm -f "$tmp"
    f="$(mail_virtual_file)"
    if [ -f "$f" ]; then tmp="$(mktemp)"; awk -v a="$addr" '$2 != a' "$f" > "$tmp"; cat "$tmp" > "$f"; rm -f "$tmp"; fi
    d="${addr#*@}"; lp="${addr%@*}"
    if valid_mail_local "$lp" && valid_domain "$d" && [ -d "$MAIL_DIR/data/mail-data/$d/$lp" ] \
            && confirm "Also delete the stored messages of $addr? (cannot be undone)" n; then
        rm -rf "$MAIL_DIR/data/mail-data/$d/$lp"; ok "Messages deleted."
    fi
    ok "Mailbox $addr removed."
}

mail_alias_add() {
    local domain="${1:-}" lp al target
    if [ -z "$domain" ]; then mail_pick_domain domain || return 1; fi
    explain "An alias is an extra address that delivers to another address, e.g. contact@example.com -> info@example.com." \
            "The target can also be an address on another server."
    while true; do ask "Alias name before the @ (e.g. contact)" "" lp; lp="${lp,,}"; valid_mail_local "$lp" && break; err "Invalid name."; done
    al="$lp@$domain"
    mail_box_exists "$al" && { err "$al is already a real mailbox."; return 1; }
    while true; do ask "Deliver it to (full address)" "" target; target="${target,,}"; valid_email "$target" && break; err "Invalid address."; done
    [ "$al" != "$target" ] || { err "An alias cannot point to itself."; return 1; }
    local f; f="$(mail_virtual_file)"; mkdir -p "$(dirname "$f")"; touch "$f"
    grep -qE "^${al//./\\.}[[:space:]]" "$f" 2>/dev/null && { err "$al already exists."; return 1; }
    printf '%s %s\n' "$al" "$target" >> "$f"
    ok "Alias added: $al -> $target (active within a few seconds)."
}

mail_alias_remove() {
    local domain="${1:-}" choice i=1 line f tmp
    local -a list=()
    mapfile -t list < <(mail_aliases "$domain")
    [ "${#list[@]}" -gt 0 ] || { info "There are no aliases${domain:+ for $domain}."; return 0; }
    echo ""
    for line in "${list[@]}"; do printf '   %2d) %s\n' "$i" "${line/ / -> }"; i=$((i+1)); done
    echo "    0) Cancel"
    read -r -p "${C_YELLOW}Remove which alias: ${C_RESET}" choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#list[@]}" ] || { info "Cancelled."; return 0; }
    line="${list[$((choice-1))]}"
    f="$(mail_virtual_file)"; tmp="$(mktemp)"
    awk -v a="${line%% *}" -v t="${line#* }" '!($1 == a && $2 == t)' "$f" > "$tmp"; cat "$tmp" > "$f"; rm -f "$tmp"
    ok "Alias removed."
}

mail_box_list() {   # [DOMAIN]
    local b size d lp
    section "Mailboxes${1:+ of $1}"
    if [ -z "$(mail_boxes "${1:-}")" ]; then info "No mailboxes yet."; else
        while read -r b; do
            d="${b#*@}"; lp="${b%@*}"
            size="$(du -sh "$MAIL_DIR/data/mail-data/$d/$lp" 2>/dev/null | cut -f1)"
            printf '  %-40s %s\n' "$b" "${size:-empty}"
        done < <(mail_boxes "${1:-}")
    fi
    if [ -n "$(mail_aliases "${1:-}")" ]; then
        echo ""; echo "  Aliases:"
        mail_aliases "${1:-}" | sed 's/ / -> /; s/^/    /'
    fi
}

# menu_mail_boxes [DOMAIN]  (with a domain: only that domain, used from the project menu)
menu_mail_boxes() {
    local dom="${1:-}" c b
    while true; do
        clear; banner "Mailboxes${dom:+: $dom}" "$C_BLUE"
        mail_status_row; echo ""
        echo " 1) List mailboxes and aliases"
        echo " 2) Create a mailbox"
        echo " 3) Change a mailbox password"
        echo " 4) Delete a mailbox"
        echo " 5) Add an alias (extra address that delivers to another address)"
        echo " 6) Remove an alias"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) mail_box_list "$dom"; pause ;;
            2) mail_box_add "$dom"; pause ;;
            3) if mail_pick_box b "$dom"; then mail_box_password "$b"; fi; pause ;;
            4) if mail_pick_box b "$dom"; then mail_box_delete "$b"; fi; pause ;;
            5) mail_alias_add "$dom"; pause ;;
            6) mail_alias_remove "$dom"; pause ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

mail_send_test() {
    local from pass to
    mail_installed && mail_up || { err "The mail server is not running."; return 1; }
    has_cmd python3 || { err "python3 is needed for this test (apt install python3)."; return 1; }
    section "Send a test email"
    explain "Sends one message from one of your mailboxes through your own server, to any address you choose." \
            "Use an address you can read (for example on another provider) and check whether it arrives in the inbox or in spam."
    mail_pick_box from || return 1
    ask_secret "Password of $from" pass
    ask "Send the test to (full address)" "" to; to="${to,,}"
    valid_email "$to" || { err "Invalid address."; return 1; }
    if ! mail_smtp_py send "$from" "$pass" "$to" "Test from your own mail server" \
        "This message was sent by HiDeploy through your own mail server ($(cfg_get MAIL_FQDN)). If you can read it, sending works."; then
        err "Sending failed (wrong password, or the mail server is not ready)."; return 1
    fi
    ok "The server accepted the message. Delivery to $to now happens in the background."
    sleep 6
    local lines
    lines="$(mail_cmd sh -c 'tail -n 300 /var/log/mail/mail.log 2>/dev/null' | grep -F -- "$to" | grep -E 'status=' | tail -n 3)"
    if [ -n "$lines" ]; then
        echo "  Delivery log:"; printf '%s\n' "$lines" | sed 's/^/    /' | cut -c1-200
        grep -q 'status=sent' <<<"$lines" && ok "Delivered to the other server." || warn "Not delivered yet. See: Email -> Status and logs."
    else
        info "No delivery line yet. Check again in a minute: Email -> Status and logs."
    fi
}

# ---------- webmail (Roundcube), closed unless you open it -------------------------------

# write_mailweb_vhost DOMAIN MODE   MODE: http | open | closed | https (= open if running, else closed)
write_mailweb_vhost() {
    local domain="$1" mode="$2" out="$NGINX_DIR/conf.d/$1.conf" ip have_allow=0
    local -a ips=()
    if [ "$mode" = "https" ]; then
        if container_running "$MAILWEB_CONTAINER"; then mode="open"; else mode="closed"; fi
    fi
    IFS=',' read -ra ips <<< "$(cfg_get MAILWEB_ALLOW || true)"
    {
        if [ "$mode" = "http" ]; then
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
                echo "    # Webmail is stopped: this domain is closed completely."
                echo "    return 444;"
            else
                echo "    client_max_body_size 30M;"
                echo "    resolver 127.0.0.11 valid=10s ipv6=off;"
                for ip in "${ips[@]}"; do
                    ip="${ip// /}"
                    [ -n "$ip" ] && { echo "    allow $ip;"; have_allow=1; }
                done
                [ "$have_allow" -eq 1 ] && echo "    deny all;"
                if [ -f "$MAILWEB_HTPASSWD" ]; then
                    echo '    auth_basic "Restricted";'
                    echo "    auth_basic_user_file /etc/nginx/conf.d/webmail.htpasswd;"
                fi
                echo '    add_header X-Robots-Tag "noindex, nofollow" always;'
                cat <<'EOF'

    location / {
        set $web_upstream "http://__WEB__:80";
        proxy_pass $web_upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
EOF
            fi
            echo "}"
        fi
    } | sed -e "s|__DOMAIN__|$domain|g" -e "s|__WEB__|$MAILWEB_CONTAINER|g" > "$out"
}

mailweb_write_compose() {
    local fqdn; fqdn="$(cfg_get MAIL_FQDN)"
    mkdir -p "$MAILWEB_DIR"
    cat > "$MAILWEB_DIR/docker-compose.yml" <<EOF
services:
  webmail:
    image: ${MAILWEB_IMAGE}
    container_name: ${MAILWEB_CONTAINER}
    restart: "no"          # does NOT come back after a server reboot: you open it only when you need it
    environment:
      ROUNDCUBEMAIL_DEFAULT_HOST: "tls://${fqdn}"
      ROUNDCUBEMAIL_DEFAULT_PORT: "143"
      ROUNDCUBEMAIL_SMTP_SERVER: "tls://${fqdn}"
      ROUNDCUBEMAIL_SMTP_PORT: "587"
      ROUNDCUBEMAIL_DB_TYPE: "sqlite"
      ROUNDCUBEMAIL_UPLOAD_MAX_FILESIZE: "25M"
      ROUNDCUBEMAIL_PLUGINS: "archive,zipdownload"
    volumes:
      - webmail-db:/var/roundcube/db
    mem_limit: 256m
    networks:
      - ${NETWORK}

volumes:
  webmail-db:

networks:
  ${NETWORK}:
    external: true
EOF
}

mailweb_write_auth() {
    local user="$1" pass="$2" hash
    hash="$(printf '%s' "$pass" | openssl passwd -apr1 -stdin)" || return 1
    printf '%s:%s\n' "$user" "$hash" > "$MAILWEB_HTPASSWD"
    chmod 644 "$MAILWEB_HTPASSWD"
}

# Sets MW_USER / MW_PASS / MW_GENERATED; MW_USER empty = no extra login
mailweb_ask_auth() {
    local pass pass2
    MW_USER=""; MW_PASS=""; MW_GENERATED="no"
    explain \
        "Extra protection (recommended): a browser login (HTTP Basic Auth) in front of the webmail page." \
        "After it you still log in with your mailbox address and password."
    confirm "Add the extra browser login?" y || return 0
    while true; do
        ask "Basic-auth username" "${1:-admin}" MW_USER
        [[ "$MW_USER" =~ ^[A-Za-z0-9_.-]{3,32}$ ]] && break
        err "Use 3-32 characters: letters, digits, dot, dash, underscore."
    done
    while true; do
        ask_secret "Basic-auth password (Enter = auto-generate a strong one)" pass
        if [ -z "$pass" ]; then MW_PASS="$(gen_password)"; MW_GENERATED="yes"; break; fi
        [ "${#pass}" -ge 10 ] || { err "Use at least 10 characters."; continue; }
        ask_secret "Repeat password" pass2
        [ "$pass" = "$pass2" ] && { MW_PASS="$pass"; break; }
        err "Passwords do not match."
    done
}

mailweb_ask_ips() {
    local ips ip ok_all=1 mine="${SSH_CLIENT:-}"
    mine="${mine%% *}"
    explain \
        "Optional: only these IP addresses may open the webmail at all." \
        "Example: 203.0.113.10,198.51.100.0/24   (Enter = no IP restriction)"
    [ -n "$mine" ] && explain "Your current IP (from your SSH session) looks like: $mine"
    while true; do
        ask "Allowed IPs, comma-separated" "$(cfg_get MAILWEB_ALLOW || true)" ips
        ips="${ips// /}"; ok_all=1
        local -a list=(); IFS=',' read -ra list <<< "$ips"
        for ip in "${list[@]}"; do
            [[ "$ip" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || ok_all=0
        done
        [ "$ok_all" -eq 1 ] && break
        err "Invalid IP list."
    done
    if [ -n "$ips" ]; then cfg_set MAILWEB_ALLOW "$ips"; else cfg_unset MAILWEB_ALLOW; fi
}

mailweb_setup() {
    section "Webmail setup (optional)"
    explain \
        "Roundcube: read, write and send mail in the browser, for every mailbox on your mail server." \
        "It runs on its own domain with HTTPS. It does NOT start automatically after a reboot:" \
        "you open it when you need it and close it when you are done. While closed, the domain does not answer at all."
    mail_installed && mail_up || { err "Install and start the mail server first (Email -> Install)."; return 1; }
    container_running "$NGINX_CONTAINER" || { err "nginx is not running."; return 1; }
    local domain
    while true; do
        ask "Webmail domain (e.g. webmail.example.com)" "$(cfg_get MAILWEB_DOMAIN || true)" domain
        domain="${domain,,}"; valid_domain "$domain" && break; err "Invalid domain."
    done
    if [ -f "$NGINX_DIR/conf.d/$domain.conf" ] && ! mailweb_configured; then
        err "A site configuration for $domain already exists (used by a project). Choose another domain."; return 1
    fi
    explain "Create an A record for $domain pointing to this server first."
    if ! dns_check "$domain"; then
        warn "DNS does not point to this server yet."
        confirm "Continue anyway? (the certificate will fail until DNS is correct)" n || return 1
    fi
    mailweb_ask_auth "admin"
    mailweb_ask_ips
    mailweb_write_compose
    if [ -n "$MW_USER" ]; then mailweb_write_auth "$MW_USER" "$MW_PASS" || { err "Could not create the password file."; return 1; }
    else rm -f "$MAILWEB_HTPASSWD"; fi
    cfg_set MAILWEB_DOMAIN "$domain"
    info "Starting the webmail container (the first start downloads the image)..."
    mailweb_dc up -d || { err "Could not start the webmail."; return 1; }
    apply_vhost "$domain" "$MAILWEB_CONTAINER" http mailweb || return 1
    if ssl_setup "$domain" "$MAILWEB_CONTAINER" mailweb; then
        echo ""; banner "Webmail is ready" "$C_BLUE"
        printf '  URL: https://%s\n' "$domain"
        if [ -n "$MW_USER" ]; then
            printf '  Browser login user: %s\n' "$MW_USER"
            if [ "$MW_GENERATED" = "yes" ]; then printf '  Browser login pass: %s   (shown only now, save it)\n' "$MW_PASS"; else printf '  Browser login pass: the one you typed\n'; fi
        fi
        explain "" "Then log in with a full mailbox address (for example info@example.com) and its password."
        warn "While it is open, anyone who reaches the page can try to log in. Close it when you finish."
        confirm "Leave the webmail OPEN right now?" y || mailweb_stop
        next_steps "Close it any time: Email -> Webmail -> Stop." "Open it again: Email -> Webmail -> Start."
    else
        warn "SSL failed, so for safety the webmail stays closed. Fix DNS and run this setup again."
        mailweb_dc stop >/dev/null 2>&1
        return 1
    fi
}

mailweb_start() {
    mailweb_configured || { err "Webmail is not set up yet (option 1)."; return 1; }
    mail_up || { err "The mail server is not running."; return 1; }
    local domain; domain="$(cfg_get MAILWEB_DOMAIN)"
    mailweb_dc up -d || { err "Could not start the webmail."; return 1; }
    apply_vhost "$domain" "$MAILWEB_CONTAINER" open mailweb || return 1
    ok "Webmail is OPEN: https://$domain"
    warn "Remember to close it when you are done: Email -> Webmail -> Stop."
}

mailweb_stop() {
    mailweb_configured || { err "Webmail is not set up."; return 1; }
    local domain; domain="$(cfg_get MAILWEB_DOMAIN)"
    apply_vhost "$domain" "$MAILWEB_CONTAINER" closed mailweb || return 1
    mailweb_dc stop >/dev/null 2>&1
    ok "Webmail is CLOSED: the domain no longer answers and the container is stopped."
}

mailweb_status() {
    section "Webmail status"
    if ! mailweb_configured; then info "Not set up. Use option 1."; return 0; fi
    local d days allow user
    d="$(cfg_get MAILWEB_DOMAIN)"; days="$(cert_days "$d")"; allow="$(cfg_get MAILWEB_ALLOW || true)"
    user="$(cut -d: -f1 "$MAILWEB_HTPASSWD" 2>/dev/null)"
    printf '  Domain:            https://%s\n' "$d"
    printf '  State:             %s\n' "$(container_running "$MAILWEB_CONTAINER" && echo "OPEN (running)" || echo "CLOSED (stopped)")"
    printf '  SSL days left:     %s\n' "${days:--}"
    printf '  Browser login:     %s\n' "${user:-none}"
    printf '  Allowed IPs:       %s\n' "${allow:-anyone who reaches the page}"
}

# Remove without questions (used when the whole mail server is removed)
mailweb_remove_quiet() {
    local domain; domain="$(cfg_get MAILWEB_DOMAIN)"
    mailweb_dc down -v >/dev/null 2>&1
    [ -n "$domain" ] && rm -f "$NGINX_DIR/conf.d/$domain.conf"
    rm -f "$MAILWEB_HTPASSWD"; nginx_test_reload >/dev/null 2>&1
    rm -rf "$MAILWEB_DIR"; cfg_unset MAILWEB_DOMAIN; cfg_unset MAILWEB_ALLOW
}

mailweb_remove() {
    mailweb_configured || { err "Webmail is not set up."; return 1; }
    local domain; domain="$(cfg_get MAILWEB_DOMAIN)"
    warn "This removes the webmail container, its settings and its nginx configuration (your mailboxes are NOT touched)."
    confirm "Remove the webmail?" n || return 0
    mailweb_remove_quiet
    if [ -d "$NGINX_DIR/letsencrypt/live/$domain" ] && confirm "Delete the SSL certificate for $domain too?" y; then
        certbot_run delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 && ok "Certificate deleted."
    fi
    ok "Webmail removed."
}

menu_webmail() {
    local c domain
    while true; do
        clear; banner "Webmail (optional)" "$C_BLUE"
        mailweb_status_row; echo ""
        echo " 1) Set up the webmail (domain + HTTPS + extra login + optional IP list)"
        echo " 2) Start  (open it to the internet)"
        echo " 3) Stop   (close it completely)"
        echo " 4) Show status"
        echo " 5) Change the browser login (Basic Auth)"
        echo " 6) Change the allowed IP list"
        echo " 7) Remove the webmail"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item mailweb_setup ;;
            2) run_item mailweb_start ;;
            3) run_item mailweb_stop ;;
            4) run_item mailweb_status ;;
            5) if mailweb_configured; then
                   mailweb_ask_auth "$(cut -d: -f1 "$MAILWEB_HTPASSWD" 2>/dev/null)"
                   if [ -n "$MW_USER" ]; then mailweb_write_auth "$MW_USER" "$MW_PASS"; else rm -f "$MAILWEB_HTPASSWD"; fi
                   domain="$(cfg_get MAILWEB_DOMAIN)"
                   apply_vhost "$domain" "$MAILWEB_CONTAINER" https mailweb && ok "Browser login updated."
                   [ "$MW_GENERATED" = "yes" ] && warn "New generated password: $MW_PASS   (shown only now)"
               else err "Webmail is not set up."; fi
               pause ;;
            6) if mailweb_configured; then
                   mailweb_ask_ips
                   domain="$(cfg_get MAILWEB_DOMAIN)"
                   apply_vhost "$domain" "$MAILWEB_CONTAINER" https mailweb && ok "IP list applied."
               else err "Webmail is not set up."; fi
               pause ;;
            7) run_item mailweb_remove ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ---------- email inside a project -------------------------------------------------------

# Writes the SMTP settings of one mailbox into the project's .env
mail_project_connect() {
    local path="$1" domain mdom addr pass fqdn from_name enc_u enc_p
    load_project "$path" || return 1
    mail_installed && mail_up || { err "The mail server is not running (main menu 9) Email)."; return 1; }
    [ -f "$path/.env" ] || { err "This project has no .env file yet."; return 1; }
    domain="$(basename "$path")"; mdom="$(kv_get "$path/.deploy.env" MAIL_DOMAIN)"; mdom="${mdom:-$domain}"
    mail_domain_registered "$mdom" || { err "$mdom is not a mail domain yet. Use option 1 first."; return 1; }
    mail_pick_box addr "$mdom" || return 1
    fqdn="$(cfg_get MAIL_FQDN)"
    echo ""
    ask_secret "Password of $addr (Enter = set a NEW generated password now)" pass
    if [ -z "$pass" ]; then
        warn "A new password replaces the old one: everything else that logs in as $addr must be updated."
        confirm "Set a new password for $addr?" y || return 0
        pass="$(gen_password)"
        mail_account_write "$addr" "$pass" || { err "Could not change the password."; return 1; }
        mail_wait_login "$addr" "$pass" || warn "The new password is not confirmed yet; the project may fail to send for a minute."
    else
        mail_smtp_py login "$addr" "$pass" >/dev/null 2>&1
        case $? in
            0) ok "Login verified." ;;
            2) warn "python3 is missing: could not verify the password." ;;
            *) err "That password does not work for $addr."; return 1 ;;
        esac
    fi
    if is_next; then
        enc_u="$(urlencode "$addr")"; enc_p="$(urlencode "$pass")"
        env_set "$path/.env" SMTP_HOST "$fqdn"
        env_set "$path/.env" SMTP_PORT 587
        env_set "$path/.env" SMTP_SECURE false
        env_set "$path/.env" SMTP_USER "$addr"
        env_set "$path/.env" SMTP_PASSWORD "${pass//\$/\$\$}"
        env_set "$path/.env" SMTP_FROM "$addr"
        env_set "$path/.env" SMTP_URL "smtp://${enc_u}:${enc_p}@${fqdn}:587"
        ok "SMTP_HOST, SMTP_PORT, SMTP_SECURE, SMTP_USER, SMTP_PASSWORD, SMTP_FROM and SMTP_URL were written to .env."
        dc up -d --force-recreate >/dev/null 2>&1 && wait_healthy
    else
        env_set "$path/.env" MAIL_MAILER smtp
        env_set "$path/.env" MAIL_HOST "$fqdn"
        env_set "$path/.env" MAIL_PORT 587
        env_set "$path/.env" MAIL_USERNAME "$addr"
        env_set "$path/.env" MAIL_PASSWORD "$(env_quote "$pass")"
        env_set "$path/.env" MAIL_ENCRYPTION tls
        env_set "$path/.env" MAIL_FROM_ADDRESS "$(env_quote "$addr")"
        env_unset "$path/.env" MAIL_SCHEME
        if [ -z "$(env_get "$path/.env" MAIL_FROM_NAME)" ]; then
            from_name='"${APP_NAME}"'; env_set "$path/.env" MAIL_FROM_NAME "$from_name"
        fi
        ok "MAIL_MAILER, MAIL_HOST, MAIL_PORT, MAIL_USERNAME, MAIL_PASSWORD, MAIL_ENCRYPTION and MAIL_FROM_ADDRESS were written to .env."
        artisan optimize:clear >/dev/null 2>&1; artisan optimize >/dev/null 2>&1; artisan queue:restart >/dev/null 2>&1
    fi
    kv_set "$path/.deploy.env" MAIL_DOMAIN "$mdom"
    echo ""
    printf '  %s now sends through your own mail server (%s:587, STARTTLS) as %s.\n' "$domain" "$fqdn" "$addr"
    explain "The project container reaches the mail server through the internal Docker network; nothing leaves this server until the message goes to its recipient." \
            "Try it from the project (a password-reset mail, for example) and watch: Email -> Status and logs."
}

mail_project_disconnect() {
    local path="$1" k
    load_project "$path" || return 1
    confirm "Remove the SMTP settings from this project's .env?" n || return 0
    if is_next; then
        for k in SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_USER SMTP_PASSWORD SMTP_FROM SMTP_URL; do env_unset "$path/.env" "$k"; done
        dc up -d --force-recreate >/dev/null 2>&1 && wait_healthy
    else
        env_set "$path/.env" MAIL_MAILER log
        for k in MAIL_HOST MAIL_USERNAME MAIL_PASSWORD; do env_set "$path/.env" "$k" ""; done
        artisan optimize:clear >/dev/null 2>&1; artisan optimize >/dev/null 2>&1; artisan queue:restart >/dev/null 2>&1
    fi
    ok "SMTP settings removed (a Laravel project now writes mail to its log instead of sending it)."
}

mail_project_show() {
    local path="$1" domain mdom fqdn
    load_project "$path" || return 1
    domain="$(basename "$path")"; mdom="$(kv_get "$path/.deploy.env" MAIL_DOMAIN)"
    section "Email of $domain"
    printf '  Mail domain:   %s\n' "${mdom:-not enabled (project domain $domain is the default)}"
    if mail_installed; then fqdn="$(cfg_get MAIL_FQDN)"; printf '  Mail server:   %s (%s)\n' "$fqdn" "$(mail_up && echo running || echo stopped)"; else printf '  Mail server:   not installed\n'; fi
    if is_next; then
        printf '  In .env:       SMTP_HOST=%s  SMTP_USER=%s\n' "$(env_get "$path/.env" SMTP_HOST)" "$(env_get "$path/.env" SMTP_USER)"
    else
        printf '  In .env:       MAIL_MAILER=%s  MAIL_HOST=%s  MAIL_USERNAME=%s\n' "$(env_get "$path/.env" MAIL_MAILER)" "$(env_get "$path/.env" MAIL_HOST)" "$(env_get "$path/.env" MAIL_USERNAME)"
    fi
    [ -n "${mdom:-}" ] && { echo ""; echo "  Mailboxes:"; mail_boxes "$mdom" | sed 's/^/    /'; }
    return 0
}

project_mail_menu() {
    local path="$1" c domain mdom
    domain="$(basename "$path")"
    while true; do
        load_project "$path" || return
        mdom="$(kv_get "$path/.deploy.env" MAIL_DOMAIN)"; mdom="${mdom:-$domain}"
        clear; banner "Email for: $domain" "$C_BLUE"
        mail_status_row
        printf '  Mail domain of this project: %s\n\n' "$mdom"
        echo " 1) Enable email for this domain (adds it to the mail server, DKIM key, DNS records)"
        echo " 2) Mailboxes and aliases of $mdom"
        echo " 3) Let this project send mail through a mailbox (writes the SMTP settings to .env)"
        echo " 4) Show the DNS records / check the DNS"
        echo " 5) Show this project's mail settings"
        echo " 6) Stop sending mail from this project (remove the SMTP settings)"
        echo " 7) Use a different mail domain for this project (default: the project domain)"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) mail_domain_enable "$mdom" && kv_set "$path/.deploy.env" MAIL_DOMAIN "$mdom"; pause ;;
            2) if mail_installed && mail_domain_registered "$mdom"; then menu_mail_boxes "$mdom"; else err "Enable email for $mdom first (option 1)."; pause; fi ;;
            3) mail_project_connect "$path"; pause ;;
            4) if mail_installed && mail_domain_registered "$mdom"; then
                   mail_dns_show "$mdom"
                   confirm "Check now what the internet answers for these records?" y && mail_dns_check "$mdom"
               else err "Enable email for $mdom first (option 1)."; fi
               pause ;;
            5) mail_project_show "$path"; pause ;;
            6) mail_project_disconnect "$path"; pause ;;
            7) ask "Mail domain (e.g. example.com)" "$mdom" c; c="${c,,}"
               if valid_domain "$c"; then kv_set "$path/.deploy.env" MAIL_DOMAIN "$c"; ok "Mail domain of this project: $c (enable it with option 1 if it is new)."; else err "Invalid domain."; fi
               pause ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ---------- main menu 9 ------------------------------------------------------------------

menu_mail() {
    local c
    while true; do
        clear; banner "9) Email (your own mail server)" "$C_BLUE"
        explain "One shared mail server for ALL your domains: send and receive without any outside SMTP/API service." \
                "Typical order: 1 (install) -> 2 (add a domain, publish its DNS) -> 3 (mailboxes) -> 5 (check) -> 4 (webmail)." ""
        mail_status_row; mailweb_status_row; echo ""
        echo " 1) Install the mail server (once per server)"
        echo " 2) Mail domains (add, DNS records, check DNS, remove)"
        echo " 3) Mailboxes and aliases (info@..., noreply@...)"
        echo " 4) Webmail (Roundcube: read and send in the browser; open / close on demand)"
        echo " 5) Deliverability check (ports, reverse DNS, blacklists, DNS of every domain)"
        echo " 6) Send a test email"
        echo " 7) Status and logs"
        echo " 8) Start / stop / restart the mail server"
        echo " 9) Include mailboxes in the nightly backup (on/off)"
        echo "10) Remove the mail server"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item mail_install ;;
            2) menu_mail_domains ;;
            3) if mail_installed; then menu_mail_boxes ""; else err "Install the mail server first."; pause; fi ;;
            4) if mail_installed; then menu_webmail; else err "Install the mail server first."; pause; fi ;;
            5) run_item mail_check ;;
            6) run_item mail_send_test ;;
            7) run_item mail_logs ;;
            8) run_item mail_start_stop ;;
            9) run_item mail_toggle_backup ;;
            10) run_item mail_remove ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# NOTIFICATIONS (main menu 10): alerts by email (your own mail server) and Telegram
# ============================================================================
# How it works:
#   * Things that happen on this server (a deployment, a backup, a stopped container, a full disk ...)
#     become small "event files" in a spool folder.
#   * A root cron job (hideploy notify-run, every minute) turns each event into a message and sends it to
#     every channel that is switched on. Failed deliveries are retried for up to an hour.
#   * Pipelines run as the unprivileged 'gitlab-runner' user, which must never see your secrets (Telegram token,
#     mailbox password). So a pipeline only DROPS an event file into the spool; the root job does the sending.
#   * The same job also watches the server (containers, disk, certificates, reboot) every 5 minutes. A problem is
#     announced once, repeated as a reminder after a day, and announced again when it is fixed.

NOTIFY_EVENTS=(
    "deploy_fail|Deployment failed|on"
    "deploy_ok|Deployment succeeded|on"
    "rollback|Rollback to an earlier version|on"
    "backup_fail|Backup failed|on"
    "backup_ok|Backup finished OK (every night)|off"
    "ssl_fail|SSL renewal failed|on"
    "ssl_expiring|A certificate expires soon|on"
    "container_down|A project or shared service stopped|on"
    "disk_high|Disk almost full|on"
    "reboot_needed|Server needs a reboot|off"
)

declare -A NF_ST=() NF_STT=() NF_BAD=()

nf_get()   { kv_get "$NOTIFY_CONF" "$1"; }
nf_val()   { local v; v="$(nf_get "$1")"; printf '%s' "${v:-$2}"; }
nf_set()   { mkdir -p "$NOTIFY_DIR"; chmod 700 "$NOTIFY_DIR"; kv_set "$NOTIFY_CONF" "$1" "$2"; }
nf_unset() {
    [ -f "$NOTIFY_CONF" ] || return 0
    local tmp; tmp="$(mktemp)"
    grep -v "^$1=" "$NOTIFY_CONF" > "$tmp" || true
    cat "$tmp" > "$NOTIFY_CONF"; rm -f "$tmp"
}

nf_event_known() { local e; for e in "${NOTIFY_EVENTS[@]}"; do [ "${e%%|*}" = "$1" ] && return 0; done; return 1; }
nf_event_label() { local e; for e in "${NOTIFY_EVENTS[@]}"; do if [ "${e%%|*}" = "$1" ]; then e="${e#*|}"; printf '%s' "${e%|*}"; return 0; fi; done; }
nf_event_default() { local e; for e in "${NOTIFY_EVENTS[@]}"; do [ "${e%%|*}" = "$1" ] && { printf '%s' "${e##*|}"; return 0; }; done; printf 'off'; }
nf_event_on() { [ "$(nf_val "EV_$1" "$(nf_event_default "$1")")" = "on" ]; }

nf_master_on() { [ "$(nf_val ENABLED no)" = "yes" ]; }
nf_email_on()  { [ "$(nf_val EMAIL_ENABLED no)" = "yes" ] && [ -n "$(nf_get EMAIL_FROM)" ] && [ -n "$(nf_get EMAIL_PASS)" ] && [ -n "$(nf_get EMAIL_TO)" ]; }
nf_tg_on()     { [ "$(nf_val TG_ENABLED no)" = "yes" ] && [ -n "$(nf_get TG_TOKEN)" ] && [ -n "$(nf_get TG_CHATS)" ]; }
nf_has_channel() { nf_email_on || nf_tg_on; }
nf_configured()  { [ -f "$NOTIFY_CONF" ] && { [ -n "$(nf_get EMAIL_FROM)" ] || [ -n "$(nf_get TG_TOKEN)" ]; }; }

nf_status_row() {
    local ch="" ts ok_ts msg
    if ! nf_configured; then status_row "Notifications" dim "NOT SET UP" "optional: main menu 10) Notifications"; return 0; fi
    nf_email_on && ch+="email "; nf_tg_on && ch+="Telegram "
    ch="${ch% }"
    if ! nf_master_on; then status_row "Notifications" warn "PAUSED" "channels: ${ch:-none}. Turn on: main menu 10"; return 0; fi
    if [ -z "$ch" ]; then status_row "Notifications" warn "NO CHANNEL" "switch a channel on: main menu 10"; return 0; fi
    ts="$(cut -d'|' -f1 "$NOTIFY_DIR/last_error" 2>/dev/null)"; ok_ts="$(cat "$NOTIFY_DIR/last_ok" 2>/dev/null)"
    if [[ "$ts" =~ ^[0-9]+$ ]] && [ "$ts" -gt "${ok_ts:-0}" ] && [ $(( $(date +%s) - ts )) -lt 86400 ]; then
        msg="$(cut -d'|' -f2- "$NOTIFY_DIR/last_error" 2>/dev/null)"
        status_row "Notifications" warn "DELIVERY ISSUE" "${msg:0:70}"
    else
        status_row "Notifications" good "ON" "$ch"
    fi
}

# ---------- sending ----------------------------------------------------------------------

nf_log()      { printf '[%s] %s\n' "$(date -Is)" "$*"; }
nf_note_ok()  { date +%s > "$NOTIFY_DIR/last_ok" 2>/dev/null; }
nf_note_err() { printf '%s|%s\n' "$(date +%s)" "$1" > "$NOTIFY_DIR/last_error" 2>/dev/null; }

# Telegram: the token is part of the URL, so it is given to curl through a config read from stdin and never shows up in "ps"
# nf_tg_call METHOD [curl config lines ...] -> the raw answer of the Telegram API
nf_tg_call() {
    local method="$1" token proxy; shift
    token="$(nf_get TG_TOKEN)"; proxy="$(nf_get TG_PROXY)"
    {
        printf 'url = "%s/bot%s/%s"\n' "$TG_API_BASE" "$token" "$method"
        [ -n "$proxy" ] && printf 'proxy = "%s"\n' "$proxy"
        [ "$#" -gt 0 ] && printf '%s\n' "$@"
    } | curl -sS --max-time 25 -K - 2>&1
}

# nf_tg_send CHAT TEXTFILE
nf_tg_send() {
    local out
    out="$(nf_tg_call sendMessage "data-urlencode = \"chat_id=$1\"" "data-urlencode = \"text@$2\"" 'data-urlencode = "disable_web_page_preview=true"')"
    if grep -q '"ok":true' <<<"$out"; then return 0; fi
    NF_ERR="$(sed -n 's/.*"description":"\([^"]*\)".*/\1/p' <<<"$out" | head -n1)"
    [ -n "$NF_ERR" ] || NF_ERR="$(printf '%s' "$out" | head -c 150)"
    [ -n "$NF_ERR" ] || NF_ERR="no answer from Telegram"
    return 1
}

# The places a message goes to: "email" and one "tg:<chat>" per Telegram chat
nf_targets() {
    local chat; local -a chats=()
    nf_email_on && echo "email"
    if nf_tg_on; then
        IFS=',' read -ra chats <<< "$(nf_get TG_CHATS)"
        for chat in "${chats[@]}"; do chat="${chat// /}"; [ -n "$chat" ] && echo "tg:$chat"; done
    fi
    return 0
}

# nf_send_target TARGET — sends NF_SUBJECT / NF_TEXT; on failure sets NF_ERR
nf_send_target() {
    local out rc tf
    NF_ERR=""
    case "$1" in
        email)
            mail_up || { NF_ERR="the mail server is not running"; return 1; }
            out="$(mail_smtp_py send "$(nf_get EMAIL_FROM)" "$(nf_get EMAIL_PASS)" "$(nf_get EMAIL_TO)" "$NF_SUBJECT" "$NF_TEXT" auto 2>&1)"; rc=$?
            [ "$rc" -eq 0 ] && return 0
            [ "$rc" -eq 2 ] && out="python3 is not installed (apt install python3)"
            NF_ERR="${out:-sending failed}"; return 1 ;;
        tg:*)
            tf="$(mktemp)"
            printf '%s\n' "$NF_TEXT" | head -c 3800 | iconv -c -f UTF-8 -t UTF-8 > "$tf" 2>/dev/null
            nf_tg_send "${1#tg:}" "$tf"; rc=$?
            rm -f "$tf"; return "$rc" ;;
        *) NF_ERR="unknown channel"; return 1 ;;
    esac
}

# ---------- events: files, reading, messages --------------------------------------------

# nf_emit EVENT [KEY=VALUE ...] — drops an event file for the sender (does nothing while notifications are off)
nf_emit() {
    local ev="$1" f kv; shift
    [ -d "$NOTIFY_SPOOL" ] || return 0
    nf_master_on || return 0
    f="$NOTIFY_SPOOL/$(date +%s%N)-$$-$RANDOM.evt"
    {
        printf 'EVENT=%s\n' "$ev"
        for kv in "$@"; do printf '%s\n' "$(printf '%s' "$kv" | tr -d '\r\n')"; done
    } > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
}

# Send what is waiting, without blocking the menu
nf_kick() { nf_master_on || return 0; ( nf_run >> "$NOTIFY_LOG" 2>&1 & ) >/dev/null 2>&1; }

# nf_read_event FILE — event files may come from the pipeline user, so they are never "sourced":
# only known keys are read, control characters are removed, lengths are limited.
nf_read_event() {
    local f="$1" k v
    [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -c %s "$f" 2>/dev/null || echo 99999)" -le 4096 ] || return 1
    NF_EVENT=""; NF_MODE=""; NF_DOMAIN=""; NF_COMMIT=""; NF_MESSAGE=""; NF_AUTHOR=""; NF_BRANCH=""
    NF_SECONDS=""; NF_DETAIL=""; NF_KIND=""; NF_PIPELINE_URL=""; NF_JOB_URL=""
    while IFS='=' read -r k v || [ -n "$k" ]; do
        v="$(printf '%s' "$v" | tr -d '\000-\010\013-\037\177' | cut -c1-300 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)"
        case "$k" in
            EVENT) NF_EVENT="$v" ;;     MODE) NF_MODE="$v" ;;       DOMAIN) NF_DOMAIN="$v" ;;
            COMMIT) NF_COMMIT="$v" ;;   MESSAGE) NF_MESSAGE="$v" ;; AUTHOR) NF_AUTHOR="$v" ;;
            BRANCH) NF_BRANCH="$v" ;;   SECONDS) NF_SECONDS="$v" ;; DETAIL) NF_DETAIL="$v" ;;
            KIND) NF_KIND="$v" ;;
            PIPELINE_URL) [[ "$v" =~ ^https?://[^[:space:]]+$ ]] && NF_PIPELINE_URL="$v" ;;
            JOB_URL)      [[ "$v" =~ ^https?://[^[:space:]]+$ ]] && NF_JOB_URL="$v" ;;
        esac
    done < <(head -n 40 "$f")
    nf_event_known "$NF_EVENT" || [ "$NF_EVENT" = "test" ] || return 1
    [[ "$NF_SECONDS" =~ ^[0-9]{1,6}$ ]] || NF_SECONDS=""
    [[ "$NF_COMMIT" =~ ^[0-9a-zA-Z]{0,40}$ ]] || NF_COMMIT=""
    [[ "$NF_KIND" =~ ^(problem|reminder|resolved)$ ]] || NF_KIND=""
    if [ -n "$NF_DOMAIN" ] && ! valid_domain "$NF_DOMAIN"; then NF_DOMAIN="(invalid name)"; fi
    return 0
}

nf_dur() {
    local s="$1"; [[ "$s" =~ ^[0-9]+$ ]] || return 0
    if [ "$s" -ge 60 ]; then printf '%dm %ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

nf_lines_deploy() {
    [ -n "$NF_DOMAIN" ]  && NF_LINES+=("Project: $NF_DOMAIN")
    [ -n "$NF_COMMIT" ]  && NF_LINES+=("Commit: $NF_COMMIT${NF_MESSAGE:+  $NF_MESSAGE}")
    [ -n "$NF_AUTHOR" ]  && NF_LINES+=("By: $NF_AUTHOR")
    [ -n "$NF_BRANCH" ]  && NF_LINES+=("Branch: $NF_BRANCH")
    [ -n "$NF_SECONDS" ] && NF_LINES+=("Took: $(nf_dur "$NF_SECONDS")")
    if [ "$NF_MODE" = "manual" ]; then NF_LINES+=("Started from: the HiDeploy menu"); else NF_LINES+=("Started from: a GitLab pipeline"); fi
    [ -n "$NF_PIPELINE_URL" ] && NF_LINES+=("Pipeline: $NF_PIPELINE_URL")
    [ -n "$NF_JOB_URL" ]      && NF_LINES+=("Job log: $NF_JOB_URL")
    return 0
}

# nf_compose — builds NF_SUBJECT and NF_TEXT from the NF_* fields of the event
nf_compose() {
    local host when ico tag title pre="" line res="no"
    host="$(nf_val SERVER_NAME "$(hostname -s)")"; when="$(date '+%F %H:%M %Z')"
    NF_LINES=()
    case "$NF_KIND" in reminder) pre="Reminder: " ;; resolved) res="yes" ;; esac
    case "$NF_EVENT" in
        deploy_ok)    ico="✅"; tag="OK";     title="Deployment succeeded"; nf_lines_deploy ;;
        deploy_fail)  ico="❌"; tag="FAILED"; title="Deployment FAILED"; nf_lines_deploy
                      NF_LINES+=("The previous version may still be running. Fix the problem and push again, or roll back:")
                      NF_LINES+=("sudo hideploy -> 5) Manage Projects -> this project -> Deployments") ;;
        rollback)     ico="↩️"; tag="ROLLBACK"; title="Rolled back to an earlier version"; nf_lines_deploy
                      NF_LINES+=("The rollback is temporary: your next push deploys the newest code again.") ;;
        backup_ok)    ico="💾"; tag="OK";     title="Backup finished"
                      [ -n "$NF_DETAIL" ] && NF_LINES+=("$NF_DETAIL") ;;
        backup_fail)  ico="❌"; tag="FAILED"; title="Backup FAILED"
                      [ -n "$NF_DETAIL" ] && NF_LINES+=("$NF_DETAIL"); NF_LINES+=("Log: $BK_LOG") ;;
        ssl_fail)     ico="🔒"; tag="FAILED"; title="SSL renewal failed"
                      [ -n "$NF_DETAIL" ] && NF_LINES+=("$NF_DETAIL")
                      NF_LINES+=("Check: sudo hideploy -> 5) Manage Projects -> SSL management") ;;
        ssl_expiring) ico="🔒"; tag="WARNING"; title="Certificate expires soon"
                      [ "$res" = yes ] && { ico="🟢"; tag="RESOLVED"; title="Certificate renewed"; }
                      [ -n "$NF_DETAIL" ] && NF_LINES+=("$NF_DETAIL")
                      [ "$res" = yes ] || NF_LINES+=("Renew now: sudo hideploy -> 5) Manage Projects -> SSL management") ;;
        container_down) ico="🔴"; tag="PROBLEM"; title="A service stopped"
                      [ "$res" = yes ] && { ico="🟢"; tag="RESOLVED"; title="Running again"; }
                      [ -n "$NF_DETAIL" ] && NF_LINES+=("$NF_DETAIL")
                      [ "$res" = yes ] || NF_LINES+=("Look: sudo hideploy -> 5) Manage Projects, or: docker ps -a") ;;
        disk_high)    ico="💽"; tag="WARNING"; title="Disk almost full"
                      [ "$res" = yes ] && { ico="🟢"; tag="RESOLVED"; title="Disk space is fine again"; }
                      [ -n "$NF_DETAIL" ] && NF_LINES+=("$NF_DETAIL")
                      [ "$res" = yes ] || NF_LINES+=("Free space: sudo hideploy -> 5) Manage Projects -> Disk usage and cleanup") ;;
        reboot_needed) ico="🔄"; tag="INFO"; title="Server needs a reboot"
                      [ "$res" = yes ] && { ico="🟢"; tag="RESOLVED"; title="Reboot done"; }
                      [ -n "$NF_DETAIL" ] && NF_LINES+=("$NF_DETAIL")
                      [ "$res" = yes ] || NF_LINES+=("When convenient: sudo reboot (containers start again by themselves)") ;;
        test)         ico="🔔"; tag="TEST"; title="Test notification"
                      NF_LINES+=("If you can read this, this channel works.") ;;
        *)            ico="ℹ️"; tag="INFO"; title="$NF_EVENT" ;;
    esac
    title="${pre}${title}"
    NF_SUBJECT="$(printf '[%s] %s: %s%s' "$host" "$tag" "$title" "${NF_DOMAIN:+ - $NF_DOMAIN}" | tr -d '\000-\037\177' | cut -c1-150)"
    NF_TEXT="$ico $title"
    for line in "${NF_LINES[@]}"; do NF_TEXT+=$'\n'"$line"; done
    NF_TEXT+=$'\n\n'"Server: $host"$'\n'"Time: $when"
}

# ---------- the sender job ---------------------------------------------------------------

# Looks at the spool, sends every waiting event to every target that has not received it yet
nf_process_spool() {
    [ -d "$NOTIFY_SPOOL" ] || return 0
    local f t n=0 done_all age muted
    local -a targets=()
    muted=",$(nf_val MUTED ''),"
    find "$NOTIFY_SPOOL" -maxdepth 1 -name '*.tmp' -mmin +60 -delete 2>/dev/null
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n + 1)); [ "$n" -le 20 ] || break                   # at most 20 messages per minute; the rest waits
        if ! nf_read_event "$f"; then rm -f "$f" "$f.sent"; nf_log "dropped an invalid event file"; continue; fi
        if [ "$NF_EVENT" != "test" ] && ! nf_event_on "$NF_EVENT"; then rm -f "$f" "$f.sent"; continue; fi
        if [ -n "$NF_DOMAIN" ] && [[ "$muted" == *",$NF_DOMAIN,"* ]]; then rm -f "$f" "$f.sent"; continue; fi
        mapfile -t targets < <(nf_targets)
        if [ "${#targets[@]}" -eq 0 ]; then rm -f "$f" "$f.sent"; continue; fi
        nf_compose
        done_all=1
        for t in "${targets[@]}"; do
            if grep -qxF -- "$t" "$f.sent" 2>/dev/null; then continue; fi
            if nf_send_target "$t"; then
                echo "$t" >> "$f.sent"; nf_note_ok; nf_log "sent $NF_EVENT -> $t"
            else
                done_all=0; nf_note_err "$t: $NF_ERR"; nf_log "FAILED $NF_EVENT -> $t: $NF_ERR"
            fi
        done
        if [ "$done_all" -eq 1 ]; then
            rm -f "$f" "$f.sent"
        else
            age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
            if [ "$age" -gt 3600 ]; then rm -f "$f" "$f.sent"; nf_log "gave up on $NF_EVENT after one hour"; fi
        fi
    done < <(find "$NOTIFY_SPOOL" -maxdepth 1 -name '*.evt' -type f 2>/dev/null | sort)
    return 0
}

# ---------- watching the server ----------------------------------------------------------

nf_state_load() {
    local k s t
    NF_ST=(); NF_STT=()
    [ -f "$NOTIFY_STATE" ] || return 0
    while IFS='|' read -r k s t; do
        [ -n "$k" ] || continue
        NF_ST[$k]="$s"; NF_STT[$k]="${t:-0}"
    done < "$NOTIFY_STATE"
}
nf_state_save() {
    local k tmp="$NOTIFY_STATE.tmp"
    : > "$tmp"
    for k in "${!NF_ST[@]}"; do printf '%s|%s|%s\n' "$k" "${NF_ST[$k]}" "${NF_STT[$k]:-0}" >> "$tmp"; done
    mv "$tmp" "$NOTIFY_STATE"; chmod 600 "$NOTIFY_STATE"
}

# nf_apply CATEGORY EVENT STRIKES REMIND_SECONDS RESOLVE(yes|no)
# Compares the problems found just now (global NF_BAD[name]=description) with the remembered state:
#   new problem -> announce (after STRIKES consecutive checks)   still there for a day -> remind   gone -> "resolved"
nf_apply() {
    local cat="$1" ev="$2" strikes="$3" remind="$4" resolve="$5" now k name prev t
    local new="" rem="" res=""
    now="$(date +%s)"
    for name in "${!NF_BAD[@]}"; do
        k="$cat:$name"; prev="${NF_ST[$k]:-ok}"; t="${NF_STT[$k]:-0}"
        case "$prev" in
            ok)      if [ "$strikes" -gt 1 ]; then NF_ST[$k]="pending"; NF_STT[$k]="$now"
                     else NF_ST[$k]="bad"; NF_STT[$k]="$now"; new+="${new:+, }${NF_BAD[$name]}"; fi ;;
            pending) NF_ST[$k]="bad"; NF_STT[$k]="$now"; new+="${new:+, }${NF_BAD[$name]}" ;;
            bad)     if [ $((now - t)) -ge "$remind" ]; then NF_STT[$k]="$now"; rem+="${rem:+, }${NF_BAD[$name]}"; fi ;;
        esac
    done
    if [ "$resolve" = "yes" ]; then
        for k in "${!NF_ST[@]}"; do
            [[ "$k" == "$cat:"* ]] || continue
            name="${k#"$cat:"}"
            [ -n "${NF_BAD[$name]+x}" ] && continue
            [ "${NF_ST[$k]}" = "bad" ] && res+="${res:+, }$name"
            unset 'NF_ST[$k]' 'NF_STT[$k]'
        done
    fi
    [ -z "$new" ] || nf_emit "$ev" "KIND=problem" "DETAIL=$new"
    [ -z "$rem" ] || nf_emit "$ev" "KIND=reminder" "DETAIL=$rem"
    [ -z "$res" ] || nf_emit "$ev" "KIND=resolved" "DETAIL=$res"
    return 0
}

nf_check_containers() {
    nf_event_on container_down || return 0
    local c p cn dom h muted; local -a list=() projs=()
    NF_BAD=()
    muted=",$(nf_val MUTED ''),"
    if ! docker_ready; then
        if has_cmd docker; then NF_BAD[docker]="Docker engine is not running"; nf_apply container container_down 2 86400 no; fi
        return 0
    fi
    list=("$NGINX_CONTAINER" "$DB_CONTAINER")
    [ -f "$REDIS_DIR/docker-compose.yml" ] && list+=("$REDIS_CONTAINER")
    mail_installed && list+=("$MAIL_CONTAINER")
    [ -f "$PG_DIR/docker-compose.yml" ] && list+=("$PG_CONTAINER")
    for c in "${list[@]}"; do
        docker inspect "$c" >/dev/null 2>&1 || continue
        container_running "$c" || NF_BAD[$c]="$c (stopped)"
    done
    mapfile -t projs < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null | sort)
    for p in "${projs[@]}"; do
        [ -n "$p" ] || continue
        dom="$(basename "$p")"
        [[ "$muted" == *",$dom,"* ]] && continue
        cn="$(kv_get "$p/.deploy.env" CONTAINER_NAME)"; [ -n "$cn" ] || continue
        if ! docker inspect "$cn" >/dev/null 2>&1; then NF_BAD[$cn]="$dom (container missing)"
        elif ! container_running "$cn"; then NF_BAD[$cn]="$dom (stopped)"
        else
            h="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cn" 2>/dev/null)"
            [ "$h" = "unhealthy" ] && NF_BAD[$cn]="$dom (unhealthy)"
        fi
    done
    nf_apply container container_down 2 86400 yes
}

nf_check_disk() {
    nf_event_on disk_high || return 0
    local p lim; p="$(disk_pct)"; lim="$(nf_val DISK_PCT 90)"
    NF_BAD=()
    [[ "$p" =~ ^[0-9]+$ ]] || return 0
    if [ "$p" -ge "$lim" ]; then NF_BAD[root]="${p}% of the disk is used (limit ${lim}%)"; fi
    nf_apply disk disk_high 1 86400 yes
}

nf_check_certs() {
    nf_event_on ssl_expiring || return 0
    local d name days lim; lim="$(nf_val CERT_DAYS 14)"
    NF_BAD=()
    for d in "$NGINX_DIR"/letsencrypt/live/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"; days="$(cert_days "$name")"
        [[ "$days" =~ ^-?[0-9]+$ ]] || continue
        if [ "$days" -lt "$lim" ]; then NF_BAD[$name]="$name ($days days left)"; fi
    done
    nf_apply cert ssl_expiring 1 86400 yes
}

nf_check_reboot() {
    nf_event_on reboot_needed || return 0
    NF_BAD=()
    if sec_reboot_needed; then NF_BAD[reboot]="updates are waiting for a reboot"; fi
    nf_apply reboot reboot_needed 1 259200 yes
}

nf_checks_if_due() {
    local last now; now="$(date +%s)"
    last="$(cat "$NOTIFY_DIR/last_check" 2>/dev/null || echo 0)"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
    [ $((now - last)) -ge 280 ] || return 0
    echo "$now" > "$NOTIFY_DIR/last_check"
    nf_state_load
    nf_check_containers; nf_check_disk; nf_check_certs; nf_check_reboot
    nf_state_save
}

# What the cron job (and the background kick) runs. Only one copy at a time.
nf_run() {
    nf_master_on || return 0
    mkdir -p "$NOTIFY_DIR"; chmod 700 "$NOTIFY_DIR" 2>/dev/null
    ( flock -n 9 || exit 0; nf_checks_if_due; nf_process_spool ) 9>"$NOTIFY_LOCK"
}

# ---------- hooks used by other parts of HiDeploy -----------------------------------------

# nf_emit_deploy EVENT PATH SECONDS — a deployment started from the menu
nf_emit_deploy() {
    local ev="$1" path="$2" secs="$3" sha msg
    nf_master_on || return 0
    sha="$(as_runner git -C "$path" rev-parse --short HEAD 2>/dev/null || true)"
    msg="$(as_runner git -C "$path" log -1 --format=%s 2>/dev/null | tr -d '\r\n' | cut -c1-120)"
    nf_emit "$ev" "MODE=manual" "DOMAIN=$(basename "$path")" "COMMIT=$sha" "MESSAGE=$msg" "BRANCH=${BRANCH:-}" "SECONDS=$secs"
    nf_kick
}

# nf_emit_backup EXIT_CODE
nf_emit_backup() {
    local rc="$1" detail=""
    nf_master_on || return 0
    [ "$rc" -eq 75 ] && return 0                                 # another backup was already running: not a failure
    if [ "$rc" -eq 0 ]; then
        detail="$(kv_get "$BK_DIR/last_run.txt" SIZE) - SSH: $(kv_get "$BK_DIR/last_run.txt" SSH), S3: $(kv_get "$BK_DIR/last_run.txt" S3)"
        nf_emit backup_ok "DETAIL=$detail"
    else
        nf_emit backup_fail "DETAIL=The backup ended with problems (exit code $rc)."
    fi
    nf_kick
}

# ---------- switching on / off -----------------------------------------------------------

nf_spool_prepare() {
    mkdir -p "$NOTIFY_SPOOL"
    if getent group "$RUNNER_USER" >/dev/null 2>&1; then
        chown "root:$RUNNER_USER" "$NOTIFY_SPOOL"; chmod 1770 "$NOTIFY_SPOOL"
    else
        chown root:root "$NOTIFY_SPOOL"; chmod 0700 "$NOTIFY_SPOOL"
    fi
}

nf_write_cron() {
    local self; self="$(hideploy_self)"
    [ -x "$self" ] || { err "hideploy is not installed at $self. Install it first with install.sh."; return 1; }
    printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n* * * * * root %s notify-run >> %s 2>&1\n' \
        "$self" "$NOTIFY_LOG" > "$NOTIFY_CRON"
    chmod 644 "$NOTIFY_CRON"
    write_logrotate
}

nf_enable() {
    nf_has_channel || { err "Set up at least one channel first (email or Telegram)."; return 1; }
    has_cmd flock && has_cmd curl || { err "flock and curl are required."; return 1; }
    nf_spool_prepare
    nf_write_cron || return 1
    nf_set ENABLED yes
    if renew_enabled; then step_renew_enable >/dev/null 2>&1; fi          # refreshes the renewal job: it now reports failures
    ok "Notifications are ON. A background job runs every minute (log: $NOTIFY_LOG)."
    explain "Deployments started from a GitLab pipeline need the newer .gitlab-ci.yml: Notifications -> Pipeline notifications."
}

nf_disable() {
    nf_set ENABLED no
    rm -f "$NOTIFY_CRON"
    rm -rf "$NOTIFY_SPOOL"
    ok "Notifications are OFF: the background job and the spool folder were removed. Your settings are kept."
}

# ---------- setup: email -----------------------------------------------------------------

nf_valid_email_list() {   # "a@x.com, b@y.org" -> prints the cleaned, comma-separated list; fails when something is wrong
    local raw="${1// /}" a out=""; local -a arr=()
    [ -n "$raw" ] || return 1
    IFS=',' read -ra arr <<< "$raw"
    for a in "${arr[@]}"; do a="${a,,}"; valid_email "$a" || return 1; out+="${out:+,}$a"; done
    printf '%s' "$out"
}

nf_email_setup() {
    section "Email notifications (through your own mail server)"
    explain \
        "Messages are sent by a dedicated mailbox on YOUR mail server (notifications@<your domain>), so no outside service is involved." \
        "HiDeploy creates that mailbox with a generated password and keeps the password in a file only root can read." \
        "Tip: use Telegram too. If the mail server itself is down, an email alert about it cannot be delivered."
    mail_installed && mail_up || { err "The mail server must be installed and running first: main menu 9) Email."; return 1; }
    if ! has_cmd python3; then
        confirm "python3 is needed to send mail. Install it now?" y && sec_apt_install python3 >/dev/null 2>&1
        has_cmd python3 || { err "python3 is missing."; return 1; }
    fi
    local d from pass to list rc
    mail_pick_domain d || return 1
    from="notifications@$d"
    if mail_box_exists "$from"; then
        info "The mailbox $from already exists."
        ask_secret "Its password (Enter = set a NEW generated password)" pass
        if [ -z "$pass" ]; then
            pass="$(gen_password)"
            mail_account_write "$from" "$pass" || { err "Could not change the password."; return 1; }
        else
            mail_smtp_py login "$from" "$pass" >/dev/null 2>&1; rc=$?
            if [ "$rc" -eq 1 ]; then err "That password does not work for $from."; return 1; fi
        fi
    else
        pass="$(gen_password)"
        mail_account_write "$from" "$pass" || { err "Could not create the mailbox."; return 1; }
    fi
    mail_wait_login "$from" "$pass" || { err "The mailbox does not accept the login yet. Wait a minute and run this again."; return 1; }
    ok "Sender mailbox ready: $from"
    while true; do
        ask "Send alerts to (one or more addresses, comma-separated)" "$(nf_get EMAIL_TO)" to
        if list="$(nf_valid_email_list "$to")"; then break; fi
        err "Enter valid email addresses, separated by commas."
    done
    nf_set EMAIL_FROM "$from"; nf_set EMAIL_PASS "$pass"; nf_set EMAIL_TO "$list"; nf_set EMAIL_ENABLED yes
    ok "Email channel saved."
    explain "" "Messages come from $from. If the first ones land in spam, mark them 'not spam' and add the address to your contacts." \
               "Check that this domain passes SPF/DKIM: Email -> Mail domains -> Check DNS."
    nf_after_setup
}

# ---------- setup: Telegram --------------------------------------------------------------

nf_tg_detect_chats() {   # prints "id name" lines for the chats that wrote to the bot recently
    nf_tg_call getUpdates | grep -oE '"chat":\{"id":-?[0-9]+,"(first_name|title)":"[^"]*"' \
        | sed -E 's/^"chat":\{"id":(-?[0-9]+),"(first_name|title)":"([^"]*)"$/\1 \3/' | sort -u
}

# nf_tg_restore OLD_TOKEN OLD_PROXY — a failed (re-)setup must never destroy a token that was working
nf_tg_restore() {
    if [ -n "$1" ]; then nf_set TG_TOKEN "$1"; else nf_unset TG_TOKEN; fi
    if [ -n "$2" ]; then nf_set TG_PROXY "$2"; else nf_unset TG_PROXY; fi
}

nf_tg_setup() {
    section "Telegram notifications"
    explain \
        "You need a Telegram bot of your own (free, one minute):" \
        "  1. In Telegram open @BotFather and send:  /newbot   then choose a name and a username." \
        "  2. BotFather answers with a TOKEN (looks like 123456789:ABC...). Paste it below." \
        "  3. Open your new bot and send it any message (for a group: add the bot to the group and write there)." \
        "  4. HiDeploy then finds the chat by itself."
    local token proxy out bot line n i choice manual picked="" id name prev_token prev_proxy
    local -a found=()
    prev_token="$(nf_get TG_TOKEN)"; prev_proxy="$(nf_get TG_PROXY)"
    while true; do
        ask_secret "Bot token" token
        [ -n "$token" ] || { info "Cancelled."; return 0; }
        [[ "$token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$ ]] && break
        err "That does not look like a bot token (123456789:AAE...)."
    done
    nf_set TG_TOKEN "$token"
    out="$(nf_tg_call getMe)"
    if ! grep -q '"ok":true' <<<"$out"; then
        warn "Telegram did not answer correctly: $(printf '%s' "$out" | head -c 120)"
        explain "If Telegram is blocked from this server, use a proxy (for example socks5h://127.0.0.1:1080 or http://host:port)."
        ask "Proxy (Enter = none)" "" proxy
        if [ -n "$proxy" ]; then
            [[ "$proxy" =~ ^(https?|socks5h?)://[A-Za-z0-9._:@-]+$ ]] || { err "Invalid proxy address."; nf_tg_restore "$prev_token" "$prev_proxy"; return 1; }
            nf_set TG_PROXY "$proxy"; out="$(nf_tg_call getMe)"
        fi
    fi
    if ! grep -q '"ok":true' <<<"$out"; then
        err "The token was not accepted (or Telegram cannot be reached from this server)."
        nf_tg_restore "$prev_token" "$prev_proxy"
        [ -z "$prev_token" ] || info "Your previous bot settings were kept."
        return 1
    fi
    bot="$(sed -n 's/.*"username":"\([^"]*\)".*/\1/p' <<<"$out" | head -n1)"
    ok "Bot accepted: @${bot:-?}"
    while true; do
        read -r -p "${C_YELLOW}Now send a message to @${bot:-your bot} in Telegram, then press [Enter] (or type m to enter a chat ID yourself): ${C_RESET}" manual
        found=()
        if [[ "${manual,,}" != "m" ]]; then mapfile -t found < <(nf_tg_detect_chats); fi
        if [ "${#found[@]}" -gt 0 ]; then
            echo ""; i=1
            for line in "${found[@]}"; do printf '   %2d) %s\n' "$i" "${line#* }  (chat id ${line%% *})"; i=$((i + 1)); done
            echo "    0) Enter a chat ID by hand"
            read -r -p "${C_YELLOW}Send alerts to which chat (several: 1,2): ${C_RESET}" choice
            if [ "$choice" != "0" ]; then
                for n in ${choice//,/ }; do
                    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#found[@]}" ] || continue
                    id="${found[$((n-1))]%% *}"; picked+="${picked:+,}$id"
                done
                [ -n "$picked" ] && break
                err "Nothing selected."; continue
            fi
        elif [[ "${manual,,}" != "m" ]]; then
            warn "No message found yet. Telegram only shows messages from the last 24 hours, and the bot must have been written to."
            confirm "Try again?" y && continue
        fi
        ask "Chat ID (a number such as 123456789 or -1001234567890, or @channelname)" "" id
        if [[ "$id" =~ ^-?[0-9]{5,20}$ || "$id" =~ ^@[A-Za-z][A-Za-z0-9_]{4,31}$ ]]; then picked="$id"; break; fi
        err "Invalid chat ID."
    done
    nf_set TG_CHATS "$picked"; nf_set TG_ENABLED yes
    ok "Telegram channel saved."
    nf_after_setup
}

nf_tg_chat_add() {
    nf_configured && [ -n "$(nf_get TG_TOKEN)" ] || { err "Set up Telegram first."; return 1; }
    local id cur; cur="$(nf_get TG_CHATS)"
    explain "Another person or group can receive the alerts: they (or the group) must write to the bot first." "Detected chats are listed below."
    nf_tg_detect_chats | sed 's/^/   /'
    ask "Chat ID to add" "" id
    [[ "$id" =~ ^-?[0-9]{5,20}$ || "$id" =~ ^@[A-Za-z][A-Za-z0-9_]{4,31}$ ]] || { err "Invalid chat ID."; return 1; }
    [[ ",$cur," == *",$id,"* ]] && { info "Already in the list."; return 0; }
    nf_set TG_CHATS "${cur:+$cur,}$id"; ok "Added."
}

nf_tg_chat_remove() {
    local cur id out="" c; local -a arr=()
    cur="$(nf_get TG_CHATS)"; [ -n "$cur" ] || { info "No chats configured."; return 0; }
    echo "  Chats: $cur"
    ask "Chat ID to remove" "" id
    IFS=',' read -ra arr <<< "$cur"
    for c in "${arr[@]}"; do [ "$c" = "$id" ] || out+="${out:+,}$c"; done
    if [ -n "$out" ]; then nf_set TG_CHATS "$out"; else nf_unset TG_CHATS; nf_set TG_ENABLED no; warn "No chat left: Telegram is switched off."; fi
    ok "Removed."
}

nf_after_setup() {
    if ! nf_master_on; then
        confirm "Turn notifications ON now?" y && nf_enable
    else
        step_renew_enable >/dev/null 2>&1 || true
    fi
    confirm "Send a test notification now?" y && nf_test
}

# ---------- test, events, settings -------------------------------------------------------

nf_test() {
    section "Test notification"
    local -a targets=(); local t any=0
    mapfile -t targets < <(nf_targets)
    if [ "${#targets[@]}" -eq 0 ]; then err "No channel is switched on."; return 1; fi
    NF_EVENT="test"; NF_KIND=""; NF_DOMAIN=""; NF_DETAIL=""
    nf_compose
    for t in "${targets[@]}"; do
        printf '  %-34s ' "$t"
        if nf_send_target "$t"; then printf '%sdelivered%s\n' "$C_GREEN" "$C_RESET"; nf_note_ok; any=1
        else printf '%sFAILED%s  %s\n' "$C_RED" "$C_RESET" "$NF_ERR"; nf_note_err "$t: $NF_ERR"; fi
    done
    [ "$any" -eq 1 ] || return 1
}

nf_events_menu() {
    local c i e key
    while true; do
        clear; banner "Which events notify you" "$C_MAGENTA"
        i=1
        for e in "${NOTIFY_EVENTS[@]}"; do
            key="${e%%|*}"
            printf ' %2d) [%s] %s\n' "$i" "$(nf_event_on "$key" && echo "${C_GREEN}ON ${C_RESET}" || echo "${C_DIM}off${C_RESET}")" "$(nf_event_label "$key")"
            i=$((i + 1))
        done
        echo ""
        echo "  Type a number to switch it on/off.   A) all on   N) all off   0) back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            0) return ;;
            [Aa]) for e in "${NOTIFY_EVENTS[@]}"; do nf_set "EV_${e%%|*}" on; done ;;
            [Nn]) for e in "${NOTIFY_EVENTS[@]}"; do nf_set "EV_${e%%|*}" off; done ;;
            *) if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#NOTIFY_EVENTS[@]}" ]; then
                   key="${NOTIFY_EVENTS[$((c-1))]%%|*}"
                   if nf_event_on "$key"; then nf_set "EV_$key" off; else nf_set "EV_$key" on; fi
               else err "Invalid option."; sleep 1; fi ;;
        esac
    done
}

nf_muted_menu() {
    local p dom cur c i muted list="" d
    local -a projs=()
    mapfile -t projs < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null | sort)
    [ "${#projs[@]}" -gt 0 ] || { info "No projects yet."; return 0; }
    while true; do
        cur=",$(nf_val MUTED ''),"; i=1
        echo ""
        for p in "${projs[@]}"; do
            dom="$(basename "$p")"
            printf '  %2d) %-36s %s\n' "$i" "$dom" "$([[ "$cur" == *",$dom,"* ]] && echo "${C_YELLOW}MUTED${C_RESET}" || echo "notifies")"
            i=$((i + 1))
        done
        explain "" "A muted project sends no deployment or 'stopped' alerts (useful for test sites). Server-wide alerts still arrive."
        read -r -p "${C_YELLOW}Number to mute / unmute (0 = back): ${C_RESET}" c
        [[ "$c" =~ ^[0-9]+$ ]] || continue
        [ "$c" = "0" ] && return 0
        [ "$c" -le "${#projs[@]}" ] || continue
        dom="$(basename "${projs[$((c-1))]}")"
        list=""
        for d in $(nf_val MUTED '' | tr ',' ' '); do [ "$d" = "$dom" ] || list+="${list:+,}$d"; done
        if [[ "$cur" != *",$dom,"* ]]; then list+="${list:+,}$dom"; fi
        if [ -n "$list" ]; then nf_set MUTED "$list"; else nf_unset MUTED; fi
    done
}

nf_settings_menu() {
    local c v
    while true; do
        clear; banner "Notification settings" "$C_MAGENTA"
        printf '  Server name in messages:  %s\n' "$(nf_val SERVER_NAME "$(hostname -s) (default)")"
        printf '  Disk alert from:          %s%% used\n' "$(nf_val DISK_PCT 90)"
        printf '  Certificate alert when:   fewer than %s days left\n' "$(nf_val CERT_DAYS 14)"
        printf '  Muted projects:           %s\n\n' "$(nf_val MUTED none)"
        echo " 1) Change the server name"
        echo " 2) Change the disk threshold"
        echo " 3) Change the certificate threshold"
        echo " 4) Mute / unmute projects"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) ask "Server name (letters, digits, space . _ -)" "$(nf_val SERVER_NAME "$(hostname -s)")" v
               if [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]{0,39}$ ]]; then nf_set SERVER_NAME "$v"; ok "Saved."; else err "Invalid name."; fi; pause ;;
            2) ask "Alert when the disk is this many percent full (50-99)" "$(nf_val DISK_PCT 90)" v
               if [[ "$v" =~ ^[0-9]{2}$ ]] && [ "$v" -ge 50 ] && [ "$v" -le 99 ]; then nf_set DISK_PCT "$v"; ok "Saved."; else err "Enter a number from 50 to 99."; fi; pause ;;
            3) ask "Alert when a certificate has fewer than this many days left (3-60)" "$(nf_val CERT_DAYS 14)" v
               if [[ "$v" =~ ^[0-9]{1,2}$ ]] && [ "$v" -ge 3 ] && [ "$v" -le 60 ]; then nf_set CERT_DAYS "$v"; ok "Saved."; else err "Enter a number from 3 to 60."; fi; pause ;;
            4) nf_muted_menu ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ---------- pipelines --------------------------------------------------------------------

nf_ci_status() {
    section "Pipeline notifications (deployments started by GitLab)"
    explain \
        "A pipeline runs as the 'gitlab-runner' user, which must not see your Telegram token or mailbox password." \
        "So the new .gitlab-ci.yml only drops a small event file in $NOTIFY_SPOOL; the server sends it within a minute." \
        "Projects whose .gitlab-ci.yml is older do not send deployment alerts from pipelines (menu deployments always do)."
    local p dom state kind tag pm tmp n_old=0
    local -a olds=() projs=()
    mapfile -t projs < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null | sort)
    [ "${#projs[@]}" -gt 0 ] || { info "No projects yet."; return 0; }
    echo ""
    for p in "${projs[@]}"; do
        dom="$(basename "$p")"
        if   [ ! -f "$p/.gitlab-ci.yml" ];            then state="${C_RED}NO CI FILE${C_RESET}"
        elif grep -q 'notify_event' "$p/.gitlab-ci.yml"; then state="${C_GREEN}READY${C_RESET}"
        else state="${C_YELLOW}OLD CI FILE${C_RESET}"; olds+=("$p"); fi
        printf '  %-36s %s\n' "$dom" "$state"
    done
    n_old="${#olds[@]}"
    [ "$n_old" -gt 0 ] || { echo ""; ok "All projects are ready."; return 0; }
    echo ""
    confirm "Generate new .gitlab-ci.yml files for the $n_old project(s) marked OLD / NO CI FILE?" y || return 0
    tag="$(cfg_get RUNNER_TAG || true)"; tag="${tag:-production}"
    for p in "${olds[@]}"; do
        dom="$(basename "$p")"
        load_project "$p" || continue
        kind="${PROJECT_TYPE:-laravel}"; pm="pnpm"
        grep -q 'yarn install' "$p/Dockerfile" 2>/dev/null && pm="yarn"
        grep -q 'npm ci' "$p/Dockerfile" 2>/dev/null && pm="npm"
        tmp="$(mktemp -d)"
        generate_project_files "$tmp" "$dom" "${BRANCH:-main}" "$tag" yes "$kind" "$pm" >/dev/null
        mkdir -p "$TEMPLATES_DIR/$dom"
        cp "$tmp/.gitlab-ci.yml" "$TEMPLATES_DIR/$dom/.gitlab-ci.yml"; rm -rf "$tmp"
        ok "New .gitlab-ci.yml for $dom: $TEMPLATES_DIR/$dom/.gitlab-ci.yml"
    done
    next_steps \
        "For each project: copy the new file into the repository on your computer:   scp root@SERVER_IP:$TEMPLATES_DIR/<domain>/.gitlab-ci.yml ." \
        "Then:   git add .gitlab-ci.yml && git commit -m 'Deployment notifications' && git push" \
        "Only .gitlab-ci.yml is replaced; your Dockerfile and compose file are untouched."
}

nf_log_show() {
    section "Recent notification log"
    if [ -s "$NOTIFY_LOG" ]; then tail -n 25 "$NOTIFY_LOG" | cut -c1-200; else info "Nothing logged yet."; fi
    local n; n="$(find "$NOTIFY_SPOOL" -maxdepth 1 -name '*.evt' 2>/dev/null | wc -l)"
    echo ""; printf '  Events waiting to be sent: %s\n' "$n"
}

nf_status_show() {
    section "Notifications"
    printf '  Master switch:   %s\n' "$(nf_master_on && echo ON || echo "OFF (paused)")"
    printf '  Email:           %s\n' "$(nf_email_on && echo "ON  -> $(nf_get EMAIL_TO)  (from $(nf_get EMAIL_FROM))" || echo off)"
    printf '  Telegram:        %s\n' "$(nf_tg_on && echo "ON  -> chat(s) $(nf_get TG_CHATS)" || echo off)"
    [ -n "$(nf_get TG_PROXY)" ] && printf '  Telegram proxy:  %s\n' "$(nf_get TG_PROXY)"
    echo ""; echo "  Events:"
    local e key
    for e in "${NOTIFY_EVENTS[@]}"; do
        key="${e%%|*}"
        printf '    [%s] %s\n' "$(nf_event_on "$key" && echo "ON " || echo "off")" "$(nf_event_label "$key")"
    done
    echo ""
    printf '  Background job:  %s\n' "$([ -f "$NOTIFY_CRON" ] && echo "installed (every minute)" || echo "not installed")"
    if [ -s "$NOTIFY_DIR/last_error" ]; then printf '  Last problem:    %s\n' "$(cut -d'|' -f2- "$NOTIFY_DIR/last_error")"; fi
}

# ---------- menu 10 ----------------------------------------------------------------------

menu_notify() {
    local c
    while true; do
        clear; banner "10) Notifications (email and Telegram)" "$C_MAGENTA"
        explain \
            "Get a message when a deployment succeeds or fails, a backup fails, a service stops, the disk fills up or a certificate is about to expire." \
            "Recommended order: 2 and/or 3 (a channel) -> 6 (test) -> 8 (pipelines). Both channels together is the safest." ""
        nf_status_row; echo ""
        echo " 1) Show the current settings"
        echo " 2) Email channel (sent by your own mail server)"
        echo " 3) Telegram channel (bot, chats, proxy)"
        echo " 4) Choose which events notify you"
        echo " 5) Settings: server name, thresholds, muted projects"
        echo " 6) Send a test notification"
        echo " 7) Turn notifications ON / OFF"
        echo " 8) Pipeline notifications (check projects, new .gitlab-ci.yml)"
        echo " 9) Recent log and waiting events"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item nf_status_show ;;
            2) menu_notify_email ;;
            3) menu_notify_tg ;;
            4) nf_events_menu ;;
            5) nf_settings_menu ;;
            6) run_item nf_test ;;
            7) if nf_master_on; then confirm "Turn notifications OFF?" n && nf_disable; else nf_enable; fi; pause ;;
            8) run_item nf_ci_status ;;
            9) run_item nf_log_show ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

menu_notify_email() {
    local c to list
    while true; do
        clear; banner "Email notifications" "$C_MAGENTA"
        printf '  Email: %s\n\n' "$(nf_email_on && echo "ON -> $(nf_get EMAIL_TO) (from $(nf_get EMAIL_FROM))" || echo "off")"
        echo " 1) Set up / re-create the sender mailbox and recipients"
        echo " 2) Change the recipients"
        echo " 3) Switch the email channel off / on"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item nf_email_setup ;;
            2) if [ -n "$(nf_get EMAIL_FROM)" ]; then
                   while true; do ask "Send alerts to (comma-separated)" "$(nf_get EMAIL_TO)" to; if list="$(nf_valid_email_list "$to")"; then break; fi; err "Invalid address list."; done
                   nf_set EMAIL_TO "$list"; ok "Saved."
               else err "Set up the email channel first (option 1)."; fi
               pause ;;
            3) if [ -z "$(nf_get EMAIL_FROM)" ]; then err "Set up the email channel first (option 1)."
               elif [ "$(nf_val EMAIL_ENABLED no)" = "yes" ]; then nf_set EMAIL_ENABLED no; ok "Email channel is OFF."
               else nf_set EMAIL_ENABLED yes; ok "Email channel is ON."; fi
               pause ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

menu_notify_tg() {
    local c proxy
    while true; do
        clear; banner "Telegram notifications" "$C_MAGENTA"
        printf '  Telegram: %s\n\n' "$(nf_tg_on && echo "ON -> chat(s) $(nf_get TG_CHATS)" || echo "off")"
        echo " 1) Set up the bot and the first chat"
        echo " 2) Add another chat (person or group)"
        echo " 3) Remove a chat"
        echo " 4) Proxy (when Telegram is blocked from this server)"
        echo " 5) Switch the Telegram channel off / on"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item nf_tg_setup ;;
            2) nf_tg_chat_add; pause ;;
            3) nf_tg_chat_remove; pause ;;
            4) if [ -n "$(nf_get TG_TOKEN)" ]; then
                   ask "Proxy, e.g. socks5h://127.0.0.1:1080 or http://host:port (Enter = none)" "$(nf_get TG_PROXY)" proxy
                   if [ -z "$proxy" ]; then nf_unset TG_PROXY; ok "Proxy removed."
                   elif [[ "$proxy" =~ ^(https?|socks5h?)://[A-Za-z0-9._:@-]+$ ]]; then nf_set TG_PROXY "$proxy"; ok "Proxy saved."
                   else err "Invalid proxy address."; fi
               else err "Set up Telegram first (option 1)."; fi
               pause ;;
            5) if [ -z "$(nf_get TG_TOKEN)" ]; then err "Set up Telegram first (option 1)."
               elif [ "$(nf_val TG_ENABLED no)" = "yes" ]; then nf_set TG_ENABLED no; ok "Telegram channel is OFF."
               else nf_set TG_ENABLED yes; ok "Telegram channel is ON."; fi
               pause ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# POSTGRESQL (shared database server, optional next to MariaDB)
# ============================================================================

pg_installed() { [ -f "$PG_DIR/docker-compose.yml" ] || docker inspect "$PG_CONTAINER" >/dev/null 2>&1; }

pg_status_row() {
    pg_installed || return 0          # optional service: no noise while it does not exist
    container_row "PostgreSQL" "$PG_CONTAINER"
}

step_postgres_install() {
    section "Install shared PostgreSQL container"
    explain \
        "One PostgreSQL container stores the databases of every project that chooses PostgreSQL (saves RAM and disk)." \
        "It runs next to MariaDB: each project picks one of the two. It is NOT exposed to the internet;" \
        "only containers on '$NETWORK' can reach it."
    docker_ready && net_exists || { err "Docker/network not ready. Use main menu 1) first."; return 1; }
    if container_running "$PG_CONTAINER"; then ok "PostgreSQL container is already running."; return 0; fi
    local pass suggested i status
    if [ -f "$PG_DIR/docker-compose.yml" ]; then
        # never rewrite an existing installation: its compose file knows where the data lives
        info "PostgreSQL is installed but stopped: starting it with its existing settings and data."
        docker compose -f "$PG_DIR/docker-compose.yml" up -d >/dev/null 2>&1
        for i in $(seq 1 40); do
            status="$(docker inspect -f '{{.State.Health.Status}}' "$PG_CONTAINER" 2>/dev/null)"
            [ "$status" = "healthy" ] && break
            sleep 3
        done
        [ "$status" = "healthy" ] && { ok "PostgreSQL is healthy."; return 0; }
        err "PostgreSQL is not healthy. Check: docker logs $PG_CONTAINER"; return 1
    fi

    pick_postgres_image || { err "Cancelled."; return 1; }
    suggested="$(gen_password)"
    explain "Allowed superuser password characters: letters, digits and . _ @ % + = : , -   (min 12 characters)"
    while true; do
        ask "PostgreSQL superuser password (Enter = use generated one)" "$suggested" pass
        [[ "$pass" =~ ^[A-Za-z0-9._@%+=:,-]{12,}$ ]] && break
        err "Password not allowed. Use at least 12 characters from the allowed set."
    done

    mkdir -p "$PG_DIR"
    printf 'POSTGRES_PASSWORD=%s\n' "$pass" > "$PG_DIR/.env"
    chmod 600 "$PG_DIR/.env"
    # PostgreSQL 18+ keeps its data in a per-version folder under /var/lib/postgresql: the volume is mounted there
    # (mounting /var/lib/postgresql/data, the old way, makes version 18 fail; mounting the new way on 17 without PGDATA loses data).
    pg_write_compose "$POSTGRES_IMAGE" "postgres_data" || { err "Could not write the compose file (unknown version in '$POSTGRES_IMAGE')."; return 1; }
    info "Starting PostgreSQL (the first start downloads the image, about 1 minute)..."
    docker compose -f "$PG_DIR/docker-compose.yml" up -d || { err "PostgreSQL failed to start."; return 1; }
    info "Waiting for PostgreSQL to become healthy..."
    for i in $(seq 1 40); do
        status="$(docker inspect -f '{{.State.Health.Status}}' "$PG_CONTAINER" 2>/dev/null)"
        [ "$status" = "healthy" ] && break
        sleep 3
    done
    if [ "${status:-}" = "healthy" ]; then
        ok "PostgreSQL $(upd_running_version postgres) is healthy ($POSTGRES_IMAGE)."
        warn "Superuser password: $pass"
        explain "Saved (root-only) in: $PG_DIR/.env  — you normally never need it; this script uses the local socket of the container."
        next_steps \
            "Choose PostgreSQL when you deploy a project (main menu 4)." \
            "Or add it to an existing project: Manage Projects -> your project -> Add a database."
    else
        err "PostgreSQL is not healthy yet. Check: docker logs $PG_CONTAINER"
        return 1
    fi
}

# ============================================================================
# BROTLI (nginx image with the Brotli modules: smaller pages for modern browsers)
# ============================================================================
# The official nginx image has no Brotli. HiDeploy builds a small image of its own: the official nginx image plus the
# two ngx_brotli modules compiled from source against the SAME nginx version (google/ngx_brotli with the Brotli library
# it pins, normally the newest one). gzip stays active for browsers without Brotli. Everything is reversible.

brotli_on()   { [ "$(cfg_get NGINX_BROTLI || true)" = "yes" ]; }
brotli_level(){ local v; v="$(cfg_get BROTLI_LEVEL || true)"; printf '%s' "${v:-4}"; }

# The image the nginx container should run (used when nginx is (re)installed)
nginx_image_current() {
    local img=""
    if brotli_on; then img="$(cfg_get NGINX_BROTLI_IMAGE || true)"; fi
    printf '%s' "${img:-$NGINX_IMAGE}"
}

brotli_status_row() {
    if brotli_on; then status_row "Brotli" good "ON" "level $(brotli_level) - $(cfg_get NGINX_BROTLI_INFO || true)"
    elif container_running "$NGINX_CONTAINER"; then status_row "Brotli" dim "OFF" "optional: Shared Services -> Brotli (smaller pages)"
    fi
}

# brotli_write_conf [FILE] — the http-level settings
brotli_write_conf() {
    local f="${1:-$BROTLI_CONF}"
    cat > "$f" <<EOF
# Managed by HiDeploy (Shared Services -> Brotli). Change it through the menu, not by hand.
# Used for browsers that announce Brotli support (all modern ones, over HTTPS); gzip stays the fallback.
brotli on;
brotli_comp_level $(brotli_level);
brotli_min_length 1024;
brotli_types text/plain text/css text/xml text/javascript application/javascript application/json application/xml application/rss+xml application/atom+xml application/manifest+json application/wasm image/svg+xml image/x-icon font/ttf font/otf application/vnd.ms-fontobject;
EOF
}

# What the Next.js vhosts need: without this the app compresses with gzip itself and nginx never gets to use Brotli
brotli_ae_line() {
    if brotli_on; then printf 'proxy_set_header Accept-Encoding "";'; else printf '# (Brotli is off)'; fi
}

brotli_write_dockerfile() {
    mkdir -p "$NGINX_BROTLI_DIR"
    cat > "$NGINX_BROTLI_DIR/Dockerfile" <<'EOF'
# Generated by HiDeploy: the official nginx image plus the Brotli modules, compiled from source
# against the same nginx version as the base image.
ARG NGINX_IMAGE=nginx:stable-alpine
FROM ${NGINX_IMAGE} AS build
ARG NGX_BROTLI_REF=master
RUN apk add --no-cache build-base git cmake curl pcre2-dev zlib-dev openssl-dev linux-headers
WORKDIR /build
RUN set -eux; \
    NGX_VER="$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')"; \
    test -n "$NGX_VER"; \
    echo "$NGX_VER" > nginx.version; \
    curl -fsSL "https://nginx.org/download/nginx-${NGX_VER}.tar.gz" -o nginx.tar.gz; \
    tar xzf nginx.tar.gz; \
    git clone --recurse-submodules --depth 1 --branch "${NGX_BROTLI_REF}" https://github.com/google/ngx_brotli.git; \
    git -C ngx_brotli rev-parse --short HEAD > ngx_brotli.commit; \
    { git -C ngx_brotli/deps/brotli describe --tags --always 2>/dev/null || git -C ngx_brotli/deps/brotli rev-parse --short HEAD; } > brotli.version
# the Brotli encoder library, built as a static library with position-independent code
RUN set -eux; \
    cd /build/ngx_brotli/deps/brotli; mkdir -p out; cd out; \
    cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_C_FLAGS="-O3 -fPIC" -DCMAKE_INSTALL_PREFIX=./installed ..; \
    cmake --build . --config Release -j2 --target brotlienc
# the two nginx modules
RUN set -eux; \
    cd "/build/nginx-$(cat /build/nginx.version)"; \
    ./configure --with-compat --add-dynamic-module=/build/ngx_brotli; \
    make -j2 modules

FROM ${NGINX_IMAGE}
LABEL org.hideploy.brotli="1"
COPY --from=build /build/nginx-*/objs/ngx_http_brotli_filter_module.so /build/nginx-*/objs/ngx_http_brotli_static_module.so /usr/lib/nginx/modules/
COPY --from=build /build/nginx.version /build/ngx_brotli.commit /build/brotli.version /etc/nginx/hideploy-brotli/
RUN set -eux; \
    { printf '%s\n' 'load_module modules/ngx_http_brotli_filter_module.so;' 'load_module modules/ngx_http_brotli_static_module.so;'; cat /etc/nginx/nginx.conf; } > /tmp/nginx.conf; \
    mv /tmp/nginx.conf /etc/nginx/nginx.conf; \
    nginx -t
EOF
}

# brotli_build — builds the image; on success sets BROTLI_IMG (tag) and BROTLI_INFO (versions)
brotli_build() {
    local ref log pid rc ver ngx brv
    ref="$(cfg_get NGX_BROTLI_REF || true)"; ref="${ref:-$NGX_BROTLI_REF}"
    [[ "$ref" =~ ^[A-Za-z0-9._/-]{1,60}$ ]] || { err "Invalid NGX_BROTLI_REF in the settings."; return 1; }
    brotli_write_dockerfile
    log="$(mktemp)"
    info "Building nginx with Brotli (ngx_brotli '$ref'). This takes about 2-5 minutes; the sites keep running meanwhile."
    docker build --pull --build-arg "NGINX_IMAGE=$NGINX_IMAGE" --build-arg "NGX_BROTLI_REF=$ref" \
        -t "$NGINX_BROTLI_TAG:build" "$NGINX_BROTLI_DIR" > "$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do printf '.'; sleep 5; done; echo ""
    wait "$pid"; rc=$?
    if [ "$rc" -ne 0 ]; then
        err "The build failed. Last lines of the build log:"; tail -n 15 "$log" | sed 's/^/    /'
        explain "Saved in: $log   (a common cause: no internet access to github.com / nginx.org from this server)"
        return 1
    fi
    rm -f "$log"
    ver="$(docker run --rm --entrypoint cat "$NGINX_BROTLI_TAG:build" /etc/nginx/hideploy-brotli/nginx.version 2>/dev/null)"
    ngx="$(docker run --rm --entrypoint cat "$NGINX_BROTLI_TAG:build" /etc/nginx/hideploy-brotli/ngx_brotli.commit 2>/dev/null)"
    brv="$(docker run --rm --entrypoint cat "$NGINX_BROTLI_TAG:build" /etc/nginx/hideploy-brotli/brotli.version 2>/dev/null)"
    [[ "$ver" =~ ^[0-9][0-9.]*$ ]] || { err "The image was built but its version could not be read."; return 1; }
    BROTLI_IMG="$NGINX_BROTLI_TAG:$ver"
    docker tag "$NGINX_BROTLI_TAG:build" "$BROTLI_IMG" && docker rmi "$NGINX_BROTLI_TAG:build" >/dev/null 2>&1
    BROTLI_INFO="nginx $ver, ngx_brotli ${ngx:-?}, Brotli library ${brv:-?}"
    ok "Built $BROTLI_IMG ($BROTLI_INFO)"
}

# brotli_test_image IMAGE — checks the complete current configuration plus the Brotli settings with that image,
# in a throw-away container, BEFORE the real nginx is touched
brotli_test_image() {
    local img="$1" tmp out rc
    tmp="$(mktemp -d)"; cp -a "$NGINX_DIR/conf.d/." "$tmp/" 2>/dev/null
    brotli_write_conf "$tmp/01-brotli.conf"
    out="$(docker run --rm --network "$NETWORK" \
            -v "$tmp:/etc/nginx/conf.d:ro" -v "$NGINX_DIR/letsencrypt:/etc/letsencrypt:ro" \
            -v "$NGINX_DIR/certbot-www:/var/www/certbot:ro" -v "$PROJECTS_DIR:$PROJECTS_DIR:ro" \
            "$img" nginx -t 2>&1)"; rc=$?
    rm -rf "$tmp"
    if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" | tail -n 8 | sed 's/^/    /'; return 1; fi
    return 0
}

# nginx_switch_image IMAGE — recreate the nginx container with another image (a second or two of downtime);
# the previous compose file is restored when the new container does not come up healthy
nginx_switch_image() {
    local new="$1" f="$NGINX_DIR/docker-compose.yml" bak
    [ -f "$f" ] || { err "nginx was not installed by HiDeploy (compose file not found)."; return 1; }
    bak="$f.bak-$(date +%F_%H%M%S)"; cp "$f" "$bak"
    sed -i "s|^    image: .*|    image: $new|" "$f"
    docker compose -f "$f" up -d >/dev/null 2>&1
    sleep 3
    if container_running "$NGINX_CONTAINER" && docker exec "$NGINX_CONTAINER" nginx -t >/dev/null 2>&1; then
        rm -f "$bak"; return 0
    fi
    err "The new nginx container did not come up correctly: restoring the previous one."
    cp "$bak" "$f"; docker compose -f "$f" up -d >/dev/null 2>&1; rm -f "$bak"
    return 1
}

# brotli_activate IMAGE INFO MODE — switch to the image, turn the settings on, refresh the vhosts; undo everything on failure
brotli_activate() {
    local img="$1" info_txt="$2" mode="$3" prev
    prev="$(sed -n 's/^    image: //p' "$NGINX_DIR/docker-compose.yml" | head -n1)"
    nginx_switch_image "$img" || return 1
    brotli_write_conf
    if ! nginx_test_reload; then
        err "nginx rejected the Brotli settings: going back to the previous image."
        rm -f "$BROTLI_CONF"; nginx_switch_image "${prev:-$NGINX_IMAGE}" >/dev/null 2>&1
        return 1
    fi
    cfg_set NGINX_BROTLI yes; cfg_set NGINX_BROTLI_IMAGE "$img"; cfg_set NGINX_BROTLI_MODE "$mode"; cfg_set NGINX_BROTLI_INFO "$info_txt"
    info "Updating every project's nginx configuration (Next.js sites must let nginx do the compression)..."
    nginx_refresh_all >/dev/null 2>&1
    nginx_test_reload >/dev/null 2>&1 || true
    return 0
}

brotli_enable() {
    section "Brotli compression for all sites"
    explain \
        "Brotli compresses text (HTML, CSS, JavaScript, JSON, SVG, fonts) better than gzip: files are usually 10-25% smaller," \
        "which shortens the load time most on phones and slow connections. It costs a little CPU on this server." \
        "All modern browsers use it over HTTPS; older ones automatically keep getting gzip. You can switch it off again any time."
    docker_ready && container_running "$NGINX_CONTAINER" || { err "The nginx container is not running (main menu 2)."; return 1; }
    [ -f "$NGINX_DIR/docker-compose.yml" ] || { err "nginx was not installed by HiDeploy (compose file not found)."; return 1; }
    if brotli_on; then ok "Brotli is already ON ($(cfg_get NGINX_BROTLI_INFO || true))."; return 0; fi

    local choice lvl img custom
    echo ""
    echo " 1) Build it for me (recommended): official nginx + the newest ngx_brotli, compiled on this server (2-5 minutes)"
    echo " 2) Use an nginx image that I already have (for example my own nginx-brotli:latest)"
    echo " 0) Cancel"
    read -r -p "Select [1]: " choice; choice="${choice:-1}"
    case "$choice" in 1|2) ;; *) info "Cancelled."; return 0 ;; esac
    while true; do
        ask "Compression level 1-11 (higher = smaller files but more CPU; 4-6 is the sweet spot)" "$(brotli_level)" lvl
        [[ "$lvl" =~ ^([1-9]|10|11)$ ]] && break; err "Enter a number from 1 to 11."
    done
    cfg_set BROTLI_LEVEL "$lvl"

    if [ "$choice" = "1" ]; then
        explain "Source code is downloaded from github.com (google/ngx_brotli) and nginx.org and compiled in a temporary build stage."
        confirm "Start the build now?" y || { info "Cancelled."; return 0; }
        brotli_build || return 1
        img="$BROTLI_IMG"; custom="build"
    else
        ask "Image name (e.g. nginx-brotli:latest)" "" img
        [[ "$img" =~ ^[A-Za-z0-9._/:@-]{1,120}$ ]] || { err "Invalid image name."; return 1; }
        docker image inspect "$img" >/dev/null 2>&1 || { err "That image does not exist on this server (docker images)."; return 1; }
        BROTLI_INFO="your own image $img"; custom="custom"
    fi
    info "Testing the complete nginx configuration with the new image (nothing is changed yet)..."
    if ! brotli_test_image "$img"; then
        err "The new image does not accept the configuration, so nothing was changed."
        [ "$custom" = "custom" ] && explain "A custom image must load the Brotli modules itself (a 'load_module' line in its nginx.conf, or Brotli compiled in)."
        return 1
    fi
    ok "The new image accepts the configuration."
    warn "Now nginx is recreated with the new image: sites are unreachable for about 1-3 seconds."
    confirm "Switch now?" y || { info "Cancelled. Nothing was changed."; return 0; }
    brotli_activate "$img" "$BROTLI_INFO" "$custom" || { err "Brotli was not enabled; everything is as before."; return 1; }
    ok "Brotli is ON."
    next_steps \
        "Check a site: Shared Services -> Brotli -> Test it on a site (shows the real sizes: plain, gzip, Brotli)." \
        "Browsers use Brotli only over HTTPS, so test with the https:// address."
}

brotli_rebuild() {
    section "Rebuild Brotli with the newest versions"
    brotli_on || { err "Brotli is not enabled."; return 1; }
    [ "$(cfg_get NGINX_BROTLI_MODE || true)" = "build" ] || { err "Brotli runs with your own image: update that image yourself."; return 1; }
    explain "Pulls the newest official nginx image and the newest ngx_brotli, builds a fresh image, tests it and switches (1-3 seconds without service)."
    confirm "Rebuild now?" y || return 0
    local old; old="$(cfg_get NGINX_BROTLI_IMAGE || true)"
    brotli_build || return 1
    info "Testing the complete nginx configuration with the new image (nothing is changed yet)..."
    brotli_test_image "$BROTLI_IMG" || { err "The new image does not accept the configuration; nothing was changed."; return 1; }
    nginx_switch_image "$BROTLI_IMG" || { err "Could not switch; the previous nginx keeps running."; return 1; }
    nginx_test_reload >/dev/null 2>&1 || true
    cfg_set NGINX_BROTLI_IMAGE "$BROTLI_IMG"; cfg_set NGINX_BROTLI_INFO "$BROTLI_INFO"
    [ -n "$old" ] && [ "$old" != "$BROTLI_IMG" ] && docker rmi "$old" >/dev/null 2>&1
    ok "nginx now runs: $BROTLI_INFO"
}

brotli_set_level() {
    brotli_on || { err "Brotli is not enabled."; return 1; }
    local lvl old; old="$(brotli_level)"
    while true; do
        ask "Compression level 1-11 (4-6 recommended; current $old)" "$old" lvl
        [[ "$lvl" =~ ^([1-9]|10|11)$ ]] && break; err "Enter a number from 1 to 11."
    done
    cfg_set BROTLI_LEVEL "$lvl"; brotli_write_conf
    if nginx_test_reload; then ok "Level set to $lvl."; else
        err "nginx rejected it: back to level $old."; cfg_set BROTLI_LEVEL "$old"; brotli_write_conf; nginx_test_reload >/dev/null 2>&1
    fi
}

brotli_disable() {
    section "Turn Brotli off"
    brotli_on || { info "Brotli is not enabled."; return 0; }
    confirm "Turn Brotli off? (sites go back to gzip only)" n || return 0
    rm -f "$BROTLI_CONF"
    cfg_set NGINX_BROTLI no
    nginx_test_reload >/dev/null 2>&1 || true
    nginx_refresh_all >/dev/null 2>&1
    ok "Brotli settings removed; sites use gzip."
    if confirm "Also go back to the standard nginx image (recommended)?" y; then
        nginx_switch_image "$NGINX_IMAGE" && ok "nginx runs the standard image again." || warn "Could not switch the image; Brotli stays loaded but unused."
    fi
}

# Shows the real transfer sizes of a site: what a browser downloads with and without compression
brotli_test_site() {
    section "Test compression on a site"
    local d p n=0 hdrs enc plain gz br
    local -a doms=()
    while IFS= read -r p; do doms+=("$(basename "$p")"); done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null | sort)
    ask "Domain to test" "${doms[0]:-}" d
    valid_domain "$d" || { err "Invalid domain."; return 1; }
    hdrs="$(curl -s -o /dev/null -D - --max-time 25 -H 'Accept-Encoding: br, gzip' "https://$d/" 2>/dev/null)"
    [ -n "$hdrs" ] || { err "No answer from https://$d/ (DNS, SSL or the site itself)."; return 1; }
    enc="$(grep -i '^content-encoding:' <<<"$hdrs" | tr -d '\r' | awk '{print tolower($2)}' | head -n1)"
    plain="$(curl -s --max-time 25 -H 'Accept-Encoding: identity' "https://$d/" 2>/dev/null | wc -c)"
    gz="$(curl -s --max-time 25 -H 'Accept-Encoding: gzip' "https://$d/" 2>/dev/null | wc -c)"
    br="$(curl -s --max-time 25 -H 'Accept-Encoding: br' "https://$d/" 2>/dev/null | wc -c)"
    printf '  Page https://%s/\n' "$d"
    printf '    without compression: %8s bytes\n    gzip:                %8s bytes\n    Brotli:              %8s bytes\n' "$plain" "$gz" "$br"
    printf '  A browser that supports Brotli receives: %s\n' "${enc:-no compression}"
    if [ "$enc" = "br" ]; then ok "Brotli is working for this site."
    elif brotli_on; then
        warn "Brotli is ON but this page did not use it."
        explain "Pages under 1 KB are not compressed, and some responses are skipped (redirects, errors, images). Try a bigger page, or check: docker logs $NGINX_CONTAINER"
    else info "Brotli is OFF: enable it in this menu."; fi
}

menu_brotli() {
    local c
    while true; do
        clear; banner "Brotli compression" "$C_BLUE"
        brotli_status_row; echo ""
        echo " 1) Enable Brotli (build the nginx image, test it, switch)"
        echo " 2) Rebuild with the newest nginx and Brotli versions"
        echo " 3) Change the compression level"
        echo " 4) Test it on a site (real sizes: plain, gzip, Brotli)"
        echo " 5) Turn Brotli off"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item brotli_enable ;;
            2) run_item brotli_rebuild ;;
            3) run_item brotli_set_level ;;
            4) run_item brotli_test_site ;;
            5) run_item brotli_disable ;;
            0) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ============================================================================
# VERSIONS AND UPDATE CENTER (main menu 11)
# ============================================================================
# Two ideas:
#  1) Versions are never hidden: whenever HiDeploy installs something it suggests a version (with the reason), the user
#     accepts it or picks another one, and the image tag is checked on the registry before it is used.
#  2) The compose file that is installed on the server is the single source of truth. Nothing is "upgraded behind your
#     back": a newer image is only started after a safety backup, and a failed start is rolled back automatically.
#     A change of MAJOR version (MariaDB, PostgreSQL, Redis) is a separate, guided procedure (dump -> new data volume ->
#     restore -> verify) that keeps the old data volume until you delete it yourself.

# Release facts below were checked on this date against the official pages (postgresql.org, mariadb.org, php.net,
# nodejs.org, laravel.com). They only drive suggestions and warnings: every tag is verified on the registry before use.
CATALOG_CHECKED="2026-11-08"
DEFAULT_PHP_VERSION="8.5"
PHP_CANDIDATES=(8.5 8.4 8.3 8.2)
NODE_CANDIDATES=(26 24 22)

# End of security support (YYYY-MM-DD) per version line
catalog_eol() {   # KIND VERSION
    case "$1:$2" in
        php:8.2) echo 2026-12-31 ;;  php:8.3) echo 2027-12-31 ;;  php:8.4) echo 2028-12-31 ;;  php:8.5) echo 2029-12-31 ;;
        node:20) echo 2026-04-30 ;;  node:22) echo 2027-04-30 ;;  node:24) echo 2028-04-30 ;;  node:26) echo 2029-04-30 ;;
        mariadb:10.6) echo 2026-07-06 ;;   mariadb:10.11) echo 2028-02-16 ;;  mariadb:11.4) echo 2029-05-29 ;;
        mariadb:11.8) echo 2028-06-04 ;;   mariadb:12.3) echo 2029-06-12 ;;
        postgres:14) echo 2026-11-12 ;;  postgres:15) echo 2027-11-11 ;;  postgres:16) echo 2028-11-09 ;;
        postgres:17) echo 2029-11-08 ;;  postgres:18) echo 2030-11-14 ;;
    esac
    return 0
}

eol_plain() {   # KIND VERSION -> plain text
    local d s left
    d="$(catalog_eol "$1" "$2")"; [ -n "$d" ] || { printf 'support dates: see the vendor website'; return 0; }
    s="$(date -d "$d" +%s 2>/dev/null)" || return 0
    left=$(( (s - $(date +%s)) / 86400 ))
    if [ "$left" -lt 0 ]; then printf 'ENDED %s, no more security fixes' "$d"
    elif [ "$left" -lt 180 ]; then printf 'support ends %s (in %d days)' "$d" "$left"
    else printf 'supported until %s' "$d"; fi
}

eol_text() {    # KIND VERSION -> coloured
    local t; t="$(eol_plain "$1" "$2")"
    case "$t" in
        ENDED*)        printf '%s%s%s' "$C_RED" "$t" "$C_RESET" ;;
        "support ends"*) printf '%s%s%s' "$C_YELLOW" "$t" "$C_RESET" ;;
        *)             printf '%s%s%s' "$C_DIM" "$t" "$C_RESET" ;;
    esac
}

# ---------- what is installed ---------------------------------------------------------------
compose_image_of() { [ -f "$1" ] || return 0; sed -n 's/^    image: *//p' "$1" | head -n1 | tr -d '"'; }

# The installed compose file wins over the defaults at the top of this script, so an existing server keeps exactly
# the images it runs, and every later rewrite of a compose file (tuning, Brotli ...) keeps them too.
load_installed_images() {
    local i
    i="$(compose_image_of "$DB_DIR/docker-compose.yml")";      [ -n "$i" ] && MARIADB_IMAGE="$i"
    i="$(compose_image_of "$PG_DIR/docker-compose.yml")";      [ -n "$i" ] && POSTGRES_IMAGE="$i"
    i="$(compose_image_of "$REDIS_DIR/docker-compose.yml")";   [ -n "$i" ] && REDIS_IMAGE="$i"
    i="$(compose_image_of "$PMA_DIR/docker-compose.yml")";     [ -n "$i" ] && PMA_IMAGE="$i"
    i="$(compose_image_of "$MAIL_DIR/docker-compose.yml")";    [ -n "$i" ] && MAIL_IMAGE="$i"
    i="$(compose_image_of "$MAILWEB_DIR/docker-compose.yml")"; [ -n "$i" ] && MAILWEB_IMAGE="$i"
    i="$(cfg_get NGINX_BASE_IMAGE || true)";                    [ -n "$i" ] && NGINX_IMAGE="$i"
    return 0
}

image_tag() { local t="${1#*:}"; [ "$t" = "$1" ] && t=latest; printf '%s' "$t"; }

image_series() {   # KIND IMAGE -> 12.3 (mariadb) | 18 (postgres, redis, node)
    local t; t="$(image_tag "$2")"
    case "$1" in
        mariadb) [[ "$t" =~ ^([0-9]+\.[0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}" ;;
        postgres|redis|node) [[ "$t" =~ ^([0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}" ;;
    esac
    return 0
}

series_key() { local a="${1%%.*}" b="${1#*.}"; [ "$b" = "$1" ] && b=0; echo $(( 10#$a * 1000 + 10#$b )); }

# ---------- choosing a version -----------------------------------------------------------------
image_exists() {
    docker image inspect "$1" >/dev/null 2>&1 && return 0
    timeout 40 docker manifest inspect "$1" >/dev/null 2>&1
}

verify_image() {   # IMAGE -> 0 when it may be used
    info "Checking on the registry that $1 exists..."
    if image_exists "$1"; then ok "$1 is available."; return 0; fi
    warn "Could not confirm that '$1' exists (wrong tag, or this server cannot reach the registry)."
    confirm "Use it anyway?" n
}

# choose_tag LABEL SUGGESTED_TAG REASON REGEX "tag|note" ...   -> CHOSEN_TAG   (returns 1 on cancel)
choose_tag() {
    local label="$1" sug="$2" reason="$3" re="$4"; shift 4
    local -a tags=() notes=()
    local item i def=0 choice n mark
    for item in "$@"; do tags+=("${item%%|*}"); notes+=("${item#*|}"); done
    for i in "${!tags[@]}"; do [ "${tags[$i]}" = "$sug" ] && def=$((i+1)); done
    [ "$def" -gt 0 ] || def=1
    echo ""
    printf ' %sWhich %s version?%s\n' "$C_BOLD" "$label" "$C_RESET"
    [ -z "$reason" ] || explain "$reason"
    for i in "${!tags[@]}"; do
        mark=""; [ $((i+1)) -eq "$def" ] && mark="   <- suggested"
        printf '  %d) %-14s %s%s%s%s%s%s\n' $((i+1)) "${tags[$i]}" "$C_DIM" "${notes[$i]}" "$C_RESET" "$C_GREEN" "$mark" "$C_RESET"
    done
    n=$(( ${#tags[@]} + 1 ))
    printf '  %d) Type another version\n  0) Cancel\n' "$n"
    while true; do
        read -r -p "${C_YELLOW}Select [$def]: ${C_RESET}" choice; choice="${choice:-$def}"
        if [ "$choice" = "0" ]; then return 1; fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$n" ]; then CHOSEN_TAG="${tags[$((choice-1))]}"; return 0; fi
        if [ "$choice" = "$n" ]; then
            read -r -p "${C_YELLOW}Version / tag: ${C_RESET}" choice
            if [[ "$choice" =~ $re ]]; then CHOSEN_TAG="$choice"; return 0; fi
            err "That does not look right for $label (expected something like ${tags[0]})."; continue
        fi
        err "Choose a number from the list."
    done
}

# Service pickers: each sets the matching *_IMAGE variable (used by the install step that called it)
pick_mariadb_image() {
    choose_tag "MariaDB" "12.3" "12.3 is the newest long-term-support (LTS) line. 11.8 is the more settled one; 10.11 is the oldest still supported." \
        '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
        "12.3|newest LTS - $(eol_plain mariadb 12.3)" "11.8|LTS - $(eol_plain mariadb 11.8)" "10.11|older LTS - $(eol_plain mariadb 10.11)" || return 1
    MARIADB_IMAGE="mariadb:$CHOSEN_TAG"; verify_image "$MARIADB_IMAGE"
}

pick_postgres_image() {
    choose_tag "PostgreSQL" "18-bookworm" "The number before the dash is the major version. 'bookworm' pins the Debian base: it never changes underneath your data." \
        '^[0-9]+(\.[0-9]+)?(-[a-z0-9.]+)?$' \
        "18-bookworm|newest - $(eol_plain postgres 18)" "17-bookworm|previous - $(eol_plain postgres 17)" "16-bookworm|older - $(eol_plain postgres 16)" || return 1
    [ -n "$(image_series postgres "postgres:$CHOSEN_TAG")" ] || { err "The tag must start with the major version number (for example 18-bookworm)."; return 1; }
    POSTGRES_IMAGE="postgres:$CHOSEN_TAG"; verify_image "$POSTGRES_IMAGE"
}

pick_redis_image() {
    choose_tag "Redis" "8-alpine" "Redis 8 is the current line (AGPLv3 licence: fine for running your own projects). 7 is the previous line." \
        '^[0-9]+(\.[0-9]+)*(-[a-z0-9.]+)?$' \
        "8-alpine|current" "7-alpine|previous line" || return 1
    REDIS_IMAGE="redis:$CHOSEN_TAG"; verify_image "$REDIS_IMAGE"
}

pick_nginx_image() {
    choose_tag "nginx" "stable-alpine" "'stable' only receives fixes (calm, recommended for servers). 'mainline' also gets new features sooner." \
        '^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$' \
        "stable-alpine|recommended" "mainline-alpine|newer features" || return 1
    NGINX_IMAGE="nginx:$CHOSEN_TAG"; verify_image "$NGINX_IMAGE" && cfg_set NGINX_BASE_IMAGE "$NGINX_IMAGE"
}

# ---------- project-aware suggestions (PHP and Node) ------------------------------------------------
# constraint_ok CONSTRAINT MAJOR MINOR -> 0 when that version satisfies a composer/npm style constraint
# (^8.2  ~8.3.0  >=8.2 <8.5  8.3.*  ^8.2 || ^8.3). Syntax that is not understood counts as satisfied.
constraint_ok() {
    local c="$1" tmaj="$2" tmin="$3" part tok op cmaj cmin cpat t k allok hasmin haspat
    local -a parts toks
    c="$(printf '%s' "$c" | tr 'A-Z' 'a-z' | sed -E 's/\|\|/|/g; s/([<>=!~^]+)[[:space:]]+/\1/g; s/,/ /g')"
    [ -n "${c// /}" ] || return 0
    IFS='|' read -r -a parts <<<"$c"
    for part in "${parts[@]}"; do
        read -r -a toks <<<"$part"
        allok=1
        for tok in "${toks[@]}"; do
            [[ "$tok" =~ ^(\^|~|>=|<=|>|<|=|!=)?v?([0-9]+)(\.([0-9]+|\*|x))?(\.([0-9]+|\*|x))?.*$ ]] || continue
            op="${BASH_REMATCH[1]}"; cmaj="${BASH_REMATCH[2]}"; cmin="${BASH_REMATCH[4]}"; cpat="${BASH_REMATCH[6]}"
            hasmin=1; haspat=1
            if [ -z "$cmin" ] || [ "$cmin" = "*" ] || [ "$cmin" = "x" ]; then hasmin=0; cmin=0; fi
            if [ -z "$cpat" ] || [ "$cpat" = "*" ] || [ "$cpat" = "x" ]; then haspat=0; cpat=0; fi
            t=$(( 10#$tmaj * 1000 + 10#$tmin )); k=$(( 10#$cmaj * 1000 + 10#$cmin ))
            case "$op" in
                ""|"=")  if [ "$hasmin" -eq 0 ]; then [ "$tmaj" -eq "$cmaj" ] || allok=0; else [ "$t" -eq "$k" ] || allok=0; fi ;;
                "^")     [ "$tmaj" -eq "$cmaj" ] && [ "$t" -ge "$k" ] || allok=0 ;;
                "~")     if [ "$haspat" -eq 1 ]; then [ "$t" -eq "$k" ] || allok=0
                         elif [ "$hasmin" -eq 1 ]; then [ "$tmaj" -eq "$cmaj" ] && [ "$t" -ge "$k" ] || allok=0
                         else [ "$tmaj" -eq "$cmaj" ] || allok=0; fi ;;
                ">=")    [ "$t" -ge "$k" ] || allok=0 ;;
                ">")     if [ "$haspat" -eq 1 ]; then [ "$t" -ge "$k" ] || allok=0; else [ "$t" -gt "$k" ] || allok=0; fi ;;
                "<")     if [ "$t" -lt "$k" ]; then :; elif [ "$t" -eq "$k" ] && [ "$cpat" -gt 0 ]; then :; else allok=0; fi ;;
                "<=")    if [ "$hasmin" -eq 0 ]; then [ "$tmaj" -le "$cmaj" ] || allok=0; else [ "$t" -le "$k" ] || allok=0; fi ;;
            esac
        done
        [ "$allok" -eq 1 ] && return 0
    done
    return 1
}

composer_php_constraint() { [ -f "$1/composer.json" ] || return 0; sed -n 's/.*"php"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/composer.json" | head -n1; }
composer_laravel_major()  {
    local c; [ -f "$1/composer.json" ] || return 0
    c="$(sed -n 's#.*"laravel/framework"[[:space:]]*:[[:space:]]*"\([^"]*\)".*#\1#p' "$1/composer.json" | head -n1)"
    [[ "$c" =~ ([0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
    return 0
}
pkg_node_constraint() { [ -f "$1/package.json" ] || return 0; sed -n 's/.*"node"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/package.json" | head -n1; }

# The newest PHP in the list that the project allows. Laravel 10 is tested up to PHP 8.3 and Laravel 11 up to 8.4.
suggest_php_from() {   # CONSTRAINT LARAVEL_MAJOR -> SUG_PHP, SUG_REASON
    local con="$1" lv="$2" cap="8.5" v maj min why=""
    if [[ "$lv" =~ ^[0-9]+$ ]]; then
        if [ "$lv" -le 10 ]; then cap="8.3"; elif [ "$lv" -eq 11 ]; then cap="8.4"; fi
        [ "$cap" = "8.5" ] || why="Laravel $lv is tested up to PHP $cap. "
    fi
    [ -z "$con" ] || why="${why}composer.json asks for php \"$con\". "
    for v in "${PHP_CANDIDATES[@]}"; do
        maj="${v%%.*}"; min="${v#*.}"
        [ "$(series_key "$v")" -le "$(series_key "$cap")" ] || continue
        if [ -z "$con" ] || constraint_ok "$con" "$maj" "$min"; then
            SUG_PHP="$v"; SUG_REASON="${why}Suggested: the newest version that fits. $(eol_plain php "$v")."; return 0
        fi
    done
    SUG_PHP="$DEFAULT_PHP_VERSION"; SUG_REASON="${why}No PHP version in the list fits exactly; check your composer.json."
    return 1
}

suggest_node_from() {   # CONSTRAINT -> SUG_NODE, SUG_REASON
    local con="$1" v why=""
    [ -z "$con" ] || why="package.json (engines) asks for node \"$con\". "
    for v in "${NODE_CANDIDATES[@]}"; do
        if [ -z "$con" ] || constraint_ok "$con" "$v" 99; then
            SUG_NODE="$v"; SUG_REASON="${why}Suggested: the newest LTS that fits. $(eol_plain node "$v")."; return 0
        fi
    done
    SUG_NODE="${NODE_CANDIDATES[0]}"; SUG_REASON="${why}No Node version in the list fits exactly."; return 1
}

php_menu_items() {
    local v n
    for v in "${PHP_CANDIDATES[@]}"; do
        case "$v" in 8.5) n="newest" ;; 8.4) n="widely used" ;; 8.3) n="security fixes only" ;; *) n="old" ;; esac
        printf '%s|%s - %s\n' "$v" "$n" "$(eol_plain php "$v")"
    done
}
node_menu_items() {
    local v n
    for v in "${NODE_CANDIDATES[@]}"; do
        case "$v" in 26) n="newest LTS" ;; 24) n="LTS, more conservative" ;; *) n="LTS, in maintenance" ;; esac
        printf '%s|%s - %s\n' "$v" "$n" "$(eol_plain node "$v")"
    done
}

# pick_php [PATH] [CURRENT] -> PICK_PHP ; PATH is a project folder (composer.json is read when present)
pick_php() {
    local path="${1:-}" cur="${2:-}" con="" lv="" sug why
    local -a items
    [ -z "$path" ] || { con="$(composer_php_constraint "$path")"; lv="$(composer_laravel_major "$path")"; }
    suggest_php_from "$con" "$lv"; sug="$SUG_PHP"; why="$SUG_REASON"
    # keep the version that is already in use when it still fits the project: no surprise changes
    if [ -n "$cur" ] && { [ -z "$con" ] || constraint_ok "$con" "${cur%%.*}" "$(cut -d. -f2 <<<"$cur")"; }; then sug="$cur"; why="${why} Keeping the version already in use ($cur)."; fi
    mapfile -t items < <(php_menu_items)
    choose_tag "PHP" "$sug" "$why" '^[0-9]+\.[0-9]+(\.[0-9]+)?$' "${items[@]}" || return 1
    PICK_PHP="$CHOSEN_TAG"
    verify_image "php:${PICK_PHP}-fpm-alpine" || return 1
}

pick_node() {   # [PATH] [CURRENT] -> PICK_NODE (major version number)
    local path="${1:-}" cur="${2:-}" con="" sug why
    local -a items
    [ -z "$path" ] || con="$(pkg_node_constraint "$path")"
    suggest_node_from "$con"; sug="$SUG_NODE"; why="$SUG_REASON"
    if [ -n "$cur" ] && { [ -z "$con" ] || constraint_ok "$con" "$cur" 99; }; then sug="$cur"; why="${why} Keeping the version already in use ($cur)."; fi
    mapfile -t items < <(node_menu_items)
    choose_tag "Node.js" "$sug" "$why" '^[0-9]{2}(\.[0-9]+)*$' "${items[@]}" || return 1
    PICK_NODE="$CHOSEN_TAG"
    verify_image "node:${PICK_NODE}-alpine" || return 1
}

# ---------- reading versions from project files ---------------------------------------------------
dockerfile_php_version() {
    local f="$1/Dockerfile" v; [ -f "$f" ] || return 0
    v="$(sed -n 's/^ARG PHP_VERSION=\([0-9][0-9.]*\).*/\1/p' "$f" | head -n1)"
    [ -n "$v" ] || v="$(sed -n 's/^FROM php:\([0-9][0-9.]*\)-.*/\1/p' "$f" | head -n1)"
    printf '%s' "$v"
}
dockerfile_node_version() {
    local f="$1/Dockerfile" v; [ -f "$f" ] || return 0
    v="$(sed -n 's/^ARG NODE_VERSION=\([0-9][0-9.]*\).*/\1/p' "$f" | head -n1)"
    [ -n "$v" ] || v="$(sed -n 's/^FROM node:\([0-9][0-9.]*\)-.*/\1/p' "$f" | head -n1)"
    printf '%s' "$v"
}
dockerfile_has_arg() { grep -qs "^ARG $2=" "$1/Dockerfile"; }

# Warn when the Dockerfile builds a PHP that composer.json does not allow (composer install would fail later)
check_php_fit() {   # PATH
    local path="$1" v con
    v="$(dockerfile_php_version "$path")"; con="$(composer_php_constraint "$path")"
    [ -n "$v" ] && [ -n "$con" ] || return 0
    constraint_ok "$con" "${v%%.*}" "$(cut -d. -f2 <<<"$v")" && return 0
    warn "composer.json asks for php \"$con\" but the Dockerfile builds PHP $v: 'composer install' will probably fail."
    return 1
}

# ---------- components -----------------------------------------------------------------------------
upd_ids() { echo "nginx mariadb postgres redis phpmyadmin mail webmail"; }
upd_label() { case "$1" in nginx) echo "nginx";; mariadb) echo "MariaDB";; postgres) echo "PostgreSQL";; redis) echo "Redis";; phpmyadmin) echo "phpMyAdmin";; mail) echo "Mail server";; webmail) echo "Webmail (Roundcube)";; esac; }
upd_dir() { case "$1" in nginx) echo "$NGINX_DIR";; mariadb) echo "$DB_DIR";; postgres) echo "$PG_DIR";; redis) echo "$REDIS_DIR";; phpmyadmin) echo "$PMA_DIR";; mail) echo "$MAIL_DIR";; webmail) echo "$MAILWEB_DIR";; esac; }
upd_container() { case "$1" in nginx) echo "$NGINX_CONTAINER";; mariadb) echo "$DB_CONTAINER";; postgres) echo "$PG_CONTAINER";; redis) echo "$REDIS_CONTAINER";; phpmyadmin) echo "$PMA_CONTAINER";; mail) echo "$MAIL_CONTAINER";; webmail) echo "$MAILWEB_CONTAINER";; esac; }
upd_compose() { printf '%s/docker-compose.yml' "$(upd_dir "$1")"; }
upd_installed() { [ -f "$(upd_compose "$1")" ]; }
upd_image() { compose_image_of "$(upd_compose "$1")"; }
upd_kind() { case "$1" in mariadb|postgres|redis) echo "$1";; *) echo "";; esac; }

upd_running_version() {
    local c; c="$(upd_container "$1")"
    container_running "$c" || { printf 'not running'; return 0; }
    case "$1" in
        mariadb)  docker exec "$c" sh -c 'mariadbd --version 2>/dev/null || mysqld --version 2>/dev/null' | sed -n 's/.*Ver \([0-9][0-9.]*\).*/\1/p' | head -n1 ;;
        postgres) docker exec "$c" postgres --version 2>/dev/null | sed -n 's/.*) \([0-9][0-9.]*\).*/\1/p' | head -n1 ;;
        redis)    docker exec "$c" redis-server --version 2>/dev/null | sed -n 's/.*v=\([0-9][0-9.]*\).*/\1/p' | head -n1 ;;
        nginx)    docker exec "$c" nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p' | head -n1 ;;
        *)        docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$c" 2>/dev/null ;;
    esac
    return 0
}

upd_pending() {   # ID -> 0 when a newer build of the image is on this server but the container still runs the old one
    local c img new cur
    c="$(upd_container "$1")"; img="$(upd_image "$1")"
    new="$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null)"; cur="$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null)"
    [ -n "$new" ] && [ -n "$cur" ] && [ "$new" != "$cur" ]
}

# the data volume a container really uses (by mount point)
upd_volume_of() { docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Name}}{{end}}{{end}}" "$1" 2>/dev/null; }

upd_nginx_built() { brotli_on && [ "$(cfg_get NGINX_BROTLI_MODE || true)" = "build" ]; }

# ---------- overview and check ------------------------------------------------------------------------
upd_overview() {
    local id img run kind ser eol pend
    printf '  %-20s %-14s %s\n' "COMPONENT" "RUNNING" "IMAGE / SUPPORT"
    for id in $(upd_ids); do
        upd_installed "$id" || continue
        img="$(upd_image "$id")"; run="$(upd_running_version "$id")"; kind="$(upd_kind "$id")"; eol=""
        if [ -n "$kind" ]; then ser="$(image_series "$kind" "$img")"; [ -z "$ser" ] || eol="  $(eol_text "$kind" "$ser")"; fi
        pend=""
        if docker_ready && container_running "$(upd_container "$id")" && upd_pending "$id"; then pend="  ${C_GREEN}update ready${C_RESET}"; fi
        printf '  %-20s %-14s %s%s%s%s%s\n' "$(upd_label "$id")" "${run:-?}" "$C_DIM" "$img" "$C_RESET" "$eol" "$pend"
    done
}

upd_check_all() {
    section "Checking for updates"
    docker_ready || { err "Docker is not ready."; return 1; }
    explain "Downloads the newest build of every installed image (same version line). Nothing is started or changed yet."
    local id img n=0 note
    for id in $(upd_ids); do
        upd_installed "$id" || continue
        img="$(upd_image "$id")"
        if [ "$id" = "nginx" ] && upd_nginx_built; then
            note="built on this server: use Shared Services -> Brotli -> Rebuild (or option 2 here)"
            printf '  %-20s %s\n' "$(upd_label "$id")" "$note"; continue
        fi
        printf '  %-20s ' "$(upd_label "$id")"
        if ! docker pull -q "$img" >/dev/null 2>&1; then printf '%scould not download %s%s\n' "$C_YELLOW" "$img" "$C_RESET"; continue; fi
        if container_state "$(upd_container "$id")" | grep -q missing; then printf 'installed, container missing\n'
        elif upd_pending "$id"; then printf '%supdate ready%s (%s)\n' "$C_GREEN" "$C_RESET" "$img"; n=$((n+1))
        else printf 'up to date (%s)\n' "$img"; fi
    done
    cfg_set UPD_LAST_CHECK "$(date +%s)"
    echo ""
    if [ "$n" -gt 0 ]; then ok "$n update(s) ready. Install them with option 2 or 3."; else ok "Everything is on the newest build of its version line."; fi
    local id2 ser latest
    for id2 in mariadb postgres redis; do
        upd_installed "$id2" || continue
        ser="$(image_series "$id2" "$(upd_image "$id2")")"; [ -n "$ser" ] || continue
        case "$id2" in mariadb) latest="12.3" ;; postgres) latest="18" ;; redis) latest="8" ;; esac
        if [ "$(series_key "$ser")" -lt "$(series_key "$latest")" ]; then
            info "$(upd_label "$id2") $ser is not the newest line ($latest). Upgrade (guided, option 4): $(eol_plain "$id2" "$ser")."
        fi
    done
}

upd_status_row() {
    local any=0 id last days
    for id in $(upd_ids); do upd_installed "$id" && any=1; done
    [ "$any" -eq 1 ] || return 0
    last="$(cfg_get UPD_LAST_CHECK || true)"
    if [ -z "$last" ]; then status_row "Updates" warn "NEVER CHECKED" "main menu 11 -> Check for updates"; return 0; fi
    days=$(( ( $(date +%s) - last ) / 86400 ))
    if [ "$days" -ge 90 ]; then status_row "Updates" warn "CHECK DUE" "last check $days days ago: main menu 11"
    else status_row "Updates" good "CHECKED" "$days days ago"; fi
}

# ---------- safety backup before touching a component ------------------------------------------------
upd_env_secret() {   # FILE KEY -> the value, without quotes or escapes
    local raw; raw="$(grep -E "^$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2-)"
    case "$raw" in
        \"*\") raw="${raw#\"}"; raw="${raw%\"}"; printf '%s' "$raw" | sed 's/\\\(.\)/\1/g' ;;
        \'*\') raw="${raw#\'}"; raw="${raw%\'}"; printf '%s' "$raw" ;;
        *) printf '%s' "$raw" ;;
    esac
}

# upd_managed_dbs ENGINE -> lines "DB|USER|PASS" of the projects that use that engine
upd_managed_dbs() {
    local p db user pass
    while IFS= read -r p; do
        [ "$(db_engine_of "$p")" = "$1" ] || continue
        [ "$( . "$p/.deploy.env" 2>/dev/null; echo "${USE_DATABASE:-yes}" )" = "yes" ] || continue
        db="$(env_get "$p/.env" DB_DATABASE)"; user="$(env_get "$p/.env" DB_USERNAME)"; pass="$(upd_env_secret "$p/.env" DB_PASSWORD)"
        [ -n "$db" ] && [ -n "$user" ] && [ -n "$pass" ] && printf '%s|%s|%s\n' "$db" "$user" "$pass"
    done < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null | sort)
}

upd_list_dbs() {   # ENGINE -> every user database on the server
    if [ "$1" = "postgres" ]; then
        printf "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1;\n" | pg_sql
    else
        printf "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys') ORDER BY 1;\n" | db_sql
    fi
}

dump_ok() {   # FILE -> 0 when a gz dump is complete
    [ -s "$1" ] && gzip -t "$1" 2>/dev/null || return 1
    case "$2" in
        postgres) gzip -dc "$1" | tail -n 5 | grep -q 'PostgreSQL database cluster dump complete' ;;
        *)        gzip -dc "$1" | tail -n 5 | grep -q 'Dump completed' ;;
    esac
}

# upd_dump_all ENGINE DIR -> one verified dump per database (MariaDB) or one cluster dump (PostgreSQL) + counts.txt
upd_dump_all() {
    local e="$1" dir="$2" db n
    mkdir -p "$dir"; chmod 700 "$dir"; : > "$dir/counts.txt"
    if [ "$e" = "postgres" ]; then
        info "Dumping the whole PostgreSQL cluster (all databases and roles)..."
        docker exec "$PG_CONTAINER" pg_dumpall -U postgres | gzip > "$dir/cluster.sql.gz"
        [ "${PIPESTATUS[0]}" -eq 0 ] && dump_ok "$dir/cluster.sql.gz" postgres || { err "The cluster dump is incomplete."; return 1; }
    fi
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        n="$(dbx_table_count "$e" "$db")"; printf '%s|%s\n' "$db" "$n" >> "$dir/counts.txt"
        if [ "$e" = "mariadb" ]; then
            info "Dumping database '$db' ($n tables)..."
            dbx_dump mariadb "$db" --events | gzip > "$dir/db-$db.sql.gz"
            [ "${PIPESTATUS[0]}" -eq 0 ] && dump_ok "$dir/db-$db.sql.gz" mariadb || { err "The dump of '$db' is incomplete."; return 1; }
        fi
    done < <(upd_list_dbs "$e")
    ok "Safety dump complete: $dir"
}

upd_safety_backup() {   # ID
    local ts dir; ts="$(date +%F_%H%M%S)"; dir="$BACKUP_DIR/pre-update-$1-$ts"
    case "$1" in
        mariadb|postgres) container_running "$(upd_container "$1")" || return 0; upd_dump_all "$1" "$dir" ;;
        mail) mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
              tar -C "$MAIL_DIR" -czf "$BACKUP_DIR/pre-update-mail-$ts.tgz" config 2>/dev/null && ok "Mail configuration saved: $BACKUP_DIR/pre-update-mail-$ts.tgz (messages stay in $MAIL_DIR/data)" ;;
        *) return 0 ;;
    esac
}

upd_confirm() { [ "${UPD_ASSUME_YES:-no}" = "yes" ] || confirm "$@"; }

upd_wait_ok() {   # CONTAINER -> 0 when healthy (or, without a healthcheck, running steadily)
    local c="$1" i st
    for i in $(seq 1 40); do
        st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null)"
        case "$st" in
            healthy) return 0 ;;
            none) if container_running "$c" && [ "$i" -ge 5 ]; then return 0; fi ;;
        esac
        sleep 3
    done
    return 1
}

upd_post_check() {
    case "$1" in
        nginx)    docker exec "$NGINX_CONTAINER" nginx -t >/dev/null 2>&1 ;;
        mariadb)  echo 'SELECT 1;' | db_sql >/dev/null 2>&1 ;;
        postgres) echo 'SELECT 1;' | pg_sql >/dev/null 2>&1 ;;
        *)        return 0 ;;
    esac
}

# ---------- update within the same version line ---------------------------------------------------------
upd_apply() {   # ID
    local id="$1" c dir img old_id keep f
    upd_installed "$id" || { err "$(upd_label "$id") is not installed."; return 1; }
    docker_ready || { err "Docker is not ready."; return 1; }
    c="$(upd_container "$id")"; img="$(upd_image "$id")"; f="$(upd_compose "$id")"
    section "Update $(upd_label "$id")"
    if [ "$id" = "nginx" ] && upd_nginx_built; then
        explain "This nginx contains Brotli modules built on this server, so it is rebuilt instead of pulled."
        brotli_rebuild; return $?
    fi
    info "Downloading the newest build of $img ..."
    docker pull -q "$img" >/dev/null 2>&1 || { err "Could not download $img (no internet, or the registry is unreachable). Nothing was changed."; return 1; }
    if ! upd_pending "$id"; then
        ok "$(upd_label "$id") already runs the newest build of $img."
        container_running "$c" || warn "It is stopped: docker start $c"
        return 0
    fi
    case "$id" in
        mariadb|postgres) warn "The database restarts (about 10-30 seconds): sites that use it show errors meanwhile." ;;
        nginx)            warn "nginx is recreated: sites are unreachable for 1-3 seconds." ;;
        mail)             warn "The mail server restarts (about 1 minute). Incoming mail is retried by other servers, nothing is lost." ;;
        *)                info "The container restarts (a few seconds)." ;;
    esac
    explain "Before anything changes HiDeploy keeps the old image; if the new one does not start healthy it goes back to it automatically."
    upd_confirm "Update $(upd_label "$id") now?" y || { info "Cancelled."; return 0; }
    upd_safety_backup "$id" || { confirm "The safety backup failed. Continue without it?" n || return 1; }
    old_id="$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null)"
    keep="hideploy-rollback/${id}:before-update"
    [ -z "$old_id" ] || docker tag "$old_id" "$keep" >/dev/null 2>&1
    info "Starting the new version..."
    docker compose -f "$f" up -d >/dev/null 2>&1
    if upd_wait_ok "$c" && upd_post_check "$id"; then
        ok "$(upd_label "$id") now runs $(upd_running_version "$id") ($img)."
        return 0
    fi
    err "The new version did not come up correctly. Going back to the previous one..."
    if [ -n "$old_id" ] && docker tag "$keep" "$img" >/dev/null 2>&1; then
        docker compose -f "$f" up -d --force-recreate >/dev/null 2>&1
        if upd_wait_ok "$c"; then ok "Rolled back: $(upd_label "$id") runs $(upd_running_version "$id") again."; else err "Roll-back did not become healthy either. Check: docker logs $c"; fi
    else
        err "No previous image was kept. Check: docker logs $c"
    fi
    return 1
}

upd_pick_component() {   # -> UPD_PICK
    local id n=0 choice
    local -a list=()
    for id in $(upd_ids); do upd_installed "$id" && list+=("$id"); done
    [ "${#list[@]}" -gt 0 ] || { err "No shared service installed yet."; return 1; }
    echo ""
    for id in "${list[@]}"; do n=$((n+1)); printf '  %d) %-20s %s%s%s\n' "$n" "$(upd_label "$id")" "$C_DIM" "$(upd_image "$id")" "$C_RESET"; done
    read -r -p "${C_YELLOW}Select (0 = back): ${C_RESET}" choice
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#list[@]}" ] || return 1
    UPD_PICK="${list[$((choice-1))]}"
}

upd_apply_menu() { upd_pick_component || return 0; upd_apply "$UPD_PICK"; }

upd_apply_all() {
    section "Update everything that has an update ready"
    docker_ready || { err "Docker is not ready."; return 1; }
    local id img
    local -a todo=()
    for id in $(upd_ids); do
        upd_installed "$id" || continue
        if [ "$id" = "nginx" ] && upd_nginx_built; then continue; fi
        img="$(upd_image "$id")"; docker pull -q "$img" >/dev/null 2>&1 || continue
        container_running "$(upd_container "$id")" && upd_pending "$id" && todo+=("$id")
    done
    [ "${#todo[@]}" -gt 0 ] || { ok "Nothing to update."; cfg_set UPD_LAST_CHECK "$(date +%s)"; return 0; }
    echo "  Ready: ${todo[*]}"
    warn "One by one, each with its own safety backup and automatic roll-back. Each restart is short, but sites may show errors for a moment."
    confirm "Update all of them now?" y || return 0
    UPD_ASSUME_YES=yes
    for id in "${todo[@]}"; do upd_apply "$id" || warn "$(upd_label "$id") was not updated."; done
    UPD_ASSUME_YES=no
    cfg_set UPD_LAST_CHECK "$(date +%s)"
}

# ---------- upgrade to a newer MAJOR line (guided) ---------------------------------------------------------
# New data volume + dump/restore: the old volume is never modified, so going back is always possible.

upd_rollback_major() {   # COMPOSE BACKUP CONTAINER NEWVOLUME
    warn "Going back to the previous version (its data was not touched)..."
    docker compose -f "$1" down >/dev/null 2>&1
    cp "$2" "$1"
    [ -z "$4" ] || docker volume rm "$4" >/dev/null 2>&1
    docker compose -f "$1" up -d >/dev/null 2>&1
    if upd_wait_ok "$3"; then ok "The previous version runs again; nothing was lost."; else err "The previous version did not start: docker logs $3"; fi
}

upd_type_to_confirm() {   # WORD
    local a; read -r -p "${C_YELLOW}Type $1 to continue (anything else cancels): ${C_RESET}" a
    [ "$a" = "$1" ]
}

pg_write_compose() {   # IMAGE VOLUME_KEY  -> the layout of PostgreSQL 17+: PGDATA is a per-version folder under /var/lib/postgresql
    local img="$1" vol="$2" major
    major="$(image_series postgres "$img")"; [ -n "$major" ] || return 1
    mkdir -p "$PG_DIR"
    cat > "$PG_DIR/docker-compose.yml" <<EOF
services:
  postgres:
    image: ${img}
    container_name: ${PG_CONTAINER}
    restart: always
    shm_size: 128mb
    environment:
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --data-checksums"
      PGDATA: /var/lib/postgresql/${major}/docker
    command:
      - postgres
      - -c
      - max_connections=60
      - -c
      - shared_buffers=128MB
    volumes:
      - ${vol}:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - ${NETWORK}

networks:
  ${NETWORK}:
    external: true

volumes:
  ${vol}:
EOF
}

upd_major_gate() {   # ENGINE -> sets UPD_CUR_SERIES ; common checks
    local e="$1" c; c="$(upd_container "$e")"
    upd_installed "$e" || { err "$(upd_label "$e") is not installed."; return 1; }
    container_running "$c" || { err "$(upd_label "$e") must be running."; return 1; }
    UPD_CUR_IMAGE="$(upd_image "$e")"; UPD_CUR_SERIES="$(image_series "$e" "$UPD_CUR_IMAGE")"
    [ -n "$UPD_CUR_SERIES" ] || { err "Cannot tell the version line from '$UPD_CUR_IMAGE'."; return 1; }
}

upd_counts_match() {   # ENGINE DIR -> 0 when every database has the same number of tables as before
    local e="$1" dir="$2" db n now bad=0
    while IFS='|' read -r db n; do
        [ -n "$db" ] || continue
        now="$(dbx_table_count "$e" "$db")"
        if [ "$now" = "$n" ]; then echo "  $db: $now tables (same as before)"; else echo "  $db: $now tables, expected $n"; bad=1; fi
    done < "$dir/counts.txt"
    return "$bad"
}

upd_postgres_major() {
    section "Upgrade PostgreSQL to a newer major version"
    upd_major_gate postgres || return 1
    local cur="$UPD_CUR_SERIES" ts dir newimg newmajor bak oldvol newvol variant log errs
    explain "Current: PostgreSQL $cur ($UPD_CUR_IMAGE). A major upgrade changes the data format, so HiDeploy does it by dump and restore:" \
            "  1. a complete dump of all databases and roles   2. a NEW empty data volume with the new version" \
            "  3. restore + check that every table count matches   4. the OLD volume stays untouched until you delete it." \
            "If anything fails, the old version is started again automatically."
    variant="$(image_tag "$UPD_CUR_IMAGE")"; variant="${variant#*-}"; [ "$variant" != "$(image_tag "$UPD_CUR_IMAGE")" ] || variant="bookworm"
    choose_tag "PostgreSQL" "18-$variant" "Pick the new major version. Keeping the same Debian base ('$variant') avoids sorting-order changes in your indexes." \
        '^[0-9]+(\.[0-9]+)?(-[a-z0-9.]+)?$' \
        "18-$variant|newest - $(eol_plain postgres 18)" "17-$variant|$(eol_plain postgres 17)" "16-$variant|$(eol_plain postgres 16)" || return 0
    newimg="postgres:$CHOSEN_TAG"; newmajor="$(image_series postgres "$newimg")"
    [ -n "$newmajor" ] || { err "The tag must start with the major version."; return 1; }
    [ "$newmajor" -gt "$cur" ] || { err "PostgreSQL cannot be downgraded: the new version must be higher than $cur."; return 1; }
    verify_image "$newimg" || return 1
    warn "All sites that use PostgreSQL will be offline while this runs (minutes; longer for big databases)."
    explain "Free disk space needed: roughly 3x the size of your data (volume + dump + new volume)."
    upd_type_to_confirm UPGRADE || { info "Cancelled."; return 0; }
    ts="$(date +%F_%H%M%S)"; dir="$BACKUP_DIR/upgrade-postgres-$cur-to-$newmajor-$ts"
    upd_dump_all postgres "$dir" || { err "No dump, no upgrade. Nothing was changed."; return 1; }
    docker pull -q "$newimg" >/dev/null 2>&1 || docker image inspect "$newimg" >/dev/null 2>&1 || { err "Could not download $newimg. Nothing was changed."; return 1; }
    bak="$PG_DIR/docker-compose.yml.bak-$ts"; cp "$PG_DIR/docker-compose.yml" "$bak"
    oldvol="$(upd_volume_of "$PG_CONTAINER" /var/lib/postgresql/data)"; [ -n "$oldvol" ] || oldvol="$(upd_volume_of "$PG_CONTAINER" /var/lib/postgresql)"
    info "Stopping the old PostgreSQL (its data stays in volume '$oldvol')..."
    docker compose -f "$PG_DIR/docker-compose.yml" down >/dev/null 2>&1
    pg_write_compose "$newimg" "postgres_data_v${newmajor}" || { err "Could not write the new compose file."; cp "$bak" "$PG_DIR/docker-compose.yml"; docker compose -f "$PG_DIR/docker-compose.yml" up -d >/dev/null 2>&1; return 1; }
    info "Starting PostgreSQL $newmajor on a new data volume..."
    docker compose -f "$PG_DIR/docker-compose.yml" up -d >/dev/null 2>&1
    newvol="$(upd_volume_of "$PG_CONTAINER" /var/lib/postgresql)"
    if ! upd_wait_ok "$PG_CONTAINER"; then err "PostgreSQL $newmajor did not start."; upd_rollback_major "$PG_DIR/docker-compose.yml" "$bak" "$PG_CONTAINER" "$newvol"; return 1; fi
    info "Restoring everything (this is the long step)..."
    log="$dir/restore.log"
    gzip -dc "$dir/cluster.sql.gz" | docker exec -i "$PG_CONTAINER" psql -U postgres -X -q -v ON_ERROR_STOP=0 -d postgres >/dev/null 2>"$log"
    errs="$(grep 'ERROR:' "$log" 2>/dev/null | grep -vc 'role "postgres" already exists')"; errs="${errs:-0}"
    [ "$errs" -eq 0 ] || warn "$errs message(s) in $log (the table check below decides whether they matter)."
    info "Checking every database..."
    if upd_counts_match postgres "$dir"; then
        docker exec "$PG_CONTAINER" vacuumdb -U postgres --all --analyze-only >/dev/null 2>&1 || true
        cfg_set OLD_VOLUME_POSTGRES "$oldvol"
        ok "PostgreSQL now runs $(upd_running_version postgres)."
        explain "The old data is still in volume '$oldvol' and the dump in $dir." \
                "When you have seen your sites work for a few days: main menu 11 -> Remove old data from a major upgrade."
        return 0
    fi
    err "The table counts do not match: the upgrade is cancelled."
    upd_rollback_major "$PG_DIR/docker-compose.yml" "$bak" "$PG_CONTAINER" "$newvol"
    return 1
}

upd_mariadb_major() {
    section "Upgrade MariaDB to a newer version line"
    upd_major_gate mariadb || return 1
    local cur="$UPD_CUR_SERIES" ts dir newimg newser bak oldvol newvol bp mc skip row db user pass f unmanaged="" managed_names=""
    explain "Current: MariaDB $cur ($UPD_CUR_IMAGE). HiDeploy upgrades by dump and restore into a NEW data volume:" \
            "  1. a verified dump of every database   2. a new empty server of the new version   3. databases and users are" \
            "  re-created from each project's .env, the dumps are loaded and every table count is compared." \
            "The old volume stays untouched until you delete it. If anything fails, the old version is started again."
    choose_tag "MariaDB" "12.3" "Pick the new line. LTS lines are supported for years; do not pick a rolling line (for example 13.0) for servers." \
        '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
        "12.3|newest LTS - $(eol_plain mariadb 12.3)" "11.8|LTS - $(eol_plain mariadb 11.8)" "10.11|LTS - $(eol_plain mariadb 10.11)" || return 0
    newimg="mariadb:$CHOSEN_TAG"; newser="$(image_series mariadb "$newimg")"
    [ "$(series_key "$newser")" -gt "$(series_key "$cur")" ] || { err "MariaDB cannot be downgraded: the new line must be newer than $cur."; return 1; }
    verify_image "$newimg" || return 1
    while IFS='|' read -r db user pass; do managed_names="$managed_names $db "; done < <(upd_managed_dbs mariadb)
    while IFS= read -r db; do [ -z "$db" ] || [[ "$managed_names" == *" $db "* ]] || unmanaged="$unmanaged $db"; done < <(upd_list_dbs mariadb)
    if [ -n "$unmanaged" ]; then
        warn "Databases that no HiDeploy project uses:$unmanaged"
        explain "Their DATA is carried over, but their database users and privileges are not (HiDeploy only knows its own projects' users)."
        confirm "Continue anyway?" n || { info "Cancelled."; return 0; }
    fi
    warn "All sites that use MariaDB will be offline while this runs (minutes; longer for big databases)."
    explain "Free disk space needed: roughly 3x the size of your data."
    upd_type_to_confirm UPGRADE || { info "Cancelled."; return 0; }
    ts="$(date +%F_%H%M%S)"; dir="$BACKUP_DIR/upgrade-mariadb-$cur-to-$newser-$ts"
    upd_dump_all mariadb "$dir" || { err "No dump, no upgrade. Nothing was changed."; return 1; }
    docker pull -q "$newimg" >/dev/null 2>&1 || docker image inspect "$newimg" >/dev/null 2>&1 || { err "Could not download $newimg. Nothing was changed."; return 1; }
    bp="$(perf_db_current bp)"; mc="$(perf_db_current mc)"; skip="$(perf_db_current skip)"
    bak="$DB_DIR/docker-compose.yml.bak-$ts"; cp "$DB_DIR/docker-compose.yml" "$bak"
    oldvol="$(upd_volume_of "$DB_CONTAINER" /var/lib/mysql)"
    info "Stopping the old MariaDB (its data stays in volume '$oldvol')..."
    docker compose -f "$DB_DIR/docker-compose.yml" down >/dev/null 2>&1
    MARIADB_IMAGE="$newimg"
    mariadb_write_compose "${bp:-128M}" "${mc:-60}" "${skip:-no}" "mariadb_data_v${newser//./_}"
    info "Starting MariaDB $newser on a new data volume..."
    docker compose -f "$DB_DIR/docker-compose.yml" up -d >/dev/null 2>&1
    newvol="$(upd_volume_of "$DB_CONTAINER" /var/lib/mysql)"
    if ! perf_wait_db; then err "MariaDB $newser did not start."; MARIADB_IMAGE="$UPD_CUR_IMAGE"; upd_rollback_major "$DB_DIR/docker-compose.yml" "$bak" "$DB_CONTAINER" "$newvol"; return 1; fi
    info "Re-creating users and loading the databases..."
    while IFS='|' read -r db user pass; do
        dbx_provision mariadb "$db" "$user" "$pass" || { err "Could not create '$db'."; MARIADB_IMAGE="$UPD_CUR_IMAGE"; upd_rollback_major "$DB_DIR/docker-compose.yml" "$bak" "$DB_CONTAINER" "$newvol"; return 1; }
    done < <(upd_managed_dbs mariadb)
    for f in "$dir"/db-*.sql.gz; do
        [ -e "$f" ] || continue
        echo "  loading $(basename "$f")"
        if ! gzip -dc "$f" | docker exec -i "$DB_CONTAINER" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot'; then
            err "Loading $(basename "$f") failed."; MARIADB_IMAGE="$UPD_CUR_IMAGE"
            upd_rollback_major "$DB_DIR/docker-compose.yml" "$bak" "$DB_CONTAINER" "$newvol"; return 1
        fi
    done
    info "Checking every database..."
    if upd_counts_match mariadb "$dir"; then
        cfg_set OLD_VOLUME_MARIADB "$oldvol"
        ok "MariaDB now runs $(upd_running_version mariadb)."
        explain "The old data is still in volume '$oldvol' and the dumps in $dir." \
                "When you have seen your sites work for a few days: main menu 11 -> Remove old data from a major upgrade."
        return 0
    fi
    err "The table counts do not match: the upgrade is cancelled."
    MARIADB_IMAGE="$UPD_CUR_IMAGE"
    upd_rollback_major "$DB_DIR/docker-compose.yml" "$bak" "$DB_CONTAINER" "$newvol"
    return 1
}

upd_redis_major() {
    section "Upgrade Redis to a newer major version"
    upd_major_gate redis || return 1
    local cur="$UPD_CUR_SERIES" ts dir newimg newmajor bak before after pass f="$REDIS_DIR/docker-compose.yml"
    explain "Current: Redis $cur ($UPD_CUR_IMAGE). Redis keeps cache, sessions and queued jobs; the new version reads the same files." \
            "HiDeploy saves a copy of the data first and goes back automatically if the new version does not start."
    choose_tag "Redis" "8-alpine" "Redis 8 is the current line." '^[0-9]+(\.[0-9]+)*(-[a-z0-9.]+)?$' "8-alpine|current" "7-alpine|previous line" || return 0
    newimg="redis:$CHOSEN_TAG"; newmajor="$(image_series redis "$newimg")"
    [ "$newmajor" -gt "$cur" ] || { err "The new version must be higher than $cur."; return 1; }
    verify_image "$newimg" || return 1
    warn "Redis restarts (a few seconds): queue workers and sessions reconnect on their own."
    upd_type_to_confirm UPGRADE || { info "Cancelled."; return 0; }
    ts="$(date +%F_%H%M%S)"; dir="$BACKUP_DIR/upgrade-redis-$cur-to-$newmajor-$ts"; mkdir -p "$dir"; chmod 700 "$dir"
    pass="$(redis_pass)"
    before="$(docker exec -e "REDISCLI_AUTH=$pass" "$REDIS_CONTAINER" redis-cli DBSIZE 2>/dev/null | tr -dc '0-9')"
    docker exec -e "REDISCLI_AUTH=$pass" "$REDIS_CONTAINER" redis-cli SAVE >/dev/null 2>&1 || true
    docker run --rm --entrypoint tar -v "$(upd_volume_of "$REDIS_CONTAINER" /data):/data:ro" -v "$dir:/out" "$UPD_CUR_IMAGE" czf /out/redis-data.tgz -C /data . 2>/dev/null \
        && ok "Data copy saved: $dir/redis-data.tgz" || warn "Could not copy the data (continuing: Redis only holds cache and queues)."
    docker pull -q "$newimg" >/dev/null 2>&1 || docker image inspect "$newimg" >/dev/null 2>&1 || { err "Could not download $newimg. Nothing was changed."; return 1; }
    bak="$f.bak-$ts"; cp "$f" "$bak"
    sed -i "s|^    image: .*|    image: $newimg|" "$f"
    docker compose -f "$f" up -d >/dev/null 2>&1
    after="$(docker exec -e "REDISCLI_AUTH=$pass" "$REDIS_CONTAINER" redis-cli DBSIZE 2>/dev/null | tr -dc '0-9')"
    if upd_wait_ok "$REDIS_CONTAINER" && [ "${after:-x}" = "${before:-y}" ]; then
        ok "Redis now runs $(upd_running_version redis) (keys before: $before, after: $after)."
        return 0
    fi
    err "Redis $newmajor did not start with the same data (keys before: ${before:-?}, after: ${after:-?}). Going back."
    docker compose -f "$f" down >/dev/null 2>&1; cp "$bak" "$f"; docker compose -f "$f" up -d >/dev/null 2>&1
    upd_wait_ok "$REDIS_CONTAINER" && ok "The previous Redis runs again." || err "Check: docker logs $REDIS_CONTAINER"
    return 1
}

upd_major_menu() {
    local c
    echo ""
    explain "A newer VERSION LINE changes the data format, so it is a guided procedure with its own safety dump." \
            "Sites that use the database are offline while it runs. Do it at a quiet time, and ideally after a full backup (main menu 6)."
    echo " 1) PostgreSQL   (now: $(image_series postgres "$(upd_image postgres)" | sed 's/^$/not installed/'))"
    echo " 2) MariaDB      (now: $(image_series mariadb "$(upd_image mariadb)" | sed 's/^$/not installed/'))"
    echo " 3) Redis        (now: $(image_series redis "$(upd_image redis)" | sed 's/^$/not installed/'))"
    echo " 0) Back"
    read -r -p "Select: " c
    case "$c" in 1) upd_postgres_major ;; 2) upd_mariadb_major ;; 3) upd_redis_major ;; *) return 0 ;; esac
}

# ---------- old data left behind by a major upgrade -----------------------------------------------------------
upd_cleanup_old() {
    section "Remove old data from a major upgrade"
    local e vol found=0 name
    explain "After a major upgrade the previous data volume is kept as a safety net. Delete it only when your sites have worked well for a while." \
            "Dumps in $BACKUP_DIR are separate files: delete them yourself when you do not need them any more."
    for e in postgres mariadb; do
        name="$(cfg_get "OLD_VOLUME_$(tr a-z A-Z <<<"$e")" || true)"
        [ -n "$name" ] || continue
        docker volume inspect "$name" >/dev/null 2>&1 || { cfg_unset "OLD_VOLUME_$(tr a-z A-Z <<<"$e")"; continue; }
        found=1
        printf '  %s: old data volume %s\n' "$(upd_label "$e")" "$name"
        if upd_type_to_confirm DELETE; then
            docker volume rm "$name" >/dev/null 2>&1 && { ok "Removed $name."; cfg_unset "OLD_VOLUME_$(tr a-z A-Z <<<"$e")"; } || err "Could not remove it (is a container still using it?)."
        else info "Kept."; fi
    done
    [ "$found" -eq 1 ] || ok "No old data volumes are recorded."
}

# ---------- project runtimes (PHP, Node) -----------------------------------------------------------------------
upd_projects_list() {   # -> fills UPD_PROJ (array of paths) and prints the table
    UPD_PROJ=()
    mapfile -t UPD_PROJ < <(find "$PROJECTS_DIR" -mindepth 2 -maxdepth 2 -name .deploy.env -printf '%h\n' 2>/dev/null | sort)
    [ "${#UPD_PROJ[@]}" -gt 0 ] || { err "No projects deployed yet."; return 1; }
    local i=0 p typ v src run
    printf '\n  %-4s %-32s %-8s %-10s %s\n' "#" "DOMAIN" "TYPE" "VERSION" "SUPPORT"
    for p in "${UPD_PROJ[@]}"; do
        i=$((i+1))
        typ="$( . "$p/.deploy.env" 2>/dev/null; echo "${PROJECT_TYPE:-laravel}" )"
        if [ "$typ" = "nextjs" ]; then
            v="$( . "$p/.deploy.env" 2>/dev/null; echo "${NODE_VERSION:-}" )"; [ -n "$v" ] || v="$(dockerfile_node_version "$p")"
            printf '  %-4s %-32s %-8s %-10s %s\n' "$i" "$(basename "$p")" "$typ" "node ${v:-?}" "$(eol_text node "${v%%.*}")"
        else
            v="$( . "$p/.deploy.env" 2>/dev/null; echo "${PHP_VERSION:-}" )"; [ -n "$v" ] || v="$(dockerfile_php_version "$p")"
            printf '  %-4s %-32s %-8s %-10s %s\n' "$i" "$(basename "$p")" "$typ" "php ${v:-?}" "$(eol_text php "$(cut -d. -f1,2 <<<"$v")")"
        fi
    done
}

upd_project_change() {   # PATH
    local path="$1" typ old new key conf
    typ="$( . "$path/.deploy.env" 2>/dev/null; echo "${PROJECT_TYPE:-laravel}" )"
    if [ "$typ" = "nextjs" ]; then key="NODE_VERSION"; else key="PHP_VERSION"; fi
    if ! dockerfile_has_arg "$path" "$key"; then
        warn "This project's Dockerfile has the version written into it (generated by an older HiDeploy), so it cannot be changed from the server."
        explain "Fix: main menu 3 -> Generate Project Files (choose the version there), copy the new files into your repository, commit and push." \
                "From then on the version can be changed here without touching git."
        return 0
    fi
    old="$( . "$path/.deploy.env" 2>/dev/null; eval "echo \"\${$key:-}\"" )"
    if [ "$typ" = "nextjs" ]; then [ -n "$old" ] || old="$(dockerfile_node_version "$path")"; pick_node "$path" "$old" || return 0; new="$PICK_NODE"
    else [ -n "$old" ] || old="$(dockerfile_php_version "$path")"; pick_php "$path" "$old" || return 0; new="$PICK_PHP"; fi
    [ "$new" != "$old" ] || { ok "That is the version already in use."; return 0; }
    warn "Changing the runtime rebuilds the container. Test big jumps (for example PHP 8.3 -> 8.5) on a copy of the project first."
    confirm "Rebuild and deploy $(basename "$path") with $new now?" y || { info "Cancelled."; return 0; }
    conf="$path/.deploy.env.bak-$(date +%s)"; cp "$path/.deploy.env" "$conf"
    env_set "$path/.deploy.env" "$key" "$new"
    if deploy_project "$path" no; then rm -f "$conf"; ok "Now built with $new."; return 0; fi
    err "The deployment with $new failed: going back to ${old:-the previous version}."
    cp "$conf" "$path/.deploy.env"; rm -f "$conf"
    deploy_project "$path" no || err "The old version did not deploy either: Manage Projects -> this project -> Deployments."
    return 1
}

upd_projects_menu() {
    upd_projects_list || return 0
    local n; read -r -p "${C_YELLOW}Change the version of project number (0 = back): ${C_RESET}" n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#UPD_PROJ[@]}" ] || return 0
    upd_project_change "${UPD_PROJ[$((n-1))]}"
}

upd_self_update() {
    section "Update HiDeploy itself"
    explain "Installs the newest HiDeploy from GitHub ($HIDEPLOY_REPO). Your settings and projects are not touched."
    confirm "Update HiDeploy now?" y || return 0
    curl -fsSL "https://raw.githubusercontent.com/${HIDEPLOY_REPO}/main/install.sh" | bash
}

menu_updates() {
    local c
    while true; do
        clear; banner "11) Updates and versions" "$C_CYAN"
        explain "Versions checked by this script: $CATALOG_CHECKED (every tag is verified on the registry before it is used)."
        echo ""; upd_overview; echo ""
        echo " 1) Check for updates now (downloads the newest builds, installs nothing)"
        echo " 2) Update one component (same version line: safe, with backup and automatic roll-back)"
        echo " 3) Update ALL components that have an update ready"
        echo " 4) Upgrade to a NEWER version line (PostgreSQL / MariaDB / Redis: guided, with dump and roll-back)"
        echo " 5) Projects: see and change the PHP / Node version of each project"
        echo " 6) Remove old data left by a major upgrade"
        echo " 7) Update HiDeploy itself"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item upd_check_all ;;
            2) upd_apply_menu; pause ;;
            3) run_item upd_apply_all ;;
            4) upd_major_menu; pause ;;
            5) upd_projects_menu; pause ;;
            6) run_item upd_cleanup_old ;;
            7) run_item upd_self_update ;;
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
        echo " 7) Firewall (optional, with lockout protection)"
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
        echo " 2) Install MariaDB container (stores the databases of projects that use MariaDB)"
        echo " 3) Enable SSL auto-renew"
        echo " 4) Show status"
        echo " 5) phpMyAdmin (optional: web UI for your databases, on its own domain)"
        echo " 6) Redis (optional: fast cache, sessions and queues for all projects)"
        echo " 7) PostgreSQL (optional second database server; each project chooses MariaDB or PostgreSQL)"
        echo " 8) Brotli compression (optional: smaller pages, faster loading; nginx image built for you)"
        echo " A) Run ALL of the above in order"
        echo " 0) Back"
        read -r -p "Select: " c; echo ""
        case "$c" in
            1) run_item step_nginx_install ;;   2) run_item step_mariadb_install ;;
            3) run_item step_renew_enable ;;    4) run_item services_status ;;
            5) menu_phpmyadmin ;;
            6) menu_redis ;;
            7) run_item step_postgres_install ;;
            8) menu_brotli ;;
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
  sudo hideploy security-check  print the security report (firewall, fail2ban, updates, SSH, ports, files)
  sudo hideploy notify-run  send waiting notifications and check the server (the every-minute job calls this)
  sudo hideploy notify-test send a test notification to every switched-on channel
EOF
}

main() {
    load_installed_images
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
        notify-run)
            [ "$EUID" -eq 0 ] || { echo "Run as root: sudo hideploy notify-run" >&2; exit 1; }
            nf_run
            exit 0 ;;
        notify-test)
            [ "$EUID" -eq 0 ] || { echo "Run as root: sudo hideploy notify-test" >&2; exit 1; }
            nf_test
            exit $? ;;
        security-check)
            [ "$EUID" -eq 0 ] || { echo "Run as root: sudo hideploy security-check" >&2; exit 1; }
            sec_report
            [ "$SEC_ISSUES" -eq 0 ]
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
        echo " 4) Deploy New Project  (for every new site)"
        echo " 5) Manage Projects             (deploy, logs, backup, SSL, remove)"
        echo " 6) Backups                     (automatic, encrypted, copied off the server)"
        echo " 7) Performance tuning          (nginx, MariaDB, PHP-FPM: faster pages, less cold start)"
        echo " 8) Security                    (firewall, fail2ban, automatic security updates, SSH, checks)"
        echo " 9) Email                       (own mail server for all your domains: mailboxes, webmail)"
        echo "10) Notifications               (alerts by email and Telegram: deployments, backups, stopped services)"
        echo "11) Updates and versions        (check updates, upgrade PostgreSQL/MariaDB/Redis, PHP and Node per project)"
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
            8) menu_security ;;
            9) menu_mail ;;
            10) menu_notify ;;
            11) menu_updates ;;
            0) ok "Bye."; exit 0 ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# Run the menu only when executed directly (allows sourcing for tests)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
