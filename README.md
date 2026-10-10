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

## Day-to-day: the `voltexahub` command

`install.sh` installs `/usr/local/bin/voltexahub`. Run it with sudo.

| Command | What it does |
| --- | --- |
| `voltexahub status` | Containers, version, site address, latest backup. |
| `voltexahub doctor` | Health check: containers, HTTPS, **queue worker and scheduler running**, stuck or failed jobs, disk, certificate expiry, backup age. Exits 1 if something essential is wrong. |
| `voltexahub logs [web\|worker\|caddy\|mysql]` | Follow logs. |
| `voltexahub backup` | One archive (database, uploads, settings including `APP_KEY`) plus a checksum, in `/opt/voltexahub/backups`. |
| `voltexahub restore FILE` | Replace the database, uploads and app settings from a backup. Takes a safety backup first. |
| `voltexahub update [VERSION]` | Backs up, pulls the new image, restarts, and **rolls back automatically** if the new version does not become healthy. |
| `voltexahub support-bundle` | Redacted diagnostics for a bug report. Read it before sharing. |

### Backups

A systemd timer runs `voltexahub backup` every night at about 03:15 and keeps the newest 7. Backups contain secrets (`APP_KEY`, database passwords): **copy them off the server** (another machine, object storage) and keep them private. A backup on the same disk does not protect you from losing the server.

### Moving to a new server or recovering from a disaster

1. On the new server run `install.sh` with the domain you want to use (a fresh install generates new secrets; that is fine).
2. Copy the backup file and its `.sha256` file to the new server.
3. `sudo voltexahub restore /path/to/voltexahub-backup-....tar`

The restore brings back your content, uploads and the original `APP_KEY` (needed to read encrypted settings such as mail credentials). It keeps the new server's database login and domain. Pending database migrations run when the site starts.

### Updating

`sudo voltexahub update` pulls the newest image for your current tag; `sudo voltexahub update 1.9.0-beta.1` moves to a specific version. Database migrations cannot be undone: if a new version misbehaves after starting, the output prints the exact `voltexahub restore` command for the backup it took just before updating. Updates to `compose.yml` itself arrive by running a newer `install.sh` from a fresh download (it leaves your configuration and data alone).

## Status

Tested on clean Debian 13 and Ubuntu 24.04 VMs (Docker install from scratch, install, doctor and backup on Ubuntu). The full set on Debian 13: Docker install, resume, re-run, restart, backup, restore in place, restore onto a freshly installed server with different secrets, tamper detection, update with automatic rollback of a broken image, doctor catching a stopped worker, support bundle without secrets. Not yet tested: Ubuntu 22.04, Debian 12, arm64 (the image is amd64 only), real Let's Encrypt issuance from this script, an update between two real published versions.
