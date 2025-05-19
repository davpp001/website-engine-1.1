#!/bin/bash
# Quick direct fix for the syntax error in apache.sh

APACHE_FILE="/opt/website-engine-1.1/modules/apache.sh"

# The error is on line 561 - likely a mismatched brace
# Let's directly edit that section to make sure braces match correctly

# First, let's ensure the specific issue around line 561 is fixed
# The issue is that there's an unexpected '}'

# How to use this script:
# 1. SSH into your server
# 2. Copy this script to the server
# 3. Make it executable: chmod +x fix-apache.sh
# 4. Run it: ./fix-apache.sh

# Create a backup first
cp "$APACHE_FILE" "${APACHE_FILE}.bak"
echo "Created backup at ${APACHE_FILE}.bak"

# Manual fix method - directly edit the file with sed replacements
# Looking at the error, the issue is likely in the setup_vhost function where there might be 
# an extra closing brace or a missing opening brace

# Method 1: Direct quick fix - replace the section with the error
# Replace a possible syntax error where an extra brace might be
sed -i '558,562 s/    fi\n  }/    fi\n  /g' "$APACHE_FILE"

# Check syntax
bash -n "$APACHE_FILE"
if [ $? -eq 0 ]; then
  echo "✅ Syntax fixed successfully!"
else
  echo "❌ Direct fix didn't work."
  echo "Please use the full function replacement script instead."
  # Restore the backup
  cp "${APACHE_FILE}.bak" "$APACHE_FILE"
fi
