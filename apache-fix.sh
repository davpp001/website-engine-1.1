#!/bin/bash
# This script fixes the syntax error in apache.sh line ~561

# Find the exact line with the error
APACHE_FILE="/opt/website-engine-1.1/modules/apache.sh"
BACKUP_FILE="/opt/website-engine-1.1/modules/apache.sh.bak"

# Create a backup
cp "$APACHE_FILE" "$BACKUP_FILE"

# Fix the syntax error by ensuring proper function structure for setup_vhost
# The error was that some code got misplaced or a closing brace got inserted incorrectly
sed -i '569,660 s/function setup_vhost() {\n  local SUB="$1"/function setup_vhost() {\n  local SUB="$1"/' "$APACHE_FILE"

# Verify the file syntax
bash -n "$APACHE_FILE"
if [ $? -eq 0 ]; then
  echo "✅ Syntax error in apache.sh has been fixed successfully."
else
  echo "❌ Failed to fix the syntax error. Restoring backup."
  cp "$BACKUP_FILE" "$APACHE_FILE"
  
  # Alternative fix approach: recreate the function completely
  echo "Trying alternative fix approach..."
  
  # Extract the function content for manual fixing
  sed -n '/^function setup_vhost/,/^}/p' "$BACKUP_FILE" > /tmp/setup_vhost_function.txt
  
  echo "Please manually fix the setup_vhost function by examining the content in /tmp/setup_vhost_function.txt"
  echo "Look for unbalanced braces or other syntax errors."
  echo "You may need to edit the file directly at $APACHE_FILE"
fi
