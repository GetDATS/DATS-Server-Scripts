#!/bin/bash
# Generate the backup encryption key for this server and print the bundle to
# store in the password manager. Refuses to run if a key already exists.

set -euo pipefail

KEY_FILE="/root/.backup-encryption-key"

# Never overwrite an existing key: every backup already encrypted with it would
# become unreadable. Rotating the key is a deliberate act: move the old key
# aside, keep it with the backups it protects, then run this again.
if [ -e "$KEY_FILE" ]; then
    echo "ERROR: $KEY_FILE already exists. Refusing to overwrite it." >&2
    echo "Existing encrypted backups need this key. To rotate, move it aside first." >&2
    exit 1
fi

# Generate a strong encryption key, readable by root only
umask 077
openssl rand -base64 32 > "$KEY_FILE"
chmod 600 "$KEY_FILE"

# Create a key identification header
SERVER_ID="$(hostname)-$(date +%Y%m%d)"
KEY_ID="backup-key-$SERVER_ID"

# Build the key bundle in a private temporary file, removed on exit
BUNDLE="$(mktemp)"
trap 'shred -u "$BUNDLE" 2>/dev/null || rm -f "$BUNDLE"' EXIT
cat > "$BUNDLE" << EOF
Backup Encryption Key Bundle
Generated: $(date)
Server: $(hostname)
Key ID: $KEY_ID
Purpose: MariaDB backup encryption
Algorithm: AES-256-CBC

IMPORTANT: Store this entire file securely. You need it to restore backups.

--- BEGIN ENCRYPTION KEY ---
$(cat "$KEY_FILE")
--- END ENCRYPTION KEY ---

To decrypt backups:
1. Save the key between BEGIN/END markers to a file
2. Use: openssl enc -aes-256-cbc -d -pbkdf2 -in backup.enc -out backup.tar.gz -pass file:keyfile
EOF

# Display the bundle
echo "======================================================"
echo "CRITICAL: SAVE THIS KEY BUNDLE IN YOUR PASSWORD MANAGER"
echo "======================================================"
cat "$BUNDLE"
echo "======================================================"
