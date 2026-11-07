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
sudo hideploy security-check # print the security report (exit code 1 when it finds a problem)
sudo hideploy notify-test # send a test notification to every channel that is switched on
sudo hideploy notify-run  # send waiting notifications and check the server (the every-minute job calls this)
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
8) Security                    →  firewall with lockout guard, fail2ban, automatic security updates, SSH, security check
9) Email                       →  your own mail server for every domain: mailboxes, DNS help, optional webmail
10) Notifications              →  alerts by email and Telegram: deployments, backups, stopped services, disk, certificates
```

On a brand-new server choose **`1` → `A`** (run everything), then **`2` → `A`**, and finally **`8`** (security). Each step checks what is already done and skips it, so re-running is safe. The top of the menu always shows the server status (including firewall, fail2ban, automatic updates and SSH login) and the recommended next step.

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
| **Project settings after deployment:** memory limit, extra domains (`www` etc.), change of the main domain, upload size, shared Redis | Project menu → Project settings |
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
| **Security check:** firewall, fail2ban, automatic updates, waiting updates / reboot, SSH password and root login, ports open to the internet, permissions of `.env` and backup secrets | Main menu top + Security → 1 |
| **Firewall (UFW) with lockout guard:** detects the real SSH port, shows the rules first, switches itself off again if you do not confirm you can still log in | Security → Firewall |
| **fail2ban for SSH** with safe defaults (your IP is never banned) | Security → fail2ban |
| **Automatic security updates** (security patches only; automatic reboot is off by default) | Security → Automatic security updates |
| **Own mail server, no outside SMTP/API service:** one shared server for all your domains; `info@example.com`, `noreply@example.com`, aliases; DKIM key, SPF/DMARC records generated and checked; a project can send through its own mailbox with one menu step | Email (main menu 9) / Project menu → Email |
| **Notifications by email and Telegram:** deployment succeeded / failed (from the menu **and** from GitLab pipelines), rollback, backup result, SSL renewal failed, certificate about to expire, a project or shared service stopped, disk almost full, reboot needed; each event can be switched on or off, projects can be muted | Notifications (main menu 10) |
| **Webmail (Roundcube)** on its own domain: read and send mail in the browser; HTTPS, optional Basic Auth and IP list; start/stop on demand like phpMyAdmin | Email → Webmail |
| **Keys-only SSH** (optional), with key check, `sshd -t`, backup and automatic undo | Security → Harden SSH |

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
| Shared Redis (optional) | `/var/www/infrastructure/redis` |
| Weekly cleanup schedule / log | `/etc/cron.d/hideploy-cleanup` / `/var/log/hideploy-cleanup.log` |
| Generated project files | `/root/hideploy-templates/<domain>` |
| SSL renewal | `/usr/local/bin/hideploy-renew-ssl` + `/etc/cron.d/hideploy-ssl-renew` (daily 03:17) |
| Mail server: config (accounts, aliases, DKIM keys) / messages | `/var/www/infrastructure/mail/config` / `/var/www/infrastructure/mail/data` |
| Webmail (optional) | `/var/www/infrastructure/webmail` |
| Notifications: settings and secrets / remembered problems | `/var/www/infrastructure/notify/notify.env` / `.../notify/state` (root only) |
| Notifications: events dropped by pipelines | `/var/spool/hideploy-notify` (no secrets) |
| Notifications: job / log | `/etc/cron.d/hideploy-notify` (every minute) / `/var/log/hideploy-notify.log` |
| Security settings, SSH backups and undo script | `/var/www/infrastructure/security` |
| fail2ban jail (SSH) | `/etc/fail2ban/jail.d/hideploy-sshd.local` |
| Automatic updates | `/etc/apt/apt.conf.d/20auto-upgrades` + `/etc/apt/apt.conf.d/52hideploy-unattended` |
| Keys-only SSH (when enabled) | `/etc/ssh/sshd_config.d/00-hideploy-hardening.conf` (or a marked block at the top of `sshd_config`) |

Project code stays on the server disk, so `.env` and logs are easy to read and edit. The four files you commit to your repository are generic; server-specific values are in `/var/www/projects/<domain>/.deploy.env`.

---

## Project settings after deployment

Open a project in **Manage Projects** and choose **Project settings**:

- **Memory limit:** change it any time; the container restarts with the new limit. HiDeploy warns if all limits together exceed 80% of the server's RAM.
- **Extra domains (`www` and others):** visitors of an extra domain are redirected permanently to the main domain. The SSL certificate is extended to cover the new name, so create its DNS record first. Removing an extra domain stops serving it (the certificate keeps listing the name until its next re-issue, which is harmless).
- **Change the main domain:** renames the project folder, moves nginx and SSL to the new name and restarts the container. Afterwards **commit the new `.gitlab-ci.yml`** (it contains the folder path; a copy is prepared in `/root/hideploy-templates/<new-domain>`), update `APP_URL` / `NEXT_PUBLIC_*` values, and re-add the old domain as an extra domain if you want it to redirect.
- **Upload size limit:** nginx and, for Laravel projects with the newest generated files, PHP.
- **Redis:** *Shared Services → Redis* installs one password-protected Redis for all projects (data on disk, eviction only for keys with an expiry, so queue jobs are never evicted). Each project can then use it: Laravel (cache, sessions and/or queues, with a per-project key prefix) or Next.js (`REDIS_URL` in `.env`). Laravel needs a Redis client: the PHP extension, or `composer require predis/predis` in your project (HiDeploy checks and tells you).

Projects deployed with older generated files keep working unchanged; options that need the newest template (PHP upload limit, PHP-FPM tuning) tell you so.

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

## Security (basic server protection)

Open **8) Security**. **Nothing is changed until you confirm**, and the two steps that could lock you out (firewall, SSH login) undo themselves if you cannot confirm that you still have access. The same checks are shown at the top of the main menu, and `sudo hideploy security-check` prints the full report from the command line.

**1. Security check.** One page that shows:

- firewall on or off, fail2ban on or off, automatic security updates on or off
- packages waiting to be installed (and how many of them are security fixes), and whether the server needs a **reboot**
- SSH **password login** and **root login** open or closed
- which ports are reachable from outside: only SSH, 80 and 443 are expected, anything else is flagged (a database or Redis port is marked as a real problem). Ports that Docker publishes are labelled as such, because UFW does not filter them
- whether `.env`, `.deploy.env`, the backup passphrase, destination keys and the database password are readable by other users (one menu item fixes them)

**2. Firewall with lockout guard.** HiDeploy finds the real SSH port (sshd configuration, what sshd listens on, and the port of your current connection), shows the exact rules, and only then enables UFW with *incoming: block, outgoing: allow, allow SSH + 80 + 443*. Right after enabling, open a **second** terminal and log in again; type `yes` in the first one to keep the firewall. If you type `no`, wait about 2 minutes, or your connection drops, a timer switches the firewall off again. This is the part a manual `ufw enable` does not give you. If UFW is already on, new rules are just added.

**3. fail2ban for SSH.** Installs fail2ban and writes one jail file: by default 5 failed logins within 10 minutes ban the address for 1 hour. Your current IP (and `127.0.0.1`, `::1`) is on the never-ban list. Settings can be changed, banned addresses listed and unbanned from the same menu.

**4. Automatic security updates.** Turns on `unattended-upgrades` for **security patches only** (Docker's own packages are not touched). The server is **not rebooted automatically** unless you switch that on and choose a time; when an update needs a reboot, the status table says so. You can also install the waiting security updates immediately.

**5. Keys-only SSH (optional).** Closes password login (and turns root password login into key-only). It runs only when:

1. a public key exists on the server for a user that can log in,
2. you confirmed that you tested a key login from a **second window** (HiDeploy prints the exact `ssh` command and shows recent key logins from the logs),
3. `sshd -t` accepts the new settings and they are really effective (`sshd -T`).

A copy of your SSH settings is saved first. After the reload you must prove once more, from a new window, that the key login works, otherwise the old settings come back by themselves. **Undo** is always in the same menu.

---

## Disk usage and cleanup

The menu shows the disk usage in the status table (yellow from 80%, red from 90%). *Manage Projects → Disk usage and cleanup* offers:

- **Safe cleanup:** unused Docker images, old build cache, system logs above 200 MB, package cache and Laravel logs older than 14 days. It never touches Docker volumes (your databases), running containers, project code or `.env` files.
- **Deep cleanup:** removes all Docker images no container uses (slower next deploy or backup, because tools are downloaded again).
- Large log files, old manual database backups, and an optional **weekly automatic safe cleanup** (Sundays 04:10, log in `/var/log/hideploy-cleanup.log`).

Every successful deployment also removes the dangling images it leaves behind.

---

## Email (your own mail server)

Open **9) Email**. HiDeploy runs **one shared mail server** (Postfix + Dovecot + Rspamd, via [docker-mailserver](https://github.com/docker-mailserver/docker-mailserver)) for **all** your domains, the same way it shares one nginx and one MariaDB. You can send and receive mail for `info@example.com`, `noreply@example.org` and so on without any outside SMTP or API service.

1. **Install the mail server** (once). You choose a hostname such as `mail.example.com` (A record to this server, **no AAAA record**); HiDeploy checks that outgoing port 25 is open, issues the certificate, starts the server, opens ports 25, 465, 587 and 993 and shows the DNS records of the server itself.
2. **Mail domains → Add / enable.** Any domain works (it does not have to be a deployed project). HiDeploy creates a 2048-bit **DKIM** key and prints the exact **MX, SPF, DKIM and DMARC** records. *Check DNS* later compares them with what the internet really answers.
3. **Mailboxes and aliases.** Create `info`, `noreply`, … (a strong password is generated if you press Enter). Passwords are stored only as hashes and never appear on a command line.
4. **Webmail (optional).** Roundcube on its own domain with HTTPS, an optional browser login and IP list. Like phpMyAdmin it is **closed by default**: *Start* opens it, *Stop* makes the domain stop answering completely.
5. **Deliverability check.** Ports, outgoing port 25, A/AAAA record, reverse DNS (PTR), certificate, blacklists, and the DNS of every mail domain. *Send a test email* sends through your own server and shows the delivery log.

**Per project.** In a project's menu choose **Email for this project**: enable its domain, manage its mailboxes and let the project send through one of them. HiDeploy writes the SMTP settings into the project's `.env` (`MAIL_*` for Laravel, `SMTP_*` and `SMTP_URL` for Next.js). The project reaches the mail server through the internal Docker network by its real hostname, so the certificate is valid.

**What no script can do for you**
- **Reverse DNS (PTR)** of the server IP must point to the mail hostname. Only the company that owns the IP (your server provider) can set it.
- **Outgoing port 25** must be open (some providers block it until you ask).
- A **new or previously blacklisted IP** may land in spam at Gmail / Outlook for a while, whatever the configuration. Receiving mail and low-volume sending (confirmation and password-reset mails) normally work well; large mailings from a fresh IP do not.
- Memory: expect roughly 600-900 MB of RAM in use (antivirus is off).

**Backups.** Mail accounts, aliases and DKIM keys are part of the encrypted server-configuration backup. The messages are a separate encrypted file (`mail-data`) that you can switch off in *Email → Include mailboxes in the nightly backup*.

---

## Notifications (email and Telegram)

Open **10) Notifications**. HiDeploy tells you what happens on your server, so you do not have to look.

**Channels** (use one or both; both together is safest):
- **Email**, sent by **your own mail server** (menu 9). HiDeploy creates a dedicated mailbox `notifications@<your domain>` with a generated password, kept in a file only root can read, and sends alerts to the addresses you give (they can be on any provider).
- **Telegram:** create a bot with @BotFather (one minute), paste its token, write one message to the bot, and HiDeploy finds your chat by itself. Several chats or groups are possible. If Telegram is blocked from your server, set a proxy (`socks5h://...` or `http://...`).

**Events** (each one can be switched on or off):

| Event | When | Default |
|---|---|---|
| Deployment failed / succeeded | after every deployment, from a GitLab pipeline **or** from the HiDeploy menu (commit, author, duration, pipeline and job links) | on |
| Rollback | when you roll back to an earlier version | on |
| Backup failed / finished | result of every backup run | failed: on, finished: off |
| SSL renewal failed | the daily renewal job reports an error | on |
| Certificate expires soon | fewer than 14 days left (adjustable) | on |
| A project or shared service stopped | a project, nginx, MariaDB, Redis, the mail server or Docker stopped, missing or unhealthy | on |
| Disk almost full | 90% used or more (adjustable) | on |
| Server needs a reboot | updates are waiting for a reboot | off |

**No message storms.** A problem is announced **once**, repeated as a reminder after 24 hours if it is still there, and announced again as **resolved** when it is fixed. A stopped container must be seen in two checks in a row (5 minutes apart), so the normal restart during a deployment never triggers an alert. Several problems found together arrive as one message. If a channel is temporarily unreachable, delivery is retried for up to an hour, and only the recipients that did not get it yet are retried.

**Pipelines.** A GitLab pipeline runs as the unprivileged `gitlab-runner` user, which must never see your Telegram token or mailbox password. So the pipeline only drops a small event file into `/var/spool/hideploy-notify`, and a root job (every minute) turns it into messages. For this the project needs the newer `.gitlab-ci.yml`: *Notifications → Pipeline notifications* lists which projects are ready and writes the new file for the others (copy it into your repository and push; the Dockerfile and compose file are not touched). Deployments started from the HiDeploy menu always notify.

**Good to know**
- *Notifications → Settings* sets the server name shown in messages, the disk and certificate thresholds, and lets you **mute projects** (for example a test site).
- *Notifications → Send a test notification* shows, per channel, whether delivery worked and the reason if it did not.
- If the mail server itself is down, an email about it cannot be delivered; that is why Telegram next to email is recommended.
- Nothing is sent, and no background job exists, until you turn notifications on. Turning them off removes the job and the spool folder; your settings are kept.

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

- Use **8) Security** after the first deployment: firewall, fail2ban and automatic security updates cover the most common ways a small server gets compromised. Keep a cloud-provider console at hand the first time you touch the firewall or SSH.
- HiDeploy must run as **root**. Install it only on servers you control, and read `install.sh` and `hideploy.sh` before piping anything into `sudo bash`.
- The `gitlab-runner` user is added to the `docker` group, which is **equivalent to root access** on that server. Only run pipelines you trust.
- MariaDB is not published to the internet; only containers on `web_network` can reach it.
- Each project gets its **own database user** with access to its own database only.
- phpMyAdmin is optional and **off by default**. When enabled it is protected by HTTPS and Basic Auth (plus an optional IP allow-list). Stop it when you are done: the domain then stops answering completely.
- The mail server is **off until you install it**. Once installed it must be reachable from the internet (ports 25, 465, 587, 993); sending as another mailbox is blocked, and the mail server bans addresses that fail to log in repeatedly. The webmail is **closed by default**; open it only when needed.
- Notification secrets (Telegram bot token, the mailbox password of the sender) live in `notify.env`, readable by root only, and are part of the encrypted server-configuration backup. The Telegram token is never placed on a command line, and pipelines can only drop event files: files from the spool are never executed or sourced, only a few known fields are read and cleaned.
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
- [x] Own mail server and webmail for every project domain
- [x] Notifications by email (own mail server) and Telegram
- [x] Rollback to a previous deployment, maintenance mode during deployments
- [x] Disk usage warning and cleanup helper
- [x] Security hardening (firewall with lockout guard, fail2ban, automatic security updates, SSH keys-only, security check)
- [x] Project management after deployment (domains, memory, Redis, upload size)
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
