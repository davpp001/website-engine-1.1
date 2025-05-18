#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# IONOS VOLUME SNAPSHOT ERSTELLEN
# ====================================================================

# Import config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$(dirname "$SCRIPT_DIR")/modules"
source "$MODULES_DIR/config.sh"

# Konfiguration
CONFIG_FILE="/etc/website-engine/backup/ionos.env"
DEFAULT_DESCRIPTION="Automatisches Backup vom $(date +%Y-%m-%d)"

# Zeige Verwendung an
usage() {
  echo "Verwendung: $0 [--description \"Beschreibung\"]"
  echo
  echo "Erstellt einen Snapshot des IONOS Cloud-Volumes."
  echo
  echo "Optionen:"
  echo "  --description \"Text\"  Benutzerdefinierte Beschreibung für den Snapshot"
  echo "  --help                 Diese Hilfe anzeigen"
  echo
  echo "Umgebungsvariablen (auch in $CONFIG_FILE konfigurierbar):"
  echo "  IONOS_TOKEN            IONOS API-Token für die Authentifizierung"
  echo "  IONOS_SERVER_ID        ID des Servers"
  echo "  IONOS_VOLUME_ID        ID des Volumes"
  echo "  IONOS_DATACENTER_ID    ID des Rechenzentrums (optional)"
  echo
  exit 1
}

# Parse Argumente
DESCRIPTION="$DEFAULT_DESCRIPTION"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --description)
      shift
      DESCRIPTION="$1"
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

# Lade Konfiguration
if [[ -f "$CONFIG_FILE" ]]; then
  log "INFO" "Lade IONOS-Konfiguration aus $CONFIG_FILE"
  source "$CONFIG_FILE"
else
  log "WARNING" "IONOS-Konfigurationsdatei $CONFIG_FILE nicht gefunden."
  log "WARNING" "Verwende Umgebungsvariablen, falls vorhanden."
fi

# Prüfe notwendige Umgebungsvariablen
if [[ -z "${IONOS_TOKEN:-}" ]]; then
  log "ERROR" "IONOS_TOKEN ist nicht gesetzt. Bitte in $CONFIG_FILE oder als Umgebungsvariable konfigurieren."
  echo "❌ Fehler: IONOS API-Token fehlt. Bitte konfigurieren Sie IONOS_TOKEN."
  exit 1
fi

if [[ -z "${IONOS_SERVER_ID:-}" ]]; then
  log "ERROR" "IONOS_SERVER_ID ist nicht gesetzt. Bitte in $CONFIG_FILE oder als Umgebungsvariable konfigurieren."
  echo "❌ Fehler: IONOS Server-ID fehlt. Bitte konfigurieren Sie IONOS_SERVER_ID."
  exit 1
fi

if [[ -z "${IONOS_VOLUME_ID:-}" ]]; then
  log "ERROR" "IONOS_VOLUME_ID ist nicht gesetzt. Bitte in $CONFIG_FILE oder als Umgebungsvariable konfigurieren."
  echo "❌ Fehler: IONOS Volume-ID fehlt. Bitte konfigurieren Sie IONOS_VOLUME_ID."
  exit 1
fi

# Wähle die richtige API-Version und Endpunkt
API_VERSION="v6"
if [[ -n "${IONOS_API_VERSION:-}" ]]; then
  API_VERSION="$IONOS_API_VERSION"
  log "INFO" "Verwende API-Version $API_VERSION aus Konfiguration"
fi

API_ENDPOINT="https://api.ionos.com/cloudapi/$API_VERSION"
log "INFO" "Verwende API-Endpunkt: $API_ENDPOINT"

# Bestimme API-Pfad basierend auf Verfügbarkeit von DATACENTER_ID
API_PATH=""
if [[ -n "${IONOS_DATACENTER_ID:-}" ]]; then
  # Neuer Pfad für API v6
  API_PATH="datacenters/${IONOS_DATACENTER_ID}/servers/${IONOS_SERVER_ID}/volumes/${IONOS_VOLUME_ID}/create-snapshot"
  log "INFO" "Verwende API v6 Pfad mit Datacenter-ID"
else
  # Legacy-Pfad für API v5
  API_PATH="servers/${IONOS_SERVER_ID}/volumes/${IONOS_VOLUME_ID}/create-snapshot"
  log "INFO" "Verwende Legacy API v5 Pfad ohne Datacenter-ID"
fi

# Name für den Snapshot erzeugen
SNAPSHOT_NAME="snapshot-$(date +%Y-%m-%d-%H%M)"

echo "📦 Erstelle IONOS Volume-Snapshot: $SNAPSHOT_NAME..."
log "INFO" "Erstelle IONOS Volume-Snapshot: $SNAPSHOT_NAME mit Beschreibung: $DESCRIPTION"

# API-Aufruf mit Wiederholungsversuchen
MAX_RETRIES=3
RETRY_WAIT=5
SUCCESS=0
RESPONSE=""

for ((i=1; i<=MAX_RETRIES; i++)); do
  log "INFO" "API-Aufruf-Versuch $i von $MAX_RETRIES"
  
  RESPONSE=$(curl -s -X POST \
    "${API_ENDPOINT}/${API_PATH}" \
    -H "Authorization: Bearer ${IONOS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "name":"'"${SNAPSHOT_NAME}"'",
      "description":"'"${DESCRIPTION}"'"
    }' 2>&1)
  
  # Prüfe auf Fehler im Response
  if echo "$RESPONSE" | grep -q "requestId"; then
    REQUEST_ID=$(echo "$RESPONSE" | grep -oP '"requestId":\s*"\K[^"]+')
    log "SUCCESS" "Snapshot-Erstellung gestartet mit Request-ID: $REQUEST_ID"
    SUCCESS=1
    break
  else
    # Fehlerfall
    ERROR_MSG=$(echo "$RESPONSE" | grep -oP '"message":\s*"\K[^"]+' || echo "Unbekannter Fehler")
    log "WARNING" "Versuch $i fehlgeschlagen: $ERROR_MSG"
    
    if [[ $i -lt $MAX_RETRIES ]]; then
      log "INFO" "Warte $RETRY_WAIT Sekunden vor dem nächsten Versuch..."
      sleep $RETRY_WAIT
    fi
  fi
done

if [[ $SUCCESS -eq 1 ]]; then
  echo "✅ IONOS Volume-Snapshot erfolgreich erstellt: $SNAPSHOT_NAME"
  log "SUCCESS" "IONOS Volume-Snapshot erfolgreich erstellt: $SNAPSHOT_NAME"
  
  # Prüfe Status der Anfrage, falls Request-ID vorhanden
  if [[ -n "${REQUEST_ID:-}" ]]; then
    echo "🔍 Prüfe Status der Snapshot-Erstellung..."
    log "INFO" "Prüfe Status der Request-ID: $REQUEST_ID"
    
    sleep 5 # Kurze Pause, damit die Anfrage verarbeitet werden kann
    
    STATUS_RESPONSE=$(curl -s -X GET \
      "${API_ENDPOINT}/requests/${REQUEST_ID}" \
      -H "Authorization: Bearer ${IONOS_TOKEN}" \
      -H "Accept: application/json" 2>&1)
    
    STATUS=$(echo "$STATUS_RESPONSE" | grep -oP '"status":\s*"\K[^"]+' || echo "unbekannt")
    log "INFO" "Request-Status: $STATUS"
    
    if [[ "$STATUS" == "DONE" ]]; then
      echo "✅ Snapshot-Erstellung abgeschlossen"
    else
      echo "⏳ Snapshot-Erstellung läuft (Status: $STATUS)"
      echo "   Die Verarbeitung wird im Hintergrund fortgesetzt."
    fi
  fi
  
  exit 0
else
  echo "❌ Fehler bei der Erstellung des IONOS Volume-Snapshots"
  log "ERROR" "Konnte IONOS Volume-Snapshot nicht erstellen nach $MAX_RETRIES Versuchen"
  echo "   Fehlermeldung: ${ERROR_MSG:-Unbekannter Fehler}"
  exit 1
fi