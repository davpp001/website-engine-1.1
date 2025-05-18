#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# SSL-ZERTIFIKAT EINRICHTEN
# ====================================================================

# Domain als Parameter
if [ $# -lt 1 ]; then
  echo "Verwendung: $0 <domain.tld>"
  exit 1
fi

DOMAIN="$1"

# Verzeichnisse
APACHE_SITES="/etc/apache2/sites-available"
WP_DIR="/var/www/${DOMAIN%%.*}"

# Simple Basis-Konfiguration erstellen
echo "1. Erstelle einfache Apache-Konfiguration..."
sudo tee "$APACHE_SITES/$DOMAIN.conf" > /dev/null << EOF
<VirtualHost *:80>
  ServerName $DOMAIN
  DocumentRoot $WP_DIR
  
  <Directory $WP_DIR>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
</VirtualHost>
EOF

# Aktivieren und Neuladen
echo "2. Aktiviere VirtualHost..."
sudo a2ensite "$DOMAIN.conf"
sudo systemctl reload apache2

# SSL-Zertifikat mit Apache-Plugin erstellen
echo "3. Erstelle SSL-Zertifikat mit Certbot..."
sudo certbot --apache -d "$DOMAIN" --non-interactive --agree-tos --email admin@online-aesthetik.de

echo "✅ SSL-Zertifikat für $DOMAIN erfolgreich eingerichtet!"