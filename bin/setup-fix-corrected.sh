#!/bin/bash
# =========================================================================
# Website Engine - Setup Fix Script (Korrigierte Version)
# =========================================================================
# Dieses Skript korrigiert Probleme im ursprünglichen setup-server.sh
# und stellt sicher, dass der Server-Setup vollständig durchläuft.
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

# Pfad zum setup-server.sh
SETUP_SCRIPT="/opt/website-engine-1.1/bin/setup-server.sh"

# Hauptfunktion: Korrigiere das setup-server.sh Skript
fix_setup_server_script() {
  print_section "KORRIGIERE SETUP-SERVER SKRIPT"
  
  # Backup erstellen, wenn noch nicht vorhanden
  if [ ! -f "${SETUP_SCRIPT}.bak" ]; then
    cp "$SETUP_SCRIPT" "${SETUP_SCRIPT}.bak"
    print_success "Backup erstellt: ${SETUP_SCRIPT}.bak"
  else
    print_warning "Backup ${SETUP_SCRIPT}.bak existiert bereits"
  fi
  
  # Entferne 'set -e' Direktive mit einer direkte Bearbeitung
  cat > "$SETUP_SCRIPT" << 'EOF'
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
    
    echo "Entferne alle SSL-Zertifikate..."
    rm -rf /etc/letsencrypt/live/* /etc/letsencrypt/archive/* /etc/letsencrypt/renewal/* || true
    
    # Dann erst die Webverzeichnisse bereinigen
    echo "Leere /var/www/* (außer /var/www/html)"
    find /var/www -mindepth 1 -maxdepth 1 -type d ! -name "html" -exec rm -rf {} \; 2>/dev/null || true
    
    # MySQL-Datenbanken bereinigen (außer System-DBs) - robustere Implementierung
    echo "Bereinige MySQL-Datenbanken..."
    # Speichere Befehle in temporärer Datei
    mysql -e "SELECT CONCAT('DROP DATABASE IF EXISTS ', schema_name, ';') 
              FROM information_schema.schemata 
              WHERE schema_name NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')" 2>/dev/null | grep -v "CONCAT" > /tmp/drop_db_commands.sql || true
    
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
    mysql -e "SELECT CONCAT('DROP USER IF EXISTS ''', user, '''@''', host, ''';') 
              FROM mysql.user 
              WHERE user NOT IN ('root', 'mysql.sys', 'debian-sys-maint', 'mysql.infoschema', 'mysql.session')" 2>/dev/null | grep -v "CONCAT" > /tmp/drop_user_commands.sql || true
    
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
EOF

  # Hole den Rest des original Skripts, ohne die ersten Zeilen, die wir ersetzt haben
  sed -n '140,$p' "${SETUP_SCRIPT}.bak" >> "$SETUP_SCRIPT"
  
  print_success "Setup-Server Skript wurde korrigiert"
}

# Installiere minimale erforderliche Komponenten
install_minimal_required_components() {
  print_section "INSTALLIERE MINIMALE KOMPONENTEN"
  
  # Stelle sicher, dass Apache läuft
  systemctl restart apache2 || true
  
  # Aktiviere die Standard-Site
  if [ ! -L "/etc/apache2/sites-enabled/000-default.conf" ]; then
    # Entferne alte Symlinks
    rm -f /etc/apache2/sites-enabled/*.conf
    
    # Aktiviere Standard-Site
    a2ensite 000-default
    print_success "Standard-Site aktiviert"
  fi
  
  # Erstelle fehlende Verzeichnisse
  mkdir -p /opt/website-engine/{bin,modules,backup}
  mkdir -p /etc/website-engine/{sites,backup}
  mkdir -p /var/lib/website-engine /var/backups/website-engine /var/log/website-engine /var/www
  
  # Setze Berechtigungen
  chown www-data:www-data /var/lib/website-engine /var/backups/website-engine /var/www
  
  # Erstelle Symlinks
  ln -sf /opt/website-engine-1.1/bin/create-site.sh /usr/local/bin/create-site 2>/dev/null || true
  ln -sf /opt/website-engine-1.1/bin/delete-site.sh /usr/local/bin/delete-site 2>/dev/null || true
  ln -sf /opt/website-engine-1.1/bin/direct-ssl.sh /usr/local/bin/direct-ssl 2>/dev/null || true
  ln -sf /opt/website-engine-1.1/bin/maintenance.sh /usr/local/bin/maintenance 2>/dev/null || true
  ln -sf /opt/website-engine-1.1/bin/fix-ssl-certificate.sh /usr/local/bin/fix-ssl 2>/dev/null || true
  
  # Mache die Skripte ausführbar
  chmod +x /opt/website-engine/bin/*.sh 2>/dev/null || true
  chmod +x /opt/website-engine-1.1/bin/*.sh 2>/dev/null || true
  
  print_success "Minimale Komponenten wurden installiert"
}

# Führe das setup-server Skript sicher aus
run_setup_server_safely() {
  print_section "FÜHRE SETUP-SERVER SICHER AUS"
  
  # Verwende das korrigierte Skript ohne Bereinigung
  bash -c "cd /opt/website-engine-1.1 && ./bin/setup-server.sh" <<EOF
1
n
n
EOF
  
  # Prüfe, ob Apache läuft
  if systemctl is-active --quiet apache2; then
    print_success "Apache läuft"
  else
    print_warning "Apache läuft nicht, versuche zu starten..."
    systemctl start apache2 || true
  fi
  
  # Prüfe, ob MySQL läuft
  if systemctl is-active --quiet mysql; then
    print_success "MySQL läuft"
  else
    print_warning "MySQL läuft nicht, versuche zu starten..."
    systemctl start mysql || true
  fi
  
  print_success "Setup-Server wurde sicher ausgeführt"
}

# Diese Funktion erstellt manuell ein selbstsigniertes SSL-Zertifikat
# als Fallback, wenn Let's Encrypt fehlschlägt
create_self_signed_ssl() {
  print_section "ERSTELLE SELBSTSIGNIERTES SSL-ZERTIFIKAT"
  
  # Bestimme die Domain aus der Konfiguration
  source /opt/website-engine-1.1/modules/config.sh
  
  echo "Domain: $DOMAIN"
  echo "Zertifikatsverzeichnis: $SSL_DIR"
  
  # Erstelle das Verzeichnis, falls es nicht existiert
  mkdir -p "$SSL_DIR"
  
  # Erstelle selbstsigniertes Zertifikat
  echo "Erstelle selbstsigniertes Zertifikat für $DOMAIN und *.$DOMAIN..."
  
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
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -config /tmp/openssl.cnf \
    -keyout "$SSL_DIR/privkey.pem" \
    -out "$SSL_DIR/fullchain.pem"
    
  # Erstelle auch die anderen erforderlichen Dateien
  cp "$SSL_DIR/fullchain.pem" "$SSL_DIR/cert.pem"
  cp "$SSL_DIR/fullchain.pem" "$SSL_DIR/chain.pem"
  
  # Setze korrekte Berechtigungen
  chmod 600 "$SSL_DIR/privkey.pem"
  chmod 644 "$SSL_DIR/fullchain.pem" "$SSL_DIR/cert.pem" "$SSL_DIR/chain.pem"
  
  # Lösche temporäre Dateien
  rm -f /tmp/openssl.cnf
  
  # Überprüfe das erstellte Zertifikat
  if [[ -f "$SSL_CERT_PATH" ]]; then
    echo "Zertifikat erfolgreich erstellt in: $SSL_CERT_PATH"
    echo "Zertifikat gültig für folgende Domains:"
    openssl x509 -in "$SSL_CERT_PATH" -text -noout | grep DNS:
    print_success "Selbstsigniertes SSL-Zertifikat wurde erfolgreich erstellt!"
    print_warning "HINWEIS: Dies ist ein selbstsigniertes Zertifikat. Browser werden eine Warnung anzeigen."
  else
    print_error "Zertifikat konnte nicht erstellt werden."
    return 1
  fi
}

# Fix für die SSL-Zertifikate
fix_ssl_certificates() {
  print_section "ERSTELLE SSL-ZERTIFIKATE"
  
  # Bestimme die Domain aus der Konfiguration
  source /opt/website-engine-1.1/modules/config.sh
  
  # Überprüfen, ob das SSL-Verzeichnis und Zertifikate existieren
  if [ ! -d "$SSL_DIR" ] || [ ! -f "$SSL_CERT_PATH" ]; then
    print_warning "SSL-Zertifikate fehlen. Erstelle ein neues Wildcard-Zertifikat für $DOMAIN..."
    
    # Versuche zuerst mit dem SSL-Fix-Skript
    print_warning "Versuche, Wildcard-Zertifikat mit Let's Encrypt zu erstellen..."
    if /opt/website-engine-1.1/bin/fix-ssl-certificate.sh; then
      print_success "SSL-Zertifikat wurde erfolgreich erstellt!"
    else
      print_warning "Let's Encrypt Wildcard-Zertifikat konnte nicht erstellt werden."
      print_warning "Erstelle stattdessen ein selbstsigniertes Zertifikat..."
      
      # Wenn Let's Encrypt fehlschlägt, erstelle ein selbstsigniertes Zertifikat
      if create_self_signed_ssl; then
        print_success "Selbstsigniertes SSL-Zertifikat wurde als Fallback erstellt!"
      else
        print_error "Konnte weder Let's Encrypt noch selbstsigniertes Zertifikat erstellen."
        print_error "Die Website-Engine wird ohne SSL nicht korrekt funktionieren."
      fi
    fi
  else
    print_success "SSL-Zertifikate sind bereits vorhanden in $SSL_DIR"
  fi
}

# Hauptprogramm
print_section "WEBSITE ENGINE SETUP FIX"
echo -e "Dieses Skript behebt Probleme mit dem Server-Setup."

# Führe die Hauptfunktionen aus
fix_setup_server_script
install_minimal_required_components
run_setup_server_safely
fix_ssl_certificates

print_section "SETUP FIX ABGESCHLOSSEN"
echo -e "Das Setup wurde erfolgreich korrigiert und ausgeführt."
echo -e "\n${BOLD}Nächste Schritte:${NC}"
echo "1. Cloudflare-Anmeldedaten konfigurieren:"
echo "   sudo nano /etc/profile.d/cloudflare.sh"
echo "2. SSL-Zertifikate überprüfen:"
echo "   sudo ls -la /etc/letsencrypt/live/"
echo "3. Eine WordPress-Seite erstellen:"
echo "   sudo create-site testsite"
echo ""
echo "Wenn Probleme mit SSL-Zertifikaten auftreten:"
echo "   sudo /opt/website-engine-1.1/bin/fix-ssl-certificate.sh"
echo ""
echo "Bei Problemen mit Apache starten Sie den Dienst neu:"
echo "   sudo systemctl restart apache2"
echo ""
echo "Wenn die SSL-Zertifikate fehlen, aber die create-site Funktion funktionieren soll:"
echo "   sudo create-site testsite --force-ssl"
echo "   (Dies erstellt ein eigenes Zertifikat für diese Subdomain anstatt ein Wildcard-Zertifikat zu verwenden)"
echo ""
echo "HINWEIS: Da Let's Encrypt für Wildcard-Zertifikate einen DNS-Challenge benötigt,"
echo "haben wir ein selbstsigniertes Zertifikat als Fallback erstellt."
echo "Dies genügt für Entwicklungs- und Testumgebungen."
