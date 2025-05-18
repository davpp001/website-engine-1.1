#!/usr/bin/env bash
set -euo pipefail

# Import config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$(dirname "$SCRIPT_DIR")/modules"
source "$MODULES_DIR/config.sh"

# Konfigurationsdatei
CONFIG_FILE="/etc/website-engine/backup/restic.env"

# Lade Restic-Umgebung
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
else
  echo "❌ $CONFIG_FILE nicht gefunden"
  echo "⚙️ Starte Konfigurationsassistenten..."
  
  # Prüfe, ob die Konfigurationsfunktion verfügbar ist
  if type configure_backup_systems &>/dev/null; then
    configure_backup_systems
    
    # Nach der Konfiguration erneut versuchen, die Datei zu laden
    if [[ -f "$CONFIG_FILE" ]]; then
      echo "✅ Konfiguration erstellt, lade $CONFIG_FILE"
      source "$CONFIG_FILE"
    else
      echo "❌ Konfigurationsdatei konnte nicht erstellt werden."
      exit 1
    fi
  else
    echo "❌ Konfigurationsfunktion nicht verfügbar."
    exit 1
  fi
fi

echo "📦 Starte Restic-Backup..."

# Sicherstellen, dass Repository existiert oder initialisieren
restic snapshots || restic init

# Backup erstellen
restic backup /etc /var/www /opt/website-engine /etc/website-engine

# Alte Backups aufräumen
restic forget --keep-daily 14 --keep-weekly 4 --prune

echo "✅ Restic-Backup abgeschlossen"