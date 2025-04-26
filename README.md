# MC-Network-Backup-Scripts

## Overview
This repository automates the backup, syncing, and recovery process for your Minecraft server network between a production server (e.g., Oracle Cloud) and a backup server (your secondary VPS/VM).

**Goal:**  
✅ Daily syncs of world files, databases, and services.  
✅ Fast disaster recovery if Oracle terminates your server.  
✅ Fully automated, logged, and monitored with optional Discord notifications.

---

## Scripts Included

| Script | Where it Runs | Purpose |
|:------:|:--------------|:--------|
| `setup.sh` | Backup server | Prepares a fresh Linux VM (dependencies, Docker, MariaDB, Tailscale optional). |
| `backup_mirror.sh` | Source server (production) | Syncs Minecraft folders, services, MariaDB dumps to backup server, triggers import. |
| `import.sh` | Backup server | Imports MariaDB dump, updates config files, manages services. |

---

## Full Workflow

```text
[Production Server]
  ↓ (daily backup_mirror.sh via cron)
[Backup Server]
  ↳ Syncs Minecraft worlds, databases, service files
  ↳ Imports databases automatically
  ↳ Restarts Minecraft servers
