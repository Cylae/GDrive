#!/usr/bin/env bash

# Universal rclone cloud storage mount manager for Linux & macOS
# Supports multi-remote mounting from JSON config, auto-start, watchdog, status dashboard.

set -e

# Default settings
ACTION="mount"
REMOTE="gdrive"
CACHE_PATH="$HOME/.rcloneCache"
VFS_CACHE_MODE="full"
BUFFER_SIZE="128M"
DRIVE_CHUNK_SIZE="128M"
BW_LIMIT="0"
CACHE_MAX_SIZE="20G"
CONFIG_FILE=""
WATCHDOG=false
WATCHDOG_INTERVAL=2

# Determine OS
OS=$(uname -s)
if [ "$OS" = "Darwin" ]; then
    DEFAULT_MOUNT="$HOME/gdrive"
else
    DEFAULT_MOUNT="/mnt/gdrive"
fi

MOUNT_POINT="$DEFAULT_MOUNT"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -a, --action ACTION      mount|unmount|status|restart|install|uninstall (default: mount)
  -r, --remote REMOTE      rclone remote name (default: gdrive)
  -m, --mount-point PATH   Target directory (default: $DEFAULT_MOUNT)
  -c, --cache-path PATH    Root directory for VFS cache and logs (default: $CACHE_PATH)
  --vfs-cache-mode MODE    off|minimal|writes|full (default: full)
  --buffer-size SIZE       Read-ahead buffer (default: 128M)
  --drive-chunk-size SIZE  Upload chunk size (default: 128M)
  --bw-limit LIMIT         Bandwidth cap, e.g. 10M (default: 0)
  --cache-max-size SIZE    Max VFS disk cache size (default: 20G)
  --config-file PATH       JSON config file path
  --watchdog               Install a watchdog to auto-remount
  --watchdog-interval MIN  Minutes between watchdog checks (default: 2)
  -h, --help               Show this help
EOF
    exit 0
}

# Parse args
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -a|--action) ACTION="$2"; shift ;;
        -r|--remote) REMOTE="$2"; shift ;;
        -m|--mount-point) MOUNT_POINT="$2"; shift ;;
        -c|--cache-path) CACHE_PATH="$2"; shift ;;
        --vfs-cache-mode) VFS_CACHE_MODE="$2"; shift ;;
        --buffer-size) BUFFER_SIZE="$2"; shift ;;
        --drive-chunk-size) DRIVE_CHUNK_SIZE="$2"; shift ;;
        --bw-limit) BW_LIMIT="$2"; shift ;;
        --cache-max-size) CACHE_MAX_SIZE="$2"; shift ;;
        --config-file) CONFIG_FILE="$2"; shift ;;
        --watchdog) WATCHDOG=true ;;
        --watchdog-interval) WATCHDOG_INTERVAL="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

log() {
    local level=$1
    shift
    local ts=$(date "+%Y-%m-%d %H:%M:%S")
    local color="\033[0m"
    case $level in
        OK) color="\033[32m" ;;
        WARN) color="\033[33m" ;;
        FAIL) color="\033[31m" ;;
        HEAD) color="\033[36m"; echo ""; echo -e "  -- $1 --"; return ;;
    esac
    echo -e "  [${ts}] [${level}] ${color}$* \033[0m"
}

assert_prerequisites() {
    log HEAD "Prerequisites"
    if ! command -v rclone &> /dev/null; then
        log FAIL "rclone not found in PATH."
        if [ "$OS" = "Darwin" ]; then
            log FAIL "  Install via Homebrew: brew install rclone"
        else
            log FAIL "  Install via script: sudo -v ; curl https://rclone.org/install.sh | sudo bash"
        fi
        exit 1
    fi
    local v=$(rclone version | grep "rclone v" | head -n 1 | xargs)
    log OK "rclone -- $v"

    if [ "$OS" = "Darwin" ]; then
        if ! command -v macfuse &> /dev/null && [ ! -d "/Library/Filesystems/macfuse.fs" ]; then
            log WARN "macFUSE might not be installed. It is required for mounting on macOS."
            log WARN "  Install via Homebrew: brew install --cask macfuse"
        fi
    else
        if ! command -v fusermount &> /dev/null && ! command -v fusermount3 &> /dev/null; then
            log FAIL "fuse not found. rclone requires FUSE to mount on Linux."
            log FAIL "  Debian/Ubuntu: sudo apt install fuse3"
            exit 1
        fi
    fi
}

assert_remote_exists() {
    local name="$1"
    if ! rclone listremotes | grep -q "^${name}:"; then
        log FAIL "Remote '${name}:' not found in rclone.conf."
        exit 1
    fi
    log OK "Remote '${name}:' validated."
}

invoke_mount() {
    local r_name="$1"
    local m_point="$2"

    local log_file="${CACHE_PATH}/mount_${r_name}.log"
    local pid_file="${CACHE_PATH}/rclone_${r_name}.pid"

    # Check if already mounted
    if mount | grep -q "on ${m_point} "; then
        if [ -f "$pid_file" ] && kill -0 $(cat "$pid_file") 2>/dev/null; then
            log OK "[${r_name}] Already mounted on ${m_point} (PID $(cat "$pid_file")). Skipping."
            return
        fi
    fi

    mkdir -p "$CACHE_PATH"
    mkdir -p "$m_point"

    # Stop stale process
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            log WARN "Stopping stale rclone on ${m_point} (PID $old_pid)..."
            kill -15 "$old_pid" || kill -9 "$old_pid"
            sleep 2
        fi
        rm -f "$pid_file"
    fi

    # Unmount stale mountpoint
    if mount | grep -q "on ${m_point} "; then
        if [ "$OS" = "Darwin" ]; then
            diskutil unmount force "$m_point" >/dev/null 2>&1 || umount -f "$m_point" >/dev/null 2>&1
        else
            fusermount -uz "$m_point" >/dev/null 2>&1 || umount -f "$m_point" >/dev/null 2>&1
        fi
    fi

    assert_remote_exists "$r_name"

    local mount_cmd=(
        rclone mount "${r_name}:" "${m_point}"
        --vfs-cache-mode "$VFS_CACHE_MODE"
        --cache-dir "$CACHE_PATH"
        --vfs-cache-max-size "$CACHE_MAX_SIZE"
        --vfs-cache-max-age 24h
        --vfs-write-back 5s
        --buffer-size "$BUFFER_SIZE"
        --vfs-read-ahead 128M
        --drive-chunk-size "$DRIVE_CHUNK_SIZE"
        --dir-cache-time 72h
        --attr-timeout 1h
        --vfs-fast-fingerprint
        --transfers 4
        --checkers 8
        --tpslimit 10
        --tpslimit-burst 20
        --log-level INFO
        --log-file "$log_file"
        --daemon
    )

    if [ "$BW_LIMIT" != "0" ]; then
        mount_cmd+=(--bwlimit "$BW_LIMIT")
    fi

    log HEAD "Mounting ${r_name}: -> ${m_point}"

    # Execute and capture daemonized PID
    "${mount_cmd[@]}"

    # Rclone --daemon forks to background. We need to find its PID.
    # We wait up to 10s for the mount to appear
    local timeout=10
    local mounted=false
    for ((i=0; i<timeout; i++)); do
        if mount | grep -q "on ${m_point} "; then
            mounted=true
            break
        fi
        sleep 1
    done

    if $mounted; then
        # Find the PID of the rclone process handling this mount
        local pid=$(pgrep -f "rclone mount ${r_name}: ${m_point}" | head -n 1)
        if [ -n "$pid" ]; then
            echo "$pid" > "$pid_file"
            log OK "SUCCESS -- ${m_point}  |  PID: $pid  |  Remote: ${r_name}:"
        else
            log WARN "Mounted, but could not determine PID."
        fi
    else
        log FAIL "${m_point} not visible after ${timeout}s. Check logs: $log_file"
        exit 1
    fi
}

invoke_unmount() {
    local r_name="$1"
    log HEAD "Unmounting"

    local pids_found=false
    for pid_file in "${CACHE_PATH}"/rclone_*.pid; do
        [ -e "$pid_file" ] || continue
        pids_found=true
        local pid=$(cat "$pid_file")
        local name=$(basename "$pid_file" | sed 's/^rclone_//;s/\.pid$//')

        if [ "$r_name" != "*" ] && [ "$r_name" != "$name" ]; then
            continue
        fi

        if kill -0 "$pid" 2>/dev/null; then
            kill -15 "$pid"
            log OK "Stopped '${name}' (PID $pid)."
        else
            log WARN "'${name}': no live rclone at PID $pid (already stopped?)."
        fi
        rm -f "$pid_file"
    done

    if ! $pids_found; then
        log WARN "No PID files found. Using killall/fusermount fallback..."
        pkill -x rclone || true
    fi

    # Cleanup any dangling fuse mounts in cache
    for dir in "$CACHE_PATH"/*/ ; do
        if mount | grep -q "on ${dir%/} "; then
            if [ "$OS" = "Darwin" ]; then
                diskutil unmount force "${dir%/}" >/dev/null 2>&1 || umount -f "${dir%/}" >/dev/null 2>&1
            else
                fusermount -uz "${dir%/}" >/dev/null 2>&1 || umount -f "${dir%/}" >/dev/null 2>&1
            fi
        fi
    done
    sleep 2
}

show_status() {
    log HEAD "Mount Status"
    local pids_found=false
    for pid_file in "${CACHE_PATH}"/rclone_*.pid; do
        [ -e "$pid_file" ] || continue
        pids_found=true
        local pid=$(cat "$pid_file")
        local name=$(basename "$pid_file" | sed 's/^rclone_//;s/\.pid$//')

        if kill -0 "$pid" 2>/dev/null; then
            log OK "[${name}]  PID: $pid is running."
        else
            log WARN "[${name}]  PID $pid not found -- process may have crashed."
        fi
    done
    if ! $pids_found; then
        log WARN "No active mounts found."
    fi

    log HEAD "Cache"
    if [ -d "$CACHE_PATH" ]; then
        local size=$(du -sh "$CACHE_PATH" | cut -f1)
        log INFO "Path : $CACHE_PATH"
        log INFO "Used : $size"
    fi
}

install_service() {
    log HEAD "Installing Auto-Start Services"
    local SCRIPT_PATH=$(realpath "$0")

    if [ "$OS" = "Darwin" ]; then
        # macOS launchd
        local PLIST_PATH="$HOME/Library/LaunchAgents/com.rclone.mount.plist"
        cat <<EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.rclone.mount</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPT_PATH</string>
        <string>-a</string>
        <string>mount</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
        if [ "$WATCHDOG" = true ]; then
            # Insert StartInterval for watchdog (in seconds)
            local interval_sec=$(( WATCHDOG_INTERVAL * 60 ))
            sed -i '' -e "/<\/dict>/i\\
    <key>StartInterval</key>\\
    <integer>$interval_sec</integer>\\
" "$PLIST_PATH"
        fi

        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        launchctl load "$PLIST_PATH"
        log OK "Installed launchd agent at $PLIST_PATH"

    else
        # Linux systemd user service
        local SERVICE_DIR="$HOME/.config/systemd/user"
        mkdir -p "$SERVICE_DIR"
        local SERVICE_PATH="$SERVICE_DIR/rclone-mount.service"

        cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=Rclone Mount Manager
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH -a mount
RemainAfterExit=yes
ExecStop=$SCRIPT_PATH -a unmount

[Install]
WantedBy=default.target
EOF

        systemctl --user daemon-reload
        systemctl --user enable rclone-mount.service
        systemctl --user start rclone-mount.service
        log OK "Installed systemd user service at $SERVICE_PATH"

        if [ "$WATCHDOG" = true ]; then
            local TIMER_PATH="$SERVICE_DIR/rclone-mount.timer"
            cat <<EOF > "$TIMER_PATH"
[Unit]
Description=Rclone Mount Watchdog Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=${WATCHDOG_INTERVAL}min

[Install]
WantedBy=timers.target
EOF
            systemctl --user enable rclone-mount.timer
            systemctl --user start rclone-mount.timer
            log OK "Installed systemd user timer at $TIMER_PATH"
        fi
    fi
}

uninstall_service() {
    log HEAD "Removing Services"
    if [ "$OS" = "Darwin" ]; then
        local PLIST_PATH="$HOME/Library/LaunchAgents/com.rclone.mount.plist"
        if [ -f "$PLIST_PATH" ]; then
            launchctl unload "$PLIST_PATH" 2>/dev/null || true
            rm -f "$PLIST_PATH"
            log OK "Removed launchd agent."
        fi
    else
        systemctl --user stop rclone-mount.timer 2>/dev/null || true
        systemctl --user disable rclone-mount.timer 2>/dev/null || true
        systemctl --user stop rclone-mount.service 2>/dev/null || true
        systemctl --user disable rclone-mount.service 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/rclone-mount.service"
        rm -f "$HOME/.config/systemd/user/rclone-mount.timer"
        systemctl --user daemon-reload
        log OK "Removed systemd user services."
    fi
}


# Dispatch
case "$ACTION" in
    mount)
        assert_prerequisites
        invoke_mount "$REMOTE" "$MOUNT_POINT"
        ;;
    unmount)
        invoke_unmount "*"
        ;;
    status)
        show_status
        ;;
    restart)
        invoke_unmount "*"
        assert_prerequisites
        invoke_mount "$REMOTE" "$MOUNT_POINT"
        ;;
    install)
        install_service
        ;;
    uninstall)
        uninstall_service
        ;;
    *)
        log FAIL "Unknown action: $ACTION"
        exit 1
        ;;
esac
