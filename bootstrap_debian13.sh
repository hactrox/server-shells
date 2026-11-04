#!/usr/bin/env bash
# Debian 13 (trixie) AWS EC2 bootstrap script.
#
# BASE INSTALLATION — always executed:
#   - APT prerequisites
#   - en_US.UTF-8 locale
#   - Git from Debian APT
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
#   --ssm         Install, enable, and start Amazon SSM Agent
#   --cloudwatch  Install, configure, enable, and start CloudWatch Agent
#   --mysql       Install Oracle MySQL from the official MySQL APT repository
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
# Destructive disk operations and MySQL data-directory migration are NEVER
# performed automatically. Safe manual instructions are printed at the end.

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
readonly MYSQL_APT_CONFIG_VERSION="0.8.36-1"

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
INSTALL_MYSQL=false
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

usage() {
    cat <<'EOF'
Usage:
  sudo ./debian13-ec2-bootstrap.sh [options]

Base setup always installs APT prerequisites, en_US.UTF-8 locale and Git.
Go, tmux, Vim, MySQL, SSM Agent and CloudWatch Agent are optional.
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
  --mysql               Install Oracle MySQL using the official MySQL APT repo.
  --ssm                 Install and enable Amazon SSM Agent.
  --cloudwatch          Install, configure and enable Amazon CloudWatch Agent.
  --ec2                 Enable --upgrade, --go, --tmux, --ssm and --cloudwatch.
                        Other components still require explicit flags.
  --upgrade             Run apt-get upgrade before installing packages.
  -h, --help            Show this help.

Examples:
  sudo ./debian13-ec2-bootstrap.sh --ec2
  sudo ./debian13-ec2-bootstrap.sh --ec2 --vim
  sudo ./debian13-ec2-bootstrap.sh --ec2 --vim --hostname xxx
  sudo ./debian13-ec2-bootstrap.sh --hostname xxx
  sudo ./debian13-ec2-bootstrap.sh --hostname xxx --go --tmux

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
            --mysql)
                INSTALL_MYSQL=true
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
    if [[ -n "${SUDO_USER:-}" ]]; then
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

    if [[ "${ID:-}" != debian || "${VERSION_ID:-}" != 13* ]]; then
        fail "This script requires Debian 13; detected ${PRETTY_NAME:-unknown}."
        exit 1
    fi

    DEB_ARCH="$(dpkg --print-architecture)"
    case "$DEB_ARCH" in
        amd64) GO_ARCH="amd64" ;;
        arm64) GO_ARCH="arm64" ;;
        *)
            fail "Unsupported architecture: $DEB_ARCH (supported: amd64, arm64)"
            exit 1
            ;;
    esac
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
    # Base: APT index, packages, locale, hostname/cloud-init and verification.
    TOTAL_STEPS=5
    [[ "$INSTALL_GO" == true ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    # tmux installation and tmux configuration are separate steps.
    [[ "$INSTALL_TMUX" == true ]] && TOTAL_STEPS=$((TOTAL_STEPS + 2))
    [[ "$INSTALL_VIM" == true ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
    [[ "$INSTALL_MYSQL" == true ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
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
        run_logged 'Upgrading installed packages' apt_env apt-get upgrade -y
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
        packages+=(autoconf automake libtool libacl1-dev libgpm-dev python3-dev)
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
        local archive="$DOWNLOAD_DIR/$filename"
        local expected actual
        expected="$(resolve_go_checksum "$filename")"

        if [[ -f "$archive" ]]; then
            actual="$(sha256sum "$archive" | awk '{print $1}')"
            if [[ "$actual" == "$expected" ]]; then
                success "Reusing verified $archive."
            else
                warn 'Existing Go archive checksum is wrong; downloading it again.'
                rm -f "$archive"
            fi
        fi

        if [[ ! -f "$archive" ]]; then
            run_logged "Downloading $filename from go.dev" \
                as_user curl -fL --retry 4 --retry-all-errors \
                -o "$archive.part" "https://go.dev/dl/$filename"
            as_user mv "$archive.part" "$archive"
        fi

        actual="$(sha256sum "$archive" | awk '{print $1}')"
        [[ "$actual" == "$expected" ]] || {
            fail "Go checksum mismatch: expected $expected, got $actual"
            return 1
        }
        success 'Go archive checksum verified.'

        local staging_dir
        staging_dir="$(as_user mktemp -d "$DOWNLOAD_DIR/go.XXXXXX")"
        run_logged 'Extracting Go into a temporary directory' \
            as_user tar -C "$staging_dir" -xzf "$archive"
        [[ "$(GOTOOLCHAIN=local "$staging_dir/go/bin/go" version | awk '{print $3}')" == "$desired" ]] || {
            fail "Downloaded Go version does not match $GO_VERSION."
            return 1
        }

        as_root install -d -m 0755 /usr/local
        run_logged 'Replacing /usr/local/go' as_root rm -rf /usr/local/go
        run_logged 'Installing verified Go' \
            as_root cp -a --no-preserve=ownership "$staging_dir/go" /usr/local/go
    fi

    # Reuse the current PATH or an existing literal PATH assignment.
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
    if [[ "$go_on_path" == true ]]; then
        info 'Go is already on PATH; keeping the existing configuration.'
    elif grep -Eq "$go_path_pattern" /etc/profile; then
        info '/etc/profile already configures the Go path.'
    else
        printf '\n%s\n' 'export PATH="/usr/local/go/bin:$PATH"' | \
            as_root tee -a /etc/profile >/dev/null
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
    printf '%s\n' "$commit"
}

install_tmux() {
    step "Installing tmux $TMUX_VERSION from its official release archive"

    local expected="tmux $TMUX_VERSION"
    local current=""
    if [[ -x /usr/local/bin/tmux ]]; then
        current="$(/usr/local/bin/tmux -V 2>/dev/null || true)"
    fi

    if [[ "$current" == "$expected" ]]; then
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

    run_logged 'Installing tmux' \
        as_root make -C "$source_dir" install

    hash -r
    local installed
    installed="$(/usr/local/bin/tmux -V 2>/dev/null || true)"
    [[ "$installed" == "$expected" ]] || {
        fail "tmux verification failed: expected '$expected', got '$installed'"
        return 1
    }
    success "$installed"
}

find_tmux_config() {
    local config_path
    local config_paths=("$TARGET_HOME/.tmux.conf" "$TARGET_HOME/.config/tmux/tmux.conf")
    if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
        config_paths+=("$XDG_CONFIG_HOME/tmux/tmux.conf")
    fi
    for config_path in "${config_paths[@]}"; do
        if [[ -e "$config_path" || -L "$config_path" ]]; then
            printf '%s\n' "$config_path"
            return 0
        fi
    done
    return 1
}

write_tmux_config() {
    step 'Checking tmux configuration'

    local target
    if target="$(find_tmux_config)"; then
        info "Keeping existing $target."
        return
    fi
    target="$TARGET_HOME/.tmux.conf"

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

install_vim() {
    step "Installing Vim from official source ref '$VIM_REF'"

    (
        local work_dir cleanup
        work_dir="$(as_user mktemp -d /tmp/vim-bootstrap.XXXXXX)"
        # Capture the path before an ERR handler can unwind local variables.
        printf -v cleanup 'as_root rm -rf -- %q' "$work_dir"
        trap "$cleanup" EXIT

        local repo_dir="$work_dir/vim"
        local commit
        commit="$(checkout_repo_ref 'https://github.com/vim/vim.git' "$repo_dir" "$VIM_REF" | tail -n 1)"
        local marker='/usr/local/share/ec2-bootstrap/vim-commit'

        if [[ -x /usr/local/bin/vim && -f "$marker" ]] &&
           [[ "$(cat "$marker")" == "$commit" ]]; then
            success "Vim source commit $commit is already installed."
        else
            run_logged 'Configuring Vim' \
                as_user bash -lc "cd '$repo_dir' && ./configure \
                    --prefix=/usr/local \
                    --with-features=huge \
                    --enable-multibyte \
                    --enable-python3interp=dynamic \
                    --enable-terminal \
                    --disable-gui \
                    --without-x"
            run_logged 'Compiling Vim' \
                as_user bash -lc "cd '$repo_dir' && make -j'$(nproc)'"
            run_logged 'Installing Vim' \
                as_root make -C "$repo_dir" install
            as_root install -d -m 0755 /usr/local/share/ec2-bootstrap
            printf '%s\n' "$commit" | as_root tee "$marker" >/dev/null
            as_root chmod 0644 "$marker"
        fi
    )

    local vimrc="$TARGET_HOME/.vimrc"
    if [[ -e "$vimrc" || -L "$vimrc" ]]; then
        info "Keeping existing $vimrc."
    else
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
    fi

    hash -r
    success "$(/usr/local/bin/vim --version | head -n 1)"
}

install_mysql() {
    step 'Installing Oracle MySQL from the official APT repository'

    if dpkg-query -W -f='${Status}' mysql-community-server 2>/dev/null | grep -q 'install ok installed' ||
       dpkg-query -W -f='${Status}' mysql-server 2>/dev/null | grep -q 'install ok installed'; then
        success "MySQL server package is already installed: $(mysql --version 2>/dev/null || true)"
    else
        local filename="mysql-apt-config_${MYSQL_APT_CONFIG_VERSION}_all.deb"
        local package_file="$DOWNLOAD_DIR/$filename"
        local url="https://repo.mysql.com/$filename"

        if [[ ! -s "$package_file" ]]; then
            run_logged "Downloading $filename" \
                as_user curl -fL --retry 4 --retry-all-errors -o "$package_file.part" "$url"
            as_user mv "$package_file.part" "$package_file"
        else
            success "Reusing $package_file."
        fi

        # The official package's default selection is used non-interactively.
        # It can later be changed with: sudo dpkg-reconfigure mysql-apt-config
        run_logged 'Installing MySQL APT repository configuration' \
            apt_env apt-get install -y "$package_file"
        run_logged 'Updating APT index for MySQL repository' apt_env apt-get update
        run_logged 'Installing mysql-server' apt_env apt-get install -y mysql-server
    fi

    run_logged 'Enabling MySQL service' as_root systemctl enable --now mysql
    success "$(mysql --version)"
    warn 'MySQL data directory was NOT moved. Review the manual section printed below.'
}

install_ssm() {
    step 'Installing Amazon SSM Agent'

    if dpkg-query -W -f='${Status}' amazon-ssm-agent 2>/dev/null | grep -q 'install ok installed'; then
        success 'amazon-ssm-agent package is already installed.'
    else
        local aws_arch
        case "$DEB_ARCH" in
            amd64) aws_arch='debian_amd64' ;;
            arm64) aws_arch='debian_arm64' ;;
        esac
        local package_file="$DOWNLOAD_DIR/amazon-ssm-agent-${DEB_ARCH}.deb"
        local url="https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/${aws_arch}/amazon-ssm-agent.deb"

        run_logged 'Downloading the latest SSM Agent package' \
            as_user curl -fL --retry 4 --retry-all-errors -o "$package_file.part" "$url"
        as_user mv "$package_file.part" "$package_file"
        run_logged 'Installing SSM Agent' apt_env apt-get install -y "$package_file"
    fi

    run_logged 'Enabling SSM Agent' as_root systemctl enable --now amazon-ssm-agent
    success "SSM Agent service: $(systemctl is-active amazon-ssm-agent)"
}

install_cloudwatch() {
    step 'Installing and configuring Amazon CloudWatch Agent'

    if dpkg-query -W -f='${Status}' amazon-cloudwatch-agent 2>/dev/null | grep -q 'install ok installed'; then
        success 'amazon-cloudwatch-agent package is already installed.'
    else
        local package_file="$DOWNLOAD_DIR/amazon-cloudwatch-agent-${DEB_ARCH}.deb"
        local url="https://s3.amazonaws.com/amazoncloudwatch-agent/debian/${DEB_ARCH}/latest/amazon-cloudwatch-agent.deb"

        run_logged 'Downloading the latest CloudWatch Agent package' \
            as_user curl -fL --retry 4 --retry-all-errors -o "$package_file.part" "$url"
        as_user mv "$package_file.part" "$package_file"
        run_logged 'Installing CloudWatch Agent' apt_env apt-get install -y "$package_file"
    fi

    local config='/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json'
    as_root install -d -m 0755 "$(dirname "$config")"
    cat <<'EOF' | as_root tee "$config" >/dev/null
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
    as_root chmod 0644 "$config"

    run_logged 'Applying CloudWatch Agent configuration' \
        as_root /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
        -a fetch-config -m ec2 -s -c "file:$config"
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
        find_tmux_config >/dev/null || failed=true
    fi

    if [[ "$INSTALL_VIM" == true ]]; then
        /usr/local/bin/vim --version >/dev/null || failed=true
    fi
    if [[ "$INSTALL_MYSQL" == true ]]; then
        as_root systemctl is-active --quiet mysql || failed=true
    fi
    if [[ "$INSTALL_SSM" == true ]]; then
        as_root systemctl is-active --quiet amazon-ssm-agent || failed=true
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

    if [[ "$INSTALL_MYSQL" == true ]]; then
        cat <<'EOF'

=========================================
Manual MySQL data-directory migration
=========================================
The script intentionally leaves MySQL at /var/lib/mysql. Before moving it:

- create and mount /data persistently;
- back up the database and test restoration;
- stop MySQL cleanly;
- copy with rsync while preserving ownership/permissions;
- update mysqld's datadir and AppArmor rules for the exact installed version;
- validate with mysqld configuration checks before restarting.

Do not blindly reuse an Ubuntu-specific AppArmor recipe on Debian 13.
EOF
    fi
}

print_summary() {
    printf '\n=========================================\n'
    printf 'EC2 Bootstrap Complete\n'
    printf '=========================================\n'
    printf 'Target user : %s\n' "$TARGET_USER"
    printf 'Temporary downloads: %s (removed on exit)\n' "$DOWNLOAD_DIR"
    printf 'Log         : %s\n' "$LOG_FILE"
    printf 'Git         : %s\n' "$(git --version)"
    [[ -z "$TARGET_HOSTNAME" ]] || printf 'Hostname    : %s\n' "$(hostnamectl --static)"
    [[ "$INSTALL_GO" != true ]] || printf 'Go          : %s\n' "$(GOTOOLCHAIN=local /usr/local/go/bin/go version)"
    [[ "$INSTALL_TMUX" != true ]] || printf 'tmux        : %s\n' "$(/usr/local/bin/tmux -V)"
    [[ "$INSTALL_VIM" != true ]] || printf 'Vim         : %s\n' "$(/usr/local/bin/vim --version | head -n 1)"
    [[ "$INSTALL_MYSQL" != true ]] || printf 'MySQL       : %s\n' "$(mysql --version)"
    [[ "$INSTALL_SSM" != true ]] || printf 'SSM Agent   : %s\n' "$(systemctl is-active amazon-ssm-agent)"
    [[ "$INSTALL_CLOUDWATCH" != true ]] || printf 'CloudWatch  : %s\n' "$(systemctl is-active amazon-cloudwatch-agent)"

    if [[ "$INSTALL_GO" == true ]]; then
        printf 'In an existing Bash shell, run hash -r, then GOTOOLCHAIN=local go version to confirm.\n'
    fi
}

main() {
    parse_args "$@"
    require_privilege
    select_target_user
    prepare_workspace
    check_platform
    validate_inputs
    calculate_steps

    printf '=========================================\n'
    printf 'Debian 13 EC2 Bootstrap\n'
    printf '=========================================\n'
    info "Target user: $TARGET_USER"
    info "Architecture: $DEB_ARCH"
    info "Log file: $LOG_FILE"

    update_apt
    install_base_packages
    configure_locale
    configure_hostname
    [[ "$INSTALL_GO" != true ]] || install_go
    if [[ "$INSTALL_TMUX" == true ]]; then
        install_tmux
        write_tmux_config
    fi
    [[ "$INSTALL_VIM" != true ]] || install_vim
    [[ "$INSTALL_MYSQL" != true ]] || install_mysql
    [[ "$INSTALL_SSM" != true ]] || install_ssm
    [[ "$INSTALL_CLOUDWATCH" != true ]] || install_cloudwatch
    verify_installation

    print_summary
    print_manual_guides
}

main "$@"
