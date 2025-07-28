# 🛡️ MC-Network-Backup-Scripts

![Bash](https://img.shields.io/badge/Bash-Scripts-green?logo=gnu-bash)
![Status](https://img.shields.io/badge/Status-Production%20Ready-brightgreen)
![License](https://img.shields.io/badge/License-MIT-blue)

## 📖 Overview

This repository automates the **backup**, **synchronization**, and **recovery** process for your Minecraft server network between a production server (e.g., Oracle Cloud) and a backup server (secondary VPS or VM).

### 🎯 Goal:
✅ Daily syncs of world files, databases, and services  
✅ Fast disaster recovery if Oracle terminates your server  
✅ Fully automated, logged, and optionally monitored via Discord

---

## 📦 Included Scripts

| Script              | Runs On          | Purpose                                                                 |
|---------------------|------------------|-------------------------------------------------------------------------|
| `setup.sh`          | 🖥 Backup Server  | Prepares a fresh Ubuntu VM: Docker, MariaDB, SSH, DNS, Tailscale, etc. |
| `backup_mirror.sh`  | ☁️ Source Server  | Syncs Minecraft folders, service files, and MariaDB dumps to backup VM. |
| `import.sh`         | 🖥 Backup Server  | Imports databases, rewrites configs (e.g., IPs), restarts services.     |

---

## 🔁 Full Workflow

```text
[Production Server]
   ↓ (daily cron: backup_mirror.sh)
[Backup Server]
   ↳ Syncs Minecraft worlds, databases, and systemd service files
   ↳ Imports MariaDB database dumps
   ↳ Updates config files (IP/domain rewrites)
   ↳ Restarts all Minecraft services
```
---

## 🚀 How to Use

Follow these steps to set up and run the backup system:

### 1. Clone the Repository

```bash
git clone https://github.com/sooknu/minecraft-oracle-backup.git
cd minecraft-oracle-backup/v1.0
```

### 2. Create and Configure the `.env` File

Copy the example `.env` file and customize your configuration:

```bash
cp .env.example .env
nano .env
```

Fill in the required environment variables, such as:

```env
BACKUP_SOURCE=/srv/minecraft
BACKUP_DEST=/mnt/backups
USE_TAILSCALE_AUTH=true
TAILSCALE_AUTH_KEY=tskey-auth-XXXXX...
...
```

> Tip: You can create a dummy test folder with `mkdir -p /srv/minecraft` for testing.

---

### 3. Run the Setup Script

This installs required tools and configures the system:

```bash
chmod +x setup.sh
./setup.sh
```

---

### 4. Run a Backup

Use the backup script to create a snapshot:

```bash
chmod +x backup_mirror.sh
./backup_mirror.sh
```

Check your backup destination for results.

---

### 5. Restore from a Backup (Optional)

You can import a backup snapshot using:

```bash
chmod +x import.sh
./import.sh
```

---

### ✅ Tested on

- Ubuntu 24.04 Minimal
- macOS with local testing via Tailscale + SSH
- Oracle Cloud Ubuntu VM
