#!/usr/bin/env bash
set -euo pipefail

# ── CONFIGURATION ───────────────────────────────────────────
BACKUP_HOST="${BACKUP_HOST:-ubuntu@100.106.252.50}"
SOURCE_DIR="/home/ubuntu"
SERVICES=("velocity" "mc1" "mc2" "mc3")
FOLDERS=("velocity" "mc1" "mc2" "mc3")
BACKUP_DIR="/home/ubuntu/backups"
DB_DUMP_FILE="$BACKUP_DIR/db_dumps/mariadb_backup.sql"
SSH_KEY="/home/ubuntu/.ssh/sooknu-cloud.key"
TMP_DIR="/tmp/systemd_backup"
LOG_FILE="/home/ubuntu/backups/logs/backup_mirror.log"

DB_USER="sahid"
DB_PASSWORD="NX6ri4p5!"
DB_HOST="localhost"
DB_DUMP_CMD="/usr/bin/mariadb-dump"

ENABLE_FOLDERS=true
ENABLE_SERVICES=true
ENABLE_DATABASE=true
ENABLE_REMOTE_IMPORT=true

DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/your-webhook-id/your-token"

# ── LOGGING SETUP ───────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Discord Notification Helper ─────────────────────────────
send_discord_notification() {
  local message="$1"
  if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
    curl -H "Content-Type: application/json" \
         -X POST \
         -d "{\"content\": \"$message\"}" \
         "${DISCORD_WEBHOOK_URL}" >/dev/null 2>&1 || true
  fi
}
# ────────────────────────────────────────────────────────────

# ── FUNCTIONS ───────────────────────────────────────────────

check_dependencies() {
  echo "$(date) - Checking required commands..."
  local cmds=("rsync" "ssh" "$DB_DUMP_CMD")
  for cmd in "${cmds[@]}"; do
    if ! command -v ${cmd##*/} >/dev/null 2>&1; then
      echo "$(date) - ERROR: Required command '$cmd' is not installed."
      exit 1
    fi
  done

  if [[ ! -f "$SSH_KEY" ]]; then
    echo "$(date) - ERROR: SSH key $SSH_KEY not found."
    exit 1
  fi
}

sync_files() {
  local src="$1"
  local dst="$2"
  local opts="$3"
  local output

  if output=$(rsync -az --stats $opts -e "ssh -i ${SSH_KEY}" "$src" "$dst" 2>&1); then
    echo "$output"
  else
    echo "$(date) - ERROR: Failed to sync $src to $dst"
    exit 1
  fi
}

backup_folders() {
  if $ENABLE_FOLDERS; then
    echo "$(date) - Syncing Minecraft server folders..."
    for DIR in "${FOLDERS[@]}"; do
      local_path="${SOURCE_DIR}/${DIR}"
      remote_path="${BACKUP_HOST}:${SOURCE_DIR}/${DIR}"
      if [[ -d "$local_path" ]]; then
        sync_files "$local_path/" "$remote_path/" "--delete"
        echo "$(date) - Synced folder: $DIR"
      else
        echo "$(date) - Skipping missing folder: $DIR"
      fi
    done
  else
    echo "$(date) - Folder sync disabled."
  fi
}

backup_services() {
  if $ENABLE_SERVICES; then
    echo "$(date) - Syncing systemd service files..."
    ssh -i "$SSH_KEY" "$BACKUP_HOST" "mkdir -p $TMP_DIR && sudo mkdir -p /etc/systemd/system/"
    for SERVICE in "${SERVICES[@]}"; do
      local_service="/etc/systemd/system/${SERVICE}.service"
      remote_temp="${BACKUP_HOST}:${TMP_DIR}/${SERVICE}.service"
      if [[ -f "$local_service" ]]; then
        sync_files "$local_service" "$remote_temp"
        ssh -i "$SSH_KEY" "$BACKUP_HOST" "sudo mv $TMP_DIR/${SERVICE}.service /etc/systemd/system/"
        echo "$(date) - Synced service: ${SERVICE}.service"
      else
        echo "$(date) - Skipping missing service file: ${SERVICE}.service"
      fi
    done
    ssh -i "$SSH_KEY" "$BACKUP_HOST" "sudo systemctl daemon-reload"
  else
    echo "$(date) - Service sync disabled."
  fi
}

backup_database() {
  if $ENABLE_DATABASE; then
    echo "$(date) - Dumping MariaDB databases..."
    mkdir -p "$BACKUP_DIR"
    if "$DB_DUMP_CMD" --user="$DB_USER" --password="$DB_PASSWORD" --host="$DB_HOST" \
         --all-databases --single-transaction --quick --lock-tables=false > "$DB_DUMP_FILE"; then
      echo "$(date) - Database dump successful."
      sync_files "$BACKUP_DIR/" "$BACKUP_HOST:$BACKUP_DIR/"
      echo "$(date) - Database backup synced."
    else
      echo "$(date) - ERROR: Database dump failed!"
      send_discord_notification "❌ Database dump failed on $(hostname)"
      exit 1
    fi
  else
    echo "$(date) - Database backup disabled."
  fi
}

trigger_remote_import() {
  if $ENABLE_REMOTE_IMPORT; then
    echo "$(date) - Triggering remote import script..."
    if ssh -i "$SSH_KEY" "$BACKUP_HOST" "bash /home/ubuntu/import.sh"; then
      echo "$(date) - Remote import executed successfully."
    else
      echo "$(date) - ERROR: Remote import script failed."
      send_discord_notification "❌ Remote import failed on $(hostname)"
      exit 1
    fi
  else
    echo "$(date) - Remote import disabled."
  fi
}

setup_cron() {
  echo "$(date) - Setting up cronjob for daily backup..."
  local cron_entry="0 2 * * * /home/ubuntu/mc-network-backup-scripts/backup_mirror.sh >> /home/ubuntu/backups/logs/backup_mirror.log 2>&1"

  if ! crontab -l 2>/dev/null | grep -qF "backup_mirror.sh"; then
    (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
    echo "$(date) - Cronjob installed successfully."
    send_discord_notification "✅ Backup cronjob installed on $(hostname)"
  else
    echo "$(date) - Cronjob already exists. Skipping."
  fi
}

# ── MAIN ────────────────────────────────────────────────────
main() {
  START_TIME=$(date +%s)

  echo "====================================================="
  echo "$(date) - Starting backup to $BACKUP_HOST..."
  echo "====================================================="

  check_dependencies
  backup_folders
  backup_services
  backup_database
  trigger_remote_import
  setup_cron

  END_TIME=$(date +%s)
  ELAPSED_TIME=$((END_TIME - START_TIME))

  echo "$(date) - Backup completed successfully in ${ELAPSED_TIME} seconds."
  send_discord_notification "✅ Backup and Import completed successfully on $(hostname)"
}

# ── DISPATCH ────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -gt 0 ]] && declare -f "$1" &>/dev/null; then
    "$@"   # Allow running individual functions
  else
    main
  fi
fi
