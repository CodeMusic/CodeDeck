#!/bin/bash
echo "📊 Detecting total RAM..."
total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
total_ram_gb=$(awk "BEGIN { printf \"%.2f\", $total_ram_kb / 1024 / 1024 }")

echo "🧠 You have $total_ram_gb GB RAM"

# Choose ZRAM % and fallback swap size based on precise RAM
if (( $(echo "$total_ram_gb >= 7.5" | bc -l) )); then
    zram_percent=50
    fallback_swap_size="2G"
else
    zram_percent=70
    fallback_swap_size="1G"
fi

echo "⚙️ Setting up ZRAM at ${zram_percent}% of total RAM..."

# Install zram-tools
sudo apt update
sudo apt install -y zram-tools

# Configure ZRAM
zramswap_conf="/etc/default/zramswap"
if [ ! -f "$zramswap_conf" ]; then
    echo "# ZRAM swap configuration" | sudo tee "$zramswap_conf"
fi

if grep -q "^PERCENTAGE=" "$zramswap_conf"; then
    sudo sed -i "s/^PERCENTAGE=.*/PERCENTAGE=$zram_percent/" "$zramswap_conf"
else
    echo "PERCENTAGE=$zram_percent" | sudo tee -a "$zramswap_conf"
fi

sudo systemctl restart zramswap

# Set vm.swappiness (encourages zram usage before fallback)
echo "🧪 Setting vm.swappiness to 80..."
echo "vm.swappiness=80" | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl -p /etc/sysctl.d/99-swappiness.conf

# Create fallback swapfile
echo "💾 Creating fallback swapfile at /swapfile (${fallback_swap_size})..."
sudo swapoff /swapfile 2>/dev/null
sudo rm -f /swapfile
sudo fallocate -l $fallback_swap_size /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Ensure fallback swap is persistent
if ! grep -qE "^\s*/swapfile\s+" /etc/fstab; then
    echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab
fi

# Final status report
echo "✅ All done! Current swap setup:"
swapon --show

echo -e "\n📊 Memory Snapshot:"
free -h

echo -e "\n🎉 ZRAM (${zram_percent}%) is active, with a ${fallback_swap_size} fallback swapfile."