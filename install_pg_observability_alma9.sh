#!/usr/bin/env bash
# PostgreSQL observability bootstrap for AlmaLinux/RHEL 9+
# Installs: pg_stat_statements, postgres_exporter, Grafana Alloy, OpenObserve, pgBadger
# Does NOT install Prometheus or Grafana. Review before running on production.
set -Eeuo pipefail
umask 077

LOG_FILE="/var/log/pg-observability-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

say() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: sudo bash $0"; }

need_root
[[ -r /etc/os-release ]] || fail "Cannot identify operating system."
. /etc/os-release
[[ "${ID:-}" == "almalinux" || "${ID_LIKE:-}" == *rhel* || "${ID:-}" == "rocky" || "${ID:-}" == "rhel" ]] || fail "This script targets AlmaLinux/RHEL-compatible 9+. Detected: ${PRETTY_NAME:-unknown}"
[[ "${VERSION_ID%%.*}" -ge 9 ]] || fail "RHEL-compatible version 9 or newer is required."
command -v dnf >/dev/null || fail "dnf is required."

say "This script installs OpenObserve, Grafana Alloy, postgres_exporter, pgBadger and configures pg_stat_statements."
say "It may restart PostgreSQL once to enable shared_preload_libraries and the logging collector. Existing PostgreSQL settings are backed up first."
read -r -p "Continue? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

say "Installing base dependencies and Grafana Alloy repository"
dnf install -y curl jq tar gzip ca-certificates perl policycoreutils-python-utils shadow-utils openssl dnf-plugins-core

# PostgreSQL selection: use an existing installation or install a chosen PGDG major version.
# PGDG packages are versioned and can coexist with another major version; this script only
# initializes a new cluster when the selected version has no existing data directory.
find_postgres_psql() {
  local v
  for v in 18 17 16 15 14; do
    if [[ -x "/usr/pgsql-${v}/bin/psql" ]]; then
      printf '%s\n' "/usr/pgsql-${v}/bin/psql"
      return 0
    fi
  done
  command -v psql 2>/dev/null || true
}

PSQL="$(find_postgres_psql)"
if [[ -z "$PSQL" ]]; then
  say "PostgreSQL client was not found. Select the PostgreSQL major version to install."
  printf '  1) PostgreSQL 18\n  2) PostgreSQL 17\n  3) PostgreSQL 16\n  4) PostgreSQL 15\n  5) PostgreSQL 14\n'
  read -r -p 'Choose PostgreSQL version [1-5]: ' PG_CHOICE
  case "$PG_CHOICE" in
    1) PG_INSTALL_VERSION=18 ;; 2) PG_INSTALL_VERSION=17 ;; 3) PG_INSTALL_VERSION=16 ;;
    4) PG_INSTALL_VERSION=15 ;; 5) PG_INSTALL_VERSION=14 ;;
    *) fail "Invalid PostgreSQL version selection." ;;
  esac
  EL_MAJOR="${VERSION_ID%%.*}"
  REPO_ARCH="$(uname -m)"
  [[ "$REPO_ARCH" == "x86_64" || "$REPO_ARCH" == "aarch64" ]] || fail "Unsupported architecture for PGDG repository: $REPO_ARCH"
  say "Adding official PostgreSQL PGDG repository for EL ${EL_MAJOR} (${REPO_ARCH})"
  dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${EL_MAJOR}-${REPO_ARCH}/pgdg-redhat-repo-latest.noarch.rpm"
  dnf -qy module disable postgresql || true
  say "Installing PostgreSQL ${PG_INSTALL_VERSION} server, client and contrib packages"
  dnf install -y "postgresql${PG_INSTALL_VERSION}" "postgresql${PG_INSTALL_VERSION}-server" "postgresql${PG_INSTALL_VERSION}-contrib"
  PSQL="/usr/pgsql-${PG_INSTALL_VERSION}/bin/psql"
  PG_SETUP="/usr/pgsql-${PG_INSTALL_VERSION}/bin/postgresql-${PG_INSTALL_VERSION}-setup"
  PG_SERVICE="postgresql-${PG_INSTALL_VERSION}.service"
  [[ -x "$PSQL" ]] || fail "PostgreSQL ${PG_INSTALL_VERSION} client installation did not create $PSQL"
  if [[ ! -s "/var/lib/pgsql/${PG_INSTALL_VERSION}/data/PG_VERSION" ]]; then
    say "Initializing new PostgreSQL ${PG_INSTALL_VERSION} database cluster"
    "$PG_SETUP" initdb
  else
    say "Existing PostgreSQL ${PG_INSTALL_VERSION} data directory detected; preserving it."
  fi
  systemctl enable --now "$PG_SERVICE"
  systemctl is-active --quiet "$PG_SERVICE" || fail "PostgreSQL service $PG_SERVICE did not start. Check journalctl -u $PG_SERVICE."
else
  say "Found PostgreSQL client: $PSQL"
  read -r -p "Use this PostgreSQL installation for monitoring? [Y/n] " USE_EXISTING
  if [[ "$USE_EXISTING" =~ ^[Nn]$ ]]; then
    printf '  1) PostgreSQL 18\n  2) PostgreSQL 17\n  3) PostgreSQL 16\n  4) PostgreSQL 15\n  5) PostgreSQL 14\n'
    read -r -p 'Choose PostgreSQL version to install/use [1-5]: ' PG_CHOICE
    case "$PG_CHOICE" in
      1) PG_INSTALL_VERSION=18 ;; 2) PG_INSTALL_VERSION=17 ;; 3) PG_INSTALL_VERSION=16 ;;
      4) PG_INSTALL_VERSION=15 ;; 5) PG_INSTALL_VERSION=14 ;;
      *) fail "Invalid PostgreSQL version selection." ;;
    esac
    EL_MAJOR="${VERSION_ID%%.*}"
    REPO_ARCH="$(uname -m)"
    [[ "$REPO_ARCH" == "x86_64" || "$REPO_ARCH" == "aarch64" ]] || fail "Unsupported architecture for PGDG repository: $REPO_ARCH"
    dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${EL_MAJOR}-${REPO_ARCH}/pgdg-redhat-repo-latest.noarch.rpm"
    dnf -qy module disable postgresql || true
    dnf install -y "postgresql${PG_INSTALL_VERSION}" "postgresql${PG_INSTALL_VERSION}-server" "postgresql${PG_INSTALL_VERSION}-contrib"
    PSQL="/usr/pgsql-${PG_INSTALL_VERSION}/bin/psql"
    PG_SETUP="/usr/pgsql-${PG_INSTALL_VERSION}/bin/postgresql-${PG_INSTALL_VERSION}-setup"
    PG_SERVICE="postgresql-${PG_INSTALL_VERSION}.service"
    [[ -x "$PSQL" ]] || fail "PostgreSQL ${PG_INSTALL_VERSION} client installation did not create $PSQL"
    if [[ ! -s "/var/lib/pgsql/${PG_INSTALL_VERSION}/data/PG_VERSION" ]]; then "$PG_SETUP" initdb; fi
    systemctl enable --now "$PG_SERVICE"
    systemctl is-active --quiet "$PG_SERVICE" || fail "PostgreSQL service $PG_SERVICE did not start."
  fi
fi

rpm --import https://rpm.grafana.com/gpg.key
cat > /etc/yum.repos.d/grafana.repo <<'REPO'
[grafana]
name=Grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
REPO
dnf install -y alloy

# Detect a working local PostgreSQL administrative connection. Use the selected/installed
# client by absolute path because PGDG clients may not be in root's PATH.
[[ -x "$PSQL" ]] || PSQL="$(command -v psql || true)"
[[ -n "$PSQL" && -x "$PSQL" ]] || fail "PostgreSQL client is still unavailable after installation."
PGADMIN=(runuser -u postgres -- "$PSQL" -X -v ON_ERROR_STOP=1 -Atqc)
if ! "${PGADMIN[@]}" 'SELECT 1' >/dev/null 2>&1; then
  fail "Cannot connect locally as OS user postgres. Verify PostgreSQL is running and that local peer/socket administration works. No PostgreSQL configuration was changed."
fi
PGMAJOR="$("${PGADMIN[@]}" 'SHOW server_version_num' | awk '{print int($1/10000)}')"
PGDATA="$("${PGADMIN[@]}" 'SHOW data_directory')"
PGCONF="$("${PGADMIN[@]}" 'SHOW config_file')"
PGHBA="$("${PGADMIN[@]}" 'SHOW hba_file')"
PGPORT="$("${PGADMIN[@]}" 'SHOW port')"
PGSERVICE=""
while read -r unit _; do
  [[ "$unit" == postgresql*.service ]] && PGSERVICE="$unit" && break
done < <(systemctl list-units --type=service --state=running --no-legend | awk '{print $1, $2}')
[[ -n "$PGSERVICE" ]] || fail "Could not identify a running PostgreSQL systemd service. Found PGDATA=$PGDATA; configure/restart PostgreSQL manually and rerun."
say "Detected PostgreSQL $PGMAJOR, data directory $PGDATA, config $PGCONF, port $PGPORT, service $PGSERVICE"

# Install the contrib package that matches PGDG or distribution packaging.
say "Installing PostgreSQL contrib package for pg_stat_statements"
if ! rpm -q "postgresql${PGMAJOR}-contrib" >/dev/null 2>&1 && ! rpm -q postgresql-contrib >/dev/null 2>&1; then
  dnf install -y "postgresql${PGMAJOR}-contrib" || dnf install -y postgresql-contrib || say "WARNING: Could not determine the contrib package name. The extension must be available before continuing."
fi

# Backup config and update settings with ALTER SYSTEM so existing config files are not rewritten.
BACKUP_DIR="/root/pg-observability-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a "$PGCONF" "$BACKUP_DIR/"
cp -a "$PGHBA" "$BACKUP_DIR/" 2>/dev/null || true
say "Configuration backup saved under $BACKUP_DIR"

# Preserve any existing shared_preload_libraries entries.
EXISTING_PRELOAD="$("${PGADMIN[@]}" "SHOW shared_preload_libraries" | tr -d '[:space:]')"
if [[ ",$EXISTING_PRELOAD," != *,pg_stat_statements,* ]]; then
  if [[ -n "$EXISTING_PRELOAD" ]]; then NEW_PRELOAD="${EXISTING_PRELOAD},pg_stat_statements"; else NEW_PRELOAD="pg_stat_statements"; fi
  # Use SQL quoting for a value that is a simple list of library names.
  "${PGADMIN[@]}" "ALTER SYSTEM SET shared_preload_libraries = '$NEW_PRELOAD'"
fi
"${PGADMIN[@]}" "ALTER SYSTEM SET logging_collector = 'on'"
"${PGADMIN[@]}" "ALTER SYSTEM SET log_destination = 'stderr'"
"${PGADMIN[@]}" "ALTER SYSTEM SET log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'"
"${PGADMIN[@]}" "ALTER SYSTEM SET log_rotation_age = '1d'"
"${PGADMIN[@]}" "ALTER SYSTEM SET log_rotation_size = '100MB'"
"${PGADMIN[@]}" "ALTER SYSTEM SET log_min_duration_statement = '1000'"
"${PGADMIN[@]}" "ALTER SYSTEM SET log_checkpoints = 'on'"
"${PGADMIN[@]}" "ALTER SYSTEM SET log_lock_waits = 'on'"
"${PGADMIN[@]}" "ALTER SYSTEM SET deadlock_timeout = '1s'"
"${PGADMIN[@]}" "ALTER SYSTEM SET log_line_prefix = '%m [%p] user=%u,db=%d,app=%a,client=%h '"

say "Restarting PostgreSQL service $PGSERVICE to apply startup settings"
systemctl restart "$PGSERVICE"
systemctl is-active --quiet "$PGSERVICE" || fail "PostgreSQL did not become active after restart. Check: journalctl -u $PGSERVICE -n 100"

# Create the extension in the postgres maintenance database; it can also be enabled in each application DB.
runuser -u postgres -- "$PSQL" -X -v ON_ERROR_STOP=1 -d postgres -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'

# Create a least-privilege monitoring role, with a randomly generated URL-safe password.
EXPORTER_PASS="$(openssl rand -hex 24)"
if runuser -u postgres -- "$PSQL" -X -d postgres -Atqc "SELECT 1 FROM pg_roles WHERE rolname='postgres_exporter'" | grep -qx 1; then
  runuser -u postgres -- "$PSQL" -X -v ON_ERROR_STOP=1 -d postgres -c "ALTER ROLE postgres_exporter WITH LOGIN PASSWORD '${EXPORTER_PASS}'"
else
  runuser -u postgres -- "$PSQL" -X -v ON_ERROR_STOP=1 -d postgres -c "CREATE ROLE postgres_exporter LOGIN PASSWORD '${EXPORTER_PASS}'"
fi
runuser -u postgres -- "$PSQL" -X -v ON_ERROR_STOP=1 -d postgres -c 'GRANT pg_monitor TO postgres_exporter'

# Install latest postgres_exporter release for x86_64 or aarch64.
ARCH="$(uname -m)"
case "$ARCH" in x86_64) ASSET_ARCH="amd64" ;; aarch64|arm64) ASSET_ARCH="arm64" ;; *) fail "Unsupported architecture for postgres_exporter: $ARCH" ;; esac
say "Downloading latest postgres_exporter release"
EXPORTER_URL="$(curl -fsSL https://api.github.com/repos/prometheus-community/postgres_exporter/releases/latest | jq -r --arg suffix "linux-${ASSET_ARCH}.tar.gz" '.assets[] | select(.name | endswith($suffix)) | .browser_download_url' | head -n1)"
[[ -n "$EXPORTER_URL" && "$EXPORTER_URL" != "null" ]] || fail "Could not find a postgres_exporter release asset for linux-${ASSET_ARCH}."
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
curl -fL --retry 3 "$EXPORTER_URL" -o "$TMPDIR/exporter.tar.gz"
tar -xzf "$TMPDIR/exporter.tar.gz" -C "$TMPDIR"
EXPORTER_BIN="$(find "$TMPDIR" -type f -name postgres_exporter -perm /111 | head -n1)"
[[ -n "$EXPORTER_BIN" ]] || fail "postgres_exporter binary not found in release archive."
install -m 0755 "$EXPORTER_BIN" /usr/local/bin/postgres_exporter

id postgres_exporter >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin postgres_exporter
cat > /etc/postgres_exporter.env <<EOF
DATA_SOURCE_URI=127.0.0.1:${PGPORT}/postgres?sslmode=disable
DATA_SOURCE_USER=postgres_exporter
DATA_SOURCE_PASS=${EXPORTER_PASS}
EOF
chown root:postgres_exporter /etc/postgres_exporter.env
chmod 0640 /etc/postgres_exporter.env
cat > /etc/systemd/system/postgres_exporter.service <<'UNIT'
[Unit]
Description=Prometheus PostgreSQL Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=postgres_exporter
Group=postgres_exporter
EnvironmentFile=/etc/postgres_exporter.env
ExecStart=/usr/local/bin/postgres_exporter --web.listen-address=127.0.0.1:9187 --collector.stat_statements
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now postgres_exporter

# Install OpenObserve binary as a localhost-only service.
say "Installing OpenObserve (latest stable GitHub release)"
OO_TAG="$(curl -fsSL https://api.github.com/repos/openobserve/openobserve/releases/latest | jq -r '.tag_name')"
[[ -n "$OO_TAG" && "$OO_TAG" != "null" ]] || fail "Could not resolve the latest OpenObserve release."
OO_URL="https://downloads.openobserve.ai/releases/openobserve/${OO_TAG}/openobserve-${OO_TAG}-linux-${ASSET_ARCH}.tar.gz"
if ! curl -fsSL "$OO_URL" -o "$TMPDIR/openobserve.tar.gz"; then
  say "WARNING: Official release URL did not match expected asset naming. OpenObserve was not replaced; install it using the current official instructions and rerun the integration section manually."
  OO_INSTALLED=0
else
  tar -xzf "$TMPDIR/openobserve.tar.gz" -C "$TMPDIR"
  OO_BIN="$(find "$TMPDIR" -type f -name openobserve -perm /111 | head -n1)"
  if [[ -z "$OO_BIN" ]]; then
    say "WARNING: OpenObserve binary not found in archive; skipping OpenObserve service installation."
    OO_INSTALLED=0
  else
    id openobserve >/dev/null 2>&1 || useradd --system --home-dir /var/lib/openobserve --create-home --shell /sbin/nologin openobserve
    install -m 0755 "$OO_BIN" /usr/local/bin/openobserve
    install -d -o openobserve -g openobserve -m 0750 /var/lib/openobserve
    if [[ ! -f /etc/openobserve.env ]]; then
      read -r -p "OpenObserve admin email (e.g. admin@example.com): " OO_EMAIL
      [[ "$OO_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || fail "A valid email address is required."
      read -r -s -p "OpenObserve admin password (minimum 12 characters): " OO_PASSWORD; echo
      [[ "$OO_PASSWORD" =~ ^[A-Za-z0-9!@#%+=:_,.-]{12,}$ ]] || fail "Use at least 12 characters from letters, numbers, and !@#%+=:_,.- (quotes and backslashes are excluded for safe configuration)."
      cat > /etc/openobserve.env <<EOF
ZO_ROOT_USER_EMAIL=${OO_EMAIL}
ZO_ROOT_USER_PASSWORD=${OO_PASSWORD}
ZO_DATA_DIR=/var/lib/openobserve
ZO_HTTP_ADDR=127.0.0.1
EOF
      chmod 0600 /etc/openobserve.env
    else
      say "Keeping existing /etc/openobserve.env (credentials/settings were not overwritten)."
    fi
    cat > /etc/systemd/system/openobserve.service <<'UNIT'
[Unit]
Description=OpenObserve observability platform
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openobserve
Group=openobserve
EnvironmentFile=/etc/openobserve.env
ExecStart=/usr/local/bin/openobserve
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/openobserve

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now openobserve
    OO_INSTALLED=1
  fi
fi

# Install pgBadger from EPEL when available.
say "Installing pgBadger"
dnf config-manager --set-enabled crb || true
dnf install -y epel-release || true
dnf install -y pgbadger || say "WARNING: pgBadger package was not found in enabled repositories. Enable EPEL/CRB for this AlmaLinux release, then run: dnf install pgbadger"

# Configure Alloy to scrape exporter and remote-write metrics to local OpenObserve.
# OpenObserve Prometheus remote-write endpoint and basic auth use the configured root credentials.
if [[ "${OO_INSTALLED:-0}" -eq 1 || -f /etc/openobserve.env ]]; then
  if [[ -f /etc/openobserve.env ]]; then
    # Read only the expected key/value entries; avoid sourcing an arbitrary env file.
    OO_EMAIL="$(sed -n 's/^ZO_ROOT_USER_EMAIL=//p' /etc/openobserve.env | tail -n1)"
    OO_PASSWORD="$(sed -n 's/^ZO_ROOT_USER_PASSWORD=//p' /etc/openobserve.env | tail -n1)"
    if [[ -n "$OO_EMAIL" && -n "$OO_PASSWORD" ]]; then
      install -d -o root -g alloy -m 0750 /etc/alloy
      cat > /etc/alloy/config.alloy <<EOF
// PostgreSQL metrics -> Grafana Alloy -> OpenObserve Prometheus remote-write API
prometheus.scrape "postgres_exporter" {
  targets = [{ "__address__" = "127.0.0.1:9187", "job" = "postgresql" }]
  scrape_interval = "15s"
  forward_to = [prometheus.remote_write.openobserve.receiver]
}

prometheus.remote_write "openobserve" {
  endpoint {
    url = "http://127.0.0.1:5080/api/default/prometheus/api/v1/write"
    basic_auth {
      username = "${OO_EMAIL}"
      password = "${OO_PASSWORD}"
    }
  }
}
EOF
      chown root:alloy /etc/alloy/config.alloy
      chmod 0640 /etc/alloy/config.alloy
      systemctl enable --now alloy
      systemctl restart alloy
    else
      say "WARNING: Could not read OpenObserve credentials; Alloy installed but not configured to remote-write metrics."
    fi
  fi
fi

# Keep exporter and Alloy private; do not open firewall ports automatically.
say "Checking service states"
for svc in "$PGSERVICE" postgres_exporter alloy; do
  printf '%-28s ' "$svc"; systemctl is-active "$svc" || true
done
if systemctl list-unit-files --no-legend | awk '{print $1}' | grep -qx 'openobserve.service'; then
  printf '%-28s ' openobserve; systemctl is-active openobserve || true
fi

cat <<EOF

INSTALLATION FINISHED
=====================
PostgreSQL version : $PGMAJOR
PostgreSQL service : $PGSERVICE
PostgreSQL logs    : $PGDATA/log/ (verify with: SHOW log_directory;)
Exporter metrics   : http://127.0.0.1:9187/metrics (local only)
OpenObserve UI     : http://127.0.0.1:5080 (localhost only; use SSH tunnel for remote access)
Alloy config       : /etc/alloy/config.alloy
Exporter env       : /etc/postgres_exporter.env (password protected)
Backup directory   : $BACKUP_DIR
Install log        : $LOG_FILE

NEXT STEPS
----------
1. Verify: curl -fsS http://127.0.0.1:9187/metrics | head
2. Verify: systemctl status postgres_exporter alloy openobserve --no-pager
3. To open the OpenObserve UI securely from your workstation, use an SSH tunnel:
   ssh -L 5080:127.0.0.1:5080 USER@SERVER
   Then browse to http://127.0.0.1:5080 on your workstation.
4. pg_stat_statements was enabled in database 'postgres'. Enable it in each application database as needed:
   sudo -u postgres psql -d YOUR_DATABASE -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'
5. Review PostgreSQL logging volume. The script logs statements taking >= 1 second; adjust log_min_duration_statement to suit your workload.
6. OpenObserve remote-write ingestion and Alloy health must be verified in the UI/logs. Check with:
   journalctl -u alloy -n 100 --no-pager
   journalctl -u openobserve -n 100 --no-pager

Security: exporter and OpenObserve listen on loopback only; no firewall ports were opened.
EOF
