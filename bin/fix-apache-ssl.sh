#!/usr/bin/env bash
# =========================================================================
# Website Engine - Apache SSL Fix Script
# =========================================================================
# Dieses Skript repariert fehlende HTTPS-Konfigurationen für WordPress-Sites
# und stellt sicher, dass jede Site sowohl auf HTTP als auch auf HTTPS 
# korrekt funktioniert.
#
# Autor: GitHub Copilot
# Datum: 20. Mai 2025
# =========================================================================

# Farben für bessere Lesbarkeit
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Hilfsfunktionen
print_section() {
  echo -e "\n${BLUE}$1${NC}"
  echo "========================================"
}

print_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}⚠️ $1${NC}"
}

print_error() {
  echo -e "${RED}❌ $1${NC}"
}

# Prüfen, ob das Skript als Root oder mit sudo ausgeführt wird
if [ "$(id -u)" -ne 0 ]; then
  print_error "Dieses Skript muss als Root oder mit sudo ausgeführt werden."
  exit 1
fi

# Module laden
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Versuche verschiedene mögliche Modulpfade
if [[ -d "/opt/website-engine-1.1/modules" ]]; then
    MODULE_DIR="/opt/website-engine-1.1/modules"
elif [[ -d "/opt/website-engine/modules" ]]; then
    MODULE_DIR="/opt/website-engine/modules"
elif [[ -d "$(dirname "$SCRIPT_DIR")/modules" ]]; then
    MODULE_DIR="$(dirname "$SCRIPT_DIR")/modules"
else
    print_error "Kann das Modulverzeichnis nicht finden"
    exit 1
fi

# Sourcen der Module
source "${MODULE_DIR}/config.sh"
source "${MODULE_DIR}/apache.sh"

# Hauptprogramm
print_section "APACHE SSL KONFIGURATION REPARIEREN"
echo "Dieses Skript repariert die SSL-Konfiguration für WordPress-Sites."

# 1. Überprüfen der Wildcard-SSL-Zertifikate
print_section "ÜBERPRÜFE WILDCARD-SSL-ZERTIFIKATE"

if [[ -f "$SSL_CERT_PATH" ]]; then
  if openssl x509 -in "$SSL_CERT_PATH" -text 2>/dev/null | grep -q "DNS:\*\.$DOMAIN"; then
    print_success "Wildcard-Zertifikat für *.$DOMAIN gefunden!"
    
    # Prüfe Ablaufdatum
    cert_end_date=$(openssl x509 -in "$SSL_CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)
    cert_end_epoch=$(date -d "$cert_end_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$cert_end_date" +%s 2>/dev/null)
    now_epoch=$(date +%s)
    days_left=$(( (cert_end_epoch - now_epoch) / 86400 ))
    
    if [[ $days_left -lt 0 ]]; then
      print_error "Wildcard-Zertifikat ist abgelaufen! Ein neues Zertifikat wird erstellt."
      if create_ssl_cert "$DOMAIN" "/var/www/html"; then
        print_success "Neues Hauptzertifikat für $DOMAIN wurde erstellt."
      else
        print_warning "Konnte kein neues Hauptzertifikat erstellen. Überspringe."
      fi
    else
      print_success "Wildcard-Zertifikat ist gültig für weitere $days_left Tage."
    fi
  else
    print_warning "Zertifikat gefunden, ist aber kein Wildcard-Zertifikat."
    print_warning "Wurde das SSL-Zertifikat mit DNS-Validierung erstellt?"
    print_warning "Für ein Wildcard-Zertifikat (*.$DOMAIN) ist ein DNS-Challenge erforderlich."
    
    # Zeige Informationen an
    echo "Aktuelle Zertifikate:"
    ls -la /etc/letsencrypt/live/
  fi
else
  print_warning "Kein SSL-Zertifikat für die Hauptdomain gefunden."
  print_warning "Überprüfe Zertifikatsverzeichnis..."
  
  # Zeige alle Zertifikate an
  if [[ -d "/etc/letsencrypt/live" ]]; then
    ls -la /etc/letsencrypt/live/
  else
    print_error "Keine SSL-Zertifikate gefunden."
    print_warning "Erstelle ein neues Wildcard-Zertifikat..."
    
    if [[ -x "$SCRIPT_DIR/fix-ssl-certificate.sh" ]]; then
      "$SCRIPT_DIR/fix-ssl-certificate.sh"
    else
      print_error "Das SSL-Reparatur-Skript wurde nicht gefunden: $SCRIPT_DIR/fix-ssl-certificate.sh"
    fi
  fi
fi

# 2. Fix Apache Default SSL Configuration
print_section "KORRIGIERE APACHE DEFAULT SSL KONFIGURATION"

DEFAULT_SSL_CONF="/etc/apache2/sites-available/000-default-ssl.conf"
if [[ -f "$DEFAULT_SSL_CONF" ]]; then
  # Prüfe, ob die Default-SSL-Konfiguration mit der Wildcard-Konfiguration kollidiert
  if grep -q "ServerAlias \*\.$DOMAIN" "$DEFAULT_SSL_CONF"; then
    print_warning "Default SSL-Konfiguration könnte mit WordPress-Sites kollidieren."
    print_warning "Aktualisiere Default SSL-Konfiguration..."
    
    # Aktualisiere die Konfiguration, um Konflikte zu vermeiden
    sudo sed -i "s/ServerAlias \*\.$DOMAIN/#ServerAlias \*\.$DOMAIN # Disabled by fix-apache-ssl.sh to avoid conflicts/" "$DEFAULT_SSL_CONF"
    print_success "Default SSL-Konfiguration aktualisiert."
  else
    print_success "Default SSL-Konfiguration scheint bereits korrekt zu sein."
  fi
else
  print_warning "Keine Default SSL-Konfiguration gefunden. Erstelle eine..."
  
  # Erstelle eine minimale SSL-Konfiguration
  cat > "$DEFAULT_SSL_CONF" << EOF
<VirtualHost *:443>
    ServerName $DOMAIN
    # Die folgende Zeile wurde auskommentiert, um Konflikte mit WordPress-Sites zu vermeiden
    # ServerAlias *.$DOMAIN
    
    DocumentRoot /var/www/html
    
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$DOMAIN/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN/privkey.pem
    
    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
  
  # Aktiviere die Konfiguration
  sudo a2ensite 000-default-ssl
  print_success "Default SSL-Konfiguration erstellt und aktiviert."
fi

# 3. Repariere WordPress-Sites
print_section "REPARIERE WORDPRESS-SITES"

# Lade die Funktion aus dem Apache-Modul
echo "Suche WordPress-Installationen in /var/www/..."

# Zähle die gefundenen WordPress-Installationen
WP_COUNT=0
for site_dir in /var/www/*; do
  if [[ -d "$site_dir" && "$site_dir" != "/var/www/html" && -f "$site_dir/wp-config.php" ]]; then
    WP_COUNT=$((WP_COUNT + 1))
  fi
done

echo "Gefunden: $WP_COUNT WordPress-Installationen"

if [[ $WP_COUNT -eq 0 ]]; then
  print_warning "Keine WordPress-Installationen gefunden. Nichts zu reparieren."
else
  echo "Repariere SSL für WordPress-Sites..."
  
  # Für jede WordPress-Installation  
  FIXED_COUNT=0
  FAILED_COUNT=0
  
  for site_dir in /var/www/*; do
    if [[ -d "$site_dir" && "$site_dir" != "/var/www/html" && -f "$site_dir/wp-config.php" ]]; then
      site_name=$(basename "$site_dir")
      echo -n "Repariere SSL für $site_name... "
      
      # Prüfe, ob bereits eine SSL-Konfiguration existiert
      if [[ -f "/etc/apache2/sites-available/${site_name}-ssl.conf" ]]; then
        echo "bereits konfiguriert."
      else
        # Rufe die Funktion fix_site_ssl auf
        if fix_site_ssl "$site_name"; then
          FIXED_COUNT=$((FIXED_COUNT + 1))
          echo "erfolgreich repariert!"
        else
          FAILED_COUNT=$((FAILED_COUNT + 1))
          echo "fehlgeschlagen!"
        fi
      fi
    fi
  done
  
  print_success "$FIXED_COUNT WordPress-Sites wurden repariert. $FAILED_COUNT Sites konnten nicht repariert werden."
fi

# 4. Apache neu starten
print_section "APACHE NEU STARTEN"

# Teste die Apache-Konfiguration
if apache2ctl configtest > /dev/null 2>&1; then
  print_success "Apache-Konfiguration ist gültig."
else
  print_error "Apache-Konfiguration enthält Fehler!"
  apache2ctl configtest
  exit 1
fi

# Apache neu laden
systemctl reload apache2
print_success "Apache wurde neu geladen."

# Abschluss
print_section "REPARATUR ABGESCHLOSSEN"
echo -e "Die SSL-Konfiguration für Apache wurde erfolgreich repariert."
echo -e "\n${BOLD}Nächste Schritte:${NC}"
echo "1. Überprüfen Sie Ihre WordPress-Sites über HTTPS:"
echo "   https://ihre-site.$DOMAIN"
echo
echo "2. Falls Probleme auftreten, prüfen Sie die Apache-Fehlerprotokolle:"
echo "   tail -n 50 /var/log/apache2/error.log"
echo
echo "3. Für weitere Probleme mit SSL-Zertifikaten:"
echo "   sudo $SCRIPT_DIR/fix-ssl-certificate.sh"

exit 0
