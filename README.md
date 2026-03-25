# Optimized Rclone Mount for Windows 11

This package provides a robust, optimized method to mount Google Drive (or other cloud remotes) on Windows 11 using `rclone`. It's designed as a full-featured mount manager, providing features like a status dashboard, watchdog scheduling, multi-remote JSON config support, and bandwidth limits.

## Features

- **Multi-Remote JSON Config**: Support mounting multiple remotes from a single JSON configuration file.
- **Task Scheduler Integration**: Install an auto-start at logon and a recurring watchdog to ensure remounts if rclone dies.
- **Status Dashboard**: View a live dashboard detailing mount states, PID, uptime, RAM cache usage, and recent log tail.
- **Log Rotation**: Logs are automatically rotated once they exceed 5MB.
- **Bandwidth Limits**: Define robust bandwidth limits and schedules natively.
- **Windows Toast Notifications**: Best-effort system tray notifications on successful mounts and unmounts.
- **State Reset & Anomaly Clearance**: Automatically detects and gracefully terminates any hanging `rclone` processes.
- **Zero-I/O Latency Initialization**: Highly optimized VFS cache settings tailored for performance, large file handling, and API rate limiting.

## Usage

### Using the Executable (Recommended)

You can compile the included `installer.nsi` script into an executable (requires [NSIS](https://nsis.sourceforge.io/Download)). Once compiled, simply double-click `Rclone-Optimized.exe`.

The executable will silently install the necessary scripts to `%LOCALAPPDATA%\RcloneMountManager`, create a Desktop shortcut for easy manual remounts, execute them, and automatically establish your optimized `rclone` mount on the `X:` drive based on the default `Mount` action.

*Note: You must have `rclone.exe` installed and available in your system's PATH, and a remote named `gdrive` configured.*

### Manual Execution

If you prefer to interact with the manager's advanced features manually, open an elevated PowerShell prompt in `%LOCALAPPDATA%\RcloneMountManager`:

```powershell
# Default mount of 'gdrive' on X:
.\Mount-GDrive.ps1

# Mount a specific remote with watchdog
.\Mount-GDrive.ps1 -Remote onedrive -MountPoint Y: -Watchdog

# Install scheduled tasks to run at logon
.\Mount-GDrive.ps1 -Action Install -Watchdog -WatchdogInterval 3

# View the live status dashboard
.\Mount-GDrive.ps1 -Action Status

# Gracefully unmount and clear caches
.\Mount-GDrive.ps1 -Action Unmount
```

## Logs & Cache

Mount logs and caches are saved to `C:\RcloneCache` for troubleshooting and performance persistence.
