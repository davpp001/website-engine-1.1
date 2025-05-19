# Website Engine Optimizations and Bugfixes

This update fixes the critical issue where new WordPress sites were showing the Apache default page instead of WordPress content, due to Apache VirtualHost configurations not being properly enabled.

## Key Fixes

1. **Fixed Apache symlink creation**: Ensured that when Apache VirtualHost configurations are created in `/etc/apache2/sites-available/`, they are properly enabled by creating necessary symlinks in `/etc/apache2/sites-enabled/`.

2. **Added robust failover mechanisms**: If `a2ensite` fails to create the symlink, the script now attempts to create it manually.

3. **Added configuration status display**: Added debugging output to show the status of Apache configurations for easier troubleshooting.

4. **Enhanced error handling**: Made the site creation process more resilient to common Apache configuration issues.

## How to Test

Create a new website using the optimized script:

```bash
./create-site.sh testsite
```

The site should now be properly configured with Apache and display the WordPress installation rather than Apache's default page.

## Technical Details

Das Problem hatte mehrere Ursachen:

1. Die Apache-Konfigurationsdateien wurden zwar in `sites-available/` erstellt und mittels Symlink in `sites-enabled/` aktiviert, aber die Apache-Standardseite (`000-default.conf`) blieb aktiv.

2. Die VirtualHost-Direktiven für Port 80 enthielten keinen `DocumentRoot`, was dazu führte, dass Apache in manchen Fällen nicht wusste, welches Verzeichnis für die Anfrage verwendet werden sollte.

3. Mehrere VirtualHost-Direktiven konkurrierten miteinander, ohne dass die korrekte Priorität eingehalten wurde.

## Finale Lösung

Um das Problem zu lösen, führen Sie folgende Schritte auf dem Server aus:

```bash
# 1. Deaktivieren Sie die Apache-Standardseite
sudo a2dissite 000-default
sudo systemctl reload apache2

# 2. Starten Sie Apache neu (wichtig!)
sudo systemctl restart apache2

# 3. Führen Sie das Fix-Skript aus, wenn die Sites immer noch Probleme haben
sudo /opt/website-engine-1.1/bin/fix-apache.sh
```

Das `fix-apache.sh`-Skript überprüft und repariert alle VirtualHost-Konfigurationen, stellt sicher, dass `DocumentRoot` in allen HTTP-VirtualHosts definiert ist, und deaktiviert die Default-Site, die sonst Vorrang vor Ihren WordPress-Sites hätte.
