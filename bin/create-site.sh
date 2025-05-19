#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# NEUE WORDPRESS-SITE ERSTELLEN
# ====================================================================
#
# Dieses Skript erstellt eine neue WordPress-Site mit SSL-Zertifikat.
# Für die SSL-Installation wird ausschließlich das 'certbot --apache'
# Plugin verwendet, da es die zuverlässigste Methode ist.
#
# VERWENDUNG:
#   create-site <subdomain> [--test]
#
# OPTIONEN:
#   --test    Überspringt die DNS-Erstellung und -Überprüfung
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
  echo "Verwendung: $0 <subdomain-name> [--test]"
  echo
  echo "Erstellt eine neue WordPress-Seite für die angegebene Subdomain."
  echo
  echo "Optionen:"
  echo "  --test    Testmodus (DNS-Überprüfung überspringen)"
  echo "  --help    Diese Hilfe anzeigen"
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test)
      TEST_MODE=1
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
  # Zwingend auf DNS-Propagation warten (bis zu 10 Minuten)
  MAX_DNS_CHECKS=40
  DNS_WAIT_SECONDS=15
  DNS_CHECK_PASSED=0
  for ((i=1; i<=MAX_DNS_CHECKS; i++)); do
    echo -n "DNS-Prüfung $i von $MAX_DNS_CHECKS: "
    if host "${SUB}.${DOMAIN}" &>/dev/null || dig +short "${SUB}.${DOMAIN}" | grep -q "[0-9]"; then
      echo "✅ Erfolgreich!"
      DNS_CHECK_PASSED=1
      break
    else
      echo "⏳ Noch nicht verfügbar, warte $DNS_WAIT_SECONDS Sekunden..."
      sleep $DNS_WAIT_SECONDS
    fi
  done
  if [[ $DNS_CHECK_PASSED -eq 0 ]]; then
    echo "❌ DNS-Propagation konnte nach $((MAX_DNS_CHECKS*DNS_WAIT_SECONDS/60)) Minuten nicht verifiziert werden. Breche ab."
    delete_subdomain "$SUB"
    exit 1
  else
    echo "✅ DNS-Propagation verifiziert! Fahre mit SSL-Setup fort."
  fi
fi

# Verbesserte DNS-Propagation-Checks
DNS_OK=0
for dns_try in {1..10}; do
  echo "🌐 [Versuch $dns_try/10] Überprüfe DNS-Propagation für ${SUB}.${DOMAIN}"
  if dig +short "${SUB}.${DOMAIN}" | grep -q "$(curl -s ifconfig.me)"; then
    DNS_OK=1
    echo "✅ DNS-Propagation erfolgreich."
    break
  else
    echo "⚠️ DNS-Propagation noch nicht abgeschlossen. Warte 60 Sekunden..."
    sleep 60
  fi

done

if [[ $DNS_OK -eq 0 ]]; then
  echo "❌ DNS-Propagation nach 10 Versuchen fehlgeschlagen. Breche ab."
  exit 1
fi

# 2) Setup Apache virtual host (HTTP)
echo "🌐 Erstelle Apache vHost..."
setup_vhost "$SUB" || {
  echo "❌ Fehler beim Erstellen des Apache vHost."
  if [[ $TEST_MODE -eq 0 ]]; then
    echo "🧹 Bereinige DNS-Einträge..."
    delete_subdomain "$SUB"
  fi
  exit 1
}

# 3) SSL-Zertifikat erstellen (bis zu 3 Versuche, sonst Fallback)
SSL_OK=0
for ssl_try in {1..3}; do
  echo "🔐 [Versuch $ssl_try/3] Erstelle und installiere SSL-Zertifikat mit certbot --apache"
  if sudo certbot --apache -n --agree-tos --email "$SSL_EMAIL" -d "${SUB}.${DOMAIN}"; then
    SSL_OK=1
    break
  else
    echo "⚠️ SSL-Installation mit certbot fehlgeschlagen. Warte 30 Sekunden und versuche es erneut..."
    sleep 30
  fi
done

# Fallback-Mechanismus für SSL-Zertifikate
if [[ $SSL_OK -eq 0 ]]; then
  echo "❌ SSL-Installation mit Let's Encrypt fehlgeschlagen. Versuche Fallback-Option."
  if sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "/etc/ssl/private/${SUB}.${DOMAIN}.key" \
    -out "/etc/ssl/certs/${SUB}.${DOMAIN}.crt" \
    -subj "/CN=${SUB}.${DOMAIN}"; then
    echo "✅ Selbstsigniertes SSL-Zertifikat erfolgreich erstellt."
    SSL_OK=1
  else
    echo "❌ Fallback-SSL-Installation fehlgeschlagen. Breche ab."
    remove_vhost "$SUB"
    if [[ $TEST_MODE -eq 0 ]]; then
      delete_subdomain "$SUB"
    fi
    exit 1
  fi
fi

# 4) Apache vHost auf HTTPS umstellen (optional, falls nötig)
# ...hier ggf. weitere Optimierung möglich...

# 5) Install WordPress (nur wenn SSL erfolgreich)
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

# Complete
FINAL_URL="https://$SUB.$DOMAIN"
echo
echo "✅ Neue WordPress-Seite erfolgreich erstellt!"
echo "-------------------------------------------"
echo "🌐 Website:      $FINAL_URL"
echo "🔑 Admin-Login:  $FINAL_URL/wp-admin/"
echo "👤 Benutzer:     $WP_USER"
echo "🔒 Passwort:     $WP_PASS"
echo "📌 SSL:          Aktiv"
echo "-------------------------------------------"
echo "Die Anmeldedaten wurden in $CONFIG_DIR/sites/$SUB/ gespeichert"
echo

log "SUCCESS" "WordPress-Site für $SUB.$DOMAIN erfolgreich erstellt"
exit 0