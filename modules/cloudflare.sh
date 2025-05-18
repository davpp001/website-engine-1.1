#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# CLOUDFLARE DNS-MANAGEMENT-MODUL
# ====================================================================

# Import config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Maximalzahl Versuche für DNS-Operation
MAX_RETRIES=3
# Wartezeit zwischen Versuchen in Sekunden
RETRY_WAIT=5

# DNS-Einträge für eine Subdomain abrufen
# Usage: get_dns_records <subdomain-name>
function get_dns_records() {
  local SUB="$1"
  local FQDN="${SUB}.${ZONE}"
  
  log "INFO" "Suche DNS-Einträge für ${FQDN}"
  
  # Mit Wiederholungsversuchen
  local retry=0
  local success=0
  local result=""
  
  while [[ $retry -lt $MAX_RETRIES && $success -eq 0 ]]; do
    result=$(curl -s -X GET \
      "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$FQDN" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" 2>/dev/null)
    
    if [[ -n "$result" ]] && jq -e '.success == true' <<< "$result" >/dev/null; then
      success=1
      log "INFO" "DNS-Einträge für ${FQDN} erfolgreich abgerufen"
    else
      retry=$((retry+1))
      log "WARNING" "Fehler beim Abrufen der DNS-Einträge für ${FQDN} (Versuch $retry von $MAX_RETRIES)"
      sleep $RETRY_WAIT
    fi
  done
  
  if [[ $success -eq 0 ]]; then
    log "ERROR" "Konnte DNS-Einträge für ${FQDN} nicht abrufen"
    return 1
  fi
  
  echo "$result"
  return 0
}

# Subdomain in Cloudflare erstellen
# Usage: create_subdomain <subdomain-name>
function create_subdomain() {
  check_env_vars || return 1
  
  local BASE="$1"
  local IP="$SERVER_IP"
  
  log "INFO" "Erstelle Subdomain ${BASE}.${ZONE} mit IP $IP"
  
  local SUB="$BASE"
  local SUF=1
  local MAX_SUFFIX=10
  
  while [[ $SUF -le $MAX_SUFFIX ]]; do
    local FQDN="${SUB}.${ZONE}"
    log "INFO" "Prüfe, ob Subdomain ${FQDN} bereits existiert"
    
    local records=$(get_dns_records "$SUB") || {
      log "ERROR" "Konnte DNS-Einträge nicht abrufen"
      return 1
    }
    
    local cnt=$(jq -r '.result | length' <<< "$records")

    if [[ "$cnt" -eq 0 ]]; then
      log "INFO" "Subdomain ${FQDN} existiert nicht, erstelle sie"
      
      # Mit Wiederholungsversuchen
      local retry=0
      local success=0
      local create_result=""
      
      while [[ $retry -lt $MAX_RETRIES && $success -eq 0 ]]; do
        create_result=$(curl -s -X POST \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" \
          --data '{
            "type":"A",
            "name":"'"$SUB"'",
            "content":"'"$IP"'",
            "ttl":'"$TTL"',
            "proxied":false
          }' 2>/dev/null)
        
        if [[ -n "$create_result" ]] && jq -e '.success == true' <<< "$create_result" >/dev/null; then
          success=1
          log "INFO" "Subdomain ${FQDN} erfolgreich erstellt"
        else
          retry=$((retry+1))
          log "WARNING" "Fehler beim Erstellen der Subdomain ${FQDN} (Versuch $retry von $MAX_RETRIES)"
          if [[ -n "$create_result" ]]; then
            local error_msg=$(jq -r '.errors[0].message // "Unbekannter Fehler"' <<< "$create_result")
            log "WARNING" "Fehlermeldung: $error_msg"
          fi
          sleep $RETRY_WAIT
        fi
      done
      
      if [[ $success -eq 0 ]]; then
        log "ERROR" "Konnte Subdomain ${FQDN} nicht erstellen"
        return 1
      fi
      
      log "SUCCESS" "Subdomain ${FQDN} angelegt und zeigt auf $IP"
      echo "$SUB"
      return 0
    fi

    log "INFO" "Subdomain ${FQDN} existiert bereits, versuche nächste Variante"
    SUF=$((SUF+1))
    SUB="${BASE}${SUF}"
  done
  
  log "ERROR" "Konnte keine freie Subdomain für ${BASE} finden nach $MAX_SUFFIX Versuchen"
  return 1
}

# Subdomain in Cloudflare löschen
# Usage: delete_subdomain <subdomain-name>
function delete_subdomain() {
  check_env_vars || return 1
  
  local SUB="$1"
  local FQDN="${SUB}.${ZONE}"
  
  log "INFO" "Lösche DNS-Einträge für ${FQDN}"
  
  local records=$(get_dns_records "$SUB") || {
    log "ERROR" "Konnte DNS-Einträge nicht abrufen"
    return 1
  }
  
  local IDS=$(jq -r '.result[]?.id' <<< "$records")
  
  if [[ -z "$IDS" ]]; then
    log "WARNING" "Keine DNS-Einträge für ${FQDN} gefunden"
    return 0
  fi
  
  local success=1
  
  for id in $IDS; do
    log "INFO" "Lösche DNS-Eintrag mit ID ${id}"
    
    # Mit Wiederholungsversuchen
    local retry=0
    local delete_success=0
    
    while [[ $retry -lt $MAX_RETRIES && $delete_success -eq 0 ]]; do
      local delete_result=$(curl -s -X DELETE \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${id}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" 2>/dev/null)
      
      if [[ -n "$delete_result" ]] && jq -e '.success == true' <<< "$delete_result" >/dev/null; then
        delete_success=1
        log "INFO" "DNS-Eintrag ${id} für ${FQDN} erfolgreich gelöscht"
      else
        retry=$((retry+1))
        log "WARNING" "Fehler beim Löschen des DNS-Eintrags ${id} (Versuch $retry von $MAX_RETRIES)"
        if [[ -n "$delete_result" ]]; then
          local error_msg=$(jq -r '.errors[0].message // "Unbekannter Fehler"' <<< "$delete_result")
          log "WARNING" "Fehlermeldung: $error_msg"
        fi
        sleep $RETRY_WAIT
      fi
    done
    
    if [[ $delete_success -eq 0 ]]; then
      log "ERROR" "Konnte DNS-Eintrag ${id} für ${FQDN} nicht löschen"
      success=0
    fi
  done
  
  if [[ $success -eq 1 ]]; then
    log "SUCCESS" "Alle DNS-Einträge für ${FQDN} erfolgreich gelöscht"
    return 0
  else
    log "ERROR" "Nicht alle DNS-Einträge für ${FQDN} konnten gelöscht werden"
    return 1
  fi
}

# Warten auf DNS-Propagation
# Usage: wait_for_dns <subdomain-name> [max-wait-time-in-seconds]
function wait_for_dns() {
  local SUB="$1"
  local FQDN="${SUB}.${ZONE}"
  local MAX_WAIT=${2:-60}  # Standardwartezeit: 60 Sekunden
  local SLEEP_INTERVAL=5   # Prüfe alle 5 Sekunden
  
  log "INFO" "Warte auf DNS-Propagation für ${FQDN} (max ${MAX_WAIT}s)"
  
  local elapsed=0
  local propagated=0
  
  echo -n "⏳ Warte auf DNS-Aktivierung von ${FQDN} "
  
  # Zuerst mit der Cloudflare-API prüfen, ob der Eintrag existiert
  if [[ -n "${CF_API_TOKEN:-}" && -n "${ZONE_ID:-}" ]]; then
    # Cloudflare API direkt abfragen
    local cf_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" | jq -r --arg name "${FQDN}" '.result[] | select(.name==$name and .type=="A")')
    
    if [[ -n "$cf_response" ]]; then
      log "INFO" "DNS-Eintrag in Cloudflare gefunden, setze DNS-Prüfung fort"
    else
      log "WARNING" "DNS-Eintrag in Cloudflare nicht gefunden, fahre trotzdem fort"
    fi
  fi
  
  while [[ $elapsed -lt $MAX_WAIT && $propagated -eq 0 ]]; do
    # Führe verschiedene Prüfungen durch, um DNS-Propagation zu bestätigen
    
    # 1. Prüfe mit dig gegen Cloudflare-DNS direkt
    if dig @1.1.1.1 +short "${FQDN}" | grep -q "$SERVER_IP"; then
      log "SUCCESS" "DNS-Eintrag über Cloudflare-DNS (1.1.1.1) bestätigt"
      propagated=1
      break
    fi
    
    # 2. Prüfe mit dig (allgemein)
    if dig +short "${FQDN}" | grep -q "$SERVER_IP"; then
      propagated=1
      break
    fi
    
    # 3. Prüfe mit nslookup
    if command -v nslookup &>/dev/null; then
      if nslookup "${FQDN}" 2>/dev/null | grep -q "$SERVER_IP"; then
        propagated=1
        break
      fi
    fi
    
    # 4. Prüfe mit host
    if command -v host &>/dev/null; then
      if host "${FQDN}" 2>/dev/null | grep -q "$SERVER_IP"; then
        propagated=1
        break
      fi
    fi
    
    # Zeige Fortschritt an
    echo -n "."
    sleep $SLEEP_INTERVAL
    elapsed=$((elapsed + SLEEP_INTERVAL))
  done
  
  echo
  
  if [[ $propagated -eq 1 ]]; then
    log "SUCCESS" "DNS-A-Record für ${FQDN} ist aktiv (nach ${elapsed}s)"
    echo "✅ DNS-A-Record aktiv."
    return 0
  else
    log "ERROR" "DNS-Timeout: A-Record für ${FQDN} konnte nicht innerhalb von ${MAX_WAIT}s verifiziert werden"
    echo "⚠️ DNS-Timeout: A-Record für ${FQDN} nicht gefunden."
    return 1
  fi
}