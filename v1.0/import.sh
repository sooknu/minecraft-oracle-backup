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

# ── Config from .env ───────────────────────────────────────
ENABLE_DISCORD_IMPORT="${ENABLE_DISCORD_IMPORT:-false}"
RESTART_SERVICES="${RESTART_SERVICES:-true}"
DB_USER="${DB_USER:?Missing DB_USER}"
DB_PASSWORD="${DB_PASSWORD:?Missing DB_PASSWORD}"
DB_DUMP_FILE="${DB_DUMP_FILE:-/home/ubuntu/backups/db_dumps/mariadb_backup.sql}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

FOLDERS=("${FOLDERS[@]}")
SERVICES=("${SERVICES[@]}")

# If CONFIG_UPDATES wasn't in .env (array), fallback to default
CONFIG_UPDATES_DEFAULT=(
  "/home/ubuntu/mc1/plugins/ItemsAdder/config.yml;192.9.224.67;99.46.81.50"
  "/home/ubuntu/mc2/plugins/ItemsAdder/config.yml;pack.sooknu.com;mcpack.sooknu.com"
  "/home/ubuntu/mc3/plugins/ItemsAdder/config.yml;pack.sooknu.com;mcpack.sooknu.com"
  "/home/ubuntu/velocity/velocity.toml;minecraft.sooknu.com;mc.sooknu.com"
)
CONFIG_UPDATES=("${CONFIG_UPDATES[@]:-${CONFIG_UPDATES_DEFAULT[@]}}")

LOG_FILE="/home/ubuntu/backups/logs/import.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

declare -A SERVICE_WAS_RUNNING

# ── Discord Embed ──────────────────────────────────────────
send_discord_notification() {
  [[ "$ENABLE_DISCORD_IMPORT" == true && -n "$DISCORD_WEBHOOK_URL" ]] || return
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

# ── Failure trap ───────────────────────────────────────────
trap '[[ "$ENABLE_DISCORD_IMPORT" == true ]] && send_discord_notification "❌ Import failed on $(hostname) at ${FUNCNAME[1]:-main}"' ERR

# ── Stop services cleanly ─────────────────────────────────
stop_services() {
  echo "$(date) - Stopping services..."
  for s in "${SERVICES[@]}"; do
    if sudo systemctl is-active --quiet "$s"; then
      SERVICE_WAS_RUNNING["$s"]=true
      sudo systemctl stop "$s"
      echo "  → stopped $s"
    else
      SERVICE_WAS_RUNNING["$s"]=false
      echo "  ↷ $s not running"
    fi
  done
}

# ── Drop all non-system databases ─────────────────────────
drop_databases() {
  echo "$(date) - Dropping old databases..."
  local dbs
  dbs=$(mysql -u"$DB_USER" -p"$DB_PASSWORD" -Nse \
        "SHOW DATABASES;" | grep -Ev "^(mysql|information_schema|performance_schema|sys)$")
  for db in $dbs; do
    mysql -u"$DB_USER" -p"$DB_PASSWORD" -e "DROP DATABASE \`$db\`;"
    echo "  → dropped $db"
  done
}

# ── Import backup file ────────────────────────────────────
import_database() {
  [[ -f "$DB_DUMP_FILE" ]] || { send_discord_notification "❌ Dump not found"; exit 1; }
  echo "$(date) - Importing database..."
  drop_databases
  mariadb -u"$DB_USER" -p"$DB_PASSWORD" < "$DB_DUMP_FILE"
  echo "  → import complete"
}

# ── Patch IPs / Domains in config ─────────────────────────
update_configurations() {
  echo "$(date) - Patching configs..."
  for entry in "${CONFIG_UPDATES[@]}"; do
    IFS=';' read -r file find replace <<<"$entry"
    if [[ -f "$file" ]] && grep -qF "$find" "$file"; then
      sed -i "s|$find|$replace|g" "$file"
      echo "  → patched $file"
    else
      echo "  ↷ skip $file"
    fi
  done
}

# ── Restart or start services ─────────────────────────────
manage_services() {
  if $RESTART_SERVICES; then
    echo "$(date) - Restoring services..."
    for s in "${SERVICES[@]}"; do
      if [[ "${SERVICE_WAS_RUNNING[$s]}" == true ]]; then
        sudo systemctl restart "$s"
        echo "  → restarted $s"
      else
        sudo systemctl start "$s"
        echo "  → started $s"
      fi
    done
  else
    echo "Leaving services stopped."
  fi
}

# ── Main function ─────────────────────────────────────────
main() {
  stop_services
  import_database
  update_configurations
  manage_services
  echo "$(date) - Import completed"

  local fields='[
    {"name": "Services", "value": "Velocity, MC1, MC2, MC3", "inline": true},
    {"name": "Database Imported", "value": "✅", "inline": true}
  ]'

  send_discord_notification "✅ Import Completed on $(hostname)" "Database and configs successfully restored." "$fields"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main
