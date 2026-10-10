#!/usr/bin/env bash
# VoltexaHub installer (Docker). Installs a complete, self-contained VoltexaHub stack on a fresh
# Debian or Ubuntu server: Caddy (automatic HTTPS), the web app, the queue worker and MySQL.
#
#   sudo ./install.sh                      # asks for the few things it needs
#   sudo ./install.sh --yes --domain=forum.example.com --email=you@example.com
#
# Safe to run again: it never overwrites an existing configuration, secrets or data.
# Source and issues: https://github.com/joogiebear/voltexahub-install  (AGPL-3.0-or-later)
set -Eeuo pipefail
trap 'echo "install.sh failed at line $LINENO. Nothing was deleted; fix the problem and run it again." >&2' ERR

readonly DEFAULT_IMAGE="ghcr.io/joogiebear/voltexahub:beta"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

DIR="/opt/voltexahub"
DOMAIN=""
EMAIL=""
ADMIN_NAME=""
ADMIN_PASSWORD_FILE=""
IMAGE="$DEFAULT_IMAGE"
ASSUME_YES=0
SKIP_DNS=0
SKIP_OS=0
ACME_STAGING=0
LOCAL_CA=0
ADMIN_PASSWORD=""
RESUME=0

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [options]

  --domain=NAME              Public domain for the community (required, e.g. forum.example.com).
                             Its DNS record must already point at this server.
  --email=ADDRESS            Administrator email; also the Let's Encrypt contact.
  --name=NAME                Administrator display name (default: Admin, max 30 characters).
  --admin-password-file=F    Read the administrator password (12+ characters) from a file
                             instead of generating one.
  --yes                      Never prompt; fail if a required value is missing.
  --dir=PATH                 Install directory (default: /opt/voltexahub).
  --image=REF                Container image to run (default: ghcr.io/joogiebear/voltexahub:beta).
  --skip-dns-check           Do not require the domain to resolve to this server (for example
                             behind Cloudflare's proxy).
  --acme-staging             Use the Let's Encrypt staging CA (for testing; browsers will not trust it).
  --local-ca                 TESTING ONLY: use Caddy's own internal CA instead of Let's Encrypt
                             and skip the DNS check. Browsers will warn about the certificate.
  --skip-os-check            Continue on an operating system that is not officially supported.
  -h, --help                 Show this help.
EOF
}

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
    --domain=*) DOMAIN="${1#*=}"; shift ;;
    --email) EMAIL="${2:?--email needs a value}"; shift 2 ;;
    --email=*) EMAIL="${1#*=}"; shift ;;
    --name) ADMIN_NAME="${2:?--name needs a value}"; shift 2 ;;
    --name=*) ADMIN_NAME="${1#*=}"; shift ;;
    --admin-password-file) ADMIN_PASSWORD_FILE="${2:?--admin-password-file needs a value}"; shift 2 ;;
    --admin-password-file=*) ADMIN_PASSWORD_FILE="${1#*=}"; shift ;;
    --dir) DIR="${2:?--dir needs a value}"; shift 2 ;;
    --dir=*) DIR="${1#*=}"; shift ;;
    --image) IMAGE="${2:?--image needs a value}"; shift 2 ;;
    --image=*) IMAGE="${1#*=}"; shift ;;
    --yes | -y) ASSUME_YES=1; shift ;;
    --skip-dns-check) SKIP_DNS=1; shift ;;
    --acme-staging) ACME_STAGING=1; shift ;;
    --local-ca) LOCAL_CA=1; SKIP_DNS=1; shift ;;
    --skip-os-check) SKIP_OS=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "Run this as root, for example: sudo ./install.sh"
[ -f "$SCRIPT_DIR/compose.yml" ] || die "compose.yml was not found next to install.sh. Run the installer from the extracted release bundle."

exec 9>/var/lock/voltexahub-install.lock
flock -n 9 || die "Another install.sh is already running."

can_prompt() { [ "$ASSUME_YES" -eq 0 ] && { : </dev/tty; } 2>/dev/null; }

# ask "Prompt" "default" -> prints the answer (the default when not interactive or left empty)
ask() {
  local prompt="$1" default="${2:-}" reply=""
  if can_prompt; then
    read -r -p "${prompt}${default:+ [$default]}: " reply </dev/tty || true
  fi
  printf '%s' "${reply:-$default}"
}

# ---------------------------------------------------------------------------------------------
# An install that finished earlier is left alone.
# ---------------------------------------------------------------------------------------------
if [ -f "$DIR/.install-complete" ]; then
  log "VoltexaHub is already installed in $DIR. Your configuration, secrets and data are untouched."
  command -v docker >/dev/null 2>&1 || die "Docker is not installed, so the existing stack cannot be started."
  cd "$DIR"
  docker compose up -d --wait --wait-timeout 300
  url="$(sed -n 's/^APP_URL=//p' "$DIR/app.env" | head -n 1)"
  log "Running. Site: ${url:-unknown}"
  exit 0
fi

if [ -f "$DIR/app.env" ]; then
  RESUME=1
  log "An earlier install in $DIR did not finish. Reusing its configuration and secrets."
  if [ -z "$DOMAIN" ]; then
    DOMAIN="$(sed -n 's#^APP_URL=https://##p' "$DIR/app.env" | head -n 1)"
  fi
fi

# ---------------------------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------------------------
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-unknown}"
case "$OS_ID:$OS_VERSION" in
  debian:12 | debian:13 | ubuntu:22.04 | ubuntu:24.04) ;;
  *)
    if [ "$SKIP_OS" -eq 1 ]; then
      warn "Unsupported operating system ${OS_ID} ${OS_VERSION}; continuing because of --skip-os-check."
    else
      die "Unsupported operating system: ${PRETTY_NAME:-$OS_ID $OS_VERSION}. Supported: Debian 12 and 13, Ubuntu 22.04 and 24.04 (or use --skip-os-check)."
    fi
    ;;
esac

ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ]; then
  if [ "$IMAGE" = "$DEFAULT_IMAGE" ]; then
    die "This beta publishes an amd64 image only; this server is $ARCH. Pass --image with an image built for $ARCH."
  fi
  warn "Architecture is $ARCH; make sure $IMAGE is built for it."
fi

MEM_MB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
[ "${MEM_MB:-0}" -ge 1800 ] || die "At least 2 GB of RAM is required; this server has ${MEM_MB} MB."

PARENT="$DIR"
while [ ! -d "$PARENT" ]; do PARENT="$(dirname "$PARENT")"; done
DISK_MB="$(df -Pm "$PARENT" | awk 'NR==2 {print $4}')"
[ "${DISK_MB:-0}" -ge 10240 ] || die "At least 10 GB of free disk space is required under $PARENT; ${DISK_MB} MB is free."

if ! command -v curl >/dev/null 2>&1; then
  log "Installing curl"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates
fi

if [ "$RESUME" -eq 0 ] && command -v ss >/dev/null 2>&1; then
  if ss -H -ltn '( sport = :80 or sport = :443 )' | grep -q .; then
    die "Port 80 or 443 is already in use on this server. Stop the other web server first (check: ss -ltnp)."
  fi
fi

# ---------------------------------------------------------------------------------------------
# What we need from the person installing
# ---------------------------------------------------------------------------------------------
if [ -z "$DOMAIN" ]; then
  DOMAIN="$(ask "Domain for your community (its DNS record must point at this server)")"
fi
DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')"
[ -n "$DOMAIN" ] || die "A domain is required. Pass --domain=forum.example.com"
printf '%s' "$DOMAIN" | grep -Eq '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' \
  || die "'$DOMAIN' is not a valid domain name. Use a name such as forum.example.com (IP addresses are not supported)."

if [ -z "$EMAIL" ]; then
  EMAIL="$(ask "Administrator email (also used for Let's Encrypt notices)")"
fi
[ -n "$EMAIL" ] || die "An administrator email is required. Pass --email=you@example.com"
printf '%s' "$EMAIL" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' || die "'$EMAIL' is not a valid email address."

if [ -z "$ADMIN_NAME" ]; then
  ADMIN_NAME="$(ask "Administrator display name" "Admin")"
fi
[ "${#ADMIN_NAME}" -ge 1 ] && [ "${#ADMIN_NAME}" -le 30 ] || die "The administrator name must be 1 to 30 characters."

if [ -n "$ADMIN_PASSWORD_FILE" ]; then
  [ -r "$ADMIN_PASSWORD_FILE" ] || die "Cannot read $ADMIN_PASSWORD_FILE."
  ADMIN_PASSWORD="$(head -n 1 "$ADMIN_PASSWORD_FILE" | tr -d '\r\n')"
  [ "${#ADMIN_PASSWORD}" -ge 12 ] || die "The administrator password must be at least 12 characters."
fi

# DNS: the domain must point here, or Let's Encrypt cannot issue a certificate.
if [ "$SKIP_DNS" -eq 0 ] && [ "$RESUME" -eq 0 ]; then
  RESOLVED="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}')"
  [ -n "$RESOLVED" ] || die "$DOMAIN does not resolve yet. Create an A record pointing at this server's public IP, wait for it to propagate, then run again (or use --skip-dns-check)."
  PUBLIC_IP="$(curl -4fsS -m 8 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$PUBLIC_IP" ]; then
    warn "Could not determine this server's public IP, so the DNS check only confirmed that $DOMAIN resolves to $RESOLVED."
  elif [ "$RESOLVED" != "$PUBLIC_IP" ]; then
    die "$DOMAIN points to $RESOLVED but this server's public IP is $PUBLIC_IP. Fix the DNS record, or use --skip-dns-check if a proxy such as Cloudflare is in front."
  fi
  if getent ahostsv6 "$DOMAIN" | awk '{print $1}' | grep -vi '^::ffff:' | grep -q .; then
    warn "$DOMAIN has an IPv6 (AAAA) record. Make sure it points at this server, or remove it; Let's Encrypt tries IPv6 first."
  fi
fi

# ---------------------------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------------------------
install_docker() {
  log "Installing Docker from Docker's official apt repository"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  local codename="${VERSION_CODENAME:-}"
  if [ "$OS_ID" = "ubuntu" ] && [ -n "${UBUNTU_CODENAME:-}" ]; then codename="$UBUNTU_CODENAME"; fi
  [ -n "$codename" ] || die "Could not determine the distribution codename for the Docker repository."
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${codename} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

if ! command -v docker >/dev/null 2>&1; then
  install_docker
fi
COMPOSE_VERSION="$(docker compose version --short 2>/dev/null || true)"
[ -n "$COMPOSE_VERSION" ] || die "Docker Compose v2 is required (the 'docker compose' command). Install the docker-compose-plugin package."
COMPOSE_MAJOR_MINOR="$(printf '%s' "${COMPOSE_VERSION#v}" | awk -F. '{printf "%d%03d", $1, $2}')"
[ "$COMPOSE_MAJOR_MINOR" -ge 2020 ] || die "Docker Compose 2.20 or newer is required; found $COMPOSE_VERSION. Update Docker."
docker info >/dev/null 2>&1 || die "The Docker daemon is not running (try: systemctl start docker)."

# ---------------------------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------------------------
log "Writing configuration to $DIR"
install -d -m 750 "$DIR"
install -m 644 "$SCRIPT_DIR/compose.yml" "$DIR/compose.yml"

write_secret_file() { # write_secret_file path  (content on stdin)
  local target="$1"
  install -m 600 /dev/null "$target"
  cat >"$target"
}

if [ "$RESUME" -eq 0 ]; then
  APP_KEY="base64:$(openssl rand -base64 32)"
  DB_PASSWORD="$(openssl rand -hex 24)"
  DB_ROOT_PASSWORD="$(openssl rand -hex 24)"

  write_secret_file "$DIR/app.env" <<EOF
APP_NAME=VoltexaHub
APP_ENV=production
APP_DEBUG=false
APP_KEY=${APP_KEY}
APP_URL=https://${DOMAIN}
# Safe only because the web container's port is never published; only Caddy can reach it.
TRUSTED_PROXIES=*
LOG_CHANNEL=stderr
LOG_LEVEL=info
PORT=8080

DB_CONNECTION=mysql
DB_HOST=mysql
DB_PORT=3306
DB_DATABASE=voltexahub
DB_USERNAME=voltexahub
DB_PASSWORD=${DB_PASSWORD}

SESSION_DRIVER=database
SESSION_SECURE_COOKIE=true
CACHE_STORE=database
QUEUE_CONNECTION=database

# Emails are only written to the log until you configure a mail provider in the admin panel.
MAIL_MAILER=log
MAIL_FROM_ADDRESS=noreply@${DOMAIN}

UPLOADS_ROOT=/data/uploads
EOF

  write_secret_file "$DIR/mysql.env" <<EOF
MYSQL_DATABASE=voltexahub
MYSQL_USER=voltexahub
MYSQL_PASSWORD=${DB_PASSWORD}
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
EOF
fi

write_secret_file "$DIR/.env" <<EOF
COMPOSE_PROJECT_NAME=voltexahub
VOLTEXAHUB_IMAGE=${IMAGE}
EOF

{
  echo "{"
  echo "	admin off"
  if [ "$LOCAL_CA" -eq 1 ]; then
    echo "	local_certs"
    echo "	skip_install_trust"
  else
    echo "	email ${EMAIL}"
    if [ "$ACME_STAGING" -eq 1 ]; then
      echo "	acme_ca https://acme-staging-v02.api.letsencrypt.org/directory"
    fi
  fi
  echo "}"
  echo
  echo "${DOMAIN} {"
  echo "	reverse_proxy web:8080"
  echo "}"
} >"$DIR/Caddyfile"
chmod 644 "$DIR/Caddyfile"

# ---------------------------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------------------------
cd "$DIR"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "Pulling $IMAGE"
  docker pull "$IMAGE" || die "Could not pull $IMAGE. If this is a beta that is not published yet, build the image yourself and pass --image."
fi
docker compose pull --quiet caddy mysql

show_failure_logs() {
  docker compose ps || true
  for svc in web mysql caddy worker; do
    echo "---- last log lines: $svc ----" >&2
    docker compose logs --no-color --tail 25 "$svc" >&2 || true
  done
}

log "Starting the stack (the first start creates the database and takes a minute or two)"
if ! docker compose up -d --wait --wait-timeout 300; then
  show_failure_logs
  die "The stack did not become healthy. The logs above show why; fix the cause and run install.sh again."
fi

# ---------------------------------------------------------------------------------------------
# Administrator account
# ---------------------------------------------------------------------------------------------
if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=\n')"
fi
log "Creating the administrator account"
INSTALL_OUTPUT="$(FORUM_ADMIN_PASSWORD="$ADMIN_PASSWORD" docker compose exec -T -e FORUM_ADMIN_PASSWORD web \
  sh deploy/drop-privileges.sh php artisan forum:install --email="$EMAIL" --name="$ADMIN_NAME" --no-interaction 2>&1)" || {
  printf '%s\n' "$INSTALL_OUTPUT" >&2
  die "forum:install failed (output above)."
}
ADMIN_CREATED=1
if printf '%s' "$INSTALL_OUTPUT" | grep -q 'An administrator already exists'; then
  ADMIN_CREATED=0
fi

# ---------------------------------------------------------------------------------------------
# Check the public path (Caddy -> web), resolving the domain to this machine so a stale or
# proxied DNS record cannot give a false result.
# ---------------------------------------------------------------------------------------------
log "Checking https://${DOMAIN}/up"
CURL_OPTS=(-sS -o /dev/null -m 10 -w '%{http_code}' --resolve "${DOMAIN}:443:127.0.0.1")
[ "$LOCAL_CA" -eq 1 ] && CURL_OPTS+=(-k)
HTTPS_OK=0
for _ in $(seq 1 24); do
  code="$(curl "${CURL_OPTS[@]}" "https://${DOMAIN}/up" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then
    HTTPS_OK=1
    break
  fi
  sleep 5
done

touch "$DIR/.install-complete"
chmod 600 "$DIR/.install-complete"

echo
echo "=============================================================================="
if [ "$HTTPS_OK" -eq 1 ]; then
  echo " VoltexaHub is installed and running."
else
  echo " VoltexaHub is installed, but https://${DOMAIN}/up did not answer yet."
  echo " Usually the certificate is still being issued, or DNS / ports 80 and 443 are not"
  echo " reachable from the internet. Check: cd ${DIR} && docker compose logs caddy"
fi
echo
echo "   Site:      https://${DOMAIN}"
echo "   Admin:     ${EMAIL}"
if [ "$ADMIN_CREATED" -eq 1 ]; then
  echo "   Password:  ${ADMIN_PASSWORD}"
  echo "              (shown only once; change it after signing in)"
else
  echo "   An administrator already existed, so no account was created or changed."
fi
echo
echo " Back up ${DIR}/app.env now. It holds APP_KEY, which cannot be recovered: without"
echo " it, encrypted settings (mail credentials and similar) are unreadable after a restore."
echo
echo " Next: sign in, open the admin setup checklist, and configure outgoing email."
echo " Until then, emails (verification, password resets) are only written to the log."
if [ "$LOCAL_CA" -eq 1 ]; then
  echo
  echo " --local-ca was used: browsers will warn about the certificate. Testing only."
fi
echo "=============================================================================="
