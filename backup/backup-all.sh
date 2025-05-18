#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# VOLLSTÄNDIGES BACKUP AUSFÜHREN
# ====================================================================

# Import config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$(dirname "$SCRIPT_DIR")/modules"
source "$MODULES_DIR/config.sh"

# Zeige Verwendung an
usage() {
  echo "Verwendung: $0 [Optionen]"
  echo
  echo "Führt ein vollständiges Backup der Website Engine aus."
  echo "Dies umfasst: MySQL-Datenbanken, IONOS Volume-Snapshots und Restic File-Backups."
  echo
  echo "Optionen:"
  echo "  --all           Alle Backup-Typen ausführen (Standard)"
  echo "  --mysql         Nur MySQL-Datenbank-Backup ausführen"
  echo "  --ionos         Nur IONOS Volume-Snapshot erstellen"
  echo "  --restic        Nur Restic File-Backup ausführen"
  echo "  --only-site=SUB Nur Backup für eine bestimmte Subdomain ausführen"
  echo "  --verbose       Ausführliche Ausgabe aktivieren"
  echo "  --help          Diese Hilfe anzeigen"
  echo
  exit 1
}

# Initialisiere Optionen
DO_MYSQL=0
DO_IONOS=0
DO_RESTIC=0
VERBOSE=0
ONLY_SITE=""

# Keine Option bedeutet alle
if [[ $# -eq 0 ]]; then
  DO_MYSQL=1
  DO_IONOS=1
  DO_RESTIC=1
fi

# Parse Argumente
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      DO_MYSQL=1
      DO_IONOS=1
      DO_RESTIC=1
      shift
      ;;
    --mysql)
      DO_MYSQL=1
      shift
      ;;
    --ionos)
      DO_IONOS=1
      shift
      ;;
    --restic)
      DO_RESTIC=1
      shift
      ;;
    --only-site=*)
      ONLY_SITE="${1#*=}"
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    --help)
      usage
      ;;
    *)
      echo "Unbekannte Option: $1"
      usage
      ;;
  esac
done

# Verzeichnisse prüfen und erstellen
mkdir -p "${MYSQL_BACKUP_DIR}"
chmod -R 700 "${MYSQL_BACKUP_DIR}"

# Zeige Banner an
echo "====================================================================="
echo "🚀 WEBSITE ENGINE - VOLLSTÄNDIGES BACKUP"
echo "🕒 Startzeit: $(date '+%Y-%m-%d %H:%M:%S')"
echo "====================================================================="
log "INFO" "Starte vollständiges Backup..."

# Prüfe und konfiguriere Backup-Systeme bei Bedarf
if [[ $DO_IONOS -eq 1 || $DO_RESTIC -eq 1 ]]; then
  # Konfigurationsfunktion direkt hier definieren für maximale Kompatibilität
  function backup_configuration() {
    local config_changed=0

    # IONOS-Konfiguration
    local ionos_config="/etc/website-engine/backup/ionos.env"
    local should_configure_ionos=0

    if [[ ! -f "$ionos_config" ]]; then
      should_configure_ionos=1
    elif [[ ! -s "$ionos_config" ]]; then
      should_configure_ionos=1
    else
      # Prüfe, ob wichtige Einstellungen vorhanden sind
      source "$ionos_config" 2>/dev/null || true
      if [[ -z "${IONOS_TOKEN:-}" || -z "${IONOS_SERVER_ID:-}" || -z "${IONOS_VOLUME_ID:-}" ]]; then
        should_configure_ionos=1
      fi
    fi

    if [[ $should_configure_ionos -eq 1 ]]; then
      echo
      echo "==============================================================="
      echo "🌩️  IONOS Cloud Snapshot-Konfiguration"
      echo "==============================================================="
      echo "Für Server-Snapshots benötigen wir eine Verbindung zu IONOS Cloud."
      echo "Bitte halten Sie folgende Informationen bereit:"
      echo "  - IONOS API-Token (aus Ihrem IONOS Cloud Panel)"
      echo "  - Server-ID und Volume-ID Ihres IONOS Cloud-Servers"
      echo

      # IONOS-Token abfragen
      local ionos_token=""
      read -p "IONOS API-Token: " ionos_token
      
      # Server-ID abfragen
      local ionos_server_id=""
      read -p "IONOS Server-ID: " ionos_server_id
      
      # Volume-ID abfragen
      local ionos_volume_id=""
      read -p "IONOS Volume-ID: " ionos_volume_id

      # Optional: Datacenter-ID abfragen
      local ionos_datacenter_id=""
      read -p "IONOS Datacenter-ID (optional, Enter für Standard): " ionos_datacenter_id
      
      # Konfigurationsdatei erstellen
      mkdir -p "$(dirname "$ionos_config")"
      cat > "$ionos_config" << EOL
# IONOS Cloud API Konfiguration
# Automatisch konfiguriert am $(date +%Y-%m-%d)

# Erforderliche Konfiguration
IONOS_TOKEN="$ionos_token"
IONOS_SERVER_ID="$ionos_server_id"
IONOS_VOLUME_ID="$ionos_volume_id"

# Optionale Konfiguration
IONOS_DATACENTER_ID="$ionos_datacenter_id"
IONOS_API_VERSION="v6"
EOL

      # Berechtigungen setzen
      chmod 600 "$ionos_config"
      log "SUCCESS" "IONOS-Konfiguration gespeichert in $ionos_config"
      echo "✅ IONOS-Konfiguration gespeichert."
      config_changed=1
    else
      log "INFO" "IONOS-Konfiguration existiert bereits und scheint gültig zu sein"
    fi

    # Restic-Konfiguration
    local restic_config="/etc/website-engine/backup/restic.env"
    local should_configure_restic=0

    if [[ ! -f "$restic_config" ]]; then
      should_configure_restic=1
    elif [[ ! -s "$restic_config" ]]; then
      should_configure_restic=1
    else
      # Prüfe, ob wichtige Einstellungen vorhanden sind
      source "$restic_config" 2>/dev/null || true
      if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD:-}" ]]; then
        should_configure_restic=1
      fi
    fi

    if [[ $should_configure_restic -eq 1 ]]; then
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
      local restic_repo=""
      read -p "S3-Repository-URL: " restic_repo
      
      # Repository-Passwort abfragen oder generieren
      local restic_pwd=""
      read -p "Repository-Passwort (Enter für automatische Generierung): " restic_pwd
      if [[ -z "$restic_pwd" ]]; then
        # Einfache Passwortgenerierung
        restic_pwd=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
        echo "Generiertes Passwort: $restic_pwd"
        echo "⚠️ WICHTIG: Speichern Sie dieses Passwort sicher ab!"
      fi
      
      # S3 Credentials abfragen
      local aws_access_key=""
      read -p "S3 Access Key ID: " aws_access_key
      
      local aws_secret_key=""
      read -p "S3 Secret Access Key: " aws_secret_key

      # Konfigurationsdatei erstellen
      mkdir -p "$(dirname "$restic_config")"
      cat > "$restic_config" << EOL
# Restic-Konfiguration
# Automatisch konfiguriert am $(date +%Y-%m-%d)
export RESTIC_REPOSITORY="$restic_repo"
export RESTIC_PASSWORD="$restic_pwd"
export AWS_ACCESS_KEY_ID="$aws_access_key"
export AWS_SECRET_ACCESS_KEY="$aws_secret_key"
EOL

      # Berechtigungen setzen
      chmod 600 "$restic_config"
      log "SUCCESS" "Restic-Konfiguration gespeichert in $restic_config"
      echo "✅ Restic-Konfiguration gespeichert."
      config_changed=1
    else
      log "INFO" "Restic-Konfiguration existiert bereits und scheint gültig zu sein"
    fi

    # Wenn Konfiguration geändert wurde, Status melden
    if [[ $config_changed -eq 1 ]]; then
      echo
      echo "==============================================================="
      echo "✅ Backup-Konfiguration abgeschlossen"
      echo "==============================================================="
      echo "Die Backup-Systeme wurden konfiguriert."
      echo
    fi

    return 0
  }

  # Backup-Konfiguration ausführen
  backup_configuration
fi

# Status-Funktion für Backup-Fortschritt
status_msg() {
  local level="$1"
  local msg="$2"
  echo "[$level] $msg"
  log "$level" "$msg"
}

# MySQL-Backup
if [[ $DO_MYSQL -eq 1 ]]; then
  echo
  echo "📦 1. MySQL-DATENBANK-BACKUP"
  echo "--------------------------------------------------------------------"
  MYSQL_STATUS=0
  
  # Site-spezifisches Backup oder alle Datenbanken
  if [[ -n "$ONLY_SITE" ]]; then
    status_msg "INFO" "Erstelle Backup nur für Subdomain $ONLY_SITE"
    
    # Lade DB-Infos für die Site
    DB_INFO_FILE="$CONFIG_DIR/sites/${ONLY_SITE}/db-info.env"
    if [[ -f "$DB_INFO_FILE" ]]; then
      source "$DB_INFO_FILE"
      BACKUP_FILE="${MYSQL_BACKUP_DIR}/${ONLY_SITE}-$(date +%F).sql.gz"
      
      status_msg "INFO" "Erstelle Backup für Datenbank $DB_NAME nach $BACKUP_FILE"
      
      if ! mysqldump --single-transaction --routines --events --databases "$DB_NAME" | gzip > "$BACKUP_FILE"; then
        status_msg "ERROR" "Fehler beim Backup der Datenbank $DB_NAME"
        MYSQL_STATUS=1
      else
        status_msg "SUCCESS" "Datenbank-Backup für $ONLY_SITE abgeschlossen: $BACKUP_FILE"
      fi
    else
      status_msg "ERROR" "Keine Datenbank-Informationen für Subdomain $ONLY_SITE gefunden"
      MYSQL_STATUS=1
    fi
  else
    # Backup aller Datenbanken
    BACKUP_FILE="${MYSQL_BACKUP_DIR}/backup-$(date +%F).sql.gz"
    status_msg "INFO" "Erstelle Backup aller Datenbanken nach $BACKUP_FILE"
    
    if ! mysqldump --single-transaction --routines --events --all-databases | gzip > "$BACKUP_FILE"; then
      status_msg "ERROR" "Fehler beim Backup aller Datenbanken"
      MYSQL_STATUS=1
    else
      status_msg "SUCCESS" "Backup aller Datenbanken abgeschlossen: $BACKUP_FILE"
    fi
    
    # Alte Backups aufräumen
    if [[ -d "$MYSQL_BACKUP_DIR" ]]; then
      status_msg "INFO" "Entferne MySQL-Backups älter als $MYSQL_BACKUP_RETENTION Tage"
      find "$MYSQL_BACKUP_DIR" -type f -mtime +"$MYSQL_BACKUP_RETENTION" -name "*.gz" -delete
      status_msg "INFO" "Bereinigung alter Backups abgeschlossen"
    fi
  fi
  
  if [[ $MYSQL_STATUS -eq 0 ]]; then
    echo "✅ MySQL-Backup erfolgreich abgeschlossen"
  else
    echo "❌ MySQL-Backup mit Fehlern abgeschlossen"
  fi
fi

# IONOS Volume-Snapshot
if [[ $DO_IONOS -eq 1 ]]; then
  echo
  echo "📦 2. IONOS VOLUME-SNAPSHOT"
  echo "--------------------------------------------------------------------"
  IONOS_STATUS=0
  
  # IONOS-Snapshot-Skript ausführen
  status_msg "INFO" "Erstelle IONOS Volume-Snapshot"
  
  if [[ $VERBOSE -eq 1 ]]; then
    # Ausführlich
    if ! "$SCRIPT_DIR/ionos-snapshot.sh"; then
      status_msg "ERROR" "Fehler beim Erstellen des IONOS Volume-Snapshots"
      IONOS_STATUS=1
    fi
  else
    # Standard (weniger Ausgabe)
    if ! "$SCRIPT_DIR/ionos-snapshot.sh" > /dev/null; then
      status_msg "ERROR" "Fehler beim Erstellen des IONOS Volume-Snapshots"
      IONOS_STATUS=1
    else
      status_msg "SUCCESS" "IONOS Volume-Snapshot erfolgreich erstellt"
    fi
  fi
  
  if [[ $IONOS_STATUS -eq 0 ]]; then
    echo "✅ IONOS-Snapshot erfolgreich abgeschlossen"
  else
    echo "❌ IONOS-Snapshot mit Fehlern abgeschlossen"
  fi
fi

# Restic File-Backup
if [[ $DO_RESTIC -eq 1 ]]; then
  echo
  echo "📦 3. RESTIC FILE-BACKUP"
  echo "--------------------------------------------------------------------"
  RESTIC_STATUS=0
  
  # Lade Restic-Umgebung
  RESTIC_ENV_FILE="/etc/website-engine/backup/restic.env"
  if [[ -f "$RESTIC_ENV_FILE" ]]; then
    status_msg "INFO" "Lade Restic-Konfiguration aus $RESTIC_ENV_FILE"
    source "$RESTIC_ENV_FILE"
  else
    status_msg "ERROR" "Restic-Konfigurationsdatei nicht gefunden: $RESTIC_ENV_FILE"
    echo "❌ Restic-Konfigurationsdatei nicht gefunden: $RESTIC_ENV_FILE"
    RESTIC_STATUS=1
  fi
  
  if [[ $RESTIC_STATUS -eq 0 ]]; then
    # Prüfe, ob Restic-Repository initialisiert ist
    if ! restic snapshots > /dev/null 2>&1; then
      status_msg "WARNING" "Restic-Repository existiert nicht oder ist nicht initialisiert"
      
      status_msg "INFO" "Initialisiere Restic-Repository"
      if ! restic init; then
        status_msg "ERROR" "Fehler bei der Initialisierung des Restic-Repositories"
        RESTIC_STATUS=1
      else
        status_msg "SUCCESS" "Restic-Repository erfolgreich initialisiert"
      fi
    fi
    
    if [[ $RESTIC_STATUS -eq 0 ]]; then
      # Erstelle Backup
      status_msg "INFO" "Erstelle Restic-Backup"
      
      # Site-spezifisches Backup oder alles
      if [[ -n "$ONLY_SITE" ]]; then
        SITE_PATH="${WP_DIR}/${ONLY_SITE}"
        status_msg "INFO" "Erstelle Backup nur für Subdomain $ONLY_SITE: $SITE_PATH"
        
        if [[ -d "$SITE_PATH" ]]; then
          if ! restic backup "$SITE_PATH" --tag "$ONLY_SITE" --tag "wordpress" --tag "$(date +%F)"; then
            status_msg "ERROR" "Fehler beim Erstellen des Restic-Backups für $ONLY_SITE"
            RESTIC_STATUS=1
          else
            status_msg "SUCCESS" "Restic-Backup für $ONLY_SITE abgeschlossen"
          fi
        else
          status_msg "ERROR" "Verzeichnis für Subdomain nicht gefunden: $SITE_PATH"
          RESTIC_STATUS=1
        fi
      else
        # Standardpfade sichern
        status_msg "INFO" "Sichere Standardpfade: /etc, /var/www, /opt/website-engine, /etc/website-engine"
        
        if ! restic backup /etc /var/www /opt/website-engine /etc/website-engine --tag "full" --tag "$(date +%F)"; then
          status_msg "ERROR" "Fehler beim Erstellen des Restic-Backups"
          RESTIC_STATUS=1
        else
          status_msg "SUCCESS" "Restic-Backup abgeschlossen"
        fi
      fi
      
      # Alte Backups aufräumen (nur wenn kein site-spezifisches Backup)
      if [[ -z "$ONLY_SITE" && $RESTIC_STATUS -eq 0 ]]; then
        status_msg "INFO" "Bereinige alte Restic-Backups"
        
        if ! restic forget --keep-daily "$RESTIC_BACKUP_RETAIN_DAILY" --keep-weekly "$RESTIC_BACKUP_RETAIN_WEEKLY" --keep-monthly "$RESTIC_BACKUP_RETAIN_MONTHLY" --prune; then
          status_msg "ERROR" "Fehler bei der Bereinigung alter Restic-Backups"
          RESTIC_STATUS=1
        else
          status_msg "SUCCESS" "Bereinigung alter Restic-Backups abgeschlossen"
        fi
      fi
    fi
  fi
  
  if [[ $RESTIC_STATUS -eq 0 ]]; then
    echo "✅ Restic-Backup erfolgreich abgeschlossen"
  else
    echo "❌ Restic-Backup mit Fehlern abgeschlossen"
  fi
fi

# Abschluss und Zusammenfassung
echo
echo "====================================================================="
echo "🏁 BACKUP ABGESCHLOSSEN"
echo "🕒 Endzeit: $(date '+%Y-%m-%d %H:%M:%S')"

# Gesamtstatus ermitteln
TOTAL_STATUS=$((MYSQL_STATUS + IONOS_STATUS + RESTIC_STATUS))
if [[ $TOTAL_STATUS -eq 0 ]]; then
  echo "✅ Alle Backup-Operationen erfolgreich abgeschlossen"
  log "SUCCESS" "Vollständiges Backup erfolgreich abgeschlossen"
else
  echo "⚠️ Backup mit einigen Fehlern abgeschlossen"
  log "WARNING" "Backup mit $TOTAL_STATUS Fehlern abgeschlossen"
fi
echo "====================================================================="

# Backup-Übersicht anzeigen (wenn verbose)
if [[ $VERBOSE -eq 1 ]]; then
  echo
  echo "📊 BACKUP-ÜBERSICHT"
  echo "--------------------------------------------------------------------"
  
  # MySQL-Übersicht
  if [[ $DO_MYSQL -eq 1 ]]; then
    echo "MySQL-Backup:"
    ls -lah "$MYSQL_BACKUP_DIR" | tail -n 5
    echo
  fi
  
  # Restic-Übersicht
  if [[ $DO_RESTIC -eq 1 && $RESTIC_STATUS -eq 0 ]]; then
    echo "Restic-Snapshots:"
    restic snapshots --last 5
    echo
  fi
fi

exit $TOTAL_STATUS