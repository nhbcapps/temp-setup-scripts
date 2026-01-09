#!/usr/bin/env bash
# Ensure we are running under bash even if invoked via sh or a non-bash shell
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi
set -Eeuo pipefail

# How to run (app/user phase):
#   # Ensure you are NOT root; switch to the target user first:
#   #   sudo su - frappe
#   /opt/frappe-setup/setup-frappe-app.sh -u frappe -p 'root_pwd' -s 'apps.localhost' -a 'admin_pwd'

# Must not run as root
if [[ "$EUID" -eq 0 ]]; then
  echo "Do not run this script as root. Switch to the target user first (e.g., sudo su - frappe)."
  exit 1
fi

# Logging
SCRIPT_BASENAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_STEM="${SCRIPT_BASENAME%.*}"
LOG_FILE="/tmp/${SCRIPT_STEM}-$(date +%Y-%m-%d).log"
touch "$LOG_FILE"
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}
fail() {
  log "ERROR: $*"
  exit 1
}
trap 'fail "Script failed at line $LINENO"' ERR

# Usage and args
usage() {
  cat <<USAGE
Usage: $0 [options]
  -u, --user              Frappe system user (e.g., frappe)
  -p, --db-password       MariaDB root password
  -s, --site              Frappe site name (e.g., apps.localhost)
  -a, --admin-password    Frappe Administrator password
  -h, --help              Show this help and exit

Example:
  ./setup-user.sh -u frappe -p 'root_pwd' -s 'apps.localhost' -a 'admin_pwd'
USAGE
}
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--user) FRAPPE_APP_USER="$2"; shift 2 ;;
      -p|--db-password) FRAPPE_DB_PASSWORD="$2"; shift 2 ;;
      -s|--site) SITE_NAME="$2"; shift 2 ;;
      -a|--admin-password) APP_ADMIN_PASSWORD="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1"; echo; usage; exit 1 ;;
    esac
  done
}
parse_args "$@"

# Resolve and validate
FRAPPE_APP_USER="${FRAPPE_APP_USER:-}"
FRAPPE_DB_PASSWORD="${FRAPPE_DB_PASSWORD:-}"
SITE_NAME="${SITE_NAME:-}"
APP_ADMIN_PASSWORD="${APP_ADMIN_PASSWORD:-}"
[[ -z "${FRAPPE_APP_USER}" ]] && fail "FRAPPE_APP_USER is required. Use -u|--user."
[[ -z "${FRAPPE_DB_PASSWORD}" ]] && fail "FRAPPE_DB_PASSWORD is required. Use -p|--db-password."
[[ -z "${SITE_NAME}" ]] && fail "SITE_NAME is required. Use -s|--site."
[[ -z "${APP_ADMIN_PASSWORD}" ]] && fail "APP_ADMIN_PASSWORD is required. Use -a|--admin-password."

# Must run as the specified user
if [[ "$(id -un)" != "$FRAPPE_APP_USER" ]]; then
  fail "This script must be run as $FRAPPE_APP_USER. Try: sudo su - $FRAPPE_APP_USER"
fi

log "Executor: script=${SCRIPT_BASENAME} user=$(id -un) uid=$(id -u)"

cd ~

#############################################
# NVM / NODE / YARN
#############################################
log "Installing NVM & Node"
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash

export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"

nvm install 24
npm install -g yarn

#############################################
# UV + PYTHON
#############################################
log "Installing uv & Python"
curl -LsSf https://astral.sh/uv/install.sh | sh
source "$HOME/.local/bin/env"
uv python install 3.14 --default

#############################################
# BENCH
#############################################
log "Installing Bench CLI"
uv tool install frappe-bench==5.28

log "Initializing Bench"
bench init frappe-bench --frappe-branch version-16-beta

#############################################
# SITE CREATION
#############################################
cd ~/frappe-bench
log "Creating site: $SITE_NAME"
bench new-site "$SITE_NAME" \
  --db-root-username=root \
  --db-root-password="$FRAPPE_DB_PASSWORD" \
  --admin-password="$APP_ADMIN_PASSWORD"

#############################################
# APPS
#############################################
log "Installing apps"
bench get-app https://github.com/nhbcapps/mission-tracker.git
bench get-app https://github.com/nhbcapps/heritage-hub.git

~/frappe-bench/env/bin/python -m pip install qrcode==8.2

bench --site "$SITE_NAME" install-app mission_tracker
bench --site "$SITE_NAME" install-app heritage_hub

#############################################
# MIGRATIONS
#############################################
log "Running migrations"
bench --site "$SITE_NAME" execute heritage_hub.heritage_hub.lifecycle.setup_metadata.execute_all
bench --site "$SITE_NAME" execute heritage_hub.heritage_hub.lifecycle.migrate_contacts_to_worshippers.execute
bench --site "$SITE_NAME" execute heritage_hub.heritage_hub.lifecycle.migrate_guests_officers_to_users.execute
bench --site "$SITE_NAME" execute heritage_hub.heritage_hub.lifecycle.migrate_guests.execute
bench --site "$SITE_NAME" execute heritage_hub.heritage_hub.lifecycle.migrate_event_attendance.execute
bench --site "$SITE_NAME" execute heritage_hub.heritage_hub.lifecycle.migrate_ministries.execute
bench --site "$SITE_NAME" execute heritage_hub.heritage_hub.lifecycle.migrate_official_posts.execute

bench set-config -g developer_mode true

log "Setup (user phase) completed successfully"

