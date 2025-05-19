#!/bin/bash
# Diagnose für Apache VirtualHost Prioritäten
# ===========================================

# Dieser Befehl zeigt die Reihenfolge an, in der Apache VirtualHosts lädt
echo "=== APACHE VHOST LADUNGSREIHENFOLGE ==="
apache2ctl -t -D DUMP_VHOSTS

echo
echo "=== DEFAULT SITE STATUS ==="
if [[ -e "/etc/apache2/sites-enabled/000-default.conf" ]]; then
  echo "⚠️ Default-Site ist aktiv - das ist oft ein Problem!"
  echo "Führe folgenden Befehl aus, um sie zu deaktivieren:"
  echo "sudo a2dissite 000-default && sudo systemctl reload apache2"
else
  echo "✅ Default-Site ist deaktiviert (gut!)"
fi

echo
echo "=== VERGLEICH DER VIRTUALHOST DATEIEN ==="
# Diese Analyse zeigt, welche VirtualHost-Konfiguration Apache für eine bestimmte Domain verwenden wird
echo "Hier sehen Sie, welche VirtualHost-Konfiguration für eine Domain verwendet wird:"

SUB=${1:-testsite99}
DOMAIN=${2:-s-neue.website}
FQDN="${SUB}.${DOMAIN}"

echo "Getestet für: $FQDN"
echo

# Verwende curl, um zu sehen, welche Seite für unseren Host-Header tatsächlich angezeigt wird
echo "=== HEADER-TEST ==="
echo "Dieser Test zeigt, welche Webseite tatsächlich ausgeliefert wird:"
echo
echo "1. Mit Domain-Namen im Host-Header:"
curl -s -I -H "Host: $FQDN" "http://localhost" | grep -E '(HTTP|Server|Location)'

echo
echo "2. Mit localhost im Host-Header (sollte Default-Site sein):"
curl -s -I "http://localhost" | grep -E '(HTTP|Server|Location)'

echo
echo "=== DIAGNOSEABSCHLUSS ==="
echo "Wenn beide Tests unterschiedliche Ergebnisse liefern, ist die VirtualHost-Konfiguration korrekt."
echo "Wenn beide gleich sind, wird die falsche Site ausgeliefert."

echo
echo "=== LÖSUNG ==="
echo "1. Deaktivieren Sie die Default-Site: sudo a2dissite 000-default"
echo "2. Stellen Sie sicher, dass ServerName in allen VirtualHosts korrekt ist"
echo "3. Starten Sie Apache neu: sudo systemctl restart apache2"
echo "4. Führen Sie dieses Diagnose-Skript erneut aus"
