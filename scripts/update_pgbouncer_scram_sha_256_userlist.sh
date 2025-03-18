#!/bin/bash
#
# update_pgbouncer_userlist.sh - Updates PgBouncer userlist.txt file with PostgreSQL users
#
# This script updates the PgBouncer userlist.txt file with SCRAM-SHA-256 password hashes
# from PostgreSQL. It should be run after creating or modifying PostgreSQL users.
#
# Usage: sudo ./update_pgbouncer_userlist.sh
#
# Author: System Administrator

set -e # Exit immediately if a command exits with a non-zero status

# Configuration
PGBOUNCER_USER="pgbouncer"
PGBOUNCER_GROUP="pgbouncer"
USERLIST_PATH="/etc/pgbouncer/userlist.txt"
TEMP_USERLIST="/tmp/pgbouncer_userlist.tmp"
PGBOUNCER_SERVICE="pgbouncer"
PG_SUPERUSER="postgres"
LOG_FILE="/var/log/pgbouncer/userlist_updates.log"

# Ensure log directory exists
mkdir -p $(dirname "$LOG_FILE")

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root or with sudo" >&2
    exit 1
fi

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Create log file if it doesn't exist
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
    chown "$PGBOUNCER_USER:$PGBOUNCER_GROUP" "$LOG_FILE"
    chmod 640 "$LOG_FILE"
fi

log_message "Starting PgBouncer userlist update"

# Create backup of current userlist if it exists
if [ -f "$USERLIST_PATH" ]; then
    BACKUP_FILE="${USERLIST_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$USERLIST_PATH" "$BACKUP_FILE"
    log_message "Created backup of current userlist at $BACKUP_FILE"
fi

# Check if PgBouncer is installed and running
if ! command -v pgbouncer &> /dev/null; then
    log_message "ERROR: PgBouncer is not installed"
    exit 1
fi

if ! systemctl is-active --quiet $PGBOUNCER_SERVICE; then
    log_message "WARNING: PgBouncer service is not running"
fi

# Check if PostgreSQL is running
if ! su - $PG_SUPERUSER -c "pg_isready" &> /dev/null; then
    log_message "ERROR: PostgreSQL is not running"
    exit 1
fi

# Check PostgreSQL password encryption method
PG_PASSWORD_ENCRYPTION=$(su - $PG_SUPERUSER -c "psql -t -c \"SHOW password_encryption;\"" | tr -d '[:space:]')

if [ "$PG_PASSWORD_ENCRYPTION" != "scram-sha-256" ]; then
    log_message "WARNING: PostgreSQL password encryption is not scram-sha-256 (found: $PG_PASSWORD_ENCRYPTION)"
    log_message "This script is designed for SCRAM-SHA-256 authentication"
fi

# Check PgBouncer version for SCRAM-SHA-256 support
PGBOUNCER_VERSION=$(pgbouncer --version | grep -oP '[\d\.]+' | head -1)

if [ "$(printf '%s\n' "1.18.0" "$PGBOUNCER_VERSION" | sort -V | head -n1)" = "1.18.0" ]; then
    log_message "WARNING: PgBouncer version $PGBOUNCER_VERSION may not support SCRAM-SHA-256"
    log_message "PgBouncer 1.18.0 or higher is recommended for SCRAM-SHA-256 support"
fi

# Get current PgBouncer auth_type
PGBOUNCER_AUTH_TYPE=$(grep -oP '(?<=auth_type\s*=\s*).+' /etc/pgbouncer/pgbouncer.ini | tr -d '[:space:]')

if [ "$PGBOUNCER_AUTH_TYPE" != "scram-sha-256" ]; then
    log_message "WARNING: PgBouncer auth_type is not set to scram-sha-256 (found: $PGBOUNCER_AUTH_TYPE)"
    log_message "Make sure to set auth_type = scram-sha-256 in pgbouncer.ini"
fi

log_message "Extracting user credentials from PostgreSQL"

# Generate new userlist.txt content with SCRAM-SHA-256 password hashes
# The format must be: "username" "SCRAM-SHA-256$<iterations>:<salt>$<stored_key>:<server_key>"
su - $PG_SUPERUSER -c "psql -t -c \"
    SELECT concat('\\\"', usename, '\\\" \\\"', 
                 CASE WHEN rolpassword LIKE 'SCRAM-SHA-256%' 
                      THEN rolpassword 
                      ELSE 'SCRAM-SHA-256' || substring(rolpassword from ':.*') 
                 END, '\\\"')
    FROM pg_authid 
    WHERE rolcanlogin = true AND rolpassword IS NOT NULL;
\"" > "$TEMP_USERLIST"

# Check if query was successful
if [ ! -s "$TEMP_USERLIST" ]; then
    log_message "ERROR: Failed to retrieve user credentials from PostgreSQL"
    exit 1
fi

# Replace any malformed quotation marks and clean up whitespace
sed -i 's/\\"/"/g' "$TEMP_USERLIST"
sed -i 's/^\s*//; s/\s*$//' "$TEMP_USERLIST"

# Check if anything would change
if [ -f "$USERLIST_PATH" ] && diff -q "$TEMP_USERLIST" "$USERLIST_PATH" >/dev/null; then
    log_message "No changes detected in userlist.txt"
else
    # Apply new userlist
    cp "$TEMP_USERLIST" "$USERLIST_PATH"
    chown "$PGBOUNCER_USER:$PGBOUNCER_GROUP" "$USERLIST_PATH"
    chmod 600 "$USERLIST_PATH"
    
    log_message "Updated $USERLIST_PATH with $(wc -l < "$USERLIST_PATH") entries"
    
    # Restart PgBouncer if it's running
    if systemctl is-active --quiet $PGBOUNCER_SERVICE; then
        log_message "Restarting PgBouncer service"
        systemctl restart $PGBOUNCER_SERVICE
        
        # Verify PgBouncer is running after restart
        if systemctl is-active --quiet $PGBOUNCER_SERVICE; then
            log_message "PgBouncer service restarted successfully"
        else
            log_message "ERROR: PgBouncer service failed to restart"
            exit 1
        fi
    else
        log_message "PgBouncer service is not running, not attempting restart"
    fi
fi

# Clean up
rm -f "$TEMP_USERLIST"

log_message "PgBouncer userlist update completed successfully"

exit 0
