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
