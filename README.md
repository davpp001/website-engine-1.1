# Vereinfachte Website Engine

Eine schlanke Anwendung zum Erstellen und Löschen von WordPress-Subdomains mit SSL-Zertifikaten.

## Funktionen

- Erstellen einer neuen Subdomain mit WordPress-Installation
- Löschen einer bestehenden Subdomain mit WordPress-Installation
- Server-Setup mit allen notwendigen Komponenten
- Backup-System (MySQL, Restic S3)

## Installation

1. Klone dieses Repository:
   ```
   git clone https://github.com/username/website-engine-2.0.git
   cd website-engine-2.0/simplified
   ```

2. Führe das Server-Setup aus:
   ```
   sudo ./bin/setup-server.sh
   ```

3. Konfiguriere deine Cloudflare-Anmeldedaten:
   ```
   sudo nano /etc/profile.d/cloudflare.sh
   source /etc/profile.d/cloudflare.sh
   ```

4. Prüfe die WordPress-Admin-Zugangsdaten:
   ```
   sudo cat /etc/website-engine/credentials.env
   ```

5. Konfiguriere das Backup-System (optional):
   ```
   sudo nano /etc/website-engine/backup/restic.env
   ```

## Verwendung

### Erstellen einer neuen WordPress-Seite

```bash
create-site kundename
```

Dies:
- Erstellt einen A-Record bei Cloudflare (z.B. kundename.s-neue.website)
- Richtet einen Apache vHost mit SSL ein (mit Let's Encrypt Zertifikat)
- Installiert und konfiguriert WordPress mit eindeutigen Datenbank-Anmeldedaten
- Speichert die Datenbank-Informationen für Backups

### Testmodus (ohne DNS)

```bash
create-site testkunde --test
```

### Löschen einer WordPress-Seite

```bash
delete-site kundename
```

Dies:
- Entfernt die Apache-Konfiguration
- Löscht die WordPress-Installation und Datenbank
- Entfernt den DNS-Eintrag

### DNS-Eintrag beibehalten

```bash
delete-site kundename --keep-dns
```

### SSL-Zertifikat separat einrichten

Falls notwendig, kann ein SSL-Zertifikat auch separat mit dem direct-ssl.sh Skript eingerichtet werden:

```bash
direct-ssl subdomain.domain.tld
```

Dies wird normalerweise automatisch durch create-site erledigt. Es kann aber nützlich sein, wenn:
- Zertifikat nicht beim ersten Mal erstellt wurde
- Ein Zertifikat erneuert werden muss
- Sie ein Zertifikat für eine bestehende Domain einrichten wollen

## Struktur

```
/opt/website-engine/
├── bin/
│   ├── create-site.sh      # Erstellt eine neue Subdomain mit WordPress
│   ├── delete-site.sh      # Löscht eine bestehende Subdomain mit WordPress
│   ├── direct-ssl.sh       # Richtet SSL direkt für eine Domain ein
│   └── setup-server.sh     # Servereinrichtung mit Voraussetzungen
├── modules/
│   ├── config.sh           # Zentrale Konfigurationsdatei
│   ├── cloudflare.sh       # Cloudflare DNS-Funktionen
│   ├── wordpress.sh        # WordPress-Installations-Funktionen
│   └── apache.sh           # Apache-Konfigurations-Funktionen
└── backup/
    ├── mysql-backup.sh     # MySQL-Backup-Skript
    └── restic-backup.sh    # Restic-Backup-Skript
```

## Konfiguration

Die Anwendung verwendet folgende Konfigurationsdateien:

- `/opt/website-engine/modules/config.sh`: Zentrale Konfigurationsdatei
- `/etc/profile.d/cloudflare.sh`: Cloudflare API-Tokens
- `/etc/website-engine/credentials.env`: WordPress-Admin-Zugangsdaten
- `/etc/website-engine/backup/restic.env`: Restic S3-Backup-Konfiguration
- `/etc/website-engine/sites/<subdomain>/db-info.env`: Datenbank-Informationen pro Site

## Backup-System

Das erweiterte Backup-System bietet:

1. **MySQL-Datenbankbackups**
   - Tägliche Backups um 03:00 Uhr
   - 14 Tage Aufbewahrung
   - Speicherort: `/var/backups/mysql/`

2. **IONOS Volume-Snapshots** 
   - Tägliche Block-Level-Snapshots um 01:00 Uhr
   - Erstellung über IONOS Cloud API
   - Vollständige Point-in-Time-Recovery-Möglichkeit

3. **Restic-Datei-Backups**
   - Tägliche Sicherung um 02:30 Uhr zu S3-kompatiblem Speicher
   - Sichert /etc, /var/www, /opt/website-engine, /etc/website-engine
   - 14 tägliche, 4 wöchentliche und 3 monatliche Aufbewahrungspunkte
   - Verschlüsselte Speicherung für maximale Sicherheit

4. **Manuelle Backup-Befehle**
   - `website-backup`: Manuelles Backup aller oder einzelner Komponenten
   - `website-restore`: Wiederherstellung von Backups
   - `website-secrets`: Verschlüsselung sensibler Konfigurationsdateien

## Sicherheit

- Jede WordPress-Installation erhält einen eigenen Datenbankbenutzer
- Datenbank-Passwörter werden zufällig generiert
- Anmeldedaten werden in sicheren Dateien mit eingeschränkten Berechtigungen gespeichert
- Automatische SSL-Verschlüsselung für alle Websites mit Let's Encrypt (certbot --apache)
- Restic-Backups sind verschlüsselt