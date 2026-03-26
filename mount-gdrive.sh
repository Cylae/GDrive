#!/usr/bin/env bash

# Universal rclone cloud storage mount manager for Linux & macOS
# Features: Multi-remote JSON config, OS-Native Daemons (systemd/launchd), Auto-Start, Watchdog

set -e

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
  -a, --action ACTION      mount|unmount|status|daemon|install|uninstall (default: mount)
  -r, --remote REMOTE      rclone remote name (default: gdrive)
  -m, --mount-point PATH   Target directory (default: $DEFAULT_MOUNT)
  -c, --cache-path PATH    Root directory for VFS cache and logs (default: $CACHE_PATH)
  --config-file PATH       JSON config file path (overrides CLI flags)
  --watchdog               Install an OS-native watchdog to auto-remount on crash
  -h, --help               Show this help
EOF
    exit 0
}

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
        --watchdog-interval) shift ;; # Deprecated, ignored safely
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

has_cmd() { command -v "$1" >/dev/null 2>&1; }

unmount_path() {
    local m_point="$1"
    if mount | grep -q "on ${m_point} "; then
        if [ "$OS" = "Darwin" ]; then
            diskutil unmount force "$m_point" >/dev/null 2>&1 || umount -f "$m_point" >/dev/null 2>&1
        else
            fusermount -uz "$m_point" >/dev/null 2>&1 || umount -f "$m_point" >/dev/null 2>&1
        fi
        log OK "Unmounted $m_point"
    fi
}

assert_prerequisites() {
    log HEAD "Prerequisites (Auto-Installer)"
    local needs_restart=false

    if ! has_cmd rclone; then
        log WARN "rclone not found. Attempting auto-installation..."
        if [ "$OS" = "Darwin" ]; then
            if ! has_cmd brew; then
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            fi
            brew install rclone
        else
            sudo -v || true
            curl -fsSL https://rclone.org/install.sh | sudo bash
        fi
        if ! has_cmd rclone; then
            log FAIL "rclone auto-install failed."
            exit 1
        fi
        needs_restart=true
    fi
    local v=$(rclone version | grep "rclone v" | head -n 1 | xargs)
    log OK "rclone -- $v"

    if [ "$OS" = "Darwin" ]; then
        if ! has_cmd macfuse && [ ! -d "/Library/Filesystems/macfuse.fs" ]; then
            log WARN "macFUSE not found. Attempting auto-installation via Homebrew..."
            if ! has_cmd brew; then
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            fi
            brew install --cask macfuse
            log INFO "macFUSE requires kernel extension approval in System Settings > Security."
            needs_restart=true
        fi
    else
        if ! has_cmd fusermount && ! has_cmd fusermount3; then
            log WARN "FUSE not found. Attempting auto-installation..."
            if has_cmd apt-get; then sudo apt-get update && sudo apt-get install -y fuse3
            elif has_cmd dnf; then sudo dnf install -y fuse3
            elif has_cmd pacman; then sudo pacman -S --noconfirm fuse3
            else log FAIL "Unsupported package manager. Please install fuse3 manually."; exit 1; fi
            needs_restart=true
        fi
    fi

    if [ -n "$CONFIG_FILE" ]; then
        if ! has_cmd python3; then
            log WARN "python3 not found. Attempting auto-installation..."
            if [ "$OS" = "Darwin" ]; then brew install python
            elif has_cmd apt-get; then sudo apt-get update && sudo apt-get install -y python3
            elif has_cmd dnf; then sudo dnf install -y python3
            elif has_cmd pacman; then sudo pacman -S --noconfirm python3; fi
        fi
    fi

    if $needs_restart; then
        log INFO "Dependencies were just installed. You may need to restart your terminal."
    fi
}

assert_remote_exists() {
    local name="$1"
    if ! rclone listremotes | grep -q "^${name}:"; then
        log FAIL "Remote '${name}:' not found in rclone.conf."
        exit 1
    fi
}

invoke_daemon() {
    local r_name="$1"
    local m_point="$2"

    local log_file="${CACHE_PATH}/mount_${r_name}.log"
    mkdir -p "$CACHE_PATH"
    mkdir -p "$m_point"

    # In foreground daemon mode, we must strictly clean the path first
    unmount_path "$m_point"
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
        --vfs-read-chunk-size 128M
        --vfs-read-chunk-size-limit off
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
    )

    if [ "$BW_LIMIT" != "0" ]; then
        mount_cmd+=(--bwlimit "$BW_LIMIT")
    fi

    log HEAD "Starting Daemon: ${r_name}: -> ${m_point}"

    # Replace the current shell process with rclone (foreground execution)
    # This delegates full lifecycle management and PID tracking to the OS service manager
    exec "${mount_cmd[@]}"
}

install_services() {
    log HEAD "Installing OS-Native Services"
    local SCRIPT_PATH=$(realpath "$0")

    for i in "${!REMOTES[@]}"; do
        local r_name="${REMOTES[$i]}"
        local m_point="${MOUNT_POINTS[$i]}"

        local CMD_ARGS=("-a" "daemon" "-r" "$r_name" "-m" "$m_point" "-c" "$CACHE_PATH")
        if [ -n "$CONFIG_FILE" ]; then
            CMD_ARGS+=("--config-file" "$(realpath "$CONFIG_FILE")")
        fi

        if [ "$OS" = "Darwin" ]; then
            local PLIST_PATH="$HOME/Library/LaunchAgents/com.rclone.mount.${r_name}.plist"
            mkdir -p "$HOME/Library/LaunchAgents"

            local args_xml="<string>$SCRIPT_PATH</string>"
            for arg in "${CMD_ARGS[@]}"; do
                arg=$(echo "$arg" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g')
                args_xml="$args_xml"$'\n'"        <string>$arg</string>"
            done

            local keep_alive="<false/>"
            if [ "$WATCHDOG" = true ]; then keep_alive="<true/>"; fi

            cat <<EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.rclone.mount.${r_name}</string>
    <key>ProgramArguments</key>
    <array>
        $args_xml
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    $keep_alive
</dict>
</plist>
EOF
            launchctl unload "$PLIST_PATH" 2>/dev/null || true
            launchctl load "$PLIST_PATH"
            log OK "Installed launchd agent: $PLIST_PATH"

        else
            local SERVICE_DIR="$HOME/.config/systemd/user"
            mkdir -p "$SERVICE_DIR"
            local SERVICE_PATH="$SERVICE_DIR/rclone-mount-${r_name}.service"

            local exec_start="$SCRIPT_PATH"
            for arg in "${CMD_ARGS[@]}"; do
                exec_start="$exec_start $(printf '%q' "$arg")"
            done

            local restart="no"
            if [ "$WATCHDOG" = true ]; then restart="always"; fi

            cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=Rclone Mount (${r_name})
After=network-online.target

[Service]
Type=simple
ExecStart=$exec_start
ExecStopPre=$SCRIPT_PATH -a unmount -r ${r_name}
Restart=$restart
RestartSec=10

[Install]
WantedBy=default.target
EOF

            systemctl --user daemon-reload
            systemctl --user enable "rclone-mount-${r_name}.service"
            systemctl --user start "rclone-mount-${r_name}.service"
            log OK "Installed systemd service: $SERVICE_PATH"
        fi
    done
}

uninstall_services() {
    log HEAD "Removing Services"
    if [ "$OS" = "Darwin" ]; then
        for plist in "$HOME/Library/LaunchAgents/com.rclone.mount."*.plist; do
            [ -e "$plist" ] || continue
            launchctl unload "$plist" 2>/dev/null || true
            rm -f "$plist"
            log OK "Removed $(basename "$plist")"
        done
    else
        for srv in "$HOME/.config/systemd/user/rclone-mount-"*.service; do
            [ -e "$srv" ] || continue
            local srv_name=$(basename "$srv")
            systemctl --user stop "$srv_name" 2>/dev/null || true
            systemctl --user disable "$srv_name" 2>/dev/null || true
            rm -f "$srv"
            log OK "Removed $srv_name"
        done
        systemctl --user daemon-reload
    fi
}

show_status() {
    log HEAD "OS-Native Service Status"
    if [ "$OS" = "Darwin" ]; then
        local found=false
        for plist in "$HOME/Library/LaunchAgents/com.rclone.mount."*.plist; do
            [ -e "$plist" ] || continue
            found=true
            local label=$(basename "$plist" .plist)
            local pid=$(launchctl list | grep "$label" | awk '{print $1}')
            if [[ "$pid" =~ ^[0-9]+$ ]]; then
                local uptime=$(ps -p "$pid" -o etime= | xargs)
                log OK "[$label]  PID: $pid  |  Uptime: $uptime"
            else
                log WARN "[$label] Not running or crashed."
            fi
        done
        if ! $found; then log WARN "No launchd agents found."; fi
    else
        local found=false
        for srv in "$HOME/.config/systemd/user/rclone-mount-"*.service; do
            [ -e "$srv" ] || continue
            found=true
            local srv_name=$(basename "$srv")
            local state=$(systemctl --user is-active "$srv_name" 2>/dev/null || echo "inactive")
            if [ "$state" = "active" ]; then
                local pid=$(systemctl --user show -p MainPID --value "$srv_name")
                local uptime=$(ps -p "$pid" -o etimes= | awk '{printf "%dd %02dh %02dm\n", $1/86400, ($1%86400)/3600, ($1%3600)/60}')
                log OK "[$srv_name]  PID: $pid  |  Uptime: $uptime"
            else
                log WARN "[$srv_name] State: $state"
            fi
        done
        if ! $found; then log WARN "No systemd services found."; fi
    fi

    log HEAD "Cache"
    if [ -d "$CACHE_PATH" ]; then
        log INFO "Path : $CACHE_PATH"
        log INFO "Used : $(du -sh "$CACHE_PATH" | cut -f1)"
    fi
}

case "$ACTION" in
    install)
        assert_prerequisites

        log HEAD "Cloud Provider Configuration"
        echo -e "  \033[36mWelcome to the Universal Rclone Mount Manager Setup.\033[0m"
        echo -e "  You can mount Google Drive, OneDrive, Amazon S3, Dropbox, and 40+ more providers."
        echo ""
        read -p "  Do you need to configure a NEW cloud remote now? [y/N]: " setup_new
        if [[ "$setup_new" =~ ^[Yy]$ ]]; then
            rclone config
        fi

        echo ""
        log HEAD "Mount Configuration"

        # Determine available remotes
        available_remotes=$(rclone listremotes | sed 's/://g' | xargs)
        if [ -z "$available_remotes" ]; then
            log FAIL "No remotes configured in rclone! Please run setup again and create a remote."
            exit 1
        fi

        echo -e "  Available remotes: \033[32m$available_remotes\033[0m"

        local json_remotes=""
        local default_remote
        if echo "$available_remotes" | grep -qw "gdrive"; then default_remote="gdrive"; else default_remote=$(echo "$available_remotes" | awk '{print $1}'); fi

        while true; do
            local user_remote=""
            while true; do
                read -p "  Which remote would you like to auto-mount? [Default: $default_remote]: " user_remote
                user_remote=${user_remote:-$default_remote}
                if echo "$available_remotes" | grep -qw "$user_remote"; then break; fi
                log WARN "Invalid remote '$user_remote'. Please choose from: $available_remotes"
            done

            local user_mount=""
            while true; do
                read -p "  Where should it be mounted? [Default: $DEFAULT_MOUNT]: " user_mount
                user_mount=${user_mount:-$DEFAULT_MOUNT}

                # Expand ~ to $HOME
                user_mount="${user_mount/#\~/$HOME}"

                # Enforce absolute path
                if [[ "$user_mount" != /* ]]; then
                    log WARN "Mount path must be absolute (start with / or ~)."
                    continue
                fi

                if [ -d "$user_mount" ]; then
                    if [ "$(ls -A "$user_mount" 2>/dev/null)" ]; then
                        if mount | grep -q "on ${user_mount} "; then
                            log WARN "Directory is currently mounted by another process."
                            continue
                        fi
                        read -p "  Warning: Directory '$user_mount' is not empty. Mount over it anyway? [y/N]: " force_mount
                        if [[ ! "$force_mount" =~ ^[Yy]$ ]]; then continue; fi
                    fi
                fi
                break
            done

            json_remotes+="$(cat <<EOF
    {
      "name": "$user_remote",
      "mountPoint": "$user_mount",
      "enabled": true
    },
EOF
)"

            echo ""
            read -p "  Would you like to mount another remote? [y/N]: " add_another
            if [[ ! "$add_another" =~ ^[Yy]$ ]]; then break; fi
            echo ""
        done

        # Remove trailing comma from json_remotes
        json_remotes="${json_remotes%,}"

        echo ""
        log HEAD "Advanced Settings"
        read -p "  Maximum Local Cache Size [Default: 20G]: " user_cache
        user_cache=${user_cache:-20G}

        read -p "  Bandwidth Limit (e.g. 10M, or 0 for unlimited) [Default: 0]: " user_bw
        user_bw=${user_bw:-0}

        cfg_path="$CACHE_PATH/config.json"
        if [ -n "$CONFIG_FILE" ]; then cfg_path="$CONFIG_FILE"; fi

        mkdir -p "$(dirname "$cfg_path")"
        cat <<EOF > "$cfg_path"
{
  "remotes": [
$json_remotes
  ],
  "cachePath": "$CACHE_PATH",
  "vfsCacheMode": "full",
  "cacheMaxSize": "$user_cache",
  "bufferSize": "128M",
  "driveChunkSize": "128M",
  "bwLimit": "$user_bw",
  "watchdog": true
}
EOF
        log OK "Configuration saved to: $cfg_path"

        CONFIG_FILE="$cfg_path"
        eval "$(parse_config)"

        install_services
        ;;
    uninstall)
        uninstall_services
        ;;
    *)
        # All other commands need the config loaded first
        if [ -n "$CONFIG_FILE" ]; then
            if [ ! -f "$CONFIG_FILE" ]; then log FAIL "Config file not found: $CONFIG_FILE"; exit 1; fi
            eval "$(parse_config)"
            log OK "Config loaded: $CONFIG_FILE"
        else
            REMOTES=("$REMOTE")
            MOUNT_POINTS=("$MOUNT_POINT")
        fi

        case "$ACTION" in
            daemon)
        # INTERNAL: Run rclone in foreground. Managed by systemd/launchd.
        assert_prerequisites
        invoke_daemon "$REMOTE" "$MOUNT_POINT"
        ;;
    mount)
        assert_prerequisites
        # Backwards compatibility: manual mount fires off isolated background daemons using nohup
        for i in "${!REMOTES[@]}"; do
            unmount_path "${MOUNT_POINTS[$i]}"
            nohup "$0" -a daemon -r "${REMOTES[$i]}" -m "${MOUNT_POINTS[$i]}" -c "$CACHE_PATH" >/dev/null 2>&1 &
            log OK "Launched background mount for ${REMOTES[$i]} -> ${MOUNT_POINTS[$i]}"
        done
        ;;
    unmount)
        for i in "${!REMOTES[@]}"; do
            if [ "$REMOTE" != "gdrive" ] && [ "$REMOTE" != "${REMOTES[$i]}" ] && [ -z "$CONFIG_FILE" ]; then continue; fi
            # Stop any systemd service first so watchdog doesn't respawn it
            if [ "$OS" = "Linux" ]; then systemctl --user stop "rclone-mount-${REMOTES[$i]}.service" 2>/dev/null || true; fi
            # Kill the actual daemon process
            pkill -f "rclone mount ${REMOTES[$i]}: ${MOUNT_POINTS[$i]}" || true
            unmount_path "${MOUNT_POINTS[$i]}"
        done
        ;;
    status)
        show_status
        ;;
    restart)
        "$0" -a unmount
        sleep 2
        "$0" -a mount
                ;;
            *)
                log FAIL "Unknown action: $ACTION"
                exit 1
                ;;
        esac
        ;;
esac
