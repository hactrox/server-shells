#!/bin/bash

set -euo pipefail

USERNAME="${1:-}"
SSH_KEY="${2:-}"

if [[ -z "$USERNAME" || -z "$SSH_KEY" ]]; then
    echo "Usage:"
    echo "  sudo $0 <username> '<ssh-ed25519-public-key>'"
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run as root or use sudo."
    exit 1
fi

if [[ "$USERNAME" == -* ]]; then
    echo "ERROR: Invalid username."
    exit 1
fi

if [[ "$SSH_KEY" != ssh-ed25519\ * || "$SSH_KEY" == *$'\n'* || "$SSH_KEY" == *$'\r'* ]] ||
    ! KEY_INFO="$(ssh-keygen -E sha256 -lf - <<< "$SSH_KEY" 2>/dev/null)"; then
    echo "ERROR: Supply one valid ssh-ed25519 public key."
    exit 1
fi
read -r _ KEY_FINGERPRINT _ <<< "$KEY_INFO"

echo "Checking SSH server configuration..."

if ! sshd -t; then
    echo "ERROR: sshd_config syntax check failed."
    exit 1
fi

SSHD_EFFECTIVE_CONFIG="$(sshd -T)"

if ! grep -qx "pubkeyauthentication yes" <<< "$SSHD_EFFECTIVE_CONFIG"; then
    echo "ERROR: PubkeyAuthentication is not enabled."
    echo "Please set: PubkeyAuthentication yes"
    exit 1
fi

if ! grep -qx "passwordauthentication no" <<< "$SSHD_EFFECTIVE_CONFIG"; then
    echo "ERROR: PasswordAuthentication is not disabled."
    echo "Please set: PasswordAuthentication no"
    exit 1
fi

if ! grep -qx "kbdinteractiveauthentication no" <<< "$SSHD_EFFECTIVE_CONFIG"; then
    echo "ERROR: KbdInteractiveAuthentication is not disabled."
    echo "Please set: KbdInteractiveAuthentication no"
    exit 1
fi

NEW_USER=false
if ! id "$USERNAME" >/dev/null 2>&1; then
    echo "Creating user: $USERNAME"
    adduser --disabled-password --gecos "" "$USERNAME"
    NEW_USER=true
fi

HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
if [[ "$HOME_DIR" != /* || ! -d "$HOME_DIR" ]]; then
    echo "ERROR: Home directory is unavailable for '$USERNAME'."
    exit 1
fi
SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

echo "Checking sudo permission..."

USER_UID="$(id -u "$USERNAME")"
USER_GROUPS="$(id -Gn "$USERNAME")"
if [[ "$USER_UID" == 0 ]]; then
    echo "ERROR: Refusing to use a root account."
    exit 1
fi
if [[ " $USER_GROUPS " == *" sudo "* ]]; then
    if [[ "$NEW_USER" == false ]]; then
        echo "ERROR: Existing user '$USERNAME' belongs to the sudo group."
        exit 1
    fi
    deluser "$USERNAME" sudo
fi

if command -v sudo >/dev/null && sudo -n -l -U "$USERNAME" >/dev/null 2>&1; then
    echo "ERROR: User '$USERNAME' has sudo privileges."
    exit 1
fi

# Read and append as the account that owns the home. Lock the directory so
# concurrent calls also agree when authorized_keys has not been created yet.
runuser -u "$USERNAME" -- bash -s -- \
    "$SSH_DIR" "$AUTH_KEYS" "$SSH_KEY" "$KEY_FINGERPRINT" "$USERNAME" <<'EOF'
set -euo pipefail
umask 077
ssh_dir="$1" auth_keys="$2" ssh_key="$3" fingerprint="$4" username="$5"
mkdir -p -- "$ssh_dir"
exec 9<"$ssh_dir"
flock -x 9

existing_keys=""
if [[ -e "$auth_keys" || -L "$auth_keys" ]]; then
    if [[ ! -f "$auth_keys" || ! -r "$auth_keys" ]]; then
        echo "ERROR: authorized_keys must be a readable regular file." >&2
        exit 1
    fi
    # OpenSSH parses options and comments, preserving restrictions on a
    # matching key instead of adding an unrestricted duplicate.
    existing_keys="$(ssh-keygen -E sha256 -lf "$auth_keys" 2>/dev/null || true)"
    if awk -v fingerprint="$fingerprint" '$2 == fingerprint { found = 1 }
        END { exit !found }' <<< "$existing_keys"; then
        echo "Requested SSH key is already installed for '$username'."
        exit 0
    fi
fi

if [[ -n "$existing_keys" ]]; then
    echo "User '$username' already has SSH keys. Appending the new key."
fi
separator=""
if [[ -s "$auth_keys" && "$(tail -c 1 -- "$auth_keys" | wc -l)" -eq 0 ]]; then
    separator=$'\n'
fi
printf '%s%s\n' "$separator" "$ssh_key" >> "$auth_keys"
EOF

echo
echo "User and SSH key are ready."
echo
echo "Username                 : $USERNAME"
echo "Home                     : $HOME_DIR"
echo "SSH key                  : installed"
echo "PasswordAuthentication   : disabled"
echo "PubkeyAuthentication     : enabled"
echo "KbdInteractiveAuth       : disabled"
echo "Sudo permission          : not granted"
