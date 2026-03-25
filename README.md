# Optimized Rclone Mount for Windows 11

This package provides a robust, optimized method to mount Google Drive (or other cloud remotes) on Windows 11 using `rclone`. It's designed to minimize I/O latency, aggressively clear old caches, prevent hardware lockups, and ensure a seamless, hidden mount.

## Features

- **State Reset & Anomaly Clearance**: Automatically detects and gracefully terminates any hanging `rclone` processes to prevent conflicts before mounting.
- **Aggressive VFS Purge**: Clears out old Virtual File System (VFS) caches to ensure you're working with fresh metadata and to prevent disk bloat.
- **Hardware Lock Audit**: Checks if the desired mount point (default `X:`) is already locked or in use, preventing critical mounting failures.
- **Zero-I/O Latency Initialization**: Launches the `rclone` mount using highly optimized VFS cache settings:
  - `--vfs-cache-mode writes`: Caches file writes locally before uploading.
  - `--buffer-size 256M` & `--vfs-read-ahead 256M`: Allocates generous memory buffers for smooth playback and transfers.
  - `--dir-cache-time 8760h`: Caches directory structures for up to a year to drastically reduce API calls.
  - `--vfs-fast-fingerprint`: Uses fast file hashing for quicker change detection.
  - `--tpslimit 10`: Rate limits transactions to avoid API bans.

## Usage

### Using the Executable (Recommended)

You can compile the included `installer.nsi` script into an executable (requires [NSIS](https://nsis.sourceforge.io/Download)). Once compiled, simply double-click `Rclone-Optimized.exe`.

The executable will silently extract the necessary scripts, execute them, and automatically establish your optimized `rclone` mount on the `X:` drive.

*Note: You must have `rclone.exe` installed and available in your system's PATH, and a remote named `gdrive` configured.*

### Manual Execution

If you prefer to run the scripts manually:
1. Double-click `Run-Rclone.bat`. This acts as a wrapper to launch the PowerShell script silently while bypassing execution policies.
2. Alternatively, you can run the `Rclone-Optimized.ps1` script directly from an elevated PowerShell prompt.

## Logs

Mount logs are saved to `C:\RcloneCache\mount.log` for troubleshooting.
