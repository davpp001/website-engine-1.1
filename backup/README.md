# Backup-System der Website Engine

Dieses Dokument beschreibt das integrierte Backup-System der Website Engine und wie es verwendet wird.

## Übersicht

Das Backup-System besteht aus drei Hauptkomponenten:

1. **MySQL-Datenbankbackups**
   - Tägliche Sicherung aller Datenbanken
   - 14 Tage Aufbewahrung
   - Speicherort: `/var/backups/mysql/`

2. **IONOS Volume-Snapshots**
   - Tägliche Block-Level-Snapshots des gesamten Servers
   - Erstellung über IONOS Cloud API
   - Unbegrenzte Aufbewahrung im IONOS Cloud Panel

3. **Restic Datei-Backups**
   - Tägliche inkrementelle Sicherung wichtiger Verzeichnisse
   - Verschlüsselte Speicherung in S3-kompatiblem Storage
   - 14 tägliche, 4 wöchentliche Aufbewahrungspunkte

## Konfiguration

Alle Backup-Komponenten werden während der Servereinrichtung automatisch konfiguriert. Folgende Konfigurationsdateien müssen angepasst werden:

### IONOS-Snapshots

Datei: `/etc/website-engine/backup/ionos.env`

```
IONOS_TOKEN="dein-ionos-api-token"
IONOS_SERVER_ID="deine-server-id"
IONOS_VOLUME_ID="deine-volume-id"
IONOS_DATACENTER_ID="deine-datacenter-id"  # optional
```

### S3 und Restic-Dateibackups

Datei: `/etc/website-engine/backup/restic.env`

```
# S3-Zugangsdaten
export AWS_ACCESS_KEY_ID="dein-s3-access-key"
export AWS_SECRET_ACCESS_KEY="dein-s3-secret-key"

# S3-Konfiguration
export S3_ENDPOINT="s3.eu-central-3.ionoscloud.com"
export S3_BUCKET="website-backups"
export S3_PATH_RESTIC="restic"
export S3_PATH_MYSQL="mysql"

# Restic-Konfiguration - WICHTIG: Die korrekte Syntax für S3 ist:
# s3:s3.example.com/bucket-name/path (OHNE https://)
export RESTIC_REPOSITORY="s3:s3.eu-central-3.ionoscloud.com/website-backups/restic"
export RESTIC_PASSWORD="ein-sicheres-passwort"
```

## Sicherheit

Sensible Konfigurationsdateien sollten verschlüsselt werden, wenn sie nicht verwendet werden:

```bash
website-secrets encrypt
```

Dies verschlüsselt alle Konfigurationsdateien mit einem Passwort. Zum Entschlüsseln:

```bash
website-secrets decrypt
```

## Cron-Jobs

Das System richtet automatisch folgende Cron-Jobs ein:

| Zeit  | Job                      | Beschreibung              |
|-------|--------------------------|---------------------------|
| 01:00 | IONOS-Snapshot           | Block-Level-Snapshots     |
| 02:30 | Restic-Backup            | Datei-Level-Backups       |
| 03:00 | MySQL-Backup             | Datenbank-Dumps           |

## Manuelle Backup-Durchführung

Sie können jederzeit manuell ein Backup durchführen:

```bash
# Alle Backup-Typen ausführen
./backup-all.sh

# Nur bestimmte Backup-Typen
./backup-all.sh --mysql
./backup-all.sh --ionos
./backup-all.sh --restic

# S3-Speicherung erzwingen oder verhindern
./backup-all.sh --s3     # Bevorzuge S3-Storage (Standard)
./backup-all.sh --local  # Verwende nur lokale Speicherung

# Nur eine bestimmte Site sichern
./backup-all.sh --only-site=kunde1 --mysql --restic
```

## Backup-Wiederherstellung

### MySQL-Wiederherstellung

1. Listen Sie verfügbare Backups auf:
   ```bash
   ./restore.sh --list-mysql
   ```

2. Stellen Sie ein Backup wieder her:
   ```bash
   ./restore.sh --mysql /var/backups/mysql/backup-2023-05-15.sql.gz
   ```

3. Stellen Sie nur eine Site wieder her:
   ```bash
   ./restore.sh --mysql /var/backups/mysql/backup-2023-05-15.sql.gz --only-site=kunde1
   ```

### Restic-Wiederherstellung

1. Listen Sie verfügbare Snapshots auf:
   ```bash
   ./restore.sh --list-restic
   ```

2. Stellen Sie einen Snapshot wieder her:
   ```bash
   ./restore.sh --restic latest --target /tmp/restore
   ```

3. Stellen Sie nur eine Site wieder her:
   ```bash
   ./restore.sh --restic latest --only-site=kunde1
   ```

## IONOS-Snapshots

IONOS-Snapshots werden über das IONOS Cloud Panel verwaltet. Sie können Snapshots dort einsehen und wiederherstellen.

Ein manueller Snapshot kann erstellt werden mit:

```bash
./ionos-snapshot.sh
```

## Best Practices

1. **Testen Sie regelmäßig die Wiederherstellung**: Führen Sie quartalsweise Tests durch, um sicherzustellen, dass die Backups funktionieren.

2. **Verschlüsseln Sie Konfigurationsdateien**: Verwenden Sie `website-secrets encrypt`, um sensible Daten zu schützen.

3. **Überwachen Sie Backup-Logs**: Überprüfen Sie regelmäßig `/var/log/website-engine.log` auf Backup-Fehler.

4. **Off-Site-Backup**: Speichern Sie Restic-Backups in einem geografisch getrennten S3-Bucket.

5. **Dokumentieren Sie Wiederherstellungsprozeduren**: Bewahren Sie Kopien dieser Dokumentation außerhalb des Servers auf.

## Fehlerbehebung

### MySQL-Backups

- **Problem**: MySQL-Backups schlagen fehl
  - **Lösung**: Überprüfen Sie MySQL-Benutzerberechtigungen und freien Speicherplatz

### IONOS-Snapshots

- **Problem**: API-Fehler
  - **Lösung**: Überprüfen Sie das API-Token und die Server/Volume-IDs in der Konfigurationsdatei

### Restic-Backups

- **Problem**: Repository-Zugriffsfehler
  - **Lösung**: Überprüfen Sie S3-Zugangsdaten und Netzwerkverbindung

- **Problem**: `Fatal: invalid backend` Fehler
  - **Lösung**: Korrigieren Sie die Repository-URL. Entfernen Sie `https://` aus der URL:
    ```
    # Falsch:
    export RESTIC_REPOSITORY="s3:https://s3.example.com/bucket/path"
    # Richtig:
    export RESTIC_REPOSITORY="s3:s3.example.com/bucket/path"
    ```

- **Problem**: Repository ist gesperrt
  - **Lösung**: Führen Sie aus: `restic unlock`