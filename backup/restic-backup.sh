#!/usr/bin/env bash
set -euo pipefail

# Import config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$(dirname "$SCRIPT_DIR")/modules"
source "$MODULES_DIR/config.sh"

# Konfigurationsdatei
CONFIG_FILE="/etc/website-engine/backup/restic.env"

# Lade Restic-Umgebung
if [[ -f "$CONFIG_FILE" ]] && [[ -s "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
  
  # Zusätzliche Prüfung ob die essentiellen Variablen gesetzt sind
  if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD:-}" ]]; then
    echo "⚠️ Restic-Konfiguration unvollständig. Starte Konfigurationsassistenten..."
    NEED_CONFIG=1
  fi
else
  echo "❌ $CONFIG_FILE nicht gefunden oder leer"
  echo "⚙️ Starte Konfigurationsassistenten..."
  NEED_CONFIG=1
fi

# Konfigurationsassistent bei Bedarf
if [[ "${NEED_CONFIG:-0}" -eq 1 ]]; then
  echo
  echo "==============================================================="
  echo "📦 Restic Backup-Konfiguration"
  echo "==============================================================="
  echo "Für verschlüsselte Datei-Backups benötigen wir eine Restic-Konfiguration."
  echo "Bitte halten Sie folgende Informationen bereit:"
  echo "  - S3-Repository-URL (z.B. s3:https://s3.eu-central-3.ionoscloud.com/my-backups)"
  echo "  - Ein sicheres Repository-Passwort"
  echo "  - S3 Access Key und Secret Key"
  echo

  # Repository-URL abfragen
  RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-""}
  read -p "S3-Repository-URL: " RESTIC_REPOSITORY
  
  # Repository-Passwort abfragen oder generieren
  RESTIC_PASSWORD=${RESTIC_PASSWORD:-""}
  read -p "Repository-Passwort (Enter für automatische Generierung): " RESTIC_PASSWORD
  if [[ -z "$RESTIC_PASSWORD" ]]; then
    RESTIC_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    echo "Generiertes Passwort: $RESTIC_PASSWORD"
    echo "⚠️ WICHTIG: Speichern Sie dieses Passwort sicher ab!"
  fi
  
  # S3 Credentials abfragen
  AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-""}
  read -p "S3 Access Key ID: " AWS_ACCESS_KEY_ID
  
  AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-""}
  read -p "S3 Secret Access Key: " AWS_SECRET_ACCESS_KEY

  # Konfigurationsdatei erstellen
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" << EOL
# Restic-Konfiguration
# Automatisch konfiguriert am $(date +%Y-%m-%d)
export RESTIC_REPOSITORY="$RESTIC_REPOSITORY"
export RESTIC_PASSWORD="$RESTIC_PASSWORD"
export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
EOL

  # Berechtigungen setzen
  chmod 600 "$CONFIG_FILE"
  echo "✅ Restic-Konfiguration gespeichert in $CONFIG_FILE"
  
  # Variablen für die aktuelle Sitzung exportieren
  export RESTIC_REPOSITORY
  export RESTIC_PASSWORD
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
fi

echo "📦 Starte Restic-Backup..."

# Sicherstellen, dass Repository existiert oder initialisieren
restic snapshots || restic init

# Backup erstellen
restic backup /etc /var/www /opt/website-engine /etc/website-engine

# Alte Backups aufräumen
restic forget --keep-daily 14 --keep-weekly 4 --prune

echo "✅ Restic-Backup abgeschlossen"