#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/var/backups/mysql"
RETENTION_DAYS=14

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# MySQL backups
echo "📦 Erstelle MySQL-Backup..."
mysqldump --single-transaction --routines --events --all-databases | \
  gzip > "$BACKUP_DIR/backup-$(date +%F).sql.gz"

# Remove old backups
find "$BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" -name "*.gz" -delete

echo "✅ MySQL-Backup abgeschlossen: $BACKUP_DIR/backup-$(date +%F).sql.gz"