#!/bin/bash
# This script fixes the issue with Apache showing the default page instead of WordPress content
# by disabling the default SSL configurations that are intercepting HTTPS traffic

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
    DocumentRoot /var/www/$site_name/public_html
    
    ErrorLog \${APACHE_LOG_DIR}/$site_name-error.log
    CustomLog \${APACHE_LOG_DIR}/$site_name-access.log combined
    
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$domain/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$domain/privkey.pem
    
    <Directory /var/www/$site_name/public_html>
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
      sed -i "/<VirtualHost \*:443>/a\\    DocumentRoot /var/www/$site_name/public_html" "$config"
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

# Restart Apache to apply changes
echo "🔄 Restarting Apache..."
systemctl restart apache2

echo "✅ Apache SSL configuration fix completed."
echo "If sites are still showing the default page, check individual site configurations and SSL certificate paths."
