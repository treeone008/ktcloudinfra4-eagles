#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE_DIR="$HOME/db-practice"
CONFIG_FILE="$BASE_DIR/config/db.env"
TMP_FILE=""

cleanup() {
  unset MYSQL_PWD 2>/dev/null || true
  if [ -n "${TMP_FILE:-}" ] && [ -f "$TMP_FILE" ]; then
    rm -f "$TMP_FILE"
  fi
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

mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.sql"
TMP_FILE="${BACKUP_FILE}.tmp"

export MYSQL_PWD="$DB_PASS"

log_info "Backup started"
log_info "DB_HOST=$DB_HOST"
log_info "DB_NAME=$DB_NAME"
log_info "BACKUP_FILE=$BACKUP_FILE"

mysqldump \
  -h "$DB_HOST" \
  -u "$DB_USER" \
  --single-transaction \
  --quick \
  --routines \
  --triggers \
  "$DB_NAME" > "$TMP_FILE"

if [ ! -s "$TMP_FILE" ]; then
  log_error "Backup file is empty: $TMP_FILE"
  exit 1
fi

mv "$TMP_FILE" "$BACKUP_FILE"
TMP_FILE=""

log_info "Backup completed: $BACKUP_FILE"
ls -lh "$BACKUP_FILE"

if [ -n "${MGMT_HOST:-}" ] && [ -n "${MGMT_USER:-}" ] && [ -n "${MGMT_BACKUP_DIR:-}" ]; then
  log_info "Transfer to mgmt started"
  log_info "MGMT_TARGET=${MGMT_USER}@${MGMT_HOST}:${MGMT_BACKUP_DIR}"

  ssh "${MGMT_USER}@${MGMT_HOST}" "mkdir -p '${MGMT_BACKUP_DIR}'"
  scp "$BACKUP_FILE" "${MGMT_USER}@${MGMT_HOST}:${MGMT_BACKUP_DIR}/"

  log_info "Transfer to mgmt completed"
else
  log_info "MGMT transfer config is not set. Skip transfer."
fi
