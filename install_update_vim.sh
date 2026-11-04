#!/usr/bin/env bash

# Debian 13: install or update Vim with `bash vim_install_update.sh`.
# Edit VIM_VERSION below to select the exact version; skip installation
# when that version is already installed.
# Create a default ~/.vimrc for the invoking user only when it is missing.
set -Eeuo pipefail
VIM_VERSION="9.2.1252"

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
    error "Vim setup failed (exit $status). See the command output above."
    exit "$status"
}
trap 'on_error "$?"' ERR

[[ "$VIM_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || {
    error "Invalid Vim version: $VIM_VERSION"
    exit 1
}
version_long=$((10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 10000 + 10#${BASH_REMATCH[3]}))

# Check the full patch level without loading vimrc/plugins or writing viminfo.
vim_is_target_version() {
    "$1" -N -u NONE -i NONE -n -es \
        -c "if v:versionlong != $version_long | cquit 1 | endif" \
        -c 'qa!'
}

report_vim_on_path() {
    local vim_path
    # Check this script's PATH, independently of its command cache.
    hash -r
    vim_path="$(type -P vim || true)"
    if [[ -n "$vim_path" ]] && vim_is_target_version "$vim_path"; then
        success "Vim on PATH in this script matches $VIM_VERSION: $vim_path"
    else
        if [[ -z "$vim_path" ]]; then
            warn 'vim was not found on PATH in this script.'
        else
            warn "Vim on PATH in this script ($vim_path) did not pass the version check for $VIM_VERSION."
        fi
        warn 'Put /usr/local/bin before other Vim directories in PATH, or run /usr/local/bin/vim directly.'
    fi
    info 'This checks the script environment only; your shell may have a different PATH, aliases, functions or cached paths.'
    info 'In your existing Bash shell, run hash -r, then type -a vim and vim --version to confirm.'
}

ensure_vimrc() (
    # Keep temporary-file cleanup and user variables local to this subshell.
    target_user="${SUDO_USER:-$(id -un)}"
    target_home="$(getent passwd "$target_user" | cut -d: -f6)" || {
        error "Cannot find the home directory for $target_user."
        exit 1
    }
    [[ "$target_home" == /* && -d "$target_home" ]] || {
        error "Target home directory is unavailable: $target_home"
        exit 1
    }
    vimrc="$target_home/.vimrc"
    if [[ -e "$vimrc" || -L "$vimrc" ]]; then
        info "Keeping existing $vimrc."
        exit 0
    fi

    target_uid="$(id -u "$target_user")"
    target_gid="$(id -g "$target_user")"
    tmp="$(mktemp /tmp/vimrc.XXXXXX)"
    trap 'rm -f -- "$tmp"' EXIT
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

    if ((EUID == 0)); then
        install -m 0644 -o "$target_uid" -g "$target_gid" "$tmp" "$vimrc"
    elif [[ "$(id -u)" == "$target_uid" ]]; then
        install -m 0644 -g "$target_gid" "$tmp" "$vimrc"
    else
        sudo install -m 0644 -o "$target_uid" -g "$target_gid" "$tmp" "$vimrc"
    fi
    success "Created $vimrc."
)

if [[ -x /usr/local/bin/vim ]] && vim_is_target_version /usr/local/bin/vim; then
    success "Vim $VIM_VERSION is already installed."
    ensure_vimrc
    report_vim_on_path
    exit 0
fi

sudo_cmd=()
if ((EUID != 0)); then
    sudo_cmd=(sudo)
fi
"${sudo_cmd[@]}" apt-get update
"${sudo_cmd[@]}" apt-get install -y --no-install-recommends \
    ca-certificates curl tar gzip build-essential pkg-config libtool-bin \
    libncurses-dev libacl1-dev libgpm-dev python3-dev

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT
curl -fL --retry 3 --retry-delay 2 \
    -o "$work_dir/vim.tar.gz" \
    "https://github.com/vim/vim/archive/refs/tags/v${VIM_VERSION}.tar.gz"
mkdir "$work_dir/src"
tar -C "$work_dir/src" --strip-components=1 -xzf "$work_dir/vim.tar.gz"
cd "$work_dir/src"

./configure \
    --prefix=/usr/local \
    --with-features=huge \
    --enable-multibyte \
    --enable-python3interp=dynamic \
    --enable-terminal \
    --disable-gui \
    --without-x
make -j"$(nproc)"

vim_is_target_version ./src/vim || {
    error "Built Vim version does not match $VIM_VERSION."
    exit 1
}
build_info="$(./src/vim --version)"
[[ "$build_info" == *'+python3/dyn'* && "$build_info" == *'+terminal'* ]] || {
    error 'Built Vim is missing Python 3 dynamic or terminal support.'
    exit 1
}

# Install the program/runtime only; keep existing vimrc and plugins.
"${sudo_cmd[@]}" make install
vim_is_target_version /usr/local/bin/vim || {
    error "Installed Vim version does not match $VIM_VERSION."
    exit 1
}
success "Installed Vim $VIM_VERSION: /usr/local/bin/vim."
ensure_vimrc
report_vim_on_path
