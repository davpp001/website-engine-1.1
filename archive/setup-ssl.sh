#!/usr/bin/env bash
set -eo pipefail

# Professional SSL setup script
# This script configures SSL for all WordPress sites using Let's Encrypt

echo "🔒 Setting up SSL certificates for WordPress sites..."

# 1. Check if Certbot is installed
echo "🔍 Checking if Certbot is installed..."
if ! command -v certbot &> /dev/null; then
  echo "📦 Installing Certbot and plugins..."
  apt-get update
  apt-get install -y certbot python3-certbot-apache python3-certbot-dns-cloudflare
fi

# 2. Create directory for Cloudflare credentials
echo "📁 Setting up Cloudflare credentials for DNS validation..."
mkdir -p /etc/letsencrypt/cloudflare
chmod 700 /etc/letsencrypt/cloudflare

# 3. Create Cloudflare credentials file
cat > /etc/letsencrypt/cloudflare/credentials.ini << 'EOF'
# Cloudflare API credentials used by Certbot
dns_cloudflare_api_token = lLrGrv3Q8hmj-Db4ncotnGqbaE0IFX9oKvD8yxQV
EOF
chmod 600 /etc/letsencrypt/cloudflare/credentials.ini

# 4. Create a script to set up SSL for a specific subdomain
echo "📝 Creating script for SSL setup per subdomain..."
cat > /opt/infra-scripts/ssl-setup.sh << 'EOF'
#!/usr/bin/env bash
set -eo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <subdomain>"
  exit 1
fi

SUB="$1"
DOMAIN="s-neue.website"
FQDN="${SUB}.${DOMAIN}"

echo "🔒 Setting up SSL for ${FQDN}..."

# Check if site exists
if [ ! -f "/etc/apache2/sites-available/${SUB}.conf" ]; then
  echo "❌ Site configuration not found for ${SUB}."
  exit 1
fi

# Run Certbot to obtain certificate
echo "🔑 Obtaining SSL certificate..."
certbot --apache \
  --non-interactive \
  --agree-tos \
  --redirect \
  --email admin@online-aesthetik.de \
  -d "${FQDN}"

echo "✅ SSL setup complete for ${FQDN}"
echo "🔗 URL: https://${FQDN}"
EOF
chmod +x /opt/infra-scripts/ssl-setup.sh
ln -sf /opt/infra-scripts/ssl-setup.sh /usr/local/bin/ssl-setup

# 5. Create script for wildcard SSL certificate
echo "📝 Creating script for wildcard SSL certificate..."
cat > /opt/infra-scripts/wildcard-ssl-setup.sh << 'EOF'
#!/usr/bin/env bash
set -eo pipefail

DOMAIN="s-neue.website"

echo "🔒 Setting up wildcard SSL certificate for *.${DOMAIN}..."

# Obtain wildcard certificate using DNS validation
echo "🔑 Obtaining wildcard certificate..."
certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare/credentials.ini \
  --non-interactive \
  --agree-tos \
  --email admin@online-aesthetik.de \
  -d "*.${DOMAIN}" \
  -d "${DOMAIN}"

# Create a template for Apache SSL configuration
echo "📝 Creating Apache SSL template..."
cat > /etc/apache2/sites-available/subdomain-ssl-template.conf << TEMPLATE
<IfModule mod_ssl.c>
  <VirtualHost *:443>
    ServerName SUBDOMAIN.${DOMAIN}
    DocumentRoot /var/www/SUBDOMAIN
    
    <Directory /var/www/SUBDOMAIN>
      Options FollowSymLinks
      AllowOverride All
      Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/error-SUBDOMAIN.log
    CustomLog \${APACHE_LOG_DIR}/access-SUBDOMAIN.log combined
    
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/${DOMAIN}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${DOMAIN}/privkey.pem
    Include /etc/letsencrypt/options-ssl-apache.conf
  </VirtualHost>
</IfModule>
TEMPLATE

echo "✅ Wildcard SSL certificate obtained successfully"
echo "Now you can apply SSL to any subdomain with: ssl-update-all"
EOF
chmod +x /opt/infra-scripts/wildcard-ssl-setup.sh
ln -sf /opt/infra-scripts/wildcard-ssl-setup.sh /usr/local/bin/wildcard-ssl-setup

# 6. Create script to apply wildcard SSL to all sites
echo "📝 Creating script to apply SSL to all sites..."
cat > /opt/infra-scripts/ssl-update-all.sh << 'EOF'
#!/usr/bin/env bash
set -eo pipefail

DOMAIN="s-neue.website"

echo "🔄 Applying SSL to all WordPress sites..."

# Enable required Apache modules
echo "🔌 Enabling Apache SSL modules..."
a2enmod ssl
a2enmod headers

# Get all subdomains with active sites
echo "🔍 Finding all active sites..."
SITES=$(find /etc/apache2/sites-enabled/ -name "*.conf" | grep -v "-le-ssl" | grep -v "000-default" | grep -v "subdomain-ssl-template")

for SITE_CONF in $SITES; do
  # Extract subdomain from filename
  SITE_FILE=$(basename "$SITE_CONF")
  SUB="${SITE_FILE%.conf}"
  
  echo "🔒 Setting up SSL for ${SUB}.${DOMAIN}..."
  
  # Create SSL config from template
  SSL_CONF="/etc/apache2/sites-available/${SUB}-ssl.conf"
  cp /etc/apache2/sites-available/subdomain-ssl-template.conf "$SSL_CONF"
  sed -i "s/SUBDOMAIN/${SUB}/g" "$SSL_CONF"
  
  # Enable the site
  a2ensite "${SUB}-ssl.conf"
  
  # Add redirect from HTTP to HTTPS
  if ! grep -q "RewriteEngine On" "$SITE_CONF"; then
    sed -i '/<VirtualHost \*:80>/a \\n  RewriteEngine On\n  RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]' "$SITE_CONF"
  fi
  
  echo "✅ SSL enabled for ${SUB}.${DOMAIN}"
done

# Reload Apache
echo "🔄 Reloading Apache..."
systemctl reload apache2

echo "✅ SSL applied to all sites successfully"
echo "🔗 All sites now available over HTTPS"
EOF
chmod +x /opt/infra-scripts/ssl-update-all.sh
ln -sf /opt/infra-scripts/ssl-update-all.sh /usr/local/bin/ssl-update-all

# 7. Create a script to automatically apply SSL to new sites
echo "📝 Creating script to integrate SSL into WordPress setup..."
cat > /opt/infra-scripts/integrate-ssl.sh << 'EOF'
#!/usr/bin/env bash
set -eo pipefail

# Add SSL setup to WordPress installation
echo "🔗 Integrating SSL into WordPress setup process..."

# Backup original setup_wp.sh
cp /opt/infra-scripts/wordpress/setup_wp.sh /opt/infra-scripts/wordpress/setup_wp.sh.pre-ssl

# Add SSL setup at the end
cat >> /opt/infra-scripts/wordpress/setup_wp.sh << 'APPEND'

# 4. Set up SSL if wildcard certificate exists
if [ -d "/etc/letsencrypt/live/s-neue.website" ]; then
  echo "🔒 Setting up SSL for ${SUB}..."
  
  # Create SSL config from template
  if [ -f "/etc/apache2/sites-available/subdomain-ssl-template.conf" ]; then
    SSL_CONF="/etc/apache2/sites-available/${SUB}-ssl.conf"
    cp /etc/apache2/sites-available/subdomain-ssl-template.conf "$SSL_CONF"
    sed -i "s/SUBDOMAIN/${SUB}/g" "$SSL_CONF"
    
    # Enable the site
    a2ensite "${SUB}-ssl.conf"
    
    # Add redirect from HTTP to HTTPS
    SITE_CONF="/etc/apache2/sites-available/${SUB}.conf"
    if ! grep -q "RewriteEngine On" "$SITE_CONF"; then
      sed -i '/<VirtualHost \*:80>/a \\n  RewriteEngine On\n  RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]' "$SITE_CONF"
    fi
    
    # Reload Apache
    systemctl reload apache2
    
    echo "✅ SSL enabled for ${SUB}.s-neue.website"
    echo "🔗 URL: https://${SUB}.s-neue.website"
  else
    echo "⚠️ SSL template not found. Run 'wildcard-ssl-setup' first."
  fi
else
  echo "⚠️ Wildcard SSL certificate not found. Run 'wildcard-ssl-setup' first."
fi
APPEND

echo "✅ SSL integration complete!"
EOF
chmod +x /opt/infra-scripts/integrate-ssl.sh
ln -sf /opt/infra-scripts/integrate-ssl.sh /usr/local/bin/integrate-ssl

# 8. Modify Apache to ensure SSL modules are enabled
echo "🔌 Enabling Apache SSL modules..."
a2enmod ssl
a2enmod headers
a2enmod rewrite

# 9. Set up automatic renewal with cron job
echo "🔄 Setting up automatic SSL renewal..."
cat > /etc/cron.d/certbot << 'EOF'
0 3 * * * root certbot renew --quiet --post-hook "systemctl reload apache2"
EOF

echo "✅ SSL setup scripts created successfully!"
echo ""
echo "To get started with SSL, follow these steps:"
echo ""
echo "1. Set up a wildcard certificate for all subdomains (recommended):"
echo "   wildcard-ssl-setup"
echo ""
echo "2. Apply SSL to all existing WordPress sites:"
echo "   ssl-update-all"
echo ""
echo "3. Integrate SSL into new WordPress installations:"
echo "   integrate-ssl"
echo ""
echo "4. For individual sites, you can also use:"
echo "   ssl-setup testkunde9"
echo ""
echo "After these steps, all your WordPress sites will use HTTPS!"