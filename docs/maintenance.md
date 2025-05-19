# Server-Wartung und Reset

Diese Dokumentation beschreibt, wie die Website Engine korrekt eingerichtet, zurückgesetzt und gewartet werden kann, um Probleme wie verwaiste Apache-Konfigurationen zu vermeiden.

## Servereinrichtung mit Clean-Start-Option

Die `setup-server.sh` enthält jetzt eine Reset-Funktion, die vor der Installation ausgeführt werden kann. Es gibt folgende Optionen:

1. **Kein Reset** - Keine Bereinigung vor der Installation
2. **Minimaler Reset** - Bereinigt nur Apache-Konfigurationen (empfohlen)
3. **Standard-Reset** - Bereinigt Apache-Konfigurationen und SSL-Zertifikate für Subdomains
4. **Vollständiger Reset** - Löscht alle Webdaten, Datenbanken und Zertifikate

Der minimale Reset ist für die meisten Installationen ausreichend und sorgt dafür, dass keine verwaisten Apache-Konfigurationen zurückbleiben.

## Regelmäßige Wartung

Das neue Wartungsskript `maintenance.sh` kann regelmäßig ausgeführt werden, um folgende Aufgaben durchzuführen:

1. **Identifizierung verwaister Apache-Konfigurationen** - Findet Konfigurationen, die auf nicht existierende Verzeichnisse verweisen
2. **Bereinigung temporärer Let's Encrypt-Dateien** - Entfernt nicht mehr benötigte `-temp-le-ssl.conf`-Dateien
3. **Überprüfung von WordPress-Installationen** - Prüft auf Konsistenz zwischen WordPress-Verzeichnissen und Apache-Konfigurationen

### Manuelle Ausführung

```bash
sudo /opt/website-engine-1.1/bin/maintenance.sh
```

Nur Überprüfung ohne Änderungen:
```bash
sudo /opt/website-engine-1.1/bin/maintenance.sh --check-only
```

### Automatische Ausführung

Für eine monatliche automatische Wartung:

```bash
sudo crontab -e
```

Fügen Sie folgende Zeile hinzu:
```
0 4 1 * * /opt/website-engine-1.1/bin/maintenance.sh > /var/log/website-engine/maintenance.log 2>&1
```

## Verbesserte Website-Erstellung und -Löschung

Die Skripte `create-site.sh` und `delete-site.sh` wurden verbessert, um eine bessere Fehlerbehandlung und Bereinigung zu gewährleisten:

1. **Verbesserte Vorbedingungen** - Prüft auf und bereinigt vorhandene Konfigurationen vor der Erstellung einer neuen Site
2. **Erweiterte Fehlerbehebung** - Bessere Behandlung von Fehlersituationen bei der SSL-Zertifikatserstellung
3. **Gründliche Bereinigung** - Entfernt alle zugehörigen Apache-Konfigurationen beim Löschen einer Site

## Best Practices

1. **Regelmäßige Wartung** - Führen Sie mindestens einmal pro Monat das Wartungsskript aus
2. **Nach Fehlern bereinigen** - Wenn Probleme bei der Erstellung einer Site auftreten, nutzen Sie `delete-site.sh`, um vollständig aufzuräumen
3. **Immer die Standardbefehle verwenden** - Nutzen Sie `create-site` und `delete-site` anstatt manuelle Änderungen vorzunehmen

## Fehlerbehebung

### Verwaiste Apache-Konfigurationen

Wenn Warnungen über nicht existierende DocumentRoot-Verzeichnisse erscheinen:

```bash
sudo /opt/website-engine-1.1/bin/maintenance.sh
```

### Apache startet nicht

Wenn Apache nicht startet, könnte dies an fehlerhaften Konfigurationen liegen:

```bash
sudo apachectl configtest
```

Bereinigen Sie fehlerhafte Konfigurationen:

```bash
sudo find /etc/apache2/sites-available/ -name "*-temp-le-ssl.conf" -delete
sudo systemctl restart apache2
```

## Wildcard SSL-Zertifikate

Die Website Engine verwendet Wildcard-SSL-Zertifikate über die Cloudflare DNS-01-Challenge. Diese funktionieren korrekt, sofern die Cloudflare-API-Zugangsdaten richtig konfiguriert sind.

Die Zertifikate werden automatisch für `*.ihre-domain.de` erstellt und alle neuen Sites nutzen dieses Zertifikat.
