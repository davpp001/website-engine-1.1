#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# WORDPRESS-SITE LÖSCHEN
# ====================================================================

# Import modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")/modules"

source "${MODULE_DIR}/config.sh"
source "${MODULE_DIR}/cloudflare.sh"
source "${MODULE_DIR}/apache.sh"
source "${MODULE_DIR}/wordpress.sh"

# Show usage
usage() {
  echo "Verwendung: $0 <subdomain-name> [--keep-dns] [--keep-db] [--force]"
  echo
  echo "Löscht eine WordPress-Seite für die angegebene Subdomain."
  echo
  echo "Optionen:"
  echo "  --keep-dns    DNS-Einträge beibehalten (nur Apache und WordPress entfernen)"
  echo "  --keep-db     Datenbank beibehalten (nur Dateien und Apache entfernen)"
  echo "  --force       Keine Bestätigung abfragen, direkt löschen"
  echo "  --help        Diese Hilfe anzeigen"
  echo
  echo "Beispiele:"
  echo "  $0 kunde1                # Löscht kunde1.$DOMAIN vollständig"
  echo "  $0 test --keep-dns       # Löscht test.$DOMAIN, behält aber DNS-Einträge"
  exit 1
}

log "INFO" "===== LÖSCHE WORDPRESS-SITE ====="

# Parse arguments
SUBDOMAIN=""
KEEP_DNS=0
KEEP_DB=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-dns)
      KEEP_DNS=1
      shift
      ;;
    --keep-db)
      KEEP_DB=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --help)
      usage
      ;;
    -*)
      echo "Unbekannte Option: $1"
      usage
      ;;
    *)
      if [[ -z "$SUBDOMAIN" ]]; then
        SUBDOMAIN="$1"
      else
        echo "Zu viele Parameter: $1"
        usage
      fi
      shift
      ;;
  esac
done

# Check if subdomain is provided
if [[ -z "$SUBDOMAIN" ]]; then
  echo "❌ Fehler: Bitte geben Sie einen Subdomain-Namen an."
  usage
fi

# Systemprüfung
if ! check_system_ready; then
  echo "❌ Systemprüfung fehlgeschlagen. Bitte führen Sie zuerst setup-server.sh aus."
  exit 1
fi

# Bestätigung abfragen, wenn nicht --force
if [[ $FORCE -eq 0 ]]; then
  echo "🔔 Sie sind dabei, die WordPress-Site für $SUBDOMAIN.$DOMAIN zu löschen."
  
  if [[ $KEEP_DNS -eq 1 ]]; then
    echo "   DNS-Einträge bleiben erhalten."
  else
    echo "   DNS-Einträge werden gelöscht."
  fi
  
  if [[ $KEEP_DB -eq 1 ]]; then
    echo "   Datenbank bleibt erhalten."
  else
    echo "   Datenbank wird gelöscht."
  fi
  
  read -p "Sind Sie sicher? (j/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[jJyY]$ ]]; then
    echo "❌ Vorgang abgebrochen."
    exit 0
  fi
fi

# Main process
echo "🗑️ Lösche WordPress-Seite mit Subdomain: $SUBDOMAIN"

# 1) Identifiziere Apache-Konfigurationen
echo "🔍 Prüfe auf zugehörige Apache-Konfigurationen..."

# Zähle vorhandene Konfigurationsdateien
APACHE_CONFIG_COUNT=$(find /etc/apache2/sites-available/ -name "$SUBDOMAIN*.conf" | wc -l)
APACHE_ENABLED_COUNT=$(find /etc/apache2/sites-enabled/ -name "$SUBDOMAIN*.conf" | wc -l)

if [[ $APACHE_CONFIG_COUNT -eq 0 ]]; then
  echo "⚠️ Keine Apache-Konfigurationsdateien für $SUBDOMAIN gefunden."
  echo "   Möglicherweise wurde die Site bereits gelöscht oder existiert nicht."
  
  # Wenn kein Zwang, frage nach
  if [[ $FORCE -eq 0 ]]; then
    read -p "Trotzdem fortfahren? [j/N] " proceed
    if [[ ! "$proceed" =~ ^[jJ] ]]; then
      echo "❌ Abbruch."
      exit 1
    fi
  fi
else
  echo "✅ $APACHE_CONFIG_COUNT Apache-Konfigurationsdateien gefunden."
  if [[ $APACHE_ENABLED_COUNT -gt 0 ]]; then
    echo "✅ $APACHE_ENABLED_COUNT aktivierte Apache-Sites gefunden."
  fi
fi

# 2) Entferne Apache vHost-Konfiguration
echo "🗑️ Entferne Apache-Konfiguration..."
remove_vhost "$SUBDOMAIN"

# 3) Bereinige alle temporären Konfigurationen (als zusätzliche Sicherheit)
echo "🧹 Bereinige temporäre Konfigurationen..."
rm -f /etc/apache2/sites-available/$SUBDOMAIN-temp-le-ssl.conf 2>/dev/null || true
rm -f /etc/apache2/sites-available/$SUBDOMAIN-le-ssl.conf 2>/dev/null || true

# Apache neuladen, um sicherzustellen, dass keine ungültigen Konfigurationen verbleiben
systemctl reload apache2 || {
  echo "⚠️ Apache konnte nicht neu geladen werden."
}

# 4) Entferne WordPress-Installation
echo "🗑️ Entferne WordPress-Installation..."
if [[ $KEEP_DB -eq 1 ]]; then
  # Nur WordPress-Dateien löschen, Datenbank behalten
  echo "🗑️ Entferne nur WordPress-Dateien, behalte Datenbank..."
  DOCROOT="${WP_DIR}/${SUBDOMAIN}"
  if [[ -d "$DOCROOT" ]]; then
    sudo rm -rf "$DOCROOT" || {
      log "WARNING" "Fehler beim Löschen des WordPress-Verzeichnisses"
      echo "⚠️ Warnung: Konnte WordPress-Verzeichnis nicht vollständig löschen."
    }
  fi
  log "INFO" "WordPress-Dateien entfernt, Datenbank beibehalten"
else
  # WordPress vollständig entfernen (Dateien und Datenbank)
  echo "🗑️ Entferne WordPress-Installation vollständig..."
  uninstall_wordpress "$SUBDOMAIN" || {
    log "WARNING" "Fehler beim Entfernen der WordPress-Installation"
    echo "⚠️ Warnung: Konnte WordPress nicht vollständig entfernen."
    echo "   Fahre mit dem Löschprozess fort."
  }
fi

# 3) Delete Cloudflare DNS subdomain
if [[ $KEEP_DNS -eq 0 ]]; then
  # Check if environment variables are set
  if ! check_env_vars; then
    log "ERROR" "Cloudflare-Umgebungsvariablen nicht gesetzt"
    echo "❌ Fehler: Cloudflare-Umgebungsvariablen nicht gesetzt."
    echo "DNS-Einträge konnten nicht gelöscht werden."
    echo "Bitte führe aus: source /etc/profile.d/cloudflare.sh"
    exit 1
  fi
  
  echo "🌐 Lösche Cloudflare DNS-Eintrag..."
  delete_subdomain "$SUBDOMAIN" || {
    log "WARNING" "Fehler beim Löschen des DNS-Eintrags"
    echo "⚠️ Warnung: Fehler beim Löschen des DNS-Eintrags."
    echo "   Fahre mit dem Löschprozess fort."
  }
else
  log "INFO" "DNS-Eintrag wird beibehalten (--keep-dns Option)"
  echo "🔒 DNS-Eintrag wird beibehalten (--keep-dns Option)"
fi

# Endgültige Prüfung
ERRORS=0

# Prüfe, ob WordPress-Verzeichnis noch existiert
if [[ -d "${WP_DIR}/${SUBDOMAIN}" ]]; then
  log "WARNING" "WordPress-Verzeichnis existiert noch: ${WP_DIR}/${SUBDOMAIN}"
  echo "⚠️ Warnung: WordPress-Verzeichnis existiert noch: ${WP_DIR}/${SUBDOMAIN}"
  ERRORS=$((ERRORS+1))
fi

# Prüfe, ob Apache-Konfiguration noch existiert
if [[ -f "${APACHE_SITES_DIR}/${SUBDOMAIN}.conf" ]]; then
  log "WARNING" "Apache-Konfiguration existiert noch: ${APACHE_SITES_DIR}/${SUBDOMAIN}.conf"
  echo "⚠️ Warnung: Apache-Konfiguration existiert noch: ${APACHE_SITES_DIR}/${SUBDOMAIN}.conf"
  ERRORS=$((ERRORS+1))
fi

# Prüfe, ob DNS-Eintrag noch existiert (nur wenn --keep-dns nicht gesetzt ist)
if [[ $KEEP_DNS -eq 0 ]]; then
  if dig +short "${SUBDOMAIN}.${DOMAIN}" | grep -q "${SERVER_IP}"; then
    log "WARNING" "DNS-Eintrag existiert noch: ${SUBDOMAIN}.${DOMAIN}"
    echo "⚠️ Warnung: DNS-Eintrag existiert noch: ${SUBDOMAIN}.${DOMAIN}"
    echo "   Dies kann normal sein, da DNS-Änderungen einige Zeit zur Propagation benötigen."
    ERRORS=$((ERRORS+1))
  fi
fi

# Complete
if [[ $ERRORS -eq 0 ]]; then
  echo
  echo "✅ WordPress-Seite für ${SUBDOMAIN}.${DOMAIN} erfolgreich gelöscht!"
  log "SUCCESS" "WordPress-Site für ${SUBDOMAIN}.${DOMAIN} erfolgreich gelöscht"
else
  echo
  echo "⚠️ WordPress-Seite für ${SUBDOMAIN}.${DOMAIN} mit Warnungen gelöscht!"
  echo "   Es wurden $ERRORS Probleme gefunden. Siehe Warnungen oben."
  log "WARNING" "WordPress-Site für ${SUBDOMAIN}.${DOMAIN} mit $ERRORS Warnungen gelöscht"
fi

exit 0