#!/usr/bin/env bash
# ====================================================================
# FIX-SSL-CERTIFICATE.SH (KORRIGIERTE VERSION)
# ====================================================================
# 
# Dieses Skript erstellt ein SSL-Zertifikat (Wildcard oder selbstsigniert)
# für die konfigurierte Domain. Es versucht zuerst Let's Encrypt und
# erstellt bei Fehlschlag ein selbstsigniertes Zertifikat als Fallback.
#
# Author: GitHub Copilot
# Version: 1.1
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

# Funktion zum Erstellen eines selbstsignierten Zertifikats
function create_self_signed_cert() {
  print_section "ERSTELLE SELBSTSIGNIERTES ZERTIFIKAT"
  echo "Domain: $DOMAIN"
  echo "SSL-Verzeichnis: $SSL_DIR"
  
  # Erstelle SSL-Verzeichnis
  sudo mkdir -p "$SSL_DIR"
  
  # Erstelle eine OpenSSL-Konfigurationsdatei für das Wildcard-Zertifikat
  cat > /tmp/openssl.cnf <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C=DE
ST=Bayern
L=München
O=Website Engine
OU=Server
CN=$DOMAIN

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
DNS.2 = *.$DOMAIN
EOF

  # Erstelle einen privaten Schlüssel und ein selbstsigniertes Zertifikat
  sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -config /tmp/openssl.cnf \
    -keyout "$SSL_DIR/privkey.pem" \
    -out "$SSL_DIR/fullchain.pem"
    
  # Erstelle auch die anderen erforderlichen Dateien
  sudo cp "$SSL_DIR/fullchain.pem" "$SSL_DIR/cert.pem"
  sudo cp "$SSL_DIR/fullchain.pem" "$SSL_DIR/chain.pem"
  
  # Setze korrekte Berechtigungen
  sudo chmod 600 "$SSL_DIR/privkey.pem"
  sudo chmod 644 "$SSL_DIR/fullchain.pem" "$SSL_DIR/cert.pem" "$SSL_DIR/chain.pem"
  
  # Lösche temporäre Dateien
  rm -f /tmp/openssl.cnf
  
  # Überprüfe das erstellte Zertifikat
  if [[ -f "$SSL_CERT_PATH" ]]; then
    echo "Zertifikat erfolgreich erstellt in: $SSL_CERT_PATH"
    echo "Zertifikat gültig für folgende Domains:"
    sudo openssl x509 -in "$SSL_CERT_PATH" -text -noout | grep DNS:
    
    # Zeige das Ablaufdatum an
    cert_end_date=$(sudo openssl x509 -in "$SSL_CERT_PATH" -noout -enddate | cut -d= -f2)
    cert_end_epoch=$(date -d "$cert_end_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$cert_end_date" +%s 2>/dev/null)
    now_epoch=$(date +%s)
    days_left=$(( (cert_end_epoch - now_epoch) / 86400 ))
    
    print_success "Selbstsigniertes Zertifikat ist gültig für $days_left Tage (bis $cert_end_date)"
    print_warning "HINWEIS: Dies ist ein selbstsigniertes Zertifikat. Browser werden eine Sicherheitswarnung anzeigen."
    return 0
  else
    print_error "Selbstsigniertes Zertifikat konnte nicht erstellt werden."
    return 1
  fi
}

print_section "SSL-ZERTIFIKAT ERSTELLEN"
echo "Domain: $DOMAIN"
echo "E-Mail: $SSL_EMAIL"
echo "Zertifikatsverzeichnis: $SSL_DIR"

# Prüfe, ob es sich um eine lokale/Test-Umgebung handelt
IS_LOCAL_ENV=0
if ! ping -c 1 -W 2 "$DOMAIN" &>/dev/null; then
  print_warning "Domain $DOMAIN ist nicht erreichbar. Dies scheint eine lokale Testumgebung zu sein."
  IS_LOCAL_ENV=1
fi

# Prüfe, ob das Verzeichnis existiert
if [ -d "$SSL_DIR" ]; then
  print_warning "SSL-Verzeichnis $SSL_DIR existiert bereits. Überschreibe existierende Zertifikate?"
  read -p "Fortfahren? (j/N): " -r CONFIRM
  if [[ ! $CONFIRM =~ ^[Jj]$ ]]; then
    print_warning "Abgebrochen."
    exit 0
  fi
  
  # Sichere Backup der alten Zertifikate
  if [ -f "$SSL_CERT_PATH" ]; then
    BACKUP_DIR="/tmp/ssl-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    sudo cp -a "$SSL_DIR"/* "$BACKUP_DIR/"
    print_success "Backup der alten Zertifikate erstellt in: $BACKUP_DIR"
  fi
fi

# Erstelle das Verzeichnis, falls es nicht existiert
sudo mkdir -p "$SSL_DIR"

# Wenn es eine lokale Umgebung ist, erstelle direkt selbstsignierte Zertifikate
if [ "$IS_LOCAL_ENV" -eq 1 ]; then
  print_warning "Lokale Testumgebung erkannt - erstelle ein selbstsigniertes Zertifikat"
  create_self_signed_cert
  
  print_section "SSL-ZERTIFIKAT ERSTELLT"
  print_success "Selbstsigniertes SSL-Zertifikat wurde erfolgreich erstellt!"
  exit 0
fi

# Versuche Let's Encrypt (für Produktionsumgebungen) mit DNS-Challenge
print_section "LET'S ENCRYPT MIT DNS-CHALLENGE"
echo "Prüfe, ob DNS-Plugins für Certbot verfügbar sind..."

# Prüfe verfügbare DNS-Plugins
DNS_PLUGIN=""
if command -v certbot >/dev/null 2>&1; then
  if dpkg -l | grep -q python3-certbot-dns-cloudflare; then
    DNS_PLUGIN="dns-cloudflare"
    print_success "Cloudflare DNS-Plugin gefunden"
  elif dpkg -l | grep -q python3-certbot-dns-route53; then
    DNS_PLUGIN="dns-route53"
    print_success "Route53 DNS-Plugin gefunden"
  else
    print_warning "Keine DNS-Plugins für Certbot gefunden"
    print_warning "Installiere Cloudflare DNS-Plugin..."
    sudo apt-get update
    sudo apt-get install -y python3-certbot-dns-cloudflare
    if [ $? -eq 0 ]; then
      DNS_PLUGIN="dns-cloudflare"
      print_success "Cloudflare DNS-Plugin installiert"
    fi
  fi
else
  print_warning "Certbot ist nicht installiert"
  print_warning "Installiere Certbot und DNS-Plugins..."
  sudo apt-get update
  sudo apt-get install -y certbot python3-certbot-dns-cloudflare
  if [ $? -eq 0 ]; then
    DNS_PLUGIN="dns-cloudflare"
    print_success "Certbot und Cloudflare DNS-Plugin installiert"
  fi
fi

# Wenn ein DNS-Plugin gefunden wurde, versuche Let's Encrypt mit DNS-Challenge
if [ -n "$DNS_PLUGIN" ]; then
  print_warning "Für den automatischen DNS-Challenge benötigen Sie eine konfigurierte Cloudflare API-Schlüsseldatei."
  
  # Prüfe, ob die Cloudflare-Konfigurationsdatei existiert
  CF_CONFIG="/root/.secrets/certbot/cloudflare.ini"
  if [ ! -f "$CF_CONFIG" ]; then
    print_warning "Cloudflare-Konfigurationsdatei nicht gefunden: $CF_CONFIG"
    print_warning "Erstelle Beispielkonfigurationsdatei..."
    
    sudo mkdir -p "$(dirname "$CF_CONFIG")"
    sudo tee "$CF_CONFIG" > /dev/null << EOF
# Cloudflare API credentials used by Certbot
dns_cloudflare_email = your_email@example.com
dns_cloudflare_api_key = 0123456789abcdef0123456789abcdef01234567
EOF
    sudo chmod 600 "$CF_CONFIG"
    
    print_warning "Bitte bearbeiten Sie die Datei mit Ihren Cloudflare-Anmeldedaten:"
    print_warning "sudo nano $CF_CONFIG"
    print_warning "Dann führen Sie dieses Skript erneut aus."
    
    print_section "SSL-ZERTIFIKAT: MANUELLER SCHRITT ERFORDERLICH"
    print_warning "Da Let's Encrypt-Zertifikate für Wildcard-Domains einen DNS-Challenge benötigen,"
    print_warning "und die Cloudflare-API-Konfiguration noch nicht eingerichtet ist,"
    print_warning "erstellen wir stattdessen ein selbstsigniertes Zertifikat als Fallback."
    
    if [ -f "$SSL_CERT_PATH" ]; then
      print_warning "Vorhandenes Zertifikat gefunden, wird verwendet"
    else
      create_self_signed_cert
    fi
    
    exit 0
  fi
  
  # Versuche Let's Encrypt mit DNS-Challenge
  echo "Erstelle Zertifikat für $DOMAIN und *.$DOMAIN mit DNS-Challenge..."
  sudo certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CONFIG" \
    --non-interactive --agree-tos --email "$SSL_EMAIL" \
    -d "$DOMAIN" -d "*.$DOMAIN"
  
  if [ $? -eq 0 ]; then
    print_success "Let's Encrypt Wildcard-Zertifikat für $DOMAIN erfolgreich erstellt!"
  else
    print_error "Let's Encrypt mit DNS-Challenge fehlgeschlagen, erstelle selbstsigniertes Zertifikat als Fallback..."
    create_self_signed_cert
  fi
else
  print_warning "Kein DNS-Plugin für Let's Encrypt verfügbar"
  print_warning "Für ein Wildcard-Zertifikat ist ein DNS-Challenge erforderlich"
  print_warning "Erstelle stattdessen ein selbstsigniertes Zertifikat..."
  
  create_self_signed_cert
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
  
  # Prüfe, ob es ein selbstsigniertes Zertifikat ist
  if sudo openssl x509 -in "$SSL_CERT_PATH" -noout -issuer | grep -q "CN=$DOMAIN"; then
    print_warning "Dies ist ein selbstsigniertes Zertifikat. Browser werden eine Sicherheitswarnung anzeigen."
  fi
else
  print_error "Zertifikat wurde nicht erstellt oder ist nicht auffindbar."
  exit 1
fi

print_section "AUTOMATISCHE ERNEUERUNG"
if sudo openssl x509 -in "$SSL_CERT_PATH" -noout -issuer | grep -q "Let's Encrypt"; then
  echo "Let's Encrypt-Zertifikat ist für automatische Erneuerung konfiguriert."
  echo "Teste die automatische Erneuerung mit: sudo certbot renew --dry-run"
else
  echo "Selbstsigniertes Zertifikat muss manuell erneuert werden."
  echo "Es ist gültig für $days_left Tage (bis $cert_end_date)."
fi

print_success "SSL-Zertifikat wurde erfolgreich erstellt und installiert!"
exit 0
