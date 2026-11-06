# Server Shells

Scripts for server setup, software installation, and configuration.

## Server setup

Both scripts support `amd64` / `arm64`. Base setup installs APT prerequisites and Git, configures the `en_US.UTF-8` locale, and adds global `ls`, `ll` and `l` aliases for interactive Bash. Additional components are enabled through options.

### Debian 13

```bash
curl -fL -o bootstrap_debian13.sh https://raw.githubusercontent.com/hactrox/server-shells/main/bootstrap_debian13.sh &&
sudo bash bootstrap_debian13.sh
```

Common examples:

```bash
bash bootstrap_debian13.sh --help
sudo bash bootstrap_debian13.sh --ec2 --hostname my-server --vim
```

### Ubuntu 24.04 / 26.04 LTS

```bash
curl -fL -o bootstrap_ubuntu.sh https://raw.githubusercontent.com/hactrox/server-shells/main/bootstrap_ubuntu.sh &&
sudo bash bootstrap_ubuntu.sh
```

Common examples:

```bash
bash bootstrap_ubuntu.sh --help
sudo bash bootstrap_ubuntu.sh --ec2 --hostname my-server --vim
```

Shared options:

| Option | Description |
| --- | --- |
| `--go` / `--tmux` / `--vim` | Install the corresponding component |
| `--ssm` | Install or reuse Amazon SSM Agent; enable and start the service |
| `--cloudwatch` | Install and start CloudWatch Agent, using its existing configuration or creating a default |
| `--upgrade` | Upgrade system packages before installation and keep locally modified dpkg conffiles |
| `--ec2` | Enable `--upgrade --go --tmux --ssm --cloudwatch` |
| `--hostname NAME` | Set the hostname and preserve it in cloud-init |
| `--hosts-entry` | Add a `127.0.1.1` entry to `/etc/hosts`; requires `--hostname`, usually unnecessary on EC2 |

The Debian script also supports `--mysql` to install Oracle MySQL from the official MySQL APT repository.

Publishing CloudWatch metrics requires an instance IAM role with the appropriate permissions.

Setup logs: `~/downloads/ec2-bootstrap.log` under the invoking user's home directory.

## Install or update software

For Debian 13 and Ubuntu 24.04 / 26.04 LTS. No arguments required. Run as your regular user. The scripts invoke `sudo` as needed.

### Go

Supports `amd64` / `arm64`. Installs to `/usr/local/go`.

```bash
curl -fL -o install_update_go.sh https://raw.githubusercontent.com/hactrox/server-shells/main/install_update_go.sh &&
bash install_update_go.sh
```

### tmux

Builds from source and installs to `/usr/local`. Creates a default `~/.tmux.conf` only when the file is missing.

```bash
curl -fL -o install_update_tmux.sh https://raw.githubusercontent.com/hactrox/server-shells/main/install_update_tmux.sh &&
bash install_update_tmux.sh
```

### Vim

Builds from source and installs to `/usr/local`. Creates a default `~/.vimrc` only when the file is missing.

```bash
curl -fL -o install_update_vim.sh https://raw.githubusercontent.com/hactrox/server-shells/main/install_update_vim.sh &&
bash install_update_vim.sh
```

Versions are pinned in variables near the top of each script; version arguments are not supported. After installation, follow the script output to update PATH or refresh the shell's command cache.

## Time synchronization

For Debian 13 on **EC2**. Installs chrony, removes systemd-timesyncd, and configures AWS Time Sync Service (`169.254.169.123`).

```bash
curl -fL -o config_chronyc.sh https://raw.githubusercontent.com/hactrox/server-shells/main/config_chronyc.sh &&
sudo bash config_chronyc.sh
```

## Create an SSH user

For Debian 13. Creates a user without sudo privileges and installs an Ed25519 SSH public key. For an existing user without sudo privileges, appends the public key if it is missing.

The SSH server must have public key authentication enabled and password and keyboard-interactive authentication disabled. The script checks these settings without changing them.

```bash
curl -fL -o debian_13_create_user.sh https://raw.githubusercontent.com/hactrox/server-shells/main/debian_13_create_user.sh &&
sudo bash debian_13_create_user.sh newuser 'ssh-ed25519 AAAA... your-key-comment'
```
