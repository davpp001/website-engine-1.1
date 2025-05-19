#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# WEBSITE ENGINE - WARTUNGSSKRIPT
# ====================================================================
#
# Dieses Skript führt verschiedene Wartungsoperationen durch, um den
# Server sauber und optimal konfiguriert zu halten.
#
# VERWENDUNG:
#   maintenance.sh [--check-only]
#
# OPTIONEN:
#   --check-only    Nur Prüfungen durchführen, keine Änderungen vornehmen
#
# ====================================================================

# Import modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR=""

# Versuche verschiedene mögliche Modulpfade
if [[ -d "/opt/website-engine-1.1/modules" ]]; then
    MODULE_DIR="/opt/website-engine-1.1/modules"
elif [[ -d "$(dirname "$SCRIPT_DIR")/modules" ]]; then
    MODULE_DIR="$(dirname "$SCRIPT_DIR")/modules"
elif [[ -d "/usr/local/modules" ]]; then
    MODULE_DIR="/usr/local/modules"
else
    echo "❌ Fehler: Kann das Modulverzeichnis nicht finden"
    exit 1
fi

source "${MODULE_DIR}/config.sh"
source "${MODULE_DIR}/cloudflare.sh"
source "${MODULE_DIR}/apache.sh"
source "${MODULE_DIR}/wordpress.sh"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
function print_section() {
  echo -e "\n${BLUE}$1${NC}"
  echo "========================================"
}

function print_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

function print_warning() {
  echo -e "${YELLOW}⚠️ $1${NC}"
}

function print_error() {
  echo -e "${RED}❌ $1${NC}"
}

# Parse arguments
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      CHECK_ONLY=1
      shift
      ;;
    --help)
      echo "Verwendung: $0 [--check-only]"
      echo "  --check-only    Nur Prüfungen durchführen, keine Änderungen vornehmen"
      exit 0
      ;;
    *)
      echo "Unbekannte Option: $1"
      echo "Verwende --help für Hilfe."
      exit 1
      ;;
  esac
done

# Check if running as root or with sudo
if [ "$(id -u)" -ne 0 ]; then
  print_error "Dieses Skript muss als Root oder mit sudo ausgeführt werden."
  exit 1
fi

print_section "WEBSITE ENGINE - WARTUNG"
echo "Führe Wartungsoperationen für Website Engine durch."

# 1. Prüfe Apache-Konfigurationen
print_section "Prüfe Apache-Konfigurationen"
APACHE_PROBLEMS=0
APACHE_FIXES=0

echo "Prüfe auf Apache-Konfigurationen mit nicht existierenden DocumentRoot-Verzeichnissen..."
for conf_file in /etc/apache2/sites-available/*.conf; do
  if [[ -f "$conf_file" ]]; then
    # Ignoriere Standard-Konfigurationen
    if [[ "$conf_file" == *"000-default"* ]] || [[ "$conf_file" == *"default-ssl"* ]]; then
      continue
    fi
    
    docroot=$(grep -oP 'DocumentRoot\s+\K[^\s]+' "$conf_file" 2>/dev/null | head -1)
    if [[ -n "$docroot" && ! -d "$docroot" ]]; then
      APACHE_PROBLEMS=$((APACHE_PROBLEMS + 1))
      echo "- Problem gefunden: $conf_file verweist auf nicht existierendes Verzeichnis: $docroot"
      
      if [[ $CHECK_ONLY -eq 0 ]]; then
        echo "  → Entferne Konfigurationsdatei"
        rm -f "$conf_file"
        APACHE_FIXES=$((APACHE_FIXES + 1))
      fi
    fi
  fi
done

# Prüfe auf temporäre LE-Konfigurationen
echo "Prüfe auf temporäre Let's Encrypt-Konfigurationsdateien..."
TEMP_LE_COUNT=$(find /etc/apache2/sites-available/ -name "*-temp-le-ssl.conf" | wc -l)
if [[ $TEMP_LE_COUNT -gt 0 ]]; then
  APACHE_PROBLEMS=$((APACHE_PROBLEMS + $TEMP_LE_COUNT))
  echo "- Problem gefunden: $TEMP_LE_COUNT temporäre Let's Encrypt-Konfigurationsdateien"
  
  if [[ $CHECK_ONLY -eq 0 ]]; then
    echo "  → Entferne temporäre Konfigurationsdateien"
    find /etc/apache2/sites-available/ -name "*-temp-le-ssl.conf" -print -delete
    APACHE_FIXES=$((APACHE_FIXES + $TEMP_LE_COUNT))
  fi
fi

# Zusammenfassung
if [[ $APACHE_PROBLEMS -eq 0 ]]; then
  print_success "Keine Probleme mit Apache-Konfigurationen gefunden."
else
  if [[ $CHECK_ONLY -eq 1 ]]; then
    print_warning "$APACHE_PROBLEMS Probleme mit Apache-Konfigurationen gefunden. Führe das Skript ohne --check-only aus, um sie zu beheben."
  else
    print_success "$APACHE_PROBLEMS Probleme mit Apache-Konfigurationen gefunden und $APACHE_FIXES davon behoben."
    
    # Neuladen von Apache bei Änderungen
    echo "Lade Apache neu..."
    if systemctl reload apache2; then
      print_success "Apache erfolgreich neu geladen."
    else
      print_error "Konnte Apache nicht neu laden. Bitte überprüfen Sie die Konfiguration manuell."
    fi
  fi
fi

# 2. Prüfe WordPress-Installationen
print_section "Prüfe WordPress-Installationen"

# Liste alle WordPress-Verzeichnisse
echo "Suche WordPress-Verzeichnisse..."
WP_DIRS=()

if [[ -d "$WP_DIR" ]]; then
  # Finde alle potenziellen WordPress-Verzeichnisse
  while IFS= read -r dir; do
    if [[ -f "$dir/wp-config.php" ]]; then
      WP_DIRS+=("$dir")
    fi
  done < <(find "$WP_DIR" -mindepth 1 -maxdepth 1 -type d)
  
  echo "Gefunden: ${#WP_DIRS[@]} WordPress-Installationen"
  
  # Prüfe jede WordPress-Installation
  WP_PROBLEMS=0
  
  for dir in "${WP_DIRS[@]}"; do
    site=$(basename "$dir")
    echo "Prüfe WordPress-Site: $site"
    
    # 1. Prüfe, ob eine Apache-Konfiguration existiert
    if [[ ! -f "/etc/apache2/sites-available/$site.conf" ]]; then
      WP_PROBLEMS=$((WP_PROBLEMS + 1))
      echo "- Problem gefunden: Keine Apache-Konfiguration für $site"
    fi
    
    # 2. Prüfe auf grundlegende WordPress-Dateien
    if [[ ! -f "$dir/wp-config.php" || ! -f "$dir/index.php" ]]; then
      WP_PROBLEMS=$((WP_PROBLEMS + 1))
      echo "- Problem gefunden: WordPress-Installation für $site scheint beschädigt zu sein"
    fi
  done
  
  # Zusammenfassung
  if [[ $WP_PROBLEMS -eq 0 ]]; then
    print_success "Keine Probleme mit WordPress-Installationen gefunden."
  else
    print_warning "$WP_PROBLEMS Probleme mit WordPress-Installationen gefunden. Manuelle Überprüfung empfohlen."
  fi
else
  print_warning "WordPress-Verzeichnis $WP_DIR existiert nicht."
fi

# 3. Prüfe DNS-Einträge (optional)
if [[ -n "${CF_API_TOKEN:-}" && -n "${ZONE_ID:-}" ]]; then
  print_section "Prüfe Cloudflare DNS-Einträge"
  
  echo "Liste alle DNS-A-Records..."
  cf_records=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json")
  
  if [[ -n "$cf_records" ]] && jq -e '.success == true' <<< "$cf_records" >/dev/null; then
    record_count=$(jq -r '.result | length' <<< "$cf_records")
    echo "Gefunden: $record_count DNS-A-Records"
    
    # Prozess und validiere jedes DNS-Record
    # Hier nur grundlegende Informationen anzeigen
    jq -r '.result[] | "Domain: \(.name) → IP: \(.content)"' <<< "$cf_records"
    
    print_success "DNS-Einträge erfolgreich abgerufen."
  else
    print_error "Konnte DNS-Einträge nicht abrufen."
  fi
else
  print_warning "Cloudflare API-Zugangsdaten nicht gefunden. DNS-Prüfung übersprungen."
fi

# 4. Prüfe SSL-Zertifikate
print_section "Prüfe SSL-Zertifikate"  if command -v certbot &>/dev/null; then
  echo "Prüfe auf bald ablaufende Zertifikate..."
  certbot_output=$(certbot certificates 2>/dev/null || echo "Fehler bei certbot certificates")
  
  if [[ "$certbot_output" == *"Fehler"* ]]; then
    print_error "Konnte certbot-Zertifikate nicht abrufen."
  else
    echo "$certbot_output"
    
    # Verbesserte Erkennung von Zertifikatsinformationen
    if [[ "$certbot_output" == *"Certificate Name"* && "$certbot_output" == *"Expiry Date"* ]]; then
      expiry_warning=0
      
      # Extrahiere alle Zertifikatsnamen
      cert_names=$(echo "$certbot_output" | grep -oP 'Certificate Name: \K.*' || echo "")
      
      # Extrahiere alle Ablaufdaten
      while IFS= read -r line; do
        if [[ "$line" == *"Expiry Date:"* ]]; then
          # Extrahiere das Ablaufdatum und die Anzahl der verbleibenden Tage
          expiry_info=$(echo "$line" | grep -oP 'Expiry Date: \K[^(]+ \([^)]+\)')
          expiry_date=$(echo "$expiry_info" | cut -d'(' -f1)
          days_info=$(echo "$expiry_info" | grep -oP '\(VALID: \K[0-9]+')
          
          if [[ -n "$days_info" ]]; then
            days_left=$days_info
            
            # Prüfe, ob das Zertifikat bald abläuft
            if [[ $days_left -lt 30 ]]; then
              cert_name=$(echo "$certbot_output" | grep -B5 "$line" | grep "Certificate Name" | head -1 | grep -oP 'Certificate Name: \K.*')
              print_warning "Zertifikat '$cert_name' läuft in $days_left Tagen ab"
              expiry_warning=1
            fi
          fi
        fi
      done <<< "$certbot_output"
          
          if [[ $days_left -lt 30 ]]; then
            print_warning "Zertifikat läuft in $days_left Tagen ab: $line"
            expiry_warning=1
          fi
        fi
      done <<< "$certbot_output"
      
      if [[ $expiry_warning -eq 0 ]]; then
        print_success "Alle Zertifikate sind noch mindestens 30 Tage gültig."
      else
        # Automatische Erneuerung vorschlagen
        if [[ $CHECK_ONLY -eq 0 ]]; then
          echo "Versuche, ablaufende Zertifikate zu erneuern..."
          if certbot renew --noninteractive --no-random-sleep-on-renew; then
            print_success "Zertifikatserneuerung erfolgreich!"
          else
            print_error "Konnte Zertifikate nicht erneuern."
          fi
        else
          print_warning "Zertifikatserneuerung wird empfohlen (führe ohne --check-only aus)"
        fi
      fi
    else
      # Keine Zertifikate gefunden oder Format nicht erkannt
      if [[ "$certbot_output" == *"Certificate Name"* || "$certbot_output" == *"Expiry Date"* ]]; then
        # Zertifikatsausgabe erkannt, aber Format nicht wie erwartet - versuche Anzahl zu ermitteln
        cert_count=$(echo "$certbot_output" | grep -c "Certificate Name:")
        if [[ $cert_count -gt 0 ]]; then
          print_success "$cert_count Zertifikate gefunden, aber das Format konnte nicht vollständig analysiert werden."
        else
          print_warning "Zertifikatsinformationen konnten nicht analysiert werden."
        fi
      else
        print_warning "Keine Zertifikate gefunden oder unerwartetes Format der certbot-Ausgabe"
      fi
    fi
  fi
else
  print_warning "certbot ist nicht installiert. SSL-Zertifikatsprüfung übersprungen."
fi

# 5. Abschluss
print_section "Wartung abgeschlossen"

if [[ $CHECK_ONLY -eq 1 ]]; then
  echo "Dies war nur ein Check-Lauf. Keine Änderungen wurden vorgenommen."
  echo "Führe das Skript ohne --check-only aus, um erkannte Probleme zu beheben."
else
  echo "Wartungsaufgaben wurden abgeschlossen."
fi

# Empfohlene regelmäßige Wartung
echo
echo "Empfehlung: Führen Sie dieses Wartungsskript regelmäßig aus."
echo "Beispiel für eine monatliche automatische Ausführung:"
echo "  sudo crontab -e"
echo "  Fügen Sie hinzu: 0 4 1 * * /opt/website-engine-1.1/bin/maintenance.sh > /var/log/website-engine/maintenance.log 2>&1"

exit 0
