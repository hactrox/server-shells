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


    if systemctl list-unit-files \
        | grep -q "^systemd-timesyncd.service"; then

        log "Stopping systemd-timesyncd"

        systemctl disable --now systemd-timesyncd || true

    else
        log "systemd-timesyncd service not present"
    fi
}


ensure_chrony_config() {

    if [[ ! -f "${CHRONY_CONF}" ]]; then
        echo "ERROR: ${CHRONY_CONF} not found"
        exit 1
    fi


    local tmp

    tmp=$(mktemp)


    # Remove previous managed block
    awk "
        BEGIN {
            skip=0
        }

        /${MANAGED_BEGIN}/ {
            skip=1
        }

        /${MANAGED_END}/ {
            skip=0
            next
        }

        skip==0 {
            print
        }
    " "${CHRONY_CONF}" > "${tmp}"


    cat >> "${tmp}" <<EOF


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


    if cmp -s "${CHRONY_CONF}" "${tmp}"; then

        log "chrony configuration unchanged"

        rm -f "${tmp}"

        CHRONY_CHANGED=0

    else

        log "Updating chrony configuration"

        cp "${CHRONY_CONF}" \
           "${CHRONY_CONF}.backup"

        mv "${tmp}" "${CHRONY_CONF}"

        CHRONY_CHANGED=1
    fi
}


restart_chrony_if_needed() {

    if [[ "${CHRONY_CHANGED}" -eq 1 ]]; then

        log "Restarting chrony"

        systemctl enable chrony
        systemctl restart chrony

    else

        log "Skipping chrony restart"

    fi
}


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

    CHRONY_CHANGED=0


    install_chrony

    remove_systemd_timesyncd

    ensure_chrony_config

    restart_chrony_if_needed

    wait_for_sync

    verify


    echo
    echo "==> chrony bootstrap completed"
}


main "$@"
