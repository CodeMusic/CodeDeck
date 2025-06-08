#!/bin/bash

# CodeDeck Service Installation Script
# Sets up the CodeDeck Neural Interface as a system service

set -e

echo "🔧 Installing CodeDeck Neural Interface as System Service"
echo "========================================================="

# Check if running as root or with sudo
if [[ $EUID -eq 0 ]]; then
    echo "✅ Running with administrative privileges"
else
    echo "❌ This script needs to be run with sudo"
    echo "Usage: sudo ./install_service.sh"
    exit 1
fi

# Get the actual user (in case running with sudo)
ACTUAL_USER="${SUDO_USER:-codemusic}"
echo "👤 Setting up service for user: $ACTUAL_USER"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_FILE="$SCRIPT_DIR/codedeck.service"

# Check if service file exists
if [ ! -f "$SERVICE_FILE" ]; then
    echo "❌ Service file not found: $SERVICE_FILE"
    exit 1
fi

# Stop service if it's already running
echo "🛑 Stopping existing service if running..."
systemctl stop codedeck 2>/dev/null || true
systemctl disable codedeck 2>/dev/null || true

# Copy service file to systemd directory
echo "📋 Installing service file..."
cp "$SERVICE_FILE" /etc/systemd/system/

# Set proper permissions
chmod 644 /etc/systemd/system/codedeck.service

# Reload systemd daemon
echo "🔄 Reloading systemd daemon..."
systemctl daemon-reload

# Enable the service (auto-start on boot)
echo "⚡ Enabling auto-start on boot..."
systemctl enable codedeck

# Start the service
echo "🚀 Starting CodeDeck service..."
systemctl start codedeck

# Wait a moment for startup
sleep 3

# Check service status
echo "📊 Checking service status..."
if systemctl is-active --quiet codedeck; then
    echo "✅ CodeDeck service is running successfully!"
    echo ""
    echo "📡 Service Information:"
    echo "   Status: $(systemctl is-active codedeck)"
    echo "   Enabled: $(systemctl is-enabled codedeck)"
    echo "   URL: http://localhost:8000"
    echo "   Web UI: http://localhost:8000/ui"
    echo ""
    echo "🔧 Service Management Commands:"
    echo "   Status:  sudo systemctl status codedeck"
    echo "   Stop:    sudo systemctl stop codedeck"
    echo "   Start:   sudo systemctl start codedeck"
    echo "   Restart: sudo systemctl restart codedeck"
    echo "   Logs:    sudo journalctl -u codedeck -f"
    echo ""
    echo "🎉 Installation complete! CodeDeck will now start automatically on boot."
else
    echo "❌ Service failed to start. Checking logs..."
    echo ""
    echo "📋 Recent logs:"
    journalctl -u codedeck -n 20 --no-pager
    echo ""
    echo "🔍 Check the logs with: sudo journalctl -u codedeck -f"
    exit 1
fi 