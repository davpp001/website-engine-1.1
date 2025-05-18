#!/usr/bin/env bash
set -euo pipefail

# Import config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$(dirname "$SCRIPT_DIR")/modules"
source "$MODULES_DIR/config.sh"

# Lokale Backup-Einstellungen
BACKUP_DIR="${MYSQL_BACKUP_DIR:-/var/backups/mysql}"
RETENTION_DAYS="${MYSQL_BACKUP_RETENTION:-14}"
BACKUP_FILENAME="backup-$(date +%F).sql.gz"
FULL_BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILENAME"

# S3-Integration
USE_S3=0
S3_CONFIG="/etc/website-engine/backup/restic.env"

# Prüfe, ob S3-Konfiguration vorhanden ist
if [[ -f "$S3_CONFIG" ]]; then
  echo "ℹ️ S3-Konfiguration gefunden: $S3_CONFIG"
  source "$S3_CONFIG"
  
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" && -n "${S3_BUCKET:-}" ]]; then
    USE_S3=1
    echo "ℹ️ S3-Upload wird aktiviert"
  fi
fi

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# MySQL backups
echo "📦 Erstelle MySQL-Backup..."
mysqldump --single-transaction --routines --events --all-databases | \
  gzip > "$FULL_BACKUP_PATH"

# S3-Upload wenn konfiguriert
if [[ $USE_S3 -eq 1 ]]; then
  echo "🚀 Lade Backup nach S3 hoch..."
  
  S3_PATH="${S3_PATH_MYSQL:-mysql}"
  S3_ENDPOINT="${S3_ENDPOINT:-s3.eu-central-3.ionoscloud.com}"
  S3_BACKUP_PATH="s3://${S3_BUCKET}/${S3_PATH}/${BACKUP_FILENAME}"
  
  if command -v aws &> /dev/null; then
    if aws s3 cp "$FULL_BACKUP_PATH" "$S3_BACKUP_PATH" --endpoint-url "https://$S3_ENDPOINT"; then
      echo "✅ S3-Upload erfolgreich: $S3_BACKUP_PATH"
      
      # Bereinige alte S3-Backups
      echo "🧹 Bereinige alte S3-Backups (älter als $RETENTION_DAYS Tage)..."
      # Lösche Dateien, die älter als RETENTION_DAYS sind
      CUTOFF_DATE=$(date -d "-$RETENTION_DAYS days" +%F)
      
      # Finde alle Backup-Dateien
      BACKUP_FILES=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PATH}/" --endpoint-url "https://$S3_ENDPOINT" | grep -E 'backup-[0-9]{4}-[0-9]{2}-[0-9]{2}\.sql\.gz' || echo "")
      
      if [[ -n "$BACKUP_FILES" ]]; then
        echo "$BACKUP_FILES" | while read -r line; do
          # Extrahiere Datum aus Dateinamen
          FILE_DATE=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
          FILE_NAME=$(echo "$line" | awk '{print $4}')
          
          if [[ -n "$FILE_DATE" && -n "$FILE_NAME" && "$FILE_DATE" < "$CUTOFF_DATE" ]]; then
            echo "🗑️ Lösche altes Backup: $FILE_NAME ($FILE_DATE)"
            aws s3 rm "s3://${S3_BUCKET}/${S3_PATH}/${FILE_NAME}" --endpoint-url "https://$S3_ENDPOINT"
          fi
        done
      fi
    else
      echo "❌ S3-Upload fehlgeschlagen"
    fi
  else
    echo "⚠️ AWS CLI nicht gefunden - S3-Upload übersprungen"
    echo "   Installieren Sie die AWS CLI mit: apt-get install awscli"
  fi
fi

# Remove old local backups
echo "🧹 Bereinige alte lokale Backups..."
find "$BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" -name "*.gz" -delete

echo "✅ MySQL-Backup abgeschlossen: $FULL_BACKUP_PATH"