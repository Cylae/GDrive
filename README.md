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

### ⚡ Under the Hood: Performance Optimizations
These scripts configure `rclone` mounts with highly optimized flags designed for API-limit avoidance and streaming:
- **`--vfs-read-chunk-size 128M`** & **`--vfs-read-chunk-size-limit off`**: Significantly reduces API rate limits when streaming media by pulling massive chunks dynamically instead of tiny 16MB slivers.
- **`--vfs-read-ahead 128M`**: Buffers the next 128MB of the file proactively into RAM, eliminating stutter in high-bitrate playback.
- **`--tpslimit 10`** & **`--tpslimit-burst 20`**: Imposes a hard cap on API queries to prevent cloud providers (like Google Drive) from issuing 24-hour rate limit bans, while allowing small bursts for directory browsing.

---

## 📦 Zero-Touch Prerequisites (Auto-Install)

The suite is designed for a **100% zero-touch deployment**. If any underlying dependencies (`rclone`, `WinFsp`, `macFUSE`, `fuse3`, or `python3`) are missing, the scripts will automatically fetch and install the latest versions directly from the official sources before continuing.

**Auto-Installation Mechanisms:**
- **Windows**: Automatically utilizes `winget` to pull `Rclone.Rclone` and `WinFsp.WinFsp`.
- **macOS**: Automatically installs Homebrew (if missing), then `brew install rclone macfuse python`. *(Note: `macFUSE` requires manual kernel extension approval in System Settings > Security).*
- **Linux**: Automatically utilizes `apt-get`, `dnf`, `pacman`, or the official `curl` bash scripts depending on your distribution.

*Just run the scripts; they handle the rest.*

---

## ⚙️ Compiling Assembly Launchers (Optional)

For absolute minimal footprint and speed, this project includes lightweight Assembly language wrappers for both Windows and Linux. These wrappers act as silent executors for the underlying scripts and compile to tiny binaries (~1-3KB).

You can compile them on any machine with `nasm` and `mingw-w64` installed:

```bash
make
```

- **Linux**: Produces `RcloneMount-Linux`. This is a lightweight x86_64 ELF binary that safely forwards CLI arguments directly to `mount-gdrive.sh` via the `execve` syscall.
- **Windows**: Produces `RcloneMount-Windows.exe`. This is a lightweight x86 PE32 binary that silently invokes `Mount-GDrive.ps1` in the background via the Windows API `WinExec`.

---

## 🖥️ Windows Usage

### The NSIS Installer `.exe` (Recommended)

To compile the `installer.nsi` script into an executable, you need [NSIS](https://nsis.sourceforge.io/Download).
*(Note: Windows 11 ARM64 users can compile and run the generated x86 installer as Windows emulates it natively).*

Once compiled, simply double-click `Rclone-Optimized.exe`. It will silently install the PowerShell scripts into `%LOCALAPPDATA%\RcloneMountManager`, place a `Run-Rclone.bat` shortcut on your Desktop, and immediately mount your default `gdrive` to `X:`.

**Network Drive Discovery:** The rclone mount acts as a true Windows Network Location and will immediately appear under "This PC". You can also map it to any letter or browse to it via "Add Network Location" if desired.

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

## 🛠️ Troubleshooting

- **Error 0x8007045D (Windows I/O Device Error)**: This occurs when Windows Explorer treats a FUSE mount as a physical local disk and tries to probe file attributes it doesn't support while copying or creating folders. The scripts now natively enforce `--network-mode` to mount as a mapped network drive, which mitigates this bug. If you still encounter it, ensure your local VFS cache drive (e.g., `C:\`) is not genuinely failing or out of space.
- **macOS macFUSE Kext Errors**: Newer versions of macOS strongly restrict kernel extensions. If the script hangs or rclone fails to mount, go to `System Settings` > `Privacy & Security` > `Security` and click "Allow" for "macFUSE". You may need to reboot into Recovery Mode and lower the security policy to "Reduced Security" for kernel extensions to load.
- **Linux systemd user services**: The auto-start services on Linux run under `systemctl --user`. If your mounts don't start at boot until you log in, you must enable lingering for your user account: `sudo loginctl enable-linger $USER`.
- **Cache Drive Full**: The script enforces a strict 5GB minimum free space check to prevent `rclone` from writing a bad cache loop that soft-bricks your OS drive. You can increase or decrease this limit in the script directly (`assert_disk_space`).

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
