#!/usr/bin/env bash
# Ensure we are running under bash even if invoked via sh or a non-bash shell
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi
set -Eeuo pipefail

# How to run (root phase):
#   sudo /opt/frappe-setup/root-system-setup.sh -u frappe
# Next (as the created user):
#   sudo su - frappe
#   /opt/frappe-setup/setup-frappe-app.sh -u frappe -p 'root_pwd' -s 'apps.localhost' -a 'admin_pwd'

# Ensure script is run as root
if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run as root. Try: sudo $0"
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
  -h, --help              Show this help and exit

Example:
  sudo $0 -u frappe
USAGE
}
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--user) FRAPPE_APP_USER="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1"; echo; usage; exit 1 ;;
    esac
  done
}
parse_args "$@"

# Validate required values (env fallback)
FRAPPE_APP_USER="${FRAPPE_APP_USER:-}"
[[ -z "${FRAPPE_APP_USER}" ]] && fail "FRAPPE_APP_USER is required. Use -u|--user."

log "Executor: script=${SCRIPT_BASENAME} user=$(id -un) uid=$(id -u)"

#############################################
# ROOT-LEVEL OPERATIONS
#############################################
log "Adding SSH public key for root (if not present)"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
grep -q "ifeoluwa.akande@glovoapp.com" /root/.ssh/authorized_keys 2>/dev/null || echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMGtd5hMwZ3M5EBQzy05yre1/vi3Lsm1C+7zgvWegYK0 ifeoluwa.akande@glovoapp.com" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

log "Creating user: $FRAPPE_APP_USER"
if id -u "$FRAPPE_APP_USER" >/dev/null 2>&1; then
  log "User $FRAPPE_APP_USER already exists. Skipping."
else
  adduser --disabled-password --gecos "" "$FRAPPE_APP_USER"
  usermod -aG sudo "$FRAPPE_APP_USER"
fi

log "Configuring passwordless sudo"
printf '%s\n' "$FRAPPE_APP_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$FRAPPE_APP_USER"
chmod 440 "/etc/sudoers.d/$FRAPPE_APP_USER"
visudo -cf "/etc/sudoers.d/$FRAPPE_APP_USER" >/dev/null || fail "Invalid sudoers entry for $FRAPPE_APP_USER"

log "Installing system packages"
apt update
apt install -y \
  git redis-server \
  mariadb-server mariadb-client \
  libmariadb-dev \
  build-essential python3-dev pkg-config \
  xvfb libfontconfig

log "Root package installation complete."
echo
echo "Next: switch to the $FRAPPE_APP_USER user and run setup-user.sh with the same parameters:"
echo "  sudo su - $FRAPPE_APP_USER"
echo "  /opt/frappe-setup/setup-frappe-app.sh -u '$FRAPPE_APP_USER' -p '******' -s 'your.site' -a '******'"
echo
log "Done."

