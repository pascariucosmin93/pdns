#!/usr/bin/env bash
# =============================================================================
# install.sh — PowerDNS bare-metal setup
#
# Installs PowerDNS Authoritative + Recursor directly on the system.
# Handles port-53 conflict with systemd-resolved.
#
# Routing logic:
#   *.cosmin-lab.com  →  local authoritative (127.0.0.1:5300)
#   everything else   →  internet via 8.8.8.8 / 1.1.1.1
#
# Supported distros: Ubuntu 20.04+, Debian 11+, Rocky/AlmaLinux/CentOS 8+
#
# Usage:
#   sudo bash install.sh
#   LOCAL_DOMAIN=mylab.com SERVER_IP=192.168.1.10 sudo bash install.sh
# =============================================================================

set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
hr()   { echo -e "${BLUE}────────────────────────────────────────────────────${NC}"; }

# ─── Config (override via env vars) ───────────────────────────────────────────
LOCAL_DOMAIN="${LOCAL_DOMAIN:-cosmin-lab.com}"
SERVER_IP="${SERVER_IP:-$(hostname -I | awk '{print $1}')}"
AUTH_BIND="127.0.0.1"
AUTH_PORT=5300
UPSTREAM_DNS="8.8.8.8;1.1.1.1"

# ─── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run as root: sudo bash $0"

hr
info "Local domain : ${LOCAL_DOMAIN}"
info "Server IP    : ${SERVER_IP}"
info "Auth listens : ${AUTH_BIND}:${AUTH_PORT}  (internal only)"
info "Recursor     : 0.0.0.0:53  (forwards local → auth, rest → internet)"
hr

# ─── OS Detection ─────────────────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
    else
        err "Cannot detect OS. /etc/os-release not found."
    fi
}

# ─── Package Installation ─────────────────────────────────────────────────────
install_packages() {
    log "Installing PowerDNS packages..."

    case "${OS_ID}" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive

            # Add PowerDNS repo for latest stable packages
            if [[ "${OS_ID}" == "ubuntu" ]]; then
                REPO_OS="ubuntu"
                REPO_SUITE="${UBUNTU_CODENAME:-$(lsb_release -cs)}"
            else
                REPO_OS="debian"
                REPO_SUITE="${VERSION_CODENAME:-$(lsb_release -cs)}"
            fi

            # Add official PowerDNS repo (v4.9 is the current stable series)
            if [[ ! -f /etc/apt/sources.list.d/pdns.list ]]; then
                log "Adding PowerDNS official apt repository..."
                install -d /etc/apt/keyrings
                curl -fsSL https://repo.powerdns.com/FD380FBB-pub.asc \
                    | gpg --dearmor -o /etc/apt/keyrings/pdns.gpg

                cat > /etc/apt/sources.list.d/pdns.list <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/pdns.gpg] http://repo.powerdns.com/${REPO_OS} ${REPO_SUITE}-auth-49 main
deb [arch=amd64 signed-by=/etc/apt/keyrings/pdns.gpg] http://repo.powerdns.com/${REPO_OS} ${REPO_SUITE}-rec-51 main
EOF
                # Pin official repo over distro packages
                cat > /etc/apt/preferences.d/pdns <<'EOF'
Package: pdns-*
Pin: origin repo.powerdns.com
Pin-Priority: 600
EOF
            fi

            apt-get update -qq
            apt-get install -y pdns-server pdns-backend-bind pdns-recursor
            ;;

        rhel|centos|rocky|almalinux|ol)
            # Enable PowerDNS official repo
            if [[ ! -f /etc/yum.repos.d/powerdns-auth-49.repo ]]; then
                log "Adding PowerDNS official yum repositories..."
                curl -fsSL https://repo.powerdns.com/repo-files/el-auth-49.repo \
                    -o /etc/yum.repos.d/powerdns-auth-49.repo
                curl -fsSL https://repo.powerdns.com/repo-files/el-rec-51.repo \
                    -o /etc/yum.repos.d/powerdns-rec-51.repo
            fi

            dnf install -y pdns pdns-backend-bind pdns-recursor
            ;;

        *)
            err "Unsupported OS: ${OS_ID}. Supported: ubuntu, debian, rocky, almalinux, centos."
            ;;
    esac

    log "Packages installed."
}

# ─── Fix port-53 conflict (systemd-resolved) ──────────────────────────────────
fix_port53() {
    log "Checking port 53 availability..."

    if ss -tlnup 2>/dev/null | grep -q ':53 '; then
        warn "Something is listening on port 53. Checking for systemd-resolved..."

        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            warn "systemd-resolved is active. Disabling its stub listener on port 53..."

            RESOLVED_CONF="/etc/systemd/resolved.conf"
            # Backup once
            [[ ! -f "${RESOLVED_CONF}.orig" ]] && cp "${RESOLVED_CONF}" "${RESOLVED_CONF}.orig"

            # Disable stub listener
            if grep -q "^DNSStubListener=" "${RESOLVED_CONF}"; then
                sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' "${RESOLVED_CONF}"
            else
                echo "DNSStubListener=no" >> "${RESOLVED_CONF}"
            fi

            systemctl restart systemd-resolved
            log "systemd-resolved stub listener disabled."

            # Point /etc/resolv.conf to our recursor (127.0.0.1)
            # Remove the symlink that points to resolved's stub
            if [[ -L /etc/resolv.conf ]]; then
                rm /etc/resolv.conf
                cat > /etc/resolv.conf <<EOF
# Managed by install.sh — PowerDNS Recursor on 127.0.0.1:53
nameserver 127.0.0.1
options edns0 trust-ad
EOF
                log "/etc/resolv.conf updated to use local PowerDNS."
            fi
        fi
    else
        log "Port 53 is free."
    fi
}

# ─── Write zone file ──────────────────────────────────────────────────────────
write_zone_file() {
    ZONE_DIR="/etc/powerdns/zones"
    ZONE_FILE="${ZONE_DIR}/db.${LOCAL_DOMAIN}"
    SERIAL=$(date +%Y%m%d01)

    install -d -o pdns -g pdns -m 755 "${ZONE_DIR}"

    log "Writing zone file: ${ZONE_FILE}"
    cat > "${ZONE_FILE}" <<EOF
; Zone: ${LOCAL_DOMAIN}
; Managed by install.sh — edit this file to add/remove records,
; then run: pdns_control bind-reload-now ${LOCAL_DOMAIN}
\$TTL 3600
@   IN SOA  ns1.${LOCAL_DOMAIN}. hostmaster.${LOCAL_DOMAIN}. (
        ${SERIAL}  ; serial  — increment after every change (YYYYMMDDnn)
        10800      ; refresh
        3600       ; retry
        604800     ; expire
        3600       ; negative TTL
)

; ── Name server ──────────────────────────────────────────────────────────────
@         IN NS    ns1.${LOCAL_DOMAIN}.
ns1       IN A     ${SERVER_IP}

; ── Local services — add your own records below ──────────────────────────────
; Format:  <hostname>   IN A   <local-ip>
sql       IN A     ${SERVER_IP}
git       IN A     ${SERVER_IP}
grafana   IN A     ${SERVER_IP}
wiki      IN A     ${SERVER_IP}
; www     IN CNAME wiki.${LOCAL_DOMAIN}.

; ─────────────────────────────────────────────────────────────────────────────
; HOW TO ADD A RECORD:
;   1. Add a line:  myapp  IN A  192.168.1.20
;   2. Increment the serial number above  (e.g. 2026040301 → 2026040302)
;   3. Run: pdns_control bind-reload-now ${LOCAL_DOMAIN}
; ─────────────────────────────────────────────────────────────────────────────
EOF

    chown pdns:pdns "${ZONE_FILE}"
}

# ─── Configure pdns Authoritative ────────────────────────────────────────────
configure_authoritative() {
    AUTH_CONF="/etc/powerdns/pdns.conf"
    NAMED_CONF="/etc/powerdns/named.conf"

    log "Writing authoritative config: ${AUTH_CONF}"
    cat > "${AUTH_CONF}" <<EOF
# PowerDNS Authoritative — serves ${LOCAL_DOMAIN} zone
# Listens ONLY on loopback so it's not reachable from outside directly.
# All external queries come through the Recursor on port 53.

local-address=${AUTH_BIND}
local-port=${AUTH_PORT}

launch=bind
bind-config=${NAMED_CONF}

# REST API (optional — useful for future automation / web UI)
api=yes
api-key=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)
webserver=yes
webserver-address=127.0.0.1
webserver-port=8081
webserver-allow-from=127.0.0.0/8

guardian=no
version-string=anonymous
loglevel=4
EOF

    log "Writing BIND zone index: ${NAMED_CONF}"
    cat > "${NAMED_CONF}" <<EOF
zone "${LOCAL_DOMAIN}" {
    type master;
    file "/etc/powerdns/zones/db.${LOCAL_DOMAIN}";
};
EOF

    chown pdns:pdns "${AUTH_CONF}" "${NAMED_CONF}"
}

# ─── Configure pdns Recursor ──────────────────────────────────────────────────
configure_recursor() {
    REC_CONF="/etc/pdns-recursor/recursor.conf"
    # Some distros put it at /etc/powerdns/recursor.conf
    [[ -d /etc/pdns-recursor ]] || { mkdir -p /etc/pdns-recursor; REC_CONF="/etc/pdns-recursor/recursor.conf"; }
    [[ -d /etc/powerdns ]] && [[ ! -d /etc/pdns-recursor ]] && REC_CONF="/etc/powerdns/recursor.conf"

    log "Writing recursor config: ${REC_CONF}"
    cat > "${REC_CONF}" <<EOF
# PowerDNS Recursor — main DNS resolver for the system
# Listens on all interfaces (port 53) and routes:
#   ${LOCAL_DOMAIN}  →  local authoritative at ${AUTH_BIND}:${AUTH_PORT}
#   everything else  →  internet via ${UPSTREAM_DNS}

local-address=0.0.0.0, ::
local-port=53

# Allow queries from anywhere (restrict if this is a public server)
allow-from=127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, ::1/128, fc00::/7

# ── Routing ──────────────────────────────────────────────────────────────────
# Local zone → internal authoritative server (port ${AUTH_PORT})
forward-zones=${LOCAL_DOMAIN}=${AUTH_BIND}:${AUTH_PORT}

# Internet → upstream resolvers (PowerDNS recurses for all else)
# Uncomment the line below to use Google/Cloudflare instead of full recursion:
# forward-zones-recurse=.=${UPSTREAM_DNS}

# ── Security ─────────────────────────────────────────────────────────────────
dnssec=validate

# ── Performance ──────────────────────────────────────────────────────────────
max-cache-ttl=86400
packetcache-ttl=60

version-string=anonymous
loglevel=4
EOF

    chown -R pdns:pdns "$(dirname "${REC_CONF}")" 2>/dev/null || true
}

# ─── Enable and start services ────────────────────────────────────────────────
start_services() {
    log "Enabling and starting services..."

    # Authoritative first
    systemctl enable --now pdns
    systemctl restart pdns

    # Short wait so auth is ready before recursor starts
    sleep 1

    # Recursor second
    systemctl enable --now pdns-recursor
    systemctl restart pdns-recursor

    log "Services started."
}

# ─── Smoke test ───────────────────────────────────────────────────────────────
smoke_test() {
    hr
    log "Running smoke tests..."
    sleep 2  # let services fully bind

    PASS=0; FAIL=0

    run_test() {
        local label="$1" query="$2" server="$3"
        if dig +short +time=3 "@${server}" "${query}" &>/dev/null; then
            echo -e "  ${GREEN}PASS${NC}  ${label}"
            PASS=$((PASS+1))
        else
            echo -e "  ${RED}FAIL${NC}  ${label}"
            FAIL=$((FAIL+1))
        fi
    }

    # Local zone via authoritative (direct)
    run_test "sql.${LOCAL_DOMAIN} via auth (127.0.0.1:${AUTH_PORT})" \
        "sql.${LOCAL_DOMAIN}" "127.0.0.1:${AUTH_PORT}"

    # Local zone via recursor (end-to-end routing)
    run_test "sql.${LOCAL_DOMAIN} via recursor (127.0.0.1:53)" \
        "sql.${LOCAL_DOMAIN}" "127.0.0.1"

    # Internet resolution via recursor
    run_test "google.com via recursor (internet routing)" \
        "google.com" "127.0.0.1"

    hr
    info "Tests passed: ${PASS}  |  Failed: ${FAIL}"

    if [[ ${FAIL} -gt 0 ]]; then
        warn "Some tests failed. Check logs:"
        warn "  journalctl -u pdns -n 30"
        warn "  journalctl -u pdns-recursor -n 30"
    fi
}

# ─── Print summary ────────────────────────────────────────────────────────────
print_summary() {
    hr
    log "Installation complete!"
    hr
    echo ""
    echo -e "  ${GREEN}Local domain${NC}    : ${LOCAL_DOMAIN}"
    echo -e "  ${GREEN}Example record${NC}  : sql.${LOCAL_DOMAIN}  →  ${SERVER_IP}"
    echo ""
    echo -e "  ${BLUE}Test resolution${NC}"
    echo -e "    dig sql.${LOCAL_DOMAIN}          # should return ${SERVER_IP} (local)"
    echo -e "    dig google.com                  # should return Google IPs (internet)"
    echo ""
    echo -e "  ${BLUE}Add a new local record${NC}"
    echo -e "    1. Edit  /etc/powerdns/zones/db.${LOCAL_DOMAIN}"
    echo -e "    2. Add:  myapp  IN A  192.168.x.x"
    echo -e "    3. Increment the serial number"
    echo -e "    4. Run:  pdns_control bind-reload-now ${LOCAL_DOMAIN}"
    echo ""
    echo -e "  ${BLUE}Logs${NC}"
    echo -e "    journalctl -u pdns -f"
    echo -e "    journalctl -u pdns-recursor -f"
    echo ""
    hr
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    detect_os
    install_packages
    fix_port53
    configure_authoritative
    write_zone_file
    configure_recursor
    start_services
    smoke_test
    print_summary
}

main
