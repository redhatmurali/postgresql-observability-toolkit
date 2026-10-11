# PostgreSQL Observability Toolkit

A Bash-based installation toolkit for deploying PostgreSQL monitoring and performance-analysis components on AlmaLinux 9 and compatible RHEL-family Linux distributions.

## Features

- **PostgreSQL installation:** Select a supported PostgreSQL major version during installation.
- **Query performance analysis:** Use `pg_stat_statements` to identify expensive SQL statements.
- **Metrics collection:** Use `postgres_exporter` to expose PostgreSQL performance metrics.
- **Telemetry collection:** Use Grafana Alloy to collect and forward supported metrics and logs.
- **Centralized observability:** Integrate with OpenObserve for dashboards, searching, and alerting.
- **Log analysis:** Use pgBadger to analyze PostgreSQL logs and investigate performance problems.
- **Service management:** Configure systemd services for supported components.

## Supported platforms

- AlmaLinux 9.x and compatible RHEL-family distributions.
- PostgreSQL major versions supported by the selected installer and configured repositories.

## Requirements

- Root or sudo privileges.
- Internet connectivity for package and software downloads.
- Sufficient disk space and memory for the selected components.
- A PostgreSQL-compatible repository for the selected major version.

## Installation

Download `install_pg_observability_alma9.sh` from this repository.

Make the script executable:

```bash
chmod +x install_pg_observability_alma9.sh
```

Run the installer:

```bash
sudo ./install_pg_observability_alma9.sh
```

If supported by your script, select a PostgreSQL version using a command-line option:

```bash
sudo ./install_pg_observability_alma9.sh --postgres-version 17
```

Check the script's help output for the exact supported options:

```bash
./install_pg_observability_alma9.sh --help
```

## Components

| Component | Purpose |
|---|---|
| PostgreSQL | Relational database server |
| pg_stat_statements | SQL execution statistics |
| postgres_exporter | PostgreSQL metrics endpoint |
| Grafana Alloy | Telemetry collection and forwarding |
| OpenObserve | Centralized logs, metrics, and alerting |
| pgBadger | PostgreSQL log analysis |

## Security considerations

- Keep monitoring endpoints private unless remote access is explicitly required.
- Use dedicated, least-privilege PostgreSQL monitoring credentials.
- Configure strong OpenObserve administrator credentials.
- Review firewall rules and service bindings before deployment.
- Back up PostgreSQL configuration files before making changes.
- Test the installation on a non-production server before production deployment.

## Important notes

This toolkit is intended to assist with installation and observability. Monitoring does not automatically optimize SQL queries or database configuration.

Installing a different PostgreSQL major version does not migrate an existing database. Major-version upgrades require a separate migration plan.

The script's actual capabilities, supported options, and service names depend on the version committed to this repository. Review the script before executing it.

## License

MIT License — add a `LICENSE` file if you choose to distribute this project under the MIT License.
