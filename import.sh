#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ───────────────────────────────────────────
SERVICES=("velocity" "mc1" "mc2" "mc3")
RESTART_SERVICES=true
DB_USER="sahid"
DB_PASSWORD="NX6ri4p5!"
DB_DUMP_FILE="/home/ubuntu/backups/mariadb_backup.sql"
CONFIG_UPDATES=(
    "/home/ubuntu/mc1/plugins/ItemsAdder/config.yml;192.9.224.67;99.46.81.50"
    "/home/ubuntu/mc2/plugins/ItemsAdder/config.yml;pack.sooknu.com;mcpack.sooknu.com"
    "/home/ubuntu/mc3/plugins/ItemsAdder/config.yml;pack.sooknu.com;mcpack.sooknu.com"
    "/home/ubuntu/velocity/velocity.toml;minecraft.sooknu.com;mc.sooknu.com"
)

DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/your-webhook-id/your-token"

# ── Main Orchestration ──────────────────────────────────────
main() {
  stop_services
  import_database
  update_configurations
  manage_services
  echo "$(date) - Import script completed successfully."
  send_discord_notification "✅ Import script completed successfully on $(hostname)"
}

# ── Logging Setup ───────────────────────────────────────────
LOG_FILE="/home/ubuntu/backups/logs/import.log"
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
# ── Functions ───────────────────────────────────────────────

## stop_services: Stop Minecraft and Velocity services
stop_services() {
  echo "$(date) - Checking and stopping services..."
  declare -gA SERVICE_WAS_RUNNING

  for service in "${SERVICES[@]}"; do
    if sudo systemctl is-active --quiet "${service}.service"; then
      SERVICE_WAS_RUNNING["$service"]=true
      echo "$(date) - ${service}.service is running; stopping it..."
      sudo systemctl stop "${service}.service"
    else
      SERVICE_WAS_RUNNING["$service"]=false
      echo "$(date) - ${service}.service is not running."
    fi
  done
}

## import_database: Import database from dump file
import_database() {
  echo "$(date) - Starting full database import..."

  if [[ ! -f "$DB_DUMP_FILE" ]]; then
    echo "$(date) - ERROR: Database dump file not found at $DB_DUMP_FILE"
    send_discord_notification "❌ Database dump file not found at $DB_DUMP_FILE"
    exit 1
  fi

  if mariadb -u"$DB_USER" -p"$DB_PASSWORD" < "$DB_DUMP_FILE"; then
    echo "$(date) - Full database import successful."
  else
    echo "$(date) - ERROR: Database import failed!"
    send_discord_notification "❌ Database import failed on $(hostname)"
    exit 1
  fi
}

## update_configurations: Replace IPs/hostnames in config files
update_configurations() {
  echo "$(date) - Starting configuration updates..."
  
  for entry in "${CONFIG_UPDATES[@]}"; do
    IFS=';' read -r file find replace <<< "$entry"
    if [[ -f "$file" ]]; then
      if grep -qF "$find" "$file"; then
        echo "$(date) - Updating $file"
        sed -i.bak "s|$find|$replace|g" "$file"
      else
        echo "$(date) - Skipping $file – string \"$find\" not found."
      fi
    else
      echo "$(date) - Skipping $file – file not found."
    fi
  done

  echo "$(date) - Configuration updates complete!"
}

## manage_services: Restart or leave services based on previous state
manage_services() {
  if $RESTART_SERVICES; then
    echo "$(date) - Restoring service states: restarting if previously running, starting if not."
    for service in "${SERVICES[@]}"; do
      if [[ "${SERVICE_WAS_RUNNING[$service]}" = true ]]; then
        echo "$(date) - ${service}.service was running; restarting it..."
        sudo systemctl restart "${service}.service"
      else
        echo "$(date) - ${service}.service was not running; starting it..."
        sudo systemctl start "${service}.service"
      fi
    done
  else
    echo "$(date) - RESTART_SERVICES is false; leaving all services stopped."
  fi
}

# ── Dispatch Helper ─────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -gt 0 ]] && declare -f "$1" &>/dev/null; then
    "$@"   # allow calling individual functions
  else
    main
  fi
fi
