#!/usr/bin/env bash
# Fresh TemBoard server + PostgreSQL installer
# Supported OS: AlmaLinux/RHEL-compatible 9.x, Ubuntu 22.04/24.04
# PostgreSQL choices follow current TemBoard documentation: 13-17.
# This script does not remove existing PostgreSQL clusters or data.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0.0"
PG_SUPPORTED=(13 14 15 16 17)
PG_VERSION=""
TEMBOARD_PORT="8888"
INSTALL_PG="yes"
INSTALL_TEMBOARD="yes"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log()  { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
die()  { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
run()  { printf '+ '; printf '%q ' "$@"; printf '\n'; "$@"; }

cleanup() {
  rc=$?
  if [[ $rc -ne 0 ]]; then
    printf '\n%s[ERROR]%s Installation stopped (exit code %s). Review the messages above.\n' "$RED" "$NC" "$rc" >&2
  fi
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
command -v curl >/dev/null 2>&1 || true

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
else
  die "Cannot identify operating system (/etc/os-release missing)."
fi

case "${ID:-}" in
  almalinux|rocky|rhel|centos)
    OS_FAMILY="rhel"
    [[ "${VERSION_ID%%.*}" == "9" ]] || die "Only RHEL-compatible 9.x is supported by this script."
    ;;
  ubuntu)
    OS_FAMILY="debian"
    case "${VERSION_ID:-}" in 22.04|24.04) ;; *) die "Only Ubuntu 22.04 and 24.04 are supported." ;; esac
    ;;
  *)
    die "Unsupported OS: ${PRETTY_NAME:-unknown}. Supported: AlmaLinux 9.x and Ubuntu 22.04/24.04."
    ;;
esac

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

choose_pg_version() {
  echo
  echo "Select PostgreSQL major version supported by current TemBoard documentation:"
  echo "  1) PostgreSQL 13"
  echo "  2) PostgreSQL 14"
  echo "  3) PostgreSQL 15"
  echo "  4) PostgreSQL 16"
  echo "  5) PostgreSQL 17 (recommended default)"
  echo
  while true; do
    read -r -p "Enter choice [1-5] (default 5): " choice
    choice="${choice:-5}"
    case "$choice" in
      1) PG_VERSION=13; break ;;
      2) PG_VERSION=14; break ;;
      3) PG_VERSION=15; break ;;
      4) PG_VERSION=16; break ;;
      5) PG_VERSION=17; break ;;
      13|14|15|16|17) PG_VERSION="$choice"; break ;;
      *) echo "Invalid choice. Enter 1-5 or a version number 13-17." ;;
    esac
  done
}

confirm_plan() {
  echo
  echo "======================================================"
  echo " TemBoard fresh installation"
  echo "======================================================"
  echo "OS             : ${PRETTY_NAME:-$ID}"
  echo "PostgreSQL     : ${PG_VERSION}"
  echo "TemBoard UI    : HTTPS port ${TEMBOARD_PORT}"
  echo "Install mode   : PostgreSQL + TemBoard server"
  echo
  warn "This script installs packages and initializes the selected PostgreSQL version only if its data directory is not already initialized."
  warn "It will not remove existing clusters or database data."
  echo
  read -r -p "Continue? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "Cancelled by user."
}

install_rhel() {
  log "Installing prerequisites and EPEL..."
  dnf -y install epel-release curl ca-certificates openssl python3 sudo
  log "Adding official PostgreSQL PGDG repository..."
  dnf -y install "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm"
  # Disable the distribution PostgreSQL module so PGDG packages can be selected.
  dnf -qy module disable postgresql || true

  local server_pkg="postgresql${PG_VERSION}-server"
  local client_pkg="postgresql${PG_VERSION}"
  local contrib_pkg="postgresql${PG_VERSION}-contrib"
  log "Installing PostgreSQL ${PG_VERSION} packages..."
  dnf -y install "$server_pkg" "$client_pkg" "$contrib_pkg"

  local setup="/usr/pgsql-${PG_VERSION}/bin/postgresql-${PG_VERSION}-setup"
  local data_dir="/var/lib/pgsql/${PG_VERSION}/data"
  local service="postgresql-${PG_VERSION}"

  [[ -x "$setup" ]] || die "Expected PostgreSQL setup utility not found: $setup"
  if [[ ! -s "${data_dir}/PG_VERSION" ]]; then
    if [[ -e "$data_dir" ]] && [[ -n "$(find "$data_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      die "Data directory $data_dir exists but is not initialized (or is not a standard cluster). Refusing to overwrite it."
    fi
    log "Initializing PostgreSQL ${PG_VERSION} cluster..."
    "$setup" initdb
  else
    existing="$(cat "${data_dir}/PG_VERSION")"
    [[ "$existing" == "$PG_VERSION" ]] || die "Data directory version mismatch: expected $PG_VERSION, found $existing."
    warn "PostgreSQL data directory already initialized; preserving it."
  fi

  systemctl enable --now "$service"
  systemctl is-active --quiet "$service" || die "$service did not start."
  ok "PostgreSQL ${PG_VERSION} is active."
}

install_debian() {
  export DEBIAN_FRONTEND=noninteractive
  log "Installing prerequisites..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release openssl python3 sudo

  log "Adding official PostgreSQL PGDG APT repository..."
  install -d -m 0755 /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor --yes -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg
  chmod 0644 /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update

  log "Installing PostgreSQL ${PG_VERSION} packages..."
  apt-get install -y "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" "postgresql-contrib-${PG_VERSION}"

  # Debian/Ubuntu package scripts normally create and start the cluster.
  if ! pg_lsclusters --no-header | awk -v v="$PG_VERSION" '$1==v {found=1} END {exit !found}'; then
    log "No PostgreSQL ${PG_VERSION} cluster found; creating the default cluster..."
    pg_createcluster "$PG_VERSION" main --start
  else
    warn "PostgreSQL ${PG_VERSION} cluster already exists; preserving its data."
    pg_ctlcluster "$PG_VERSION" main start || true
  fi
  systemctl enable postgresql
  pg_lsclusters
  ok "PostgreSQL ${PG_VERSION} packages are installed."
}

install_temboard_repo_rhel() {
  log "Configuring the official Dalibo Labs RPM repository..."
  dnf -y install epel-release
  dnf -y install https://yum.dalibo.org/labs/dalibo-labs-4-1.noarch.rpm
}

install_temboard_repo_debian() {
  log "Configuring the official Dalibo Labs APT repository..."
  echo "deb http://apt.dalibo.org/labs ${VERSION_CODENAME}-dalibo main" > /etc/apt/sources.list.d/dalibo-labs.list
  curl -fsSL https://apt.dalibo.org/labs/debian-dalibo.gpg -o /etc/apt/trusted.gpg.d/dalibo-labs.gpg
  chmod 0644 /etc/apt/trusted.gpg.d/dalibo-labs.gpg
  apt-get update
}

install_temboard() {
  if [[ "$OS_FAMILY" == "rhel" ]]; then
    install_temboard_repo_rhel
    dnf -y install temboard
  else
    install_temboard_repo_debian
    apt-get install -y temboard
  fi

  require_cmd temboard
  temboard --version || true

  # TemBoard's documented post-install auto-configure script uses a local
  # PostgreSQL cluster accessible to the postgres OS account.
  local auto_config="/usr/share/temboard/auto_configure.sh"
  if [[ -x "$auto_config" ]]; then
    if runuser -u postgres -- psql -X -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then
      log "Running TemBoard automatic configuration..."
      if "$auto_config"; then
        ok "TemBoard auto-configuration completed."
      else
        warn "TemBoard auto-configuration failed. Package is installed; see troubleshooting notes below."
      fi
    else
      warn "Local postgres account cannot connect through the default socket. Skipping auto-configuration."
    fi
  else
    warn "Auto-configuration script not found at $auto_config. Check package contents and configure TemBoard manually."
  fi

  if [[ -f /etc/temboard/temboard.conf ]]; then
    # Do not rewrite configuration automatically; changing secrets/config may disrupt an existing setup.
    log "Found /etc/temboard/temboard.conf; leaving it unchanged."
  fi

  if systemctl list-unit-files temboard.service >/dev/null 2>&1; then
    systemctl enable temboard
    if systemctl restart temboard; then
      ok "TemBoard service started."
    else
      warn "TemBoard service did not start. Inspect: journalctl -u temboard -xe"
    fi
  else
    warn "temboard.service unit was not found. Inspect the installed package and its post-install output."
  fi
}

open_firewall() {
  if [[ "$OS_FAMILY" == "rhel" ]] && command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    read -r -p "Open TCP ${TEMBOARD_PORT} in firewalld? [y/N]: " fw
    if [[ "$fw" =~ ^[Yy]$ ]]; then
      firewall-cmd --permanent --add-port="${TEMBOARD_PORT}/tcp"
      firewall-cmd --reload
      ok "Opened TCP ${TEMBOARD_PORT} in firewalld."
    fi
  elif [[ "$OS_FAMILY" == "debian" ]] && command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    read -r -p "Open TCP ${TEMBOARD_PORT} in UFW? [y/N]: " fw
    if [[ "$fw" =~ ^[Yy]$ ]]; then
      ufw allow "${TEMBOARD_PORT}/tcp"
      ok "Opened TCP ${TEMBOARD_PORT} in UFW."
    fi
  else
    warn "No active supported host firewall detected; review your firewall/security-group rules for TCP ${TEMBOARD_PORT}."
  fi
}

show_summary() {
  local host
  host="$(hostname -f 2>/dev/null || hostname)"
  echo
  echo "======================================================"
  echo " Installation summary"
  echo "======================================================"
  echo "PostgreSQL selected : ${PG_VERSION}"
  echo "TemBoard URL        : https://${host}:${TEMBOARD_PORT}/"
  echo "TemBoard config     : /etc/temboard/temboard.conf"
  echo "TemBoard service    : systemctl status temboard"
  echo
  echo "Next steps:"
  echo "  1. Check service: systemctl --no-pager --full status temboard"
  echo "  2. Check logs:    journalctl -u temboard -n 100 --no-pager"
  echo "  3. Check PG:      runuser -u postgres -- psql -X -d postgres -c 'SELECT version();'"
  echo "  4. Log in to the UI and immediately change the default admin password if it remains admin/admin."
  echo
  warn "The documentation describes a default admin/admin login on some installations. Treat it as insecure and change it immediately."
  warn "TemBoard UI uses HTTPS with a self-signed certificate by default; replace it with a trusted certificate for production."
}

main() {
  echo "TemBoard Installer ${SCRIPT_VERSION}"
  echo "This installer configures a local PostgreSQL cluster for the TemBoard repository."
  choose_pg_version
  confirm_plan

  if [[ "$OS_FAMILY" == "rhel" ]]; then
    install_rhel
  else
    install_debian
  fi

  install_temboard
  open_firewall
  show_summary
}
main "$@"
