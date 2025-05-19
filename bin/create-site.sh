#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# NEUE WORDPRESS-SITE ERSTELLEN (OPTIMIERT)
# ====================================================================
#
# Dieses Skript erstellt eine neue WordPress-Site mit SSL-Zertifikat.
# Es nutzt automatisch das Wildcard-Zertifikat, wenn verfügbar.
#
# VERWENDUNG:
#   create-site <subdomain> [--test] [--force-ssl]
#
# OPTIONEN:
#   --test        Überspringt die DNS-Erstellung und -Überprüfung
#   --force-ssl   Erzwingt die Erstellung eines eigenen SSL-Zertifikats
#                 anstatt das Wildcard-Zertifikat zu verwenden
#
# BEISPIEL:
#   create-site kunde1       # Erstellt kunde1.s-neue.website mit SSL
#   create-site test --test  # Erstellt test.s-neue.website ohne DNS-Prüfung
#
# ====================================================================

# Import modules
# Versuche zuerst den Installationspfad zu finden
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Show usage
usage() {
  echo "Verwendung: $0 <subdomain-name> [--test] [--force-ssl]"
  echo
  echo "Erstellt eine neue WordPress-Seite für die angegebene Subdomain."
  echo
  echo "Optionen:"
  echo "  --test        Testmodus (DNS-Überprüfung überspringen)"
  echo "  --force-ssl   Erzwinge ein eigenes SSL-Zertifikat (statt Wildcard)"
  echo "  --help        Diese Hilfe anzeigen"
  echo
  echo "Beispiele:"
  echo "  $0 kunde1         # Erstellt kunde1.$DOMAIN mit WordPress"
  echo "  $0 test --test    # Erstellt test.$DOMAIN im Testmodus"
  exit 1
}

log "INFO" "===== ERSTELLE NEUE WORDPRESS-SITE ====="

# Parse arguments
SUBDOMAIN=""
TEST_MODE=0
FORCE_SSL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test)
      TEST_MODE=1
      shift
      ;;
    --force-ssl)
      FORCE_SSL=1
      shift
      ;;
    --help)
      usage
      ;;
    -*)
      echo "Unbekannte Option: $1"
      usage
      ;;
    *)
      if [[ -z "$SUBDOMAIN" ]]; then
        SUBDOMAIN="$1"
      else
        echo "Zu viele Parameter: $1"
        usage
      fi
      shift
      ;;
  esac
done

# Check if subdomain is provided
if [[ -z "$SUBDOMAIN" ]]; then
  echo "❌ Fehler: Bitte geben Sie einen Subdomain-Namen an."
  usage
fi

# Subdomain validieren (nur alphanumerische Zeichen und Bindestriche erlaubt)
if ! [[ "$SUBDOMAIN" =~ ^[a-zA-Z0-9-]+$ ]]; then
  echo "❌ Fehler: Subdomain darf nur Buchstaben, Zahlen und Bindestriche enthalten."
  exit 1
fi

# Systemprüfung
if ! check_system_ready; then
  echo "❌ Systemprüfung fehlgeschlagen. Bitte führen Sie zuerst setup-server.sh aus."
  exit 1
fi

# Main process
echo "🚀 Erstelle neue WordPress-Seite für Subdomain: $SUBDOMAIN"

# 1) Create Cloudflare DNS subdomain
if [[ $TEST_MODE -eq 1 ]]; then
  echo "🧪 Testmodus: Überspringe DNS-Erstellung und Überprüfung"
  SUB="$SUBDOMAIN"
  log "INFO" "Testmodus aktiviert für $SUB"
else
  # Check if environment variables are set
  if ! check_env_vars; then
    echo "❌ Fehler: Cloudflare-Umgebungsvariablen nicht gesetzt."
    echo "Bitte führe aus: source /etc/profile.d/cloudflare.sh"
    exit 1
  fi
  
  echo "🌐 Erstelle Cloudflare DNS-Eintrag..."
  SUB=$(create_subdomain "$SUBDOMAIN") || {
    echo "❌ Konnte DNS-Eintrag nicht erstellen"
    exit 1
  }
  
  # Optimierte DNS-Propagation-Prüfung
  # 1. Zuerst direkt bei Cloudflare prüfen
  echo "🌐 Prüfe DNS-Eintrag direkt bei Cloudflare..."
  
  if [[ -n "${CF_API_TOKEN:-}" && -n "${ZONE_ID:-}" ]]; then
    cf_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" | jq -r --arg fqdn "${SUB}.${DOMAIN}" '.result[] | select(.name==$fqdn and .type=="A")')
    
    if [[ -n "$cf_response" ]]; then
      echo "✅ DNS-Eintrag in Cloudflare API bestätigt!"
    else
      echo "⚠️ DNS-Eintrag in Cloudflare API nicht gefunden. Überprüfe Einstellungen."
    fi
  fi
  
  # 2. Auf DNS-Propagation warten mit abgestufter Strategie
  echo "🌐 Prüfe DNS-Propagation..."
  DNS_CHECK_PASSED=0
  
  # Versuch 1: Direkt gegen Cloudflare DNS-Server prüfen (schnell und direkt)
  for i in {1..3}; do
    echo -n "DNS-Prüfung (CF-Direkt) $i von 3: "
    if dig @1.1.1.1 +short "${SUB}.${DOMAIN}" | grep -q "[0-9]"; then
      echo "✅ Erfolgreich gegen Cloudflare DNS!"
      DNS_CHECK_PASSED=1
      break
    else
      echo "⏳ Noch nicht verfügbar, warte 5 Sekunden..."
      sleep 5
    fi
  done
  
  # Versuch 2: Lokaler DNS-Resolver (z.B. vom ISP oder lokalen Cache)
  if [[ $DNS_CHECK_PASSED -eq 0 ]]; then
    for i in {1..3}; do
      echo -n "DNS-Prüfung (Lokal) $i von 3: "
      if dig +short "${SUB}.${DOMAIN}" | grep -q "[0-9]"; then
        echo "✅ Erfolgreich gegen lokalen DNS!"
        DNS_CHECK_PASSED=1
        break
      else
        echo "⏳ Noch nicht verfügbar, warte 10 Sekunden..."
        sleep 10
      fi
    done
  fi
  
  # Versuch 3: Verschiedene Lookup-Methoden mit längeren Pausen
  if [[ $DNS_CHECK_PASSED -eq 0 ]]; then
    for i in {1..3}; do
      echo -n "DNS-Prüfung (Alternativ) $i von 3: "
      if host "${SUB}.${DOMAIN}" &>/dev/null || nslookup "${SUB}.${DOMAIN}" &>/dev/null; then
        echo "✅ Erfolgreich mit alternativen DNS-Tools!"
        DNS_CHECK_PASSED=1
        break
      else
        echo "⏳ Noch nicht verfügbar, warte 15 Sekunden..."
        sleep 15
      fi
    done
  fi
  
  # Fortfahren, auch wenn die DNS-Propagation noch nicht überall bestätigt wurde
  if [[ $DNS_CHECK_PASSED -eq 0 ]]; then
    echo "⚠️ DNS-Propagation konnte nicht vollständig verifiziert werden."
    echo "Wir vertrauen auf den Cloudflare-Eintrag und fahren fort. Dies kann zu temporären SSL-Problemen führen."
  else
    echo "✅ DNS-Propagation verifiziert! Fahre mit der Installation fort."
  fi
fi

# 2) Prüfe auf vorhandenes Wildcard-Zertifikat
SSL_OK=0
if [[ $FORCE_SSL -eq 0 ]]; then
  echo "🔐 Prüfe auf vorhandenes Wildcard-Zertifikat..."
  
  # Wildcard-Zertifikat verwenden, wenn vorhanden
  if [[ -f "$SSL_CERT_PATH" ]]; then
    if openssl x509 -in "$SSL_CERT_PATH" -text | grep -q "DNS:\*\.$DOMAIN"; then
      echo "✅ Wildcard-Zertifikat für *.$DOMAIN gefunden!"
      
      # Prüfe Ablaufdatum
      cert_end_date=$(openssl x509 -in "$SSL_CERT_PATH" -noout -enddate | cut -d= -f2)
      cert_end_epoch=$(date -d "$cert_end_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$cert_end_date" +%s 2>/dev/null)
      now_epoch=$(date +%s)
      days_left=$(( (cert_end_epoch - now_epoch) / 86400 ))
      
      if [[ $days_left -lt 0 ]]; then
        echo "⚠️ Wildcard-Zertifikat ist abgelaufen! Erstelle ein neues Zertifikat."
      elif [[ $days_left -lt 15 ]]; then
        echo "⚠️ Wildcard-Zertifikat läuft in $days_left Tagen ab. Bald erneuern!"
        SSL_OK=1
      else
        echo "✅ Wildcard-Zertifikat ist gültig für weitere $days_left Tage."
        SSL_OK=1
      fi
    else
      echo "⚠️ Zertifikat gefunden, ist aber kein Wildcard-Zertifikat."
    fi
  else
    echo "⚠️ Kein Wildcard-Zertifikat gefunden."
  fi
fi

# 3) Setup Apache virtual host
echo "🌐 Erstelle Apache vHost..."

# Stelle sicher, dass keine verwaisten Konfigurationen für diese Subdomain existieren
if type cleanup_apache_configs &>/dev/null; then
  echo "🧹 Bereinige möglicherweise vorhandene Apache-Konfigurationen..."
  cleanup_apache_configs "$SUB"
fi

# Wenn Wildcard-SSL verfügbar ist, erstelle direkt mit SSL
if [[ $SSL_OK -eq 1 ]]; then
  echo "🔐 Verwende vorhandenes Wildcard-Zertifikat..."
  create_vhost_config "$SUB" || {
    echo "❌ Fehler beim Erstellen des Apache vHost."
    if [[ $TEST_MODE -eq 0 ]]; then
      echo "🧹 Bereinige DNS-Einträge..."
      delete_subdomain "$SUB"
    fi
    exit 1
  }
else
  # Ansonsten erstelle zunächst den HTTP-vHost
  setup_vhost "$SUB" || {
    echo "❌ Fehler beim Erstellen des Apache vHost."
    if [[ $TEST_MODE -eq 0 ]]; then
      echo "🧹 Bereinige DNS-Einträge..."
      delete_subdomain "$SUB"
    fi
    exit 1
  }
  
  # Nur wenn wir kein Wildcard-Zertifikat haben oder --force-ssl gesetzt wurde
  if [[ $SSL_OK -eq 0 ]]; then
    # SSL-Zertifikat erstellen (bis zu 2 Versuche)
    for ssl_try in {1..2}; do
      echo "🔐 [Versuch $ssl_try/2] Erstelle und installiere SSL-Zertifikat mit certbot --apache"
      if sudo certbot --apache -n --agree-tos --email "$SSL_EMAIL" -d "${SUB}.${DOMAIN}"; then
        SSL_OK=1
        break
      else
        echo "⚠️ SSL-Installation mit certbot fehlgeschlagen. Warte 10 Sekunden und versuche es noch einmal..."
        sleep 10
      fi
    done
  fi
fi

# Wenn SSL aktiviert ist, erfolgt die Installation von WordPress
if [[ $SSL_OK -eq 1 ]]; then
  echo "📦 Installiere WordPress..."
  install_wordpress "$SUB" || {
    echo "❌ Fehler bei der WordPress-Installation."
    echo "🧹 Bereinige vHost und DNS-Einträge..."
    remove_vhost "$SUB"
    if [[ $TEST_MODE -eq 0 ]]; then
      delete_subdomain "$SUB"
    fi
    exit 1
  }
else
  echo "⚠️ SSL konnte nicht konfiguriert werden, fahre trotzdem mit HTTP fort."
  echo "📦 Installiere WordPress..."
  install_wordpress "$SUB" || {
    echo "❌ Fehler bei der WordPress-Installation."
    echo "🧹 Bereinige vHost und DNS-Einträge..."
    remove_vhost "$SUB"
    if [[ $TEST_MODE -eq 0 ]]; then
      delete_subdomain "$SUB"
    fi
    exit 1
  }
fi

# Complete
if [[ $SSL_OK -eq 1 ]]; then
  FINAL_URL="https://$SUB.$DOMAIN"
  SSL_STATUS="Aktiv"
else
  FINAL_URL="http://$SUB.$DOMAIN"
  SSL_STATUS="Inaktiv - Bitte manuell einrichten"
fi

echo
echo "✅ Neue WordPress-Seite erfolgreich erstellt!"
echo "-------------------------------------------"
echo "🌐 Website:      $FINAL_URL"
echo "🔑 Admin-Login:  $FINAL_URL/wp-admin/"
echo "👤 Benutzer:     $WP_USER"
echo "🔒 Passwort:     $WP_PASS"
echo "📌 SSL:          $SSL_STATUS"
echo "-------------------------------------------"
echo "Die Anmeldedaten wurden in $CONFIG_DIR/sites/$SUB/ gespeichert"
echo

log "SUCCESS" "WordPress-Site für $SUB.$DOMAIN erfolgreich erstellt"
exit 0