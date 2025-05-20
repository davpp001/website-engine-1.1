#!/bin/bash
# This script completely replaces the setup_vhost function in apache.sh

APACHE_FILE="/opt/website-engine-1.1/modules/apache.sh"
BACKUP_FILE="/opt/website-engine-1.1/modules/apache.sh.bak.$(date +%Y%m%d%H%M%S)"

# Create a backup
cp "$APACHE_FILE" "$BACKUP_FILE"
echo "Created backup at $BACKUP_FILE"

# Extract the current setup_vhost function
sed -n '/^function setup_vhost/,/^}/p' "$APACHE_FILE" > /tmp/old_setup_vhost.txt
echo "Extracted current function to /tmp/old_setup_vhost.txt for reference"

# Define the new setup_vhost function
read -r -d '' NEW_FUNCTION << 'EOF'
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
EOF

# Replace the function in the file
# First, create a temporary file with the entire script
# We'll use pattern matching to find and replace the function

# First, add a marker for easier replacement
sed -i '/^function setup_vhost/,/^}/c\### SETUP_VHOST_PLACEHOLDER ###' "$APACHE_FILE"

# Now replace the placeholder with our corrected function
sed -i "s|### SETUP_VHOST_PLACEHOLDER ###|$NEW_FUNCTION|" "$APACHE_FILE"

# Verify syntax
bash -n "$APACHE_FILE"
if [ $? -eq 0 ]; then
  echo "✅ The setup_vhost function has been successfully replaced."
  echo "The script syntax now looks good!"
else
  echo "❌ There's still a syntax error in the file."
  echo "Restoring the backup from $BACKUP_FILE"
  cp "$BACKUP_FILE" "$APACHE_FILE"
  echo "The original file has been restored."
  echo "Please manually edit the file to fix the syntax error."
  echo "The error is likely in the setup_vhost function. Look for unmatched braces or other issues."
fi
