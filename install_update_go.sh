#!/usr/bin/env bash

# Debian 13: install or update Go with `bash go_install_update.sh`.
# Edit GO_VERSION below to select the exact version; skip installation
# when that version is already installed.
set -Eeuo pipefail

GO_VERSION="1.27.3"

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
    error "Go setup failed (exit $status). See the command output above."
    exit "$status"
}
trap 'on_error "$?"' ERR

[[ "$GO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    error "Invalid Go version: $GO_VERSION"
    exit 1
}

sudo_cmd=()
if ((EUID != 0)); then
    sudo_cmd=(sudo)
fi

current=""
if [[ -x /usr/local/go/bin/go ]]; then
    current="$(GOTOOLCHAIN=local /usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' || true)"
fi

if [[ "$current" == "go$GO_VERSION" ]]; then
    success "Go $GO_VERSION is already installed."
else
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        amd64|arm64) ;;
        *) error "Unsupported Go architecture: $arch"; exit 1 ;;
    esac

    "${sudo_cmd[@]}" apt-get update
    "${sudo_cmd[@]}" apt-get install -y --no-install-recommends \
        ca-certificates curl jq tar gzip

    work_dir="$(mktemp -d)"
    trap 'rm -rf -- "$work_dir"' EXIT
    archive="go${GO_VERSION}.linux-${arch}.tar.gz"

    checksum="$(curl -fsSL --retry 3 --retry-delay 2 \
        'https://go.dev/dl/?mode=json&include=all' | \
        jq -r --arg filename "$archive" \
            '[.[] | .files[] | select(.filename == $filename) | .sha256][0] // empty')"
    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || {
        error "No official SHA256 found for $archive."
        exit 1
    }

    curl -fL --retry 3 --retry-delay 2 \
        -o "$work_dir/$archive" "https://go.dev/dl/$archive"
    printf '%s  %s\n' "$checksum" "$work_dir/$archive" | sha256sum -c -

    # Extract and verify before replacing the existing installation.
    tar -C "$work_dir" -xzf "$work_dir/$archive"
    [[ "$(GOTOOLCHAIN=local "$work_dir/go/bin/go" version | awk '{print $3}')" == "go$GO_VERSION" ]] || {
        error "Downloaded Go version does not match $GO_VERSION."
        exit 1
    }
    "${sudo_cmd[@]}" install -d -m 0755 /usr/local
    "${sudo_cmd[@]}" rm -rf /usr/local/go
    "${sudo_cmd[@]}" cp -a --no-preserve=ownership "$work_dir/go" /usr/local/go
fi

# Reuse the current PATH or a common literal PATH assignment in /etc/profile.
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
    success 'Go is already on PATH; keeping the existing configuration.'
elif grep -Eq "$go_path_pattern" /etc/profile; then
    info '/etc/profile already configures the Go path.'
else
    printf '\n%s\n' 'export PATH="/usr/local/go/bin:$PATH"' | \
        "${sudo_cmd[@]}" tee -a /etc/profile >/dev/null
    success 'Added the Go path to /etc/profile.'
fi
[[ "$(GOTOOLCHAIN=local /usr/local/go/bin/go version | awk '{print $3}')" == "go$GO_VERSION" ]] || {
    error "Installed Go version does not match $GO_VERSION."
    exit 1
}
installed_version="$(GOTOOLCHAIN=local /usr/local/go/bin/go version)"
success "$installed_version"
if [[ "$go_on_path" == false ]]; then
    warn 'For the current shell, run: export PATH="/usr/local/go/bin:$PATH"'
fi
info 'Run hash -r in an existing Bash shell to refresh command lookup.'
