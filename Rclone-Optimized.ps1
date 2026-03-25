$MountPoint = "X:"
$CachePath  = "C:\RcloneCache"
$LogPath    = "$CachePath\mount.log"
$OldVfsPath = "$env:LOCALAPPDATA\rclone\vfs"

# State Reset & Anomaly Clearance
$ActiveProcesses = Get-Process -Name "rclone" -ErrorAction SilentlyContinue
if ($ActiveProcesses) { Stop-Process -Name "rclone" -Force; Start-Sleep -Seconds 3 }

# Aggressive VFS Purge
if (Test-Path $OldVfsPath) { Remove-Item -Path "$OldVfsPath\*" -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path "$CachePath\vfs") { Remove-Item -Path "$CachePath\vfs\*" -Recurse -Force -ErrorAction SilentlyContinue }
if (-not (Test-Path $CachePath)) { New-Item -ItemType Directory -Force -Path $CachePath | Out-Null }

# Hardware Lock Audit
if (Test-Path $MountPoint) { Write-Error "CRITICAL: Mount point $MountPoint is locked."; Exit 1 }

# Zero-I/O Latency Initialization
Start-Process -WindowStyle Hidden -FilePath "rclone" -ArgumentList "mount gdrive: $MountPoint --vfs-cache-mode writes --cache-dir `"$CachePath`" --buffer-size 256M --vfs-read-ahead 256M --dir-cache-time 8760h --attr-timeout 8760h --vfs-fast-fingerprint --tpslimit 10 --log-level INFO --log-file `"$LogPath`""
