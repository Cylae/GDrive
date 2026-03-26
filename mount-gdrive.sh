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
LOG_MAX_BYTES=5242880 # 5MB

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
  --config-file PATH       JSON config file path (overrides CLI flags)
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

# Python script to parse JSON config safely using bash arrays and avoiding eval injection
parse_config() {
    cat << 'EOF' | python3 - "$CONFIG_FILE" "$CACHE_PATH"
import json, sys, shlex
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    if "remotes" not in data:
        sys.exit(0)

    print(f"CACHE_PATH={shlex.quote(data.get('cachePath', sys.argv[2]))}")
    print(f"VFS_CACHE_MODE={shlex.quote(data.get('vfsCacheMode', 'full'))}")
    print(f"CACHE_MAX_SIZE={shlex.quote(data.get('cacheMaxSize', '20G'))}")
    print(f"BUFFER_SIZE={shlex.quote(data.get('bufferSize', '128M'))}")
    print(f"DRIVE_CHUNK_SIZE={shlex.quote(data.get('driveChunkSize', '128M'))}")
    print(f"BW_LIMIT={shlex.quote(data.get('bwLimit', '0'))}")

    if data.get("watchdog"):
        print("WATCHDOG=true")
    if data.get("watchdogIntervalMinutes"):
        print(f"WATCHDOG_INTERVAL={shlex.quote(str(data.get('watchdogIntervalMinutes')))}")

    print("REMOTES=()")
    print("MOUNT_POINTS=()")

    for r in data["remotes"]:
        if r.get("enabled", True):
            name = shlex.quote(r.get("name", ""))
            mp = shlex.quote(r.get("mountPoint", ""))
            print(f"REMOTES+=({name})")
            print(f"MOUNT_POINTS+=({mp})")

except Exception as e:
    print(f"echo Error parsing JSON: {e} >&2", file=sys.stderr)
    sys.exit(1)
EOF
}

# Check if command exists
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

assert_prerequisites() {
    log HEAD "Prerequisites"
    if ! has_cmd rclone; then
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
        if ! has_cmd macfuse && [ ! -d "/Library/Filesystems/macfuse.fs" ]; then
            log WARN "macFUSE might not be installed. It is required for mounting on macOS."
            log WARN "  Install via Homebrew: brew install --cask macfuse"
        fi
    else
        if ! has_cmd fusermount && ! has_cmd fusermount3; then
            log FAIL "fuse not found. rclone requires FUSE to mount on Linux."
            log FAIL "  Debian/Ubuntu: sudo apt install fuse3"
            exit 1
        fi
    fi

    if [ -n "$CONFIG_FILE" ]; then
        if ! has_cmd python3; then
            log FAIL "python3 not found. It is required to parse the JSON config file."
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

assert_disk_space() {
    local path="$1"
    local required_gb=5
    local free_kb

    if [ "$OS" = "Darwin" ]; then
        free_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
    else
        free_kb=$(df -P -k "$path" | awk 'NR==2 {print $4}')
    fi

    if [ -n "$free_kb" ]; then
        local free_gb=$((free_kb / 1024 / 1024))
        if [ "$free_gb" -lt "$required_gb" ]; then
            log WARN "Low disk space on cache drive: ${free_gb}GB free (recommended >= ${required_gb}GB)."
        else
            log OK "Cache drive: ${free_gb}GB free."
        fi
    fi
}

invoke_log_rotation() {
    local log_file="$1"
    if [ ! -f "$log_file" ]; then
        return
    fi

    local size
    if [ "$OS" = "Darwin" ]; then
        size=$(stat -f%z "$log_file")
    else
        size=$(stat -c%s "$log_file")
    fi

    if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
        log INFO "Rotating log (exceeds 5MB)..."
        for i in 3 2 1; do
            if [ -f "$log_file.$i" ]; then
                if [ "$i" -eq 3 ]; then
                    rm -f "$log_file.$i"
                else
                    mv "$log_file.$i" "$log_file.$((i+1))"
                fi
            fi
        done
        mv "$log_file" "$log_file.1"
    fi
}

clear_vfs_cache() {
    log HEAD "VFS Cache Purge"
    local paths=(
        "$HOME/.cache/rclone/vfs"
        "$CACHE_PATH/vfs"
        "$HOME/Library/Caches/rclone/vfs"
    )
    for p in "${paths[@]}"; do
        if [ -d "$p" ]; then
            rm -rf "${p:?}/"*
            log OK "Cleared: $p"
        fi
    done
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

    assert_disk_space "$CACHE_PATH"
    invoke_log_rotation "$log_file"

    # Stop stale process
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            log WARN "Stopping stale rclone on ${m_point} (PID $old_pid)..."
            kill -15 "$old_pid" 2>/dev/null || kill -9 "$old_pid" 2>/dev/null
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
    log INFO "Cache mode   : $VFS_CACHE_MODE  |  Max size: $CACHE_MAX_SIZE"
    log INFO "Buffer       : $BUFFER_SIZE  |  Chunk: $DRIVE_CHUNK_SIZE"
    if [ "$BW_LIMIT" != "0" ]; then log INFO "Bandwidth cap: $BW_LIMIT"; fi
    log INFO "Log file     : $log_file"

    # Execute and capture daemonized PID
    "${mount_cmd[@]}"

    # Rclone --daemon forks to background. We need to find its PID.
    # Wait up to 20s for the mount to appear
    local timeout=20
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

    # Explicitly unmount only the mountpoints defined in our config or CLI
    # This avoids dangerously unmounting unrelated user fuse mounts.
    for i in "${!REMOTES[@]}"; do
        local configured_remote="${REMOTES[$i]}"
        local m_point="${MOUNT_POINTS[$i]}"

        if [ "$r_name" != "*" ] && [ "$r_name" != "$configured_remote" ]; then
            continue
        fi

        if mount | grep -q "on ${m_point} "; then
            if [ "$OS" = "Darwin" ]; then
                diskutil unmount force "$m_point" >/dev/null 2>&1 || umount -f "$m_point" >/dev/null 2>&1
            else
                fusermount -uz "$m_point" >/dev/null 2>&1 || umount -f "$m_point" >/dev/null 2>&1
            fi
            log OK "Unmounted $m_point"
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
            local uptime="N/A"
            if [ "$OS" = "Darwin" ]; then
                uptime=$(ps -p "$pid" -o etime= | xargs)
            else
                uptime=$(ps -p "$pid" -o etimes= | awk '{printf "%dd %02dh %02dm\n", $1/86400, ($1%86400)/3600, ($1%3600)/60}')
            fi
            log OK "[${name}]  PID: $pid  |  Uptime: $uptime"
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

    log HEAD "Recent Logs"
    for log_file in "${CACHE_PATH}"/mount_*.log; do
        [ -e "$log_file" ] || continue
        local name=$(basename "$log_file" | sed 's/^mount_//;s/\.log$//')
        echo ""
        echo -e "  \033[36m-- $name --\033[0m"
        tail -n 10 "$log_file" | while read -r line; do
            echo -e "    \033[90m$line\033[0m"
        done
    done
}

save_default_config() {
    local path="$1"
    cat <<EOF > "$path"
{
  "_comment": "Edit this file, then run: ./mount-gdrive.sh --config-file config.json",
  "remotes": [
    {
      "name": "gdrive",
      "mountPoint": "$DEFAULT_MOUNT",
      "enabled": true
    },
    {
      "name": "onedrive",
      "mountPoint": "$HOME/onedrive",
      "enabled": false
    }
  ],
  "cachePath": "$CACHE_PATH",
  "vfsCacheMode": "full",
  "cacheMaxSize": "20G",
  "bufferSize": "128M",
  "driveChunkSize": "128M",
  "bwLimit": "0",
  "watchdog": false,
  "watchdogIntervalMinutes": 2
}
EOF
    log OK "Starter config written: $path"
}

install_service() {
    log HEAD "Installing Auto-Start Services"
    local SCRIPT_PATH=$(realpath "$0")
    local -a CMD_ARGS=("-a" "mount")

    if [ -n "$CONFIG_FILE" ]; then
        CMD_ARGS+=("--config-file" "$(realpath "$CONFIG_FILE")")
    else
        CMD_ARGS+=("-r" "$REMOTE" "-m" "$MOUNT_POINT" "-c" "$CACHE_PATH")
    fi

    if [ "$OS" = "Darwin" ]; then
        # macOS launchd
        local PLIST_PATH="$HOME/Library/LaunchAgents/com.rclone.mount.plist"
        mkdir -p "$HOME/Library/LaunchAgents"

        local args_xml="<string>$SCRIPT_PATH</string>"
        for arg in "${CMD_ARGS[@]}"; do
            # Escape basic XML entities
            arg=$(echo "$arg" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g')
            args_xml="$args_xml\n        <string>$arg</string>"
        done

        cat <<EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.rclone.mount</string>
    <key>ProgramArguments</key>
    <array>
        $args_xml
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
        if [ "$WATCHDOG" = true ]; then
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

        # Build the command string properly escaping for systemd ExecStart
        local exec_start="$SCRIPT_PATH"
        for arg in "${CMD_ARGS[@]}"; do
            # Systemd requires specific quoting; using printf %q provides safe shell quoting
            exec_start="$exec_start $(printf '%q' "$arg")"
        done

        cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=Rclone Mount Manager
After=network-online.target

[Service]
Type=oneshot
ExecStart=$exec_start
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

# Load config if specified
if [ -n "$CONFIG_FILE" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        log FAIL "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    eval "$(parse_config)"
    log OK "Config loaded: $CONFIG_FILE"
else
    REMOTES=("$REMOTE")
    MOUNT_POINTS=("$MOUNT_POINT")
fi


# Dispatch
case "$ACTION" in
    mount)
        assert_prerequisites
        clear_vfs_cache
        for i in "${!REMOTES[@]}"; do
            invoke_mount "${REMOTES[$i]}" "${MOUNT_POINTS[$i]}"
        done
        if [ "$WATCHDOG" = true ]; then
            install_service
        fi
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
        for i in "${!REMOTES[@]}"; do
            invoke_mount "${REMOTES[$i]}" "${MOUNT_POINTS[$i]}"
        done
        ;;
    install)
        if [ -n "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
            mkdir -p "$(dirname "$CONFIG_FILE")"
            save_default_config "$CONFIG_FILE"
        elif [ -z "$CONFIG_FILE" ] && [ ! -f "$CACHE_PATH/config.json" ]; then
            mkdir -p "$CACHE_PATH"
            save_default_config "$CACHE_PATH/config.json"
        fi
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
