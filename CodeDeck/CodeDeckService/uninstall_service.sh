#!/bin/bash

# CodeDeck Service Uninstall Script
# Removes the CodeDeck Neural Interface system service

set -e

echo "🗑️  Uninstalling CodeDeck Neural Interface Service"
echo "================================================="

# Check if running as root or with sudo
if [[ $EUID -eq 0 ]]; then
    echo "✅ Running with administrative privileges"
else
    echo "❌ This script needs to be run with sudo"
    echo "Usage: sudo ./uninstall_service.sh"
    exit 1
fi

# Stop the service
echo "🛑 Stopping CodeDeck service..."
systemctl stop codedeck 2>/dev/null || echo "   Service was not running"

# Disable the service
echo "⚡ Disabling auto-start..."
systemctl disable codedeck 2>/dev/null || echo "   Service was not enabled"

# Remove service file
echo "🗂️  Removing service file..."
rm -f /etc/systemd/system/codedeck.service

# Reload systemd daemon
echo "🔄 Reloading systemd daemon..."
systemctl daemon-reload

# Reset failed state
systemctl reset-failed codedeck 2>/dev/null || true

echo ""
echo "✅ CodeDeck service has been uninstalled successfully!"
echo ""
echo "📝 Note: This only removes the service installation."
echo "   Your CodeDeck files and virtual environment remain intact."
echo "   You can still run manually with: ./run.sh"
echo "" 