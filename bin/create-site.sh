#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# NEUE WORDPRESS-SITE ERSTELLEN
# ====================================================================

# Import modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")/modules"

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