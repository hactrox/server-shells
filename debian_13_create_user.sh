#!/bin/bash

set -euo pipefail

# Note: If ERROR: sshd_config syntax check failed,
# Make sure uncomment the following items:
# PermitRootLogin
# PubkeyAuthentication
# PasswordAuthentication
# KbdInteractiveAuthentication

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

if ! echo "$SSH_KEY" | grep -q "^ssh-ed25519 "; then
    echo "ERROR: Only ssh-ed25519 public keys are allowed."
    exit 1
fi

echo "Checking SSH server configuration..."

if ! sshd -t; then
    echo "ERROR: sshd_config syntax check failed."
    exit 1
fi

SSHD_EFFECTIVE_CONFIG="$(sshd -T)"

if ! echo "$SSHD_EFFECTIVE_CONFIG" | grep -q "^pubkeyauthentication yes$"; then
    echo "ERROR: PubkeyAuthentication is not enabled."
    echo "Please set: PubkeyAuthentication yes"
    exit 1
fi

if ! echo "$SSHD_EFFECTIVE_CONFIG" | grep -q "^passwordauthentication no$"; then
    echo "ERROR: PasswordAuthentication is not disabled."
    echo "Please set: PasswordAuthentication no"
    exit 1
fi

if ! echo "$SSHD_EFFECTIVE_CONFIG" | grep -q "^kbdinteractiveauthentication no$"; then
    echo "ERROR: KbdInteractiveAuthentication is not disabled."
    echo "Please set: KbdInteractiveAuthentication no"
    exit 1
fi

if id "$USERNAME" >/dev/null 2>&1; then
    echo "ERROR: User '$USERNAME' already exists."
    exit 1
fi

echo "Creating user: $USERNAME"

adduser --disabled-password --gecos "" "$USERNAME"

HOME_DIR="/home/$USERNAME"
SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
echo "$SSH_KEY" > "$AUTH_KEYS"

chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"

echo "Checking sudo permission..."

if groups "$USERNAME" | grep -qw "sudo"; then
    echo "ERROR: User '$USERNAME' is in sudo group."
    echo "Removing from sudo group..."
    deluser "$USERNAME" sudo
fi

if sudo -l -U "$USERNAME" 2>/dev/null | grep -q "(ALL"; then
    echo "ERROR: User '$USERNAME' appears to have sudo privileges."
    exit 1
fi

echo
echo "User created successfully."
echo
echo "Username                 : $USERNAME"
echo "Home                     : $HOME_DIR"
echo "SSH key                  : installed"
echo "PasswordAuthentication   : disabled"
echo "PubkeyAuthentication     : enabled"
echo "KbdInteractiveAuth       : disabled"
echo "Sudo permission          : not granted"
