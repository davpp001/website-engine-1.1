#!/bin/bash
# Erweitertes Diagnose-Skript für das Apache-Konfigurationsproblem
# Führen Sie dieses Skript auf dem Server aus, um detaillierte Informationen zu erhalten

# Farben für bessere Lesbarkeit
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color
BOLD='\033[1m'

echo -e "${BOLD}=== ERWEITERTE APACHE VHOST DIAGNOSE ===${NC}\n"

# Subdomain-Parameter
SUB=${1:-testsite100}
DOMAIN=${2:-s-neue.website}
FQDN="${SUB}.${DOMAIN}"
echo -e "Prüfe Konfiguration für: ${BOLD}${FQDN}${NC}\n"

# Konfigurationsprüfung
echo -e "${BOLD}1. Apache VirtualHost-Konfigurationen:${NC}"
echo "   --- Apache Geladene VirtualHosts ---"
apache2ctl -t -D DUMP_VHOSTS
echo "   -----------------------------------"

echo -e "\n${BOLD}2. Überprüfe, welcher VirtualHost für diese Domain aktiv ist:${NC}"
echo "   Teste mit curl, welche Seite für ${FQDN} ausgeliefert wird:"
echo "   --- Response-Header von ${FQDN} ---"
curl -s -I -H "Host: ${FQDN}" http://localhost | grep -E '(HTTP|Location|Server)'
echo "   ---------------------------------"

# Überprüfung der Apache-Konfigurationsdateien
echo -e "\n${BOLD}3. Überprüfe alle aktivierten Apache-Konfigurationen:${NC}"
SITE_COUNT=$(ls -1 /etc/apache2/sites-enabled/ | wc -l)
echo "   Es gibt ${SITE_COUNT} aktivierte Konfigurationsdateien:"
ls -l /etc/apache2/sites-enabled/
echo

# Überprüfe konkurrierende VirtualHosts
echo -e "${BOLD}4. Überprüfe auf _default_ VirtualHosts:${NC}"
DEFAULT_VHOSTS=$(grep -r "_default_" /etc/apache2/sites-enabled/ --include="*.conf" || echo "Keine _default_ VirtualHosts gefunden")
if [[ "$DEFAULT_VHOSTS" == *"_default_"* ]]; then
  echo -e "   ${YELLOW}⚠️ _default_ VirtualHost-Konfiguration gefunden:${NC}"
  echo "$DEFAULT_VHOSTS"
else
  echo -e "   ${GREEN}✅ Keine _default_ VirtualHost-Konfiguration gefunden${NC}"
fi
echo

# Überprüfe die Priorität der VirtualHosts
echo -e "${BOLD}5. Überprüfe apache2.conf und andere Konfigurationsdateien:${NC}"
if grep -q "IncludeOptional sites-enabled/\*.conf" /etc/apache2/apache2.conf; then
  echo -e "   ${GREEN}✅ sites-enabled/*.conf wird in apache2.conf eingebunden${NC}"
else
  echo -e "   ${RED}❌ sites-enabled/*.conf wird NICHT in apache2.conf eingebunden!${NC}"
fi
echo

# Überprüfung speziell auf einen Fehler in der HTTPS-Weiterleitung
echo -e "${BOLD}6. Überprüfe HTTPS-Redirect-Konfiguration:${NC}"
HTTP_CONF=$(grep -r "Redirect permanent" /etc/apache2/sites-enabled/ --include="*.conf")
if [[ "$HTTP_CONF" == *"Redirect permanent"* ]]; then
  echo -e "   ${YELLOW}⚠️ Einfacher Redirect gefunden, sollte mit RedirectMatch präziser sein:${NC}"
  echo "$HTTP_CONF"
else
  echo -e "   ${GREEN}✅ Keine problematischen einfachen Redirects gefunden${NC}"
fi

# Überprüfung der Module
echo -e "\n${BOLD}7. Überprüfe, ob alle benötigten Module aktiviert sind:${NC}"
MODULES=("rewrite" "ssl" "headers")
for mod in "${MODULES[@]}"; do
  if apache2ctl -M 2>/dev/null | grep -q "$mod"; then
    echo -e "   ${GREEN}✅ Modul $mod ist aktiviert${NC}"
  else
    echo -e "   ${RED}❌ Modul $mod ist NICHT aktiviert!${NC}"
  fi
done
echo

# Test des eigentlichen Problems
echo -e "${BOLD}8. Direkter Test der Website:${NC}"
echo "   Versuche, die Website aufzurufen..."
HTTP_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${FQDN}" http://localhost)
echo -e "   HTTP-Statuscode: ${YELLOW}${HTTP_RESPONSE}${NC}"

if [[ "$HTTP_RESPONSE" == "301" ]]; then
  echo "   Die Website leitet zu HTTPS weiter (erwartet)"
  HTTPS_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${FQDN}" --insecure https://localhost)
  echo -e "   HTTPS-Statuscode: ${YELLOW}${HTTPS_RESPONSE}${NC}"
fi
echo

# Inhalt der relevanten Konfigurationsdatei
echo -e "${BOLD}9. Inhalt der VirtualHost-Konfiguration:${NC}"
if [[ -f "/etc/apache2/sites-enabled/${SUB}.conf" ]]; then
  echo "   --- /etc/apache2/sites-enabled/${SUB}.conf Inhalt ---"
  cat "/etc/apache2/sites-enabled/${SUB}.conf"
  echo "   -------------------------------------------"
else
  echo -e "   ${RED}❌ Konfigurationsdatei für ${SUB} nicht gefunden!${NC}"
fi
echo

# Lösungsvorschläge
echo -e "${BOLD}===== LÖSUNGSVORSCHLÄGE =====${NC}"
echo -e "1. ${YELLOW}Apache neu starten${NC} (nicht nur reload):"
echo "   sudo systemctl restart apache2"
echo
echo -e "2. ${YELLOW}Andere konkurrierende VirtualHosts deaktivieren${NC}:"
echo "   sudo a2dissite testsite44"
echo "   sudo a2dissite testsite99"
echo
echo -e "3. ${YELLOW}Die Default-Site vollständig entfernen${NC}:"
echo "   sudo rm -f /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-enabled/000-default.conf"
echo
echo -e "4. ${YELLOW}Die VirtualHost-Direktive präziser gestalten${NC}:"
echo "   Ersetze '<VirtualHost *:80>' mit '<VirtualHost _default_:80>' und sorge für korrekte ServerName-Einträge"
echo
echo -e "5. ${YELLOW}Überprüfen, ob mod_vhost_alias aktiviert ist${NC}:"
echo "   sudo a2enmod vhost_alias"
echo "   sudo systemctl restart apache2"
