#!/bin/bash

# Generate a strong encryption key
openssl rand -base64 32 > /root/.backup-encryption-key

# Create a key identification header
SERVER_ID="$(hostname)-$(date +%Y%m%d)"
KEY_ID="backup-key-$SERVER_ID"

# Create a key bundle with metadata
cat > /tmp/key-bundle.txt << EOF
Backup Encryption Key Bundle
Generated: $(date)
Server: $(hostname)
Key ID: $KEY_ID
Purpose: MariaDB backup encryption
Algorithm: AES-256-CBC

IMPORTANT: Store this entire file securely. You need it to restore backups.

--- BEGIN ENCRYPTION KEY ---
$(cat /root/.backup-encryption-key)
--- END ENCRYPTION KEY ---

To decrypt backups:
1. Save the key between BEGIN/END markers to a file
2. Use: openssl enc -aes-256-cbc -d -pbkdf2 -in backup.enc -out backup.tar.gz -pass file:keyfile
EOF

# Display the bundle
echo "======================================================"
echo "CRITICAL: SAVE THIS KEY BUNDLE IN YOUR PASSWORD MANAGER"
echo "======================================================"
cat /tmp/key-bundle.txt
echo "======================================================"

# Delete the temporary key bundle file
shred -u /tmp/key-bundle.txt

# Secure local copy
chmod 600 /root/.backup-encryption-key