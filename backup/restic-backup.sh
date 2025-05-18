#!/usr/bin/env bash
set -euo pipefail

# Lade Restic-Umgebung
if [[ -f "/etc/website-engine/backup/restic.env" ]]; then
  source "/etc/website-engine/backup/restic.env"
else
  echo "❌ /etc/website-engine/backup/restic.env nicht gefunden"
  exit 1
fi

echo "📦 Starte Restic-Backup..."

# Sicherstellen, dass Repository existiert oder initialisieren
restic snapshots || restic init

# Backup erstellen
restic backup /etc /var/www /opt/website-engine /etc/website-engine

# Alte Backups aufräumen
restic forget --keep-daily 14 --keep-weekly 4 --prune

echo "✅ Restic-Backup abgeschlossen"