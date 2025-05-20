# Website Engine Optimizations and Bugfixes

This document compiles the fixes and optimizations for the Website Engine system.

## Latest Fix: SSL Certificate Issues (20. Mai 2025)

This update addresses the critical issue where the `create-site` script fails with the error "SSL-Zertifikat '/etc/letsencrypt/live/s-neue.website/fullchain.pem' not found".

### Key Fixes

1. **SSL Certificate Recovery**: Added a new script (`fix-ssl-certificate.sh`) to automatically generate wildcard SSL certificates after a server reset.

2. **MySQL Database Cleanup**: Fixed an issue in `setup-server.sh` that caused the script to fail during MySQL database cleanup.

3. **Fixed Setup Script Syntax**: Corrected syntax errors in the `setup-fix.sh` script's sed commands.

4. **Improved Error Handling**: Enhanced error handling and recovery throughout the setup process.

## Previous Fix: Apache Configuration Issues

This update addressed the critical issue where new WordPress sites were showing the Apache default page instead of WordPress content.

### Key Fixes

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

## SSL Certificate Fix Solution

To fix the SSL certificate issue after a server reset, use the following steps:

```bash
# 1. Run the SSL fix script to generate a wildcard certificate
sudo /opt/website-engine-1.1/bin/fix-ssl-certificate.sh

# 2. Verify that the certificates were created correctly
sudo ls -la /etc/letsencrypt/live/

# 3. If you still encounter issues, use the complete setup fix script
sudo /opt/website-engine-1.1/bin/setup-fix.sh
```

The `fix-ssl-certificate.sh` script will attempt to create a wildcard certificate for your domain using certbot with the Apache plugin.

## Apache Configuration Fix Solution

To fix Apache configuration issues with virtual hosts, use these steps:

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

## Installation Directories

This installation has two directories:
- `/opt/website-engine` (original)
- `/opt/website-engine-1.1` (newer version)

The commands in `/usr/local/bin` (like `create-site`) are symlinked to the correct script versions. If you want to update scripts in both locations, use:

```bash
# Copy updated scripts to both locations
sudo cp /opt/website-engine-1.1/bin/fix-ssl-certificate.sh /opt/website-engine/bin/
sudo chmod +x /opt/website-engine*/bin/*.sh
```
