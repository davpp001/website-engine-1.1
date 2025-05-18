#!/usr/bin/env bash
set -euo pipefail

# DIREKTES SSL-SETUP OHNE KOMPLEXITÄT
# Dieses Skript richtet ein SSL-Zertifikat für eine Domain DIREKT ein

if [ $# -ne 1 ]; then
  echo "Verwendung: $0 <subdomain.domain>"
  exit 1
fi

FQDN="$1"
SUB=$(echo "$FQDN" | cut -d. -f1)
DOMAIN=$(echo "$FQDN" | cut -d. -f2-)
DOCROOT="/var/www/${SUB}"

echo "🔒 SSL-Setup für $FQDN (direkte Methode)"

# 1. Stelle sicher, dass das Verzeichnis existiert
if [ ! -d "$DOCROOT" ]; then
  echo "ℹ️ Erstelle Verzeichnis $DOCROOT"
  mkdir -p "$DOCROOT"
  chown -R www-data:www-data "$DOCROOT"
  echo "<?php echo 'SSL-Test für $FQDN'; ?>" > "$DOCROOT/index.php"
fi

# 2. Erstelle einfache Apache-Konfiguration
echo "📝 Erstelle Apache-Konfiguration"

# Entferne alte Konfigurationen
a2dissite "*$SUB*" &>/dev/null || true
rm -f "/etc/apache2/sites-available/*$SUB*" &>/dev/null || true

# Einfache neue Konfiguration
cat > "/etc/apache2/sites-available/${SUB}.conf" << EOF
<VirtualHost *:80>
  ServerName ${FQDN}
  DocumentRoot ${DOCROOT}
  
  <Directory ${DOCROOT}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
</VirtualHost>
EOF

# 3. Aktiviere die Site
echo "🔄 Aktiviere VirtualHost"
a2ensite "${SUB}.conf"
systemctl reload apache2

# 4. SSL direkt mit Apache-Plugin erstellen
echo "🔐 Erstelle und installiere SSL-Zertifikat"
certbot --apache -n --agree-tos --email admin@online-aesthetik.de -d "$FQDN"

# 5. Reload Apache
echo "🔄 Aktualisiere Apache"
systemctl reload apache2

echo "✅ SSL für $FQDN erfolgreich eingerichtet!"