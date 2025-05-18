#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# SENSITIVE CONFIG-DATEIEN VERSCHLÜSSELN/ENTSCHLÜSSELN
# ====================================================================

# Import config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$(dirname "$SCRIPT_DIR")/modules"
source "$MODULES_DIR/config.sh"

# Zeige Verwendung an
usage() {
  echo "Verwendung: $0 [encrypt|decrypt] [Dateiname]"
  echo
  echo "Verschlüsselt oder entschlüsselt sensitive Konfigurationsdateien."
  echo
  echo "Befehle:"
  echo "  encrypt [Datei]  Verschlüsselt die angegebene Datei"
  echo "  decrypt [Datei]  Entschlüsselt die angegebene Datei"
  echo
  echo "Beispiele:"
  echo "  $0 encrypt /etc/website-engine/backup/ionos.env"
  echo "  $0 decrypt /etc/website-engine/backup/ionos.env.enc"
  echo
  echo "Hinweis: Wenn keine Datei angegeben wird, werden Standard-Konfigurationsdateien verwendet."
  exit 1
}

# Standardkonfigurationsdateien
DEFAULT_FILES=(
  "/etc/website-engine/credentials.env"
  "/etc/website-engine/backup/restic.env"
  "/etc/website-engine/backup/ionos.env"
  "/etc/profile.d/cloudflare.sh"
)

# Verschlüsselungspasswort (wird interaktiv abgefragt)
ENCRYPTION_PASSWORD=""

# Verschlüssele eine Datei
encrypt_file() {
  local file="$1"
  local encrypted_file="${file}.enc"
  
  if [[ ! -f "$file" ]]; then
    echo "❌ Fehler: Datei nicht gefunden: $file"
    return 1
  fi
  
  # Prüfe, ob OpenSSL verfügbar ist
  if ! command -v openssl &> /dev/null; then
    echo "❌ Fehler: OpenSSL ist nicht installiert."
    return 1
  fi
  
  # Passwort abfragen, wenn nicht gesetzt
  if [[ -z "$ENCRYPTION_PASSWORD" ]]; then
    echo -n "🔒 Bitte Verschlüsselungspasswort eingeben: "
    read -r -s ENCRYPTION_PASSWORD
    echo
    
    echo -n "🔒 Passwort bestätigen: "
    read -r -s PASSWORD_CONFIRM
    echo
    
    if [[ "$ENCRYPTION_PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
      echo "❌ Fehler: Passwörter stimmen nicht überein."
      return 1
    fi
  fi
  
  echo "🔒 Verschlüssele $file nach $encrypted_file..."
  
  # Datei mit OpenSSL verschlüsseln
  if ! openssl enc -aes-256-cbc -salt -pbkdf2 -in "$file" -out "$encrypted_file" -pass pass:"$ENCRYPTION_PASSWORD"; then
    echo "❌ Fehler beim Verschlüsseln der Datei: $file"
    return 1
  fi
  
  echo "✅ Datei erfolgreich verschlüsselt: $encrypted_file"
  
  # Berechtigungen setzen
  chmod 600 "$encrypted_file"
  
  # Sicherheitskopie der Originaldatei erstellen
  cp "$file" "${file}.bak"
  chmod 600 "${file}.bak"
  
  # Nachfragen, ob Originaldatei gelöscht werden soll
  echo -n "❓ Originaldatei $file löschen? (j/n): "
  read -r REPLY
  if [[ "$REPLY" =~ ^[jJyY]$ ]]; then
    rm -f "$file"
    echo "✅ Originaldatei gelöscht. Sicherheitskopie unter ${file}.bak"
  else
    echo "✅ Originaldatei beibehalten. Sicherheitskopie unter ${file}.bak"
  fi
  
  return 0
}

# Entschlüssele eine Datei
decrypt_file() {
  local encrypted_file="$1"
  local decrypted_file="${encrypted_file%.enc}"
  
  if [[ ! -f "$encrypted_file" ]]; then
    echo "❌ Fehler: Verschlüsselte Datei nicht gefunden: $encrypted_file"
    return 1
  fi
  
  # Prüfe, ob die Datei eine .enc-Erweiterung hat
  if [[ "$encrypted_file" != *.enc ]]; then
    echo "⚠️ Warnung: Datei hat keine .enc-Erweiterung. Fortfahren? (j/n): "
    read -r REPLY
    if [[ ! "$REPLY" =~ ^[jJyY]$ ]]; then
      echo "❌ Vorgang abgebrochen."
      return 1
    fi
  fi
  
  # Passwort abfragen, wenn nicht gesetzt
  if [[ -z "$ENCRYPTION_PASSWORD" ]]; then
    echo -n "🔑 Bitte Entschlüsselungspasswort eingeben: "
    read -r -s ENCRYPTION_PASSWORD
    echo
  fi
  
  # Prüfe, ob Zieldatei bereits existiert
  if [[ -f "$decrypted_file" ]]; then
    echo "⚠️ Warnung: Zieldatei existiert bereits: $decrypted_file"
    echo -n "❓ Überschreiben? (j/n): "
    read -r REPLY
    if [[ ! "$REPLY" =~ ^[jJyY]$ ]]; then
      echo "❌ Vorgang abgebrochen."
      return 1
    fi
  fi
  
  echo "🔓 Entschlüssele $encrypted_file nach $decrypted_file..."
  
  # Datei mit OpenSSL entschlüsseln
  if ! openssl enc -aes-256-cbc -d -salt -pbkdf2 -in "$encrypted_file" -out "$decrypted_file" -pass pass:"$ENCRYPTION_PASSWORD"; then
    echo "❌ Fehler beim Entschlüsseln der Datei: $encrypted_file"
    echo "   Falsches Passwort oder beschädigte Datei?"
    return 1
  fi
  
  # Berechtigungen setzen
  chmod 600 "$decrypted_file"
  
  echo "✅ Datei erfolgreich entschlüsselt: $decrypted_file"
  return 0
}

# Verschlüssele alle Standarddateien
encrypt_all() {
  local success=0
  local failures=0
  
  for file in "${DEFAULT_FILES[@]}"; do
    if [[ -f "$file" ]]; then
      echo "🔒 Verschlüssele $file..."
      if encrypt_file "$file"; then
        success=$((success+1))
      else
        failures=$((failures+1))
      fi
    else
      echo "⚠️ Datei nicht gefunden, überspringe: $file"
    fi
  done
  
  echo
  echo "🏁 Verschlüsselung abgeschlossen: $success erfolgreich, $failures fehlgeschlagen"
  
  return $failures
}

# Entschlüssele alle Standarddateien
decrypt_all() {
  local success=0
  local failures=0
  
  for file in "${DEFAULT_FILES[@]}"; do
    local encrypted_file="${file}.enc"
    if [[ -f "$encrypted_file" ]]; then
      echo "🔓 Entschlüssele $encrypted_file..."
      if decrypt_file "$encrypted_file"; then
        success=$((success+1))
      else
        failures=$((failures+1))
      fi
    else
      echo "⚠️ Verschlüsselte Datei nicht gefunden, überspringe: $encrypted_file"
    fi
  done
  
  echo
  echo "🏁 Entschlüsselung abgeschlossen: $success erfolgreich, $failures fehlgeschlagen"
  
  return $failures
}

# Parse Befehle
if [[ $# -lt 1 ]]; then
  usage
fi

case "$1" in
  encrypt)
    if [[ $# -eq 2 ]]; then
      encrypt_file "$2"
    else
      encrypt_all
    fi
    ;;
  decrypt)
    if [[ $# -eq 2 ]]; then
      decrypt_file "$2"
    else
      decrypt_all
    fi
    ;;
  --help)
    usage
    ;;
  *)
    echo "Unbekannter Befehl: $1"
    usage
    ;;
esac

exit $?