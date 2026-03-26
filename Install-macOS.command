#!/usr/bin/env bash
# Universal Rclone Mount Manager - 1-Click Installer (macOS)
# Double-click this file in Finder to automatically install
# rclone, macFUSE, and configure background mounting.

# Get the script directory regardless of where it was launched from
cd "$(dirname "$0")"

echo ""
echo "======================================================="
echo "   Installing Universal Rclone Mount Manager (macOS)"
echo "======================================================="
echo ""

# Ensure the main script is executable
chmod +x ./mount-gdrive.sh

# Run the installer process which handles dependencies, config generation, and launchd
./mount-gdrive.sh -a install --watchdog

echo ""
echo "======================================================="
echo " Installation Complete!"
echo " Your cloud drive will now mount automatically at logon."
echo ""
echo " If you see a macFUSE Security prompt, please allow the "
echo " kernel extension in System Settings -> Privacy & Security."
echo " You may close this terminal window."
echo "======================================================="
