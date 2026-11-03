# HiDeploy

**Deploy GitLab-hosted Laravel projects to your own server, one command and one menu, as many projects as you like.**

HiDeploy prepares a fresh Ubuntu server once, then deploys and manages Laravel projects from a single interactive menu. After the first deployment, every `git push` to your branch redeploys automatically through GitLab CI.

```
git push  →  GitLab pipeline  →  build  →  migrate  →  live
```

> **Scope:** HiDeploy targets **Laravel (PHP)** projects hosted on **GitLab** (it uses GitLab Runner for CI/CD). The tool itself is hosted on GitHub.

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
- A **GitLab** repository (SSH URL) containing a Laravel project
- A GitLab runner token (created in GitLab: *Settings → CI/CD → Runners → New project runner*)

HiDeploy installs Docker, GitLab Runner, nginx and MariaDB for you.

---

## First run

```
1) Prepare Server              →  Docker, GitLab Runner, shared network
2) Shared Services             →  nginx + MariaDB + SSL auto-renew (+ optional phpMyAdmin)
3) Generate Project Files      →  Dockerfile, compose, CI for your repository
4) Deploy New Laravel Project  →  the deployment wizard
5) Manage Projects             →  deploy, logs, backups, restore, SSL, remove
```

On a brand-new server choose **`1` → `A`** (run everything), then **`2` → `A`**. Each step checks what is already done and skips it, so re-running is safe. The top of the menu always shows the server status and the recommended next step.

---

## Deploying a project

Choose **3) Generate Project Files**, copy the four generated files into your Laravel project, commit and push them. Then choose **4) Deploy New Laravel Project**. The wizard handles:

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
| Automatic SSL issuance and daily renewal | Shared Services / SSL Management |
| SSL overview: expiry dates, days left, file paths, forced renewal | Manage Projects → SSL management |
| Frontend (Vite) build in a temporary Node container; npm, pnpm or yarn detected from the lock file | Project menu → Frontend assets |
| Projects without a database; add one later | Wizard / Project menu → Add a database |
| Database backup (`.sql.gz`) | Project menu → Backup |
| Database restore from `.sql` / `.sql.gz` (replace or add; MySQL 8 dumps converted automatically) | Project menu → Restore |
| phpMyAdmin on its own domain: HTTPS, Basic Auth, optional IP allow-list, start/stop on demand | Shared Services → phpMyAdmin |
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
| Database backups | `/var/backups/hideploy` |
| Generated project files | `/root/hideploy-templates/<domain>` |
| SSL renewal | `/usr/local/bin/hideploy-renew-ssl` + `/etc/cron.d/hideploy-ssl-renew` (daily 03:17) |

Project code stays on the server disk, so `.env` and logs are easy to read and edit. The four files you commit to your repository are generic; server-specific values are in `/var/www/projects/<domain>/.deploy.env`.

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
- [ ] Per-project resource alerts
- [ ] Debian testing

---

## Contributing

Issues and pull requests are welcome. For large changes, please open an issue first.

## License

MIT, see [LICENSE](LICENSE).

## Author

Built and maintained by [@hesami](https://github.com/hesami).
