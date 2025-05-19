#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# RESTIC S3-KONFIGURATION EINRICHTEN
# ====================================================================

# Farbige Ausgabe
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Banner anzeigen
echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}🚀 WEBSITE ENGINE - RESTIC S3-KONFIGURATION${NC}"
echo -e "${BLUE}🕒 Startzeit: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}=====================================================================${NC}"

# Konfigurationsverzeichnis 
CONFIG_DIR="/etc/website-engine/backup"
RESTIC_ENV="$CONFIG_DIR/restic.env"

# Überprüfe, ob das Verzeichnis existiert
if [[ ! -d "$CONFIG_DIR" ]]; then
  echo -e "${YELLOW}Das Konfigurationsverzeichnis existiert nicht, wird erstellt...${NC}"
  mkdir -p "$CONFIG_DIR"
  chmod 750 "$CONFIG_DIR"
fi

# Erstelle eine leere Konfigurationsdatei oder verwende bestehende
touch "$RESTIC_ENV"
chmod 600 "$RESTIC_ENV"

# Frage nach S3-Konfiguration
echo
echo -e "${BLUE}S3-KONFIGURATION${NC}"
echo "====================================================================="
echo "Bitte geben Sie die erforderlichen S3-Informationen ein."
echo

# Abfrage der S3-Zugangsdaten
read -p "S3 Access Key ID: " ACCESS_KEY
read -p "S3 Secret Access Key: " SECRET_KEY
read -p "S3 Endpoint [s3.eu-central-3.ionoscloud.com]: " S3_ENDPOINT
S3_ENDPOINT=${S3_ENDPOINT:-"s3.eu-central-3.ionoscloud.com"}

read -p "S3 Bucket-Name: " S3_BUCKET

# Standardpfade für verschiedene Backup-Typen
read -p "Pfad für Restic-Repository im Bucket [restic]: " RESTIC_PATH
RESTIC_PATH=${RESTIC_PATH:-"restic"}

read -p "Pfad für MySQL-Backups im Bucket [mysql]: " MYSQL_PATH
MYSQL_PATH=${MYSQL_PATH:-"mysql"}

# Restic-Passwort
read -p "Restic-Repository-Passwort (leer für Auto-Generierung): " RESTIC_PWD
if [[ -z "$RESTIC_PWD" ]]; then
  # Einfache Passwortgenerierung
  RESTIC_PWD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
  echo -e "${GREEN}Generiertes Passwort: $RESTIC_PWD${NC}"
  echo -e "${YELLOW}⚠️ WICHTIG: Speichern Sie dieses Passwort sicher ab!${NC}"
fi

# Baue das korrekte Repository-Format
RESTIC_REPO="s3:$S3_ENDPOINT/$S3_BUCKET/$RESTIC_PATH"
echo
echo -e "${BLUE}Repository-URL:${NC} $RESTIC_REPO"
echo -e "${YELLOW}Hinweis: Die korrekte Syntax für S3 ist 's3:s3.example.com/bucket/path' (ohne https://)${NC}"
echo

# Schreibe die Konfiguration
cat > "$RESTIC_ENV" << EOL
# S3 und Restic-Konfiguration
# Erstellt am $(date +%Y-%m-%d)

# S3-Zugangsdaten
export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"

# S3-Konfiguration
export S3_ENDPOINT="$S3_ENDPOINT"
export S3_BUCKET="$S3_BUCKET"
export S3_PATH_RESTIC="$RESTIC_PATH"
export S3_PATH_MYSQL="$MYSQL_PATH"

# Restic-Konfiguration - WICHTIG: Die korrekte Syntax für S3 ist:
# s3:s3.example.com/bucket-name/path (OHNE https://)
export RESTIC_REPOSITORY="$RESTIC_REPO"
export RESTIC_PASSWORD="$RESTIC_PWD"
EOL

echo -e "${GREEN}✅ Konfiguration gespeichert in $RESTIC_ENV${NC}"

# Lade die Konfiguration
source "$RESTIC_ENV"

# Initialisiere das Repository
echo
echo -e "${BLUE}REPOSITORY-INITIALISIERUNG${NC}"
echo "====================================================================="

# Prüfe, ob restic installiert ist
if ! command -v restic &> /dev/null; then
  echo -e "${RED}❌ FEHLER: Restic ist nicht installiert${NC}"
  echo "Installieren Sie Restic mit: apt-get install restic"
  exit 1
fi

echo "Versuche, auf das Repository zuzugreifen..."
if restic snapshots &>/dev/null; then
  echo -e "${GREEN}✅ Repository ist bereits initialisiert und zugänglich${NC}"
else
  echo "Repository existiert noch nicht. Initialisiere..."
  if restic init; then
    echo -e "${GREEN}✅ Repository erfolgreich initialisiert!${NC}"
  else
    echo -e "${RED}❌ Fehler bei der Repository-Initialisierung${NC}"
    echo
    echo "Häufige Probleme:"
    echo "1. Falsches Repository-Format. Stellen Sie sicher, dass die URL korrekt ist."
    echo "2. Fehlende S3-Bucket-Berechtigungen oder nicht existierender Bucket."
    echo "3. Falsche S3-Zugangsdaten."
    echo
    echo "Prüfen Sie die Konfiguration und versuchen Sie es erneut."
    exit 1
  fi
fi

# Abschluss
echo
echo -e "${BLUE}=====================================================================${NC}"
echo -e "${GREEN}🏁 RESTIC S3-KONFIGURATION ABGESCHLOSSEN${NC}"
echo -e "${BLUE}🕒 Endzeit: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BLUE}=====================================================================${NC}"

echo
echo "Nächste Schritte:"
echo "1. Führen Sie ein Test-Backup durch: ./backup-all.sh --restic"
echo "2. Prüfen Sie, ob das Backup im S3-Bucket erscheint"
echo "3. Testen Sie die Wiederherstellung: ./restore.sh --list-restic"

exit 0