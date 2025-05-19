#!/bin/bash
# Apache-Fix für die Website-Engine
# Löst das Problem mit der Apache Default-Seite statt WordPress
set -e

# Farben für die Ausgabe
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # Keine Farbe

echo -e "${YELLOW}=== WordPress-Site Apache Fix ===${NC}"

# Schritt 1: Default-Site deaktivieren
echo -e "${YELLOW}Schritt 1: Default-Site deaktivieren${NC}"
if [ -e "/etc/apache2/sites-enabled/000-default.conf" ]; then
    sudo a2dissite 000-default
    sudo rm -f /etc/apache2/sites-enabled/000-default.conf
    echo -e "${GREEN}✅ Default-Site deaktiviert${NC}"
else
    echo -e "${GREEN}✅ Default-Site ist bereits deaktiviert${NC}"
fi

# Schritt 2: Alle VirtualHost-Konfigurationen überprüfen und reparieren
echo -e "${YELLOW}Schritt 2: VirtualHost-Konfigurationen reparieren${NC}"

# Alle Konfigurationsdateien durchgehen
for vhost_file in /etc/apache2/sites-available/*.conf; do
    site_name=$(basename "$vhost_file" .conf)
    
    # Überspringe Default-Site und andere spezielle Konfigurationen
    if [[ "$site_name" == "000-default" || "$site_name" == "default-ssl" ]]; then
        continue
    fi
    
    echo -e "${YELLOW}Bearbeite $site_name...${NC}"
    
    # Extrahiere den DocumentRoot und ServerName
    doc_root=$(grep -oP 'DocumentRoot\s+\K[^ ]+' "$vhost_file" | head -1)
    server_name=$(grep -oP 'ServerName\s+\K[^ ]+' "$vhost_file" | head -1)
    
    if [[ -z "$doc_root" ]]; then
        echo -e "${RED}❌ Konnte DocumentRoot nicht ermitteln für $vhost_file${NC}"
        continue
    fi
    
    # Prüfe, ob HTTP-VirtualHost existiert und DocumentRoot enthält
    if grep -q "<VirtualHost \*:80>" "$vhost_file" && ! grep -q "DocumentRoot.*<VirtualHost \*:80>" "$vhost_file"; then
        echo -e "${YELLOW}   Füge DocumentRoot zur HTTP-VirtualHost-Konfiguration hinzu${NC}"
        
        # Temporäre Datei
        tmp_file=$(mktemp)
        
        # DocumentRoot einfügen
        awk '
        /<VirtualHost \*:80>/,/<\/VirtualHost>/ {
            if (/ServerSignature Off/ && !doc_root_added) {
                print $0;
                print "";
                print "  DocumentRoot '"$doc_root"'";
                doc_root_added=1;
                next;
            }
        }
        { print $0 }' "$vhost_file" > "$tmp_file"
        
        # Original mit der aktualisierten Version ersetzen
        sudo cp "$tmp_file" "$vhost_file"
        rm "$tmp_file"
        
        echo -e "${GREEN}   ✅ DocumentRoot hinzugefügt${NC}"
    fi
    
    # Stelle sicher, dass die Konfiguration aktiviert ist
    if [ ! -e "/etc/apache2/sites-enabled/$site_name.conf" ]; then
        echo -e "${YELLOW}   Aktiviere Konfiguration${NC}"
        sudo a2ensite "$site_name"
        
        # Stelle sicher, dass der Symlink erstellt wurde
        if [ ! -e "/etc/apache2/sites-enabled/$site_name.conf" ]; then
            echo -e "${YELLOW}   Erstelle Symlink manuell${NC}"
            sudo ln -sf "/etc/apache2/sites-available/$site_name.conf" "/etc/apache2/sites-enabled/$site_name.conf"
        fi
        
        echo -e "${GREEN}   ✅ Konfiguration aktiviert${NC}"
    fi
done

# Schritt 3: Apache neu starten
echo -e "${YELLOW}Schritt 3: Apache neu starten${NC}"
sudo systemctl restart apache2
echo -e "${GREEN}✅ Apache neu gestartet${NC}"

# Schritt 4: VirtualHost-Konfiguration anzeigen
echo -e "${YELLOW}Schritt 4: VirtualHost-Konfiguration überprüfen${NC}"
sudo apache2ctl -t -D DUMP_VHOSTS | grep -v '(.*\.conf)'

echo -e "${GREEN}✅ Fix abgeschlossen${NC}"
echo -e "${YELLOW}Die WordPress-Sites sollten jetzt korrekt angezeigt werden.${NC}"
