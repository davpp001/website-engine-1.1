#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# DIREKTE SSL-ZERTIFIKAT-INSTALLATION
# ====================================================================
#
# BESCHREIBUNG:
#   Dieses Skript richtet ein SSL-Zertifikat für eine Domain oder
#   Subdomain direkt mit certbot --apache ein. Es ist die zuverlässigste
#   Methode zur SSL-Installation.
#
# VERWENDUNG:
#   direct-ssl <subdomain.domain.tld>
#   
#   Beispiel: direct-ssl kunde.s-neue.website
#
# HINWEISE:
#   - Verwendet die --apache certbot Methode (nicht --webroot)
#   - Prüft DNS-Propagation vor der Installation
#   - Erstellt automatisch die notwendige Apache-Konfiguration
#
# ====================================================================

# Importiere Module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Versuche, Konfiguration zu laden (mehrere mögliche Pfade)
if [[ -f "$(dirname "$SCRIPT_DIR")/modules/config.sh" ]]; then
    source "$(dirname "$SCRIPT_DIR")/modules/config.sh"
elif [[ -f "/opt/website-engine-1.1/modules/config.sh" ]]; then
    source "/opt/website-engine-1.1/modules/config.sh"
fi

# Parameter prüfen
if [ $# -ne 1 ]; then
  echo "❌ Fehler: Fehlende Parameter"
  echo "✏️ Verwendung: $0 <subdomain.domain>"
  echo "📋 Beispiel: $0 kunde.s-neue.website"
  exit 1
fi

FQDN="$1"
SUB=$(echo "$FQDN" | cut -d. -f1)
DOMAIN=$(echo "$FQDN" | cut -d. -f2-)
DOCROOT="/var/www/${SUB}"
EMAIL=${SSL_EMAIL:-"admin@$DOMAIN"}

echo "🔒 SSL-Setup für $FQDN (direkte Methode)"

# DNS-Überprüfung hinzufügen
echo "🌐 Prüfe DNS-Propagation für ${FQDN}..."
DNS_CHECK_PASSED=0
MAX_DNS_CHECKS=5
DNS_WAIT_SECONDS=15

for ((i=1; i<=MAX_DNS_CHECKS; i++)); do
  echo -n "DNS-Prüfung $i von $MAX_DNS_CHECKS: "
  
  if host "${FQDN}" &>/dev/null || dig +short "${FQDN}" | grep -q "[0-9]"; then
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

# 1. Stelle sicher, dass das Verzeichnis und ACME-Challenge-Verzeichnis existieren
echo "ℹ️ Stelle Verzeichnisstruktur für $DOCROOT sicher"
sudo mkdir -p "$DOCROOT/.well-known/acme-challenge"
sudo chown -R www-data:www-data "$DOCROOT"

# Erstelle eine Test-Datei, wenn das Verzeichnis neu ist
if [ ! -f "$DOCROOT/index.php" ]; then
  echo "<?php echo 'SSL-Test für ${FQDN}'; ?>" | sudo tee "$DOCROOT/index.php" > /dev/null
fi

# Erstelle auch eine Test-Datei im ACME-Challenge-Verzeichnis für bessere Fehlerbehebung
echo "This is an ACME challenge directory test file" | sudo tee "$DOCROOT/.well-known/acme-challenge/test.txt" > /dev/null
sudo chmod 644 "$DOCROOT/.well-known/acme-challenge/test.txt"

# 2. Erstelle einfache Apache-Konfiguration
echo "📝 Erstelle Apache-Konfiguration"

# Entferne alte Konfigurationen
sudo a2dissite "*$SUB*" &>/dev/null || true
sudo rm -f "/etc/apache2/sites-available/*$SUB*" &>/dev/null || true

# Einfache neue Konfiguration
sudo tee "/etc/apache2/sites-available/${SUB}.conf" > /dev/null << EOF
<VirtualHost *:80>
  ServerName ${FQDN}
  DocumentRoot ${DOCROOT}
  
  <Directory ${DOCROOT}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
  
  # Unterstützung für ACME-Challenge (Let's Encrypt)
  <Directory "${DOCROOT}/.well-known/acme-challenge">
    Options None
    AllowOverride None
    Require all granted
  </Directory>
</VirtualHost>
EOF

# 3. Aktiviere die Site
echo "🔄 Aktiviere VirtualHost"
sudo a2ensite "${SUB}.conf"
sudo systemctl reload apache2

# Kurze Pause, um sicherzustellen, dass Apache vollständig geladen ist
echo "⏳ Warte, bis Apache bereit ist..."
sleep 5

# 4. SSL mit certbot --apache erstellen
echo "🔐 Erstelle und installiere SSL-Zertifikat mit certbot --apache"
if sudo certbot --apache -n --agree-tos --email "$EMAIL" -d "$FQDN"; then
  # 5. Reload Apache
  echo "🔄 Aktualisiere Apache"
  sudo systemctl reload apache2
  
  echo "✅ SSL für $FQDN erfolgreich eingerichtet!"
  echo "🔗 Die Website ist jetzt unter https://$FQDN verfügbar"
else
  echo "❌ SSL-Installation fehlgeschlagen!"
  echo
  echo "   Diagnostik:"
  echo "   - Überprüfe die DNS-Einträge: dig $FQDN"
  echo "   - Teste HTTP-Erreichbarkeit: curl -I http://$FQDN"
  echo "   - Prüfe den Apache Status: systemctl status apache2"
  echo "   - Prüfe die certbot Logs: tail -n 50 /var/log/letsencrypt/letsencrypt.log"
  echo
  echo "   Die Website ist ohne SSL unter http://$FQDN verfügbar."
  exit 1
fi