# Änderungsprotokoll

## Version 1.1.1 - Mai 2025

### Neu: Server-Reset und Wartungsfunktionen

#### Server-Reset im Setup
- Implementierung von vier Reset-Optionen im `setup-server.sh`:
  - Kein Reset
  - Minimaler Reset (nur Apache-Konfigurationen)
  - Standard-Reset (Apache-Konfigurationen und SSL-Zertifikate)
  - Vollständiger Reset (alle Webdaten, Datenbanken und Zertifikate)
- Erkennung und Bereinigung verwaister Apache-Konfigurationen
- Verbesserter Schutz vor unbeabsichtigtem Datenverlust

#### Neues Wartungsskript
- Einführung des `maintenance.sh` Skripts für regelmäßige Serverüberprüfung
- Automatische Erkennung und Bereinigung von Problemen:
  - Verwaiste Apache-Konfigurationen
  - Temporäre Let's Encrypt-Dateien
  - Inkonsistente WordPress-Installationen
- Überprüfung von Zertifikaten auf baldigen Ablauf
- Check-Only-Modus für Überprüfung ohne Änderungen

#### Verbesserte Website-Verwaltung
- Verbesserte Fehlerbehandlung bei `create-site.sh`
- Gründlichere Bereinigung bei `delete-site.sh`
- Bessere Erkennung und Vermeidung von temporären Let's Encrypt-Dateien
- Robustere Apache-Konfigurationsverwaltung

#### Dokumentation
- Neue umfassende Dokumentation unter `docs/maintenance.md`
- Aktualisierte README-Datei mit Information zu neuen Funktionen
- Empfehlungen für regelmäßige Wartung

### Fehlerbehebungen
- Behoben: Verwaiste Apache-Konfigurationen (kunde88 und kunde9)
- Behoben: Potenzielle Probleme bei der SSL-Zertifikatserstellung
- Behoben: Inkonsistenzen bei der Cloudflare-DNS-Verwaltung
- Verbesserte Fehlerbehandlung und Logging

### Änderungen für Administratoren
- Neue Befehle: `maintenance` zur Serverüberprüfung
- Empfohlene Konfiguration für automatische monatliche Wartung
- Verbesserter Setup-Prozess mit Bereinigungsoptionen

## Version 1.1.0 - Initial Release
- Grundfunktionalität für WordPress-Website-Verwaltung
- Cloudflare DNS-Integration
- SSL-Zertifikatsverwaltung mit Let's Encrypt
- Backup-System
