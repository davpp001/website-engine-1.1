#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# WORDPRESS-MANAGEMENT-MODUL
# ====================================================================

# Import config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Maximale Anzahl der Wiederholungsversuche
MAX_RETRIES=3

# WordPress auf erfolgreiche Installation prüfen
# Usage: check_wordpress_installation <subdomain-name>
function check_wordpress_installation() {
  local SUB="$1"
  local DOCROOT="${WP_DIR}/${SUB}"
  
  log "INFO" "Prüfe WordPress-Installation in $DOCROOT"
  
  # Prüfe, ob Verzeichnis existiert
  if [[ ! -d "$DOCROOT" ]]; then
    log "ERROR" "WordPress-Verzeichnis existiert nicht: $DOCROOT"
    return 1
  fi
  
  # Prüfe, ob wp-config.php existiert
  if [[ ! -f "$DOCROOT/wp-config.php" ]]; then
    log "ERROR" "wp-config.php nicht gefunden in $DOCROOT"
    return 1
  fi
  
  # Prüfe, ob index.php existiert
  if [[ ! -f "$DOCROOT/index.php" ]]; then
    log "ERROR" "index.php nicht gefunden in $DOCROOT"
    return 1
  fi
  
  # Prüfe, ob wp-admin/ existiert
  if [[ ! -d "$DOCROOT/wp-admin" ]]; then
    log "ERROR" "wp-admin/ nicht gefunden in $DOCROOT"
    return 1
  fi
  
  log "SUCCESS" "WordPress-Installation in $DOCROOT ist vollständig"
  return 0
}

# WordPress-Datenbankverbindung abrufen
# Usage: get_db_credentials <subdomain-name>
function get_db_credentials() {
  local SUB="$1"
  local DB_INFO_FILE="$CONFIG_DIR/sites/${SUB}/db-info.env"
  
  log "INFO" "Lese Datenbank-Anmeldedaten für $SUB"
  
  # Prüfe, ob Datei existiert
  if [[ -f "$DB_INFO_FILE" ]]; then
    log "INFO" "DB-Info-Datei gefunden: $DB_INFO_FILE"
    source "$DB_INFO_FILE"
    local DB_NAME_LOCAL=${DB_NAME:-""}
    local DB_USER_LOCAL=${DB_USER:-""}
    local DB_PASS_LOCAL=${DB_PASS:-""}
    
    if [[ -n "$DB_NAME_LOCAL" && -n "$DB_USER_LOCAL" && -n "$DB_PASS_LOCAL" ]]; then
      log "INFO" "Datenbank-Anmeldedaten für $SUB geladen"
      return 0
    else
      log "WARNING" "Unvollständige Datenbank-Anmeldedaten in $DB_INFO_FILE"
    fi
  fi
  
  # Standardwerte
  log "INFO" "Verwende Standard-Datenbank-Namen und -Benutzer"
  export DB_NAME="${DB_PREFIX}${SUB//./_}"
  export DB_USER="${DB_PREFIX}${SUB//./_}_user"
  # Zufälliges Passwort generieren
  export DB_PASS=$(generate_secure_password 20)
  
  log "SUCCESS" "Standard-Datenbank-Anmeldedaten für $SUB erstellt"
  return 0
}

# WordPress-Datenbank erstellen
# Usage: create_wordpress_database <subdomain-name>
function create_wordpress_database() {
  local SUB="$1"
  
  log "INFO" "Erstelle WordPress-Datenbank für $SUB"
  
  # Lade Datenbank-Anmeldedaten
  get_db_credentials "$SUB"
  
  # Verwende erstellte Anmeldedaten
  local DB_NAME_LOCAL="$DB_NAME"
  local DB_USER_LOCAL="$DB_USER"
  local DB_PASS_LOCAL="$DB_PASS"
  
  log "INFO" "Erstelle Datenbank $DB_NAME_LOCAL und Benutzer $DB_USER_LOCAL"
  
  # Mit Wiederholungsversuchen
  local retry=0
  local success=0
  
  while [[ $retry -lt $MAX_RETRIES && $success -eq 0 ]]; do
    # Führe MySQL-Befehle aus, um Datenbank und Benutzer zu erstellen
    if sudo mysql -e "
      CREATE DATABASE IF NOT EXISTS \`${DB_NAME_LOCAL}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      CREATE USER IF NOT EXISTS '${DB_USER_LOCAL}'@'localhost' IDENTIFIED BY '${DB_PASS_LOCAL}';
      GRANT ALL PRIVILEGES ON \`${DB_NAME_LOCAL}\`.* TO '${DB_USER_LOCAL}'@'localhost';
      FLUSH PRIVILEGES;" 2>/dev/null; then
      success=1
      log "SUCCESS" "Datenbank $DB_NAME_LOCAL und Benutzer $DB_USER_LOCAL erfolgreich erstellt"
    else
      retry=$((retry+1))
      log "WARNING" "Fehler beim Erstellen der Datenbank (Versuch $retry von $MAX_RETRIES)"
      sleep 2
    fi
  done
  
  if [[ $success -eq 0 ]]; then
    log "ERROR" "Konnte Datenbank für $SUB nicht erstellen"
    return 1
  fi
  
  # Speichere Datenbank-Informationen
  local DB_INFO_DIR="$CONFIG_DIR/sites/${SUB}"
  local DB_INFO_FILE="$DB_INFO_DIR/db-info.env"
  
  sudo mkdir -p "$DB_INFO_DIR"
  sudo tee "$DB_INFO_FILE" > /dev/null << INFO_EOF
# Datenbank-Informationen für ${SUB}.${DOMAIN}
# Erstellt von Website Engine am $(date '+%Y-%m-%d %H:%M:%S')
DB_NAME=${DB_NAME_LOCAL}
DB_USER=${DB_USER_LOCAL}
DB_PASS=${DB_PASS_LOCAL}
INFO_EOF
  
  sudo chmod 600 "$DB_INFO_FILE"
  
  log "SUCCESS" "Datenbank-Anmeldedaten gespeichert in $DB_INFO_FILE"
  return 0
}

# WordPress-Datenbank löschen
# Usage: drop_wordpress_database <subdomain-name>
function drop_wordpress_database() {
  local SUB="$1"
  local DB_INFO_FILE="$CONFIG_DIR/sites/${SUB}/db-info.env"
  
  log "INFO" "Lösche WordPress-Datenbank für $SUB"
  
  # Lade Datenbank-Anmeldedaten
  local DB_NAME_LOCAL=""
  local DB_USER_LOCAL=""
  
  if [[ -f "$DB_INFO_FILE" ]]; then
    source "$DB_INFO_FILE"
    DB_NAME_LOCAL=${DB_NAME:-""}
    DB_USER_LOCAL=${DB_USER:-""}
  else
    # Standard-Namen, falls keine Info-Datei existiert
    DB_NAME_LOCAL="${DB_PREFIX}${SUB//./_}"
    DB_USER_LOCAL="${DB_PREFIX}${SUB//./_}_user"
  fi
  
  log "INFO" "Lösche Datenbank $DB_NAME_LOCAL und Benutzer $DB_USER_LOCAL"
  
  # Mit Wiederholungsversuchen
  local retry=0
  local success=0
  
  while [[ $retry -lt $MAX_RETRIES && $success -eq 0 ]]; do
    # Führe MySQL-Befehle aus, um Datenbank und Benutzer zu löschen
    if sudo mysql -e "
      DROP DATABASE IF EXISTS \`${DB_NAME_LOCAL}\`;
      DROP USER IF EXISTS '${DB_USER_LOCAL}'@'localhost';
      FLUSH PRIVILEGES;" 2>/dev/null; then
      success=1
      log "SUCCESS" "Datenbank $DB_NAME_LOCAL und Benutzer $DB_USER_LOCAL erfolgreich gelöscht"
    else
      retry=$((retry+1))
      log "WARNING" "Fehler beim Löschen der Datenbank (Versuch $retry von $MAX_RETRIES)"
      sleep 2
    fi
  done
  
  # Lösche Anmeldedaten-Datei
  if [[ -f "$DB_INFO_FILE" ]]; then
    sudo rm -f "$DB_INFO_FILE"
    log "INFO" "Datenbank-Anmeldedaten-Datei gelöscht: $DB_INFO_FILE"
    
    # Versuche, das Verzeichnis zu löschen, wenn es leer ist
    sudo rmdir "$CONFIG_DIR/sites/${SUB}" 2>/dev/null || true
  fi
  
  if [[ $success -eq 0 ]]; then
    log "ERROR" "Konnte Datenbank für $SUB nicht vollständig löschen"
    return 1
  fi
  
  return 0
}

# WordPress installieren
# Usage: install_wordpress <subdomain-name>
function install_wordpress() {
  local SUB="$1"
  local FQDN="${SUB}.${DOMAIN}"
  local DOCROOT="${WP_DIR}/${SUB}"
  
  log "INFO" "Installiere WordPress für $SUB in $DOCROOT"
  
  # Stelle sicher, dass Anmeldedaten geladen sind
  load_env_vars
  
  # 1. Erstelle Datenbank
  create_wordpress_database "$SUB" || {
    log "ERROR" "Konnte WordPress-Datenbank nicht erstellen"
    return 1
  }
  
  # Verwende die Datenbank-Anmeldedaten
  local DB_NAME_LOCAL="$DB_NAME"
  local DB_USER_LOCAL="$DB_USER"
  local DB_PASS_LOCAL="$DB_PASS"
  
  # 2. Lade WordPress-Core herunter
  log "INFO" "Lade WordPress-Core herunter"
  
  # Prüfe, ob bereits WordPress-Dateien vorhanden sind
  if [[ -f "$DOCROOT/wp-config.php" || -d "$DOCROOT/wp-admin" ]]; then
    log "WARNING" "WordPress-Dateien scheinen bereits vorhanden zu sein. Bereinige Verzeichnis..."
    sudo rm -rf "$DOCROOT"
    sudo mkdir -p "$DOCROOT"
    sudo chown www-data:www-data "$DOCROOT"
  fi
  
  if ! sudo -u www-data wp core download --path="$DOCROOT" --quiet; then
    log "ERROR" "Konnte WordPress-Core nicht herunterladen"
    return 1
  fi
  
  # 3. Erstelle wp-config.php
  log "INFO" "Erstelle wp-config.php"
  
  # Zufällige Salts generieren
  local WP_SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
  
  # Erstelle wp-config.php mit erhöhter Sicherheit
  if ! sudo -u www-data wp config create --path="$DOCROOT" \
    --dbname="$DB_NAME_LOCAL" --dbuser="$DB_USER_LOCAL" --dbpass="$DB_PASS_LOCAL" \
    --extra-php <<PHP
/* Automatisch generierte Salts */
$WP_SALTS

/* Sicherheitseinstellungen */
define('DISALLOW_FILE_EDIT', true);
define('WP_POST_REVISIONS', 5);
define('AUTOMATIC_UPDATER_DISABLED', false);
define('WP_AUTO_UPDATE_CORE', 'minor');
PHP
  then
    log "ERROR" "Konnte wp-config.php nicht erstellen"
    return 1
  fi
  
  # Überprüfe, ob Konstanten bereits definiert sind, bevor sie hinzugefügt werden
  if ! grep -q "define('DISALLOW_FILE_EDIT'" "$DOCROOT/wp-config.php"; then
    echo "define('DISALLOW_FILE_EDIT', true);" | sudo -u www-data tee -a "$DOCROOT/wp-config.php" > /dev/null
  fi
  if ! grep -q "define('WP_POST_REVISIONS'" "$DOCROOT/wp-config.php"; then
    echo "define('WP_POST_REVISIONS', 5);" | sudo -u www-data tee -a "$DOCROOT/wp-config.php" > /dev/null
  fi
  if ! grep -q "define('AUTOMATIC_UPDATER_DISABLED'" "$DOCROOT/wp-config.php"; then
    echo "define('AUTOMATIC_UPDATER_DISABLED', false);" | sudo -u www-data tee -a "$DOCROOT/wp-config.php" > /dev/null
  fi
  if ! grep -q "define('WP_AUTO_UPDATE_CORE'" "$DOCROOT/wp-config.php"; then
    echo "define('WP_AUTO_UPDATE_CORE', 'minor');" | sudo -u www-data tee -a "$DOCROOT/wp-config.php" > /dev/null
  fi
  
  # 4. WordPress installieren
  log "INFO" "Führe WordPress-Installation durch"
  
  if ! sudo -u www-data wp core install --path="$DOCROOT" \
    --url="https://${FQDN}" \
    --title="WordPress ${SUB}" \
    --admin_user="$WP_USER" \
    --admin_password="$WP_PASS" \
    --admin_email="$WP_EMAIL" \
    --skip-email; then
    log "ERROR" "Konnte WordPress nicht installieren"
    return 1
  fi
  
  # 5. Standard-Plugins und -Themes entfernen
  log "INFO" "Bereinige Standard-Plugins und -Themes"
  
  # Entferne Standard-Themes außer dem aktuellen
  local current_theme=$(sudo -u www-data wp theme list --path="$DOCROOT" --status=active --field=name)
  for theme in $(sudo -u www-data wp theme list --path="$DOCROOT" --field=name); do
    if [[ "$theme" != "$current_theme" && "$theme" != "twentytwentyfour" ]]; then
      sudo -u www-data wp theme delete "$theme" --path="$DOCROOT" --quiet
    fi
  done
  
  # Entferne Standard-Plugins, die nicht benötigt werden
  sudo -u www-data wp plugin deactivate hello --path="$DOCROOT" --quiet 2>/dev/null || true
  sudo -u www-data wp plugin delete hello --path="$DOCROOT" --quiet 2>/dev/null || true
  
  # 6. Optimale Einstellungen
  log "INFO" "Konfiguriere optimale Einstellungen"
  
  # Permalink-Struktur
  sudo -u www-data wp rewrite structure '/%postname%/' --path="$DOCROOT" --quiet
  
  # Deaktiviere Kommentare standardmäßig
  sudo -u www-data wp option update default_comment_status closed --path="$DOCROOT" --quiet
  
  # Setze Zeitzone
  sudo -u www-data wp option update timezone_string 'Europe/Berlin' --path="$DOCROOT" --quiet
  
  # Deaktiviere XML-RPC
  if ! grep -q "xmlrpc" "$DOCROOT/.htaccess" 2>/dev/null; then
    echo "# Disable XML-RPC
<Files xmlrpc.php>
  order deny,allow
  deny from all
</Files>" | sudo -u www-data tee -a "$DOCROOT/.htaccess" > /dev/null
  fi
  
  # Verstecke WP-Version
  if ! grep -q "remove_action.*wp_generator" "$DOCROOT/wp-content/themes/$current_theme/functions.php" 2>/dev/null; then
    echo "
// Verstecke WordPress-Version
remove_action('wp_head', 'wp_generator');" | sudo -u www-data tee -a "$DOCROOT/wp-content/themes/$current_theme/functions.php" > /dev/null
  fi
  
  # 7. Abschließende Prüfung
  check_wordpress_installation "$SUB" || {
    log "ERROR" "WordPress-Installation scheint nicht vollständig zu sein"
    return 1
  }
  
  log "SUCCESS" "WordPress für $FQDN erfolgreich installiert"
  log "INFO" "Admin-Login: https://$FQDN/wp-admin/"
  log "INFO" "Benutzer: $WP_USER / Passwort: $WP_PASS"
  
  return 0
}

# WordPress deinstallieren
# Usage: uninstall_wordpress <subdomain-name>
function uninstall_wordpress() {
  local SUB="$1"
  local DOCROOT="${WP_DIR}/${SUB}"
  
  log "INFO" "Deinstalliere WordPress für $SUB"
  
  # 1. WordPress-Verzeichnis löschen
  if [[ -d "$DOCROOT" ]]; then
    log "INFO" "Lösche WordPress-Verzeichnis: $DOCROOT"
    
    # Mit Wiederholungsversuchen
    local retry=0
    local success=0
    
    while [[ $retry -lt $MAX_RETRIES && $success -eq 0 ]]; do
      if sudo rm -rf "$DOCROOT" 2>/dev/null; then
        success=1
        log "SUCCESS" "WordPress-Verzeichnis $DOCROOT erfolgreich gelöscht"
      else
        retry=$((retry+1))
        log "WARNING" "Fehler beim Löschen des WordPress-Verzeichnisses (Versuch $retry von $MAX_RETRIES)"
        sleep 2
      fi
    done
    
    if [[ $success -eq 0 ]]; then
      log "ERROR" "Konnte WordPress-Verzeichnis nicht löschen"
      # Ignoriere den Fehler und fahre fort
    fi
  else
    log "INFO" "WordPress-Verzeichnis existiert nicht: $DOCROOT"
  fi
  
  # 2. Datenbank und Benutzer löschen
  drop_wordpress_database "$SUB" || {
    log "ERROR" "Konnte WordPress-Datenbank nicht löschen"
    # Ignoriere den Fehler und fahre fort
  }
  
  log "SUCCESS" "WordPress-Installation für $SUB erfolgreich entfernt"
  return 0
}