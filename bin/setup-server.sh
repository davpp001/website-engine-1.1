#!/usr/bin/env bash
set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
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

# Show header
print_section "WEBSITE ENGINE - SERVER SETUP"
echo "Dieses Skript richtet die Website Engine Umgebung ein."

# Check if running as root or with sudo
if [ "$(id -u)" -ne 0 ]; then
  print_error "Dieses Skript muss als Root oder mit sudo ausgeführt werden."
  exit 1
fi

# 1. Install required packages
print_section "Installiere benötigte Pakete"
apt-get update
apt-get install -y apache2 mysql-server php php-cli php-mysql php-curl php-xml \
  php-mbstring php-zip php-gd php-intl libapache2-mod-php curl jq certbot python3-certbot-apache

# Install WP-CLI if not already installed
if ! command -v wp >/dev/null 2>&1; then
  print_section "Installiere WP-CLI"
  curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x wp-cli.phar
  mv wp-cli.phar /usr/local/bin/wp
  print_success "WP-CLI installiert"
fi

# Install necessary tools for backups
print_section "Installiere Backup-Tools"
apt-get install -y restic

# 2. Enable Apache modules
print_section "Aktiviere Apache-Module"
a2enmod rewrite ssl
systemctl reload apache2
print_success "Apache-Module aktiviert"

# 3. Create directory structure
print_section "Erstelle Verzeichnisstruktur"
mkdir -p /opt/website-engine/{bin,modules,backup}
mkdir -p /etc/website-engine/{sites,backup}
mkdir -p /var/lib/website-engine
mkdir -p /var/backups/website-engine
mkdir -p /var/log/website-engine 2>/dev/null || true
mkdir -p /var/www

# Setze korrekte Berechtigungen
chown www-data:www-data /var/lib/website-engine
chown www-data:www-data /var/backups/website-engine
chown www-data:www-data /var/www

print_success "Verzeichnisstruktur erstellt"

# 4. Copy files to the right locations
print_section "Kopiere Dateien an die richtigen Orte"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

cp -r "$BASE_DIR/bin/"* /opt/website-engine/bin/
cp -r "$BASE_DIR/modules/"* /opt/website-engine/modules/
cp -r "$BASE_DIR/backup/"* /opt/website-engine/backup/ 2>/dev/null || true
print_success "Dateien kopiert"

# 5. Make scripts executable
chmod +x /opt/website-engine/bin/*.sh
chmod +x /opt/website-engine/modules/*.sh
print_success "Skripte ausführbar gemacht"

# 6. Create symlinks
print_section "Erstelle Symlinks für Befehle"
ln -sf /opt/website-engine/bin/create-site.sh /usr/local/bin/create-site
ln -sf /opt/website-engine/bin/delete-site.sh /usr/local/bin/delete-site
ln -sf /opt/website-engine/bin/direct-ssl.sh /usr/local/bin/direct-ssl
ln -sf /opt/website-engine/bin/setup-server.sh /usr/local/bin/setup-server
print_success "Symlinks erstellt"

# 7. Set up environment files
print_section "Erstelle Umgebungsdateien"

# Cloudflare-Konfiguration
print_section "Cloudflare-Konfiguration"
echo "Möchtest du jetzt deine Cloudflare-API-Daten einrichten? (j/n)"
read -r setup_cloudflare

if [[ "$setup_cloudflare" =~ ^[jJ] ]]; then
  echo "Bitte gib deinen Cloudflare API-Token ein:"
  read -r cf_token
  
  echo "Bitte gib deine Cloudflare Zone-ID ein:"
  read -r zone_id
  
  # Werte speichern
  cat > /etc/profile.d/cloudflare.sh << EOF
export CF_API_TOKEN="$cf_token"
export ZONE_ID="$zone_id"
EOF
  chmod +x /etc/profile.d/cloudflare.sh
  
  # Umgebungsvariablen sofort laden
  export CF_API_TOKEN="$cf_token"
  export ZONE_ID="$zone_id"
  
  print_success "Cloudflare-Konfiguration gespeichert und geladen"
else
  # Standard-Template erstellen
  cat > /etc/profile.d/cloudflare.sh << EOF
export CF_API_TOKEN="DEIN_CLOUDFLARE_TOKEN"
export ZONE_ID="DEINE_ZONE_ID"
EOF
  chmod +x /etc/profile.d/cloudflare.sh
  print_warning "Cloudflare-Konfiguration wurde nicht eingerichtet. Du kannst dies später tun, indem du /etc/profile.d/cloudflare.sh bearbeitest."
fi

# WordPress credentials
cat > /etc/website-engine/credentials.env << EOF
# WordPress-Admin-Zugangsdaten
DB_USER="we-admin"
DB_PASS="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
WP_USER="admin"
WP_PASS="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
EOF
chmod 600 /etc/website-engine/credentials.env

# WordPress-Zugangsdaten anzeigen und speichern
WP_PASS=$(grep "WP_PASS" /etc/website-engine/credentials.env | cut -d'"' -f2)
print_section "WordPress-Zugangsdaten"
echo "WordPress-Admin-Benutzer: admin"
echo "WordPress-Admin-Passwort: $WP_PASS"
echo "Diese Anmeldedaten werden für alle neuen WordPress-Installationen verwendet."
echo "Bitte notiere dir das Passwort!"

print_success "Umgebungsdateien erstellt"

# 8. Set up SSL certificate (using certbot --apache method)
print_section "Richte SSL-Zertifikat ein (mit certbot --apache)"
SERVER_IP=$(curl -s https://ifconfig.me)
SERVER_DOMAIN="$(grep DOMAIN= /opt/website-engine/modules/config.sh | cut -d'"' -f2)"

if [[ -z "$SERVER_DOMAIN" ]]; then
  print_warning "Domain konnte nicht aus der Konfiguration gelesen werden."
  SERVER_DOMAIN="s-neue.website"
fi

# Admin-E-Mail-Adresse abfragen
echo "Bitte gib die Admin-E-Mail für das SSL-Zertifikat ein (Standard: admin@$SERVER_DOMAIN):"
read -r SSL_EMAIL
SSL_EMAIL=${SSL_EMAIL:-"admin@$SERVER_DOMAIN"}

echo "Soll ein Wildcard-Zertifikat (*.domain.com) erstellt werden? Das erfordert ggf. DNS-Plugins. (j/n)"
read -r wildcard_response

if [[ "$wildcard_response" =~ ^[jJ] ]]; then
  print_warning "Versuche ein Wildcard-SSL-Zertifikat für *.$SERVER_DOMAIN zu erstellen..."
  
  # Prüfen, ob DNS-Plugin installiert ist
  if dpkg -l | grep -q "python3-certbot-dns-cloudflare"; then
    print_success "DNS-Plugin für Cloudflare gefunden"
    echo "Hinweis: Für ein Wildcard-Zertifikat wird die Datei /etc/letsencrypt/cloudflare/credentials.ini benötigt."
    echo "Mit deinen Cloudflare API-Zugangsdaten. Erstelle diese, falls noch nicht geschehen."
    
    if certbot certonly --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare/credentials.ini \
      -d "$SERVER_DOMAIN" -d "*.$SERVER_DOMAIN" --agree-tos --email "$SSL_EMAIL"; then
      print_success "Wildcard-SSL-Zertifikat erfolgreich erstellt!"
    else
      print_warning "Wildcard-Zertifikat konnte nicht erstellt werden. Erstelle Standard-Zertifikat..."
      certbot --apache -d "$SERVER_DOMAIN" --agree-tos --email "$SSL_EMAIL"
      print_success "Standard-SSL-Zertifikat erstellt"
    fi
  else
    print_warning "Kein DNS-Plugin für Certbot gefunden. Erstelle Standard-Zertifikat..."
    certbot --apache -d "$SERVER_DOMAIN" --agree-tos --email "$SSL_EMAIL"
    print_success "Standard-SSL-Zertifikat erstellt"
    echo "Für ein Wildcard-Zertifikat installiere: sudo apt-get install python3-certbot-dns-cloudflare"
  fi
else
  print_warning "Erstelle Standard-SSL-Zertifikat für $SERVER_DOMAIN..."
  if certbot --apache -d "$SERVER_DOMAIN" --agree-tos --email "$SSL_EMAIL"; then
    print_success "Standard-SSL-Zertifikat erfolgreich erstellt!"
  else
    print_error "SSL-Zertifikat konnte nicht erstellt werden."
    print_warning "SSL-Zertifikat muss manuell eingerichtet werden."
    echo "Später mit folgendem Befehl:"
    echo "certbot --apache -d $SERVER_DOMAIN --agree-tos --email $SSL_EMAIL"
  fi
fi

# 5. Installiere Wildcard-SSL-Zertifikat
print_section "Installiere Wildcard-SSL-Zertifikat"

# Überprüfe, ob die Cloudflare-API-Zugangsdaten vorhanden sind
if [[ ! -f "/etc/letsencrypt/cloudflare.ini" ]]; then
  print_error "Cloudflare-API-Zugangsdaten fehlen. Bitte erstellen Sie die Datei /etc/letsencrypt/cloudflare.ini."
  exit 1
fi

# Setze Berechtigungen für die Zugangsdaten
chmod 600 /etc/letsencrypt/cloudflare.ini

# Erstelle Wildcard-Zertifikat mit certbot und der DNS-01-Challenge
if certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  --agree-tos \
  --email admin@domain.com \
  -d "*.domain.com" \
  --non-interactive; then
  print_success "Wildcard-SSL-Zertifikat erfolgreich installiert"
else
  print_error "Fehler bei der Installation des Wildcard-SSL-Zertifikats"
  exit 1
fi

# Konfiguriere Apache für die Verwendung des Wildcard-Zertifikats
print_section "Konfiguriere Apache für Wildcard-SSL"
cat <<EOF > /etc/apache2/sites-available/000-default-ssl.conf
<VirtualHost *:443>
    ServerName domain.com
    ServerAlias *.domain.com

    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/domain.com/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/domain.com/privkey.pem

    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

a2ensite 000-default-ssl
systemctl reload apache2
print_success "Apache für Wildcard-SSL konfiguriert"

# 9. Set up backup scripts
print_section "Richte Backup-System ein"

# Erforderliche Verzeichnisse
mkdir -p /var/backups/mysql
chmod 700 /var/backups/mysql
mkdir -p /etc/website-engine/backup
chmod 750 /etc/website-engine/backup

# Kopiere alle Backup-Skripte
cp -f "$BASE_DIR/backup/"*.sh /opt/website-engine/backup/
chmod +x /opt/website-engine/backup/*.sh
print_success "Backup-Skripte kopiert"

# Backup-Konfiguration einrichten
source "/opt/website-engine/modules/config.sh"

print_section "Backup-Konfiguration"
echo "Möchtest du jetzt die Backup-Systeme konfigurieren? (j/n)"
read -r setup_backup

if [[ "$setup_backup" =~ ^[jJ] ]]; then
  # Prüfen, ob die Funktion verfügbar ist
  if type configure_backup_systems &>/dev/null; then
    configure_backup_systems
    print_success "Backup-Systeme wurden konfiguriert"
  else
    print_warning "Die Funktion configure_backup_systems wurde nicht gefunden."
    print_warning "Möglicherweise wird eine ältere Version von config.sh verwendet."
    
    # Erstelle IONOS-Konfigurationsdatei aus Template
    if [[ -f "$BASE_DIR/backup/ionos.env.template" ]]; then
      cp "$BASE_DIR/backup/ionos.env.template" /etc/website-engine/backup/ionos.env
      chmod 600 /etc/website-engine/backup/ionos.env
      print_success "IONOS-Konfigurationsvorlage erstellt"
    else 
      print_warning "IONOS-Template nicht gefunden. Erstelle leere Konfiguration"
      cat > /etc/website-engine/backup/ionos.env << 'EOF'
# IONOS Cloud API Konfiguration
IONOS_TOKEN=""
IONOS_SERVER_ID=""
IONOS_VOLUME_ID=""
EOF
      chmod 600 /etc/website-engine/backup/ionos.env
    fi

    # Erstelle Restic-Konfigurationsdatei
    cat > /etc/website-engine/backup/restic.env << 'EOF'
# Restic configuration
export RESTIC_REPOSITORY=""  # z.B. s3:https://s3.eu-central-3.ionoscloud.com/my-backups
export RESTIC_PASSWORD=""    # Ein sicheres Passwort für die Repository-Verschlüsselung
export AWS_ACCESS_KEY_ID=""  # S3 Access Key
export AWS_SECRET_ACCESS_KEY="" # S3 Secret Key
EOF
    chmod 600 /etc/website-engine/backup/restic.env
    
    print_warning "Die Backup-Konfigurationsdateien wurden erstellt, müssen aber manuell bearbeitet werden."
  fi
else
  # Erstelle leere Konfigurationsdateien für spätere Verwendung
  print_warning "Backup-Systeme werden nicht jetzt konfiguriert."
  
  # Erstelle IONOS-Konfigurationsdatei aus Template
  if [[ -f "$BASE_DIR/backup/ionos.env.template" ]]; then
    cp "$BASE_DIR/backup/ionos.env.template" /etc/website-engine/backup/ionos.env
    chmod 600 /etc/website-engine/backup/ionos.env
    print_success "IONOS-Konfigurationsvorlage erstellt"
  else 
    print_warning "IONOS-Template nicht gefunden. Erstelle leere Konfiguration"
    cat > /etc/website-engine/backup/ionos.env << 'EOF'
# IONOS Cloud API Konfiguration
IONOS_TOKEN=""
IONOS_SERVER_ID=""
IONOS_VOLUME_ID=""
EOF
    chmod 600 /etc/website-engine/backup/ionos.env
  fi

  # Erstelle Restic-Konfigurationsdatei
  cat > /etc/website-engine/backup/restic.env << 'EOF'
# Restic configuration
export RESTIC_REPOSITORY=""  # z.B. s3:https://s3.eu-central-3.ionoscloud.com/my-backups
export RESTIC_PASSWORD=""    # Ein sicheres Passwort für die Repository-Verschlüsselung
export AWS_ACCESS_KEY_ID=""  # S3 Access Key
export AWS_SECRET_ACCESS_KEY="" # S3 Secret Key
EOF
  chmod 600 /etc/website-engine/backup/restic.env
  print_warning "Du kannst die Backup-Systeme später über die Backup-Skripte konfigurieren."
fi

# Erstelle Symlinks für Backup-Befehle
ln -sf /opt/website-engine/backup/backup-all.sh /usr/local/bin/website-backup
ln -sf /opt/website-engine/backup/restore.sh /usr/local/bin/website-restore
ln -sf /opt/website-engine/backup/secrets-encrypt.sh /usr/local/bin/website-secrets
print_success "Backup-Befehlssymlinks erstellt"

# Setup cron jobs
print_section "Richte Cron-Jobs ein"
(crontab -l 2>/dev/null || true; echo "0 3 * * * /opt/website-engine/backup/backup-all.sh --mysql") | crontab -
(crontab -l 2>/dev/null || true; echo "0 1 * * * /opt/website-engine/backup/ionos-snapshot.sh") | crontab -
(crontab -l 2>/dev/null || true; echo "30 2 * * * /opt/website-engine/backup/backup-all.sh --restic") | crontab -
print_success "Cron-Jobs eingerichtet"

# Verschlüsselung für sensible Dateien anbieten
print_section "Sichere Konfiguration"
echo "Möchten Sie sensible Konfigurationsdateien verschlüsseln? (j/n)"
read -r response
if [[ "$response" =~ ^[jJyY] ]]; then
  echo "Starte Verschlüsselung mit website-secrets..."
  /usr/local/bin/website-secrets encrypt
  print_success "Verschlüsselung abgeschlossen"
else
  print_warning "Konfigurationsdateien wurden nicht verschlüsselt. Sie können dies später mit 'website-secrets encrypt' nachholen."
fi

# 10. Final check
print_section "Abschließende Prüfung"
# Check command symlinks
for cmd in create-site delete-site setup-server; do
  if [ -L "/usr/local/bin/$cmd" ]; then
    print_success "Befehl $cmd ist korrekt verlinkt"
  else
    print_error "Befehl $cmd ist nicht korrekt verlinkt"
  fi
done

# Check Apache is running
if systemctl is-active --quiet apache2; then
  print_success "Apache läuft"
else
  print_error "Apache läuft nicht"
fi

# Check required directories
for dir in /opt/website-engine /etc/website-engine; do
  if [ -d "$dir" ]; then
    print_success "Verzeichnis $dir existiert"
  else
    print_error "Verzeichnis $dir fehlt"
  fi
done

# 11. Instructions for the user
print_section "SETUP ABGESCHLOSSEN"
echo -e "${GREEN}Dein Server ist jetzt eingerichtet!${NC}"
echo

# Prüfen, ob Cloudflare konfiguriert wurde
if [[ -n "${CF_API_TOKEN:-}" && -n "${ZONE_ID:-}" ]]; then
  CF_CONFIGURED=1
else
  CF_CONFIGURED=0
fi

echo -e "${YELLOW}Nächste Schritte:${NC}"

if [[ $CF_CONFIGURED -eq 0 ]]; then
  echo "1. Cloudflare-Anmeldedaten einrichten (falls noch nicht erfolgt):"
  echo "   Bearbeite /etc/profile.d/cloudflare.sh und füge deine API-Token ein"
  echo "   Dann führe aus: source /etc/profile.d/cloudflare.sh"
  echo
fi

# Prüfen, ob Backup-Systeme konfiguriert wurden
IONOS_CONFIG="/etc/website-engine/backup/ionos.env"
RESTIC_CONFIG="/etc/website-engine/backup/restic.env"
BACKUP_CONFIGURED=1

# Prüfe IONOS-Konfiguration
if [[ -f "$IONOS_CONFIG" ]]; then
  source "$IONOS_CONFIG" 2>/dev/null || true
  if [[ -z "${IONOS_TOKEN:-}" || -z "${IONOS_SERVER_ID:-}" || -z "${IONOS_VOLUME_ID:-}" ]]; then
    BACKUP_CONFIGURED=0
  fi
else
  BACKUP_CONFIGURED=0
fi

# Prüfe Restic-Konfiguration
if [[ -f "$RESTIC_CONFIG" ]]; then
  source "$RESTIC_CONFIG" 2>/dev/null || true
  if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD:-}" ]]; then
    BACKUP_CONFIGURED=0
  fi
else
  BACKUP_CONFIGURED=0
fi

if [[ $BACKUP_CONFIGURED -eq 0 ]]; then
  echo "1. Backup-System konfigurieren (noch nicht vollständig eingerichtet):"
  echo "   - Konfiguriere automatisch mit: /opt/website-engine/backup/backup-all.sh"
  echo "   - Oder manuelle Konfiguration:"
  echo "     - IONOS-Snapshots: Bearbeite /etc/website-engine/backup/ionos.env"
  echo "     - Restic-Backups: Bearbeite /etc/website-engine/backup/restic.env"
  echo "   - Verschlüssele sensible Dateien mit: website-secrets encrypt"
  echo "   - Manuelles Backup ausführen: website-backup --all"
else
  echo "1. Backup-System ist konfiguriert. Weitere Optionen:"
  echo "   - Manuelles Backup ausführen: website-backup --all"
  echo "   - Sensible Dateien verschlüsseln: website-secrets encrypt"
  echo "   - Backup-Konfiguration anpassen: bearbeite /etc/website-engine/backup/*.env"
fi
echo
echo "2. Subdomain mit WordPress erstellen:"
echo "   create-site kunde1"
echo
echo "3. Im Testmodus (ohne DNS) erstellen:"
echo "   create-site testkunde --test"
echo
echo "4. Subdomain mit WordPress löschen:"
echo "   delete-site kunde1"
echo

# WordPress-Zugangsdaten noch einmal anzeigen
WP_PASS=$(grep "WP_PASS" /etc/website-engine/credentials.env | cut -d'"' -f2)
echo -e "${YELLOW}WordPress-Admin-Zugangsdaten:${NC}"
echo "Benutzer: admin"
echo "Passwort: $WP_PASS"
echo

echo -e "${GREEN}Deine Server-IP ist: $SERVER_IP${NC}"