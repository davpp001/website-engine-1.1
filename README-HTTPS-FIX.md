# WordPress HTTPS Fix

This repository contains fixes for the issue where WordPress sites show the Apache default page instead of WordPress content when accessed over HTTPS.

## Problem Description

When visiting WordPress sites over HTTPS, the Apache default page is shown instead of the WordPress content. This happens because:

1. The default SSL configuration (`000-default-ssl.conf`) has a wildcard `ServerAlias *.s-neue.website` that captures all HTTPS requests to subdomains
2. WordPress sites are only configured for HTTP (port 80), not for HTTPS (port 443)
3. The default SSL configuration intercepts all HTTPS requests before the WordPress site-specific configurations can handle them

## Solution

The fix consists of multiple changes:

1. **Removing the Wildcard ServerAlias**: Modify the default SSL configuration to remove the wildcard ServerAlias that captures all subdomain requests
2. **Adding HTTPS VirtualHosts for WordPress**: Ensure all WordPress sites have proper HTTPS VirtualHost configurations with the correct SSL certificate paths
3. **Updating the Apache Module**: Modify the `apache.sh` module to ensure all future sites are properly configured for both HTTP and HTTPS

## Fix Scripts

### 1. fix-wordpress-ssl.sh

This is a comprehensive fix script that:

- Fixes the default SSL configuration by removing the wildcard ServerAlias
- Checks all WordPress sites and ensures they have proper HTTPS configurations
- Validates the Apache configuration and restarts Apache to apply the changes

Run it with:

```bash
sudo ./fix-wordpress-ssl.sh
```

### 2. Preventive Measures

The code in `bin/setup-server.sh` has been updated to prevent this issue from occurring in future server setups by removing the wildcard ServerAlias from the default SSL configuration template.

The `modules/apache.sh` script has been updated to ensure all future WordPress sites get proper HTTP and HTTPS configurations even if SSL certificate files are not immediately available.

## Manual Fix Steps

If you need to manually fix this issue:

1. Disable the default SSL configuration:

```bash
sudo a2dissite 000-default-ssl
```

2. For each WordPress site, ensure it has an HTTPS VirtualHost section in its configuration:

```bash
sudo nano /etc/apache2/sites-available/your-site.conf
```

3. Add an HTTPS VirtualHost section if missing:

```apache
<VirtualHost *:443>
  ServerName your-domain.com
  DocumentRoot /var/www/your-site
  
  # SSL configuration
  SSLEngine on
  SSLCertificateFile /etc/letsencrypt/live/s-neue.website/fullchain.pem
  SSLCertificateKeyFile /etc/letsencrypt/live/s-neue.website/privkey.pem
  
  # Other configuration directives...
</VirtualHost>
```

4. Restart Apache:

```bash
sudo systemctl restart apache2
```

## Support

For additional support, please contact the server administrator.
