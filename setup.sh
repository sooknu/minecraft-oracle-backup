#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────
TIMEZONE="America/Los_Angeles"
DNS="8.8.8.8 1.1.1.1"
FALLBACK_DNS="9.9.9.9 1.0.0.1"
DB_USER="sahid"
DB_PASS="NX6ri4p5!"
USE_TAILSCALE_AUTH_KEY=true
TAILSCALE_AUTH_KEY="tskey-auth-kCt2JkiDfy11CNTRL-M1Tm3HpQeHUyE54eaZyhJUJAM36XpfPUK"
GITHUB_USERNAME="sooknu"
# ───────────────────────────────────────────────────────────

# check if running as root
[[ $EUID -ne 0 ]] && echo ">>> Run with sudo" >&2 && exit 1

# Main function: orchestrates the setup
main() {
  check_internet
  update_system
  install_dependencies
  secure_ssh_keys
  ubuntu_user
  install_github_ssh_keys
  enable_passwordless_sudo
  set_timezone
  configure_dns
  create_backup_folders
  install_docker
  install_mariadb
  install_tailscale
  echo "🎉 All done!"
}


# ── Function definitions ─────────────────────────────────

## check_internet: verify basic connectivity and DNS resolution
check_internet() {
  echo ">>> Checking internet connectivity..."

  # First, ping a raw IP to check basic network
  if ping -c 1 8.8.8.8 &>/dev/null; then
    echo "✅ Network connection to Internet verified (ping 8.8.8.8)."
  else
    echo "🌐 ERROR: Cannot reach Internet (8.8.8.8 unreachable). Exiting." >&2
    exit 1
  fi

  # Second, resolve and curl a domain to check DNS working
  if curl -s --head --request GET https://google.com | grep "200 OK" > /dev/null; then
    echo "✅ DNS resolution and web access verified (google.com reachable)."
  else
    echo "🌐 ERROR: DNS not resolving properly or web access blocked. Exiting." >&2
    exit 1
  fi
}
# ───────────────────────────────────────────────────────────


## update_system: update & upgrade packages
update_system() {
  echo ">>> Updating system packages"
  sudo apt update -y && sudo apt dist-upgrade -y
  echo "✅ System updated."
}

## ubuntu_user: ensure ubuntu exists & is in sudo group
ubuntu_user() {
  if [[ $EUID -ne 0 ]]; then
    echo ">>> Run as root or via sudo." >&2; exit 1
  fi

  if id ubuntu &>/dev/null; then
    echo ">>> User 'ubuntu' exists."
  else
    read -rp "Create 'ubuntu'? [Y/n] " yn
    [[ $yn =~ ^[Yy]$ ]] || { echo "Need 'ubuntu'—exiting."; exit 1; }
    useradd -m -s /bin/bash ubuntu
    passwd ubuntu
  fi

  if ! id -nG ubuntu | grep -qw sudo; then
    echo ">>> Adding 'ubuntu' to sudo group"
    usermod -aG sudo ubuntu
  fi
}

## enable_passwordless_sudo: allow ubuntu to sudo without a password
enable_passwordless_sudo() {
  echo ">>> Enabling passwordless sudo"
  if ! grep -q '^ubuntu ALL=(ALL) NOPASSWD: ALL' /etc/sudoers; then
    echo -e "\n# Passwordless sudo\nubuntu ALL=(ALL) NOPASSWD: ALL" \
      | sudo tee -a /etc/sudoers > /dev/null
  fi
}

## set_timezone: configure system timezone
set_timezone() {
  echo ">>> Setting timezone to $TIMEZONE"
  sudo timedatectl set-timezone "$TIMEZONE"
  echo "✅ Timezone set to $TIMEZONE"
}

## configure_dns: persistent DNS via systemd-resolved
configure_dns() {
  echo ">>> Configuring persistent DNS"
  sudo sed -i \
    -e "s|^#DNS=|DNS=$DNS|" \
    -e "s|^#FallbackDNS=|FallbackDNS=$FALLBACK_DNS|" \

    /etc/systemd/resolved.conf
  sudo systemctl restart systemd-resolved
}

## install_docker: install latest Docker CE
install_docker() {
  echo ">>> Installing Docker CE..."
  if ! command -v docker &>/dev/null; then
    sudo apt update -y
    sudo apt install -y ca-certificates curl gnupg lsb-release

    # Add Docker’s official GPG key
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    # Set up the stable repo
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Enable, restart Docker and apply group change
    sudo systemctl enable --now docker
    sudo systemctl restart docker
    sudo usermod -aG docker ubuntu
    echo ">>> Applying docker group to current shell"
    newgrp docker <<EOF
echo "✅ Docker CE installed and group applied"
EOF
  else
    echo "✅ Docker CE already installed."
  fi
}

# ───────────────────────────────────────────────────────────

## INSTALL_DEPENDENCIES: install basic required packages
install_dependencies() {
  echo ">>> Installing basic dependencies"
  sudo apt install -y nano curl dnsutils screen openjdk-21-jre-headless rsync
}
# ───────────────────────────────────────────────────────────

## INSTALL_GITHUB_SSH_KEYS: Pull public SSH keys from GitHub and install
install_github_ssh_keys() {
  echo ">>> Installing public SSH keys from GitHub user: $GITHUB_USERNAME"

  mkdir -p /home/ubuntu/.ssh
  curl -fsSL "https://github.com/${GITHUB_USERNAME}.keys" >> /home/ubuntu/.ssh/authorized_keys
  
  chmod 700 /home/ubuntu/.ssh
  chmod 600 /home/ubuntu/.ssh/authorized_keys
  chown -R ubuntu:ubuntu /home/ubuntu/.ssh

  echo "✅ Public SSH keys installed from GitHub."
}
# ───────────────────────────────────────────────────────────


## install_mariadb: install and set up MariaDB 11.4
install_mariadb() {
  echo "-> Checking if MariaDB is already installed"
  if command -v mariadb &>/dev/null; then
    echo "-> MariaDB is already installed."
    return
  fi

  echo "-> Installing MariaDB 11.4"
  sudo apt-get install -y apt-transport-https curl
  sudo mkdir -p /etc/apt/keyrings
  sudo curl -fsSL -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp'

  # Create the MariaDB sources file
  echo "-> Creating MariaDB source list"
  sudo tee /etc/apt/sources.list.d/mariadb.sources > /dev/null <<EOF
# MariaDB 11.4 repository list
X-Repolib-Name: MariaDB
Types: deb
URIs: https://mirrors.xtom.com/mariadb/repo/11.4/ubuntu
Suites: noble
Components: main main/debug
Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp
EOF

  # Install MariaDB
  sudo apt-get update
  sudo apt-get install -y mariadb-server

  # Enable and start MariaDB
  echo "-> Enabling and starting MariaDB service"
  sudo systemctl enable --now mariadb

  echo "⚡ MariaDB installation complete!"
  echo "⚠️  IMPORTANT: Run 'sudo mysql_secure_installation' manually to secure your MariaDB server!"

  # Create the user only
  echo "-> Setting up initial MariaDB user"

  sudo mariadb -u root <<MYSQL_SCRIPT
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
FLUSH PRIVILEGES;
EXIT
MYSQL_SCRIPT

  echo "✅ MariaDB user '${DB_USER}' created with full privileges."
}
# ───────────────────────────────────────────────────────────

## install_tailscale: optional setup for Tailscale VPN
install_tailscale() {
  echo ">>> Setting up Tailscale VPN..."

  read -rp "Do you want to install and set up Tailscale? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    # Install Tailscale
    echo ">>> Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    # Enable and start Tailscale service
    echo ">>> Enabling and starting Tailscale service..."
    sudo systemctl enable --now tailscaled

    # Ask about Auth Key
    read -rp "Do you want to use an Auth Key for automatic Tailscale login? [y/N] " use_authkey
    if [[ "$use_authkey" =~ ^[Yy]$ ]]; then
      read -rp "Use saved Auth Key from config? [y/N] " use_saved_key
      if [[ "$use_saved_key" =~ ^[Yy]$ ]]; then
        echo ">>> Running 'sudo tailscale up --authkey=${TAILSCALE_AUTH_KEY}'..."
        sudo tailscale up --authkey="${TAILSCALE_AUTH_KEY}"
      else
        read -rp "Enter your Tailscale Auth Key: " custom_authkey
        echo ">>> Running 'sudo tailscale up --authkey=[entered key]'..."
        sudo tailscale up --authkey="${custom_authkey}"
      fi
    else
      echo ">>> Running 'sudo tailscale up' (manual authentication required)..."
      sudo tailscale up

      echo
      echo "⚡ Open the URL shown in the output above to authenticate this server with Tailscale."
      echo "After completing authentication, press ENTER to continue..."
      read -r
    fi

    # Show assigned Tailscale IP address
    echo ">>> Checking assigned Tailscale IP address..."
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "No IP found")
    echo "✅ Tailscale connected. Assigned IP: ${TS_IP}"

  else
    echo ">>> Skipping Tailscale installation."
  fi
}
# ───────────────────────────────────────────────────────────

## create_backup_folders: create required backup directories
create_backup_folders() {
  echo ">>> Creating backup folders"
  mkdir -p /home/ubuntu/backups
  mkdir -p /home/ubuntu/backups/db_dumps
  mkdir -p /home/ubuntu/backups/logs
  echo "✅ Backup folders created."
}

# ───────────────────────────────────────────────────────────

## secure_ssh_keys: ensure SSH private keys are secured
secure_ssh_keys() {
  echo ">>> Securing SSH private keys"
  find /home/ubuntu/.ssh/ -type f -name "*.key" -exec chmod 600 {} \; 2>/dev/null || true
  echo "✅ SSH keys secured."
}
# ───────────────────────────────────────────────────────────








# Dispatch: run “main” or a single function by name
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -gt 0 ]] && declare -f "$1" &>/dev/null; then
    "$@"
  else
    main
  fi
fi
