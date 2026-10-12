# PostgreSQL Observability Toolkit

A collection of installation scripts and dashboards for monitoring
PostgreSQL and Linux system health on **AlmaLinux 9**. The repository
brings together PostgreSQL metrics, system metrics, and OpenObserve
dashboards to help DBAs inspect performance and troubleshoot problems
from a central interface.

> **Important:** Review the installation script before running it on a
> production server. The script may install packages, create services
> and users, modify configuration files, and change firewall or database
> settings.

## Repository

GitHub:
<https://github.com/redhatmurali/postgresql-observability-toolkit>

Clone the repository:

``` bash
git clone https://github.com/redhatmurali/postgresql-observability-toolkit.git
cd postgresql-observability-toolkit
```

## What's included

  -----------------------------------------------------------------------------------------
  File                                                  Purpose
  ----------------------------------------------------- -----------------------------------
  `install_pg_observability_alma9_fixed_v2.sh`          Main installation script for the
                                                        AlmaLinux 9 PostgreSQL
                                                        observability stack

  `openobserve_postgresql_9_key_metrics_dashboard...`   OpenObserve dashboard focused on
                                                        key PostgreSQL metrics

  `openobserve_postgresql_pgBadger_dashboard...`        OpenObserve dashboard for
                                                        PostgreSQL/pgBadger-related views

  `openobserve_system_metrics_detailed_dashboard...`    Detailed Linux system metrics
                                                        dashboard

  `openobserve_unified_postgres_linux_dashboard...`     Unified PostgreSQL and Linux
                                                        monitoring dashboard
  -----------------------------------------------------------------------------------------

Dashboard filenames above are shortened to match the names shown in the
repository listing. Use `ls -1` to see the exact filenames in your
checkout.

## Intended environment

-   Operating system: AlmaLinux 9
-   Database: PostgreSQL 16, as configured by the installation script
-   Observability: PostgreSQL metrics and Linux system metrics
-   Visualization: OpenObserve dashboards supplied in this repository

The exact services, ports, credentials, firewall rules, and supported
configurations depend on the current version of the installation script.
Check the script before deployment rather than assuming default values.

## Quick installation

Run as `root` or with equivalent `sudo` privileges.

### 1. Download the project

``` bash
git clone https://github.com/redhatmurali/postgresql-observability-toolkit.git
cd postgresql-observability-toolkit
```

### 2. Inspect the installer

``` bash
less install_pg_observability_alma9_fixed_v2.sh
```

Check the script's configuration variables, repositories, service ports,
credentials, and firewall changes before executing it.

### 3. Run the installer

``` bash
chmod +x install_pg_observability_alma9_fixed_v2.sh
sudo ./install_pg_observability_alma9_fixed_v2.sh
```

Follow the messages printed by the installer. If installation fails,
save the complete terminal output and inspect the relevant service logs
before rerunning it.

### Download only the installation script

If you do not want to clone the whole repository, download the script
directly:

``` bash
curl -fL "https://raw.githubusercontent.com/redhatmurali/postgresql-observability-toolkit/main/install_pg_observability_alma9_fixed_v2.sh" -o install_pg_observability_alma9_fixed_v2.sh
chmod +x install_pg_observability_alma9_fixed_v2.sh
sudo ./install_pg_observability_alma9_fixed_v2.sh
```

## Importing dashboards into OpenObserve

1.  Sign in to your OpenObserve instance.
2.  Open the dashboard management/import area in the OpenObserve UI.
3.  Select the relevant dashboard JSON file from the cloned repository.
4.  Map or verify the required streams and fields if prompted.
5.  Save the dashboard and confirm that data is arriving.

Dashboard imports may need adjustment if your stream names, field names,
or data sources differ from those expected by the dashboard.

## Verify the installation

Use these commands to review running services and listening ports:

``` bash
systemctl --type=service --state=running
ss -lntup
```

Check PostgreSQL status (the service name can vary by installation):

``` bash
systemctl --type=service | grep -i postgres
```

Check recent logs for a service that is not working:

``` bash
journalctl -u SERVICE_NAME -n 100 --no-pager
```

Replace `SERVICE_NAME` with the actual service unit name on your system.
Use the installer output and service configuration to identify the
correct units and URLs.

## Security recommendations

-   Do not expose PostgreSQL, OpenObserve, exporters, or monitoring
    endpoints directly to the public internet.
-   Restrict access with a firewall and, where appropriate, a VPN or
    private network.
-   Change any default or temporary passwords immediately.
-   Use dedicated, least-privilege database credentials for monitoring
    wherever the components support them.
-   Review the install script before using it on a production server.
-   Back up existing PostgreSQL and configuration data before making
    changes.
-   Avoid publishing credentials, tokens, internal addresses, or
    unredacted logs in GitHub issues.

## Troubleshooting

### PostgreSQL initialization or package path errors

Confirm which PostgreSQL packages and binaries are installed:

``` bash
rpm -qa | grep -i postgres
command -v psql
find /usr -name postgresql-setup -o -name initdb 2>/dev/null
```

Do not assume the generic `postgresql-setup` command exists when
PostgreSQL is installed from the PostgreSQL Global Development Group
(PGDG) repository. PGDG packages commonly use version-specific paths and
service names. Use the paths and service units that match the packages
actually installed.

### Dashboard shows no data

-   Confirm the relevant collector/exporter service is running.
-   Verify that the metrics or logs are reaching OpenObserve.
-   Check stream names, timestamps, and field names.
-   Review the collector and OpenObserve logs.
-   Confirm that the dashboard's selected time range includes recent
    data.

### Installer fails

-   Copy the full error output.
-   Check the corresponding service with
    `systemctl status SERVICE_NAME --no-pager`.
-   Review logs with `journalctl -u SERVICE_NAME -n 100 --no-pager`.
-   Correct the underlying issue before rerunning the installer.

## Contributing and support

Issues and improvements are welcome through the repository's GitHub
Issues page:

<https://github.com/redhatmurali/postgresql-observability-toolkit/issues>

When reporting a problem, include your OS version, PostgreSQL
installation method/version, the command you ran, and relevant error
output. Redact passwords, tokens, and sensitive infrastructure details.

## Disclaimer

This project is provided as-is for monitoring, learning, and
troubleshooting. Review and test changes in a non-production environment
before applying them to critical systems. The maintainers are not
responsible for data loss, downtime, or security issues resulting from
use of the scripts or dashboards.
