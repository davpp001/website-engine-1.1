#!/bin/bash
# Dieses Skript wird alle Apache-Konfigurationen bereinigen und die bestehenden Konfigurationen optimieren

# Grundlegende Absicherung
set -e

# Farben für Ausgaben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Optimiere Apache-Konfiguration für WordPress-Sites ===${NC}"

# 1. Deaktiviere die Default-Site
echo -e "${YELLOW}Deaktiviere Default-Site...${NC}"
if [ -e "/etc/apache2/sites-enabled/000-default.conf" ]; then
    sudo a2dissite 000-default
    echo -e "${GREEN}✅ Default-Site deaktiviert${NC}"
else
    echo -e "${GREEN}✅ Default-Site bereits deaktiviert${NC}"
fi

# 2. Repariere alle existierenden VirtualHost-Konfigurationen
echo -e "${YELLOW}Repariere VirtualHost-Konfigurationen...${NC}"

# Temporärer Ordner für die Dateibearbeitung
TEMP_DIR=$(mktemp -d)

for vhost_file in /etc/apache2/sites-available/*.conf; do
    filename=$(basename "$vhost_file")
    site_name="${filename%.conf}"
    
    # Überspringe Default-Site und andere spezielle Konfigurationen
    if [[ "$site_name" == "000-default" || "$site_name" == "default-ssl" ]]; then
        continue
    fi
    
    echo -e "${YELLOW}Bearbeite $site_name...${NC}"
    
    # Extrahiere den DocumentRoot
    doc_root=$(grep -oP 'DocumentRoot\s+\K[^ ]+' "$vhost_file" | head -1)
    
    # Finde die ServerName-Direktive
    server_name=$(grep -oP 'ServerName\s+\K[^ ]+' "$vhost_file" | head -1)
    
    # Wenn die Konfigurationsdatei keine VirtualHost-Direktive für Port 80 enthält,
    # oder die DocumentRoot-Direktive fehlt, repariere die Datei
    if ! grep -q "<VirtualHost \*:80>" "$vhost_file" || ! grep -q "DocumentRoot.*<VirtualHost \*:80>" "$vhost_file"; then
        echo "   🔨 Repariere HTTP VirtualHost-Konfiguration für $server_name"
        
        # Erstelle eine aktualisierte Version der Datei
        cp "$vhost_file" "$TEMP_DIR/$filename"
        
        # Füge DocumentRoot zur HTTP-VirtualHost-Konfiguration hinzu, falls erforderlich
        if grep -q "<VirtualHost \*:80>" "$vhost_file" && ! grep -q "DocumentRoot.*<VirtualHost \*:80>" "$vhost_file"; then
            sed -i '/<VirtualHost \*:80>/,/<\/VirtualHost>/ s|ServerSignature Off|ServerSignature Off\n\n  DocumentRoot '"$doc_root"'|' "$TEMP_DIR/$filename"
        fi
        
        # Wende die Änderungen an
        sudo cp "$TEMP_DIR/$filename" "$vhost_file"
    fi
    
    # Stelle sicher, dass die Konfiguration aktiviert ist
    if [ ! -e "/etc/apache2/sites-enabled/$filename" ]; then
        echo "   🔗 Aktiviere Site $site_name"
        sudo a2ensite "$site_name"
    fi
done

# Aufräumen
rm -rf "$TEMP_DIR"

# Apache-Konfiguration testen
echo -e "${YELLOW}Apache-Konfiguration testen...${NC}"
if sudo apache2ctl configtest; then
    echo -e "${GREEN}✅ Apache-Konfiguration ist gültig${NC}"
else
    echo -e "${RED}❌ Apache-Konfiguration enthält Fehler${NC}"
    exit 1
fi

# Apache neu starten
echo -e "${YELLOW}Apache neu starten...${NC}"
sudo systemctl restart apache2

# VirtualHost-Prioritäten anzeigen
echo -e "${YELLOW}VirtualHost-Prioritäten:${NC}"
sudo apache2ctl -t -D DUMP_VHOSTS

echo -e "${GREEN}✅ Apache-Optimierung abgeschlossen!${NC}"
echo -e "${YELLOW}Testen Sie Ihre WordPress-Sites, sie sollten jetzt korrekt funktionieren.${NC}"
