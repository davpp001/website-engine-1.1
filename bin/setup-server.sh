#!/usr/bin/env bash
# Error handling entfernt, um das Skript nicht bei Fehlern abzubrechen
# Wir behandeln Fehler selbst innerhalb des Skripts

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

# Neue Funktion zur Bereinigung des Servers
function reset_server() {
  local RESET_LEVEL="$1"
  
  print_section "SERVERBEREINIGUNG (Level: $RESET_LEVEL)"
  
  # Stoppt Apache, um Probleme bei der Bereinigung zu vermeiden
  echo "Stoppe Apache-Webserver..."
  systemctl stop apache2 || true
  
  # Immer durchzuführende Aufgaben (Minimalreset)
  if [[ "$RESET_LEVEL" == "minimal" || "$RESET_LEVEL" == "standard" || "$RESET_LEVEL" == "full" ]]; then
    echo "Bereinige Apache-Konfigurationen..."
    
    # Deaktiviere alle Sites außer der Default-Site
    find /etc/apache2/sites-enabled/ -type l ! -name "000-default.conf" -delete || true
    
    # Entferne alle VirtualHost-Konfigurationen außer der Default-Site
    find /etc/apache2/sites-available/ -type f ! -name "000-default.conf" ! -name "default-ssl.conf" -delete || true
    
    # Entferne -temp-le-ssl.conf-Dateien
    find /etc/apache2/sites-available/ -name "*-temp-le-ssl.conf" -type f -delete || true
    
    # Sicherstellen, dass die Standard-Konfiguration existiert
    if [ ! -f "/etc/apache2/sites-available/000-default.conf" ]; then
      cat > /etc/apache2/sites-available/000-default.conf << EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
      print_success "Standard-Konfiguration (000-default.conf) erstellt"
    fi
    
    # Aktiviere die Standard-Konfiguration
    if [ ! -L "/etc/apache2/sites-enabled/000-default.conf" ]; then
      cleanup_apache_configs ""  # Alle alten Sites löschen
      a2ensite 000-default &>/dev/null || true
      print_success "Standard-Site aktiviert"
    fi
    
    print_success "Apache-Konfigurationen bereinigt"
  fi
  
  # Standard-Reset (zusätzliche Aufgaben) - Zertifikate löschen
  if [[ "$RESET_LEVEL" == "standard" || "$RESET_LEVEL" == "full" ]]; then
    echo "Führe Standard-Reset durch..."
    
    # Lösche alle SSL-Zertifikate für Subdomains, behalte aber die Hauptdomain-Zertifikate
    local MAIN_DOMAIN=$(grep DOMAIN= /opt/website-engine-1.1/modules/config.sh 2>/dev/null | cut -d'"' -f2 || echo "")
    if [[ -n "$MAIN_DOMAIN" && -d "/etc/letsencrypt/live" ]]; then
      for cert_dir in /etc/letsencrypt/live/*; do
        if [[ -d "$cert_dir" ]]; then
          local cert_name=$(basename "$cert_dir")
          if [[ "$cert_name" != "$MAIN_DOMAIN" && "$cert_name" != "*.$MAIN_DOMAIN" ]]; then
            print_warning "Entferne SSL-Zertifikat: $cert_name"
            certbot delete --cert-name "$cert_name" --non-interactive || true
          fi
        fi
      done
    fi
    
    print_success "Standard-Reset abgeschlossen"
  fi
  
  # Vollständiger Reset (zusätzliche Aufgaben)
  if [[ "$RESET_LEVEL" == "full" ]]; then
    echo "Führe vollständigen Reset durch..."
    
    # Zuerst alle SSL-Zertifikate entfernen (vor dem Neustart von Apache)
    echo "Entferne alle SSL-Zertifikate..."
    rm -rf /etc/letsencrypt/live/* /etc/letsencrypt/archive/* /etc/letsencrypt/renewal/* || true
    
    # Dann erst die Webverzeichnisse bereinigen
    echo "Leere /var/www/* (außer /var/www/html)"
    find /var/www -mindepth 1 -maxdepth 1 -type d ! -name "html" -exec rm -rf {} \; 2>/dev/null || true
    
    # MySQL-Datenbanken bereinigen (außer System-DBs) - robustere Implementierung
    echo "Bereinige MySQL-Datenbanken..."
    # Speichere Befehle in temporärer Datei
    {
      mysql -e "SELECT CONCAT('DROP DATABASE IF EXISTS ', schema_name, ';') 
                FROM information_schema.schemata 
                WHERE schema_name NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')" 2>/dev/null || echo "# MySQL-Abfrage fehlgeschlagen"
    } | grep -v "CONCAT" > /tmp/drop_db_commands.sql || true
    
    # Wenn die Datei existiert und nicht leer ist, führe die Befehle aus
    if [ -s /tmp/drop_db_commands.sql ]; then
      while IFS= read -r drop_cmd; do
        # Überspringe Kommentarzeilen
        [[ "$drop_cmd" =~ ^#.*$ ]] && continue
        echo "  - Lösche Datenbank: ${drop_cmd}"
        mysql -e "${drop_cmd}" 2>/dev/null || true
      done < /tmp/drop_db_commands.sql
    else
      echo "  Keine benutzerdefinierten Datenbanken gefunden."
    fi
    rm -f /tmp/drop_db_commands.sql
    
    # MySQL-Benutzer bereinigen - robustere Implementierung
    echo "Bereinige MySQL-Benutzer..."
    # Speichere Befehle in temporärer Datei
    {
      mysql -e "SELECT CONCAT('DROP USER IF EXISTS ''', user, '''@''', host, ''';') 
                FROM mysql.user 
                WHERE user NOT IN ('root', 'mysql.sys', 'debian-sys-maint', 'mysql.infoschema', 'mysql.session')" 2>/dev/null || echo "# MySQL-Abfrage fehlgeschlagen"
    } | grep -v "CONCAT" > /tmp/drop_user_commands.sql || true
    
    # Wenn die Datei existiert und nicht leer ist, führe die Befehle aus
    if [ -s /tmp/drop_user_commands.sql ]; then
      while IFS= read -r drop_user; do
        # Überspringe Kommentarzeilen
        [[ "$drop_user" =~ ^#.*$ ]] && continue
        echo "  - Lösche Benutzer: ${drop_user}"
        mysql -e "${drop_user}" 2>/dev/null || true
      done < /tmp/drop_user_commands.sql
    else
      echo "  Keine benutzerdefinierten MySQL-Benutzer gefunden."
    fi
    rm -f /tmp/drop_user_commands.sql
    
    print_success "Vollständiger Reset abgeschlossen"
  fi
  
  # Apache-Konfiguration testen, bevor der Dienst neu gestartet wird
  echo "Prüfe Apache-Konfiguration..."
  if apache2ctl configtest &>/dev/null; then
    print_success "Apache-Konfiguration ist gültig"
  else
    print_warning "Apache-Konfiguration enthält Fehler, korrigiere..."
    # Versuche, Probleme automatisch zu beheben
    find /etc/apache2/sites-enabled/ -type l ! -name "000-default.conf" -delete || true
    
    # Noch einmal prüfen
    if apache2ctl configtest &>/dev/null; then
      print_success "Apache-Konfiguration wurde korrigiert"
    else
      print_warning "Apache-Konfiguration enthält weiterhin Fehler"
      # Wir versuchen trotzdem zu starten, da wir eine minimale Konfiguration haben
    fi
  fi
  
  # Apache neustarten
  echo "Starte Apache neu..."
  if systemctl start apache2; then
    print_success "Apache erfolgreich gestartet"
  else
    print_error "Apache konnte nicht gestartet werden, überprüfe die Konfiguration manuell."
    print_warning "Die Serverbereinigung wurde durchgeführt, aber Apache konnte nicht gestartet werden."
    print_warning "Fahre trotzdem mit der Installation fort..."
  fi
  
  print_success "Serverbereinigung abgeschlossen (Level: $RESET_LEVEL)"
}

# Show header
print_section "WEBSITE ENGINE - SERVER SETUP"
echo "Dieses Skript richtet die Website Engine Umgebung ein."

# Check if running as root or with sudo
if [ "$(id -u)" -ne 0 ]; then
  print_error "Dieses Skript muss als Root oder mit sudo ausgeführt werden."
  exit 1
fi

# Frage nach Server-Reset
print_section "SERVER-RESET OPTION"
echo "Möchtest du den Server vor der Installation bereinigen?"
echo "  1) Nein - keine Bereinigung durchführen"
echo "  2) Minimal - nur Apache-Konfigurationen bereinigen (empfohlen)"
echo "  3) Standard - Apache-Konfigurationen und SSL-Zertifikate bereinigen"
echo "  4) Vollständig - Alle Webdaten, Datenbanken und Zertifikate löschen (Vorsicht!)"
read -r -p "Wähle eine Option [1-4] (Standard: 2): " reset_choice

case ${reset_choice:-2} in
  1)
    echo "Überspringe Server-Reset"
    ;;
  2)
    reset_server "minimal"
    ;;
  3)
    echo "⚠️ Warnung: Dies entfernt alle SSL-Zertifikate für Subdomains."
    read -r -p "Fortfahren? [j/N] " confirm_reset
    if [[ "$confirm_reset" =~ ^[jJ] ]]; then
      reset_server "standard"
    else
      print_warning "Standard-Reset abgebrochen"
    fi
    ;;
  4)
    echo "⚠️ ACHTUNG: Dies löscht alle Website-Daten, Datenbanken und Zertifikate!"
    echo "⚠️ Diese Aktion kann nicht rückgängig gemacht werden!"
    read -r -p "Wirklich fortfahren? Gib 'RESET' ein um zu bestätigen: " confirm_full_reset
    if [[ "$confirm_full_reset" == "RESET" ]]; then
      reset_server "full"
    else
      print_warning "Vollständiger Reset abgebrochen"
    fi
    ;;
  *)
    print_warning "Ungültige Eingabe. Fahre mit minimalem Reset fort."
    reset_server "minimal"
    ;;
esac

# 1. Install required packages
print_section "Installiere benötigte Pakete"
apt-get update || { print_warning "apt-get update fehlgeschlagen, fahre trotzdem fort"; }
apt-get install -y apache2 mysql-server php php-cli php-mysql php-curl php-xml \
  php-mbstring php-zip php-gd php-intl libapache2-mod-php curl jq certbot python3-certbot-apache || {
  print_warning "Einige Pakete konnten nicht installiert werden, überprüfe die Fehlermeldungen oben.";
  print_warning "Die wichtigsten Pakete werden später noch einmal überprüft.";
}

# Install WP-CLI if not already installed
if ! command -v wp >/dev/null 2>&1; then
  print_section "Installiere WP-CLI"
  if curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; then
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
    print_success "WP-CLI installiert"
  else
    print_warning "WP-CLI konnte nicht heruntergeladen werden, überspringe."
  fi
fi

# Install necessary tools for backups
print_section "Installiere Backup-Tools"
apt-get install -y restic || print_warning "Restic konnte nicht installiert werden, fahre trotzdem fort."

# 2. Enable Apache modules
print_section "Aktiviere Apache-Module"
a2enmod rewrite ssl

# Versuche Apache neu zu laden oder zu starten
echo "Lade Apache mit den neuen Modulen..."
if systemctl is-active --quiet apache2; then
  systemctl reload apache2 || systemctl restart apache2 || true
else
  systemctl start apache2 || true
fi

# Prüfe, ob Apache läuft
if systemctl is-active --quiet apache2; then
  print_success "Apache-Module aktiviert und Apache läuft"
else
  print_warning "Apache konnte nicht gestartet werden. Fahre trotzdem fort."
fi

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
ln -sf /opt/website-engine/bin/maintenance.sh /usr/local/bin/maintenance
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

  # Automatische Erstellung der Cloudflare-Zugangsdaten-Datei
  mkdir -p /etc/letsencrypt/cloudflare
  cat > /etc/letsencrypt/cloudflare.ini << EOF
# Cloudflare API credentials
dns_cloudflare_api_token = $cf_token
EOF
  chmod 600 /etc/letsencrypt/cloudflare.ini
  print_success "Cloudflare-Zugangsdaten erstellt"
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
  SERVER_DOMAIN="example.com"
fi

# Admin-E-Mail-Adresse abfragen
echo "Bitte gib die Admin-E-Mail für das SSL-Zertifikat ein (Standard: admin@$SERVER_DOMAIN):"
read -r SSL_EMAIL
SSL_EMAIL=${SSL_EMAIL:-"admin@$SERVER_DOMAIN"}

# Automatische Erstellung der Cloudflare-Zugangsdaten-Datei
if [[ ! -f "/etc/letsencrypt/cloudflare.ini" ]]; then
  print_section "Erstelle Cloudflare-Zugangsdaten"
  echo "Bitte gib deinen Cloudflare API-Token ein:"
  read -r CF_API_TOKEN

  mkdir -p /etc/letsencrypt/cloudflare
  cat > /etc/letsencrypt/cloudflare.ini << EOF
# Cloudflare API credentials
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
  chmod 600 /etc/letsencrypt/cloudflare.ini
  print_success "Cloudflare-Zugangsdaten erstellt"
fi

# Installiere das DNS-Plugin, falls es fehlt
if ! dpkg -l | grep -q "python3-certbot-dns-cloudflare"; then
  print_section "Installiere DNS-Plugin für Certbot"
  apt-get install -y python3-certbot-dns-cloudflare
  print_success "DNS-Plugin für Certbot installiert"
fi

# Erstelle Wildcard-Zertifikat mit certbot und der DNS-01-Challenge
if certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  --agree-tos \
  --email "$SSL_EMAIL" \
  -d "*.$SERVER_DOMAIN" \
  --non-interactive; then
  print_success "Wildcard-SSL-Zertifikat erfolgreich installiert"
else
  print_error "Fehler bei der Installation des Wildcard-SSL-Zertifikats. Bitte prüfen Sie die Cloudflare-API-Daten und versuchen Sie es erneut."
  exit 1
fi

# Konfiguriere Apache für die Verwendung des Wildcard-Zertifikats
print_section "Konfiguriere Apache für Wildcard-SSL"
cat <<EOF > /etc/apache2/sites-available/000-default-ssl.conf
<VirtualHost *:443>
    ServerName $SERVER_DOMAIN
    ServerAlias *.$SERVER_DOMAIN

    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$SERVER_DOMAIN/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$SERVER_DOMAIN/privkey.pem

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
echo "Möchtest du jetzt deine Backup-Credentials einrichten? (j/n)"
read -r setup_backup

if [[ "$setup_backup" =~ ^[jJ] ]]; then
  echo "Bitte gib die IONOS-Credentials ein:"
  echo "IONOS-Token (leer lassen, falls nicht gewünscht):"
  read -r ionos_token
  echo "IONOS-Server-ID (leer lassen, falls nicht gewünscht):"
  read -r ionos_server_id
  echo "IONOS-Volume-ID (leer lassen, falls nicht gewünscht):"
  read -r ionos_volume_id

  cat > /etc/website-engine/backup/ionos.env << EOF
# IONOS Cloud API Konfiguration
IONOS_TOKEN="$ionos_token"
IONOS_SERVER_ID="$ionos_server_id"
IONOS_VOLUME_ID="$ionos_volume_id"
EOF
  chmod 600 /etc/website-engine/backup/ionos.env
  print_success "IONOS-Credentials gespeichert"

  echo "Bitte gib die Restic-Credentials ein:"
  echo "Restic-Repository (z. B. s3:https://s3.eu-central-3.ionoscloud.com/my-backups, leer lassen, falls nicht gewünscht):"
  read -r restic_repository
  echo "Restic-Passwort (leer lassen, falls nicht gewünscht):"
  read -r restic_password
  echo "AWS Access Key ID (leer lassen, falls nicht gewünscht):"
  read -r aws_access_key_id
  echo "AWS Secret Access Key (leer lassen, falls nicht gewünscht):"
  read -r aws_secret_access_key

  cat > /etc/website-engine/backup/restic.env << EOF
# Restic configuration
export RESTIC_REPOSITORY="$restic_repository"
export RESTIC_PASSWORD="$restic_password"
export AWS_ACCESS_KEY_ID="$aws_access_key_id"
export AWS_SECRET_ACCESS_KEY="$aws_secret_access_key"
EOF
  chmod 600 /etc/website-engine/backup/restic.env
  print_success "Restic-Credentials gespeichert"
else
  # Standard-Template erstellen
  if [[ -f "$BASE_DIR/backup/ionos.env.template" ]]; then
    cp "$BASE_DIR/backup/ionos.env.template" /etc/website-engine/backup/ionos.env
    chmod 600 /etc/website-engine/backup/ionos.env
  else 
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
  print_warning "Backup-Credentials wurden nicht eingerichtet. Du kannst dies später tun, indem du die Dateien in /etc/website-engine/backup/ bearbeitest."
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

# Versuche Apache zu starten, falls es noch nicht läuft
if ! systemctl is-active --quiet apache2; then
  echo "Apache ist nicht aktiv. Versuche zu starten..."
  
  # Prüfe die Konfiguration erneut
  if ! apache2ctl configtest &>/dev/null; then
    print_warning "Apache-Konfiguration enthält Fehler. Verwende Standard-Konfiguration..."
    
    # Deaktiviere alle Sites außer der Default-Site
    find /etc/apache2/sites-enabled/ -type l ! -name "000-default.conf" -delete || true
    
    # Sicherstelle, dass default aktiv ist
    a2ensite 000-default &>/dev/null || true
  fi
  
  # Starte Apache
  systemctl start apache2 || true
fi

# Check Apache is running
if systemctl is-active --quiet apache2; then
  print_success "Apache läuft"
else
  print_error "Apache läuft nicht. Dies muss manuell behoben werden."
  print_warning "Führe folgende Befehle aus, nachdem du die Installation abgeschlossen hast:"
  echo "  sudo rm -f /etc/apache2/sites-enabled/*.conf"
  echo "  sudo a2ensite 000-default"
  echo "  sudo systemctl restart apache2"
fi

# Überprüfe SSL-Konfiguration
if [ -d "/etc/letsencrypt/live" ]; then
  echo "Prüfe SSL-Zertifikate..."
  ls -la /etc/letsencrypt/live || true
else
  print_warning "Keine SSL-Zertifikate gefunden. Dies ist normal bei einer Erstinstallation."
  echo "SSL-Zertifikate werden automatisch erstellt, wenn du neue Websites hinzufügst."
fi

# Check required directories
for dir in /opt/website-engine /etc/website-engine; do
  if [ -d "$dir" ]; then
    print_success "Verzeichnis $dir existiert"
  else
    print_error "Verzeichnis $dir fehlt"
  fi
done

# Prüfe die MySQL-Installation
echo "Prüfe MySQL-Server..."
if systemctl is-active --quiet mysql; then
  print_success "MySQL-Server läuft"
else
  print_error "MySQL-Server läuft nicht. Versuche zu starten..."
  systemctl start mysql || true
  
  if systemctl is-active --quiet mysql; then
    print_success "MySQL-Server erfolgreich gestartet"
  else
    print_error "MySQL-Server konnte nicht gestartet werden. Dies muss manuell behoben werden."
  fi
fi

# Zusätzliche Überprüfung wichtiger Komponenten
print_section "FINALE ÜBERPRÜFUNG"

# Prüfen, ob alle kritischen Dienste laufen
services_status=0

echo "Überprüfe kritische Dienste..."
if systemctl is-active --quiet apache2; then
  print_success "Apache läuft"
else
  print_error "Apache läuft nicht. Versuche zu starten..."
  systemctl start apache2 || true
  if systemctl is-active --quiet apache2; then
    print_success "Apache wurde erfolgreich gestartet"
  else
    print_error "Apache konnte nicht gestartet werden. Bitte prüfe das manuell."
    services_status=1
  fi
fi

if systemctl is-active --quiet mysql; then
  print_success "MySQL läuft"
else
  print_error "MySQL läuft nicht. Versuche zu starten..."
  systemctl start mysql || true
  if systemctl is-active --quiet mysql; then
    print_success "MySQL wurde erfolgreich gestartet"
  else
    print_error "MySQL konnte nicht gestartet werden. Bitte prüfe das manuell."
    services_status=1
  fi
fi

# Prüfen, ob die grundlegenden Verzeichnisse existieren
directories_status=0
echo "Überprüfe kritische Verzeichnisse..."
for dir in /opt/website-engine /etc/website-engine /var/www /var/lib/website-engine; do
  if [ -d "$dir" ]; then
    print_success "Verzeichnis $dir existiert"
  else
    print_error "Verzeichnis $dir fehlt! Versuche zu erstellen..."
    mkdir -p "$dir" && print_success "Verzeichnis $dir erstellt" || {
      print_error "Konnte Verzeichnis $dir nicht erstellen";
      directories_status=1;
    }
  fi
done

# Prüfen, ob die Symlinks für die Befehle existieren
symlinks_status=0
echo "Überprüfe Befehlssymlinks..."
for cmd in create-site delete-site direct-ssl maintenance; do
  if [ -L "/usr/local/bin/$cmd" ]; then
    print_success "Befehl $cmd ist korrekt verlinkt"
  else
    print_error "Befehl $cmd ist nicht korrekt verlinkt! Versuche zu verlinken..."
    ln -sf "/opt/website-engine/bin/${cmd}.sh" "/usr/local/bin/$cmd" && print_success "Befehl $cmd verlinkt" || {
      print_error "Konnte Befehl $cmd nicht verlinken";
      symlinks_status=1;
    }
  fi
done

# Gesamtstatus
if [ $services_status -eq 0 ] && [ $directories_status -eq 0 ] && [ $symlinks_status -eq 0 ]; then
  print_success "Alle kritischen Komponenten sind korrekt eingerichtet"
else
  print_warning "Einige Komponenten könnten Probleme haben. Überprüfen Sie die Warnungen oben."
  print_warning "Sie können './bin/setup-fix.sh' ausführen, um häufige Probleme zu beheben."
fi

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

# Complete
print_section "INSTALLATION ABGESCHLOSSEN"
echo "Die Website Engine wurde erfolgreich installiert."
echo
echo "Folgende Befehle sind jetzt verfügbar:"
echo "  create-site <subdomain> - Erstellt eine neue WordPress-Seite"
echo "  delete-site <subdomain> - Löscht eine WordPress-Seite"
echo "  direct-ssl <domain>     - Erstellt ein SSL-Zertifikat für eine externe Domain"
echo "  setup-server            - Richtet den Server neu ein"
echo "  maintenance.sh          - Führt Wartungsaufgaben durch"
echo
echo "Für regelmäßige Wartung (empfohlen):"
echo "  sudo /opt/website-engine-1.1/bin/maintenance.sh"
echo "Oder für automatische monatliche Wartung:"
echo "  sudo crontab -e"
echo "  Füge hinzu: 0 4 1 * * /opt/website-engine-1.1/bin/maintenance.sh > /var/log/website-engine/maintenance.log 2>&1"
echo
echo "Weitere Informationen findest du in der Dokumentation:"
echo "  /opt/website-engine-1.1/docs/maintenance.md"

# Hinweis zur ersten Website
print_section "NÄCHSTE SCHRITTE"
echo "Um deine erste WordPress-Seite zu erstellen, führe aus:"
echo "  create-site <subdomain>"
echo
echo "Beispiel:"
echo "  create-site kunde1"
echo

print_success "Website Engine Installation abgeschlossen!"
exit 0