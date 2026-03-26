# Universal Rclone Mount Manager

This package provides a robust, optimized method to mount Google Drive (or other cloud remotes) using `rclone`. It supports Windows 11 (x86/ARM), macOS (Intel/Apple Silicon), and Linux (x86/ARM64). It acts as a full-featured mount manager with features like a status dashboard, watchdog scheduling, and bandwidth limits.

## Features

- **Cross-Platform**: Support for Windows (PowerShell/NSIS), macOS (Bash/launchd), and Linux (Bash/systemd). Fully supports ARM architectures like Apple Silicon and Raspberry Pi.
- **Auto-Start & Watchdog**: Install an auto-start mechanism at boot/logon and a recurring watchdog to ensure remounts if the rclone process crashes.
- **Multi-Remote JSON Config** (Windows): Support mounting multiple remotes from a single JSON configuration file.
- **Status Dashboard**: View a live dashboard detailing mount states, PID, uptime, RAM cache usage, and recent log tail.
- **Log Rotation**: Logs are automatically rotated once they exceed 5MB.
- **Bandwidth Limits**: Define robust bandwidth limits and schedules natively.
- **Windows Toast Notifications**: Best-effort system tray notifications on successful mounts and unmounts.
- **State Reset & Anomaly Clearance**: Automatically detects and gracefully terminates any hanging `rclone` processes.
- **Zero-I/O Latency Initialization**: Highly optimized VFS cache settings tailored for performance, large file handling, and API rate limiting.

## Windows Usage

### Using the Executable (Recommended)

You can compile the included `installer.nsi` script into an executable (requires [NSIS](https://nsis.sourceforge.io/Download)). Windows 11 ARM64 users can simply run the generated x86 installer as it runs perfectly via native emulation. Once compiled, simply double-click `Rclone-Optimized.exe`.

The executable will silently install the necessary scripts to `%LOCALAPPDATA%\RcloneMountManager`, create a Desktop shortcut for easy manual remounts, execute them, and automatically establish your optimized `rclone` mount on the `X:` drive based on the default `Mount` action.

*Note: You must have `rclone.exe` installed and available in your system's PATH, and a remote named `gdrive` configured.*

### Manual Execution

If you prefer to interact with the manager's advanced features manually, open an elevated PowerShell prompt in `%LOCALAPPDATA%\RcloneMountManager`:

```powershell
# Default mount of 'gdrive' on X:
.\Mount-GDrive.ps1

# Install scheduled tasks to run at logon with Watchdog
.\Mount-GDrive.ps1 -Action Install -Watchdog

# View the live status dashboard
.\Mount-GDrive.ps1 -Action Status
```

## macOS & Linux Usage

A cross-platform Bash script (`mount-gdrive.sh`) is provided for macOS (Intel/Apple Silicon ARM) and Linux (x86/ARM64). It automatically detects the OS and handles FUSE/macFUSE dependencies, `systemd` user services (Linux), and `launchd` agents (macOS).

*Note: You must have `rclone` installed and a remote named `gdrive` configured. On Linux, `fuse3` must be installed. On macOS, `macfuse` must be installed.*

### Commands

Make the script executable: `chmod +x mount-gdrive.sh`

```bash
# Default mount of 'gdrive' to ~/gdrive (macOS) or /mnt/gdrive (Linux)
./mount-gdrive.sh -a mount

# Mount a specific remote to a custom path
./mount-gdrive.sh -r onedrive -m ~/onedrive -a mount

# Install an auto-start service with Watchdog (systemd/launchd)
./mount-gdrive.sh -a install --watchdog

# View the live status dashboard
./mount-gdrive.sh -a status

# Gracefully unmount and clear caches
./mount-gdrive.sh -a unmount
```

## Logs & Cache

Mount logs and caches are saved to `C:\RcloneCache` for troubleshooting and performance persistence.
