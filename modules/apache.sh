#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# APACHE VHOST-MANAGEMENT-MODUL
# ====================================================================

# Import config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

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
    log "INFO" "Erstelle ein eigenes Zertifikat für $DOMAIN_TO_CHECK"
    
    if sudo certbot --apache --non-interactive --agree-tos --email "$SSL_EMAIL" -d "$DOMAIN_TO_CHECK"; then
      log "SUCCESS" "SSL-Zertifikat für $DOMAIN_TO_CHECK erfolgreich erstellt und Apache konfiguriert"
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
        
        if sudo certbot --apache --non-interactive --agree-tos --email "$SSL_EMAIL" -d "$DOMAIN_TO_CHECK"; then
          CERT_PATH="/etc/letsencrypt/live/$DOMAIN_TO_CHECK/fullchain.pem"
          KEY_PATH="/etc/letsencrypt/live/$DOMAIN_TO_CHECK/privkey.pem"
          log "SUCCESS" "SSL-Zertifikat für $DOMAIN_TO_CHECK erfolgreich erstellt und Apache konfiguriert"
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
      
      # Direkt mit Apache-Integration erstellen
      # Das löst beide Probleme: Zertifikat erstellen UND Apache richtig konfigurieren
      if sudo certbot --apache --non-interactive --agree-tos --email "$SSL_EMAIL" -d "$FQDN"; then
        # Aktualisiere Zertifikatspfade nach erfolgreicher Erstellung
        CERT_PATH="/etc/letsencrypt/live/$FQDN/fullchain.pem"
        KEY_PATH="/etc/letsencrypt/live/$FQDN/privkey.pem"
        log "SUCCESS" "SSL-Zertifikat für $FQDN erfolgreich erstellt und Apache konfiguriert"
      else
        log "ERROR" "Konnte kein SSL-Zertifikat erstellen. VHost wird mit Standard-Zertifikat konfiguriert."
        CERT_PATH="$SSL_CERT_PATH"
        KEY_PATH="$SSL_KEY_PATH"
      fi
    fi
  fi
  
  # Erzeuge vHost-Konfiguration
  sudo tee "$VHOST_CONFIG" > /dev/null << VHOST_EOF
# Apache VirtualHost für ${FQDN}
# Erstellt von Website Engine am $(date '+%Y-%m-%d %H:%M:%S')

# HTTP -> HTTPS Redirect
<VirtualHost *:80>
  ServerName ${FQDN}
  ServerAdmin ${WP_EMAIL}
  ServerSignature Off
  
  ErrorLog \${APACHE_LOG_DIR}/${SUB}_error.log
  CustomLog \${APACHE_LOG_DIR}/${SUB}_access.log combined
  
  Redirect permanent / https://${FQDN}/
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
  
  # Prüfe, ob die Konfiguration erfolgreich erstellt wurde
  if [[ ! -f "$VHOST_CONFIG" ]]; then
    log "ERROR" "Konnte vHost-Konfiguration nicht erstellen: $VHOST_CONFIG"
    return 1
  fi
  
  # Prüfe, ob die Zertifikatsdateien existieren, falls SSL verwendet wird
  if grep -q "SSLCertificateFile" "$VHOST_CONFIG"; then
    # Nur prüfen, wenn es sich um eine SSL-Konfiguration handelt
    if [[ ! -f "$CERT_PATH" ]]; then
      log "ERROR" "SSL-Zertifikatsdatei nicht gefunden: $CERT_PATH"
      log "INFO" "Erstelle HTTP-only Fallback-Konfiguration"
      
      # Erstelle HTTP-only VHost als Fallback
      sudo tee "$VHOST_CONFIG" > /dev/null << VHOST_HTTP_EOF
# Apache VirtualHost für ${FQDN} (HTTP-only fallback)
# Erstellt von Website Engine am $(date '+%Y-%m-%d %H:%M:%S')
# HINWEIS: Dies ist eine Fallback-Konfiguration, da das SSL-Zertifikat fehlt

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
</VirtualHost>
VHOST_HTTP_EOF
    fi
  fi
  
  log "SUCCESS" "Apache vHost-Konfiguration für $FQDN erstellt"
  return 0
}

# Apache vHost aktivieren
# Usage: enable_vhost <subdomain-name>
function enable_vhost() {
  local SUB="$1"
  local VHOST_CONFIG="${APACHE_SITES_DIR}/${SUB}.conf"
  
  log "INFO" "Aktiviere Apache vHost für $SUB"
  
  # Prüfe, ob Konfiguration existiert
  if [[ ! -f "$VHOST_CONFIG" ]]; then
    log "ERROR" "vHost-Konfiguration nicht gefunden: $VHOST_CONFIG"
    return 1
  fi
  
  # Prüfe Apache-Syntax
  local syntax_check=$(sudo apache2ctl -t 2>&1)
  if [[ $? -ne 0 ]]; then
    log "ERROR" "Apache-Syntax ungültig: $syntax_check"
    
    # Versuche, die häufigsten Fehler zu beheben
    if [[ "$syntax_check" == *"SSLCertificateFile"* || "$syntax_check" == *"SSLCertificateKeyFile"* ]]; then
      log "WARNING" "Fehler bei SSL-Konfiguration erkannt. Erstelle HTTP-only Fallback"
      
      # Erstelle HTTP-only Fallback
      sudo tee "$VHOST_CONFIG" > /dev/null << VHOST_HTTP_EOF
# Apache VirtualHost für ${SUB}.${DOMAIN} (HTTP-only recovery)
# Erstellt von Website Engine am $(date '+%Y-%m-%d %H:%M:%S')
# HINWEIS: Dies ist eine Fallback-Konfiguration nach SSL-Fehler

<VirtualHost *:80>
  ServerName ${SUB}.${DOMAIN}
  ServerAdmin ${WP_EMAIL}
  ServerSignature Off
  
  DocumentRoot ${WP_DIR}/${SUB}
  
  ErrorLog \${APACHE_LOG_DIR}/${SUB}_error.log
  CustomLog \${APACHE_LOG_DIR}/${SUB}_access.log combined
  
  <Directory ${WP_DIR}/${SUB}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
</VirtualHost>
VHOST_HTTP_EOF

      # Prüfe erneut die Syntax
      syntax_check=$(sudo apache2ctl -t 2>&1)
      if [[ $? -ne 0 ]]; then
        log "ERROR" "Apache-Syntax immer noch ungültig: $syntax_check"
        return 1
      else
        log "INFO" "Fallback-Konfiguration erstellt und Syntax validiert"
      fi
    else
      # Andere Fehler können wir nicht automatisch beheben
      return 1
    fi
  fi
  
  # Aktiviere vHost mit a2ensite
  sudo a2ensite "${SUB}.conf" > /dev/null 2>&1 || {
    log "ERROR" "Konnte vHost nicht aktivieren mit a2ensite"
    return 1
  }
  
  # Lade Apache neu
  sudo systemctl reload apache2 > /dev/null 2>&1 || {
    log "ERROR" "Konnte Apache nicht neu laden"
    return 1
  }
  
  log "SUCCESS" "Apache vHost für $SUB aktiviert"
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
      sudo tee "$VHOST_CONFIG" > /dev/null << VHOST_HTTP_EOF
# Apache VirtualHost für ${FQDN} (HTTP-only fallback)
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
</VirtualHost>
VHOST_HTTP_EOF
    fi
  fi
  
  # Jetzt versuchen, den vHost zu aktivieren
  enable_vhost "$SUB" || {
    log "ERROR" "Konnte vHost nicht aktivieren"
    return 1
  }
  
  log "SUCCESS" "Apache vHost für $FQDN erfolgreich eingerichtet"
  return 0
}

# Apache vHost entfernen
# Usage: remove_vhost <subdomain-name>
function remove_vhost() {
  local SUB="$1"
  local VHOST_CONFIG="${APACHE_SITES_DIR}/${SUB}.conf"
  
  log "INFO" "Entferne Apache vHost für $SUB"
  
  # 1. Deaktiviere vHost mit a2dissite
  local site_enabled=0
  if [[ -f "/etc/apache2/sites-enabled/${SUB}.conf" ]]; then
    site_enabled=1
  fi
  
  if [[ $site_enabled -eq 1 ]]; then
    sudo a2dissite "${SUB}.conf" > /dev/null 2>&1 || {
      log "WARNING" "Konnte vHost nicht deaktivieren mit a2dissite, versuche trotzdem fortzufahren"
    }
  else 
    log "INFO" "vHost ist bereits deaktiviert"
  fi
  
  # 2. Entferne Konfigurationsdatei
  if [[ -f "$VHOST_CONFIG" ]]; then
    sudo rm -f "$VHOST_CONFIG" || {
      log "WARNING" "Konnte vHost-Konfiguration nicht löschen: $VHOST_CONFIG"
    }
    log "INFO" "vHost-Konfiguration gelöscht: $VHOST_CONFIG"
  else
    log "INFO" "vHost-Konfiguration existiert nicht: $VHOST_CONFIG"
  fi
  
  # 3. Prüfe auf zusätzliche SSL-Konfiguration
  local SSL_VHOST_CONFIG="${APACHE_SITES_DIR}/${SUB}-le-ssl.conf"
  if [[ -f "$SSL_VHOST_CONFIG" ]]; then
    # Deaktiviere zuerst, falls aktiviert
    if [[ -f "/etc/apache2/sites-enabled/${SUB}-le-ssl.conf" ]]; then
      sudo a2dissite "${SUB}-le-ssl.conf" > /dev/null 2>&1 || {
        log "WARNING" "Konnte SSL-vHost nicht deaktivieren, versuche trotzdem fortzufahren"
      }
    fi
    
    # Dann lösche die Datei
    sudo rm -f "$SSL_VHOST_CONFIG" || {
      log "WARNING" "Konnte SSL-vHost-Konfiguration nicht löschen: $SSL_VHOST_CONFIG"
    }
    log "INFO" "SSL-vHost-Konfiguration gelöscht: $SSL_VHOST_CONFIG"
  fi
  
  # 4. Lade Apache neu
  sudo systemctl reload apache2 > /dev/null 2>&1 || {
    log "WARNING" "Konnte Apache nicht neu laden"
  }
  
  log "SUCCESS" "Apache vHost für $SUB erfolgreich entfernt"
  return 0
}