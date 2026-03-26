# Universal Rclone Mount Manager

A robust, enterprise-grade cloud storage mount manager leveraging `rclone`. It supports **Windows 11 (x86/ARM)**, **macOS (Intel/Apple Silicon)**, and **Linux (x86/ARM64)** natively.

This suite is designed for power users who require absolute stability, zero-I/O latency, large-file caching, auto-mounting at boot, and intelligent crash-recovery watchdogs.

---

## 🚀 Features

- **Cross-Platform**: Run the PowerShell/NSIS suite on Windows, or the unified Bash script on macOS/Linux. 100% feature parity.
- **Multi-Remote JSON Configuration**: Mount an arbitrary number of remotes (`gdrive`, `onedrive`, `s3`, etc.) using a single config file.
- **Auto-Start & Crash Watchdog**: Automatically mount your drives at system boot/logon. A background watchdog service checks for `rclone` crashes and auto-remounts seamlessly.
- **Status Dashboard**: A unified CLI command (`-Action Status`) provides a beautiful overview of all active mounts, PIDs, uptimes, RAM/disk cache usage, and recent log tailing.
- **Aggressive VFS Caching**: Zero-I/O latency. Uses `vfs-cache-mode full` for in-place editing, rapid seek, media playback buffering, and offline writes.
- **Anomaly Clearance & State Reset**: Automatically cleans up stale PID files, forcefully kills hanging `rclone` daemon threads, and clears old VFS cache chunks to prevent disk bloat.
- **Bandwidth Limits & Log Rotation**: Natively cap bandwidth and rotate log files automatically once they exceed 5MB.

---

## 📦 Prerequisites

### Windows
1. **[Rclone](https://rclone.org/downloads/)**: Must be in your system `PATH`.
2. **[WinFsp](https://winfsp.dev/rel/)**: Required by rclone to map drives.

### macOS (Intel & Apple Silicon)
1. **Rclone**: `brew install rclone`
2. **macFUSE**: `brew install --cask macfuse` (You may need to allow kernel extensions in macOS Security settings).
3. **Python 3**: Pre-installed on macOS, used to parse JSON configs.

### Linux (Ubuntu/Debian, CentOS, Raspberry Pi)
1. **Rclone**: `curl https://rclone.org/install.sh | sudo bash`
2. **FUSE3**: `sudo apt install fuse3`
3. **Python 3**: `sudo apt install python3`

---

## 🖥️ Windows Usage

### The NSIS Installer `.exe` (Recommended)

To compile the `installer.nsi` script into an executable, you need [NSIS](https://nsis.sourceforge.io/Download).
*(Note: Windows 11 ARM64 users can compile and run the generated x86 installer as Windows emulates it natively).*

Once compiled, simply double-click `Rclone-Optimized.exe`. It will silently install the PowerShell scripts into `%LOCALAPPDATA%\RcloneMountManager`, place a `Run-Rclone.bat` shortcut on your Desktop, and immediately mount your default `gdrive` to `X:`.

### Manual PowerShell Usage

Open an elevated PowerShell prompt to access advanced features:

```powershell
# Default mount of 'gdrive' on X:
.\Mount-GDrive.ps1

# Install an auto-start Task Scheduler entry + Crash Watchdog
.\Mount-GDrive.ps1 -Action Install -Watchdog

# Display the Status Dashboard
.\Mount-GDrive.ps1 -Action Status

# Unmount all active drives
.\Mount-GDrive.ps1 -Action Unmount
```

---

## 🍏🐧 macOS & Linux Usage

Ensure the script is executable before running:
```bash
chmod +x mount-gdrive.sh
```

### Basic Commands

```bash
# Mount the default 'gdrive' remote to ~/gdrive (macOS) or /mnt/gdrive (Linux)
./mount-gdrive.sh -a mount

# Mount a specific remote with a bandwidth limit
./mount-gdrive.sh -r onedrive -m ~/onedrive --bw-limit 10M -a mount

# Show the interactive Status Dashboard
./mount-gdrive.sh -a status

# Unmount all active drives gracefully
./mount-gdrive.sh -a unmount
```

### Auto-Start Service & Watchdog Integration

You can register the script to run automatically in the background using native system services (`systemd` for Linux, `launchd` for macOS).

```bash
# Install the system service and enable the crash watchdog
./mount-gdrive.sh -a install --watchdog

# Uninstall the system services completely
./mount-gdrive.sh -a uninstall
```

---

## ⚙️ Multi-Remote JSON Configuration

For power users with multiple cloud drives, you can use a single `config.json` file to dictate all mounting behavior.

1. Generate a starter config by running:
   - Windows: `.\Mount-GDrive.ps1 -Action Install`
   - Mac/Linux: `./mount-gdrive.sh -a install`
2. Edit the generated `config.json` located in `~/.rcloneCache/config.json` (Mac/Linux) or `C:\RcloneCache\config.json` (Windows).

### Example `config.json`

```json
{
  "remotes": [
    {
      "name": "gdrive",
      "mountPoint": "/mnt/gdrive",
      "enabled": true
    },
    {
      "name": "dropbox",
      "mountPoint": "/mnt/dropbox",
      "enabled": true
    }
  ],
  "cachePath": "/home/user/.rcloneCache",
  "vfsCacheMode": "full",
  "cacheMaxSize": "50G",
  "bufferSize": "256M",
  "driveChunkSize": "128M",
  "bwLimit": "0",
  "watchdog": true,
  "watchdogIntervalMinutes": 2
}
```

Once edited, load it manually or install it into the service manager:
```bash
./mount-gdrive.sh --config-file ~/.rcloneCache/config.json -a mount
```
