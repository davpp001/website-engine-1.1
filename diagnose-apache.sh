#!/bin/bash
# Diagnostisches Skript für Apache-Konfiguration
# Dieses Skript hilft bei der Identifizierung, warum die Apache-Standardseite 
# statt der WordPress-Site angezeigt wird.

echo "====== APACHE VHOST DIAGNOSE ======"

# Subdomain prüfen
SUB=${1:-testsite99}
DOMAIN=${2:-s-neue.website}
FQDN="${SUB}.${DOMAIN}"

echo "Prüfe Konfiguration für: $FQDN"
echo

# 1. Prüfen, ob die Konfigurationsdatei existiert
echo "1. Prüfe Konfigurationsdateien:"
if [ -f "/etc/apache2/sites-available/${SUB}.conf" ]; then
  echo "✅ Konfigurationsdatei existiert: /etc/apache2/sites-available/${SUB}.conf"
  
  # Zeige den Inhalt der Konfigurationsdatei
  echo "   --- Inhalt der Konfigurationsdatei ---"
  cat "/etc/apache2/sites-available/${SUB}.conf"
  echo "   -----------------------------------"
else
  echo "❌ Konfigurationsdatei fehlt: /etc/apache2/sites-available/${SUB}.conf"
fi

# 2. Prüfen, ob der Symlink korrekt erstellt wurde
echo
echo "2. Prüfe Symlinks:"
if [ -L "/etc/apache2/sites-enabled/${SUB}.conf" ]; then
  echo "✅ Symlink existiert: /etc/apache2/sites-enabled/${SUB}.conf"
  # Zeige das Ziel des Symlinks
  echo "   → Ziel: $(readlink -f /etc/apache2/sites-enabled/${SUB}.conf)"
else
  echo "❌ Symlink fehlt: /etc/apache2/sites-enabled/${SUB}.conf"
fi

# 3. Prüfe aktive Sites in Apache
echo
echo "3. Liste aller aktivierten Sites:"
ls -la /etc/apache2/sites-enabled/

# 4. Prüfe die Standardseite (000-default.conf)
echo
echo "4. Prüfe Apache Default-Site:"
if [ -L "/etc/apache2/sites-enabled/000-default.conf" ]; then
  echo "⚠️ Default-Site ist aktiviert und könnte Konflikte verursachen"
  echo "   --- Inhalt der Default-Site ---"
  cat /etc/apache2/sites-enabled/000-default.conf
  echo "   ----------------------------"
else
  echo "✅ Default-Site ist nicht aktiviert"
fi

# 5. Prüfe die DocumentRoot-Verzeichnisse
WP_DIR="${3:-/var/www/html/wordpress}"
echo
echo "5. Prüfe DocumentRoot-Verzeichnis:"
if [ -d "${WP_DIR}/${SUB}" ]; then
  echo "✅ DocumentRoot existiert: ${WP_DIR}/${SUB}"
  echo "   Dateien im DocumentRoot:"
  ls -la "${WP_DIR}/${SUB}"
  
  # Prüfe wp-config.php
  if [ -f "${WP_DIR}/${SUB}/wp-config.php" ]; then
    echo "✅ WordPress ist installiert (wp-config.php gefunden)"
  else
    echo "❌ WordPress scheint nicht installiert zu sein (keine wp-config.php)"
  fi
else
  echo "❌ DocumentRoot fehlt: ${WP_DIR}/${SUB}"
fi

# 6. Prüfe Apache-Konfiguration
echo
echo "6. Prüfe Apache-Konfiguration:"
echo "   --- Apache-Test-Ausgabe ---"
apache2ctl -t -D DUMP_VHOSTS
echo "   -------------------------"

# 7. Prüfe DNS-Auflösung
echo
echo "7. Prüfe DNS-Auflösung für ${FQDN}:"
host "${FQDN}" || echo "❌ DNS-Auflösung fehlgeschlagen"

# 8. Empfehlungen
echo
echo "====== DIAGNOSE ABGESCHLOSSEN ======"
echo
echo "Mögliche Probleme:"
echo "1. NameVirtualHost-Konfiguration fehlt oder ist falsch"
echo "2. DocumentRoot-Berechtigungen"
echo "3. Default-Site hat Vorrang"
echo "4. SSL-Konfiguration blockiert HTTP-Zugriff"
echo "5. .htaccess-Probleme"
echo
echo "Empfehlungen für nächste Schritte:"
echo "- Prüfen, ob NameVirtualHost *:80 und *:443 in Apache-Konfiguration"
echo "- ServerName und ServerAlias in der VirtualHost-Konfiguration prüfen"
echo "- Berechtigungen des DocumentRoot überprüfen (www-data:www-data)"
echo "- Default-Site deaktivieren: sudo a2dissite 000-default"
echo "- Apache neu starten: sudo systemctl restart apache2"
