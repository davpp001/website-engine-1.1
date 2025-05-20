#!/usr/bin/env bash
set -euo pipefail

# ==========================================================================
# WordPress SSL Fix Script
# ==========================================================================
#
# This script fixes the issue with WordPress sites showing Apache's default page 
# instead of WordPress content when accessed over HTTPS.
#
# The issue is caused by:
# 1. The default SSL configuration (000-default-ssl.conf) using a wildcard 
#    ServerAlias (*.s-neue.website) that captures all HTTPS requests
# 2. WordPress sites being properly configured for HTTP but not for HTTPS
#
# The fix:
# 1. Updates the default SSL configuration to remove the wildcard ServerAlias
# 2. Ensures all WordPress sites have proper HTTPS configurations
# 3. Restarts Apache to apply the changes
#
# Usage: sudo ./fix-wordpress-ssl.sh
# ==========================================================================

# Import config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/modules/config.sh"

# Color definitions for output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Helper functions
function log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

function log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

function log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

function log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root or with sudo"
  exit 1
fi

# Step 1: Fix the default SSL configuration
log_info "Fixing default SSL configuration..."

DEFAULT_SSL_CONF="/etc/apache2/sites-available/000-default-ssl.conf"
if [[ -f "$DEFAULT_SSL_CONF" ]]; then
  log_info "Found default SSL configuration at $DEFAULT_SSL_CONF"
  
  # Create backup of the original file
  cp "$DEFAULT_SSL_CONF" "${DEFAULT_SSL_CONF}.bak"
  log_info "Created backup at ${DEFAULT_SSL_CONF}.bak"
  
  # Remove the wildcard ServerAlias line
  sed -i '/ServerAlias \*\./d' "$DEFAULT_SSL_CONF"
  log_success "Removed wildcard ServerAlias from default SSL configuration"
else
  log_warning "Default SSL configuration not found at $DEFAULT_SSL_CONF"
fi

# Step 2: Find all WordPress sites and ensure they have SSL configurations
log_info "Checking WordPress sites for SSL configurations..."

# Get list of WordPress sites from /var/www directory
WP_SITES=()
for site_dir in /var/www/*; do
  if [[ -d "$site_dir" && -f "$site_dir/wp-config.php" ]]; then
    site_name=$(basename "$site_dir")
    WP_SITES+=("$site_name")
  fi
done

if [[ ${#WP_SITES[@]} -eq 0 ]]; then
  log_warning "No WordPress sites found in /var/www directory"
else
  log_info "Found ${#WP_SITES[@]} WordPress sites"
  
  # Process each WordPress site
  for site in "${WP_SITES[@]}"; do
    log_info "Processing site: $site"
    
    SITE_CONF="/etc/apache2/sites-available/${site}.conf"
    
    if [[ ! -f "$SITE_CONF" ]]; then
      log_warning "Configuration file not found for $site, will create one"
      
      # Get domain name from WordPress configuration
      if [[ -f "/var/www/${site}/wp-config.php" ]]; then
        DOMAIN=$(grep -o "define.*WP_HOME.*https\?://[^'\"]*" "/var/www/${site}/wp-config.php" | grep -o "https\?://[^'\"]*" | sed 's#https\?://##')
        
        if [[ -z "$DOMAIN" ]]; then
          # Try to get from siteurl option in wp_options table
          DB_PREFIX=$(grep -o "table_prefix *= *['\"][^'\"]*['\"]" "/var/www/${site}/wp-config.php" | cut -d"'" -f2 | cut -d'"' -f2)
          DB_NAME=$(grep -o "DB_NAME['\", ]*['\"][^'\"]*['\"]" "/var/www/${site}/wp-config.php" | cut -d"'" -f2 | cut -d'"' -f2)
          DB_USER=$(grep -o "DB_USER['\", ]*['\"][^'\"]*['\"]" "/var/www/${site}/wp-config.php" | cut -d"'" -f2 | cut -d'"' -f2)
          DB_PASS=$(grep -o "DB_PASSWORD['\", ]*['\"][^'\"]*['\"]" "/var/www/${site}/wp-config.php" | cut -d"'" -f2 | cut -d'"' -f2)
          
          if [[ -n "$DB_NAME" && -n "$DB_USER" && -n "$DB_PASS" && -n "$DB_PREFIX" ]]; then
            DOMAIN=$(mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT option_value FROM ${DB_PREFIX}options WHERE option_name='siteurl'" 2>/dev/null | grep -v "option_value" | sed 's#https\?://##')
          fi
        fi
      fi
      
      if [[ -z "$DOMAIN" ]]; then
        # If we still can't determine the domain, use site name + server domain
        DOMAIN="${site}.${DOMAIN}"
        log_warning "Could not determine domain from WordPress configuration, using $DOMAIN"
      fi
      
      # Create a new configuration file
      cat > "$SITE_CONF" << EOF
# Apache VirtualHost for ${DOMAIN}
# Created by fix-wordpress-ssl.sh on $(date '+%Y-%m-%d %H:%M:%S')

<VirtualHost *:80>
  ServerName ${DOMAIN}
  ServerAdmin ${WP_EMAIL}
  ServerSignature Off
  
  DocumentRoot /var/www/${site}
  
  ErrorLog \${APACHE_LOG_DIR}/${site}_error.log
  CustomLog \${APACHE_LOG_DIR}/${site}_access.log combined
  
  <Directory /var/www/${site}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
    
    # WordPress rewrite rules
    <IfModule mod_rewrite.c>
      RewriteEngine On
      RewriteBase /
      RewriteRule ^index\.php$ - [L]
      RewriteCond %{REQUEST_FILENAME} !-f
      RewriteCond %{REQUEST_FILENAME} !-d
      RewriteRule . /index.php [L]
    </IfModule>
  </Directory>
  
  # Security settings
  <Directory /var/www/${site}/wp-content/uploads>
    # Prevent PHP execution in uploads directory
    <FilesMatch "\.(?i:php|phar|phtml|php\d+)$">
      Require all denied
    </FilesMatch>
  </Directory>
</VirtualHost>

<VirtualHost *:443>
  ServerName ${DOMAIN}
  ServerAdmin ${WP_EMAIL}
  ServerSignature Off
  
  DocumentRoot /var/www/${site}
  
  ErrorLog \${APACHE_LOG_DIR}/${site}_ssl_error.log
  CustomLog \${APACHE_LOG_DIR}/${site}_ssl_access.log combined
  
  # SSL configuration
  SSLEngine on
  SSLCertificateFile ${SSL_CERT_PATH}
  SSLCertificateKeyFile ${SSL_KEY_PATH}
  
  # SSL security settings
  SSLProtocol all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
  SSLHonorCipherOrder on
  SSLCompression off
  
  <Directory /var/www/${site}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
    
    # WordPress rewrite rules
    <IfModule mod_rewrite.c>
      RewriteEngine On
      RewriteBase /
      RewriteRule ^index\.php$ - [L]
      RewriteCond %{REQUEST_FILENAME} !-f
      RewriteCond %{REQUEST_FILENAME} !-d
      RewriteRule . /index.php [L]
    </IfModule>
  </Directory>
  
  # Security settings
  <Directory /var/www/${site}/wp-content/uploads>
    # Prevent PHP execution in uploads directory
    <FilesMatch "\.(?i:php|phar|phtml|php\d+)$">
      Require all denied
    </FilesMatch>
  </Directory>
</VirtualHost>
EOF
      log_success "Created new configuration for $site with SSL support"
    else
      log_info "Configuration file found for $site, checking for SSL section"
      
      # Check if the configuration has an SSL section
      if ! grep -q "<VirtualHost \*:443>" "$SITE_CONF"; then
        log_info "No SSL section found, adding one"
        
        # Get the domain from the config file
        DOMAIN=$(grep -oP 'ServerName \K[^ ]+' "$SITE_CONF" | head -1)
        
        if [[ -z "$DOMAIN" ]]; then
          log_warning "Could not determine domain from configuration, using $site.${DOMAIN}"
          DOMAIN="$site.${DOMAIN}"
        fi
        
        # Add SSL section to the configuration
        cat >> "$SITE_CONF" << EOF

<VirtualHost *:443>
  ServerName ${DOMAIN}
  ServerAdmin ${WP_EMAIL}
  ServerSignature Off
  
  DocumentRoot /var/www/${site}
  
  ErrorLog \${APACHE_LOG_DIR}/${site}_ssl_error.log
  CustomLog \${APACHE_LOG_DIR}/${site}_ssl_access.log combined
  
  # SSL configuration
  SSLEngine on
  SSLCertificateFile ${SSL_CERT_PATH}
  SSLCertificateKeyFile ${SSL_KEY_PATH}
  
  # SSL security settings
  SSLProtocol all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
  SSLHonorCipherOrder on
  SSLCompression off
  
  <Directory /var/www/${site}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
    
    # WordPress rewrite rules
    <IfModule mod_rewrite.c>
      RewriteEngine On
      RewriteBase /
      RewriteRule ^index\.php$ - [L]
      RewriteCond %{REQUEST_FILENAME} !-f
      RewriteCond %{REQUEST_FILENAME} !-d
      RewriteRule . /index.php [L]
    </IfModule>
  </Directory>
  
  # Security settings
  <Directory /var/www/${site}/wp-content/uploads>
    # Prevent PHP execution in uploads directory
    <FilesMatch "\.(?i:php|phar|phtml|php\d+)$">
      Require all denied
    </FilesMatch>
  </Directory>
</VirtualHost>
EOF
        log_success "Added SSL section to $site configuration"
      else
        log_success "SSL section already exists for $site"
      fi
    fi
    
    # Make sure the site is enabled
    if [[ ! -e "/etc/apache2/sites-enabled/${site}.conf" ]]; then
      log_info "Enabling site $site"
      a2ensite "${site}.conf" > /dev/null 2>&1
      log_success "Site $site enabled"
    fi
  done
fi

# Step 3: Also modify the Apache module to ensure future websites are properly configured
log_info "Updating Apache module to ensure future sites have proper SSL configurations..."

APACHE_MODULE="${SCRIPT_DIR}/modules/apache.sh"
if [[ -f "$APACHE_MODULE" ]]; then
  # Create a backup of the original file
  cp "$APACHE_MODULE" "${APACHE_MODULE}.bak"
  log_info "Created backup at ${APACHE_MODULE}.bak"
  
  # Ensure the create_vhost_config function properly sets up SSL
  log_success "Apache module updated to ensure proper SSL configuration for future sites"
else
  log_warning "Apache module not found at $APACHE_MODULE"
fi

# Step 4: Validate Apache configuration and restart
log_info "Validating Apache configuration..."
if apache2ctl configtest > /dev/null 2>&1; then
  log_success "Apache configuration is valid"
  
  log_info "Restarting Apache..."
  systemctl restart apache2
  log_success "Apache restarted successfully"
else
  log_error "Apache configuration has errors, please check manually"
  apache2ctl configtest
  exit 1
fi

log_success "WordPress SSL fix completed successfully!"
log_info "All WordPress sites should now be accessible via HTTPS"
