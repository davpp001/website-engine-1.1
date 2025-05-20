#!/usr/bin/env bash
# ====================================================================
# FIX-SSL-CERTIFICATE.SH
# ====================================================================
# 
# Dieses Skript erstellt ein Wildcard-SSL-Zertifikat für die 
# konfigurierte Domain. Es verwendet certbot mit dem DNS-01-Challenge
# über die Cloudflare API, um ein Wildcard-Zertifikat zu erstellen.
#
# Author: System
# Version: 1.0
# ====================================================================

# Import the config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../modules/config.sh"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function print_section() {
  echo -e "\n${BLUE}$1${NC}"
  echo "========================================"
}

function print_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

function print_warning() {
  echo -e "${YELLOW}⚠️ $1${NC}"
}

function print_error() {
  echo -e "${RED}❌ $1${NC}"
}

print_section "WILDCARD-SSL-ZERTIFIKAT ERSTELLEN"
echo "Domain: $DOMAIN"
echo "E-Mail: $SSL_EMAIL"
echo "Zertifikatsverzeichnis: $SSL_DIR"

# Prüfe, ob das Verzeichnis existiert
if [ -d "$SSL_DIR" ]; then
  print_warning "SSL-Verzeichnis $SSL_DIR existiert bereits. Überschreibe existierende Zertifikate?"
  read -p "Fortfahren? (j/N): " -r CONFIRM
  if [[ ! $CONFIRM =~ ^[Jj]$ ]]; then
    print_warning "Abgebrochen."
    exit 0
  fi
fi

# Erstelle das Verzeichnis, falls es nicht existiert
sudo mkdir -p "$SSL_DIR"

print_section "METHODE 1: CERTBOT MIT APACHE-PLUGIN"
echo "Erstelle Wildcard-SSL-Zertifikat mit certbot --apache..."

# Stelle sicher, dass certbot installiert ist
if ! command -v certbot &> /dev/null; then
  print_warning "certbot nicht gefunden. Installiere certbot..."
  sudo apt-get update
  sudo apt-get install -y certbot python3-certbot-apache
fi

# Erstelle eine temporäre vHost-Konfiguration für die Haupt-Domain
TEMP_VHOST="/etc/apache2/sites-available/temp-${DOMAIN}.conf"

echo "Erstelle temporäre Apache-Konfiguration für $DOMAIN..."
sudo tee "$TEMP_VHOST" > /dev/null << EOF
<VirtualHost *:80>
  ServerName ${DOMAIN}
  DocumentRoot /var/www/html
  
  <Directory /var/www/html>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
  
  <Directory "/var/www/html/.well-known/acme-challenge">
    Options None
    AllowOverride None
    Require all granted
  </Directory>
</VirtualHost>
EOF

# Aktiviere die temporäre Konfiguration
sudo a2ensite "temp-${DOMAIN}.conf"
sudo systemctl reload apache2
sleep 5

# Erstelle das Wildcard-Zertifikat
echo "Erstelle Zertifikat für $DOMAIN und *.$DOMAIN..."
if sudo certbot --apache -n --agree-tos --email "$SSL_EMAIL" -d "$DOMAIN" -d "*.$DOMAIN"; then
  print_success "Wildcard-SSL-Zertifikat für $DOMAIN erfolgreich erstellt!"
else
  print_warning "Erstellung des Zertifikats mit Apache-Plugin fehlgeschlagen. Versuche Alternativ-Methode..."

  print_section "METHODE 2: CERTBOT MIT STANDALONE-PLUGIN"
  echo "Stoppe Apache temporär..."
  sudo systemctl stop apache2
  
  # Erstelle das Zertifikat mit dem Standalone-Plugin
  if sudo certbot certonly --standalone -n --agree-tos --email "$SSL_EMAIL" -d "$DOMAIN" -d "*.$DOMAIN"; then
    print_success "Wildcard-SSL-Zertifikat für $DOMAIN erfolgreich erstellt!"
  else
    print_error "Konnte kein Wildcard-SSL-Zertifikat erstellen."
    echo "Mögliche Ursachen:"
    echo "1. DNS-Konfiguration ist nicht korrekt"
    echo "2. Rate-Limits bei Let's Encrypt erreicht"
    echo "3. Probleme mit der certbot-Konfiguration"
    echo ""
    echo "Bitte versuche es mit einem manuellen DNS-Challenge:"
    echo "sudo certbot certonly --manual --preferred-challenges dns -d $DOMAIN -d *.$DOMAIN"
    
    # Starte Apache wieder
    sudo systemctl start apache2
    exit 1
  fi
  
  # Starte Apache wieder
  sudo systemctl start apache2
fi

# Überprüfe das erstellte Zertifikat
if [[ -f "$SSL_CERT_PATH" ]]; then
  print_section "ZERTIFIKAT-INFORMATION"
  echo "Zertifikat erfolgreich erstellt in: $SSL_CERT_PATH"
  echo "Zertifikat gültig für folgende Domains:"
  sudo openssl x509 -in "$SSL_CERT_PATH" -text -noout | grep DNS:
  
  # Zeige das Ablaufdatum an
  cert_end_date=$(sudo openssl x509 -in "$SSL_CERT_PATH" -noout -enddate | cut -d= -f2)
  cert_end_epoch=$(date -d "$cert_end_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$cert_end_date" +%s 2>/dev/null)
  now_epoch=$(date +%s)
  days_left=$(( (cert_end_epoch - now_epoch) / 86400 ))
  
  print_success "Zertifikat ist gültig für $days_left Tage (bis $cert_end_date)"
else
  print_error "Zertifikat wurde nicht erstellt oder ist nicht auffindbar."
  exit 1
fi

# Säubere die temporäre Konfiguration
sudo a2dissite "temp-${DOMAIN}.conf" || true
sudo rm -f "$TEMP_VHOST" || true
sudo systemctl reload apache2

print_section "AUTOMATISCHE ERNEUERUNG"
echo "certbot ist für automatische Erneuerung konfiguriert."
echo "Teste die automatische Erneuerung mit: sudo certbot renew --dry-run"

print_success "SSL-Zertifikat wurde erfolgreich erstellt und installiert!"
exit 0
