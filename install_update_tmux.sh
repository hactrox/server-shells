#!/usr/bin/env bash

# Install or update tmux with `bash install_update_tmux.sh`.
# Edit TMUX_VERSION below to select the exact version; skip installation
# when that version is already installed.
# Create a default ~/.tmux.conf only when the file is missing.
set -Eeuo pipefail
umask 022
TMUX_VERSION="3.8"

log_message() {
    local level="$1" color="$2" symbol="$3"
    shift 3
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
        printf '\033[%sm%s [%s] %s\033[0m\n' "$color" "$symbol" "$level" "$*"
    else
        printf '%s [%s] %s\n' "$symbol" "$level" "$*"
    fi
}

info()    { log_message INFO 36 '•' "$@"; }
success() { log_message OK 32 '✓' "$@"; }
warn()    { log_message WARN '1;33' '⚠' "$@" >&2; }
error()   { log_message ERROR '1;31' '✗' "$@" >&2; }

on_error() {
    local status="$1"
    trap - ERR
    error "tmux setup failed (exit $status). See the command output above."
    exit "$status"
}
trap 'on_error "$?"' ERR

[[ "$TMUX_VERSION" =~ ^[0-9]+\.[0-9]+[a-z]?$ ]] || {
    error "Invalid tmux version: $TMUX_VERSION"
    exit 1
}

tmux_is_target_version() {
    local version
    version="$("$1" -V 2>/dev/null)" || return 1
    [[ "$version" == "tmux $TMUX_VERSION" ]]
}

report_tmux_on_path() {
    local tmux_path
    # Check this script's PATH, independently of its command cache.
    hash -r
    tmux_path="$(type -P tmux || true)"
    if [[ -n "$tmux_path" ]] && tmux_is_target_version "$tmux_path"; then
        success "tmux on PATH in this script matches $TMUX_VERSION: $tmux_path"
    else
        if [[ -z "$tmux_path" ]]; then
            warn 'tmux was not found on PATH in this script.'
        else
            warn "tmux on PATH in this script ($tmux_path) did not pass the version check for $TMUX_VERSION."
        fi
        warn 'Put /usr/local/bin before other tmux directories in PATH, or run /usr/local/bin/tmux directly.'
    fi
    info 'This checks the script environment only; your shell may have a different PATH, aliases, functions or cached paths.'
    info 'In your existing Bash shell, run hash -r, then type -a tmux and tmux -V to confirm.'
    info 'Existing tmux servers keep their running version until they exit.'
}

ensure_tmux_config() (
    # Keep temporary-file cleanup and user variables local to this subshell.
    if ((EUID == 0)) && [[ -n "${SUDO_USER:-}" ]]; then
        target_user="$SUDO_USER"
    else
        target_user="$(id -un)"
    fi
    target_home="$(getent passwd "$target_user" | cut -d: -f6)" || {
        error "Cannot find the home directory for $target_user."
        exit 1
    }
    [[ "$target_home" == /* && -d "$target_home" ]] || {
        error "Target home directory is unavailable: $target_home"
        exit 1
    }
    tmux_config="$target_home/.tmux.conf"
    if [[ -e "$tmux_config" || -L "$tmux_config" ]]; then
        info "Keeping existing $tmux_config."
        exit 0
    fi

    target_uid="$(id -u "$target_user")"
    target_gid="$(id -g "$target_user")"
    tmp="$(mktemp /tmp/tmux-config.XXXXXX)"
    trap 'rm -f -- "$tmp"' EXIT
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

    if ((EUID == 0)); then
        install -m 0644 -o "$target_uid" -g "$target_gid" "$tmp" "$tmux_config"
    else
        install -m 0644 -g "$target_gid" "$tmp" "$tmux_config"
    fi
    success "Created $tmux_config."
)

pending='/usr/local/.server-shells-tmux-installing'
if [[ ! -e "$pending" && -x /usr/local/bin/tmux ]] && tmux_is_target_version /usr/local/bin/tmux; then
    success "tmux $TMUX_VERSION is already installed."
    ensure_tmux_config
    report_tmux_on_path
    exit 0
fi

sudo_cmd=()
if ((EUID != 0)); then
    sudo_cmd=(sudo)
fi
"${sudo_cmd[@]}" apt-get update
"${sudo_cmd[@]}" apt-get install -y --no-install-recommends \
    ca-certificates curl tar gzip build-essential pkg-config \
    libevent-dev libncurses-dev bison

work_dir="$(mktemp -d /tmp/tmux-install.XXXXXX)"
trap 'rm -rf -- "$work_dir"' EXIT
curl -fL --retry 3 --retry-delay 2 \
    -o "$work_dir/tmux.tar.gz" \
    "https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz"
mkdir "$work_dir/src"
tar -C "$work_dir/src" --strip-components=1 -xzf "$work_dir/tmux.tar.gz"
cd "$work_dir/src"

./configure --prefix=/usr/local
make -j"$(nproc)"

tmux_is_target_version ./tmux || {
    error "Built tmux version does not match $TMUX_VERSION."
    exit 1
}

# Keep an interrupted installation retryable, even if its binary already matches.
"${sudo_cmd[@]}" mkdir -p /usr/local
{
    flock -x 9
    "${sudo_cmd[@]}" touch "$pending"
    "${sudo_cmd[@]}" make install
    tmux_is_target_version /usr/local/bin/tmux || {
        error "Installed tmux version does not match $TMUX_VERSION."
        exit 1
    }
    "${sudo_cmd[@]}" rm -f -- "$pending"
} 9</usr/local
success "Installed tmux $TMUX_VERSION: /usr/local/bin/tmux."
ensure_tmux_config
report_tmux_on_path
