#!/usr/bin/env bash
# =============================================================================
# status.sh — PowerDNS health dashboard
#
# Shows at a glance:
#   - service status (pdns + recursor)
#   - port bindings
#   - zone file info and records
#   - DNS resolution tests (local + internet)
#   - recent query log
#
# Usage:
#   sudo bash status.sh
#   sudo bash status.sh --watch      (refresh every 5 seconds)
# =============================================================================

set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}●${NC} $*"; }
fail() { echo -e "  ${RED}●${NC} $*"; }
warn() { echo -e "  ${YELLOW}●${NC} $*"; }
hr()   { echo -e "${DIM}────────────────────────────────────────────────────${NC}"; }
hdr()  { echo -e "\n${BOLD}${CYAN}$*${NC}"; hr; }

# ─── Detect domain ────────────────────────────────────────────────────────────
ZONE_DIR="/etc/powerdns/zones"
LOCAL_DOMAIN="${LOCAL_DOMAIN:-}"

detect_domain() {
    if [[ -z "${LOCAL_DOMAIN}" ]]; then
        ZONE_FILE=$(ls "${ZONE_DIR}"/db.* 2>/dev/null | head -1 || true)
        [[ -n "${ZONE_FILE}" ]] && LOCAL_DOMAIN="${ZONE_FILE#${ZONE_DIR}/db.}"
    fi
}

# ─── Services ─────────────────────────────────────────────────────────────────
section_services() {
    hdr "Services"

    for svc in pdns pdns-recursor; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            uptime=$(systemctl show "${svc}" --property=ActiveEnterTimestamp \
                | cut -d= -f2 | xargs -I{} date -d "{}" "+since %Y-%m-%d %H:%M" 2>/dev/null \
                || echo "running")
            ok "${svc}  ${DIM}(${uptime})${NC}"
        elif systemctl list-unit-files --quiet "${svc}.service" &>/dev/null; then
            fail "${svc}  ${DIM}(stopped)${NC}"
        else
            warn "${svc}  ${DIM}(not installed)${NC}"
        fi
    done
}

# ─── Port bindings ────────────────────────────────────────────────────────────
section_ports() {
    hdr "Port Bindings"

    check_port() {
        local port="$1" label="$2"
        if ss -tlnup 2>/dev/null | grep -q ":${port} "; then
            local proc
            proc=$(ss -tlnup 2>/dev/null | grep ":${port} " | grep -oP 'users:\(\("\K[^"]+' | head -1 || echo "unknown")
            ok "Port ${port}  ${DIM}(${label} — ${proc})${NC}"
        else
            fail "Port ${port}  ${DIM}(${label} — nothing listening)${NC}"
        fi
    }

    check_port 53   "recursor — DNS"
    check_port 5300 "authoritative — internal"
    check_port 8081 "authoritative — REST API"
}

# ─── Zone info ────────────────────────────────────────────────────────────────
section_zone() {
    detect_domain
    [[ -z "${LOCAL_DOMAIN}" ]] && { warn "No zone file found in ${ZONE_DIR}"; return; }

    local zone_file="${ZONE_DIR}/db.${LOCAL_DOMAIN}"
    hdr "Zone: ${LOCAL_DOMAIN}"

    if [[ ! -f "${zone_file}" ]]; then
        fail "Zone file not found: ${zone_file}"
        return
    fi

    local serial record_count
    serial=$(grep -oP '^\s+\K[0-9]{10}(?=\s*;\s*serial)' "${zone_file}" 2>/dev/null || echo "unknown")
    record_count=$(grep -cP '^\S.*\s+IN\s+(A|CNAME|MX|TXT)\s+' "${zone_file}" 2>/dev/null || echo "0")

    echo -e "  ${DIM}File   :${NC} ${zone_file}"
    echo -e "  ${DIM}Serial :${NC} ${serial}"
    echo -e "  ${DIM}Records:${NC} ${record_count}"
    echo ""

    printf "  ${BOLD}%-22s %-8s %s${NC}\n" "HOSTNAME" "TYPE" "VALUE"
    echo "  ──────────────────────────────────────────────"
    grep -P '^\S.*\s+IN\s+(A|CNAME|MX|TXT|NS)\s+' "${zone_file}" \
        | grep -v '^;' \
        | while IFS= read -r line; do
            name=$(echo "${line}" | awk '{print $1}')
            type=$(echo "${line}" | grep -oP 'IN\s+\K\S+')
            value=$(echo "${line}" | awk '{print $NF}')
            printf "  %-22s ${CYAN}%-8s${NC} %s\n" "${name}" "${type}" "${value}"
          done
}

# ─── DNS resolution tests ─────────────────────────────────────────────────────
section_tests() {
    detect_domain
    hdr "DNS Resolution Tests"

    run_test() {
        local label="$1" query="$2" server="$3" port="${4:-53}"
        local result
        if result=$(dig +short +time=3 +tries=1 "@${server}" -p "${port}" "${query}" 2>/dev/null) \
                && [[ -n "${result}" ]]; then
            ok "${label}  ${DIM}→ ${result}${NC}"
        else
            fail "${label}  ${DIM}(no answer)${NC}"
        fi
    }

    if [[ -n "${LOCAL_DOMAIN}" ]]; then
        run_test "sql.${LOCAL_DOMAIN}   (local → auth direct)"     "sql.${LOCAL_DOMAIN}"  "127.0.0.1" "5300"
        run_test "sql.${LOCAL_DOMAIN}   (local → via recursor)"    "sql.${LOCAL_DOMAIN}"  "127.0.0.1" "53"
    fi

    run_test "google.com          (internet via recursor)"  "google.com"  "127.0.0.1" "53"
    run_test "cloudflare.com      (internet via recursor)"  "cloudflare.com" "127.0.0.1" "53"

    # Negative test — local domain should NOT resolve on internet DNS
    if [[ -n "${LOCAL_DOMAIN}" ]]; then
        local neg
        neg=$(dig +short +time=2 +tries=1 @8.8.8.8 "sql.${LOCAL_DOMAIN}" 2>/dev/null || true)
        if [[ -z "${neg}" ]]; then
            ok "sql.${LOCAL_DOMAIN}   (correctly NOT on internet DNS)  ${DIM}8.8.8.8${NC}"
        else
            warn "sql.${LOCAL_DOMAIN}   (unexpectedly resolves on internet: ${neg})"
        fi
    fi
}

# ─── Backups ──────────────────────────────────────────────────────────────────
section_backups() {
    local backup_dir="/var/backups/pdns"
    hdr "Zone Backups"

    if [[ ! -d "${backup_dir}" ]]; then
        echo -e "  ${DIM}No backups yet (created on first manage-dns.sh change)${NC}"
        return
    fi

    local count
    count=$(ls "${backup_dir}"/*.zone 2>/dev/null | wc -l || echo 0)
    echo -e "  ${DIM}Directory :${NC} ${backup_dir}"
    echo -e "  ${DIM}Backups   :${NC} ${count} file(s)"

    ls -t "${backup_dir}"/*.zone 2>/dev/null | head -5 | while read -r f; do
        echo -e "  ${DIM}$(basename "${f}")  $(stat -c '%y' "${f}" | cut -d. -f1)${NC}"
    done
}

# ─── Recent logs ──────────────────────────────────────────────────────────────
section_logs() {
    hdr "Recent Logs  ${DIM}(last 8 lines each)${NC}"

    for svc in pdns pdns-recursor; do
        echo -e "  ${BOLD}${svc}${NC}"
        if systemctl list-unit-files --quiet "${svc}.service" &>/dev/null; then
            journalctl -u "${svc}" -n 8 --no-pager --output=short-iso 2>/dev/null \
                | sed 's/^/    /' \
                | sed "s/error/$(echo -e "${RED}")error$(echo -e "${NC}")/i" \
                || echo "    (no logs)"
        else
            echo "    (service not found)"
        fi
        echo ""
    done
}

# ─── API health ───────────────────────────────────────────────────────────────
section_api() {
    hdr "REST API  ${DIM}(PowerDNS Authoritative — port 8081)${NC}"

    local api_key
    api_key=$(grep -oP '(?<=api-key=)\S+' /etc/powerdns/pdns.conf 2>/dev/null || true)

    if [[ -z "${api_key}" ]]; then
        warn "api-key not found in /etc/powerdns/pdns.conf"
        return
    fi

    local response
    if response=$(curl -sf -H "X-API-Key: ${api_key}" \
            http://127.0.0.1:8081/api/v1/servers/localhost 2>/dev/null); then
        local version
        version=$(echo "${response}" | grep -oP '"version"\s*:\s*"\K[^"]+' || echo "unknown")
        ok "API reachable  ${DIM}(PowerDNS ${version})${NC}"

        local zones
        zones=$(curl -sf -H "X-API-Key: ${api_key}" \
            http://127.0.0.1:8081/api/v1/servers/localhost/zones 2>/dev/null \
            | grep -oP '"name"\s*:\s*"\K[^"]+' | tr '\n' ' ' || echo "")
        [[ -n "${zones}" ]] && echo -e "  ${DIM}Zones: ${zones}${NC}"
    else
        fail "API not reachable on 127.0.0.1:8081"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
print_dashboard() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${BOLD}${BLUE}  PowerDNS Status Dashboard${NC}  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo ""

    section_services
    section_ports
    section_zone
    section_tests
    section_api
    section_backups
    section_logs

    echo ""
}

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }

if [[ "${1:-}" == "--watch" ]]; then
    while true; do
        print_dashboard
        echo -e "  ${DIM}Refreshing every 5s — Ctrl+C to exit${NC}\n"
        sleep 5
    done
else
    print_dashboard
fi
