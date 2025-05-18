#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# WIEDERHERSTELLUNG VON BACKUPS
# ====================================================================

# Import config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$(dirname "$SCRIPT_DIR")/modules"
source "$MODULES_DIR/config.sh"

# Zeige Verwendung an
usage() {
  echo "Verwendung: $0 [Optionen]"
  echo
  echo "Stellt Backups der Website Engine wieder her."
  echo
  echo "Optionen:"
  echo "  --mysql [Datei]     MySQL-Backup wiederherstellen (erforderlich für Datenbank-Wiederherstellung)"
  echo "  --restic [ID|Tag]   Restic-Backup wiederherstellen (erforderlich für Datei-Wiederherstellung)"
  echo "  --target [Pfad]     Zielverzeichnis für Restic-Wiederherstellung (Standard: /tmp/restore)"
  echo "  --list-mysql        Verfügbare MySQL-Backups auflisten"
  echo "  --list-restic       Verfügbare Restic-Snapshots auflisten"
  echo "  --only-site=SUB     Nur Backup für eine bestimmte Subdomain wiederherstellen"
  echo "  --dry-run           Nur anzeigen, was getan würde, ohne Änderungen vorzunehmen"
  echo "  --help              Diese Hilfe anzeigen"
  echo
  echo "Beispiele:"
  echo "  $0 --mysql /var/backups/mysql/backup-2023-05-14.sql.gz            # MySQL-Backup wiederherstellen"
  echo "  $0 --restic latest --target /tmp/restore                           # Letztes Restic-Backup wiederherstellen"
  echo "  $0 --only-site=kunde1 --restic latest                             # Nur eine bestimmte Site wiederherstellen"
  echo "  $0 --list-mysql                                                   # Verfügbare MySQL-Backups auflisten"
  echo "  $0 --list-restic                                                  # Verfügbare Restic-Snapshots auflisten"
  exit 1
}

# Initialisiere Optionen
MYSQL_BACKUP=""
RESTIC_BACKUP=""
TARGET_DIR="/tmp/restore-$(date +%F-%H%M)"
ONLY_SITE=""
DRY_RUN=0
LIST_MYSQL=0
LIST_RESTIC=0

# Parse Argumente
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mysql)
      shift
      if [[ $# -eq 0 || "$1" == --* ]]; then
        echo "❌ Fehler: --mysql erfordert einen Dateipfad"
        usage
      fi
      MYSQL_BACKUP="$1"
      shift
      ;;
    --restic)
      shift
      if [[ $# -eq 0 || "$1" == --* ]]; then
        echo "❌ Fehler: --restic erfordert eine Snapshot-ID oder ein Tag"
        usage
      fi
      RESTIC_BACKUP="$1"
      shift
      ;;
    --target)
      shift
      if [[ $# -eq 0 || "$1" == --* ]]; then
        echo "❌ Fehler: --target erfordert einen Verzeichnispfad"
        usage
      fi
      TARGET_DIR="$1"
      shift
      ;;
    --only-site=*)
      ONLY_SITE="${1#*=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --list-mysql)
      LIST_MYSQL=1
      shift
      ;;
    --list-restic)
      LIST_RESTIC=1
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

# Zeige Banner an
echo "====================================================================="
echo "🚀 WEBSITE ENGINE - BACKUP-WIEDERHERSTELLUNG"
echo "🕒 Startzeit: $(date '+%Y-%m-%d %H:%M:%S')"
echo "====================================================================="
log "INFO" "Starte Backup-Wiederherstellung..."

# Status-Funktion
status_msg() {
  local level="$1"
  local msg="$2"
  echo "[$level] $msg"
  log "$level" "$msg"
}

# MySQL-Backups auflisten
if [[ $LIST_MYSQL -eq 1 ]]; then
  echo "📋 VERFÜGBARE MYSQL-BACKUPS"
  echo "--------------------------------------------------------------------"
  
  if [[ -d "$MYSQL_BACKUP_DIR" ]]; then
    # Anzahl der Backups zählen
    backup_count=$(find "$MYSQL_BACKUP_DIR" -type f -name "*.sql.gz" | wc -l)
    
    if [[ $backup_count -eq 0 ]]; then
      echo "❌ Keine MySQL-Backups gefunden in: $MYSQL_BACKUP_DIR"
    else
      echo "🗂️ Gefunden: $backup_count Backups in $MYSQL_BACKUP_DIR"
      echo
      
      # Backups mit Details auflisten
      echo "DATUM       | GRÖSSE  | DATEINAME"
      echo "------------------------------------------------------------------------"
      find "$MYSQL_BACKUP_DIR" -type f -name "*.sql.gz" | sort -r | while read -r backup; do
        size=$(du -h "$backup" | cut -f1)
        date=$(basename "$backup" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo "Unknown")
        name=$(basename "$backup")
        printf "%-10s | %-7s | %s\n" "$date" "$size" "$name"
      done
    fi
  else
    echo "❌ MySQL-Backup-Verzeichnis nicht gefunden: $MYSQL_BACKUP_DIR"
  fi
  
  exit 0
fi

# Restic-Snapshots auflisten
if [[ $LIST_RESTIC -eq 1 ]]; then
  echo "📋 VERFÜGBARE RESTIC-SNAPSHOTS"
  echo "--------------------------------------------------------------------"
  
  # Lade Restic-Umgebung
  RESTIC_ENV_FILE="/etc/website-engine/backup/restic.env"
  if [[ -f "$RESTIC_ENV_FILE" ]]; then
    source "$RESTIC_ENV_FILE"
    
    # Versuche, Snapshots aufzulisten
    if ! restic snapshots; then
      echo "❌ Fehler beim Auflisten der Restic-Snapshots."
      echo "   Bitte stellen Sie sicher, dass die Repository-Konfiguration korrekt ist."
      exit 1
    fi
  else
    echo "❌ Restic-Konfigurationsdatei nicht gefunden: $RESTIC_ENV_FILE"
    exit 1
  fi
  
  exit 0
fi

# Prüfe, ob alle erforderlichen Optionen angegeben wurden
if [[ -z "$MYSQL_BACKUP" && -z "$RESTIC_BACKUP" ]]; then
  echo "❌ Fehler: Mindestens eine der Optionen --mysql oder --restic muss angegeben werden."
  usage
fi

# MySQL-Backup wiederherstellen
if [[ -n "$MYSQL_BACKUP" ]]; then
  echo
  echo "🔄 MYSQL-BACKUP WIEDERHERSTELLEN"
  echo "--------------------------------------------------------------------"
  
  # Prüfe, ob die Backup-Datei existiert
  if [[ ! -f "$MYSQL_BACKUP" ]]; then
    status_msg "ERROR" "MySQL-Backup-Datei nicht gefunden: $MYSQL_BACKUP"
    echo "❌ Fehler: MySQL-Backup-Datei nicht gefunden: $MYSQL_BACKUP"
    echo "   Verwenden Sie --list-mysql, um verfügbare Backups aufzulisten."
    exit 1
  fi
  
  # Site-spezifische Wiederherstellung oder alles
  if [[ -n "$ONLY_SITE" ]]; then
    status_msg "INFO" "MySQL-Wiederherstellung nur für Subdomain $ONLY_SITE"
    
    # Lade DB-Infos für die Site
    DB_INFO_FILE="$CONFIG_DIR/sites/${ONLY_SITE}/db-info.env"
    if [[ -f "$DB_INFO_FILE" ]]; then
      source "$DB_INFO_FILE"
      
      status_msg "INFO" "Stelle Datenbank $DB_NAME aus $MYSQL_BACKUP wieder her"
      
      if [[ $DRY_RUN -eq 1 ]]; then
        echo "🔍 [DRY RUN] MySQL-Wiederherstellung für $ONLY_SITE: $DB_NAME"
        echo "   Befehl: gunzip -c $MYSQL_BACKUP | mysql -u root $DB_NAME"
      else
        echo "⚠️ ACHTUNG: Bestehende Datenbank $DB_NAME wird überschrieben!"
        echo -n "❓ Fortfahren? (j/n): "
        read -r REPLY
        if [[ ! "$REPLY" =~ ^[jJyY]$ ]]; then
          echo "❌ MySQL-Wiederherstellung abgebrochen."
          exit 0
        fi
        
        # Führe Wiederherstellung durch
        if ! gunzip -c "$MYSQL_BACKUP" | grep -v "CREATE DATABASE" | grep -v "USE \`" | mysql -u root "$DB_NAME"; then
          status_msg "ERROR" "Fehler bei der MySQL-Wiederherstellung für $DB_NAME"
          echo "❌ Fehler bei der MySQL-Wiederherstellung für $DB_NAME"
          exit 1
        else
          status_msg "SUCCESS" "MySQL-Wiederherstellung für $DB_NAME abgeschlossen"
          echo "✅ MySQL-Wiederherstellung für $DB_NAME erfolgreich abgeschlossen"
        fi
      fi
    else
      status_msg "ERROR" "Keine Datenbank-Informationen für Subdomain $ONLY_SITE gefunden"
      echo "❌ Fehler: Keine Datenbank-Informationen für $ONLY_SITE gefunden"
      exit 1
    fi
  else
    # Alles wiederherstellen
    status_msg "INFO" "Stelle alle Datenbanken aus $MYSQL_BACKUP wieder her"
    
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "🔍 [DRY RUN] MySQL-Wiederherstellung für alle Datenbanken"
      echo "   Befehl: gunzip -c $MYSQL_BACKUP | mysql -u root"
    else
      echo "⚠️ ACHTUNG: Alle bestehenden Datenbanken werden überschrieben!"
      echo "   Dies ist ein potenziell destruktiver Vorgang."
      echo -n "❓ Sind Sie ABSOLUT sicher? (j/n): "
      read -r REPLY
      if [[ ! "$REPLY" =~ ^[jJyY]$ ]]; then
        echo "❌ MySQL-Wiederherstellung abgebrochen."
        exit 0
      fi
      
      # Zweite Bestätigung
      echo -n "❓ Wirklich alle Datenbanken überschreiben? Letzte Warnung! (j/n): "
      read -r REPLY
      if [[ ! "$REPLY" =~ ^[jJyY]$ ]]; then
        echo "❌ MySQL-Wiederherstellung abgebrochen."
        exit 0
      fi
      
      # Führe Wiederherstellung durch
      if ! gunzip -c "$MYSQL_BACKUP" | mysql -u root; then
        status_msg "ERROR" "Fehler bei der MySQL-Wiederherstellung"
        echo "❌ Fehler bei der MySQL-Wiederherstellung"
        exit 1
      else
        status_msg "SUCCESS" "MySQL-Wiederherstellung abgeschlossen"
        echo "✅ MySQL-Wiederherstellung erfolgreich abgeschlossen"
      fi
    fi
  fi
fi

# Restic-Backup wiederherstellen
if [[ -n "$RESTIC_BACKUP" ]]; then
  echo
  echo "🔄 RESTIC-BACKUP WIEDERHERSTELLEN"
  echo "--------------------------------------------------------------------"
  
  # Lade Restic-Umgebung
  RESTIC_ENV_FILE="/etc/website-engine/backup/restic.env"
  if [[ ! -f "$RESTIC_ENV_FILE" ]]; then
    status_msg "ERROR" "Restic-Konfigurationsdatei nicht gefunden: $RESTIC_ENV_FILE"
    echo "❌ Fehler: Restic-Konfigurationsdatei nicht gefunden: $RESTIC_ENV_FILE"
    exit 1
  fi
  
  source "$RESTIC_ENV_FILE"
  
  # Prüfe, ob das Repository erreichbar ist
  if ! restic snapshots &>/dev/null; then
    status_msg "ERROR" "Konnte nicht auf Restic-Repository zugreifen"
    echo "❌ Fehler: Konnte nicht auf Restic-Repository zugreifen."
    echo "   Bitte stellen Sie sicher, dass die Repository-Konfiguration korrekt ist."
    exit 1
  fi
  
  # Erstelle Zielverzeichnis, wenn es nicht existiert
  if [[ ! -d "$TARGET_DIR" && $DRY_RUN -eq 0 ]]; then
    mkdir -p "$TARGET_DIR"
  fi
  
  # Site-spezifische Wiederherstellung oder alles
  RESTORE_PATHS=()
  
  if [[ -n "$ONLY_SITE" ]]; then
    status_msg "INFO" "Restic-Wiederherstellung nur für Subdomain $ONLY_SITE"
    
    SITE_PATH="${WP_DIR}/${ONLY_SITE}"
    RESTORE_PATHS+=("$SITE_PATH")
    
    # Baue --include-Parameter für Restic
    INCLUDE_OPTS=(--include "$SITE_PATH")
    
    status_msg "INFO" "Stelle Dateien für $ONLY_SITE aus Snapshot $RESTIC_BACKUP nach $TARGET_DIR wieder her"
    
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "🔍 [DRY RUN] Restic-Wiederherstellung für $ONLY_SITE"
      echo "   Befehl: restic restore $RESTIC_BACKUP --target $TARGET_DIR ${INCLUDE_OPTS[*]}"
    else
      echo "ℹ️ Stelle Dateien aus Snapshot $RESTIC_BACKUP nach $TARGET_DIR wieder her"
      echo -n "❓ Fortfahren? (j/n): "
      read -r REPLY
      if [[ ! "$REPLY" =~ ^[jJyY]$ ]]; then
        echo "❌ Restic-Wiederherstellung abgebrochen."
        exit 0
      fi
      
      # Führe Wiederherstellung durch
      if ! restic restore "$RESTIC_BACKUP" --target "$TARGET_DIR" "${INCLUDE_OPTS[@]}"; then
        status_msg "ERROR" "Fehler bei der Restic-Wiederherstellung für $ONLY_SITE"
        echo "❌ Fehler bei der Restic-Wiederherstellung für $ONLY_SITE"
        exit 1
      else
        status_msg "SUCCESS" "Restic-Wiederherstellung für $ONLY_SITE abgeschlossen"
        echo "✅ Restic-Wiederherstellung für $ONLY_SITE erfolgreich abgeschlossen"
        echo "   Wiederhergestellte Dateien befinden sich in: $TARGET_DIR$SITE_PATH"
      fi
    fi
  else
    # Alles wiederherstellen
    status_msg "INFO" "Stelle alle Dateien aus Snapshot $RESTIC_BACKUP nach $TARGET_DIR wieder her"
    
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "🔍 [DRY RUN] Restic-Wiederherstellung für alle Dateien"
      echo "   Befehl: restic restore $RESTIC_BACKUP --target $TARGET_DIR"
    else
      echo "ℹ️ Stelle alle Dateien aus Snapshot $RESTIC_BACKUP nach $TARGET_DIR wieder her"
      echo -n "❓ Fortfahren? (j/n): "
      read -r REPLY
      if [[ ! "$REPLY" =~ ^[jJyY]$ ]]; then
        echo "❌ Restic-Wiederherstellung abgebrochen."
        exit 0
      fi
      
      # Führe Wiederherstellung durch
      if ! restic restore "$RESTIC_BACKUP" --target "$TARGET_DIR"; then
        status_msg "ERROR" "Fehler bei der Restic-Wiederherstellung"
        echo "❌ Fehler bei der Restic-Wiederherstellung"
        exit 1
      else
        status_msg "SUCCESS" "Restic-Wiederherstellung abgeschlossen"
        echo "✅ Restic-Wiederherstellung erfolgreich abgeschlossen"
        echo "   Wiederhergestellte Dateien befinden sich in: $TARGET_DIR"
      fi
    fi
  fi
fi

# Abschluss
echo
echo "====================================================================="
echo "🏁 WIEDERHERSTELLUNG ABGESCHLOSSEN"
echo "🕒 Endzeit: $(date '+%Y-%m-%d %H:%M:%S')"
echo "====================================================================="
log "SUCCESS" "Backup-Wiederherstellung abgeschlossen"

exit 0