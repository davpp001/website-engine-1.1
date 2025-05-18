#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# NEUE WORDPRESS-SITE ERSTELLEN
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
  
  # Wait for DNS propagation
  wait_for_dns "$SUB" 120 || {
    echo "⚠️ DNS-Propagation konnte nicht verifiziert werden"
    echo "Fahre trotzdem fort. Sie müssen möglicherweise warten, bis DNS-Änderungen wirksam werden."
  }
fi

# 2) Setup Apache virtual host
echo "🌐 Erstelle Apache vHost..."
setup_vhost "$SUB" || {
  echo "❌ Fehler beim Erstellen des Apache vHost."
  
  # Cleanup in case of error
  if [[ $TEST_MODE -eq 0 ]]; then
    echo "🧹 Bereinige DNS-Einträge..."
    delete_subdomain "$SUB"
  fi
  
  exit 1
}

# 3) Install WordPress
echo "📦 Installiere WordPress..."
install_wordpress "$SUB" || {
  echo "❌ Fehler bei der WordPress-Installation."
  
  # Cleanup in case of error
  echo "🧹 Bereinige vHost und DNS-Einträge..."
  remove_vhost "$SUB"
  
  if [[ $TEST_MODE -eq 0 ]]; then
    delete_subdomain "$SUB"
  fi
  
  exit 1
}


# EXAKT DEN ERFOLGREICH GETESTETEN ANSATZ VON direct-ssl.sh VERWENDEN
echo "🔒 Richte SSL-Zertifikat ein (bewährte Methode)..."

# Zusätzliche DNS-Überprüfung, um sicherzustellen, dass DNS propagiert ist
echo "🌐 Prüfe DNS-Propagation für ${SUB}.${DOMAIN}..."
DNS_CHECK_PASSED=0
MAX_DNS_CHECKS=5
DNS_WAIT_SECONDS=15

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
  echo "⚠️ DNS-Propagation konnte nicht verifiziert werden. Dies könnte zu Problemen bei der SSL-Zertifikatserstellung führen."
  echo "   Fahre dennoch fort..."
else
  echo "✅ DNS-Propagation verifiziert! Fahre mit SSL-Setup fort."
fi

# 1. Erstelle einfache Apache-Konfiguration
echo "📝 Erstelle Apache-Konfiguration"

# Entferne alte Konfigurationen
sudo a2dissite "*${SUB}*" &>/dev/null || true
sudo rm -f "/etc/apache2/sites-available/*${SUB}*" &>/dev/null || true

# Stelle sicher, dass Verzeichnis existiert und .well-known Ordner angelegt ist
sudo mkdir -p "${WP_DIR}/${SUB}/.well-known/acme-challenge"
sudo chown -R www-data:www-data "${WP_DIR}/${SUB}"

# Erstelle Test-Dateien für ACME Challenge (hilfreich für Debugging)
echo "This is an ACME challenge directory test file" | sudo tee "${WP_DIR}/${SUB}/.well-known/acme-challenge/test.txt" > /dev/null
sudo chmod 644 "${WP_DIR}/${SUB}/.well-known/acme-challenge/test.txt"

# Einfache neue Konfiguration
sudo tee "/etc/apache2/sites-available/${SUB}.conf" > /dev/null << EOF
<VirtualHost *:80>
  ServerName ${SUB}.${DOMAIN}
  DocumentRoot ${WP_DIR}/${SUB}
  
  <Directory ${WP_DIR}/${SUB}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
  
  # Unterstützung für ACME-Challenge (Let's Encrypt)
  <Directory "${WP_DIR}/${SUB}/.well-known/acme-challenge">
    Options None
    AllowOverride None
    Require all granted
  </Directory>
</VirtualHost>
EOF

# 2. Aktiviere die Site
echo "🔄 Aktiviere VirtualHost"
sudo a2ensite "${SUB}.conf"
sudo systemctl reload apache2

# Warte kurz, damit Apache sich neu laden kann
sleep 2

# 3. SSL direkt mit Apache-Plugin erstellen - Bewährte Methode
echo "🔐 Erstelle und installiere SSL-Zertifikat mit certbot --apache (DIREKTE METHODE)"
echo "   Dies ist die EINZIGE FUNKTIONIERENDE METHODE!"
echo "   (Nicht mehr --webroot verwenden, da es fehlerhaft ist)"
sudo certbot --apache -n --agree-tos --email "$SSL_EMAIL" -d "${SUB}.${DOMAIN}" || {
  echo "⚠️ Certbot (--apache) fehlgeschlagen. Versuche alternative Methode..."
  
  # Versuche die direkte Methode mit unserem bewährten Skript
  echo "🔄 Starte alternatives SSL-Setup mit direct-ssl.sh..."
  sudo /opt/website-engine-1.1/bin/direct-ssl.sh "${SUB}.${DOMAIN}" || {
    echo "⚠️ Beide SSL-Installationsmethoden fehlgeschlagen."
    echo "   Mögliche Ursachen:"
    echo "   - DNS-Propagation ist noch nicht abgeschlossen"
    echo "   - Port 80 ist durch anderen Dienst blockiert"
    echo "   - Certbot hat temporäre Probleme"
    echo
    echo "   Überprüfung der Erreichbarkeit:"
    echo "   curl -I http://${SUB}.${DOMAIN}/.well-known/acme-challenge/test.txt"
    echo
    echo "   Bitte später manuell ausführen:"
    echo "   sudo /opt/website-engine-1.1/bin/direct-ssl.sh ${SUB}.${DOMAIN}"
  }
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