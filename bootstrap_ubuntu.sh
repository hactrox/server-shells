#!/usr/bin/env bash
# Ubuntu 24.04 / 26.04 LTS AWS EC2 bootstrap script.
#
# BASE INSTALLATION — always executed:
#   - APT prerequisites
#   - en_US.UTF-8 locale
#   - Git from Ubuntu APT
#   - System-wide interactive Bash aliases: ls, ll and l
#
# OPTIONAL SYSTEM CONFIGURATION:
#   --hostname NAME  Set the static hostname and preserve it in cloud-init
#   --hosts-entry    Manage 127.0.1.1 for that hostname in /etc/hosts;
#                    requires --hostname and is normally unnecessary on EC2
#
# OPTIONAL COMPONENTS — installed only when explicitly requested:
#   --go          Install Go from go.dev under /usr/local/go
#   --tmux        Build tmux from its official release archive; create config if missing
#   --vim         Build Vim from its official source repository; create vimrc if missing
#   --ssm         Reuse an existing SSM Agent or install it with Snap; enable/start it
#   --cloudwatch  Install, configure, enable, and start CloudWatch Agent
#
# EC2 PRESET:
#   --ec2         Equivalent to: --upgrade --go --tmux --ssm --cloudwatch
#                 May be combined with other explicit flags, e.g. --ec2 --vim
#
# GENERAL OPTIONS:
#   --upgrade     Run apt-get upgrade before installing packages
#   -h, --help    Show the complete command-line help
#
# User-owned files are assigned to the invoking account. When a non-root user
# runs the script with sudo, SUDO_USER is used (for example, admin -> /home/admin).
# When the server is accessed and the script is run directly as root, root is a
# valid target user and user-level files are created under /root.
#
# Component versions are not accepted as command-line arguments. Update them
# manually in the USER-EDITABLE VERSION CONSTANTS block below.
#
# Destructive disk operations are NEVER performed automatically.
# Safe manual EBS setup instructions are printed at the end.

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# ==============================================================================
# USER-EDITABLE VERSION CONSTANTS
#
# Edit the values in this block when periodically updating component versions.
# Do not add command-line overrides for these values; the script intentionally
# uses this single, reviewable source of truth.
# ==============================================================================
readonly GO_VERSION="1.27.3"
readonly TMUX_VERSION="3.8"
readonly VIM_REF="v9.2.1252"

# ==============================================================================
# INTERNAL RUNTIME STATE — DO NOT EDIT BELOW THIS LINE
# Values below are populated from command-line arguments or detected at runtime.
# ==============================================================================
TARGET_HOSTNAME=""
TARGET_USER=""
ADD_HOSTS_ENTRY=false
INSTALL_GO=false
INSTALL_TMUX=false
INSTALL_VIM=false
INSTALL_SSM=false
INSTALL_CLOUDWATCH=false
UPGRADE_SYSTEM=false

STEP_NO=0
TOTAL_STEPS=0
LOG_FILE=""
DOWNLOAD_DIR=""
TARGET_HOME=""
TARGET_UID=""
TARGET_GID=""
DEB_ARCH=""
GO_ARCH=""
SSM_INSTALL_METHOD=""
SSM_SERVICE=""

usage() {
    cat <<'EOF'
Usage:
  sudo bash ./bootstrap_ubuntu.sh [options]

Supported systems: Ubuntu 24.04 and 26.04 LTS, amd64 or arm64.
Base setup always installs APT prerequisites, en_US.UTF-8 locale and Git.
It also configures system-wide ls, ll and l aliases for interactive Bash.
Go, tmux, Vim, SSM Agent and CloudWatch Agent are optional.
The --ec2 preset enables system upgrade, Go, tmux, SSM Agent and CloudWatch Agent.
User-owned files are created for the invoking account. Under sudo, SUDO_USER is
used so a caller such as admin keeps ownership of files under /home/admin. When
the script is run directly from a root login, root is valid and /root is used.

Options:
  --hostname NAME       Set the static hostname and preserve it in cloud-init.
  --hosts-entry         Also manage "127.0.1.1 NAME" in /etc/hosts.
                        Normally unnecessary on EC2; use only when local
                        hostname resolution is required.
  --go                  Install the pinned Go version from go.dev under /usr/local/go.
  --tmux                Build/install the pinned tmux release; create a default config if missing.
  --vim                 Build/install the pinned Vim ref; create a default vimrc if missing.
  --ssm                 Reuse an existing Snap/DEB SSM Agent, or install with Snap.
                        Enable and start the selected agent; reject duplicate installs.
  --cloudwatch          Install, configure and enable Amazon CloudWatch Agent.
  --ec2                 Enable --upgrade, --go, --tmux, --ssm and --cloudwatch.
                        Other components still require explicit flags.
  --upgrade             Run apt-get upgrade before installing packages.
  -h, --help            Show this help.

Examples:
  sudo bash ./bootstrap_ubuntu.sh --ec2
  sudo bash ./bootstrap_ubuntu.sh --ec2 --vim
  sudo bash ./bootstrap_ubuntu.sh --ec2 --vim --hostname xxx
  sudo bash ./bootstrap_ubuntu.sh --hostname xxx
  sudo bash ./bootstrap_ubuntu.sh --hostname xxx --go --tmux

Component versions are maintained only in the USER-EDITABLE VERSION CONSTANTS
block near the top of this file; they cannot be overridden on the command line.

The script is intended to be safely rerunnable. Installation packages and build
sources use temporary directories under /tmp, removed when the script exits.
Logs remain in the target user's downloads directory.
Components that satisfy the pinned version are skipped.
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --hostname)
                (($# >= 2)) || { fail 'Missing value for --hostname' >&2; exit 2; }
                TARGET_HOSTNAME="$2"
                shift 2
                ;;
            --hosts-entry)
                ADD_HOSTS_ENTRY=true
                shift
                ;;
            --go)
                INSTALL_GO=true
                shift
                ;;
            --tmux)
                INSTALL_TMUX=true
                shift
                ;;
            --vim)
                INSTALL_VIM=true
                shift
                ;;
            --ssm)
                INSTALL_SSM=true
                shift
                ;;
            --cloudwatch)
                INSTALL_CLOUDWATCH=true
                shift
                ;;
            --ec2)
                UPGRADE_SYSTEM=true
                INSTALL_GO=true
                INSTALL_TMUX=true
                INSTALL_SSM=true
                INSTALL_CLOUDWATCH=true
                shift
                ;;
            --upgrade)
                UPGRADE_SYSTEM=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                (($# == 0)) || { fail "Unexpected positional argument: $1" >&2; exit 2; }
                ;;
            *)
                fail "Unknown option: $1" >&2
                printf '\n' >&2
                usage >&2
                exit 2
                ;;
        esac
    done
}

have() {
    command -v "$1" >/dev/null 2>&1
}

as_root() {
    if ((EUID == 0)); then
        "$@"
    else
        sudo "$@"
    fi
}

as_user() {
    if [[ "$(id -u)" == "$TARGET_UID" ]]; then
        "$@"
    elif ((EUID == 0)); then
        runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" "$@"
    else
        sudo -u "$TARGET_USER" -H "$@"
    fi
}

log_line() {
    local level="$1"
    shift
    local line color symbol
    printf -v line '[%s] %s' "$level" "$*"
    case "$level" in
        INFO)   color=36; symbol='•' ;;
        ' OK ') color=32; symbol='✓' ;;
        WARN)   color='1;33'; symbol='⚠' ;;
        FAIL)   color='1;31'; symbol='✗' ;;
        *)      color=0; symbol='•' ;;
    esac
    # Decorate console output only; keep the file log in its original format.
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
        printf '\033[%sm%s %s\033[0m\n' "$color" "$symbol" "$line"
    else
        printf '%s %s\n' "$symbol" "$line"
    fi
    [[ -z "$LOG_FILE" ]] || printf '%s\n' "$line" >>"$LOG_FILE"
}

info()    { log_line 'INFO' "$@"; }
success() { log_line ' OK ' "$@"; }
warn()    { log_line 'WARN' "$@"; }
fail()    { log_line 'FAIL' "$@"; }

step() {
    STEP_NO=$((STEP_NO + 1))
    printf '\n[%d/%d] %s\n' "$STEP_NO" "$TOTAL_STEPS" "$*"
    [[ -z "$LOG_FILE" ]] || printf '\n[%d/%d] %s\n' "$STEP_NO" "$TOTAL_STEPS" "$*" >>"$LOG_FILE"
}

run_logged() {
    local description="$1"
    shift

    info "$description"
    if "$@" >>"$LOG_FILE" 2>&1; then
        success "$description"
    else
        local rc=$?
        fail "$description (exit $rc)"
        printf '\nLast 60 log lines:\n' >&2
        tail -n 60 "$LOG_FILE" >&2 || true
        return "$rc"
    fi
}

on_error() {
    local rc=$?
    local line="$1"
    local command="$2"
    trap - ERR
    fail "Stopped at line $line: $command"
    [[ -z "$LOG_FILE" ]] || printf 'Full log: %s\n' "$LOG_FILE" >&2
    exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_privilege() {
    if ((EUID != 0)); then
        have sudo || { fail 'sudo is required when not running as root.' >&2; exit 1; }
        sudo -v
    fi
}

select_target_user() {
    # Preserve the invoking account across sudo. For example, admin running
    # "sudo ./script.sh" has EUID=0 but SUDO_USER=admin, so user-level files
    # stay under /home/admin. If the session itself is root, root is a valid
    # target user and its home directory (/root) is used.
    if ((EUID == 0)) && [[ -n "${SUDO_USER:-}" ]]; then
        TARGET_USER="$SUDO_USER"
    else
        TARGET_USER="$(id -un)"
    fi

    id "$TARGET_USER" >/dev/null 2>&1 || {
        fail "Target user does not exist: $TARGET_USER" >&2
        exit 1
    }

    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    TARGET_UID="$(id -u "$TARGET_USER")"
    TARGET_GID="$(id -g "$TARGET_USER")"
    [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || {
        fail "Target home directory is unavailable: $TARGET_HOME" >&2
        exit 1
    }
}

prepare_workspace() {
    local log_dir="$TARGET_HOME/downloads"
    as_root install -d -m 0755 -o "$TARGET_UID" -g "$TARGET_GID" "$log_dir"

    LOG_FILE="$log_dir/ec2-bootstrap.log"
    as_root touch "$LOG_FILE"
    as_root chown "$TARGET_UID:$TARGET_GID" "$LOG_FILE"

    DOWNLOAD_DIR="$(as_user mktemp -d /tmp/ec2-bootstrap.XXXXXX)"
    trap 'as_root rm -rf -- "$DOWNLOAD_DIR"' EXIT
    # Allow APT's unprivileged downloader to read local .deb packages.
    as_user chmod 0755 "$DOWNLOAD_DIR"
}

check_platform() {
    [[ -r /etc/os-release ]] || { fail '/etc/os-release is missing'; exit 1; }
    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-}:${VERSION_ID:-}" in
        ubuntu:24.04|ubuntu:26.04) ;;
        *)
            fail "This script requires Ubuntu 24.04 or 26.04 LTS; detected ${PRETTY_NAME:-unknown}."
            exit 1
            ;;
    esac

    DEB_ARCH="$(dpkg --print-architecture)"
    case "$DEB_ARCH" in
        amd64) GO_ARCH="amd64" ;;
        arm64) GO_ARCH="arm64" ;;
        *)
            fail "Unsupported architecture: $DEB_ARCH (supported: amd64, arm64)"
            exit 1
            ;;
    esac

    if [[ -n "$TARGET_HOSTNAME" || "$INSTALL_SSM" == true || "$INSTALL_CLOUDWATCH" == true ]]; then
        if ! have systemctl || [[ ! -d /run/systemd/system ]]; then
            fail 'Hostname and AWS Agent setup require a system booted with systemd.'
            exit 1
        fi
    fi
}

validate_inputs() {
    [[ "$GO_VERSION" =~ ^[0-9]+\.[0-9]+([.][0-9]+)?([a-z0-9.-]+)?$ ]] || {
        fail "Invalid Go version: $GO_VERSION"
        exit 2
    }
    [[ "$TMUX_VERSION" =~ ^[0-9]+\.[0-9]+[a-z]?$ ]] || {
        fail "Invalid tmux version: $TMUX_VERSION"
        exit 2
    }
    [[ -n "$VIM_REF" && "$VIM_REF" != -* ]] || {
        fail "Invalid Vim ref: $VIM_REF"
        exit 2
    }
    if [[ -n "$TARGET_HOSTNAME" ]]; then
        if ((${#TARGET_HOSTNAME} > 253)) ||
           [[ ! "$TARGET_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
           [[ "$TARGET_HOSTNAME" == *..* ]]; then
            fail "Invalid hostname: $TARGET_HOSTNAME"
            exit 2
        fi
        local label
        IFS='.' read -r -a labels <<<"$TARGET_HOSTNAME"
        for label in "${labels[@]}"; do
            if ((${#label} > 63)) || [[ "$label" == -* || "$label" == *- ]]; then
                fail "Invalid hostname label: $label"
                exit 2
            fi
        done
    elif [[ "$ADD_HOSTS_ENTRY" == true ]]; then
        fail '--hosts-entry requires --hostname NAME.'
        exit 2
    fi
}

calculate_steps() {
    # Base: APT index, packages, locale, Bash aliases, hostname/cloud-init and verification.
    TOTAL_STEPS=6
    [[ "$INSTALL_GO" == true ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    # tmux installation and tmux configuration are separate steps.
    [[ "$INSTALL_TMUX" == true ]] && TOTAL_STEPS=$((TOTAL_STEPS + 2))
    [[ "$INSTALL_VIM" == true ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    [[ "$INSTALL_SSM" == true ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    [[ "$INSTALL_CLOUDWATCH" == true ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    return 0
}

apt_env() {
    as_root env \
        DEBIAN_FRONTEND=noninteractive \
        NEEDRESTART_MODE=a \
        APT_LISTCHANGES_FRONTEND=none \
        "$@"
}

update_apt() {
    step 'Updating APT package index'
    run_logged 'apt-get update' apt_env apt-get update

    if [[ "$UPGRADE_SYSTEM" == true ]]; then
        run_logged 'Upgrading installed packages' apt_env apt-get -o Dpkg::Options::=--force-confold upgrade -y
    else
        info 'System upgrade skipped (use --upgrade to enable it).'
    fi
}

install_base_packages() {
    step 'Installing required packages'

    local packages=(
        ca-certificates curl wget gnupg jq unzip xz-utils tar gzip locales
        git xfsprogs rsync
    )
    if [[ "$INSTALL_TMUX" == true || "$INSTALL_VIM" == true ]]; then
        packages+=(
            build-essential pkg-config bison
            libevent-dev libncurses-dev libssl-dev
        )
    fi
    if [[ "$INSTALL_VIM" == true ]]; then
        packages+=(autoconf automake libtool-bin libacl1-dev libgpm-dev python3-dev)
    fi

    run_logged 'Installing base packages' \
        apt_env apt-get install -y --no-install-recommends "${packages[@]}"

    success "Git: $(git --version)"
}

configure_locale() {
    step 'Configuring locale'

    if locale -a 2>/dev/null | grep -Eiq '^en_US[.]utf-?8$'; then
        success 'en_US.UTF-8 is already generated.'
    else
        info 'Generating en_US.UTF-8.'
        if grep -Eq '^#[[:space:]]*en_US[.]UTF-8[[:space:]]+UTF-8' /etc/locale.gen; then
            as_root sed -i -E 's/^#[[:space:]]*(en_US[.]UTF-8[[:space:]]+UTF-8)/\1/' /etc/locale.gen
        elif ! grep -Eq '^[[:space:]]*en_US[.]UTF-8[[:space:]]+UTF-8' /etc/locale.gen; then
            printf 'en_US.UTF-8 UTF-8\n' | as_root tee -a /etc/locale.gen >/dev/null
        fi
        run_logged 'Running locale-gen' as_root locale-gen en_US.UTF-8
    fi

    run_logged 'Setting default LANG=en_US.UTF-8' as_root update-locale LANG=en_US.UTF-8
    export LANG=en_US.UTF-8
}

configure_bash_aliases() {
    step 'Configuring system-wide Bash aliases'

    local bashrc='/etc/bash.bashrc'
    local marker='# server-shells: global ls aliases'
    if grep -Fqx "$marker" "$bashrc"; then
        success 'System-wide Bash aliases are already configured.'
        return
    fi

    as_root tee -a "$bashrc" >/dev/null <<'EOF'

# server-shells: global ls aliases
# Defaults for all interactive Bash users; ~/.bashrc can override these.
case $- in
    *i*)
        # Preserve an existing value, including an explicitly empty one.
        : "${LS_OPTIONS=--color=auto}"
        export LS_OPTIONS
        eval "$(dircolors -b)"
        alias ls='ls $LS_OPTIONS'
        alias ll='ls $LS_OPTIONS -l'
        alias l='ls $LS_OPTIONS -lA'
        ;;
esac
EOF
    success "Configured ls, ll and l aliases in $bashrc."
}

manage_hosts_entry() {
    local hostname="$1"
    local tmp
    tmp="$(mktemp)"

    awk -v hostname="$hostname" '
        BEGIN { written = 0 }
        $1 == "127.0.1.1" {
            if (!written) {
                print "127.0.1.1 " hostname
                written = 1
            }
            next
        }
        { print }
        END {
            if (!written) print "127.0.1.1 " hostname
        }
    ' /etc/hosts >"$tmp"

    if cmp -s "$tmp" /etc/hosts; then
        rm -f "$tmp"
        success '/etc/hosts already has the requested 127.0.1.1 entry.'
        return
    fi

    if [[ ! -e /etc/hosts.ec2-bootstrap.orig ]]; then
        as_root cp -a /etc/hosts /etc/hosts.ec2-bootstrap.orig
    fi
    as_root install -m 0644 "$tmp" /etc/hosts
    rm -f "$tmp"
    success 'Updated /etc/hosts; original saved as /etc/hosts.ec2-bootstrap.orig.'
}

configure_hostname() {
    step 'Configuring hostname and cloud-init behavior'

    if [[ -z "$TARGET_HOSTNAME" ]]; then
        info 'Hostname unchanged (use --hostname NAME to set it).'
        return
    fi

    local current
    current="$(hostnamectl --static 2>/dev/null || hostname)"
    info "Current hostname: $current"
    info "Target hostname : $TARGET_HOSTNAME"

    if [[ "$current" == "$TARGET_HOSTNAME" ]]; then
        success 'Hostname is already configured.'
    else
        run_logged "Setting hostname to $TARGET_HOSTNAME" \
            as_root hostnamectl set-hostname "$TARGET_HOSTNAME"
    fi

    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
        local cloud_cfg='/etc/cloud/cloud.cfg.d/99_hostname.cfg'
        local desired='preserve_hostname: true'
        if [[ -f "$cloud_cfg" ]] && [[ "$(tr -d '\r' <"$cloud_cfg" | sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d')" == "$desired" ]]; then
            success 'cloud-init preserve_hostname is already configured.'
        else
            printf '%s\n' "$desired" | as_root tee "$cloud_cfg" >/dev/null
            as_root chmod 0644 "$cloud_cfg"
            success "Wrote $cloud_cfg."
        fi
    else
        warn '/etc/cloud/cloud.cfg.d does not exist; cloud-init override was skipped.'
    fi

    if [[ "$ADD_HOSTS_ENTRY" == true ]]; then
        manage_hosts_entry "$TARGET_HOSTNAME"
    else
        info '/etc/hosts left unchanged; use --hosts-entry only if local resolution is required.'
    fi
}

resolve_go_checksum() {
    local filename="$1"

    local metadata checksum
    metadata="$(curl -fsSL --retry 3 --retry-delay 2 'https://go.dev/dl/?mode=json&include=all')"
    checksum="$(jq -r --arg filename "$filename" '
        [.[] | .files[] | select(.filename == $filename) | .sha256][0] // empty
    ' <<<"$metadata")"

    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || {
        fail "Unable to resolve the SHA256 for $filename from go.dev."
        return 1
    }
    printf '%s\n' "$checksum"
}

# Stage on the destination filesystem so a failed download, extraction or rename
# leaves the previous installation available. This subshell owns the EXIT trap.
install_go_release() (
    filename="$1"
    checksum="$2"
    [[ -d /usr/local ]] || as_root install -d -m 0755 /usr/local
    stage="$(as_root mktemp -d /usr/local/.go-install.XXXXXX)"
    cleanup_go_stage() {
        if [[ ! -e /usr/local/go && ! -L /usr/local/go ]] &&
           { as_root test -e "$stage/previous" || as_root test -L "$stage/previous"; }; then
            as_root mv -T -- "$stage/previous" /usr/local/go || {
                printf 'Restore the previous Go installation from %s/previous\n' "$stage" >&2
                return 1
            }
        fi
        as_root rm -rf -- "$stage"
    }
    trap cleanup_go_stage EXIT

    curl -fsSL --retry 3 --retry-delay 2 "https://go.dev/dl/$filename" |
        as_root tee "$stage/$filename" >/dev/null
    printf '%s  %s\n' "$checksum" "$stage/$filename" | as_root sha256sum -c -
    as_root tar --no-same-owner -C "$stage" -xzf "$stage/$filename"
    candidate="$(as_root env GOTOOLCHAIN=local "$stage/go/bin/go" version)"
    [[ "$(awk '{print $3}' <<<"$candidate")" == "go$GO_VERSION" ]] || {
        printf 'Downloaded Go version does not match %s\n' "$GO_VERSION" >&2
        return 1
    }

    # Hold the destination lock through publication and EXIT rollback.
    exec 9</usr/local
    flock -x 9
    if [[ -e /usr/local/go || -L /usr/local/go ]]; then
        as_root mv -T -- /usr/local/go "$stage/previous"
    fi
    as_root mv -T -- "$stage/go" /usr/local/go
)

install_go() {
    step "Installing Go $GO_VERSION"

    local desired="go${GO_VERSION}"
    local current=""
    if [[ -x /usr/local/go/bin/go ]]; then
        current="$(GOTOOLCHAIN=local /usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' || true)"
    fi

    if [[ "$current" == "$desired" ]]; then
        success "$desired is already installed in /usr/local/go."
    else
        local filename="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
        local expected
        expected="$(resolve_go_checksum "$filename")"
        install_go_release "$filename" "$expected"
    fi

    # Manage login PATH independently of this process's (possibly sudo) PATH.
    local go_on_path go_path_value go_path_pattern
    case ":${PATH:-}:" in
        *:/usr/local/go/bin:*|*:/usr/local/go/bin/:*) go_on_path=true ;;
        *) go_on_path=false ;;
    esac
    # Match a complete quoted/unquoted assignment value, not a comment or suffix.
    go_path_value="(\"([^\"]*:)?/usr/local/go/bin/?(:[^\"]*)?\""
    go_path_value+="|'([^']*:)?/usr/local/go/bin/?(:[^']*)?'"
    go_path_value+="|([^[:space:]#;\"']*:)?/usr/local/go/bin/?(:[^[:space:]#;\"']*)?)"
    go_path_pattern="^[[:space:]]*(export[[:space:]]+)?PATH=$go_path_value([[:space:]]*(;.*)?|[[:space:]]+#.*)$"
    if grep -Eq "$go_path_pattern" /etc/profile; then
        info '/etc/profile already configures the Go path.'
    else
        as_root tee -a /etc/profile >/dev/null <<'EOF'

case ":${PATH:-}:" in
    *:/usr/local/go/bin:*|*:/usr/local/go/bin/:*) ;;
    *)
        export PATH="/usr/local/go/bin:$PATH"
        ;;
esac
EOF
        info 'Added the Go path to /etc/profile.'
    fi
    if [[ "$go_on_path" == false ]]; then
        export PATH="/usr/local/go/bin:$PATH"
        info 'If Go is missing from PATH in your existing shell, run: export PATH="/usr/local/go/bin:$PATH"'
    fi

    [[ "$(GOTOOLCHAIN=local /usr/local/go/bin/go version | awk '{print $3}')" == "$desired" ]] || {
        fail 'Go verification failed.'
        return 1
    }
    success "$(GOTOOLCHAIN=local /usr/local/go/bin/go version)"
}

checkout_repo_ref() {
    local repo_url="$1"
    local repo_dir="$2"
    local ref="$3"

    if [[ -d "$repo_dir/.git" ]]; then
        run_logged "Fetching updates for $repo_dir" \
            as_user git -C "$repo_dir" fetch --tags --prune origin
    elif [[ -e "$repo_dir" ]]; then
        fail "$repo_dir exists but is not a Git repository. Move or remove it first."
        return 1
    else
        run_logged "Cloning $repo_url" as_user git clone "$repo_url" "$repo_dir"
        run_logged "Fetching tags for $repo_dir" \
            as_user git -C "$repo_dir" fetch --tags --prune origin
    fi

    local commit
    if as_user git -C "$repo_dir" rev-parse --verify --quiet "origin/$ref^{commit}" >/dev/null; then
        commit="$(as_user git -C "$repo_dir" rev-parse "origin/$ref^{commit}")"
    elif as_user git -C "$repo_dir" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
        commit="$(as_user git -C "$repo_dir" rev-parse "$ref^{commit}")"
    else
        fail "Git ref not found in $repo_url: $ref"
        return 1
    fi

    run_logged "Checking out $ref ($commit)" \
        as_user git -C "$repo_dir" checkout --detach --force "$commit"
    run_logged "Cleaning source tree $repo_dir" \
        as_user git -C "$repo_dir" clean -fdx
}

install_tmux() {
    step "Installing tmux $TMUX_VERSION from its official release archive"

    local expected="tmux $TMUX_VERSION"
    local pending='/usr/local/.server-shells-tmux-installing'
    local current=""
    if [[ -x /usr/local/bin/tmux ]]; then
        current="$(/usr/local/bin/tmux -V 2>/dev/null || true)"
    fi

    if [[ ! -e "$pending" && "$current" == "$expected" ]]; then
        success "$expected is already installed."
        return
    fi

    local archive="$DOWNLOAD_DIR/tmux-${TMUX_VERSION}.tar.gz"
    local source_dir="$DOWNLOAD_DIR/tmux"
    run_logged 'Downloading tmux source archive' \
        as_user curl -fL --retry 3 --retry-delay 2 \
        -o "$archive" \
        "https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz"
    as_user mkdir "$source_dir"
    run_logged 'Extracting tmux source archive' \
        as_user tar -C "$source_dir" --strip-components=1 -xzf "$archive"

    run_logged 'Configuring tmux' \
        as_user bash -lc "cd '$source_dir' && ./configure --prefix=/usr/local"
    run_logged 'Compiling tmux' \
        as_user bash -lc "cd '$source_dir' && make -j'$(nproc)'"

    local built
    if ! built="$(as_user "$source_dir/tmux" -V 2>/dev/null)" ||
       [[ "$built" != "$expected" ]]; then
        fail "Built tmux verification failed: expected '$expected', got '$built'"
        return 1
    fi

    # make install writes several files. A retry must finish an interrupted install.
    as_root mkdir -p /usr/local
    local installed
    {
        flock -x 9
        as_root touch "$pending"
        run_logged 'Installing tmux' \
            as_root make -C "$source_dir" install

        hash -r
        installed="$(/usr/local/bin/tmux -V 2>/dev/null || true)"
        [[ "$installed" == "$expected" ]] || {
            fail "tmux verification failed: expected '$expected', got '$installed'"
            return 1
        }
        as_root rm -f -- "$pending"
    } 9</usr/local
    success "$installed"
}

write_tmux_config() {
    step 'Checking tmux configuration'

    local target="$TARGET_HOME/.tmux.conf"
    if [[ -e "$target" || -L "$target" ]]; then
        info "Keeping existing $target."
        return
    fi

    local tmp
    tmp="$(mktemp "$DOWNLOAD_DIR/tmux-config.XXXXXX")"
    cat >"$tmp" <<'EOF'
# Reload configuration
bind r source-file ~/.tmux.conf \; display-message "Config reloaded"

# Vi-style copy mode and pane navigation
set -g mode-keys vi
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# Resize panes
bind H resize-pane -L 10
bind L resize-pane -R 10
bind J resize-pane -D 5
bind K resize-pane -U 5

# Select last window
bind-key C-l select-window -l

# Split in the current pane directory
bind '"' split-window -c '#{pane_current_path}'
bind '%' split-window -h -c '#{pane_current_path}'

# Enable mouse mode
set -g mouse on
EOF

    as_root install -m 0644 -o "$TARGET_UID" -g "$TARGET_GID" "$tmp" "$target"
    rm -f "$tmp"
    success "Created $target."
}

# A release tag can be recognized from either installer's binary. Other Git
# refs need both the resolved commit and the digest of the binary it installed.
vim_matches_target() {
    local binary="$1" version_long="$2"
    [[ -x "$binary" ]] && as_user "$binary" -N -u NONE -i NONE -n -es \
        -c "if ($version_long && v:versionlong != $version_long) || !has('python3_dynamic') || !has('terminal') | cquit 1 | endif" \
        -c 'qa!'
}

install_vim_binary() {
    local binary='/usr/local/bin/vim' version_long=0
    local pending='/usr/local/.server-shells-vim-installing'
    if [[ "$VIM_REF" =~ ^v([0-9]+)[.]([0-9]+)[.]([0-9]+)$ ]]; then
        version_long=$((10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 10000 + 10#${BASH_REMATCH[3]}))
        if [[ ! -e "$pending" ]] && vim_matches_target "$binary" "$version_long"; then
            success "Vim $VIM_REF with Python 3 dynamic and terminal support is already installed."
            return
        fi
    fi

    local repo_dir="$DOWNLOAD_DIR/vim"
    checkout_repo_ref 'https://github.com/vim/vim.git' "$repo_dir" "$VIM_REF"

    local marker='/usr/local/share/ec2-bootstrap/vim-commit' commit='' digest
    if ((version_long == 0)); then
        commit="$(as_user git -C "$repo_dir" rev-parse HEAD)"
        if [[ ! -e "$pending" && -f "$marker" ]] && vim_matches_target "$binary" 0; then
            digest="$(sha256sum "$binary")"
            if [[ "$(<"$marker")" == "$commit ${digest%% *}" ]]; then
                success "Vim source commit $commit is already installed."
                return
            fi
        fi
    fi

    run_logged 'Configuring Vim' \
        as_user bash -c 'cd "$1" && ./configure \
            --prefix=/usr/local \
            --with-features=huge \
            --enable-multibyte \
            --enable-python3interp=dynamic \
            --enable-terminal \
            --disable-gui \
            --without-x' bash "$repo_dir"
    run_logged 'Compiling Vim' as_user make -C "$repo_dir" -j"$(nproc)"
    vim_matches_target "$repo_dir/src/vim" "$version_long" || {
        fail "Built Vim does not match $VIM_REF with Python 3 dynamic and terminal support."
        return 1
    }
    # The executable can be installed before its runtime files.
    as_root mkdir -p /usr/local
    {
        flock -x 9
        as_root touch "$pending"
        run_logged 'Installing Vim' as_root make -C "$repo_dir" install
        vim_matches_target "$binary" "$version_long" || {
            fail "Installed Vim does not match $VIM_REF with Python 3 dynamic and terminal support."
            return 1
        }
        if [[ -n "$commit" ]]; then
            as_root install -d -m 0755 /usr/local/share/ec2-bootstrap
            digest="$(sha256sum "$binary")"
            printf '%s %s\n' "$commit" "${digest%% *}" | as_root tee "$marker" >/dev/null
            as_root chmod 0644 "$marker"
        fi
        as_root rm -f -- "$pending"
    } 9</usr/local
}

install_vim() {
    step "Installing Vim from official source ref '$VIM_REF'"
    install_vim_binary

    hash -r
    success "$(/usr/local/bin/vim --version | sed -n '1p')"

    local vimrc="$TARGET_HOME/.vimrc"
    if [[ -e "$vimrc" || -L "$vimrc" ]]; then
        info "Keeping existing $vimrc."
        return
    fi
    local tmp
    tmp="$(mktemp)"
    cat >"$tmp" <<'EOF'
set nocompatible
set encoding=utf-8
filetype plugin indent on
syntax enable

set number
set cursorline
set hidden
set backspace=indent,eol,start
set tabstop=4
set shiftwidth=4
set softtabstop=4
set expandtab
set autoindent
set smartindent
set incsearch
set hlsearch
set ignorecase
set smartcase
set mouse=a
EOF

    as_root install -m 0644 -o "$TARGET_UID" -g "$TARGET_GID" "$tmp" "$vimrc"
    rm -f "$tmp"
    success "Created $vimrc."
}

detect_ssm_installation() {
    local deb_installed=false snap_installed=false snap_list
    SSM_INSTALL_METHOD=""
    SSM_SERVICE=""

    if [[ "$(dpkg-query -W -f='${Status}' amazon-ssm-agent 2>/dev/null || true)" == 'install ok installed' ]]; then
        deb_installed=true
    fi
    if have snap; then
        # An unfiltered list succeeds even when no snaps are installed. A query
        # failure must not be mistaken for an absent agent (for example, snapd
        # is unavailable). Never install a second agent based on that guess.
        if ! snap_list="$(as_root env LC_ALL=C snap list)"; then
            fail 'Cannot inspect installed snaps. Check snapd and retry before installing SSM Agent.'
            return 1
        fi
        if awk '$1 == "amazon-ssm-agent" { found = 1 } END { exit !found }' <<<"$snap_list"; then
            snap_installed=true
        fi
    fi

    if [[ "$deb_installed" == true && "$snap_installed" == true ]]; then
        fail 'Both Snap and DEB SSM Agents are installed. Keep one installation before rerunning; neither was removed.'
        return 1
    elif [[ "$snap_installed" == true ]]; then
        SSM_INSTALL_METHOD='snap'
        SSM_SERVICE='snap.amazon-ssm-agent.amazon-ssm-agent.service'
    elif [[ "$deb_installed" == true ]]; then
        SSM_INSTALL_METHOD='deb'
        SSM_SERVICE='amazon-ssm-agent.service'
    fi
}

install_ssm() {
    step 'Installing Amazon SSM Agent'

    # Recheck after APT operations, which can complete image provisioning.
    detect_ssm_installation
    if [[ -z "$SSM_INSTALL_METHOD" ]]; then
        # AWS recommends Snap on Ubuntu. Preserve an existing DEB installation
        # instead of silently replacing a potentially active management agent.
        if ! have snap; then
            run_logged 'Installing snapd' apt_env apt-get install -y --no-install-recommends snapd
        fi
        run_logged 'Enabling snapd socket' as_root systemctl enable --now snapd.socket
        run_logged 'Waiting for initial Snap seeding (up to 180 seconds)' \
            as_root timeout 180 snap wait system seed.loaded
        run_logged 'Installing SSM Agent from the stable Snap channel' \
            as_root snap install amazon-ssm-agent --classic --channel=stable
        SSM_INSTALL_METHOD='snap'
        SSM_SERVICE='snap.amazon-ssm-agent.amazon-ssm-agent.service'
    else
        success "SSM Agent is already installed ($SSM_INSTALL_METHOD)."
    fi

    if [[ "$SSM_INSTALL_METHOD" == snap ]]; then
        run_logged 'Enabling and starting Snap SSM Agent' \
            as_root snap start --enable amazon-ssm-agent
    else
        run_logged 'Enabling and starting DEB SSM Agent' \
            as_root systemctl enable --now "$SSM_SERVICE"
    fi
    run_logged 'Verifying SSM Agent service' as_root systemctl is-active --quiet "$SSM_SERVICE"
    success "SSM Agent service: $SSM_SERVICE"
}

install_cloudwatch() {
    step 'Installing and configuring Amazon CloudWatch Agent'

    if dpkg-query -W -f='${Status}' amazon-cloudwatch-agent 2>/dev/null | grep -q 'install ok installed'; then
        success 'amazon-cloudwatch-agent package is already installed.'
    else
        local package_file="$DOWNLOAD_DIR/amazon-cloudwatch-agent-${DEB_ARCH}.deb"
        local url="https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/${DEB_ARCH}/latest/amazon-cloudwatch-agent.deb"

        run_logged 'Downloading the latest CloudWatch Agent package' \
            as_user curl -fL --retry 4 --retry-all-errors -o "$package_file.part" "$url"
        as_user mv "$package_file.part" "$package_file"
        run_logged 'Installing CloudWatch Agent' apt_env apt-get install -y "$package_file"
    fi

    local config_dir='/opt/aws/amazon-cloudwatch-agent/etc'
    local config="$config_dir/amazon-cloudwatch-agent.json" fragment=''
    if as_root test -d "$config_dir/amazon-cloudwatch-agent.d"; then
        # The agent leaves .tmp fragments pending until validation succeeds.
        fragment="$(as_root find "$config_dir/amazon-cloudwatch-agent.d" -maxdepth 1 \
            \( -type f -o -type l \) ! -name '*.tmp' -print -quit)"
    fi
    if [[ -z "$fragment" ]] && ! as_root test -e "$config" && ! as_root test -L "$config" &&
       ! systemctl is-active --quiet amazon-cloudwatch-agent; then
        (
            as_root mkdir -p -- "$config_dir"
            tmp="$(as_root mktemp "$config_dir/.ec2-bootstrap.XXXXXX")"
            trap 'as_root rm -f -- "$tmp"' EXIT
            as_root tee "$tmp" >/dev/null <<'EOF'
{
  "agent": {
    "metrics_collection_interval": 60
  },
  "metrics": {
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}",
      "InstanceType": "${aws:InstanceType}"
    },
    "metrics_collected": {
      "mem": {
        "measurement": ["mem_used_percent"]
      },
      "disk": {
        "measurement": ["used_percent"],
        "resources": ["/"],
        "ignore_file_system_types": [
          "sysfs", "devtmpfs", "tmpfs", "overlay", "squashfs"
        ]
      },
      "swap": {
        "measurement": ["swap_used_percent"]
      }
    }
  }
}
EOF
            as_root chmod 0644 "$tmp"
            as_root ln -T -- "$tmp" "$config" || as_root test -f "$config"
        )
    fi
    # The packaged systemd service reads the primary JSON and saved fragments
    # at startup. fetch-config would replace those inputs and restart the agent.
    run_logged 'Enabling and starting CloudWatch Agent' \
        as_root systemctl enable --now amazon-cloudwatch-agent
    success "CloudWatch Agent service: $(systemctl is-active amazon-cloudwatch-agent)"
    warn 'Publishing metrics requires an EC2 IAM role with CloudWatchAgentServerPolicy-equivalent permissions.'
}

verify_installation() {
    step 'Verifying installation'

    local failed=false
    git --version >/dev/null || failed=true
    if [[ "$INSTALL_GO" == true ]]; then
        GOTOOLCHAIN=local /usr/local/go/bin/go version >/dev/null || failed=true
    fi
    if [[ "$INSTALL_TMUX" == true ]]; then
        /usr/local/bin/tmux -V >/dev/null || failed=true
        [[ -e "$TARGET_HOME/.tmux.conf" || -L "$TARGET_HOME/.tmux.conf" ]] || failed=true
    fi

    if [[ "$INSTALL_VIM" == true ]]; then
        /usr/local/bin/vim --version >/dev/null || failed=true
    fi
    if [[ "$INSTALL_SSM" == true ]]; then
        as_root systemctl is-active --quiet "$SSM_SERVICE" || failed=true
    fi
    if [[ "$INSTALL_CLOUDWATCH" == true ]]; then
        as_root systemctl is-active --quiet amazon-cloudwatch-agent || failed=true
    fi

    [[ "$failed" == false ]] || {
        fail 'One or more verification checks failed.'
        return 1
    }

    success 'All requested components passed basic verification.'
}

print_manual_guides() {
    cat <<'EOF'

=========================================
Manual EBS disk setup (NOT executed)
=========================================
WARNING: Confirm the correct empty device before running mkfs. A wrong device
selection destroys data. EC2 NVMe names may not match the console's /dev/sdX.

1. Inspect disks and filesystems:

   lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
   sudo blkid

2. Example only, after confirming /dev/nvme1n1 is the NEW EMPTY volume:

   sudo mkfs.xfs /dev/nvme1n1
   sudo mkdir -p /data
   UUID=$(sudo blkid -s UUID -o value /dev/nvme1n1)
   echo "UUID=$UUID /data xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
   sudo systemctl daemon-reload
   sudo mount -a
   findmnt /data

AWS reference:
https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-using-volumes.html
EOF
}

print_summary() {
    printf '\n=========================================\n'
    printf 'EC2 Bootstrap Complete\n'
    printf '=========================================\n'
    printf 'Target user : %s\n' "$TARGET_USER"
    printf 'Temporary downloads: %s (removed on exit)\n' "$DOWNLOAD_DIR"
    printf 'Log         : %s\n' "$LOG_FILE"
    printf 'Git         : %s\n' "$(git --version)"
    printf 'Bash aliases: ls, ll, l (system-wide defaults; user aliases take precedence)\n'
    printf 'To load these aliases in an existing Bash shell, run: source /etc/bash.bashrc\n'
    [[ -z "$TARGET_HOSTNAME" ]] || printf 'Hostname    : %s\n' "$(hostnamectl --static)"
    [[ "$INSTALL_GO" != true ]] || printf 'Go          : %s\n' "$(GOTOOLCHAIN=local /usr/local/go/bin/go version)"
    [[ "$INSTALL_TMUX" != true ]] || printf 'tmux        : %s\n' "$(/usr/local/bin/tmux -V)"
    [[ "$INSTALL_VIM" != true ]] || printf 'Vim         : %s\n' "$(/usr/local/bin/vim --version | sed -n '1p')"
    [[ "$INSTALL_SSM" != true ]] || printf 'SSM Agent   : %s\n' "$(systemctl is-active "$SSM_SERVICE")"
    [[ "$INSTALL_CLOUDWATCH" != true ]] || printf 'CloudWatch  : %s\n' "$(systemctl is-active amazon-cloudwatch-agent)"

    if [[ "$INSTALL_GO" == true ]]; then
        printf 'In an existing Bash shell, run hash -r, then GOTOOLCHAIN=local go version to confirm.\n'
    fi
}

main() {
    parse_args "$@"
    validate_inputs
    check_platform
    require_privilege
    select_target_user
    if [[ "$INSTALL_SSM" == true ]]; then
        detect_ssm_installation
    fi
    prepare_workspace
    calculate_steps

    printf '=========================================\n'
    printf 'Ubuntu EC2 Bootstrap\n'
    printf '=========================================\n'
    info "Operating system: $PRETTY_NAME"
    info "Target user: $TARGET_USER"
    info "Architecture: $DEB_ARCH"
    info "Log file: $LOG_FILE"

    update_apt
    install_base_packages
    configure_locale
    configure_bash_aliases
    configure_hostname
    [[ "$INSTALL_GO" != true ]] || install_go
    if [[ "$INSTALL_TMUX" == true ]]; then
        install_tmux
        write_tmux_config
    fi
    [[ "$INSTALL_VIM" != true ]] || install_vim
    [[ "$INSTALL_SSM" != true ]] || install_ssm
    [[ "$INSTALL_CLOUDWATCH" != true ]] || install_cloudwatch
    verify_installation

    print_summary
    print_manual_guides
}

main "$@"
