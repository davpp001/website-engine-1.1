#!/usr/bin/env bash
set -euo pipefail

# This script focuses only on fixing setup_wp and cleanup_wp
# to ensure they create and remove secure WordPress sites

echo "🔧 Fixing setup_wp and cleanup_wp for secure WordPress installations..."

# 1. First, check if we have the essential tools
echo "🔍 Checking for required tools..."
if ! command -v certbot &> /dev/null; then
  echo "📦 Installing Certbot and plugins..."
  apt-get update
  apt-get install -y certbot python3-certbot-apache
fi

# 2. Enable required Apache modules
echo "🔌 Enabling required Apache modules..."
a2enmod ssl
a2enmod rewrite
systemctl reload apache2

# 3. Fix setup_wp to include SSL configuration
echo "📝 Updating setup_wp to create secure WordPress sites..."
cat > /opt/infra-scripts/wordpress/setup_wp.sh << 'EOF'
#!/usr/bin/env bash
set -eo pipefail

# WordPress setup script with SSL support
# This script creates a subdomain, sets up WordPress, and configures SSL

if [ $# -ne 1 ]; then
  echo "Usage: $0 <subdomain>"
  exit 1
fi

# Variables
BASE="$1"
INFRA_DIR="/opt/infra-scripts"
DOMAIN="s-neue.website"

# 1. Create subdomain in Cloudflare
echo "🌐 Creating subdomain ${BASE}..."
CF_OUTPUT=$("${INFRA_DIR}/cloudflare/create_cf_sub_auto.sh" "${BASE}")
echo "${CF_OUTPUT}"

# Extract subdomain from output
SUB=$(echo "${CF_OUTPUT}" | grep -o "[a-zA-Z0-9-]*" | grep "${BASE}" | head -1 || echo "${BASE}")
FQDN="${SUB}.${DOMAIN}"

# 2. Wait for DNS propagation
echo "⏳ Waiting for DNS propagation for ${FQDN}..."
SERVER_IP=$(curl -s https://ifconfig.me)
DNS_READY=false

for i in {1..10}; do
  if dig +short @1.1.1.1 "${FQDN}" | grep -q "${SERVER_IP}"; then
    echo "✅ DNS propagated to Cloudflare DNS."
    DNS_READY=true
    break
  fi
  
  if dig +short "${FQDN}" | grep -q "${SERVER_IP}"; then
    echo "✅ DNS propagated to standard DNS."
    DNS_READY=true
    break
  fi
  
  echo "⏳ Waiting for DNS propagation... Attempt ${i}/10"
  sleep 3
done

# 3. Set up WordPress
echo "📦 Installing WordPress for ${SUB}..."

# Variables
WWW_PATH="/var/www/${SUB}"
VHOST_PATH="/etc/apache2/sites-available/${SUB}.conf"
DB_NAME="${SUB}"
DB_USER="wordpressuser"
DB_PASS="password"

# 3.1 Check DNS
echo "🔍 Checking DNS for ${FQDN}..."
if ! $DNS_READY; then
  echo "⚠️ DNS not yet propagated. Continuing anyway..."
fi

# 3.2 Create directories
echo "🔨 Creating directories..."
mkdir -p "${WWW_PATH}"
chown -R www-data:www-data "${WWW_PATH}"

# 3.3 Create Apache vhost
echo "📝 Creating Apache vhost..."
cat > "${VHOST_PATH}" << VHOST_EOF
<VirtualHost *:80>
    ServerName ${FQDN}
    DocumentRoot ${WWW_PATH}
    
    <Directory ${WWW_PATH}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/error-${SUB}.log
    CustomLog \${APACHE_LOG_DIR}/access-${SUB}.log combined
    
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]
</VirtualHost>
VHOST_EOF

# 3.4 Enable Apache site
echo "🔄 Enabling Apache site..."
a2ensite "${SUB}.conf"
systemctl reload apache2 || echo "Apache reload failed but continuing."

# 3.5 Set up WordPress
echo "📦 Downloading WordPress..."
cd "${WWW_PATH}" || exit 1
wp core download --locale=de_DE --allow-root

# 3.6 Database setup
echo "🗃️ Creating MySQL database..."
# Create database
mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"

# Check if user exists
if ! mysql -u root -e "SELECT User FROM mysql.user WHERE User='${DB_USER}'" | grep -q "${DB_USER}"; then
  echo "Creating database user..."
  mysql -u root -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
fi

# Grant privileges
mysql -u root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
mysql -u root -e "FLUSH PRIVILEGES;"

# 3.7 Create wp-config.php
echo "🔧 Generating wp-config.php..."
wp config create \
  --dbname="${DB_NAME}" \
  --dbuser="${DB_USER}" \
  --dbpass="${DB_PASS}" \
  --locale=de_DE \
  --allow-root

# 3.8 Install WordPress
echo "🚀 Installing WordPress core..."
wp core install \
  --url="https://${FQDN}" \
  --title="${SUB} - S Neue Website" \
  --admin_user="we-admin" \
  --admin_password="We-25-\$\$-Vo" \
  --admin_email="admin@online-aesthetik.de" \
  --skip-email \
  --allow-root

# 4. Set up SSL with Certbot
echo "🔒 Setting up SSL certificate..."
certbot --apache \
  --non-interactive \
  --agree-tos \
  --redirect \
  --email admin@online-aesthetik.de \
  -d "${FQDN}" || echo "⚠️ SSL setup failed, but WordPress is still installed."

echo "✅ WordPress setup complete for ${SUB}."
echo "🔗 URL: https://${FQDN}"
echo "👤 Admin: we-admin / We-25-\$\$-Vo"
EOF
chmod +x /opt/infra-scripts/wordpress/setup_wp.sh

# 4. Fix cleanup_wp to properly remove everything
echo "🧹 Updating cleanup_wp for proper site removal..."
cat > /opt/infra-scripts/wordpress/cleanup_wp.sh << 'EOF'
#!/usr/bin/env bash
set -eo pipefail

# WordPress cleanup script
# This script removes a WordPress site completely

if [ $# -ne 1 ]; then
  echo "Usage: $0 <subdomain>"
  exit 1
fi

SUB="$1"
DOMAIN="s-neue.website"
FQDN="${SUB}.${DOMAIN}"

echo "🧹 Cleaning up WordPress site for ${FQDN}..."

# 1. Disable and remove Apache configurations
echo "🔄 Removing Apache configurations..."
if [ -f "/etc/apache2/sites-enabled/${SUB}.conf" ]; then
  a2dissite "${SUB}.conf"
fi

if [ -f "/etc/apache2/sites-enabled/${SUB}-le-ssl.conf" ]; then
  a2dissite "${SUB}-le-ssl.conf"
fi

systemctl reload apache2

if [ -f "/etc/apache2/sites-available/${SUB}.conf" ]; then
  rm "/etc/apache2/sites-available/${SUB}.conf"
fi

if [ -f "/etc/apache2/sites-available/${SUB}-le-ssl.conf" ]; then
  rm "/etc/apache2/sites-available/${SUB}-le-ssl.conf"
fi

# 2. Remove the website directory
echo "🗑️ Removing website files..."
if [ -d "/var/www/${SUB}" ]; then
  rm -rf "/var/www/${SUB}"
fi

# 3. Drop the database
echo "🗑️ Removing database..."
mysql -u root -e "DROP DATABASE IF EXISTS \`${SUB}\`;"

# 4. Remove SSL certificate
echo "🔐 Removing SSL certificate..."
certbot delete --non-interactive --cert-name "${FQDN}" || echo "No certificate found for ${FQDN}"

# 5. Remove DNS record
echo "🌐 Removing DNS record..."
INFRA_DIR="/opt/infra-scripts"
"${INFRA_DIR}/cloudflare/delete_cf_sub.sh" "${SUB}" || echo "Failed to remove DNS record"

echo "✅ Cleanup complete for ${FQDN}"
EOF
chmod +x /opt/infra-scripts/wordpress/cleanup_wp.sh

# 5. Create symbolic links to ensure commands work properly
echo "🔗 Creating command links..."
ln -sf /opt/infra-scripts/wordpress/setup_wp.sh /usr/local/bin/setup_wp
ln -sf /opt/infra-scripts/wordpress/cleanup_wp.sh /usr/local/bin/cleanup_wp

# 6. Create the delete_cf_sub.sh script if it doesn't exist
if [ ! -f "/opt/infra-scripts/cloudflare/delete_cf_sub.sh" ]; then
  echo "📝 Creating DNS deletion script..."
  mkdir -p /opt/infra-scripts/cloudflare
  cat > /opt/infra-scripts/cloudflare/delete_cf_sub.sh << 'EOF'
#!/usr/bin/env bash
set -eo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <subdomain>"
  exit 1
fi

SUB="$1"
DOMAIN="s-neue.website"
FQDN="${SUB}.${DOMAIN}"

echo "🗑️ Deleting DNS record for ${FQDN}..."

: "${CF_API_TOKEN:=lLrGrv3Q8hmj-Db4ncotnGqbaE0IFX9oKvD8yxQV}"
: "${ZONE_ID:=d7e5b4cfe310063ede065b1ba06bcdf7}"

# Get the DNS record ID
echo "🔍 Looking up DNS record ID..."
RECORD_IDS=$(curl -s -X GET \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${FQDN}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  | jq -r '.result[].id')

if [ -z "${RECORD_IDS}" ]; then
  echo "⚠️ No DNS records found for ${FQDN}"
  exit 0
fi

# Delete each matching record
for RECORD_ID in ${RECORD_IDS}; do
  echo "🗑️ Deleting record ${RECORD_ID}..."
  resp=$(curl -s -X DELETE \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")
  
  ok=$(echo "$resp" | jq -r '.success')
  if [ "$ok" = "true" ]; then
    echo "✅ Successfully deleted DNS record for ${FQDN}"
  else
    echo "❌ Failed to delete DNS record: $(echo "$resp" | jq -r '.errors[].message')"
  fi
done
EOF
  chmod +x /opt/infra-scripts/cloudflare/delete_cf_sub.sh
  ln -sf /opt/infra-scripts/cloudflare/delete_cf_sub.sh /usr/local/bin/delete_cf_sub
fi

# 7. Ensure Cloudflare credentials are available
echo "🔑 Setting up Cloudflare credentials..."
cat > /etc/profile.d/cloudflare.sh << 'EOF'
export CF_API_TOKEN="lLrGrv3Q8hmj-Db4ncotnGqbaE0IFX9oKvD8yxQV"
export ZONE_ID="d7e5b4cfe310063ede065b1ba06bcdf7"
export DOMAIN="s-neue.website"
EOF
chmod +x /etc/profile.d/cloudflare.sh
source /etc/profile.d/cloudflare.sh

echo "✅ Fixes applied successfully!"
echo ""
echo "Now you can use:"
echo "  setup_wp testkunde11    - to create a secure WordPress site"
echo "  cleanup_wp testkunde11  - to completely remove a WordPress site"
echo ""
echo "These commands will now properly handle SSL and create secure sites."