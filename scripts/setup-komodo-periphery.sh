#!/bin/bash

# Exit on any error
set -e

# Define variables
SERVICE_FILE="/etc/systemd/system/periphery.service"
USER_NAME="komodo-periphery"
USER_LINE="User=$USER_NAME"
SETUP_URL="https://raw.githubusercontent.com/mbecker20/komodo/main/scripts/setup-periphery.py"  # Updated to match script source
CONFIG_DIR="/etc/komodo"
REPO_DIR="$CONFIG_DIR/repos"
STACK_DIR="$CONFIG_DIR/stacks"

# Function to check if a command succeeded
check_status() {
    if [ $? -ne 0 ]; then
        echo "Error: $1 failed. Exiting."
        exit 1
    fi
}

# Step 1: Create the komodo-periphery user if it doesn’t exist
if ! id "$USER_NAME" >/dev/null 2>&1; then
    echo "Creating system user: $USER_NAME..."
    sudo useradd -r -s /bin/false "$USER_NAME"
    check_status "User creation"
else
    echo "User $USER_NAME already exists."
fi

# Step 2: Add user to docker group
if ! groups "$USER_NAME" | grep -q docker; then
    echo "Adding $USER_NAME to docker group..."
    sudo usermod -aG docker "$USER_NAME"
    check_status "Adding user to docker group"
else
    echo "$USER_NAME is already in the docker group."
fi

# Step 3: Set up additional directories (optional for repos/stacks)
for dir in "$REPO_DIR" "$STACK_DIR"; do
    if [ ! -d "$dir" ]; then
        echo "Creating optional directory: $dir (for repos/stacks)..."
        sudo mkdir -p "$dir"
        check_status "Directory creation ($dir)"
    fi
    echo "Setting permissions for $dir..."
    sudo chown "$USER_NAME:$USER_NAME" "$dir"
    sudo chmod 750 "$dir"
    check_status "Setting permissions ($dir)"
done

# Step 4: Run setup-periphery.py (system-wide install)
echo "Fetching and running setup-periphery.py from $SETUP_URL..."
curl -sSL "$SETUP_URL" | python3
check_status "Komodo Periphery setup script execution"

# Step 5: Modify the service file to run as komodo-periphery
if [ ! -f "$SERVICE_FILE" ]; then
    echo "Error: $SERVICE_FILE not found after setup. Check setup-periphery.py output."
    exit 1
fi

if grep -q "^User=" "$SERVICE_FILE"; then
    echo "Updating existing User= line in $SERVICE_FILE..."
    sudo sed -i "s/^User=.*/$USER_LINE/" "$SERVICE_FILE"
    check_status "Updating User= line"
else
    if grep -q "^\[Service\]" "$SERVICE_FILE"; then
        echo "Adding $USER_LINE to $SERVICE_FILE..."
        sudo sed -i "/^\[Service\]/a $USER_LINE" "$SERVICE_FILE"
        check_status "Adding User= line"
    else
        echo "Error: [Service] section not found in $SERVICE_FILE."
        exit 1
    fi
fi

# Step 6: Reload systemd and restart the service
echo "Reloading systemd and restarting periphery..."
sudo systemctl daemon-reload
sudo systemctl restart periphery
check_status "Service restart"

# Step 7: Verify the service is running as the correct user
sleep 2  # Wait for the service to start
if ps -u "$USER_NAME" | grep -q "periphery"; then
    echo "Success: Periphery is running as $USER_NAME."
    systemctl status periphery | grep "Active:"
else
    echo "Warning: Service may not be running as $USER_NAME."
    echo "Check status with: systemctl status periphery"
    echo "Check logs with: journalctl -u periphery"
    exit 1
fi

# Step 8: Optional security hardening (uncomment to enable)
# echo "Hardening network access (allowing port 8120 from specific IP)..."
# sudo ufw allow from <komodo-core-ip> to any port 8120
# sudo ufw deny 8120
# check_status "Firewall configuration"

echo "Komodo Periphery setup complete. Re-run this script to update binaries."
exit 0
