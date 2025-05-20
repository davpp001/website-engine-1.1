#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# APACHE VHOST-MANAGEMENT-MODUL (OPTIMIERT)
# ====================================================================
#
# Dieses Modul verwaltet Apache Virtual Hosts und SSL-Zertifikate.
# Es nutzt ausschließlich certbot --apache für SSL-Zertifikate,
# da dies sich als die zuverlässigste Methode erwiesen hat.
#
# FUNKTIONEN:
# - create_ssl_cert       - Erstellt ein SSL-Zertifikat (--apache Methode)
# - create_http_vhost     - Erstellt eine einfache HTTP-Konfiguration
# - check_ssl_cert        - Prüft, ob ein SSL-Zertifikat existiert
# - get_ssl_cert_paths    - Ermittelt die Pfade für SSL-Zertifikate
# - create_vhost_config   - Erstellt eine vHost-Konfiguration
# - enable_vhost          - Aktiviert einen vHost
# - setup_vhost           - Richtet einen kompletten vHost ein
# - remove_vhost          - Entfernt einen vHost
#
# ====================================================================

# Import config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Hilfsfunktion zum Aufräumen von Apache-Konfigurationen
# Usage: cleanup_apache_configs <subdomain>
function cleanup_apache_configs() {
  local SUB="$1"
  local PATTERNS=("$SUB.conf" "$SUB-le-ssl.conf" "$SUB-temp-le-ssl.conf")
  
  log "INFO" "Bereinige Apache-Konfigurationen für $SUB"
  
  # Deaktiviere alle Sites, die das Muster enthalten
  for pattern in "${PATTERNS[@]}"; do
    sudo a2dissite "*$pattern" &>/dev/null || true
  done
  
  # Entferne alle Konfigurationsdateien, die das Muster enthalten
  for pattern in "${PATTERNS[@]}"; do
    for config in /etc/apache2/sites-available/*"$pattern"; do
      if [[ -f "$config" ]]; then
        log "INFO" "Entferne Apache-Konfiguration: $config"
        sudo rm -f "$config"
      fi
    done
  done
  
  # Reload Apache, um Änderungen zu übernehmen
  sudo systemctl reload apache2 || log "WARNING" "Apache konnte nicht neu geladen werden"
  
  log "SUCCESS" "Apache-Konfigurationen für $SUB bereinigt"
  return 0
}

# SSL-Zertifikat mit certbot --apache erstellen
# Usage: create_ssl_cert <domain> [document-root]
function create_ssl_cert() {
  local DOMAIN="$1"
  local DOCROOT="${2:-$WP_DIR/${DOMAIN%%.*}}"
  
  log "INFO" "Erstelle SSL-Zertifikat für $DOMAIN mit certbot --apache"
  
  # 1. Stelle sicher, dass Verzeichnis existiert
  sudo mkdir -p "$DOCROOT/.well-known/acme-challenge"
  sudo chown -R www-data:www-data "$DOCROOT"
  
  # 2. Erstelle einfache VirtualHost-Konfiguration
  local SUB="${DOMAIN%%.*}"
  local VHOST_CONFIG="/etc/apache2/sites-available/${SUB}.conf"
  
  # Entferne alte Konfigurationen
  sudo a2dissite "*$SUB*" &>/dev/null || true
  sudo rm -f "/etc/apache2/sites-available/*$SUB*" &>/dev/null || true
  
  # Erstelle neue Konfiguration
  sudo tee "$VHOST_CONFIG" > /dev/null << EOF
<VirtualHost *:80>
  ServerName ${DOMAIN}
  DocumentRoot ${DOCROOT}
  
  <Directory ${DOCROOT}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
  
  <Directory "${DOCROOT}/.well-known/acme-challenge">
    Options None
    AllowOverride None
    Require all granted
  </Directory>
</VirtualHost>
EOF
  
  # 3. Aktiviere die Konfiguration
  sudo a2ensite "${SUB}.conf"
  sudo systemctl reload apache2
  sleep 5
  
  # 4. Erstelle Zertifikat mit certbot --apache
  if sudo certbot --apache -n --agree-tos --email "$SSL_EMAIL" -d "$DOMAIN"; then
    log "SUCCESS" "SSL-Zertifikat für $DOMAIN erfolgreich erstellt"
    return 0
  else
    log "ERROR" "Konnte kein SSL-Zertifikat für $DOMAIN erstellen"
    return 1
  fi
}

# Erstelle eine einfache HTTP-only VirtualHost-Konfiguration
# Usage: create_http_vhost <subdomain> [fallback-message]
function create_http_vhost() {
  local SUB="$1"
  local FQDN="${SUB}.${DOMAIN}"
  local DOCROOT="${WP_DIR}/${SUB}"
  local VHOST_CONFIG="${APACHE_SITES_DIR}/${SUB}.conf"
  local MESSAGE="${2:-"HTTP-only"}"
  
  log "INFO" "Erstelle HTTP-only VirtualHost für $FQDN"
  
  sudo tee "$VHOST_CONFIG" > /dev/null << VHOST_HTTP_EOF
# Apache VirtualHost für ${FQDN} ($MESSAGE)
# Erstellt von Website Engine am $(date '+%Y-%m-%d %H:%M:%S')

<VirtualHost *:80>
  ServerName ${FQDN}
  ServerAdmin ${WP_EMAIL}
  ServerSignature Off
  
  DocumentRoot ${DOCROOT}
  
  ErrorLog \${APACHE_LOG_DIR}/${SUB}_error.log
  CustomLog \${APACHE_LOG_DIR}/${SUB}_access.log combined
  
  <Directory ${DOCROOT}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
    
    # WordPress .htaccess nicht benötigen
    <IfModule mod_rewrite.c>
      RewriteEngine On
      RewriteBase /
      RewriteRule ^index\.php$ - [L]
      RewriteCond %{REQUEST_FILENAME} !-f
      RewriteCond %{REQUEST_FILENAME} !-d
      RewriteRule . /index.php [L]
    </IfModule>
  </Directory>
  
  # Sicherheitseinstellungen
  <Directory ${DOCROOT}/wp-content/uploads>
    # PHP-Ausführung in Uploads-Verzeichnis verbieten
    <FilesMatch "\.(?i:php|phar|phtml|php\d+)$">
      Require all denied
    </FilesMatch>
  </Directory>
</VirtualHost>
VHOST_HTTP_EOF

  return 0
}

# SSL-Zertifikat verwalten
# Usage: check_ssl_cert [domain]
function check_ssl_cert() {
  local DOMAIN_TO_CHECK="${1:-$DOMAIN}"
  local IS_SUBDOMAIN=0
  local WILDCARD_CERT_PATH="$SSL_CERT_PATH"
  local SPECIFIC_CERT_PATH=""
  
  # Wenn wir eine Subdomain prüfen, setze IS_SUBDOMAIN
  if [[ "$DOMAIN_TO_CHECK" == *"."* && "$DOMAIN_TO_CHECK" != "$DOMAIN" ]]; then
    IS_SUBDOMAIN=1
    # Prüfe, ob ein eigenes Zertifikat existiert
    if [[ -d "/etc/letsencrypt/live/$DOMAIN_TO_CHECK" ]]; then
      SPECIFIC_CERT_PATH="/etc/letsencrypt/live/$DOMAIN_TO_CHECK/fullchain.pem"
      log "INFO" "Spezifisches Zertifikat für $DOMAIN_TO_CHECK gefunden"
    fi
  fi
  
  # Wenn ein spezifisches Zertifikat existiert, verwende dieses
  if [[ $IS_SUBDOMAIN -eq 1 && -n "$SPECIFIC_CERT_PATH" && -f "$SPECIFIC_CERT_PATH" ]]; then
    log "INFO" "Verwende spezifisches SSL-Zertifikat: $SPECIFIC_CERT_PATH"
    return 0
  fi
  
  # Prüfe auf Wildcard-Zertifikat
  local HAS_WILDCARD=0
  if [[ -f "$WILDCARD_CERT_PATH" ]]; then
    # Überprüfe, ob es sich um ein Wildcard-Zertifikat handelt
    if openssl x509 -in "$WILDCARD_CERT_PATH" -text | grep -q "DNS:\*\.$DOMAIN"; then
      log "INFO" "Wildcard-Zertifikat gefunden für *.$DOMAIN"
      HAS_WILDCARD=1
    else
      log "WARNING" "Zertifikat existiert, ist aber kein Wildcard-Zertifikat"
    fi
    
    # Prüfe Ablaufdatum
    local cert_end_date=$(openssl x509 -in "$WILDCARD_CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -n "$cert_end_date" ]]; then
      local cert_end_epoch=$(date -d "$cert_end_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$cert_end_date" +%s 2>/dev/null)
      local now_epoch=$(date +%s)
      local days_left=$(( (cert_end_epoch - now_epoch) / 86400 ))
      
      if [[ $days_left -lt 0 ]]; then
        log "ERROR" "SSL-Zertifikat ist abgelaufen!"
        HAS_WILDCARD=0
      elif [[ $days_left -lt 15 ]]; then
        log "WARNING" "SSL-Zertifikat läuft in $days_left Tagen ab! Baldige Erneuerung empfohlen."
      else
        log "INFO" "SSL-Zertifikat ist gültig für weitere $days_left Tage"
      fi
    else
      log "ERROR" "SSL-Zertifikat konnte nicht überprüft werden"
      HAS_WILDCARD=0
    fi
  else
    log "ERROR" "SSL-Zertifikat nicht gefunden: $WILDCARD_CERT_PATH"
    HAS_WILDCARD=0
  fi
  
  # Wenn wir eine Subdomain prüfen und kein Wildcard-Zertifikat haben, erstelle ein eigenes
  if [[ $IS_SUBDOMAIN -eq 1 && $HAS_WILDCARD -eq 0 ]]; then
    log "WARNING" "Kein gültiges Wildcard-Zertifikat gefunden für $DOMAIN_TO_CHECK"
    
    # Verwende die neue create_ssl_cert Funktion
    if create_ssl_cert "$DOMAIN_TO_CHECK"; then
      log "SUCCESS" "SSL-Zertifikat für $DOMAIN_TO_CHECK erfolgreich erstellt"
      SPECIFIC_CERT_PATH="/etc/letsencrypt/live/$DOMAIN_TO_CHECK/fullchain.pem"
      return 0
    else
      log "ERROR" "Konnte kein SSL-Zertifikat für $DOMAIN_TO_CHECK erstellen"
      return 1
    fi
  fi
  
  # Rückgabewert basierend auf Wildcard-Status
  return $(( 1 - HAS_WILDCARD ))
}

# SSL-Zertifikatspfade ermitteln
# Usage: get_ssl_cert_paths <domain> [out_cert_var] [out_key_var]
function get_ssl_cert_paths() {
  local DOMAIN_TO_CHECK="$1"
  local OUT_CERT_VAR="${2:-}"
  local OUT_KEY_VAR="${3:-}"
  local CERT_PATH=""
  local KEY_PATH=""
  
  # Prüfe auf domainspezifisches Zertifikat
  if [[ -d "/etc/letsencrypt/live/$DOMAIN_TO_CHECK" ]]; then
    CERT_PATH="/etc/letsencrypt/live/$DOMAIN_TO_CHECK/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$DOMAIN_TO_CHECK/privkey.pem"
    log "INFO" "Verwende spezifisches Zertifikat für $DOMAIN_TO_CHECK"
  else
    # Prüfe, ob DOMAIN_TO_CHECK eine Subdomain ist
    if [[ "$DOMAIN_TO_CHECK" == *".$DOMAIN" ]]; then
      # Prüfe auf Wildcard-Zertifikat
      if openssl x509 -in "$SSL_CERT_PATH" -text 2>/dev/null | grep -q "DNS:\*\.$DOMAIN"; then
        CERT_PATH="$SSL_CERT_PATH"
        KEY_PATH="$SSL_KEY_PATH"
        log "INFO" "Verwende Wildcard-Zertifikat für $DOMAIN_TO_CHECK"
      else
        log "WARNING" "Kein passendes Zertifikat gefunden für $DOMAIN_TO_CHECK"
        log "INFO" "Erstelle ein eigenes Zertifikat für $DOMAIN_TO_CHECK"
        
        # Verwende die neue create_ssl_cert Funktion
        if create_ssl_cert "$DOMAIN_TO_CHECK"; then
          CERT_PATH="/etc/letsencrypt/live/$DOMAIN_TO_CHECK/fullchain.pem"
          KEY_PATH="/etc/letsencrypt/live/$DOMAIN_TO_CHECK/privkey.pem"
          log "SUCCESS" "SSL-Zertifikat für $DOMAIN_TO_CHECK erfolgreich erstellt"
        else
          log "ERROR" "Konnte kein SSL-Zertifikat für $DOMAIN_TO_CHECK erstellen"
          # Verwende Standardzertifikat als Fallback (wird wahrscheinlich Fehler verursachen)
          CERT_PATH="$SSL_CERT_PATH"
          KEY_PATH="$SSL_KEY_PATH"
        fi
      fi
    else
      # Hauptdomain
      CERT_PATH="$SSL_CERT_PATH"
      KEY_PATH="$SSL_KEY_PATH"
      log "INFO" "Verwende Hauptdomain-Zertifikat für $DOMAIN_TO_CHECK"
    fi
  fi
  
  # Ausgabe setzen, wenn Variablennamen angegeben wurden
  if [[ -n "$OUT_CERT_VAR" ]]; then
    eval "$OUT_CERT_VAR=\"$CERT_PATH\""
  fi
  
  if [[ -n "$OUT_KEY_VAR" ]]; then
    eval "$OUT_KEY_VAR=\"$KEY_PATH\""
  fi
  
  # Prüfen, ob beide Pfade existieren
  if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then
    return 0
  else
    log "ERROR" "SSL-Zertifikatsdateien nicht gefunden: $CERT_PATH oder $KEY_PATH"
    return 1
  fi
}

# Vhost-Konfiguration erstellen
# Usage: create_vhost_config <subdomain-name> [ssl-cert-path] [ssl-key-path]
function create_vhost_config() {
  local SUB="$1"
  local FQDN="${SUB}.${DOMAIN}"
  local DOCROOT="${WP_DIR}/${SUB}"
  local VHOST_CONFIG="${APACHE_SITES_DIR}/${SUB}.conf"
  local CUSTOM_SSL_CERT="${2:-}"
  local CUSTOM_SSL_KEY="${3:-}"
  
  log "INFO" "Erstelle Apache vHost-Konfiguration für $FQDN in $VHOST_CONFIG"
  
  # Stelle sicher, dass das Dokumentwurzelverzeichnis existiert
  sudo mkdir -p "$DOCROOT"
  sudo chown -R www-data:www-data "$DOCROOT"
  sudo chmod -R 755 "$DOCROOT"
  
  # Bestimme, welche SSL-Zertifikate verwendet werden sollen
  local CERT_PATH=""
  local KEY_PATH=""
  
  if [[ -n "$CUSTOM_SSL_CERT" && -f "$CUSTOM_SSL_CERT" ]]; then
    # Verwende die übergebenen benutzerdefinierten Zertifikatspfade
    log "INFO" "Verwende benutzerdefiniertes SSL-Zertifikat: $CUSTOM_SSL_CERT"
    CERT_PATH="$CUSTOM_SSL_CERT"
    KEY_PATH="$CUSTOM_SSL_KEY"
  else
    # Nutze die neue Funktion, um die besten Zertifikatspfade zu ermitteln
    if ! get_ssl_cert_paths "$FQDN" CERT_PATH KEY_PATH; then
      log "WARNING" "Konnte keine passenden SSL-Zertifikate finden. Erstelle spezifisches Zertifikat."
      
      # Verwende die neue create_ssl_cert Funktion für SSL-Erstellung
      if create_ssl_cert "$FQDN" "${WP_DIR}/${SUB}"; then
        log "SUCCESS" "SSL-Zertifikat für $FQDN erfolgreich erstellt und installiert"
        
        # Aktualisiere Pfade
        CERT_PATH="/etc/letsencrypt/live/$FQDN/fullchain.pem"
        KEY_PATH="/etc/letsencrypt/live/$FQDN/privkey.pem"
      else
        log "ERROR" "Konnte kein SSL-Zertifikat erstellen. VHost wird mit Standard-Zertifikat konfiguriert."
        CERT_PATH="$SSL_CERT_PATH"
        KEY_PATH="$SSL_KEY_PATH"
      fi
    fi
  fi
  
  # Erzeuge vHost-Konfiguration
  # Prüfe, ob das Zertifikat existiert
  local USE_SSL=1
  if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
    log "WARNING" "SSL-Zertifikatsdateien nicht gefunden. Erstelle HTTP-only Konfiguration."
    USE_SSL=0
  fi

  if [[ $USE_SSL -eq 1 ]]; then
    # Vollständige Konfiguration mit HTTP und HTTPS
    sudo tee "$VHOST_CONFIG" > /dev/null << VHOST_EOF
# Apache VirtualHost für ${FQDN}
# Erstellt von Website Engine am $(date '+%Y-%m-%d %H:%M:%S')

# HTTP -> HTTPS Redirect
<VirtualHost *:80>
  ServerName ${FQDN}
  # Stellt sicher, dass diese Site Vorrang vor anderen hat
  ServerAlias ${FQDN} www.${FQDN}
  ServerAdmin ${WP_EMAIL}
  ServerSignature Off
  
  # Erhöhe die Priorität, um der Default-Seite vorzuziehen
  <IfModule mod_setenvif.c>
    SetEnvIf Host "${FQDN}" VIRTUAL_HOST=1
  </IfModule>
  
  DocumentRoot ${DOCROOT}
  
  ErrorLog \${APACHE_LOG_DIR}/${SUB}_error.log
  CustomLog \${APACHE_LOG_DIR}/${SUB}_access.log combined
  
  # Diese Zeile stellt sicher, dass die Umleitung immer funktioniert
  # RedirectMatch hat bei bestimmten Konfigurationen Probleme, daher verwenden wir mod_rewrite
  <IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteCond %{SERVER_NAME} =${FQDN} [OR]
    RewriteCond %{SERVER_NAME} =www.${FQDN}
    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
  </IfModule>
</VirtualHost>

# HTTPS VirtualHost
<VirtualHost *:443>
  ServerName ${FQDN}
  ServerAdmin ${WP_EMAIL}
  ServerSignature Off
  
  DocumentRoot ${DOCROOT}
  
  ErrorLog \${APACHE_LOG_DIR}/${SUB}_ssl_error.log
  CustomLog \${APACHE_LOG_DIR}/${SUB}_ssl_access.log combined
  
  # SSL-Konfiguration
  SSLEngine on
  SSLCertificateFile ${CERT_PATH}
  SSLCertificateKeyFile ${KEY_PATH}
  
  # SSL-Sicherheitseinstellungen
  SSLProtocol all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
  SSLHonorCipherOrder on
  SSLCompression off
  
  # Verzeichniskonfiguration
  <Directory ${DOCROOT}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
    
    # WordPress .htaccess nicht benötigen
    <IfModule mod_rewrite.c>
      RewriteEngine On
      RewriteBase /
      RewriteRule ^index\.php$ - [L]
      RewriteCond %{REQUEST_FILENAME} !-f
      RewriteCond %{REQUEST_FILENAME} !-d
      RewriteRule . /index.php [L]
    </IfModule>
  </Directory>
  
  # Sicherheitseinstellungen
  <Directory ${DOCROOT}/wp-content/uploads>
    # PHP-Ausführung in Uploads-Verzeichnis verbieten
    <FilesMatch "\.(?i:php|phar|phtml|php\d+)$">
      Require all denied
    </FilesMatch>
  </Directory>
</VirtualHost>
VHOST_EOF
  else
    # Nur HTTP-Konfiguration
    sudo tee "$VHOST_CONFIG" > /dev/null << VHOST_EOF
# Apache VirtualHost für ${FQDN} (HTTP-only)
# Erstellt von Website Engine am $(date '+%Y-%m-%d %H:%M:%S')

<VirtualHost *:80>
  ServerName ${FQDN}
  ServerAdmin ${WP_EMAIL}
  ServerSignature Off
  
  DocumentRoot ${DOCROOT}
  
  ErrorLog \${APACHE_LOG_DIR}/${SUB}_error.log
  CustomLog \${APACHE_LOG_DIR}/${SUB}_access.log combined
  
  # Verzeichniskonfiguration
  <Directory ${DOCROOT}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
    
    # WordPress .htaccess nicht benötigen
    <IfModule mod_rewrite.c>
      RewriteEngine On
      RewriteBase /
      RewriteRule ^index\.php$ - [L]
      RewriteCond %{REQUEST_FILENAME} !-f
      RewriteCond %{REQUEST_FILENAME} !-d
      RewriteRule . /index.php [L]
    </IfModule>
  </Directory>
  
  # Sicherheitseinstellungen
  <Directory ${DOCROOT}/wp-content/uploads>
    # PHP-Ausführung in Uploads-Verzeichnis verbieten
    <FilesMatch "\.(?i:php|phar|phtml|php\d+)$">
      Require all denied
    </FilesMatch>
  </Directory>
</VirtualHost>
VHOST_EOF
  fi
  # Prüfe, ob die Konfiguration erfolgreich erstellt wurde
  if [[ ! -f "$VHOST_CONFIG" ]]; then
    log "ERROR" "Konnte vHost-Konfiguration nicht erstellen: $VHOST_CONFIG"
    return 1
  fi
  
  # Aktiviere diese Konfiguration mit unserer verbesserten Funktion (wichtig!)
  enable_vhost "$SUB" || {
    log "ERROR" "Konnte vHost nicht aktivieren"
    return 1
  }
  
  # Zusätzliche Prüfung: Stelle sicher, dass die Default-Site deaktiviert wird,
  # wenn sie mit unserer neuen Site kollidieren könnte
  if [[ -e "/etc/apache2/sites-enabled/000-default.conf" ]]; then
    log "INFO" "Default-Site könnte Konflikte verursachen, deaktiviere sie"
    sudo a2dissite 000-default > /dev/null 2>&1 || log "WARNING" "Konnte Default-Site nicht deaktivieren"
  fi
  
    if grep -q "SSLCertificateFile" "$VHOST_CONFIG"; then
    # Nur prüfen, wenn es sich um eine SSL-Konfiguration handelt
    if [[ ! -f "$CERT_PATH" ]]; then
      log "ERROR" "SSL-Zertifikatsdatei nicht gefunden: $CERT_PATH"
      log "INFO" "Erstelle HTTP-only Fallback-Konfiguration"
      
      # Verwende die neue create_http_vhost Funktion
      create_http_vhost "$SUB" "HTTP-only fallback"
    fi
  fi
  
  log "SUCCESS" "Apache vHost-Konfiguration für $FQDN erstellt"
  return 0
}

# Aktiviert einen Apache vHost und lädt den Dienst neu
# Usage: enable_vhost <subdomain-name>
function enable_vhost() {
  local SUB="$1"
  log "INFO" "Aktiviere Apache vHost: ${SUB}.conf"
  sudo a2dissite 000-default.conf || true
  if ! sudo a2ensite "${SUB}.conf"; then
    log "ERROR" "Konnte vHost ${SUB}.conf nicht aktivieren"
    return 1
  fi
  sudo systemctl reload apache2
  log "SUCCESS" "vHost ${SUB}.conf aktiviert"
  return 0
}

# Apache vHost einrichten
# Usage: setup_vhost <subdomain-name>
function setup_vhost() {
  local SUB="$1"
  local FQDN="${SUB}.${DOMAIN}"
  local DOCROOT="${WP_DIR}/${SUB}"
  
  log "INFO" "Richte Apache vHost für $FQDN ein"
  
  # 1. Stelle sicher, dass das Documentroot-Verzeichnis existiert
  sudo mkdir -p "$DOCROOT" || {
    log "ERROR" "Konnte Documentroot-Verzeichnis nicht erstellen: $DOCROOT"
    return 1
  }
  
  # 2. Setze Berechtigungen
  sudo chown -R www-data:www-data "$DOCROOT" || {
    log "ERROR" "Konnte Berechtigungen für Documentroot nicht setzen"
    return 1
  }
  
  # 3. Prüfe, ob die Subdomain im DNS existiert, bevor wir das SSL-Zertifikat erstellen
  local max_dns_checks=3
  local dns_check_count=0
  local dns_success=0
  
  while [[ $dns_check_count -lt $max_dns_checks && $dns_success -eq 0 ]]; do
    dns_check_count=$((dns_check_count+1))
    
    if dig +short "${SUB}.${DOMAIN}" | grep -q "[0-9]"; then
      log "INFO" "DNS-Eintrag für ${SUB}.${DOMAIN} gefunden. Fahre fort."
      dns_success=1
    else
      log "WARNING" "DNS-Eintrag für ${SUB}.${DOMAIN} noch nicht gefunden. Warte kurz..."
      sleep 10
    fi
  done
  
  # Selbst wenn DNS noch nicht propagiert ist, fahren wir fort, aber geben eine Warnung aus
  if [[ $dns_success -eq 0 ]]; then
    log "WARNING" "DNS-Eintrag für ${SUB}.${DOMAIN} konnte nicht verifiziert werden. Dies könnte Probleme bei der SSL-Zertifikatserstellung verursachen."
  fi
  
  # 3. Erstelle vHost-Konfiguration mit intelligenter SSL-Verwaltung
  # Die Funktion create_vhost_config kümmert sich jetzt automatisch um die besten Zertifikate
  create_vhost_config "$SUB" || {
    log "ERROR" "Konnte vHost-Konfiguration nicht erstellen"
    return 1
  }
  
  # 4. Aktiviere vHost mit Fehlerbehandlung
  # Zuerst Syntax prüfen
  local syntax_error=$(sudo apachectl -t 2>&1)
  if [[ $? -ne 0 ]]; then
    log "ERROR" "Apache-Konfigurationsfehler: $syntax_error"
    log "INFO" "Versuche, den Fehler automatisch zu beheben..."
    
    # Prüfe, ob die Zertifikatsdateien existieren
    if ! [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then
      log "ERROR" "SSL-Zertifikatsdateien nicht gefunden: $CERT_PATH oder $KEY_PATH"
      
      # Wenn kein SSL-Zertifikat gefunden wurde, erstelle eine HTTP-only VHost-Konfiguration als Fallback
      log "INFO" "Erstelle temporäre HTTP-only VHost-Konfiguration als Fallback"
      create_http_vhost "$SUB" "HTTP-only fallback"
    fi
  fi
  
  # Jetzt versuchen, den vHost zu aktivieren
  log "INFO" "Aktiviere vHost für $SUB"
  if ! enable_vhost "$SUB"; then
    log "WARNING" "Aktivierung mit enable_vhost fehlgeschlagen, versuche direkten Ansatz"
    
    # Direkt Symlink prüfen und erstellen
    if [[ ! -e "/etc/apache2/sites-enabled/${SUB}.conf" ]]; then
      log "INFO" "Erzeuge Symlink manuell"
      sudo ln -sf "/etc/apache2/sites-available/${SUB}.conf" "/etc/apache2/sites-enabled/${SUB}.conf" || {
        log "ERROR" "Konnte Symlink nicht manuell erstellen"
        return 1
      }
    fi
    
    # Überprüfe, ob der Symlink jetzt existiert
    if [[ ! -e "/etc/apache2/sites-enabled/${SUB}.conf" ]]; then
      log "ERROR" "Konnte vHost nicht aktivieren - Symlink fehlt"
      return 1
    else
      log "SUCCESS" "vHost manuell aktiviert"
    fi
  fi
  
  log "SUCCESS" "Apache vHost für $FQDN erfolgreich eingerichtet"
  return 0
}

# Apache vHost entfernen
# Usage: remove_vhost <subdomain-name>
function remove_vhost() {
  local SUB="$1"
  
  log "INFO" "Entferne Apache vHost für $SUB"
  
  # Nutze die cleanup-Funktion, um alle zugehörigen Konfigurationen zu entfernen
  cleanup_apache_configs "$SUB"
  
  # Entferne alle temporären Let's Encrypt-Dateien für die Domain
  local LE_TEMP_FILES=(
    "/etc/apache2/sites-available/${SUB}-le-ssl.conf"
    "/etc/apache2/sites-available/${SUB}-temp-le-ssl.conf"
  )
  
  for temp_file in "${LE_TEMP_FILES[@]}"; do
    if [[ -f "$temp_file" ]]; then
      log "INFO" "Entferne temporäre Let's Encrypt-Konfiguration: $temp_file"
      sudo rm -f "$temp_file"
    fi
  done
  
  # Erfolgslog
  log "INFO" "Konfigurationen für $SUB bereinigt"
  
  # 3. Prüfe auf zusätzliche SSL-Konfiguration
  local SSL_VHOST_CONFIG="${APACHE_SITES_DIR}/${SUB}-le-ssl.conf"
  
  # 4. Lade Apache neu
  sudo systemctl reload apache2 > /dev/null 2>&1 || {
    log "WARNING" "Konnte Apache nicht neu laden"
  }
  
  log "SUCCESS" "Apache vHost für $SUB erfolgreich entfernt"
  return 0
}