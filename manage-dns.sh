#!/usr/bin/env bash
# =============================================================================
# manage-dns.sh — Add and remove local DNS records
#
# Usage:
#   sudo bash manage-dns.sh list
#   sudo bash manage-dns.sh add   <hostname> <ip>
#   sudo bash manage-dns.sh add   <hostname> <target> cname
#   sudo bash manage-dns.sh remove <hostname>
#
# Examples:
#   sudo bash manage-dns.sh add    docker   192.168.1.50
#   sudo bash manage-dns.sh add    www      wiki.cosmin-lab.com cname
#   sudo bash manage-dns.sh remove docker
#   sudo bash manage-dns.sh list
# =============================================================================

set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

# ─── Detect domain and zone file ──────────────────────────────────────────────
ZONE_DIR="/etc/powerdns/zones"

detect_domain() {
    if [[ -z "${LOCAL_DOMAIN:-}" ]]; then
        # Try to detect from existing zone files
        ZONE_FILE=$(ls "${ZONE_DIR}"/db.* 2>/dev/null | head -1 || true)
        if [[ -z "${ZONE_FILE}" ]]; then
            err "No zone file found in ${ZONE_DIR}. Run install.sh first, or set LOCAL_DOMAIN."
        fi
        LOCAL_DOMAIN="${ZONE_FILE#${ZONE_DIR}/db.}"
    fi
    ZONE_FILE="${ZONE_DIR}/db.${LOCAL_DOMAIN}"
    [[ -f "${ZONE_FILE}" ]] || err "Zone file not found: ${ZONE_FILE}"
}

# ─── Increment serial in zone file ────────────────────────────────────────────
bump_serial() {
    local current new today seq

    current=$(grep -oP '^\s+\K[0-9]{10}(?=\s*;\s*serial)' "${ZONE_FILE}" || true)
    if [[ -z "${current}" ]]; then
        warn "Could not detect serial number — skipping auto-increment."
        return
    fi

    today=$(date +%Y%m%d)
    local current_date="${current:0:8}"
    local current_seq="${current:8:2}"

    if [[ "${current_date}" == "${today}" ]]; then
        # Same day — increment sequence
        seq=$(printf "%02d" $(( 10#${current_seq} + 1 )))
    else
        # New day — reset sequence to 01
        seq="01"
    fi

    new="${today}${seq}"
    sed -i "s/${current}/${new}/" "${ZONE_FILE}"
    info "Serial updated: ${current} → ${new}"
}

# ─── Backup zone file before changes ────────────────────────────────────────
backup_zone() {
    local backup_dir="/var/backups/pdns"
    install -d "${backup_dir}"
    local backup_file
    backup_file="${backup_dir}/$(date +%Y%m%d_%H%M%S)_${LOCAL_DOMAIN}.zone"
    cp "${ZONE_FILE}" "${backup_file}"
    info "Backup saved: ${backup_file}"

    # Keep only the last 20 backups
    ls -t "${backup_dir}"/*.zone 2>/dev/null | tail -n +21 | xargs rm -f || true
}

# ─── Reload zone in running PowerDNS ─────────────────────────────────────────
reload_zone() {
    if systemctl is-active --quiet pdns 2>/dev/null; then
        pdns_control bind-reload-now "${LOCAL_DOMAIN}" &>/dev/null \
            && log "Zone reloaded (no restart needed)." \
            || warn "Reload failed — try: sudo pdns_control bind-reload-now ${LOCAL_DOMAIN}"
    else
        warn "pdns is not running — changes saved but not applied yet."
    fi
}

# ─── list ─────────────────────────────────────────────────────────────────────
cmd_list() {
    detect_domain
    echo ""
    echo -e "${BOLD}  Zone: ${LOCAL_DOMAIN}${NC}"
    echo -e "${BOLD}  File: ${ZONE_FILE}${NC}"
    echo ""
    printf "  ${BOLD}%-25s %-8s %s${NC}\n" "HOSTNAME" "TYPE" "VALUE"
    echo "  ──────────────────────────────────────────────────"
    grep -P '^\S.*\s+IN\s+(A|CNAME|MX|TXT|NS)\s+' "${ZONE_FILE}" \
        | grep -v '^;' \
        | while IFS= read -r line; do
            name=$(echo "${line}" | awk '{print $1}')
            type=$(echo "${line}" | grep -oP 'IN\s+\K\S+')
            value=$(echo "${line}" | awk '{print $NF}')
            printf "  %-25s %-8s %s\n" "${name}" "${type}" "${value}"
          done
    echo ""
}

# ─── add ──────────────────────────────────────────────────────────────────────
cmd_add() {
    local hostname="${1:-}"
    local target="${2:-}"
    local type="${3:-A}"
    type="${type^^}"  # uppercase

    [[ -z "${hostname}" ]] && err "Missing hostname. Usage: manage-dns.sh add <hostname> <ip>"
    [[ -z "${target}" ]]   && err "Missing value. Usage: manage-dns.sh add <hostname> <ip>"

    detect_domain

    # Validate A record is a valid IP
    if [[ "${type}" == "A" ]]; then
        if ! echo "${target}" | grep -qP '^\d{1,3}(\.\d{1,3}){3}$'; then
            err "'${target}' is not a valid IPv4 address. For CNAME use: manage-dns.sh add ${hostname} ${target} cname"
        fi
    fi

    # Check if already exists
    if grep -qP "^${hostname}\s+IN\s+${type}\s+" "${ZONE_FILE}"; then
        err "Record '${hostname} IN ${type}' already exists. Remove it first: manage-dns.sh remove ${hostname}"
    fi

    backup_zone

    # Insert before the closing comment block (or at end of file)
    local new_line
    new_line=$(printf "%-10s IN %-6s %s" "${hostname}" "${type}" "${target}")

    # Insert before the last comment section if it exists, otherwise append
    if grep -q "^; ─\+" "${ZONE_FILE}"; then
        sed -i "/^; ─\+/{i\\${new_line}
        }" "${ZONE_FILE}"
        # Remove duplicates if sed inserted multiple times (guard)
        local count
        count=$(grep -cF "${new_line}" "${ZONE_FILE}" || true)
        if [[ "${count}" -gt 1 ]]; then
            # Keep only first occurrence
            awk -v line="${new_line}" '!seen[line]++ || $0 != line' "${ZONE_FILE}" > "${ZONE_FILE}.tmp" \
                && mv "${ZONE_FILE}.tmp" "${ZONE_FILE}"
        fi
    else
        echo "${new_line}" >> "${ZONE_FILE}"
    fi

    bump_serial
    reload_zone
    log "Added: ${hostname}.${LOCAL_DOMAIN} → ${target} (${type})"
    info "Test:  dig ${hostname}.${LOCAL_DOMAIN}"
}

# ─── remove ───────────────────────────────────────────────────────────────────
cmd_remove() {
    local hostname="${1:-}"
    [[ -z "${hostname}" ]] && err "Missing hostname. Usage: manage-dns.sh remove <hostname>"

    detect_domain

    # Protect core records
    case "${hostname}" in
        ns1|@)
            err "Cannot remove '${hostname}' — it is required for the zone to work."
            ;;
    esac

    # Count matching lines
    local count
    count=$(grep -cP "^${hostname}\s+IN\s+" "${ZONE_FILE}" || true)

    if [[ "${count}" -eq 0 ]]; then
        err "No record found for '${hostname}' in zone ${LOCAL_DOMAIN}."
    fi

    if [[ "${count}" -gt 1 ]]; then
        warn "Found ${count} records for '${hostname}':"
        grep -P "^${hostname}\s+IN\s+" "${ZONE_FILE}" | nl -ba
        echo ""
        read -rp "Remove ALL of them? [y/N] " confirm
        [[ "${confirm,,}" != "y" ]] && { warn "Aborted."; exit 0; }
    fi

    backup_zone

    # Remove the lines
    sed -i "/^${hostname}\s\+IN\s\+/d" "${ZONE_FILE}"

    bump_serial
    reload_zone
    log "Removed: ${hostname}.${LOCAL_DOMAIN}"
}

# ─── restore ─────────────────────────────────────────────────────────────────
cmd_restore() {
    local backup_dir="/var/backups/pdns"
    detect_domain

    mapfile -t backups < <(ls -t "${backup_dir}"/*_"${LOCAL_DOMAIN}".zone 2>/dev/null || true)

    if [[ ${#backups[@]} -eq 0 ]]; then
        err "No backups found in ${backup_dir} for domain ${LOCAL_DOMAIN}."
    fi

    echo ""
    echo -e "${BOLD}  Available backups for ${LOCAL_DOMAIN}:${NC}"
    echo ""
    for i in "${!backups[@]}"; do
        local ts
        ts=$(stat -c '%y' "${backups[$i]}" | cut -d. -f1)
        printf "  [%d]  %s  %s\n" "$((i+1))" "$(basename "${backups[$i]}")" "${DIM}(${ts})${NC}"
    done
    echo ""

    read -rp "  Restore which backup? [1-${#backups[@]}] (0 to cancel): " choice
    [[ "${choice}" == "0" || -z "${choice}" ]] && { warn "Cancelled."; exit 0; }
    [[ "${choice}" -lt 1 || "${choice}" -gt ${#backups[@]} ]] && err "Invalid choice."

    local selected="${backups[$((choice-1))]}"

    # Backup current state before restoring
    backup_zone

    cp "${selected}" "${ZONE_FILE}"
    chown pdns:pdns "${ZONE_FILE}"
    reload_zone
    log "Restored from: $(basename "${selected}")"
}

# ─── help ─────────────────────────────────────────────────────────────────────
cmd_help() {
    echo ""
    echo -e "${BOLD}manage-dns.sh${NC} — manage local DNS records for PowerDNS"
    echo ""
    echo -e "${BOLD}USAGE${NC}"
    echo "  sudo bash manage-dns.sh <command> [args]"
    echo ""
    echo -e "${BOLD}COMMANDS${NC}"
    echo "  list                          show all current records"
    echo "  add   <host> <ip>             add an A record"
    echo "  add   <host> <target> cname   add a CNAME record"
    echo "  remove <host>                 remove a record"
    echo "  restore                       restore zone from a previous backup"
    echo ""
    echo -e "${BOLD}EXAMPLES${NC}"
    echo "  sudo bash manage-dns.sh add     sql      192.168.1.50"
    echo "  sudo bash manage-dns.sh add     docker   10.0.0.5"
    echo "  sudo bash manage-dns.sh add     www      wiki.cosmin-lab.com cname"
    echo "  sudo bash manage-dns.sh remove  sql"
    echo "  sudo bash manage-dns.sh restore"
    echo "  sudo bash manage-dns.sh list"
    echo ""
    echo -e "${BOLD}ENVIRONMENT${NC}"
    echo "  LOCAL_DOMAIN=mylab.com sudo bash manage-dns.sh list"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run as root: sudo bash $0"

COMMAND="${1:-help}"
shift || true

case "${COMMAND}" in
    list)            cmd_list ;;
    add)             cmd_add "$@" ;;
    remove|rm|del)   cmd_remove "$@" ;;
    restore)         cmd_restore ;;
    help|--help|-h)  cmd_help ;;
    *) err "Unknown command '${COMMAND}'. Run: manage-dns.sh help" ;;
esac
