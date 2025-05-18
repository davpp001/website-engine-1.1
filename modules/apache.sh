#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# APACHE VHOST-MANAGEMENT-MODUL
# ====================================================================

# Import config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# SSL-Zertifikat prüfen
# Usage: check_ssl_cert
function check_ssl_cert() {
  if [[ ! -f "$SSL_CERT_PATH" ]]; then
    log "ERROR" "SSL-Zertifikat nicht gefunden: $SSL_CERT_PATH"
    log "ERROR" "Bitte erstelle ein SSL-Zertifikat mit: certbot certonly --dns-cloudflare -d *.$DOMAIN"
    return 1
  fi
  
  log "INFO" "SSL-Zertifikat gefunden: $SSL_CERT_PATH"
  
  # Prüfe Ablaufdatum
  local cert_end_date=$(openssl x509 -in "$SSL_CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)
  if [[ -n "$cert_end_date" ]]; then
    local cert_end_epoch=$(date -d "$cert_end_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$cert_end_date" +%s 2>/dev/null)
    local now_epoch=$(date +%s)
    local days_left=$(( (cert_end_epoch - now_epoch) / 86400 ))
    
    if [[ $days_left -lt 0 ]]; then
      log "ERROR" "SSL-Zertifikat ist abgelaufen!"
      return 1
    elif [[ $days_left -lt 15 ]]; then
      log "WARNING" "SSL-Zertifikat läuft in $days_left Tagen ab! Baldige Erneuerung empfohlen."
    else
      log "INFO" "SSL-Zertifikat ist gültig für weitere $days_left Tage"
    fi
  else
    log "ERROR" "SSL-Zertifikat konnte nicht überprüft werden"
    return 1
  fi
  
  return 0
}

# Vhost-Konfiguration erstellen
# Usage: create_vhost_config <subdomain-name>
function create_vhost_config() {
  local SUB="$1"
  local FQDN="${SUB}.${DOMAIN}"
  local DOCROOT="${WP_DIR}/${SUB}"
  local VHOST_CONFIG="${APACHE_SITES_DIR}/${SUB}.conf"
  
  log "INFO" "Erstelle Apache vHost-Konfiguration für $FQDN in $VHOST_CONFIG"
  
  # Stelle sicher, dass SSL-Zertifikat existiert
  check_ssl_cert || return 1
  
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
  SSLCertificateFile ${SSL_CERT_PATH}
  SSLCertificateKeyFile ${SSL_KEY_PATH}
  
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
    return 1
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
  
  # 3. Erstelle vHost-Konfiguration
  create_vhost_config "$SUB" || {
    log "ERROR" "Konnte vHost-Konfiguration nicht erstellen"
    return 1
  }
  
  # 4. Aktiviere vHost
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