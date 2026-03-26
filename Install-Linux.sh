#!/usr/bin/env bash
# Universal Rclone Mount Manager - 1-Click Installer (Linux)
# Execute this script to automatically install dependencies,
# build the user systemd service, and start the background mount.

set -e

cd "$(dirname "$0")"

echo ""
echo "======================================================="
echo "   Installing Universal Rclone Mount Manager (Linux)"
echo "======================================================="
echo ""

chmod +x ./mount-gdrive.sh

# Run the installer process which handles dependencies, config generation, and systemd
./mount-gdrive.sh -a install --watchdog

echo ""
echo "======================================================="
echo " Installation Complete!"
echo " Your cloud drive will now mount automatically at logon."
echo ""
echo " For background operation after you log out, remember"
echo " to enable lingering for your user account:"
echo "    sudo loginctl enable-linger \$USER"
echo "======================================================="
