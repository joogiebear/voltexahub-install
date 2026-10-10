# VoltexaHub install

Installer for self-hosting [VoltexaHub](https://github.com/joogiebear/voltexahub) with Docker. Licensed under AGPL-3.0-or-later (see LICENSE). **Beta: expect rough edges.**

## Requirements

- A fresh VPS or VM running Debian 12/13 or Ubuntu 22.04/24.04 (amd64), root access.
- At least 2 GB RAM (1800 MB free minimum) and 10 GB disk.
- **A domain name** pointing at the server (A record, and AAAA only if the server really has IPv6). Ports 80 and 443 must be open and free; HTTPS certificates are issued automatically.

## Quick start

```sh
git clone https://github.com/joogiebear/voltexahub-install
cd voltexahub-install
sudo bash ./install.sh
```

The script asks for your domain and admin email, installs Docker if needed, starts the stack, creates the administrator account and prints a one-time password. Save it, and **back up `/opt/voltexahub/app.env`**: it holds `APP_KEY`, and losing it makes encrypted data unrecoverable.

Non-interactive:

```sh
sudo bash ./install.sh --yes --domain=forum.example.com --email=you@example.com --name="My Community"
```

Options: `--admin-password-file`, `--dir`, `--image`, `--skip-dns-check`, `--acme-staging` (test certificates without Let's Encrypt rate limits), `--local-ca` (internal CA for lab testing; browsers will warn), `--skip-os-check`. Run `install.sh --help` for details.

Re-running on a completed install just makes sure the stack is up. An interrupted install resumes where it stopped.

## What gets installed (`/opt/voltexahub`)

| Service | Role |
| --- | --- |
| `caddy` | Only service exposed (80/443). Automatic HTTPS, forwards to `web`. |
| `web` | VoltexaHub app. Port 8080 is internal only, never published. |
| `worker` | Queue worker and scheduler (mail, notifications, billing). |
| `mysql` | MySQL 8.4, data in the `mysql-data` volume. |

Config lives in `app.env` (app), `mysql.env` (database secrets), `.env` (image tag) and `Caddyfile`, all generated once. `compose.yml` is replaced on update; put local changes in `compose.override.yml`. Uploads live in the `uploads` volume.

## Day-to-day

```sh
cd /opt/voltexahub
docker compose ps
docker compose logs -f web
docker compose restart
```

A `voltexahub` CLI (backup, restore, update, doctor) is planned; until then back up the `mysql-data` and `uploads` volumes and `app.env` yourself.

## Status

Tested on a clean Debian 13 VM (Docker install, resume, re-run, restart). Not yet tested: Ubuntu, arm64, real Let's Encrypt issuance from this script, upgrades.
