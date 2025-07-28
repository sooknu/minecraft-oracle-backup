#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

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

# ── Trap failure notification ──────────────────────────────
trap '[[ "${ENABLE_DISCORD}" == true ]] && send_discord_notification "❌ Backup failed on $(hostname) at ${FUNCNAME[1]:-main}"' ERR

# ── Configuration ──────────────────────────────────────────
CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"
BACKUP_HOST="${BACKUP_HOST:?Missing BACKUP_HOST}"
SSH_KEY="${SSH_KEY:-/home/ubuntu/.ssh/id_rsa}"

SOURCE_DIR="/home/ubuntu"
FOLDERS=("${FOLDERS[@]}")
SERVICES=("${SERVICES[@]}")

BACKUP_DIR="/home/ubuntu/backups"
DB_DUMP_FILE="$BACKUP_DIR/db_dumps/mariadb_backup.sql"
LOG_FILE="$BACKUP_DIR/logs/backup_mirror.log"
TMP_DIR="/tmp/systemd_backup"

DB_DUMP_CMD="/usr/bin/mariadb-dump"
DB_USER="${DB_USER:?Missing DB_USER}"
DB_PASSWORD="${DB_PASSWORD:?Missing DB_PASSWORD}"
DB_HOST="${DB_HOST:-localhost}"

ENABLE_FOLDERS="${ENABLE_FOLDERS:-true}"
ENABLE_SERVICES="${ENABLE_SERVICES:-true}"
ENABLE_DATABASE="${ENABLE_DATABASE:-true}"
ENABLE_REMOTE_IMPORT="${ENABLE_REMOTE_IMPORT:-true}"
ENABLE_DISCORD="${ENABLE_DISCORD:-false}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

TOTAL_BYTES=0

# ── Logging ────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Discord Notifications ─────────────────────────────────
send_discord_notification() {
  [[ "$ENABLE_DISCORD" == true && -n "$DISCORD_WEBHOOK_URL" ]] || return
  local title="$1"
  local description="$2"
  local fields="$3"

  local payload
  payload=$(jq -n --arg title "$title" --arg desc "$description" --argjson fields "$fields" '
  {
    "embeds": [
      {
        "title": $title,
        "description": $desc,
        "color": 5814783,
        "fields": $fields
      }
    ]
  }')

  curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$DISCORD_WEBHOOK_URL" || true
}

# ── Dependency Check ──────────────────────────────────────
check_dependencies() {
  for cmd in rsync ssh "${DB_DUMP_CMD##*/}" bc; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found"; exit 1; }
  done
  [[ -f "$SSH_KEY" ]] || { echo "ERROR: SSH key $SSH_KEY missing"; exit 1; }
}

# ── File Sync Helper ──────────────────────────────────────
sync_files() {
  local src="$1" dst="$2" opts=("${3:-}")
  local out transferred sent_bytes bytes
  local attempts=0 max_attempts=3

  while (( attempts < max_attempts )); do
    if [[ -n "${opts[0]}" ]]; then
      out=$(rsync -az --stats "${opts[@]}" \
            -e "ssh -i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
            "$src" "$dst" 2>&1) && break
    else
      out=$(rsync -az --stats \
            -e "ssh -i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
            "$src" "$dst" 2>&1) && break
    fi

    echo "$(date) - WARNING: rsync failed (attempt $((attempts + 1))/$max_attempts). Retrying in 5 seconds..."
    sleep 5
    ((attempts++))
  done

  if (( attempts == max_attempts )); then
    echo "$(date) - ERROR: rsync failed after $max_attempts attempts: $src → $dst"
    return 1
  fi

  transferred=$(awk '/Total transferred file size:/ {gsub(",", "", $5); print $5}' <<<"$out")
  bytes="${transferred:-$(awk '/Total bytes sent:/ {gsub(",", "", $4); print $4}' <<<"$out")}"
  (( TOTAL_BYTES += ${bytes:-0} ))
}

# ── Folder Backup ─────────────────────────────────────────
backup_folders() {
  $ENABLE_FOLDERS || { echo "Folder sync disabled"; return; }
  echo "$(date) - Syncing folders..."
  for d in "${FOLDERS[@]}"; do
    if [[ -d "$SOURCE_DIR/$d" ]]; then
      sync_files "$SOURCE_DIR/$d/" "$BACKUP_HOST:$SOURCE_DIR/$d/" "--delete"
      echo "  → $d"
    else
      echo "  ↷ skip $d"
    fi
  done
}

# ── Service Backup ────────────────────────────────────────
backup_services() {
  $ENABLE_SERVICES || { echo "Service sync disabled"; return; }
  echo "$(date) - Syncing systemd service files..."

  ssh -i "$SSH_KEY" "$BACKUP_HOST" "mkdir -p $TMP_DIR" || {
    echo "$(date) - ERROR: Could not create $TMP_DIR on backup server"; return 1;
  }

  for s in "${SERVICES[@]}"; do
    local_svc="/etc/systemd/system/$s.service"
    remote_temp="$BACKUP_HOST:$TMP_DIR/$s.service"

    if [[ -f "$local_svc" ]]; then
      if sync_files "$local_svc" "$remote_temp" ""; then
        ssh -i "$SSH_KEY" "$BACKUP_HOST" "sudo mv $TMP_DIR/$s.service /etc/systemd/system/"
        echo "$(date) - Synced service: $s.service"
      else
        echo "$(date) - WARNING: Failed to sync $s.service, continuing..."
      fi
    else
      echo "$(date) - Skipping missing service file: $s.service"
    fi
  done

  ssh -i "$SSH_KEY" "$BACKUP_HOST" "sudo systemctl daemon-reload"
}

# ── Database Backup ───────────────────────────────────────
backup_database() {
  $ENABLE_DATABASE || { echo "$(date) - Database backup disabled."; return; }
  echo "$(date) - Dumping MariaDB databases..."
  mkdir -p "$BACKUP_DIR/db_dumps"

  if "$DB_DUMP_CMD" \
       --user="$DB_USER" --password="$DB_PASSWORD" --host="$DB_HOST" \
       --all-databases --single-transaction --quick --lock-tables=false \
       > "$DB_DUMP_FILE"; then

    echo "$(date) - Database dump successful."

    ssh -i "$SSH_KEY" "$BACKUP_HOST" \
      "mkdir -p $(dirname "$DB_DUMP_FILE")"

    sync_files "$BACKUP_DIR/db_dumps/" "$BACKUP_HOST:$BACKUP_DIR/db_dumps/" ""
    echo "$(date) - Database backup synced."

  else
    echo "$(date) - ERROR: Database dump failed!"
    send_discord_notification "❌ Database dump failed on $(hostname)"
    exit 1
  fi
}

# ── Remote Import Trigger ─────────────────────────────────
trigger_remote_import() {
  $ENABLE_REMOTE_IMPORT || { echo "Remote import disabled"; return; }
  echo "$(date) - Triggering import on remote..."
  ssh -i "$SSH_KEY" "$BACKUP_HOST" "bash /home/ubuntu/mc-network-backup-scripts/import.sh" \
    && echo "  → import triggered" \
    || {
      echo "ERROR: remote import failed"
      send_discord_notification "❌ Remote import failed on $(hostname)"
      exit 1
    }
}

# ── Cron Setup ─────────────────────────────────────────────
setup_cronjob() {
  echo "$(date) - Ensuring cronjob..."
  local marker="# mc-backup-cron"
  local cmd="/home/ubuntu/mc-network-backup-scripts/$(basename "$0") >> $LOG_FILE 2>&1"
  local entry="$CRON_SCHEDULE $cmd $marker"
  local existing
  existing=$(crontab -l 2>/dev/null || true)

  if ! grep -Fq "$marker" <<<"$existing"; then
    printf '%s\n%s\n' "$existing" "$entry" | crontab -
    echo "  → installed: $entry"
    send_discord_notification "✅ Backup cronjob installed on $(hostname) ($CRON_SCHEDULE)"
  else
    echo "  ↷ cron already present"
  fi
}

# ── Timing & Summary ──────────────────────────────────────
start_backup_timer() {
  START=$(date +%s)
  echo "===== START BACKUP ⇒ $BACKUP_HOST ====="
}

finish_backup_timer() {
  local END
  END=$(date +%s)
  local elapsed=$((END-START))
  local mb=$(echo "scale=2; $TOTAL_BYTES/1048576" | bc)
  echo "===== DONE in ${elapsed}s | ${mb} MB transferred ====="

  local fields='[
    {"name": "Elapsed Time", "value": "'"${elapsed}s"'", "inline": true},
    {"name": "Data Transferred", "value": "'"${mb} MB"'", "inline": true}
  ]'

  send_discord_notification "✅ Backup Completed on $(hostname)" "Everything completed successfully!" "$fields"
}

# ── Main ──────────────────────────────────────────────────
main() {
  start_backup_timer
  check_dependencies
  backup_folders
  backup_services
  backup_database
  trigger_remote_import
  setup_cronjob
  finish_backup_timer
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main
