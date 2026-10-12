#!/usr/bin/env bash
# PostgreSQL observability bootstrap for AlmaLinux/RHEL 9+
# Installs: pg_stat_statements, postgres_exporter, node_exporter, Grafana Alloy, OpenObserve, pgBadger
# Also configures PostgreSQL log ingestion, ACLs, and stages dashboard JSON imports.
# Does NOT install Prometheus or Grafana. Review before running on production.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="/root/openobserve-dashboards"
LOG_FILE="/var/log/pg-observability-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

say() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run as root: sudo bash $0"; }

PG_VERSION_REQUESTED=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --postgres-version|--pg-version)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a version (14, 15, 16, 17, or 18)." >&2; exit 2; }
      PG_VERSION_REQUESTED="$2"; shift 2 ;;
    --postgres-version=*|--pg-version=*)
      PG_VERSION_REQUESTED="${1#*=}"; shift ;;
    -h|--help)
      echo "Usage: sudo bash $0 [--postgres-version 14|15|16|17|18]"
      echo "If omitted, the script prompts for a version when PostgreSQL needs to be installed."
      exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; echo "Usage: sudo bash $0 [--postgres-version 14|15|16|17|18]" >&2; exit 2 ;;
  esac
done
if [[ -n "$PG_VERSION_REQUESTED" && ! "$PG_VERSION_REQUESTED" =~ ^(14|15|16|17|18)$ ]]; then
  echo "ERROR: Unsupported PostgreSQL version '$PG_VERSION_REQUESTED'. Choose 14, 15, 16, 17, or 18." >&2
  exit 2
fi

choose_pg_version() {
  if [[ -n "$PG_VERSION_REQUESTED" ]]; then
    PG_INSTALL_VERSION="$PG_VERSION_REQUESTED"
    say "PostgreSQL version specified on command line: $PG_INSTALL_VERSION"
    return
  fi
  echo "Select PostgreSQL major version to install:"
  select PG_INSTALL_VERSION in 18 17 16 15 14; do
    [[ -n "${PG_INSTALL_VERSION:-}" ]] && break
    echo "Invalid selection. Choose 18, 17, 16, 15, or 14."
  done
}

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
dnf install -y curl jq tar gzip ca-certificates perl policycoreutils-python-utils shadow-utils openssl dnf-plugins-core acl

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
  choose_pg_version
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
  if [[ -n "$PG_VERSION_REQUESTED" ]]; then
    DETECTED_PSQL_VERSION="$("$PSQL" --version | sed -E 's/.* ([0-9]+)\..*/\1/')"
    if [[ "$DETECTED_PSQL_VERSION" == "$PG_VERSION_REQUESTED" ]]; then
      USE_EXISTING=Y
      say "Using existing PostgreSQL client version $DETECTED_PSQL_VERSION as requested."
    else
      USE_EXISTING=N
      say "Requested PostgreSQL $PG_VERSION_REQUESTED differs from detected client $DETECTED_PSQL_VERSION; installing/selecting requested version."
    fi
  else
    read -r -p "Use this PostgreSQL installation for monitoring? [Y/n] " USE_EXISTING
  fi
  if [[ "$USE_EXISTING" =~ ^[Nn]$ ]]; then
    choose_pg_version
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

# Install node_exporter for OS-level CPU, memory, disk, network, and load metrics.
say "Installing node_exporter for system metrics"
NODE_EXPORTER_URL="$(curl -fsSL https://api.github.com/repos/prometheus/node_exporter/releases/latest | jq -r --arg suffix "linux-${ASSET_ARCH}.tar.gz" '.assets[] | select(.name | endswith($suffix)) | .browser_download_url' | head -n1)"
[[ -n "$NODE_EXPORTER_URL" && "$NODE_EXPORTER_URL" != "null" ]] || fail "Could not find node_exporter release for linux-${ASSET_ARCH}."
curl -fL --retry 3 "$NODE_EXPORTER_URL" -o "$TMPDIR/node_exporter.tar.gz"
mkdir -p "$TMPDIR/node_exporter"
tar -xzf "$TMPDIR/node_exporter.tar.gz" -C "$TMPDIR/node_exporter"
NODE_EXPORTER_BIN="$(find "$TMPDIR/node_exporter" -type f -name node_exporter -perm /111 | head -n1)"
[[ -n "$NODE_EXPORTER_BIN" ]] || fail "node_exporter binary not found in release archive."
install -m 0755 "$NODE_EXPORTER_BIN" /usr/local/bin/node_exporter
id node_exporter >/dev/null 2>&1 || useradd --system --no-create-home --shell /sbin/nologin node_exporter
cat > /etc/systemd/system/node_exporter.service <<'UNIT'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100
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
systemctl enable --now node_exporter

# Install OpenObserve as a native binary. AlmaLinux 9 ships glibc 2.34, so use
# the official musl build to avoid the GLIBC_2.35/2.38/2.39 failures seen with
# some regular release binaries. No container runtime or system glibc replacement.
say "Installing OpenObserve native musl binary (AlmaLinux 9-compatible)"
OO_TAG="$(curl -fsSL https://api.github.com/repos/openobserve/openobserve/releases/latest | jq -r '.tag_name')"
[[ -n "$OO_TAG" && "$OO_TAG" != "null" ]] || fail "Could not resolve the latest OpenObserve release."
OO_URL="https://downloads.openobserve.ai/releases/openobserve/${OO_TAG}/openobserve-${OO_TAG}-linux-${ASSET_ARCH}-musl.tar.gz"
if ! curl -fsSL --retry 3 "$OO_URL" -o "$TMPDIR/openobserve.tar.gz"; then
  fail "Could not download the official OpenObserve musl archive from $OO_URL. Check the current official release asset name; refusing to install an incompatible glibc binary."
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
      read -r -s -p "OpenObserve admin password (minimum 12 characters; letters/numbers and ._!@#%+=:- only): " OO_PASSWORD; echo
      [[ "$OO_PASSWORD" =~ ^[A-Za-z0-9._!@#%+=:-]{12,}$ ]] || fail "Use at least 12 characters from letters, numbers, and ._!@#%+=:- (quotes, spaces, dollar signs, and backslashes are excluded for safe configuration)."
      cat > /etc/openobserve.env <<EOF
ZO_ROOT_USER_EMAIL=${OO_EMAIL}
ZO_ROOT_USER_PASSWORD=${OO_PASSWORD}
ZO_EXT_AUTH_SALT=$(openssl rand -hex 24)
ZO_DATA_DIR=/var/lib/openobserve
ZO_HTTP_ADDR=0.0.0.0
ZO_HTTP_PORT=5080
EOF
      chmod 0600 /etc/openobserve.env
    else
      say "Keeping existing /etc/openobserve.env credentials and data settings; ensuring LAN bind and port settings."
      if grep -q '^ZO_HTTP_ADDR=' /etc/openobserve.env; then
        sed -i 's/^ZO_HTTP_ADDR=.*/ZO_HTTP_ADDR=0.0.0.0/' /etc/openobserve.env
      else
        echo 'ZO_HTTP_ADDR=0.0.0.0' >> /etc/openobserve.env
      fi
      if grep -q '^ZO_HTTP_PORT=' /etc/openobserve.env; then
        sed -i 's/^ZO_HTTP_PORT=.*/ZO_HTTP_PORT=5080/' /etc/openobserve.env
      else
        echo 'ZO_HTTP_PORT=5080' >> /etc/openobserve.env
      fi
      # OpenObserve's Argon2 implementation rejects salts longer than 48 bytes.
      # Older script versions generated 64 characters; repair missing/invalid values.
      CURRENT_SALT="$(sed -n 's/^ZO_EXT_AUTH_SALT=//p' /etc/openobserve.env | tail -n1)"
      if [[ -z "$CURRENT_SALT" || ${#CURRENT_SALT} -lt 16 || ${#CURRENT_SALT} -gt 48 ]]; then
        NEW_SALT="$(openssl rand -hex 24)"
        if grep -q '^ZO_EXT_AUTH_SALT=' /etc/openobserve.env; then
          sed -i "s/^ZO_EXT_AUTH_SALT=.*/ZO_EXT_AUTH_SALT=${NEW_SALT}/" /etc/openobserve.env
        else
          printf 'ZO_EXT_AUTH_SALT=%s\\n' "$NEW_SALT" >> /etc/openobserve.env
        fi
        say "Created a valid OpenObserve auth salt (48 characters)."
      else
        say "Existing OpenObserve auth salt length is valid."
      fi
      chmod 0600 /etc/openobserve.env
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
    systemctl enable openobserve
    systemctl reset-failed openobserve || true
    systemctl restart openobserve || true

    # Initial startup may run database migrations for 30-60 seconds.
    # Wait for the actual health endpoint instead of checking after 3 seconds.
    say "Waiting up to 180 seconds for OpenObserve startup and health check..."
    OO_HEALTH_OK=0
    for attempt in $(seq 1 90); do
      if curl -fsS --connect-timeout 2 --max-time 4 http://127.0.0.1:5080/healthz >/dev/null 2>&1; then
        OO_HEALTH_OK=1
        break
      fi
      if ! systemctl is-active --quiet openobserve && [[ "$attempt" -ge 10 ]]; then
        break
      fi
      sleep 2
    done

    if [[ "$OO_HEALTH_OK" -eq 1 ]]; then
      say "OpenObserve native service is healthy (/healthz returned HTTP 200)."
      OO_INSTALLED=1
    else
      say "OpenObserve did not become healthy within 180 seconds. Recent logs follow:"
      systemctl status openobserve --no-pager -l || true
      journalctl -u openobserve -n 100 --no-pager || true
      fail "OpenObserve failed its startup/health check after waiting up to 180 seconds."
    fi
  fi
fi

# Install pgBadger from EPEL when available.
say "Installing pgBadger"
dnf config-manager --set-enabled crb || true
dnf install -y epel-release || true
dnf install -y pgbadger || say "WARNING: pgBadger package was not found in enabled repositories. Enable EPEL/CRB for this AlmaLinux release, then run: dnf install pgbadger"

# Grant Alloy access to PostgreSQL log files, including rotated/future files.
# The default ACL is important because PostgreSQL creates new log files during rotation.
say "Granting Alloy read access to PostgreSQL logs with ACLs"
PGLOGDIR="$PGDATA/log"
install -d "$PGLOGDIR"
setfacl -m u:alloy:--x /var/lib/pgsql 2>/dev/null || true
setfacl -m u:alloy:--x "$(dirname "$PGDATA")" 2>/dev/null || true
setfacl -m u:alloy:--x "$PGDATA" 2>/dev/null || true
setfacl -m u:alloy:r-x "$PGLOGDIR"
setfacl -d -m u:alloy:r-x "$PGLOGDIR"
find "$PGLOGDIR" -maxdepth 1 -type f -name 'postgresql-*.log' -exec setfacl -m u:alloy:r-- {} + 2>/dev/null || true

# Configure Alloy: PostgreSQL exporter + node_exporter metrics to Prometheus remote-write,
# and PostgreSQL logs to the OpenObserve Loki-compatible ingestion API.
if [[ -f /etc/openobserve.env ]]; then
  OO_EMAIL="$(sed -n 's/^ZO_ROOT_USER_EMAIL=//p' /etc/openobserve.env | tail -n1)"
  OO_PASSWORD="$(sed -n 's/^ZO_ROOT_USER_PASSWORD=//p' /etc/openobserve.env | tail -n1)"
  [[ -n "$OO_EMAIL" && -n "$OO_PASSWORD" ]] || fail "OpenObserve credentials missing from /etc/openobserve.env."
  install -d -o root -g alloy -m 0750 /etc/alloy
  # Keep credentials outside the Alloy configuration and load them through systemd.
  cat > /etc/sysconfig/alloy-credentials <<EOF
OO_USER=${OO_EMAIL}
OO_PASSWORD=${OO_PASSWORD}
EOF
  chown root:root /etc/sysconfig/alloy-credentials
  chmod 0600 /etc/sysconfig/alloy-credentials
  install -d -m 0755 /etc/systemd/system/alloy.service.d
  cat > /etc/systemd/system/alloy.service.d/10-openobserve-credentials.conf <<'UNIT'
[Service]
EnvironmentFile=/etc/sysconfig/alloy-credentials
UNIT
  cat > /etc/alloy/config.alloy <<EOF
// Metrics: PostgreSQL exporter and OS node_exporter -> OpenObserve Prometheus remote-write.
// Credentials are supplied by systemd from /etc/sysconfig/alloy-credentials.
prometheus.scrape "postgres_exporter" {
  targets = [{ "__address__" = "127.0.0.1:9187", "job" = "postgresql", "instance" = "localhost" }]
  scrape_interval = "15s"
  forward_to = [prometheus.remote_write.openobserve.receiver]
}

prometheus.scrape "node_exporter" {
  targets = [{ "__address__" = "127.0.0.1:9100", "job" = "node", "instance" = "localhost" }]
  scrape_interval = "15s"
  forward_to = [prometheus.remote_write.openobserve.receiver]
}

prometheus.remote_write "openobserve" {
  endpoint {
    url = "http://127.0.0.1:5080/api/default/prometheus/api/v1/write"
    basic_auth {
      username = env("OO_USER")
      password = env("OO_PASSWORD")
    }
  }
}

// PostgreSQL log files -> OpenObserve log stream.
local.file_match "postgresql_logs" {
  path_targets = [{
    "__path__" = "${PGLOGDIR}/postgresql-*.log",
    "job" = "postgresql",
    "service" = "postgresql",
    "host" = "${HOSTNAME}",
  }]
}

loki.source.file "postgresql_logs" {
  targets    = local.file_match.postgresql_logs.targets
  forward_to = [loki.write.openobserve.receiver]
}

loki.write "openobserve" {
  endpoint {
    url = "http://127.0.0.1:5080/api/default/loki/api/v1/push"
    basic_auth {
      username = env("OO_USER")
      password = env("OO_PASSWORD")
    }
  }
}
EOF
  chown root:alloy /etc/alloy/config.alloy
  chmod 0640 /etc/alloy/config.alloy
  systemctl daemon-reload
  systemctl enable --now alloy
  systemctl restart alloy
  sleep 3
  if ! systemctl is-active --quiet alloy; then
    journalctl -u alloy -n 80 --no-pager || true
    fail "Grafana Alloy did not start. Review the configuration and journalctl output above."
  fi
else
  say "WARNING: /etc/openobserve.env not found; skipping Alloy pipeline configuration."
fi

# Stage dashboard JSON files alongside the script. Import remains a UI action because
# dashboard import APIs vary by OpenObserve version and should not be guessed.
install -d -m 0700 "$DASHBOARD_DIR"
for f in openobserve_system_metrics_detailed_dashboard_updated.json openobserve_postgresql_pgBadger_dashboard_updated.json; do
  if [[ -f "$SCRIPT_DIR/$f" ]]; then
    install -m 0600 "$SCRIPT_DIR/$f" "$DASHBOARD_DIR/$f"
  else
    say "WARNING: Dashboard file $SCRIPT_DIR/$f not found. If using the bundle, keep the JSON files beside the script."
  fi
done

# Allow the OpenObserve UI only from the trusted LAN CIDR when firewalld is active.
if systemctl is-active --quiet firewalld; then
  read -r -p "Trusted LAN CIDR allowed to access OpenObserve TCP/5080 [192.168.29.0/24]: " LAN_CIDR
  LAN_CIDR="${LAN_CIDR:-192.168.29.0/24}"
  if [[ "$LAN_CIDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]{1,2}$ ]]; then
    FIREWALL_RULE="rule family=ipv4 source address=${LAN_CIDR} port port=5080 protocol=tcp accept"
    if ! firewall-cmd --permanent --query-rich-rule="$FIREWALL_RULE" >/dev/null 2>&1; then
      firewall-cmd --permanent --add-rich-rule="$FIREWALL_RULE"
      firewall-cmd --reload
    fi
    say "OpenObserve TCP/5080 permitted from ${LAN_CIDR}."
  else
    say "WARNING: CIDR format was not accepted by the installer's basic check. No firewall rule was added; configure TCP/5080 for your trusted LAN manually."
  fi
else
  say "firewalld is not active; no firewall rule was changed. Restrict TCP/5080 using your host/network firewall."
fi

say "Checking service states"
for svc in "$PGSERVICE" postgres_exporter node_exporter alloy; do
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
Postgres metrics   : http://127.0.0.1:9187/metrics (local only)
System metrics     : http://127.0.0.1:9100/metrics (local only)
OpenObserve UI     : http://<SERVER-LAN-IP>:5080 (native service bound to 0.0.0.0; restrict access with firewall/network ACLs)
Alloy config       : /etc/alloy/config.alloy
Alloy credentials  : /etc/sysconfig/alloy-credentials (root-only)
Dashboard JSONs    : $DASHBOARD_DIR
Exporter env       : /etc/postgres_exporter.env (password protected)
Backup directory   : $BACKUP_DIR
Install log        : $LOG_FILE

NEXT STEPS
----------
1. Verify: curl -fsS http://127.0.0.1:9187/metrics | head
2. Verify: curl -fsS http://127.0.0.1:9100/metrics | head
3. Verify: systemctl status postgres_exporter node_exporter alloy openobserve --no-pager
4. Open http://<SERVER-LAN-IP>:5080 from a trusted LAN workstation. If firewalld was active, the script asked for a trusted LAN CIDR and allowed only that source to reach TCP/5080. Do not expose port 5080 directly to the public internet.
5. pg_stat_statements was enabled in database 'postgres'. Enable it in each application database as needed:
   sudo -u postgres psql -d YOUR_DATABASE -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'
6. Review PostgreSQL logging volume. The script logs statements taking >= 1 second; adjust log_min_duration_statement to suit your workload.
7. OpenObserve remote-write ingestion and Alloy health must be verified in the UI/logs. Check with:
   journalctl -u alloy -n 100 --no-pager
   journalctl -u openobserve -n 100 --no-pager

Dashboard JSON files are staged for manual import; the script does not create alerts or Telegram destinations. Import both JSON files from Dashboards → Import.

Security: postgres_exporter and node_exporter listen on loopback only. OpenObserve listens on all IPv4 interfaces; restrict TCP/5080 to trusted LAN clients and never expose it directly to the public internet. Restrict TCP/5080 to trusted LAN clients.
EOF
