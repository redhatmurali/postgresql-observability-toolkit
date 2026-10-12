PostgreSQL Observability Bundle — AlmaLinux 9+
================================================

Contents
- install_pg_observability_alma9.sh
- openobserve_system_metrics_detailed_dashboard_updated.json
- openobserve_postgresql_pgBadger_dashboard_updated.json

Install
1. Extract the archive on the target AlmaLinux 9.x server.
2. Run as root:
     sudo bash install_pg_observability_alma9.sh
3. Follow the prompts. If PostgreSQL is already installed, choose to use the existing installation.
4. When asked, enter a valid OpenObserve admin email/password. The password must match the restricted character set explained by the script.
5. If firewalld is active, enter the trusted LAN CIDR allowed to reach TCP/5080. Default is 192.168.29.0/24.
6. Open http://<server-LAN-IP>:5080 from that trusted LAN.
7. Import the two JSON files from OpenObserve → Dashboards → Import. The script stages copies in /root/openobserve-dashboards/.

What it configures
- PostgreSQL pg_stat_statements and slow-query/checkpoint/lock logging
- postgres_exporter at 127.0.0.1:9187
- node_exporter at 127.0.0.1:9100
- Native OpenObserve binary/systemd service, using the musl release to avoid a glibc upgrade
- Grafana Alloy metrics remote-write and PostgreSQL log ingestion
- ACLs allowing Alloy to read existing and future rotated PostgreSQL log files
- pgBadger package when available through configured repositories
- Backups of PostgreSQL config files and an install log

Important boundaries
- No Docker/Podman containers, Prometheus server, or Grafana server are installed.
- Dashboards are staged as JSON but still need manual import in the OpenObserve UI. The installer deliberately does not guess version-specific dashboard import APIs.
- It does not create alert rules, Telegram bots, Telegram notification destinations, or templates. Those require your Telegram bot token/chat ID and version-specific OpenObserve alert UI/API setup.
- It does not open exporter ports to the LAN. Both exporters bind to loopback.
- Do not expose OpenObserve port 5080 to the public internet. Use a trusted LAN or a properly secured reverse proxy/VPN.
- PostgreSQL may restart once to apply shared_preload_libraries and logging settings. Review the script before running on a production server and ensure a valid backup exists.

Troubleshooting
- Install log: /var/log/pg-observability-install.log
- Backup directory: printed at the end of installation
- Alloy: journalctl -u alloy -n 100 --no-pager
- OpenObserve: journalctl -u openobserve -n 100 --no-pager
- Exporter checks:
    curl -fsS http://127.0.0.1:9187/metrics | head
    curl -fsS http://127.0.0.1:9100/metrics | head
- PostgreSQL logs: SHOW log_directory; and SHOW data_directory;
