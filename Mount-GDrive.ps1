#Requires -Version 5.1
<#
.SYNOPSIS
    Universal rclone cloud storage mount manager — multi-remote, watchdog, auto-start.

.DESCRIPTION
    Full-featured mount manager for any rclone remote (Google Drive, OneDrive, S3…).
    Supports multi-remote mounting from a JSON config, auto-start at logon,
    watchdog auto-remount via Task Scheduler, bandwidth limiting, log rotation,
    Windows toast notifications, and a live status dashboard.

.PARAMETER Action
    Mount      – Mount all enabled remotes (default)
    Unmount    – Gracefully stop rclone and release drive letters
    Status     – Dashboard: mount state, PID, uptime, cache usage, recent logs
    Restart    – Unmount then remount
    Install    – Register auto-mount (at logon) + optional watchdog as scheduled tasks
    Uninstall  – Remove all registered scheduled tasks

.PARAMETER Remote
    rclone remote name as defined in rclone.conf (default: gdrive).
    Ignored when -ConfigFile is used.

.PARAMETER MountPoint
    Target drive letter, e.g. X: (default: X:).
    Ignored when -ConfigFile is used.

.PARAMETER CachePath
    Root directory for VFS cache, PID files, and logs (default: C:\RcloneCache).

.PARAMETER VfsCacheMode
    off | minimal | writes | full (default: full).
    'full' supports seek, random-read, media playback, and in-place editing.

.PARAMETER BufferSize
    Per-file in-memory read-ahead buffer (default: 128M).
    Increase to 256M on high-RAM machines for large sequential reads.

.PARAMETER DriveChunkSize
    Google Drive upload chunk size (default: 128M). Must be a power of 2 (256K-1G).

.PARAMETER BwLimit
    Bandwidth cap. 0 = unlimited. Examples:
      "10M"                   – 10 MB/s cap, always
      "10M:5M"                – 10 MB/s up, 5 MB/s down
      "08:00,10M 22:00,0"     – 10M from 8am, unlimited from 10pm

.PARAMETER CacheMaxSize
    Maximum VFS disk cache size (default: 20G). Eviction happens automatically.

.PARAMETER ConfigFile
    Path to a JSON config file. Overrides all other parameters.
    A starter config is auto-generated on first 'Install' run.

.PARAMETER Watchdog
    Also register a repeating scheduled task that auto-remounts if rclone dies.

.PARAMETER WatchdogInterval
    Minutes between watchdog health checks (default: 2, minimum: 1).

.PARAMETER Silent
    Suppress all console output. Ideal for scheduled task invocations.

.PARAMETER NoToast
    Disable Windows toast notifications.

.EXAMPLE
    .\Mount-GDrive.ps1
    .\Mount-GDrive.ps1 -BwLimit "20M" -Watchdog
    .\Mount-GDrive.ps1 -Remote onedrive -MountPoint Y: -VfsCacheMode writes
    .\Mount-GDrive.ps1 -Action Install -Watchdog -WatchdogInterval 3
    .\Mount-GDrive.ps1 -Action Status
    .\Mount-GDrive.ps1 -Action Unmount
    .\Mount-GDrive.ps1 -ConfigFile "C:\RcloneCache\config.json"
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [ValidateSet("Mount", "Unmount", "Status", "Restart", "Install", "Uninstall")]
    [string] $Action           = "Mount",

    [string] $Remote           = "gdrive",
    [string] $MountPoint       = "X:",
    [string] $CachePath        = "C:\RcloneCache",

    [ValidateSet("off", "minimal", "writes", "full")]
    [string] $VfsCacheMode     = "full",

    [string] $BufferSize       = "128M",
    [string] $DriveChunkSize   = "128M",
    [string] $BwLimit          = "0",
    [string] $CacheMaxSize     = "20G",

    [string] $ConfigFile       = "",

    [switch] $Watchdog,
    [int]    $WatchdogInterval = 2,

    [switch] $Silent,
    [switch] $NoToast
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ScriptPath            = $MyInvocation.MyCommand.Path

# ══════════════════════════════════════════════════════════════════════════════
#  Constants
# ══════════════════════════════════════════════════════════════════════════════
$TASK_MOUNT    = "RcloneMount_AutoMount"
$TASK_WATCHDOG = "RcloneMount_Watchdog"
$LOG_MAX_BYTES = 5MB   # rotate when log exceeds 5 MB
$LOG_KEEP      = 3     # number of rotated archives to keep


# ══════════════════════════════════════════════════════════════════════════════
#  Console logging
# ══════════════════════════════════════════════════════════════════════════════
function Write-Log {
    param([string] $Level, [string] $Message)
    if ($Silent) { return }
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "OK"    { "Green"  }
        "WARN"  { "Yellow" }
        "FAIL"  { "Red"    }
        "HEAD"  { "Cyan"   }
        default { $Host.UI.RawUI.ForegroundColor }
    }
    if ($Level -eq "HEAD") {
        Write-Host ""
        Write-Host "  -- $Message --" -ForegroundColor Cyan
    } else {
        Write-Host ("  [{0}] [{1}] {2}" -f $ts, $Level, $Message) -ForegroundColor $color
    }
}

# Polyfill for Windows PowerShell 5.1 which doesn't have $IsWindows
if ($null -eq $IsWindows) {
    $IsWindows = [bool]($PSVersionTable.Platform -eq "Win32NT" -or $PSVersionTable.Platform -eq $null)
}

# ══════════════════════════════════════════════════════════════════════════════
#  JSON config support
# ══════════════════════════════════════════════════════════════════════════════
function Get-Config {
    if (-not $ConfigFile -or -not (Test-Path $ConfigFile)) { return $null }
    try {
        $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        Write-Log "OK" "Config loaded: $ConfigFile"
        return $cfg
    } catch {
        Write-Log "FAIL" "Cannot parse config file: $_"
        exit 1
    }
}

function Save-DefaultConfig {
    param([string] $Path)
    $template = [ordered]@{
        "_comment"   = "Edit this file, then run: .\Mount-GDrive.ps1 -ConfigFile config.json"
        remotes      = @(
            [ordered]@{ name = "gdrive";   mountPoint = "X:"; enabled = $true  }
            [ordered]@{ name = "onedrive"; mountPoint = "Y:"; enabled = $false }
        )
        cachePath               = $CachePath
        vfsCacheMode            = "full"
        cacheMaxSize            = "20G"
        bufferSize              = "128M"
        driveChunkSize          = "128M"
        bwLimit                 = "0"
        watchdog                = $false
        watchdogIntervalMinutes = 2
    }
    $template | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
    Write-Log "OK" "Starter config written: $Path"
    Write-Log "INFO" "Edit the 'remotes' array, then re-run with -Action Install."
}


# ══════════════════════════════════════════════════════════════════════════════
#  Windows toast notification (best-effort, failure is swallowed silently)
# ══════════════════════════════════════════════════════════════════════════════
function Send-Toast {
    param([string] $Title, [string] $Body)
    if ($NoToast) { return }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

        $appId  = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
        $xml    = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
                      [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes  = $xml.GetElementsByTagName("text")
        $nodes[0].AppendChild($xml.CreateTextNode($Title)) | Out-Null
        $nodes[1].AppendChild($xml.CreateTextNode($Body))  | Out-Null
        $toast  = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch { <# Toast is always best-effort #> }
}


# ══════════════════════════════════════════════════════════════════════════════
#  Log rotation
# ══════════════════════════════════════════════════════════════════════════════
function Invoke-LogRotation {
    param([string] $LogFile)
    if (-not (Test-Path $LogFile)) { return }
    if ((Get-Item $LogFile).Length -lt $LOG_MAX_BYTES) { return }

    Write-Log "INFO" "Rotating log (exceeds $([math]::Round($LOG_MAX_BYTES/1MB))MB)..."

    for ($i = $LOG_KEEP; $i -ge 1; $i--) {
        $old = "$LogFile.$i"
        $new = "$LogFile.$($i + 1)"
        if (Test-Path $old) {
            if ($i -eq $LOG_KEEP) { Remove-Item $old -Force }
            else { Rename-Item $old $new -Force }
        }
    }
    Rename-Item $LogFile "$LogFile.1" -Force
}


# ══════════════════════════════════════════════════════════════════════════════
#  Prerequisites: rclone + WinFsp (Auto-Installer)
# ══════════════════════════════════════════════════════════════════════════════
function Assert-Prerequisites {
    Write-Log "HEAD" "Prerequisites"

    $needsRestart = $false

    # 1. Rclone
    if (-not (Get-Command "rclone" -ErrorAction SilentlyContinue)) {
        Write-Log "WARN" "rclone not found. Attempting auto-installation via winget..."
        Start-Process winget -ArgumentList "install --exact Rclone.Rclone --accept-source-agreements --accept-package-agreements --silent" -Wait -NoNewWindow

        # Refresh environment variables so powershell sees the new PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

        if (-not (Get-Command "rclone" -ErrorAction SilentlyContinue)) {
            Write-Log "FAIL" "rclone auto-install failed. Please install manually: https://rclone.org/downloads/"
            exit 1
        }
        $needsRestart = $true
    }
    $v = (& rclone version 2>&1 | Select-String "rclone v" | Select-Object -First 1).ToString().Trim()
    Write-Log "OK" "rclone -- $v"

    # 2. WinFsp
    $winfsp = Get-Service -Name "WinFsp*" -ErrorAction SilentlyContinue
    if (-not $winfsp) {
        Write-Log "WARN" "WinFsp service not found. Attempting auto-installation via winget..."
        Start-Process winget -ArgumentList "install --exact WinFsp.WinFsp --accept-source-agreements --accept-package-agreements --silent" -Wait -NoNewWindow

        $winfsp = Get-Service -Name "WinFsp*" -ErrorAction SilentlyContinue
        if (-not $winfsp) {
            Write-Log "FAIL" "WinFsp auto-install failed. Please install manually: https://winfsp.dev/rel/"
            exit 1
        }
        $needsRestart = $true
    }
    Write-Log "OK" "WinFsp -- $($winfsp.Name) [$($winfsp.Status)]"

    if ($needsRestart) {
        Write-Log "INFO" "Dependencies were just installed. You may need to restart your PowerShell session or computer for background mounting to work flawlessly."
    }
}


# ══════════════════════════════════════════════════════════════════════════════
#  Network connectivity check
# ══════════════════════════════════════════════════════════════════════════════
function Assert-NetworkConnectivity {
    Write-Log "HEAD" "Network"
    $ok = @("8.8.8.8", "1.1.1.1") |
          Where-Object { Test-Connection -ComputerName $_ -Count 1 -Quiet -ErrorAction SilentlyContinue } |
          Select-Object -First 1

    if (-not $ok) {
        Write-Log "FAIL" "No internet connectivity. Cannot reach remote storage."
        exit 1
    }
    Write-Log "OK" "Internet reachable (via $ok)."
}


# ══════════════════════════════════════════════════════════════════════════════
#  Disk space check (Optimized)
# ══════════════════════════════════════════════════════════════════════════════
function Assert-DiskSpace {
    param([string] $Path, [int] $RequiredGB = 5)

    $letter = (Split-Path -Qualifier $Path).TrimEnd(':')
    $drive  = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
    $freeGB = if ($drive -and $drive.Free) {
        [math]::Round($drive.Free / 1GB, 1)
    } elseif ($IsWindows) {
        $cim = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${letter}:'" -ErrorAction SilentlyContinue
        if ($cim -and $cim.FreeSpace) { [math]::Round($cim.FreeSpace / 1GB, 1) } else { 999 }
    } else {
        999
    }

    if ($freeGB -lt $RequiredGB) {
        Write-Log "WARN" "Low disk space on cache drive: ${freeGB}GB free (recommended >= ${RequiredGB}GB)."
    } else {
        Write-Log "OK" "Cache drive: ${freeGB}GB free."
    }
}


# ══════════════════════════════════════════════════════════════════════════════
#  Mount point availability (double-checked: PowerShell + CIM)
# ══════════════════════════════════════════════════════════════════════════════
function Assert-MountPointFree {
    param([string] $Letter)
    $clean = $Letter.TrimEnd(':')

    if (Get-PSDrive -Name $clean -ErrorAction SilentlyContinue) {
        Write-Log "FAIL" "$Letter is already in use. Choose another letter with -MountPoint."
        exit 1
    }
    if ($IsWindows) {
        $cim = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Letter'" -ErrorAction SilentlyContinue
        if ($cim) {
            Write-Log "FAIL" "$Letter is occupied (CIM DriveType: $($cim.DriveType)). Choose another letter."
            exit 1
        }
    }
    Write-Log "OK" "$Letter is free."
}


# ══════════════════════════════════════════════════════════════════════════════
#  Remote existence validation
# ══════════════════════════════════════════════════════════════════════════════
function Assert-RemoteExists {
    param([string] $Name)
    $list = & rclone listremotes 2>&1
    if ($list -notmatch "^${Name}:") {
        Write-Log "FAIL" "Remote '${Name}:' not found in rclone.conf."
        Write-Log "FAIL" "  Run 'rclone config' to add it, or check the name."
        exit 1
    }
    Write-Log "OK" "Remote '${Name}:' validated."
}


# ══════════════════════════════════════════════════════════════════════════════
#  VFS cache purge
# ══════════════════════════════════════════════════════════════════════════════
function Clear-VfsCache {
    param([string] $Cache)
    Write-Log "HEAD" "VFS Cache Purge"

    foreach ($p in @((Join-Path $env:LOCALAPPDATA "rclone\vfs"), (Join-Path $Cache "vfs"))) {
        if (Test-Path $p) {
            Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "OK" "Cleared: $p"
        }
    }
}


# ══════════════════════════════════════════════════════════════════════════════
#  Core: mount a single remote
#
#  Smart skip: if the drive letter is already live and the PID matches a running
#  rclone process, the function exits silently. This makes the function safe for
#  repeated calls from the watchdog scheduled task — no double-mounts ever.
# ══════════════════════════════════════════════════════════════════════════════
function Invoke-Mount {
    param(
        [string] $RemoteName,
        [string] $Letter,
        [string] $Cache,
        [string] $CacheMode,
        [string] $Buf,
        [string] $Chunk,
        [string] $BwLimitVal,
        [string] $MaxSize
    )

    $logFile = Join-Path $Cache "mount_${RemoteName}.log"
    $pidFile = Join-Path $Cache "rclone_${RemoteName}.pid"
    $letter  = $Letter.TrimEnd(':')

    # Already mounted and healthy? Skip silently (watchdog-safe).
    if (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue) {
        if (Test-Path $pidFile) {
            $savedPid = Get-Content $pidFile -ErrorAction SilentlyContinue
            $alive    = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
            if ($alive -and $alive.Name -eq "rclone") {
                Write-Log "OK" "[${RemoteName}] Already mounted on $Letter (PID $savedPid). Skipping."
                return
            }
        }
    }

    # Ensure cache directory exists
    if (-not (Test-Path $Cache)) {
        New-Item -ItemType Directory -Force -Path $Cache | Out-Null
    }

    Invoke-LogRotation -LogFile $logFile

    # Stop any stale rclone that still holds this mount
    if (Test-Path $pidFile) {
        $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($oldPid) {
            $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($oldProc -and $oldProc.Name -eq "rclone") {
                Write-Log "WARN" "Stopping stale rclone on $Letter (PID $oldPid)..."
                Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    Assert-MountPointFree -Letter $Letter
    Assert-RemoteExists   -Name $RemoteName

    # Build argument list
    #
    # --vfs-cache-mode full       Full read/write cache: seek, random-read, editing.
    # --vfs-cache-max-size        Hard cap; oldest entries evicted automatically.
    # --vfs-cache-max-age 24h     Evict cold entries after 1 day.
    # --vfs-write-back 5s         Flush dirty writes to the remote every 5 seconds.
    # --buffer-size               In-memory buffer per open file (sequential reads).
    # --vfs-read-ahead 128M       Lookahead for streaming / large file reads.
    # --drive-chunk-size          Upload chunk size. 128M = efficient parallel upload.
    # --dir-cache-time 72h        Directory listing TTL (fresh but not chatty).
    # --attr-timeout 1h           File attribute TTL.
    # --vfs-fast-fingerprint      size+mtime fingerprint (faster than full hash).
    # --transfers 4               Parallel file transfers.
    # --checkers 8                Parallel existence checks.
    # --tpslimit 10/--burst 20    API rate cap with burst allowance (avoids 429s).
    # --retries 5                 High-level retries on transient errors.
    # --low-level-retries 10      HTTP-level retries.
    # --poll-interval 60s         Refresh dir cache from remote periodically.
    # --stats 0                   Disable periodic stat dumps to the log file.

    $mountArgs = [System.Collections.Generic.List[string]]::new()
    $mountArgs.AddRange([string[]]@(
        "mount", "${RemoteName}:", $Letter,
        "--vfs-cache-mode",       $CacheMode,
        "--cache-dir",            $Cache,
        "--vfs-cache-max-size",   $MaxSize,
        "--vfs-cache-max-age",    "24h",
        "--vfs-write-back",       "5s",
        "--buffer-size",          $Buf,
        "--vfs-read-ahead",       "128M",
        "--vfs-read-chunk-size",  "128M",
        "--vfs-read-chunk-size-limit", "off",
        "--drive-chunk-size",     $Chunk,
        "--dir-cache-time",       "72h",
        "--attr-timeout",         "1h",
        "--vfs-fast-fingerprint",
        "--transfers",            "4",
        "--checkers",             "8",
        "--tpslimit",             "10",
        "--tpslimit-burst",       "20",
        "--retries",              "5",
        "--low-level-retries",    "10",
        "--poll-interval",        "60s",
        "--stats",                "0",
        "--network-mode",
        "--volname",              "$RemoteName",
        "--log-level",            "INFO",
        "--log-file",             $logFile
    ))

    if ($BwLimitVal -and $BwLimitVal -ne "0") {
        $mountArgs.AddRange([string[]]@("--bwlimit", $BwLimitVal))
    }

    Write-Log "HEAD" "Mounting ${RemoteName}: -> $Letter"
    Write-Log "INFO" "Cache mode   : $CacheMode  |  Max size: $MaxSize"
    Write-Log "INFO" "Buffer       : $Buf  |  Chunk: $Chunk"
    if ($BwLimitVal -ne "0") { Write-Log "INFO" "Bandwidth cap: $BwLimitVal" }
    Write-Log "INFO" "Log file     : $logFile"

    $proc = Start-Process `
        -FilePath     "rclone" `
        -ArgumentList $mountArgs.ToArray() `
        -WindowStyle  Hidden `
        -PassThru

    $proc.Id | Set-Content -Path $pidFile -Encoding UTF8

    Start-Sleep -Seconds 4

    if ($proc.HasExited) {
        Write-Log "FAIL" "rclone exited immediately (code: $($proc.ExitCode))."
        if (Test-Path $logFile) {
            Write-Host ""
            Write-Host "  -- Last log entries --" -ForegroundColor DarkGray
            Get-Content $logFile -Tail 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        exit 1
    }

    # Wait up to 20s for the drive letter to become visible in the shell
    # Fast polling loop (every 200ms) for snappy startup
    $timeout = 20000; $elapsed = 0; $mounted = $false
    while ($elapsed -lt $timeout) {
        if (Test-Path "$($Letter)\" -ErrorAction SilentlyContinue) { $mounted = $true; break }
        Start-Sleep -Milliseconds 200; $elapsed += 200
    }

    if ($mounted) {
        Write-Log "OK" "SUCCESS -- $Letter  |  PID: $($proc.Id)  |  Remote: ${RemoteName}:"
        Send-Toast -Title "Drive Mounted" -Body "${RemoteName}: -> $Letter (PID $($proc.Id))"
    } else {
        Write-Log "WARN" "$Letter not visible after $([math]::Round($timeout/1000))s. rclone (PID $($proc.Id)) is still running."
        Write-Log "WARN" "WinFsp may need a moment. Check: $logFile"
    }
}


# ══════════════════════════════════════════════════════════════════════════════
#  Unmount (all remotes, or one specific remote)
# ══════════════════════════════════════════════════════════════════════════════
function Invoke-Unmount {
    param([string] $Cache, [string] $RemoteName = "*")

    Write-Log "HEAD" "Unmounting"

    $filter   = if ($RemoteName -eq "*") { "rclone_*.pid" } else { "rclone_${RemoteName}.pid" }
    $pidFiles = Get-ChildItem -Path $Cache -Filter $filter -ErrorAction SilentlyContinue

    if (-not $pidFiles) {
        Write-Log "WARN" "No PID files found. Killing all rclone processes as fallback..."
        Stop-Process -Name "rclone" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Log "OK" "Done."
        return
    }

    foreach ($pf in $pidFiles) {
        $savedPid = Get-Content $pf.FullName -ErrorAction SilentlyContinue
        $rName    = $pf.BaseName -replace "^rclone_", ""
        if ($savedPid) {
            $proc = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
            if ($proc -and $proc.Name -eq "rclone") {
                Stop-Process -Id $savedPid -Force
                Write-Log "OK" "Stopped '${rName}' (PID $savedPid)."
                Send-Toast -Title "Drive Unmounted" -Body "${rName}: unmounted."
            } else {
                Write-Log "WARN" "'${rName}': no live rclone at PID $savedPid (already stopped?)."
            }
        }
        Remove-Item $pf.FullName -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}


# ══════════════════════════════════════════════════════════════════════════════
#  Status dashboard
# ══════════════════════════════════════════════════════════════════════════════
function Show-Status {
    param([string] $Cache)

    Write-Log "HEAD" "Mount Status"

    $pidFiles = Get-ChildItem -Path $Cache -Filter "rclone_*.pid" -ErrorAction SilentlyContinue
    if (-not $pidFiles) {
        Write-Log "WARN" "No active mounts found."
    } else {
        foreach ($pf in $pidFiles) {
            $savedPid = Get-Content $pf.FullName -ErrorAction SilentlyContinue
            $rName    = $pf.BaseName -replace "^rclone_", ""
            $proc     = Get-Process -Id $savedPid -ErrorAction SilentlyContinue

            if ($proc) {
                # StartTime can throw on some Unix platforms or for system processes, adding try/catch or simple check
                try {
                    $up = (Get-Date) - $proc.StartTime
                    $upStr = "{0}d {1:D2}h {2:D2}m" -f $up.Days, $up.Hours, $up.Minutes
                } catch {
                    $upStr = "Unknown"
                }
                $ramMB = [math]::Round($proc.WorkingSet64 / 1MB, 1)
                Write-Log "OK" "[${rName}]  PID: $savedPid  |  Uptime: $upStr  |  RAM: ${ramMB}MB"
            } else {
                Write-Log "WARN" "[${rName}]  PID $savedPid not found -- process may have crashed."
            }
        }
    }

    Write-Log "HEAD" "Cache"
    if (Test-Path $Cache) {
        $usedBytes = (Get-ChildItem $Cache -Recurse -File -ErrorAction SilentlyContinue |
                       Measure-Object -Property Length -Sum).Sum
        $usedMB    = [math]::Round($usedBytes / 1MB, 1)
        Write-Log "INFO" "Path : $Cache"
        Write-Log "INFO" "Used : ${usedMB}MB"
    }

    if ($IsWindows) {
        Write-Log "HEAD" "Scheduled Tasks"
        foreach ($tn in @($TASK_MOUNT, $TASK_WATCHDOG)) {
            $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
            if ($t) { Write-Log "OK"   "$tn  ->  $($t.State)" }
            else    { Write-Log "INFO" "$tn  ->  not registered" }
        }
    }

    Write-Log "HEAD" "Recent Logs"
    foreach ($lf in (Get-ChildItem $Cache -Filter "mount_*.log" -ErrorAction SilentlyContinue)) {
        $rName = $lf.BaseName -replace "^mount_", ""
        Write-Host ""
        Write-Host "  -- $rName --" -ForegroundColor Cyan
        Get-Content $lf.FullName -Tail 10 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}


# ══════════════════════════════════════════════════════════════════════════════
#  Task Scheduler: Install auto-mount at logon + optional watchdog
# ══════════════════════════════════════════════════════════════════════════════
function Install-ScheduledTasks {
    param([switch] $WithWatchdog, [int] $WdMinutes)

    if (-not $ScriptPath -or -not (Test-Path $ScriptPath)) {
        Write-Log "FAIL" "Cannot determine script path. Save the .ps1 to a permanent location first."
        exit 1
    }

    $who        = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isElevated) {
        Write-Log "WARN" "Not running as Administrator. Tasks will run under the current user context."
    }

    $cfgArg  = if ($ConfigFile) { " -ConfigFile `"$ConfigFile`"" } else { "" }
    $baseCmd = "-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -Action Mount -Silent$cfgArg"

    $principal = New-ScheduledTaskPrincipal `
        -UserId    $who `
        -LogonType Interactive `
        -RunLevel  LeastPrivilege

    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit         (New-TimeSpan -Hours 0) `
        -MultipleInstances          IgnoreNew `
        -StartWhenAvailable         $true `
        -DisallowStartIfOnBatteries $false

    # Auto-mount at logon
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $baseCmd
    Register-ScheduledTask `
        -TaskName  $TASK_MOUNT `
        -Trigger   (New-ScheduledTaskTrigger -AtLogOn) `
        -Action    $action `
        -Principal $principal `
        -Settings  $settings `
        -Force | Out-Null
    Write-Log "OK" "Registered: $TASK_MOUNT (trigger: at logon)"

    # Watchdog: repeating every N minutes
    if ($WithWatchdog) {
        $interval  = [math]::Max(1, $WdMinutes)
        $wdTrigger = New-ScheduledTaskTrigger `
            -Once `
            -At                 (Get-Date).AddMinutes(2) `
            -RepetitionInterval (New-TimeSpan -Minutes $interval)

        Register-ScheduledTask `
            -TaskName  $TASK_WATCHDOG `
            -Trigger   $wdTrigger `
            -Action    $action `
            -Principal $principal `
            -Settings  $settings `
            -Force | Out-Null
        Write-Log "OK" "Registered: $TASK_WATCHDOG (trigger: every ${interval}min, skips if already mounted)"
    }

    Write-Log "INFO" "To remove tasks later: .\Mount-GDrive.ps1 -Action Uninstall"
}

function Uninstall-ScheduledTasks {
    if (-not $IsWindows) { return }
    Write-Log "HEAD" "Removing Scheduled Tasks"
    foreach ($tn in @($TASK_MOUNT, $TASK_WATCHDOG)) {
        if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false
            Write-Log "OK" "Removed: $tn"
        } else {
            Write-Log "INFO" "Not found (already removed?): $tn"
        }
    }
}


# ══════════════════════════════════════════════════════════════════════════════
#  Main dispatcher
# ══════════════════════════════════════════════════════════════════════════════

$cfg = Get-Config

# Build the list of remotes.
# Config file wins over CLI params; CLI params provide the single-remote fallback.
$remoteList = @()

if ($cfg -and $cfg.remotes) {
    foreach ($r in $cfg.remotes) {
        if ($r.PSObject.Properties["enabled"] -and $r.enabled -eq $false) { continue }
        $remoteList += [PSCustomObject]@{
            Remote       = $r.name
            MountPoint   = $r.mountPoint
            CachePath    = if ($cfg.cachePath)      { $cfg.cachePath }      else { $CachePath }
            CacheMode    = if ($cfg.vfsCacheMode)   { $cfg.vfsCacheMode }   else { $VfsCacheMode }
            CacheMaxSize = if ($cfg.cacheMaxSize)   { $cfg.cacheMaxSize }   else { $CacheMaxSize }
            BufferSize   = if ($cfg.bufferSize)     { $cfg.bufferSize }     else { $BufferSize }
            ChunkSize    = if ($cfg.driveChunkSize) { $cfg.driveChunkSize } else { $DriveChunkSize }
            BwLimit      = if ($cfg.bwLimit)        { $cfg.bwLimit }        else { $BwLimit }
        }
    }
    if ($cfg.PSObject.Properties["watchdog"]                -and $cfg.watchdog)                { $Watchdog         = $true }
    if ($cfg.PSObject.Properties["watchdogIntervalMinutes"] -and $cfg.watchdogIntervalMinutes) { $WatchdogInterval = $cfg.watchdogIntervalMinutes }
} else {
    $remoteList += [PSCustomObject]@{
        Remote       = $Remote
        MountPoint   = $MountPoint
        CachePath    = $CachePath
        CacheMode    = $VfsCacheMode
        CacheMaxSize = $CacheMaxSize
        BufferSize   = $BufferSize
        ChunkSize    = $DriveChunkSize
        BwLimit      = $BwLimit
    }
}

$primaryCache = $remoteList[0].CachePath

switch ($Action) {

    "Mount" {
        $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isElevated -and -not $Silent) {
            Write-Log "WARN" "You are running this script as Administrator."
            Write-Log "WARN" "Because --network-mode is used, Windows will isolate the mapped drive to this elevated session."
            Write-Log "WARN" "The drive will likely NOT be visible in Windows Explorer. Run as a standard user instead."
            Write-Host ""
        }

        Assert-Prerequisites
        Assert-NetworkConnectivity
        Assert-DiskSpace -Path $primaryCache -RequiredGB 5
        Clear-VfsCache   -Cache $primaryCache

        foreach ($r in $remoteList) {
            Invoke-Mount `
                -RemoteName $r.Remote `
                -Letter     $r.MountPoint `
                -Cache      $r.CachePath `
                -CacheMode  $r.CacheMode `
                -Buf        $r.BufferSize `
                -Chunk      $r.ChunkSize `
                -BwLimitVal $r.BwLimit `
                -MaxSize    $r.CacheMaxSize
        }

        if ($Watchdog) {
            Install-ScheduledTasks -WithWatchdog -WdMinutes $WatchdogInterval
        }
    }

    "Unmount" {
        Invoke-Unmount -Cache $primaryCache
    }

    "Status" {
        Show-Status -Cache $primaryCache
    }

    "Restart" {
        Invoke-Unmount -Cache $primaryCache
        Start-Sleep -Seconds 3
        Assert-Prerequisites
        Assert-NetworkConnectivity

        foreach ($r in $remoteList) {
            Invoke-Mount `
                -RemoteName $r.Remote `
                -Letter     $r.MountPoint `
                -Cache      $r.CachePath `
                -CacheMode  $r.CacheMode `
                -Buf        $r.BufferSize `
                -Chunk      $r.ChunkSize `
                -BwLimitVal $r.BwLimit `
                -MaxSize    $r.CacheMaxSize
        }
    }

    "Install" {
        Assert-Prerequisites

        Write-Log "HEAD" "Cloud Provider Configuration"
        Write-Host "  Welcome to the Universal Rclone Mount Manager Setup." -ForegroundColor Cyan
        Write-Host "  You can mount Google Drive, OneDrive, Amazon S3, Dropbox, and 40+ more providers."
        Write-Host ""

        $setupNew = Read-Host "  Do you need to configure a NEW cloud remote now? [y/N]"
        if ($setupNew -match "^[Yy]") {
            Start-Process rclone -ArgumentList "config" -Wait -NoNewWindow
        }

        Write-Log "HEAD" "Mount Configuration"
        $remotesRaw = & rclone listremotes 2>&1
        if (-not $remotesRaw) {
            Write-Log "FAIL" "No remotes configured in rclone! Please run setup again and create a remote."
            exit 1
        }
        $remoteNames = @($remotesRaw | ForEach-Object { $_ -replace ":","" })
        $available = $remoteNames -join ", "
        Write-Host "  Available remotes: " -NoNewline; Write-Host $available -ForegroundColor Green

        $defaultRemote = if ($remoteNames.Contains("gdrive")) { "gdrive" } else { $remoteNames[0] }
        $remotesConfig = @()

        while ($true) {
            $userRemote = ""
            while ($true) {
                $userRemote = Read-Host "  Which remote would you like to auto-mount? [Default: $defaultRemote]"
                if ([string]::IsNullOrWhiteSpace($userRemote)) { $userRemote = $defaultRemote }
                if ($remoteNames -contains $userRemote) { break }
                Write-Log "WARN" "Invalid remote '$userRemote'. Please choose from: $available"
            }

            $userMount = ""
            while ($true) {
                $userMount = Read-Host "  Which drive letter should it map to? [Default: X:]"
                if ([string]::IsNullOrWhiteSpace($userMount)) { $userMount = "X:" }
                $userMount = $userMount.Trim().ToUpper()
                if ($userMount.Length -eq 1 -and $userMount -match "^[A-Z]$") { $userMount += ":" }

                if ($userMount -match "^[A-Z]:$") {
                    if (Test-Path "$userMount\") {
                        Write-Log "WARN" "Drive $userMount is already in use. Please choose an available letter."
                    } else {
                        break
                    }
                } else {
                    Write-Log "WARN" "Invalid format. Enter a single letter (e.g., Z: or M)."
                }
            }

            $remotesConfig += [ordered]@{ name = $userRemote; mountPoint = $userMount; enabled = $true }

            Write-Host ""
            $addAnother = Read-Host "  Would you like to mount another remote? [y/N]"
            if (-not ($addAnother -match "^[Yy]")) { break }
            Write-Host ""
        }

        Write-Host ""
        Write-Log "HEAD" "Advanced Settings"
        $userCache = Read-Host "  Maximum Local Cache Size [Default: 20G]"
        if ([string]::IsNullOrWhiteSpace($userCache)) { $userCache = "20G" }

        $userBw = Read-Host "  Bandwidth Limit (e.g. 10M, or 0 for unlimited) [Default: 0]"
        if ([string]::IsNullOrWhiteSpace($userBw)) { $userBw = "0" }

        if (-not (Test-Path $CachePath)) {
            New-Item -ItemType Directory -Force -Path $CachePath | Out-Null
        }
        $cfgPath = Join-Path $CachePath "config.json"
        if ($ConfigFile) { $cfgPath = $ConfigFile }

        $template = [ordered]@{
            remotes                 = $remotesConfig
            cachePath               = $CachePath
            vfsCacheMode            = "full"
            cacheMaxSize            = $userCache
            bufferSize              = "128M"
            driveChunkSize          = "128M"
            bwLimit                 = $userBw
            watchdog                = $true
            watchdogIntervalMinutes = 2
        }
        $template | ConvertTo-Json -Depth 5 | Set-Content -Path $cfgPath -Encoding UTF8
        Write-Log "OK" "Configuration saved to: $cfgPath"

        $ConfigFile = $cfgPath

        Install-ScheduledTasks -WithWatchdog:$true -WdMinutes 2

        Write-Log "INFO" "Starting the newly installed background mount task..."
        Start-ScheduledTask -TaskName $TASK_MOUNT -ErrorAction SilentlyContinue
    }

    "Uninstall" {
        Uninstall-ScheduledTasks
    }
}
