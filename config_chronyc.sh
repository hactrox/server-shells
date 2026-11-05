#!/usr/bin/env bash

set -euo pipefail

#
# Debian 13 EC2 chrony bootstrap
#
# Features:
# - Install chrony
# - Remove systemd-timesyncd
# - Configure AWS Time Sync Service
# - Idempotent configuration management
# - Restart only when configuration changes
#

CHRONY_CONF="/etc/chrony/chrony.conf"
CHRONY_SERVICE="chrony"

AWS_NTP_SERVER="169.254.169.123"

MANAGED_BEGIN="# BEGIN AWS_TIME_SYNC_CONFIG"
MANAGED_END="# END AWS_TIME_SYNC_CONFIG"


log() {
    echo
    echo "==> $*"
}


require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: please run as root"
        echo "Example: sudo $0"
        exit 1
    fi
}


install_chrony() {
    if dpkg-query -W -f='${Status}' chrony 2>/dev/null \
        | grep -q "install ok installed"; then

        log "chrony already installed"

    else
        log "Installing chrony"

        apt update
        apt install -y chrony
    fi
}


remove_systemd_timesyncd() {

    if dpkg-query -W -f='${Status}' systemd-timesyncd 2>/dev/null \
        | grep -q "install ok installed"; then

        log "Removing systemd-timesyncd"

        apt remove -y systemd-timesyncd

    else
        log "systemd-timesyncd already removed"
    fi


    if systemctl list-unit-files systemd-timesyncd.service --no-legend \
        | grep -q "^systemd-timesyncd.service"; then

        log "Stopping systemd-timesyncd"

        systemctl disable --now systemd-timesyncd || true

    else
        log "systemd-timesyncd service not present"
    fi
}


ensure_chrony_config() (

    if [[ ! -f "${CHRONY_CONF}" ]]; then
        echo "ERROR: ${CHRONY_CONF} not found"
        exit 1
    fi


    config=$(realpath "$CHRONY_CONF")
    tmp=$(mktemp "${config}.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    cp -p -- "$config" "$tmp"

    block=$(cat <<EOF
${MANAGED_BEGIN}

# AWS Time Sync Service
server ${AWS_NTP_SERVER} prefer iburst minpoll 4 maxpoll 4

# Reject unreliable time sources
maxdistance 0.020

# Allow initial clock correction
makestep 1.0 3

# Keep hardware clock synchronized
rtcsync

${MANAGED_END}
EOF
    )

    # Replace the existing block in place so administrator directives keep
    # their order. Reject broken markers before replacing the live file.
    if ! CHRONY_BLOCK="$block" awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '
        BEGIN { block = ENVIRON["CHRONY_BLOCK"] }
        $0 == begin {
            if (inside) exit 1
            if (!seen) print block
            inside = seen = 1
            next
        }
        $0 == end {
            if (!inside) exit 1
            inside = 0
            next
        }
        !inside { print }
        END {
            if (inside) exit 1
            if (!seen) print block
        }
    ' "$config" > "$tmp"; then
        echo "ERROR: malformed AWS time sync markers in $config" >&2
        return 1
    fi

    if cmp -s "$config" "$tmp"; then
        log "chrony configuration unchanged"
        systemctl enable --now "$CHRONY_SERVICE"
        return
    fi

    log "Updating chrony configuration"
    chronyd -p -f "$tmp" >/dev/null
    systemctl enable "$CHRONY_SERVICE"
    cp -p -- "$config" "${CHRONY_CONF}.backup"
    mv -- "$tmp" "$config"
    if ! systemctl restart "$CHRONY_SERVICE"; then
        echo "ERROR: chrony restart failed; restoring the previous configuration" >&2
        cp -p -- "${CHRONY_CONF}.backup" "$tmp"
        mv -- "$tmp" "$config"
        systemctl restart "$CHRONY_SERVICE"
        return 1
    fi
)


wait_for_sync() {

    log "Waiting for chrony synchronization"


    if chronyc waitsync 60; then

        echo "chrony synchronized"

    else

        echo "WARNING: chrony did not synchronize within 60 seconds"

    fi
}


verify() {

    echo
    echo "===================================="
    echo "chrony sources"
    echo "===================================="

    chronyc sources -v


    echo
    echo "===================================="
    echo "chrony tracking"
    echo "===================================="

    chronyc tracking
}


main() {

    require_root

    install_chrony

    remove_systemd_timesyncd

    ensure_chrony_config

    wait_for_sync

    verify


    echo
    echo "==> chrony bootstrap completed"
}


main "$@"
