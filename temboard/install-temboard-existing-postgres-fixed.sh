#!/usr/bin/env bash
# TemBoard 10 installer using an EXISTING local PostgreSQL instance.
# Fixes included:
#   - Never installs/upgrades/initializes/deletes PostgreSQL.
#   - Runs /usr/share/temboard/auto_configure.sh as ROOT (required for system user/config creation).
#   - Does not run auto_configure.sh as the postgres OS user.
#   - Does not change ownership of /var/log/temboard-auto-configure.log to postgres.
#   - Safe to re-run: preserves existing TemBoard config and starts the service.
# Supported: AlmaLinux/Rocky/RHEL 9.x, Ubuntu 22.04/24.04.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.0.0"
TEMBOARD_PORT="8888"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log()  { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
die()  { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

trap 'rc=$?; if [[ $rc -ne 0 ]]; then printf "\n%s[ERROR]%s Installer stopped (exit %s). Review the messages above.\n" "$RED" "$NC" "$rc" >&2; fi' EXIT

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ -r /etc/os-release ]] || die "/etc/os-release not found"
# shellcheck disable=SC1091
. /etc/os-release

case "${ID:-}" in
  almalinux|rocky|rhel|centos)
    OS_FAMILY="rhel"
    [[ "${VERSION_ID%%.*}" == "9" ]] || die "Supported RHEL-family version: 9.x"
    ;;
  ubuntu)
    OS_FAMILY="debian"
    case "${VERSION_ID:-}" in 22.04|24.04) ;; *) die "Supported Ubuntu versions: 22.04 and 24.04" ;; esac
    ;;
  *)
    die "Unsupported OS: ${PRETTY_NAME:-unknown}. Supported: AlmaLinux/Rocky/RHEL 9.x and Ubuntu 22.04/24.04."
    ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required."

check_existing_postgres() {
  echo
  log "Checking the existing local PostgreSQL server (no PostgreSQL packages will be installed)."
  if ! command -v runuser >/dev/null 2>&1; then
    die "runuser is missing; cannot check the local postgres OS account."
  fi
  if ! getent passwd postgres >/dev/null 2>&1; then
    die "The local Linux account 'postgres' does not exist. This script expects PostgreSQL already installed on this host."
  fi

  local version
  if ! version="$(runuser -u postgres -- psql -X -d postgres -Atqc 'SELECT version();' 2>&1)"; then
    printf '%s\n' "$version" >&2
    die "Could not connect to the existing local PostgreSQL instance as OS user postgres. Check that PostgreSQL is running and local peer/socket authentication works."
  fi
  printf '%s\n' "$version"
  ok "Existing local PostgreSQL connection works."
}

install_temboard_package() {
  if command -v temboard >/dev/null 2>&1; then
    ok "TemBoard executable already exists; package installation will be skipped."
    return
  fi

  if [[ "$OS_FAMILY" == "rhel" ]]; then
    log "Installing prerequisites and official Dalibo Labs RPM repository..."
    dnf -y install epel-release curl ca-certificates openssl sudo
    dnf -y install https://yum.dalibo.org/labs/dalibo-labs-4-1.noarch.rpm
    # Intentionally install TemBoard only. No PostgreSQL packages are requested here.
    dnf -y install temboard
  else
    export DEBIAN_FRONTEND=noninteractive
    log "Installing prerequisites..."
    apt-get update
    apt-get install -y ca-certificates curl gnupg lsb-release openssl sudo postgresql-client
    log "Adding official Dalibo Labs APT repository..."
    echo "deb http://apt.dalibo.org/labs ${VERSION_CODENAME}-dalibo main" > /etc/apt/sources.list.d/dalibo-labs.list
    curl -fsSL https://apt.dalibo.org/labs/debian-dalibo.gpg -o /etc/apt/trusted.gpg.d/dalibo-labs.gpg
    chmod 0644 /etc/apt/trusted.gpg.d/dalibo-labs.gpg
    apt-get update
    apt-get install -y temboard
  fi

  command -v temboard >/dev/null 2>&1 || die "TemBoard package installation finished, but the temboard executable was not found."
  temboard --version || true
  ok "TemBoard package is installed."
}

configure_temboard() {
  local config="/etc/temboard/temboard.conf"
  local auto_config="/usr/share/temboard/auto_configure.sh"

  if [[ -s "$config" ]]; then
    warn "$config already exists. Preserving it and skipping auto-configuration."
    return 0
  fi

  [[ -x "$auto_config" ]] || die "TemBoard auto-configuration script not found or not executable: $auto_config"

  # IMPORTANT:
  # Run as root. The official script needs privileges to create the temboard system
  # user, write /etc/temboard, and generate TLS files. Running as postgres causes
  # errors such as 'tee: /dev/fd/3: Permission denied' and 'Creating system user'.
  log "Running official TemBoard auto-configuration as root..."
  if ! bash "$auto_config"; then
    die "TemBoard auto-configuration failed. Inspect /var/log/temboard-auto-configure.log if it exists. Do not run this script as the postgres OS user."
  fi

  [[ -s "$config" ]] || die "Auto-configuration returned success but $config was not created."
  ok "TemBoard auto-configuration completed."
}

start_temboard() {
  log "Enabling and starting TemBoard..."
  systemctl daemon-reload
  systemctl enable --now temboard
  if ! systemctl is-active --quiet temboard; then
    systemctl --no-pager --full status temboard || true
    journalctl -u temboard -n 80 --no-pager || true
    die "TemBoard service is not active."
  fi
  ok "TemBoard service is active."
}

verify_listener() {
  echo
  log "Checking the TemBoard listener..."
  if command -v ss >/dev/null 2>&1; then
    ss -lntp | grep -E "(:|\])${TEMBOARD_PORT}[[:space:]]" || warn "No listener detected on TCP ${TEMBOARD_PORT} yet. Check service logs."
  else
    warn "ss command not found; skipping listener check."
  fi
}

firewall_prompt() {
  echo
  read -r -p "Open TCP ${TEMBOARD_PORT} in an active supported host firewall? [y/N]: " fw
  if [[ "$fw" =~ ^[Yy]$ ]]; then
    if [[ "$OS_FAMILY" == "rhel" ]] && command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
      firewall-cmd --permanent --add-port="${TEMBOARD_PORT}/tcp"
      firewall-cmd --reload
      ok "Opened TCP ${TEMBOARD_PORT} in firewalld."
    elif [[ "$OS_FAMILY" == "debian" ]] && command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
      ufw allow "${TEMBOARD_PORT}/tcp"
      ok "Opened TCP ${TEMBOARD_PORT} in UFW."
    else
      warn "No active supported host firewall detected. If needed, open TCP ${TEMBOARD_PORT} in your external firewall/security group, preferably only to trusted IPs."
    fi
  fi
}

main() {
  echo "======================================================"
  echo " TemBoard Existing-PostgreSQL Installer v${SCRIPT_VERSION}"
  echo "======================================================"
  echo "OS: ${PRETTY_NAME:-$ID}"
  echo
  echo "This script installs TemBoard UI only and uses the existing LOCAL PostgreSQL instance."
  echo "It does NOT install, upgrade, initialize, or delete PostgreSQL."
  echo "It does NOT change PostgreSQL listen_addresses, pg_hba.conf, or port 5432."
  echo "Auto-configuration is run as root, as required for system-level setup."
  echo
  warn "Use this script on the database host. For a remote-only PostgreSQL server, configure TemBoard's repository connection according to the official documentation instead."
  read -r -p "Continue? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || die "Cancelled by user."

  check_existing_postgres
  install_temboard_package
  configure_temboard
  start_temboard
  verify_listener
  firewall_prompt

  echo
  echo "======================================================"
  echo " TemBoard setup completed"
  echo "======================================================"
  echo "Web UI       : https://$(hostname -f 2>/dev/null || hostname):${TEMBOARD_PORT}/"
  echo "Config       : /etc/temboard/temboard.conf"
  echo "Service      : systemctl status temboard --no-pager"
  echo "Logs         : journalctl -u temboard -n 100 --no-pager"
  echo "PostgreSQL   : existing local PostgreSQL was reused"
  echo
  warn "TemBoard may use a default administrator login on a fresh setup. Change it immediately according to the official TemBoard instructions."
  warn "The installer generates a self-signed TLS certificate. Configure a trusted certificate for production."
  warn "TemBoard UI installation does not automatically register a PostgreSQL monitoring agent. Install/configure the TemBoard agent separately."
}
main "$@"
