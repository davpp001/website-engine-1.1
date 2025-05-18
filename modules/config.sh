#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# ZENTRALE KONFIGURATIONSDATEI
# ====================================================================

# Versionsinfo
VERSION="1.0.0"
CODENAME="Simplified"

# Standardfehlerbehandlung
function handle_error() {
  local line=$1
  local cmd=$2
  local code=$3
  echo "❌ [FEHLER] In Zeile $line: Befehl '$cmd' schlug fehl mit Code $code"
  echo "📝 Bitte prüfe die Logs für weitere Details: /var/log/website-engine.log"
}
trap 'handle_error ${LINENO} "${BASH_COMMAND}" $?' ERR

# Logging-Funktion
function log() {
  local level="$1"
  local message="$2"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  
  # Sicherstellen, dass Log-Verzeichnis existiert
  if [[ ! -d "/var/log" ]]; then
    mkdir -p "/var/log"
  fi
  
  echo "[$timestamp] [$level] $message" >> /var/log/website-engine.log
  
  # Bei kritischen Fehlern auch nach stderr ausgeben
  if [[ "$level" == "ERROR" ]]; then
    echo "❌ $message" >&2
  fi
}

# Domain-Konfiguration
export DOMAIN=${WEBSITE_ENGINE_DOMAIN:-"s-neue.website"}
export SERVER_IP=$(curl -s https://ifconfig.me || echo "127.0.0.1")

# Cloudflare-Konfiguration
export ZONE="$DOMAIN"
export TTL=120

# Pfade
export CONFIG_DIR="/etc/website-engine"
export DATA_DIR="/var/lib/website-engine"
export BACKUP_DIR="/var/backups/website-engine"
export SSL_DIR="/etc/letsencrypt/live/$DOMAIN"

# SSL-Konfiguration
export SSL_CERT_PATH="$SSL_DIR/fullchain.pem"
export SSL_KEY_PATH="$SSL_DIR/privkey.pem" 
export SSL_EMAIL=${WEBSITE_ENGINE_SSL_EMAIL:-"admin@$DOMAIN"}

# Apache-Konfiguration
export APACHE_SITES_DIR="/etc/apache2/sites-available"
export APACHE_LOG_DIR="/var/log/apache2"

# WordPress-Konfiguration
export WP_DIR="/var/www"
export WP_EMAIL=${WEBSITE_ENGINE_WP_EMAIL:-"admin@online-aesthetik.de"}

# Datenbank-Konfiguration
export DB_PREFIX="wp_"

# Backup-Konfiguration
export MYSQL_BACKUP_DIR="$BACKUP_DIR/mysql"
export MYSQL_BACKUP_RETENTION=14
export RESTIC_BACKUP_DIR="$BACKUP_DIR/restic"
export RESTIC_BACKUP_RETAIN_DAILY=14
export RESTIC_BACKUP_RETAIN_WEEKLY=4
export RESTIC_BACKUP_RETAIN_MONTHLY=3

# ====================================================================
# FUNKTIONEN
# ====================================================================

# Sicherstellen, dass das System bereit ist
function check_system_ready() {
  local failed=0
  
  # Prüfe Abhängigkeiten
  for cmd in apache2 mysql wp jq curl dig certbot; do
    if ! command -v "$cmd" &> /dev/null; then
      log "ERROR" "Befehl '$cmd' nicht gefunden - notwendig für Website Engine"
      failed=1
    else
      log "INFO" "Befehl '$cmd' gefunden"
    fi
  done
  
  # Prüfe Verzeichnisse und Rechte
  for dir in "$CONFIG_DIR" "$DATA_DIR" "$BACKUP_DIR" "$WP_DIR"; do
    if [[ ! -d "$dir" ]]; then
      # Versuche, fehlende Verzeichnisse automatisch zu erstellen
      log "WARNING" "Verzeichnis '$dir' nicht gefunden - versuche es zu erstellen"
      if sudo mkdir -p "$dir" 2>/dev/null; then
        # Setze korrekte Berechtigungen
        sudo chown www-data:www-data "$dir" 2>/dev/null || true
        log "SUCCESS" "Verzeichnis '$dir' erfolgreich erstellt"
      else
        log "ERROR" "Konnte Verzeichnis '$dir' nicht erstellen - benötige root-Rechte"
        failed=1
      fi
    else
      log "INFO" "Verzeichnis '$dir' existiert"
    fi
  done
  
  # Prüfe SSL-Zertifikate
  if [[ ! -f "$SSL_CERT_PATH" ]]; then
    log "ERROR" "SSL-Zertifikat '$SSL_CERT_PATH' nicht gefunden"
    log "ERROR" "Bitte führe zuerst das SSL-Setup durch: setup-server.sh"
    failed=1
  else
    # Prüfe Gültigkeit
    local cert_end_date=$(openssl x509 -in "$SSL_CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -n "$cert_end_date" ]]; then
      local cert_end_epoch=$(date -d "$cert_end_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$cert_end_date" +%s 2>/dev/null)
      local now_epoch=$(date +%s)
      local days_left=$(( (cert_end_epoch - now_epoch) / 86400 ))
      
      if [[ $days_left -lt 0 ]]; then
        log "ERROR" "SSL-Zertifikat ist abgelaufen!"
        failed=1
      elif [[ $days_left -lt 15 ]]; then
        log "WARNING" "SSL-Zertifikat läuft in $days_left Tagen ab!"
      else
        log "INFO" "SSL-Zertifikat ist gültig für weitere $days_left Tage"
      fi
    else
      log "ERROR" "SSL-Zertifikat konnte nicht überprüft werden"
      failed=1
    fi
  fi
  
  # Prüfe Dienste
  for service in apache2 mysql; do
    if ! systemctl is-active --quiet "$service"; then
      log "ERROR" "Dienst '$service' läuft nicht"
      failed=1
    else
      log "INFO" "Dienst '$service' läuft"
    fi
  done
  
  # Rückgabe
  if [[ $failed -eq 1 ]]; then
    log "ERROR" "Systemprüfung fehlgeschlagen"
    return 1
  fi
  
  log "INFO" "Systemprüfung erfolgreich"
  return 0
}

# Laden von Umgebungsvariablen
function load_env_vars() {
  # Cloudflare-Variablen
  if [[ -f "/etc/profile.d/cloudflare.sh" ]]; then
    source "/etc/profile.d/cloudflare.sh"
    log "INFO" "Cloudflare-Konfiguration geladen"
  else
    log "WARNING" "Cloudflare-Konfiguration nicht gefunden: /etc/profile.d/cloudflare.sh"
  fi
  
  # WordPress-Anmeldedaten
  if [[ -f "$CONFIG_DIR/credentials.env" ]]; then
    source "$CONFIG_DIR/credentials.env"
    log "INFO" "WordPress-Anmeldedaten geladen"
  else
    log "WARNING" "WordPress-Anmeldedaten nicht gefunden: $CONFIG_DIR/credentials.env"
    # Fallback zu sicheren Standards
    export DB_USER=${DB_USER:-"website-admin"}
    export DB_PASS=${DB_PASS:-$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | cut -c1-20)}
    export WP_USER=${WP_USER:-"admin"}
    export WP_PASS=${WP_PASS:-$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | cut -c1-20)}
    
    log "INFO" "Standard-Anmeldedaten generiert (temporär)"
  fi
}

# Überprüfe, ob alle erforderlichen Umgebungsvariablen gesetzt sind
function check_env_vars() {
  local missing=0
  
  # Cloudflare-Variablen
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    log "ERROR" "CF_API_TOKEN ist nicht gesetzt"
    missing=1
  fi
  
  if [[ -z "${ZONE_ID:-}" ]]; then
    log "ERROR" "ZONE_ID ist nicht gesetzt"
    missing=1
  fi
  
  # WordPress-Anmeldedaten
  if [[ -z "${DB_USER:-}" ]]; then
    log "ERROR" "DB_USER ist nicht gesetzt"
    missing=1
  fi
  
  if [[ -z "${DB_PASS:-}" ]]; then
    log "ERROR" "DB_PASS ist nicht gesetzt"
    missing=1
  fi
  
  if [[ -z "${WP_USER:-}" ]]; then
    log "ERROR" "WP_USER ist nicht gesetzt"
    missing=1
  fi
  
  if [[ -z "${WP_PASS:-}" ]]; then
    log "ERROR" "WP_PASS ist nicht gesetzt"
    missing=1
  fi
  
  # Rückgabe
  if [[ $missing -eq 1 ]]; then
    log "ERROR" "Erforderliche Umgebungsvariablen fehlen"
    return 1
  fi
  
  log "INFO" "Alle erforderlichen Umgebungsvariablen sind gesetzt"
  return 0
}

# Erzeugen eines sicheren Passworts
function generate_secure_password() {
  local length=${1:-20}
  openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | cut -c1-"$length"
}

# Konfiguriere Backup-Systeme (IONOS und Restic)
function configure_backup_systems() {
  local config_changed=0

  # Prüfen und erstellen des Backup-Konfigurationsverzeichnisses
  if [[ ! -d "$CONFIG_DIR/backup" ]]; then
    mkdir -p "$CONFIG_DIR/backup"
    chmod 750 "$CONFIG_DIR/backup"
    log "INFO" "Backup-Konfigurationsverzeichnis erstellt: $CONFIG_DIR/backup"
  fi

  # IONOS-Konfiguration
  local ionos_config="$CONFIG_DIR/backup/ionos.env"
  local should_configure_ionos=0

  if [[ ! -f "$ionos_config" ]]; then
    should_configure_ionos=1
    touch "$ionos_config"
    chmod 600 "$ionos_config"
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
    echo "ℹ️ IONOS-Konfiguration bereits vorhanden."
  fi

  # Restic-Konfiguration
  local restic_config="$CONFIG_DIR/backup/restic.env"
  local should_configure_restic=0

  if [[ ! -f "$restic_config" ]]; then
    should_configure_restic=1
    touch "$restic_config"
    chmod 600 "$restic_config"
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
      restic_pwd=$(generate_secure_password 32)
      echo "Generiertes Passwort: $restic_pwd"
      echo "⚠️ WICHTIG: Speichern Sie dieses Passwort sicher ab!"
    fi
    
    # S3 Credentials abfragen
    local aws_access_key=""
    read -p "S3 Access Key ID: " aws_access_key
    
    local aws_secret_key=""
    read -p "S3 Secret Access Key: " aws_secret_key

    # Konfigurationsdatei erstellen
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
    echo "ℹ️ Restic-Konfiguration bereits vorhanden."
  fi

  # Wenn Konfiguration geändert wurde, ermutigen wir zu einem Test-Backup
  if [[ $config_changed -eq 1 ]]; then
    echo
    echo "==============================================================="
    echo "✅ Backup-Konfiguration abgeschlossen"
    echo "==============================================================="
    echo "Die Backup-Systeme wurden konfiguriert. Es wird empfohlen,"
    echo "jetzt einen Test-Backup durchzuführen:"
    echo "  - MySQL-Backup: backup/mysql-backup.sh"
    echo "  - Restic-Backup: backup/restic-backup.sh"
    echo "  - IONOS-Snapshot: backup/ionos-snapshot.sh"
    echo "  - Alle Backups: backup/backup-all.sh"
    echo
  fi

  return 0
}

# Konfiguriere Backup-Systeme (IONOS und Restic)
function configure_backup_systems() {
  local config_changed=0

  # Prüfen und erstellen des Backup-Konfigurationsverzeichnisses
  if [[ ! -d "$CONFIG_DIR/backup" ]]; then
    mkdir -p "$CONFIG_DIR/backup"
    chmod 750 "$CONFIG_DIR/backup"
    log "INFO" "Backup-Konfigurationsverzeichnis erstellt: $CONFIG_DIR/backup"
  fi

  # IONOS-Konfiguration
  local ionos_config="$CONFIG_DIR/backup/ionos.env"
  local should_configure_ionos=0

  if [[ ! -f "$ionos_config" ]]; then
    should_configure_ionos=1
    touch "$ionos_config"
    chmod 600 "$ionos_config"
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
    echo "ℹ️ IONOS-Konfiguration bereits vorhanden."
  fi

  # Restic-Konfiguration
  local restic_config="$CONFIG_DIR/backup/restic.env"
  local should_configure_restic=0

  if [[ ! -f "$restic_config" ]]; then
    should_configure_restic=1
    touch "$restic_config"
    chmod 600 "$restic_config"
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
      restic_pwd=$(generate_secure_password 32)
      echo "Generiertes Passwort: $restic_pwd"
      echo "⚠️ WICHTIG: Speichern Sie dieses Passwort sicher ab!"
    fi
    
    # S3 Credentials abfragen
    local aws_access_key=""
    read -p "S3 Access Key ID: " aws_access_key
    
    local aws_secret_key=""
    read -p "S3 Secret Access Key: " aws_secret_key

    # Konfigurationsdatei erstellen
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
    echo "ℹ️ Restic-Konfiguration bereits vorhanden."
  fi

  # Wenn Konfiguration geändert wurde, ermutigen wir zu einem Test-Backup
  if [[ $config_changed -eq 1 ]]; then
    echo
    echo "==============================================================="
    echo "✅ Backup-Konfiguration abgeschlossen"
    echo "==============================================================="
    echo "Die Backup-Systeme wurden konfiguriert. Es wird empfohlen,"
    echo "jetzt einen Test-Backup durchzuführen:"
    echo "  - MySQL-Backup: backup/mysql-backup.sh"
    echo "  - Restic-Backup: backup/restic-backup.sh"
    echo "  - IONOS-Snapshot: backup/ionos-snapshot.sh"
    echo "  - Alle Backups: backup/backup-all.sh"
    echo
  fi

  return 0
}

# Lade Anmeldedaten und Konfiguration
load_env_vars