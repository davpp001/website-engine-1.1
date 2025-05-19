#!/bin/bash
# ==========================================================================
# Apache SSL Configuration Fix Script
# ==========================================================================
#
# This script fixes the issue with WordPress sites showing Apache's default page 
# instead of WordPress content when using Wildcard SSL certificates via Cloudflare DNS-01.
#
# Root causes of the issues:
# - Incorrect DocumentRoot paths in SSL VirtualHost (/var/www/site/public_html instead of /var/www/site)
# - Certificate paths pointing to site-specific certs when wildcard certs should be used
# - Duplicate DocumentRoot directives in non-SSL VirtualHost
# - Default SSL configurations intercepting HTTPS traffic
#
# The script:
# 1. Disables default SSL configs that might be intercepting HTTPS traffic
# 2. Ensures all WordPress site configs have proper SSL VirtualHost sections
# 3. Fixes DocumentRoot paths in both HTTP and HTTPS VirtualHost sections
# 4. Updates incorrect SSL certificate paths to use the wildcard certificate
# 5. Makes sure all sites are properly enabled
# 6. Fixes inconsistent error and access log naming
#
# Usage: ./fix-apache-ssl.sh
#
# ==========================================================================

echo "🔍 Checking for default SSL configurations..."

# Check if default SSL configs are enabled and disable them
if [ -L "/etc/apache2/sites-enabled/000-default-le-ssl.conf" ]; then
  echo "🚫 Disabling Let's Encrypt default SSL config..."
  a2dissite 000-default-le-ssl.conf
  echo "✅ Default Let's Encrypt SSL config disabled."
fi

if [ -L "/etc/apache2/sites-enabled/000-default-ssl.conf" ]; then
  echo "🚫 Disabling default SSL config..."
  a2dissite 000-default-ssl.conf
  echo "✅ Default SSL config disabled."
fi

# Verify that all WordPress site configs have proper SSL VirtualHost sections
echo "🔍 Checking WordPress site configurations..."

for config in /etc/apache2/sites-available/*.conf; do
  # Skip default configs
  if [[ $config == *"000-default"* ]]; then
    continue
  fi
  
  site_name=$(basename $config .conf)
  
  echo "📄 Processing site: $site_name"
  
  # Check if the site config has an SSL VirtualHost section
  if ! grep -q "<VirtualHost \*:443>" "$config"; then
    echo "⚠️ No SSL VirtualHost found in $config. Adding SSL configuration..."
    
    # Get the domain from the config
    domain=$(grep -oP 'ServerName \K[^ ]+' "$config" | head -1)
    
    if [ -z "$domain" ]; then
      echo "❌ Could not determine domain for $site_name. Skipping..."
      continue
    fi
    
    # Add SSL VirtualHost section
    cat >> "$config" << EOF

<VirtualHost *:443>
    ServerName $domain
    ServerAlias www.$domain
    DocumentRoot /var/www/$site_name
    
    ErrorLog \${APACHE_LOG_DIR}/$site_name-error.log
    CustomLog \${APACHE_LOG_DIR}/$site_name-access.log combined
    
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/s-neue.website/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/s-neue.website/privkey.pem
    
    <Directory /var/www/$site_name>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
    echo "✅ SSL VirtualHost added to $site_name"
  else
    echo "✓ SSL VirtualHost section exists in $config"
    
    # Check if DocumentRoot is set in the SSL VirtualHost
    if ! grep -A 10 "<VirtualHost \*:443>" "$config" | grep -q "DocumentRoot"; then
      echo "⚠️ DocumentRoot missing in SSL VirtualHost. Adding..."
      
      # Get the domain from the config
      domain=$(grep -oP 'ServerName \K[^ ]+' "$config" | head -1)
      
      # Insert DocumentRoot after VirtualHost line
      sed -i "/<VirtualHost \*:443>/a\\    DocumentRoot /var/www/$site_name" "$config"
      echo "✅ DocumentRoot added to SSL VirtualHost for $site_name"
    fi
  fi
  
  # Make sure the site is enabled
  if [ ! -L "/etc/apache2/sites-enabled/$site_name.conf" ]; then
    echo "⚠️ Site $site_name is not enabled. Enabling..."
    a2ensite $site_name.conf
    echo "✅ Site $site_name enabled."
  fi
done

# Fix duplicate DocumentRoot directives in HTTP VirtualHost
echo "🔍 Checking for duplicate DocumentRoot directives in HTTP configs..."

for config in /etc/apache2/sites-available/*.conf; do
  # Skip default configs
  if [[ $config == *"000-default"* ]]; then
    continue
  fi
  
  site_name=$(basename $config .conf)
  
  # Count DocumentRoot directives in HTTP VirtualHost
  http_docroot_count=$(grep -A 20 "<VirtualHost \*:80>" "$config" | grep -m 20 -c "DocumentRoot")
  
  if [ "$http_docroot_count" -gt 1 ]; then
    echo "⚠️ Found duplicate DocumentRoot directives in $site_name.conf HTTP section"
    echo "🔧 Fixing duplicate DocumentRoot directives..."
    
    # Create a temporary file for editing
    tmp_file=$(mktemp)
    
    # Process the file to remove duplicate DocumentRoot lines
    in_http_section=0
    docroot_found=0
    
    while IFS= read -r line; do
      if [[ $line == *"<VirtualHost *:80>"* ]]; then
        in_http_section=1
        docroot_found=0
        echo "$line" >> "$tmp_file"
      elif [[ $line == *"</VirtualHost>"* ]]; then
        in_http_section=0
        echo "$line" >> "$tmp_file"
      elif [[ $in_http_section -eq 1 ]] && [[ $line == *"DocumentRoot"* ]]; then
        if [[ $docroot_found -eq 0 ]]; then
          echo "  DocumentRoot /var/www/$site_name" >> "$tmp_file"
          docroot_found=1
        fi
        # Skip the line (don't output it again)
      else
        echo "$line" >> "$tmp_file"
      fi
    done < "$config"
    
    # Replace the original file
    mv "$tmp_file" "$config"
    echo "✅ Fixed duplicate DocumentRoot directives in $site_name"
  fi
done

# Check for incorrect DocumentRoot paths in SSL VirtualHost sections
echo "🔍 Checking for incorrect DocumentRoot paths in SSL configurations..."

for config in /etc/apache2/sites-available/*.conf; do
  # Skip default configs
  if [[ $config == *"000-default"* ]]; then
    continue
  fi
  
  site_name=$(basename $config .conf)
  
  # Check if SSL VirtualHost has incorrect DocumentRoot path
  if grep -q "<VirtualHost \*:443>" "$config"; then
    incorrect_path=$(grep -A 10 "<VirtualHost \*:443>" "$config" | grep -oP 'DocumentRoot\s+\K/var/www/[^/]+/public_html')
    
    if [ ! -z "$incorrect_path" ]; then
      echo "⚠️ Found incorrect DocumentRoot path in $site_name.conf SSL section: $incorrect_path"
      echo "🔧 Fixing SSL DocumentRoot path..."
      
      # Replace the incorrect path
      sed -i "s|DocumentRoot\s\+/var/www/$site_name/public_html|DocumentRoot /var/www/$site_name|g" "$config"
      
      # Also fix the Directory directive if it exists
      sed -i "s|<Directory\s\+/var/www/$site_name/public_html>|<Directory /var/www/$site_name>|g" "$config"
      
      echo "✅ Fixed SSL DocumentRoot path for $site_name"
    fi
  fi
done

# Check for inconsistent log file naming
echo "🔍 Checking for inconsistent log file naming..."

for config in /etc/apache2/sites-available/*.conf; do
  # Skip default configs
  if [[ $config == *"000-default"* ]]; then
    continue
  fi
  
  site_name=$(basename $config .conf)
  
  # Standardize log file naming in SSL VirtualHost
  if grep -q -E "ErrorLog.*${site_name}-error\.log" "$config" || grep -q -E "CustomLog.*${site_name}-access\.log" "$config"; then
    echo "⚠️ Found inconsistent log file naming in $site_name.conf"
    echo "🔧 Standardizing log file naming..."
    
    # Replace dash with underscore in log filenames
    sed -i "s|${site_name}-error\.log|${site_name}_error.log|g" "$config"
    sed -i "s|${site_name}-access\.log|${site_name}_access.log|g" "$config"
    
    echo "✅ Standardized log file naming for $site_name"
  fi
done

# Check for SSL certificate paths that point to non-existent site-specific certificates
echo "🔍 Checking for incorrect SSL certificate paths..."

for config in /etc/apache2/sites-available/*.conf; do
  # Skip default configs
  if [[ $config == *"000-default"* ]]; then
    continue
  fi
  
  site_name=$(basename $config .conf)
  domain=$(grep -oP 'ServerName \K[^ ]+' "$config" | head -1)
  
  # Check if config contains SSL section with incorrect certificate paths
  if grep -q "<VirtualHost \*:443>" "$config"; then
    cert_file=$(grep -oP 'SSLCertificateFile\s+\K[^ ]+' "$config" | head -1)
    
    # If cert_file doesn't point to the wildcard certificate, update it
    # We're not checking if the file exists because we want to standardize all certs to the wildcard
    if [[ "$cert_file" != "/etc/letsencrypt/live/s-neue.website/fullchain.pem" ]]; then
      echo "⚠️ Found non-wildcard certificate path in $site_name.conf: $cert_file"
      echo "🔧 Updating to use wildcard certificate..."
      
      # Replace the certificate paths with wildcard certificate paths
      sed -i "s|SSLCertificateFile.*|SSLCertificateFile /etc/letsencrypt/live/s-neue.website/fullchain.pem|" "$config"
      sed -i "s|SSLCertificateKeyFile.*|SSLCertificateKeyFile /etc/letsencrypt/live/s-neue.website/privkey.pem|" "$config"
      echo "✅ Updated certificate paths for $site_name"
    fi
  fi
done

# Restart Apache to apply changes
echo "🔄 Restarting Apache..."
systemctl restart apache2

echo "✅ Apache SSL configuration fix completed."
echo "If sites are still showing the default page, check individual site configurations and DocumentRoot paths."
