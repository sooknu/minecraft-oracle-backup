#!/usr/bin/env bash
set -euo pipefail

# ── Load shared config ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  echo "❌ .env file missing. Please copy .env.example and configure it."
  exit 1
fi

# ── Configuration from .env ────────────────────────────────
TIMEZONE="${TIMEZONE:-America/Los_Angeles}"
DNS="${DNS:-8.8.8.8 1.1.1.1}"
FALLBACK_DNS="${FALLBACK_DNS:-9.9.9.9 1.0.0.1}"
DB_USER="${DB_USER:?Missing DB_USER}"
DB_PASS="${DB_PASSWORD:?Missing DB_PASSWORD}"
USE_TAILSCALE_AUTH_KEY="${USE_TAILSCALE_AUTH_KEY:-false}"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
GITHUB_USERNAME="${GITHUB_USERNAME:?Missing GITHUB_USERNAME}"

# ── Root check ─────────────────────────────────────────────
[[ $EUID -ne 0 ]] && echo ">>> Run with sudo" >&2 && exit 1

# ── Main setup function ────────────────────────────────────
main() {
  check_internet
  configure_dns
  update_system
  install_dependencies
  secure_ssh_keys
  ubuntu_user
  install_github_ssh_keys
  enable_passwordless_sudo
  set_timezone
  create_backup_folders
  install_docker
  install_mariadb
  install_tailscale
  echo "🎉 All done!"
}

# ── Function definitions ─────────────────────────────────

## check_internet: verify raw internet access (skip DNS for now)
check_internet() {
  echo ">>> Checking raw internet connectivity..."
  spinner 4
  if ping -c 1 8.8.8.8 &>/dev/null; then
    echo "✅ Internet (raw IP) reachable."
    sleep 3
  else
    echo "🌐 ERROR: Cannot reach 8.8.8.8. Exiting." >&2
    exit 1
  fi
}

# ───────────────────────────────────────────────────────────


## update_system: update & upgrade packages
update_system() {
  echo ">>> Updating system packages"
  sudo apt update -y && sudo apt dist-upgrade -y
  spinner 5
  echo "✅ System updated."
  sleep 3
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
  spinner 4
  echo "✅ Timezone set to $TIMEZONE"
  sleep 3
}

## configure_dns: persistent DNS via systemd-resolved
configure_dns() {
  echo ">>> Configuring persistent DNS"

  # Check if /etc/systemd/resolved.conf exists
  if [[ ! -f /etc/systemd/resolved.conf ]]; then
    echo ">>> /etc/systemd/resolved.conf not found. Creating default..."
    sudo bash -c 'cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=9.9.9.9 1.0.0.1
EOF'
  else
    # If file exists, update it safely
    sudo sed -i \
      -e "s|^#DNS=|DNS=8.8.8.8 1.1.1.1|" \
      -e "s|^DNS=.*|DNS=8.8.8.8 1.1.1.1|" \
      -e "s|^#FallbackDNS=|FallbackDNS=9.9.9.9 1.0.0.1|" \
      -e "s|^FallbackDNS=.*|FallbackDNS=9.9.9.9 1.0.0.1|" \
      /etc/systemd/resolved.conf
  fi

  echo ">>> Restarting systemd-resolved"
  sudo systemctl restart systemd-resolved || true
  echo "✅ DNS configured to $DNS with fallback $FALLBACK_DNS"
  sleep 3
}


## install_docker: install latest Docker CE
install_docker() {
  echo ">>> Installing Docker CE..."
  spinner 4

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

    # Enable and start Docker
    sudo systemctl enable --now docker
    sudo systemctl restart docker

    # Add ubuntu user to docker group
    sudo usermod -aG docker ubuntu

    echo "✅ Docker CE installed. (You may need to log out and log back in for group changes to apply.)"
    sleep 3
  else
    echo "✅ Docker CE already installed."
    sleep 2
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
  spinner 5

  mkdir -p /home/ubuntu/.ssh
  curl -fsSL "https://github.com/${GITHUB_USERNAME}.keys" >> /home/ubuntu/.ssh/authorized_keys
  
  chmod 700 /home/ubuntu/.ssh
  chmod 600 /home/ubuntu/.ssh/authorized_keys
  chown -R ubuntu:ubuntu /home/ubuntu/.ssh

  echo "✅ Public SSH keys installed from GitHub."
  spinner 5
}
# ───────────────────────────────────────────────────────────


## ISNTALL MARIADB: install and set up MariaDB 11.4
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
  spinner 5
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

## install_tailscale: optional setup for Tailscale VPN with cleaner retry
install_tailscale() {
  echo ">>> Setting up Tailscale VPN..."

  read -rp "Do you want to install and set up Tailscale? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    echo ">>> Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    echo ">>> Enabling and starting Tailscale service..."
    sudo systemctl enable --now tailscaled

    read -rp "Do you want to use an Auth Key for automatic Tailscale login? [y/N] " use_authkey
    if [[ "$use_authkey" =~ ^[Yy]$ ]]; then
      read -rp "Use saved Auth Key from config? [y/N] " use_saved_key
      if [[ "$use_saved_key" =~ ^[Yy]$ ]]; then
        echo ">>> Running 'sudo tailscale up --ssh --authkey=${TAILSCALE_AUTH_KEY}'..."
        if sudo tailscale up --ssh --authkey="${TAILSCALE_AUTH_KEY}"; then
          spinner 3
          echo "✅ Tailscale authenticated with saved Auth Key."
          sleep 2
          echo
          echo "⚡ If authentication is required, follow any login link shown above."
          read -r
          TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "Unknown")
          echo "✅ Tailscale installed and connected! (IP: ${TAILSCALE_IP})"
          sleep 3
          return
        else
          echo "⚠️ Auth Key invalid or failed."
        fi
      fi

      while true; do
        read -rp "Enter your Tailscale Auth Key: " custom_authkey
        echo ">>> Running 'sudo tailscale up --ssh --authkey=[entered key]'..."
        if sudo tailscale up --ssh --authkey="${custom_authkey}"; then
          echo "✅ Tailscale authenticated with entered Auth Key."
          sleep 2
          break
        else
          echo "⚠️ Auth Key invalid or failed."
          sleep 2
          read -rp "Retry entering a new Auth Key? [y/N] " retry_key
          if [[ ! "$retry_key" =~ ^[Yy]$ ]]; then
            echo ">>> Switching to manual 'tailscale up --ssh' login..."
            sudo tailscale up --ssh
            break
          fi
        fi
      done
    else
      echo ">>> Running 'sudo tailscale up --ssh' (manual authentication required)..."
      sudo tailscale up --ssh
    fi

    echo
    echo "⚡ If authentication is required, follow any login link shown above."
    read -r

    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "Unknown")
    echo "✅ Tailscale installed and connected! (IP: ${TAILSCALE_IP})"
  else
    echo "-> Skipping Tailscale installation."
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
  spinner 5
}

# ───────────────────────────────────────────────────────────

## secure_ssh_keys: ensure SSH private keys are secured
secure_ssh_keys() {
  echo ">>> Securing SSH private keys"
  find /home/ubuntu/.ssh/ -type f -name "*.key" -exec chmod 600 {} \; 2>/dev/null || true
  echo "✅ SSH keys secured."
  spinner 5
}
# ───────────────────────────────────────────────────────────

## spinner: cosmetic loading animation
spinner() {
  local duration=${1:-3}
  local spinstr='|/-\'
  echo -n "    "
  for ((i = 0; i < duration * 10; i++)); do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep 0.1
    printf "\b\b\b\b\b\b"
  done
  echo ""
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
