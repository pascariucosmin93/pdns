# PDNS Portfolio Project

A portfolio-ready DNS project built with PowerDNS Authoritative and PowerDNS Recursor.

## Overview

This repository demonstrates a clean DNS architecture with separated roles:

- `PowerDNS Authoritative` serves a private zone named `portfolio.test`
- `PowerDNS Recursor` handles recursive queries and forwards the local zone upstream
- `Podman Compose` wires both services together using a dedicated bridge network and static IPs

The project is intentionally designed to be easy to present in an interview or portfolio review. It highlights DNS concepts, container networking, service separation, and infrastructure-as-code style configuration.

## Architecture

See `docs/architecture.md`.

## Repository Structure

- `compose.yaml` defines the full stack
- `configs/authoritative/pdns.conf` configures the authoritative server
- `configs/authoritative/named.conf` registers the local zone
- `configs/recursor/recursor.conf` configures forwarding behavior
- `zones/db.portfolio.test` stores the sample DNS records
- `scripts/validate.ps1` performs lightweight configuration validation
- `scripts/validate.sh` provides the same validation flow for Unix-like environments

## Key Design Decisions

- non-privileged internal ports avoid the need for extra capabilities in containers
- static container IPs make the forwarding path deterministic and easier to explain
- BIND backend keeps the zone definition transparent and version-control friendly
- API exposure on port `8081` leaves room for future automation or UI integration

## Local Development

Render the final Compose configuration:

```powershell
podman compose -f .\compose.yaml config
```

Run the lightweight validation script:

```powershell
.\scripts\validate.ps1
```

Or on Linux/macOS:

```bash
./scripts/validate.sh
```

If you want to start the stack locally later:

```powershell
podman compose -f .\compose.yaml up -d
```

## Demo Queries

Query the recursor:

```powershell
dig @127.0.0.1 -p 1053 wiki.portfolio.test
dig @127.0.0.1 -p 1053 grafana.portfolio.test
```

Query the authoritative server directly:

```powershell
dig @127.0.0.1 -p 5300 portfolio.test SOA
dig @127.0.0.1 -p 5300 www.portfolio.test
```

## Next Improvements

- add CI validation for Compose and zone file linting
- introduce DNSSEC for the authoritative zone
- replace static records with a database backend and API-driven record management
- add metrics export and dashboarding for observability
