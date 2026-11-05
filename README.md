# HiDeploy

**Deploy GitLab-hosted Laravel and Next.js projects to your own server, one command and one menu, as many projects as you like.**

HiDeploy prepares a fresh Ubuntu server once, then deploys and manages Laravel (PHP) and Next.js (Node) projects from a single interactive menu. After the first deployment, every `git push` to your branch redeploys automatically through GitLab CI.

```
git push  →  GitLab pipeline  →  build  →  migrate  →  live
```

> **Scope:** HiDeploy targets **Laravel (PHP)** and **Next.js (Node)** projects hosted on **GitLab** (it uses GitLab Runner for CI/CD). The tool itself is hosted on GitHub.

---

## Why HiDeploy?

- **Self-hosted.** No vendor lock-in. Your code, your server.
- **Light on resources.** One shared nginx and one shared MariaDB serve every project; each project is a single container (php-fpm + queue worker + scheduler).
- **No CI variables.** Server-specific settings live in `.deploy.env` on the server, outside git.
- **No `chmod 777`.** Containers run with the same UID/GID as the runner user, so permissions just work.
- **Guided.** Every step explains what it does and suggests what to do next.

---

## Quick install

On an Ubuntu server, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/hesami/hideploy/main/install.sh | sudo bash
```

Then start it:

```bash
sudo hideploy
```

Prefer to read the code first? Download, inspect, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/hesami/hideploy/main/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

To install a specific release instead of the latest `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/hesami/hideploy/main/install.sh | sudo HIDEPLOY_REF=v1.0.0 bash
```

### Commands

```bash
sudo hideploy            # interactive menu
hideploy --version       # show the installed version
hideploy --help          # show help
sudo hideploy update     # install the latest version (your projects are not touched)
sudo hideploy backup-run # run one backup now (the nightly job calls this)
sudo hideploy cleanup-run # run the safe disk cleanup now (the weekly job calls this)
```

### Manual install

```bash
git clone https://github.com/hesami/hideploy.git
cd hideploy
sudo install -m 755 hideploy.sh /usr/local/bin/hideploy
```

---

## Requirements

- An **Ubuntu** server with root access (tested on Ubuntu; Debian should work but is untested)
- A **domain** whose A record points to the server
- A **GitLab** repository (SSH URL) containing a Laravel or Next.js project
- A GitLab runner token (created in GitLab: *Settings → CI/CD → Runners → New project runner*)

HiDeploy installs Docker, GitLab Runner, nginx and MariaDB for you.

---

## First run

```
1) Prepare Server              →  Docker, GitLab Runner, shared network
2) Shared Services             →  nginx + MariaDB + SSL auto-renew (+ optional phpMyAdmin)
3) Generate Project Files      →  Dockerfile, compose, CI for your repository
4) Deploy New Project          →  the deployment wizard (Laravel or Next.js)
5) Manage Projects             →  deploy, logs, backups, restore, SSL, remove
6) Backups                     →  automatic, encrypted, copied off the server
7) Performance tuning          →  nginx, MariaDB, PHP-FPM sized for your server, cold-start diagnosis
```

On a brand-new server choose **`1` → `A`** (run everything), then **`2` → `A`**. Each step checks what is already done and skips it, so re-running is safe. The top of the menu always shows the server status and the recommended next step.

---

## Deploying a project

Choose **3) Generate Project Files** (pick Laravel or Next.js), copy the four generated files into your project, commit and push them. Then choose **4) Deploy New Project**. For Laravel the wizard handles:

1. Domain and DNS check
2. Repository access (read-only deploy key)
3. Clone to `/var/www/projects/<domain>`
4. Server settings in `.deploy.env` (memory limit, frontend build, database yes/no)
5. Project files check
6. Database and user in the shared MariaDB (suggested values, or your own; optional)
7. `.env` with production defaults
8. Laravel Passport keys (if the project uses it)
9. Build, Composer, migrations, caches
10. nginx virtual host and a Let's Encrypt certificate

After that, `git push` to the configured branch deploys automatically.

### Deploy key for several projects

The server uses **one SSH key** for all projects. Add it as a read-only *Deploy key* to the **first** project. For the next projects GitLab says *"Fingerprint has already been taken"*; do not add it again. Open *Settings → Repository → Deploy keys → Privately accessible deploy keys* and click **Enable**.

---

## Features

| Feature | Where |
|---|---|
| Shared nginx + MariaDB, one container per project | Shared Services |
| **Next.js projects** (standalone build, pnpm / npm / yarn, health-checked deployments) | Deploy New Project → Next.js |
| **Performance tuning** sized from a scan of your server (nginx, MariaDB, PHP-FPM) and a first-load diagnosis | Performance tuning |
| Automatic SSL issuance and daily renewal | Shared Services / SSL Management |
| SSL overview: expiry dates, days left, file paths, forced renewal | Manage Projects → SSL management |
| Frontend (Vite) build in a temporary Node container; npm, pnpm or yarn detected from the lock file | Project menu → Frontend assets |
| Projects without a database; add one later | Wizard / Project menu → Add a database |
| One-off database backup (`.sql.gz`) | Project menu → Backup |
| **Automatic encrypted backups** every night: all databases, project files, SSL certificates and server config; copied to another server (SSH/rsync) and/or an S3 bucket (Arvan Cloud or any S3-compatible); automatic cleanup of old copies | Backups |
| Database restore from `.sql` / `.sql.gz` (replace or add; MySQL 8 dumps converted automatically) | Project menu → Restore |
| phpMyAdmin on its own domain: HTTPS, Basic Auth, optional IP allow-list, start/stop on demand | Shared Services → phpMyAdmin |
| **Deployment history and one-step rollback** to an earlier version of the code | Project menu → Deployments |
| **Maintenance mode during every deployment**: visitors see a friendly page instead of errors; manual on/off switch | automatic / Project menu → Deployments |
| **Disk usage warning and safe cleanup** (Docker leftovers, old logs, package cache), optional weekly automatic cleanup | Manage Projects → Disk usage and cleanup |
| Logs, shell, artisan, `.env` editing, manual deploy | Project menu |

---

## How it works

```
                Internet
                   │
        ┌──────────▼──────────┐
        │    global-nginx     │   ports 80 + 443
        └──────────┬──────────┘
                   │  web_network (Docker bridge)
       ┌───────────┼────────────────┐
       ▼           ▼                ▼
  ┌─────────┐ ┌─────────┐      ┌─────────┐
  │project 1│ │project 2│ ...  │project N│   php-fpm + queue + scheduler
  └────┬────┘ └────┬────┘      └────┬────┘
       └───────────┴────────────────┘
                   ▼
        ┌─────────────────────┐
        │   global-mariadb    │   shared, not exposed to the internet
        └─────────────────────┘
```

| What | Where |
|---|---|
| Project code | `/var/www/projects/<domain>` |
| Shared infrastructure | `/var/www/infrastructure` |
| SSL certificates | `/var/www/infrastructure/nginx/letsencrypt` |
| Database backups (manual) | `/var/backups/hideploy` |
| Automatic backups (local copies) | `/var/backups/hideploy/auto` |
| Performance settings / nginx tuning file | `/var/www/infrastructure/performance.env` / `.../nginx/conf.d/10-hideploy-performance.conf` |
| Backup settings, passphrase, destination keys | `/var/www/infrastructure/backup` (root only; never included in a backup) |
| Backup schedule / log | `/etc/cron.d/hideploy-backup` / `/var/log/hideploy-backup.log` |
| Deployment history | `/var/www/projects/<domain>/.deploy.history` |
| Weekly cleanup schedule / log | `/etc/cron.d/hideploy-cleanup` / `/var/log/hideploy-cleanup.log` |
| Generated project files | `/root/hideploy-templates/<domain>` |
| SSL renewal | `/usr/local/bin/hideploy-renew-ssl` + `/etc/cron.d/hideploy-ssl-renew` (daily 03:17) |

Project code stays on the server disk, so `.env` and logs are easy to read and edit. The four files you commit to your repository are generic; server-specific values are in `/var/www/projects/<domain>/.deploy.env`.

---

## Next.js projects

In **Deploy New Project** choose *Next.js*. Each project is one container running the compiled **standalone** app (`node server.js`); nginx forwards the domain to it. Unlike Laravel, the code lives **inside the image**, so a deployment builds a new image while the current version keeps serving, then waits for the new container to be **healthy**.

**Your project needs:**
- `output: 'standalone'` in `next.config.js` / `.mjs` / `.ts`
- a committed lock file (`pnpm-lock.yaml`, `package-lock.json` or `yarn.lock`)
- the four generated files (menu 3 -> *Next.js*): a multi-stage `Dockerfile`, `docker-compose.prod.yml`, `.dockerignore`, `.gitlab-ci.yml`

**pnpm is the default** (fast, with a build cache). To migrate from npm: run `pnpm import` locally, commit `pnpm-lock.yaml`, delete `package-lock.json`. The wizard detects your lock file and warns if it does not match the Dockerfile.

**Environment variables.** The server keeps `/var/www/projects/<domain>/.env` (never in git). The container reads it at start; edit it from the project menu and the container is recreated. Variables starting with `NEXT_PUBLIC_` are baked into the JavaScript at **build** time, so change them and then run *Manual deploy* (or push). Write a literal `$` as `$$`.

**Database (optional).** Same shared MariaDB, own user per project. HiDeploy writes `DATABASE_URL` (password URL-encoded) plus `DB_HOST`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`; backup, restore and the phpMyAdmin tool work as for Laravel.

**Same safety net.** History, one-step rollback, nightly encrypted backups, SSL and disk cleanup all work for Next.js. While the container restarts, nginx shows the friendly maintenance page; a failed build leaves the previous version running. Memory: a Next.js app needs about 256-512 MB at runtime, and the **build needs about 1 GB** (add swap on small servers).

---

## Performance tuning

Open **7) Performance tuning**. **Nothing is applied automatically**: until you apply a profile, your nginx configuration and containers stay exactly as they were. Suggested values come from a scan of the server (CPU cores, RAM, swap, disk type, your projects' memory limits); press Enter to accept a suggestion or type your own.

1. **Scan:** shows what the server has and the suggested settings.
2. **Nginx tuning:** compression level, keep-alive, `open_file_cache`, browser caching for Laravel static files (`/build/` is immutable), and an nginx cache for Next.js `/_next/static/` files that keeps serving while a container restarts. nginx tests the new configuration first and keeps the old one if it is rejected. *Option 6 removes it again.*
3. **MariaDB tuning:** buffer pool and connection limits, plus `skip-name-resolve` (avoids a reverse-DNS lookup on every connection, a classic cause of multi-second delays). MariaDB restarts for 10-30 seconds, so HiDeploy asks first and restores the previous settings if it does not come back healthy.
4. **PHP-FPM tuning (Laravel):** `ondemand` (light on RAM, but the first visit after a quiet moment waits for a worker) or `dynamic` (keeps workers ready). Needs the newest generated Dockerfile and compose file (menu 3); older projects keep working unchanged.
5. **Diagnosis:** measures each site (DNS, connection, first byte, database connection) and tells you whether you see a *cold start*, a slow database, slow code, or a DNS/IPv6/network problem.

---

## Deployments, rollback and maintenance mode

**Maintenance mode.** Before the code is replaced, the site is put in Laravel maintenance mode (`artisan down`), so visitors see a friendly "we'll be right back" page that refreshes itself, instead of errors from half-updated code. When the deployment succeeds, the site comes back automatically. If it **fails**, the site is left in maintenance mode on purpose and the log tells you how to continue. While the container restarts, nginx itself shows the same kind of page (`/var/www/infrastructure/nginx/conf.d/hideploy-maintenance.html`; you can edit it, it is never overwritten).

**History.** Every deployment (pipeline or manual) records one line in `/var/www/projects/<domain>/.deploy.history`: time, version, result (`ok`, `failed`, `rollback`) and the commit message. See it in *Project menu → Deployments → Deployment history*.

**Rollback.** *Project menu → Deployments → Roll back* lists the last working versions, offers a database backup first, then switches the code, rebuilds and brings the site back. Things to know:

- It rolls back the **code only**. Database changes are not undone; HiDeploy warns you if migrations were added after the version you pick (restore a backup if the old code cannot live with them).
- It is **temporary**: the next `git push` deploys the newest code again. To keep the old version, `git revert` the bad commit and push, or fix the bug and push.

**Upgrading existing projects.** After updating HiDeploy: run *Manage Projects → Refresh nginx configuration of ALL projects*, and for the pipeline features regenerate `.gitlab-ci.yml` (main menu 3), copy it into your project and push. Until then, manual deployments from the menu already have maintenance mode and history, and rollback falls back to the git history on the server.

---

## Disk usage and cleanup

The menu shows the disk usage in the status table (yellow from 80%, red from 90%). *Manage Projects → Disk usage and cleanup* offers:

- **Safe cleanup:** unused Docker images, old build cache, system logs above 200 MB, package cache and Laravel logs older than 14 days. It never touches Docker volumes (your databases), running containers, project code or `.env` files.
- **Deep cleanup:** removes all Docker images no container uses (slower next deploy or backup, because tools are downloaded again).
- Large log files, old manual database backups, and an optional **weekly automatic safe cleanup** (Sundays 04:10, log in `/var/log/hideploy-cleanup.log`).

Every successful deployment also removes the dangling images it leaves behind.

---

## Automatic backups

Open **6) Backups** and follow the recommended order shown at the top of the menu:

1. **Passphrase.** Every backup file is encrypted (AES-256) *before* it leaves the server. HiDeploy shows the passphrase once: **save it outside the server**. Without it nobody can open your backups, and if the server dies the copy stored on it dies too.
2. **Destinations** (use one or both):
   - **SSH server:** HiDeploy creates a dedicated key and prints the exact commands to paste on the backup server (a dedicated user, `rsync`, the public key). Uploads go to a temporary name and are renamed when complete.
   - **S3 bucket:** presets for **Arvan Cloud** (Iran Central, Iran Central HiOps SSD, Iran North-West, Western Europe) or any S3-compatible endpoint. Create a *private* bucket and an access key first. Uploads use `rclone` in a temporary container; the keys are kept in a root-only file.
3. **Schedule and retention:** time of day, days to keep locally (default 7) and remotely (default 30). The newest 3 backups are never deleted.
4. **Run one now** to verify everything end to end, then turn the **nightly backup on**.

Each backup contains, per run: one file per project database, the project files (`.env`, `.deploy.env`, `storage/app` uploads, Passport keys), the server configuration (nginx, SSL certificates, runner settings) and a `SHA256SUMS` integrity file.

**Restoring.** *Backups → Restore a database* lists local or remote backups, verifies integrity, decrypts and hands the dump to the normal restore flow (with an automatic safety backup). On a **new server**, install HiDeploy, set up the destination with the same settings, then restore: you are asked for the passphrase. Project files and server configuration can be decrypted with *Backups → Decrypt a backup file*.

> The nightly job calls `hideploy backup-run`, so keep `hideploy` installed. Docker volumes other than the database dump are not copied; uploaded files outside `storage/app` (for example in `public/`) are not included.

---

## Security notes

- HiDeploy must run as **root**. Install it only on servers you control, and read `install.sh` and `hideploy.sh` before piping anything into `sudo bash`.
- The `gitlab-runner` user is added to the `docker` group, which is **equivalent to root access** on that server. Only run pipelines you trust.
- MariaDB is not published to the internet; only containers on `web_network` can reach it.
- Each project gets its **own database user** with access to its own database only.
- phpMyAdmin is optional and **off by default**. When enabled it is protected by HTTPS and Basic Auth (plus an optional IP allow-list). Stop it when you are done: the domain then stops answering completely.
- Deploy keys are read-only.

---

## Updating and removing

```bash
sudo hideploy update          # update HiDeploy itself
```

Updating replaces only the `hideploy` command. Containers, databases, certificates and projects are untouched.

To remove the command: `sudo rm /usr/local/bin/hideploy`. Running sites keep working; use `docker`, or reinstall HiDeploy, to manage them.

---

## Roadmap

- [x] Interactive server manager
- [x] Shared nginx + MariaDB
- [x] Automatic SSL issuance and renewal
- [x] GitLab CI pipeline generation
- [x] Frontend (Vite) builds, optional databases, backup/restore, phpMyAdmin
- [ ] Web panel (Persian-friendly dashboard for the same actions)
- [x] Automatic encrypted backups (SSH + S3)
- [ ] Failure notifications (email / Telegram)
- [x] Rollback to a previous deployment, maintenance mode during deployments
- [x] Disk usage warning and cleanup helper
- [ ] Security hardening (firewall, fail2ban, automatic security updates)
- [ ] Project management after deployment (change domain, `www`/extra domains, memory, Redis)
- [x] Next.js project type
- [x] Performance tuning sized from a server scan
- [ ] Per-project resource alerts
- [ ] Debian testing

---

## Contributing

Issues and pull requests are welcome. For large changes, please open an issue first.

## License

MIT, see [LICENSE](LICENSE).

## Author

Built and maintained by [@hesami](https://github.com/hesami).
