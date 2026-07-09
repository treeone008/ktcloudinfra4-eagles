#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$HOME/db-practice"
CONFIG_FILE="$BASE_DIR/config/db.env"

cleanup() {
  unset MYSQL_PWD 2>/dev/null || true
}
trap cleanup EXIT

log_info() {
  echo "[INFO] $*"
}

log_error() {
  echo "[ERROR] $*" >&2
}

if [ ! -f "$CONFIG_FILE" ]; then
  log_error "Config file not found: $CONFIG_FILE"
  exit 1
fi

source "$CONFIG_FILE"

for var_name in DB_HOST DB_NAME DB_USER DB_PASS BACKUP_DIR; do
  if [ -z "${!var_name:-}" ]; then
    log_error "Required config is missing: $var_name"
    exit 1
  fi
done

if [ $# -lt 1 ]; then
  log_error "Backup file path is required"
  echo "Usage:"
  echo "  $0 /path/to/backup.sql"
  echo "  $0 latest"
  exit 1
fi

if [ "$1" = "latest" ]; then
  BACKUP_FILE=$(ls -1t "$BACKUP_DIR"/"${DB_NAME}"_*.sql 2>/dev/null | head -n 1 || true)
  if [ -z "${BACKUP_FILE:-}" ]; then
    log_error "No backup files found in $BACKUP_DIR"
    exit 1
  fi
else
  BACKUP_FILE="$1"
fi

if [ ! -f "$BACKUP_FILE" ]; then
  log_error "Backup file not found: $BACKUP_FILE"
  exit 1
fi

if [ ! -s "$BACKUP_FILE" ]; then
  log_error "Backup file is empty: $BACKUP_FILE"
  exit 1
fi

export MYSQL_PWD="$DB_PASS"

log_info "Restore started"
log_info "DB_HOST=$DB_HOST"
log_info "DB_NAME=$DB_NAME"
log_info "BACKUP_FILE=$BACKUP_FILE"

mysql \
  -h "$DB_HOST" \
  -u "$DB_USER" \
  -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

mysql \
  -h "$DB_HOST" \
  -u "$DB_USER" \
  "$DB_NAME" < "$BACKUP_FILE"

log_info "Restore completed"
