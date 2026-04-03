# PDNS — Local DNS Server with Internet Routing

A bare-metal PowerDNS setup that acts as both a **local DNS server** and a **full internet resolver**.

- `cosmin-lab.com` subdomains resolve to your local services
- Everything else (google.com, sql.com, etc.) resolves normally via the internet

No Docker. No containers. Runs directly on the system.

## How It Works

```
DNS client
    │
    ▼  port 53
PowerDNS Recursor
    ├── *.cosmin-lab.com  ──► PowerDNS Authoritative (127.0.0.1:5300)
    │                              └── /etc/powerdns/zones/db.cosmin-lab.com
    │
    └── everything else  ──► Internet (8.8.8.8 / 1.1.1.1)
```

The **Recursor** is the single entry point on port 53. It routes queries:
- Local domain → your own authoritative server
- Internet domain → upstream resolvers (full recursion or forwarded)

## Quick Start

```bash
# Default: domain = cosmin-lab.com, server IP = auto-detected
sudo bash install.sh

# Custom domain or IP
LOCAL_DOMAIN=mylab.com SERVER_IP=192.168.1.10 sudo bash install.sh
```

The script handles:
- Package installation (from official PowerDNS repos)
- Port-53 conflict with `systemd-resolved` (disabled automatically)
- All configuration files
- Service startup and a quick smoke test

Supported distros: **Ubuntu 20.04+**, **Debian 11+**, **Rocky / AlmaLinux / CentOS 8+**

## Test It

```bash
# Local record — should return your server IP
dig sql.cosmin-lab.com

# Internet — should return real IPs
dig google.com
dig sql.com

# Direct query to authoritative (bypasses recursor)
dig @127.0.0.1 -p 5300 sql.cosmin-lab.com
```

## Add a Local Record

1. Edit the zone file:
   ```bash
   sudo nano /etc/powerdns/zones/db.cosmin-lab.com
   ```
2. Add your record (example):
   ```
   myapp   IN A   192.168.1.20
   ```
3. Increment the serial number on the SOA line (`2026040301` → `2026040302`)
4. Reload without restarting:
   ```bash
   pdns_control bind-reload-now cosmin-lab.com
   ```

## Repository Structure

```
install.sh                          — main install script (run this)
configs/authoritative/pdns.conf     — authoritative server config (reference)
configs/authoritative/named.conf    — zone registration (reference)
configs/recursor/recursor.conf      — recursor forwarding config (reference)
zones/db.portfolio.test             — example zone file (reference)
docs/architecture.md                — architecture diagram
```

> The `configs/` and `zones/` directories are reference copies.
> The live configuration is written to `/etc/powerdns/` by `install.sh`.

## Key Design Decisions

- **No containers** — runs directly on the OS, simpler to debug and present
- **Port-53 conflict solved** — `systemd-resolved` stub listener is disabled automatically
- **Split routing** — local zone served authoritatively, internet queries recurse normally
- **BIND backend** — zone files are plain text, version-control friendly
- **Loopback-only auth** — authoritative listens on `127.0.0.1:5300`, not exposed externally

## Service Management

```bash
# Status
systemctl status pdns
systemctl status pdns-recursor

# Logs
journalctl -u pdns -f
journalctl -u pdns-recursor -f

# Restart
sudo systemctl restart pdns pdns-recursor
```

## Next Improvements

- DNSSEC for the local zone
- Database backend (SQLite / PostgreSQL) for API-driven record management
- GitHub Actions CI for zone file linting
- Prometheus metrics + Grafana dashboard
