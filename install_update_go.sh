#!/usr/bin/env bash

# Install or update Go with `bash install_update_go.sh`.
# Edit GO_VERSION below to select the exact version; skip installation
# when that version is already installed.
set -Eeuo pipefail
umask 022

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

as_root() {
    if ((EUID == 0)); then
        "$@"
    else
        sudo "$@"
    fi
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

    as_root apt-get update
    as_root apt-get install -y --no-install-recommends \
        ca-certificates curl jq tar gzip

    archive="go${GO_VERSION}.linux-${arch}.tar.gz"

    checksum="$(curl -fsSL --retry 3 --retry-delay 2 \
        'https://go.dev/dl/?mode=json&include=all' | \
        jq -r --arg filename "$archive" \
            '[.[] | .files[] | select(.filename == $filename) | .sha256][0] // empty')"
    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || {
        error "No official SHA256 found for $archive."
        exit 1
    }

    install_go_release "$archive" "$checksum"
fi

# Manage login PATH independently of this process's (possibly sudo) PATH.
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
