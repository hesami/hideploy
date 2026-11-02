# HiDeploy

**Deploy any Dockerized project to your own server — one command, one panel, unlimited projects.**

HiDeploy is a self-hosted deployment tool that turns any Dockerized repository into a running service on your own server. It prepares the host once, then lets you deploy, update and manage projects from a single CLI.

```
git push  →  build  →  migrate  →  live
```

---

## Why HiDeploy?

- **Self-hosted.** No Vercel, no Railway, no vendor lock-in. Your code, your server, your rules.
- **One tool for many projects.** A single shared nginx and MariaDB serve all your deployments, keeping RAM and disk usage low.
- **Zero CI variables.** Server-specific settings live in `.deploy.env` on the server, outside git.
- **Batteries included.** Docker, GitLab Runner, SSL, backups, logs and migrations — all wired together.
- **No `chmod 777`.** Files are owned by the same UID/GID as the runner, so permissions just work.

---

## Quick install

On a fresh Ubuntu or Debian server, run as root:

```bash
curl -fsSL https://raw.githubusercontent.com/hesami/hideploy/main/install.sh | sudo bash
```

This will:

1. Download the latest `hideploy.sh` from the repository
2. Install it to `/usr/local/bin/hideploy`
3. Make it executable and globally available

After that, you can run it from any directory:

```bash
sudo hideploy
```

---

## Manual install

If you prefer to install it yourself:

```bash
# 1. Clone the repository (or download just the script)
git clone https://github.com/hesami/hideploy.git
cd hideploy

# 2. Make it executable
chmod +x hideploy.sh

# 3. Run it
sudo ./hideploy.sh
```

To make it available system-wide as `hideploy`:

```bash
sudo install -m 755 hideploy.sh /usr/local/bin/hideploy
```

---

## First run

On a **fresh server**, run HiDeploy and walk through the menu in order:

```bash
sudo hideploy
```

```
1) Prepare Server              →  Docker, GitLab Runner, shared network
2) Shared Services             →  nginx + MariaDB + SSL auto-renew
3) Generate Project Files      →  Dockerfile, compose, CI for your repo
4) Deploy New Laravel Project  →  the deployment wizard
5) Manage Projects             →  deploy, logs, backup, SSL, remove
```

If you are on a brand-new server, choose **`1` → `A` (Run all)** to prepare everything at once. Then choose **`2` → `A`** to install the shared services.

---

## Deploying your first project

Once the server is prepared and shared services are running:

```bash
sudo hideploy
# choose 4) Deploy New Laravel Project
```

The wizard guides you through:

1. **Domain** — e.g. `api.example.com`
2. **DNS check** — verifies the A record points to this server
3. **Repository** — SSH URL and branch
4. **Clone** — the project is cloned to `/var/www/projects/<domain>`
5. **Server settings** — written to `.deploy.env` (not in git)
6. **Project files** — `Dockerfile`, `docker-compose.prod.yml`, `.dockerignore`, `.gitlab-ci.yml`
7. **Database** — provisioned in the shared MariaDB container
8. **`.env`** — configured with production-safe defaults
9. **Laravel Passport** — optional, keys generated if needed
10. **Build** — image built, container started, migrations run
11. **nginx + SSL** — vhost created and a Let's Encrypt certificate issued

When it finishes, the site is live at `https://<your-domain>`.

From then on, every `git push` to the configured branch triggers a full deployment through GitLab CI.

---

## How it works

```
                Internet
                   │
                   ▼
        ┌─────────────────────┐
        │   global-nginx      │  ← one container, ports 80 + 443
        └──────────┬──────────┘
                   │  web_network (Docker bridge)
       ┌───────────┼───────────────┐
       ▼           ▼               ▼
  ┌─────────┐ ┌─────────┐     ┌─────────┐
  │project 1│ │project 2│ ... │project N│  ← php-fpm + queue + scheduler
  └────┬────┘ └────┬────┘     └────┬────┘
       └───────────┴───────────────┘
                   ▼
         ┌─────────────────────┐
         │  global-mariadb     │  ← one container, shared by all projects
         └─────────────────────┘
```

- Project code lives on the server disk at `/var/www/projects/<domain>`
- A bind mount puts it inside each project's container
- Shared infrastructure lives in `/var/www/infrastructure`
- Every project joins the `web_network` bridge, so nginx can reach each one by container name

---

## Requirements

- A fresh **Ubuntu 22.04+** or **Debian 12+** server (root access)
- A domain whose A record points to the server
- A GitLab repository (SSH URL) for the project you want to deploy
- The server's public SSH key added to the project as a **read-only Deploy Key**

HiDeploy installs Docker, GitLab Runner, nginx and MariaDB automatically. Nothing else needs to be installed beforehand.

---

## Common commands

Once installed, everything is available through the menu:

```bash
sudo hideploy
```

If you prefer to reach specific menu entries faster, you can call the script directly:

```bash
sudo /usr/local/bin/hideploy     # same as 'sudo hideploy'
```

Project actions (deploy, logs, backup, SSL, remove) are available from the **Manage Projects** menu.

---

## Security notes

- HiDeploy must run as **root**. Only install it on servers you trust.
- The nginx and MariaDB containers are on an internal Docker network. MariaDB is **not** exposed to the internet.
- SSL certificates are issued and renewed through Let's Encrypt. Renewal runs daily at 03:17 via cron.
- Deploy keys used by the runner are **read-only**. Do not grant write access unless you have a specific reason.

A web panel is planned for the next milestone. When it lands, it will sit behind basic auth and HTTPS on a dedicated subdomain.

---

## Roadmap

- [x] CLI server manager
- [x] Shared nginx + MariaDB
- [x] Automatic SSL issuance and renewal
- [x] GitLab CI pipeline generation
- [ ] **Web panel** (coming next) — a Persian-friendly dashboard for the same actions
- [ ] Support for custom build steps via `.deploy.env`
- [ ] Per-project resource limits and alerts

---

## Contributing

Issues and pull requests are welcome. Please open an issue first for large changes so we can align on the approach.

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

## Author

Built and maintained by [@hesami](https://github.com/hesami).
