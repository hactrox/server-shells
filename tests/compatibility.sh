#!/usr/bin/env bash
# Run explicitly with bash tests/compatibility.sh [debian:13|ubuntu:24.04|ubuntu:26.04].
# Each sequence installs real releases in a fresh, disposable container.
set -euo pipefail

images=(debian:13 ubuntu:24.04 ubuntu:26.04)
if (($# > 1)); then
    echo "Usage: bash $0 [debian:13|ubuntu:24.04|ubuntu:26.04]" >&2
    exit 2
elif (($# == 1)); then
    case "$1" in
        debian:13|ubuntu:24.04|ubuntu:26.04) images=("$1") ;;
        *) echo "Unsupported test image: $1" >&2; exit 2 ;;
    esac
fi
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_sequence() {
    local image="$1" first="$2" bootstrap="$3"
    docker run --rm -i --cpus=1 --memory=4g --memory-swap=4g --pids-limit=512 \
        --mount "type=bind,source=$repo,target=/repo,readonly" \
        "$image" bash -s -- "$first" "$bootstrap" <<'CONTAINER'
set -Eeuo pipefail
trap 'echo "Compatibility test failed at line $LINENO: $BASH_COMMAND" >&2' ERR
# Return only the generated defaults' checksums to the host for comparison.
exec 3>&1 >&2
first="$1" bootstrap="$2"
export DEBIAN_FRONTEND=noninteractive
apt-get update </dev/null
apt-get install -y --no-install-recommends sudo </dev/null
useradd -m -U -s /bin/bash compat
printf 'compat ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/compat
chmod 0440 /etc/sudoers.d/compat
target_home=/home/compat
xdg_config_home="$target_home/custom-config"
other_configs=(
    "$target_home/.vim/vimrc"
    "$target_home/.config/tmux/tmux.conf"
    "$xdg_config_home/vim/vimrc"
    "$xdg_config_home/tmux/tmux.conf"
)
for config in "${other_configs[@]}"; do
    runuser -u compat -- mkdir -p "$(dirname "$config")"
    runuser -u compat -- sh -c 'printf "Existing configuration\n" > "$1"' sh "$config"
done
sha256sum "${other_configs[@]}" > /tmp/compat-checksums

run_entry() {
    local entry="$1" mode="$2" tool
    local -a caller=(runuser -u compat --)
    if [[ "$mode" == sudo ]]; then
        caller+=(sudo -n -H env DEBIAN_FRONTEND=noninteractive XDG_CONFIG_HOME="$xdg_config_home")
    else
        # A shell entered via sudo -iu compat can retain SUDO_USER=root.
        caller+=(env SUDO_USER=root XDG_CONFIG_HOME="$xdg_config_home")
    fi
    if [[ "$entry" == A ]]; then
        "${caller[@]}" bash "/repo/$bootstrap" --go --tmux --vim </dev/null
    else
        for tool in go tmux vim; do
            "${caller[@]}" bash "/repo/install_update_${tool}.sh" </dev/null
        done
    fi
}

binary_state() {
    # Detect replacement and in-place reinstallation, even with identical bytes.
    stat -c '%n %i %s %z' /usr/local/go/bin/go /usr/local/bin/{tmux,vim}
}

smoke_test() {
    runuser -u compat -- bash -s -- "$tmuxrc" "$vimrc" <<'SMOKE'
set -euo pipefail
smoke_dir="$(mktemp -d)"
tmux_socket="$smoke_dir/tmux.sock"
cleanup_smoke() {
    /usr/local/bin/tmux -S "$tmux_socket" kill-server </dev/null >/dev/null 2>&1 || true
    rm -rf -- "$smoke_dir"
}
trap cleanup_smoke EXIT

cat > "$smoke_dir/main.go" <<'GO'
package main

import "fmt"

func main() {
    fmt.Println("compatibility-ok")
}
GO
GOTOOLCHAIN=local GOWORK=off /usr/local/go/bin/go build \
    -o "$smoke_dir/hello" "$smoke_dir/main.go" </dev/null
[[ "$("$smoke_dir/hello" </dev/null)" == compatibility-ok ]]

/usr/local/bin/tmux -S "$tmux_socket" -f "$1" new-session -d -s smoke 'sleep 60' </dev/null
/usr/local/bin/tmux -S "$tmux_socket" source-file "$1" </dev/null
/usr/local/bin/tmux -S "$tmux_socket" has-session -t smoke </dev/null
[[ "$(/usr/local/bin/tmux -S "$tmux_socket" show-options -gv mouse </dev/null)" == on ]]

cat > "$smoke_dir/check.vim" <<'VIM'
try
    python3 import sys; assert sys.version_info.major == 3
    if !&number || !has('terminal')
        cquit 1
    endif
catch
    echomsg v:exception
    cquit 1
endtry
qa!
VIM
if ! /usr/local/bin/vim -N -u "$2" -i NONE -n -es \
    -V1"$smoke_dir/vim.log" -S "$smoke_dir/check.vim" </dev/null; then
    cat "$smoke_dir/vim.log" >&2
    exit 1
fi
echo 'Go, tmux and Vim functional checks passed.'
SMOKE
}

run_entry "$first" sudo
sha256sum --check /tmp/compat-checksums
for config in "$target_home/.tmux.conf" "$target_home/.vimrc"; do
    [[ -s "$config" && "$(stat -c '%U:%G' "$config")" == compat:compat ]]
done
sha256sum "$target_home/.tmux.conf" "$target_home/.vimrc" >&3
binaries="$(binary_state)"
tmuxrc="$target_home/.tmux.conf"
vimrc="$target_home/.vimrc"
smoke_test
other=B
if [[ "$first" == B ]]; then
    other=A
fi
printf '# Custom tmux setting\n' >> "$tmuxrc"
printf '" Custom Vim setting\n' >> "$vimrc"
sha256sum /etc/profile "$tmuxrc" "$vimrc" >> /tmp/compat-checksums

# AAB covers AA and AB. BBA starts independently and covers BB and BA.
for next in "$first" "$other"; do
    echo "Testing $first -> $next"
    if [[ "$next" == "$first" ]]; then
        run_entry "$next" user
    else
        run_entry "$next" sudo
    fi
    [[ "$(binary_state)" == "$binaries" ]]
    sha256sum --check /tmp/compat-checksums
    [[ ! -e /root/.tmux.conf && ! -e /root/.vimrc ]]
    runuser -u compat -- bash -lc '
        test "$(command -v go)" = /usr/local/go/bin/go &&
        test "$(tr : "\n" <<< "$PATH" | grep -cx /usr/local/go/bin)" = 1
    '
    smoke_test
done
CONTAINER
}

for image in "${images[@]}"; do
    case "$image" in
        debian:13) bootstrap=bootstrap_debian13.sh ;;
        ubuntu:*) bootstrap=bootstrap_ubuntu.sh ;;
    esac
    echo "Testing $image, bootstrap first"
    a_defaults="$(run_sequence "$image" A "$bootstrap")"
    echo "Testing $image, standalone first"
    b_defaults="$(run_sequence "$image" B "$bootstrap")"
    if [[ "$a_defaults" != "$b_defaults" ]]; then
        echo "Generated tmux or Vim defaults differ by entry point on $image." >&2
        exit 1
    fi
    echo "Passed AA, AB, BB and BA on $image."
done
