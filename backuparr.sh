#!/bin/bash
###############################################################################
# backuparr.sh — Unraid Docker + extra-dirs backup with rsync delta versioning
#
# Features:
#   - Rsync --backup-dir local versioning (works across Unraid multi-disk shares)
#   - Incremental rclone with --backup-dir versioning on Google Drive
#   - Per-app configurable retention, excludes, and directory-content exclusion
#   - Extra directories outside Docker appdata
#   - Centralised global config (backuparr.conf)
#   - All original CLI flags preserved
#
# Usage: backuparr.sh [options]
#   -d   Dry run
#   -v   Verbose
#   -s   Skip Google Drive upload
#   -a   Enable snapshot creation (replaces old -a archive flag)
#   -c   Create per-app .conf files only (no backup)
#   -n X Only back up container named X
#   -u   Running from Unraid User.Scripts (adjusts output / enables notify)
#   -b X Override backup location
#   -g X Override Google Drive rclone remote
#   -y N Override default local snapshot count
###############################################################################

set -o pipefail
SECONDS=0

###############################################################################
# HARDCODED DEFAULTS (overridden by backuparr.conf, then CLI flags)
###############################################################################
BACKUP_LOCATION=/mnt/user/backup
GDRIVE_LOCATION=""
DEFAULT_TIMEOUT=30
DEFAULT_LOCAL_SNAPSHOTS=3
DEFAULT_REMOTE_SNAPSHOTS=7
GDRIVE_INCREMENTAL=true
EXCLUDE=(profile/lock '*.pid' '*.sample' '*.lock' /lock)
EXCLUDEPRE=('*.dat.old')
EXTRA_DIRS=()
DRYRUN=""
PROGRESS="--info=progress2"

###############################################################################
# SOURCE GLOBAL CONFIG
###############################################################################
script_path=$(dirname "$(realpath -s "$0")")

# Look for backuparr.conf next to the script, or in /boot/config/plugins/user.scripts/
for _conf_candidate in \
    "$script_path/backuparr.conf" \
    "/boot/config/plugins/user.scripts/backuparr.conf" \
    "$BACKUP_LOCATION/backuparr.conf"; do
    if [[ -f "$_conf_candidate" ]]; then
        # shellcheck disable=SC1090
        . "$_conf_candidate"
        break
    fi
done

###############################################################################
# RUNTIME STATE
###############################################################################
is_user_script=0
now=$(date +"%Y-%m-%d")
create_only=0
dry_run=0
verbose=0
skip_gdrive=0
docker_name=""
STOPPED_DOCKER=""
snapshot_backups=0   # renamed from archive_backups; -a flag still sets this
NUM_DAILY=""         # CLI override for DEFAULT_LOCAL_SNAPSHOTS via -y

###############################################################################
# CLI ARGUMENT PARSING (all original flags preserved)
###############################################################################
while getopts "h?cufdvsan:b:g:y:" opt; do
    case "$opt" in
    h | \?)
        echo "Options:"
        echo "  -d          Dry Run"
        echo "  -v          Verbose"
        echo "  -s          Skip Google Drive Upload"
        echo "  -a          Enable snapshot creation"
        echo "  -c          Create per-app .conf files only"
        echo "  -n [docker] Only back up this single docker container"
        echo "  -u          Running from Unraid User.Scripts (enables notify)"
        echo "  -b [path]   Override backup location"
        echo "  -g [remote] Google Drive rclone remote (e.g. gdrive:unraid_backup)"
        echo "  -y [N]      Override default local snapshot count"
        exit 0
        ;;
    c) create_only=1 ;;
    d) dry_run=1; DRYRUN="--dry-run" ;;
    v) verbose=1; PROGRESS="--progress" ;;
    s) skip_gdrive=1 ;;
    a) snapshot_backups=1 ;;
    u) is_user_script=1 ;;
    n) docker_name=${OPTARG} ;;
    b) BACKUP_LOCATION=${OPTARG} ;;
    y) NUM_DAILY=${OPTARG} ;;
    g) GDRIVE_LOCATION=${OPTARG} ;;
    esac
done

# Apply -y override to the global default
if [[ -n "$NUM_DAILY" ]]; then
    DEFAULT_LOCAL_SNAPSHOTS=$NUM_DAILY
fi

###############################################################################
# UTILITY FUNCTIONS
###############################################################################

function converttime() {
    local total=$1
    ((h = total / 3600))
    ((m = (total % 3600) / 60))
    ((s = total % 60))
    if ((h > 0)); then
        printf "%02d hours, %02d minutes, %02d seconds" $h $m $s
    else
        printf "%02d minutes, %02d seconds" $m $s
    fi
}

###############################################################################
# TRAP / EXIT HANDLING
###############################################################################

trap 'ExitFunc' EXIT SIGINT SIGTERM SIGHUP SIGPIPE SIGQUIT
SUCCESS="false"

function ExitFunc() {
    local time_m
    time_m=$(converttime $SECONDS)

    # Restart any container we left stopped
    if [[ -n "$STOPPED_DOCKER" ]]; then
        docker start "$STOPPED_DOCKER" &>/dev/null &
    fi

    if [[ "$SUCCESS" != "true" ]]; then
        NotifyError "[Backup failed]" "Backup script exited abnormally after $time_m."
        exit 255
    else
        NotifyInfo "[Backup completed]" "Backup script completed successfully after $time_m."
        exit 0
    fi
}

###############################################################################
# PARENT-DEATH CHECK
###############################################################################

trap 'ShouldExit' RETURN
function ShouldExit() {
    local pid
    pid=$(cut -d' ' -f4 < /proc/$$/stat 2>/dev/null)
    if [[ -n "$pid" && "$PPID" != "$pid" ]]; then
        echo "Parent has died. Exiting."
        ExitFunc
    fi
}

###############################################################################
# LOGGING & NOTIFICATION
###############################################################################

function NotifyInfo() {
    if [[ $is_user_script -eq 1 ]]; then
        /usr/local/emhttp/webGui/scripts/notify -e "[Backup]" -s "$1" -d "$2" -i "normal" 2>/dev/null
    fi
    echo "$1 - $2"
}

function NotifyError() {
    if [[ $is_user_script -eq 1 ]]; then
        /usr/local/emhttp/webGui/scripts/notify -e "[Backup]" -s "$1" -d "$2" -i "alert" 2>/dev/null
    fi
    echo "[ERROR] $1 - $2"
}

function LogInfo()    { echo "$@"; ShouldExit; }
function LogVerbose() { [[ "$verbose" == "1" ]] && echo "$@"; ShouldExit; }
function LogWarning() { echo "[WARNING] $@"; ShouldExit; }
function LogError()   { echo "[ERROR] $@"; NotifyError "[Backup error]" "$@"; }

###############################################################################
# DOCKER STOP / START
###############################################################################

function stop_docker() {
    local op="[DOCKER STOP]"
    local stop_seconds=$SECONDS
    local name=$1 timeout=$2
    LogInfo "$op: STOPPING $name with timeout: $timeout"

    local RUNNING
    RUNNING=$(docker container inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
    if [[ "$RUNNING" == "false" ]]; then
        LogInfo "$op: Docker is already stopped!"
        return
    fi

    if [[ "$dry_run" == "0" ]]; then
        STOPPED_DOCKER=$name
        LogInfo "$op: STOPPED docker $(docker stop -t "$timeout" "$name") in $((SECONDS - stop_seconds)) Seconds"
    else
        return
    fi

    RUNNING=$(docker container inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
    if [[ "$RUNNING" == "false" ]]; then
        LogVerbose "$op: Docker Stopped Successfully"
    else
        LogWarning "$op: Docker not stopped. Force stopping..."
        docker stop -t 600 "$name"
    fi
}

function start_docker() {
    local op="[DOCKER START]"
    local start_seconds=$SECONDS
    local name=$1
    LogInfo "$op: STARTING $name"

    local RUNNING
    RUNNING=$(docker container inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
    if [[ "$RUNNING" == "true" ]]; then
        LogInfo "$op: Docker is already started!"
        return
    fi

    if [[ "$dry_run" == "0" ]]; then
        LogInfo "$op: STARTED docker $(docker start "$name") in $((SECONDS - start_seconds)) Seconds"
        STOPPED_DOCKER=""
    else
        return
    fi

    RUNNING=$(docker container inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
    if [[ "$RUNNING" == "true" ]]; then
        LogVerbose "$op: Docker Started Successfully"
    else
        LogWarning "$op: Docker not started. Retrying..."
        docker start "$name"
    fi
}

###############################################################################
# BUILD RSYNC EXCLUDE ARRAYS
###############################################################################

# Global exclude opts (used in rsync pass 2 — post-stop, authoritative)
exclude_opts=()
for item in "${EXCLUDE[@]}"; do
    exclude_opts+=(--exclude "$item")
done

# Pre-stop exclude opts (global + EXCLUDEPRE — skip volatile files in pass 1)
exclude_opts_pre=("${exclude_opts[@]}")
for item in "${EXCLUDEPRE[@]}"; do
    exclude_opts_pre+=(--exclude "$item")
done

###############################################################################
# PER-APP CONFIG HANDLING
###############################################################################

function create_config() {
    local op="[CONFIG]"
    [[ "$dry_run" == "1" ]] && LogInfo "$op: Skipping config create in DryRun" && return

    [[ ! -d "$T_PATH" ]] && mkdir -p "$T_PATH"

    local BACKUPCONFIG
    BACKUPCONFIG=$(cat "$T_PATH/$CONF_NAME" 2>/dev/null | grep -Ev '^\s*#|^\s*$')

    if [[ -z "$BACKUPCONFIG" ]]; then
        if [[ -f "$script_path/sample-configs/$CONF_NAME" ]]; then
            cp -f "$script_path/sample-configs/$CONF_NAME" "$T_PATH/$CONF_NAME"
            # shellcheck disable=SC1090
            . "$T_PATH/$CONF_NAME"
        else
            cp -f "$script_path/sample-configs/default-backup.conf" "$T_PATH/$CONF_NAME"
        fi
    else
        LogInfo "$op: Load Variables from $T_PATH/$CONF_NAME"
        LogInfo ""
        # shellcheck disable=SC1090
        . "$T_PATH/$CONF_NAME"
    fi

    if [[ "$create_only" == "1" ]]; then
        if [[ -f "$script_path/sample-configs/$CONF_NAME" ]]; then
            cp -u "$script_path/sample-configs/$CONF_NAME" "$T_PATH/$CONF_NAME"
        else
            cp -u "$script_path/sample-configs/default-backup.conf" "$T_PATH/$CONF_NAME"
        fi
        LogInfo "$op: $T_PATH/$CONF_NAME was created."
        return
    fi
}

###############################################################################
# LOCAL VERSIONING via rsync --backup-dir
#
# Instead of hard-link snapshots (which require same filesystem — not viable
# on Unraid's multi-disk FUSE shares), we use rsync's built-in --backup-dir.
#
# During the authoritative rsync pass, any file that is changed or deleted
# from Live/ is automatically moved to Changes/YYYY-MM-DD/ before being
# overwritten. Result:
#
#   Docker/appname/
#     Live/            ← always-current full copy
#     Changes/
#       2026-03-04/    ← only files that changed/were deleted that day
#       2026-03-05/
#       2026-03-06/
#
# This works on any filesystem, costs only delta storage, and requires no
# hard link support. Old Changes/ dirs are pruned per LOCAL_SNAPSHOTS.
###############################################################################

function prune_local_changes() {
    # Args: $1=changes_base_dir $2=retention_count $3=label
    local op="[PRUNE LOCAL]"
    local changes_base=$1
    local retention=$2
    local label=${3:-app}

    [[ ! -d "$changes_base" ]] && return

    local dir_list
    dir_list=$(ls -1d "$changes_base"/????-??-?? 2>/dev/null | sort -r)
    local count=0

    while IFS= read -r dated_dir; do
        [[ -z "$dated_dir" ]] && continue
        count=$((count + 1))
        if [[ $count -gt $retention ]]; then
            if [[ "$dry_run" == "0" ]]; then
                LogInfo "$op: Removing old changes dir $dated_dir ($label)"
                rm -rf "$dated_dir"
            else
                LogInfo "$op: [DRY RUN] Would remove $dated_dir ($label)"
            fi
        fi
    done <<< "$dir_list"
}

###############################################################################
# RCLONE INCREMENTAL UPLOAD (per-app)
#
# Uses --backup-dir to move changed/deleted files on the remote into
# a dated Versions/ directory. This keeps one current copy + minimal diffs.
###############################################################################

function rclone_upload_app() {
    # Args: $1=local_dir $2=remote_path $3=remote_snapshots $4=label
    local op="[RCLONE]"
    local local_dir=$1
    local remote_path=$2
    local remote_snapshots=$3
    local label=${4:-app}

    if [[ "$skip_gdrive" == "1" || -z "$GDRIVE_LOCATION" ]]; then
        return
    fi

    [[ ! -d "$local_dir" ]] && return

    local remote_base
    remote_base=$(dirname "$remote_path")
    local remote_name
    remote_name=$(basename "$remote_path")

    if [[ "$GDRIVE_INCREMENTAL" == "true" ]]; then
        local backup_dir="${remote_base}/Versions/${remote_name}/${now}"

        LogInfo "$op: Incremental upload $local_dir -> $remote_path (backup-dir: $backup_dir)"
        if [[ "$dry_run" == "0" ]]; then
            /usr/sbin/rclone copy \
                --backup-dir "$backup_dir" \
                --drive-chunk-size 64M \
                --retries 3 \
                --checkers 16 \
                --transfers 6 \
                --fast-list \
                --copy-links \
                $PROGRESS \
                "$local_dir/" "$remote_path/"
            if [[ $? -ne 0 ]]; then
                LogError "$op: rclone copy failed for $label"
            fi
        else
            LogInfo "$op: [DRY RUN] Would rclone copy $local_dir/ to $remote_path/"
        fi

        # Prune old remote version dirs
        prune_remote_versions "${remote_base}/Versions/${remote_name}" "$remote_snapshots" "$label"
    else
        # Legacy: plain rclone sync
        LogInfo "$op: Sync upload $local_dir -> $remote_path"
        if [[ "$dry_run" == "0" ]]; then
            /usr/sbin/rclone sync \
                --drive-chunk-size 64M \
                --retries 3 \
                --checkers 16 \
                --transfers 6 \
                --fast-list \
                --copy-links \
                $PROGRESS \
                "$local_dir/" "$remote_path/"
            if [[ $? -ne 0 ]]; then
                LogError "$op: rclone sync failed for $label"
            fi
        else
            LogInfo "$op: [DRY RUN] Would rclone sync $local_dir/ to $remote_path/"
        fi
    fi
}

function prune_remote_versions() {
    # Args: $1=remote_versions_path $2=retention $3=label
    local op="[RCLONE PRUNE]"
    local remote_versions=$1
    local retention=$2
    local label=${3:-app}

    # List dated directories on the remote
    local dirs
    dirs=$(/usr/sbin/rclone lsf --dirs-only "$remote_versions/" 2>/dev/null | sort -r)
    local count=0

    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        count=$((count + 1))
        if [[ $count -gt $retention ]]; then
            if [[ "$dry_run" == "0" ]]; then
                LogInfo "$op: Removing old remote version $remote_versions/$dir ($label)"
                /usr/sbin/rclone purge "$remote_versions/$dir" 2>/dev/null
            else
                LogInfo "$op: [DRY RUN] Would remove $remote_versions/$dir ($label)"
            fi
        fi
    done <<< "$dirs"
}

###############################################################################
# BACKUP A DOCKER CONTAINER
###############################################################################

function backup_docker() {
    local op="[BACKUP DOCKER]"
    local START_TIME=$SECONDS
    local D_NAME=$1

    [[ -z "$D_NAME" ]] && LogInfo "Docker name is a required param" && return

    # Per-app paths
    local T_PATH="$BACKUP_LOCATION/Docker/$D_NAME"
    local D_PATH="$T_PATH/Live"
    local CHANGES_PATH="$T_PATH/Changes/$now"
    local CONF_NAME="${D_NAME}-backup.conf"

    # Per-app defaults (overridden by .conf if present)
    local TIMEOUT=$DEFAULT_TIMEOUT
    local BACKUP="true"
    local FORCESTART="false"
    local EXCLUDES=""
    local EXCLUDE_DIRS=""
    local LOCAL_SNAPSHOTS=$DEFAULT_LOCAL_SNAPSHOTS
    local REMOTE_SNAPSHOTS=$DEFAULT_REMOTE_SNAPSHOTS

    LogInfo "================================================================="
    LogInfo "Docker: $D_NAME [Start Time: $(date)]"
    LogInfo "================================================================="

    # Load per-app config (may override TIMEOUT, BACKUP, FORCESTART, EXCLUDES,
    # EXCLUDE_DIRS, LOCAL_SNAPSHOTS, REMOTE_SNAPSHOTS)
    create_config

    [[ "$create_only" == "1" ]] && return

    # Save docker inspect JSON for reference
    docker inspect "$D_NAME" > "$T_PATH/${D_NAME}-dockerconfig.json" 2>/dev/null

    # Determine source path (appdata location)
    local S_PATH=""
    if [[ -d "/mnt/cache/appdata/$D_NAME" ]]; then
        S_PATH="/mnt/cache/appdata/$D_NAME"
        LogInfo "Using $S_PATH as backup source"
    fi

    if [[ -z "$S_PATH" ]]; then
        S_PATH=$(docker inspect -f '{{json .Mounts }}' "$D_NAME" 2>/dev/null \
            | jq -r '.[].Source' \
            | grep 'appdata/' \
            | grep -i "$D_NAME" \
            | head -1 \
            | tr -d '\n')
    fi

    if [[ -z "$S_PATH" ]]; then
        S_PATH=$(docker inspect -f '{{json .Mounts }}' "$D_NAME" 2>/dev/null \
            | jq -r '.[].Source' \
            | grep 'appdata/' \
            | head -1 \
            | tr -d '\n')
    fi

    if [[ ! -d "$S_PATH" ]]; then
        LogWarning "Could not find $S_PATH"
        echo
        return
    fi
    if [[ -z "$S_PATH" ]]; then
        LogWarning "Could not find a source path for $D_NAME"
        echo
        return
    fi

    [[ ! -d "$D_PATH" ]] && mkdir -p "$D_PATH"
    touch "$D_PATH"

    # Build per-app exclude arrays
    local pre_excludes=("${exclude_opts_pre[@]}")
    local full_excludes=("${exclude_opts[@]}")

    # Per-app file/pattern excludes (EXCLUDES from .conf)
    if [[ -n "$EXCLUDES" ]]; then
        for item in "${EXCLUDES[@]}"; do
            pre_excludes+=(--exclude "$item")
            full_excludes+=(--exclude "$item")
        done
    fi

    # Per-app directory-content exclusion (EXCLUDE_DIRS from .conf)
    # Backs up the directory itself but excludes its contents
    if [[ -n "$EXCLUDE_DIRS" ]]; then
        for dir in "${EXCLUDE_DIRS[@]}"; do
            # Remove trailing slash for consistency, then add /*
            dir="${dir%/}"
            pre_excludes+=(--exclude "${dir}/*")
            full_excludes+=(--exclude "${dir}/*")
        done
    fi

    [[ "$BACKUP" != "true" ]] && LogInfo "$op: Skipping Docker $D_NAME (BACKUP=$BACKUP)" && return

    local RUNNING
    RUNNING=$(docker container inspect -f '{{.State.Running}}' "$D_NAME" 2>/dev/null)

    printf "Dest Path: \t %s\n" "$D_PATH"
    printf "Source Path: \t %s\n" "$S_PATH"
    [[ "$snapshot_backups" == "1" ]] && printf "Changes Path: \t %s\n" "$CHANGES_PATH"
    printf "Running: \t %s\n" "$RUNNING"
    printf "Stop Timeout: \t %s\n" "$TIMEOUT"
    printf "Local Versions: \t %s\n" "$LOCAL_SNAPSHOTS"
    printf "Remote Versions: \t %s\n" "$REMOTE_SNAPSHOTS"
    [[ -n "$EXCLUDES" ]] && printf "Excludes: \t (%s)\n" "${EXCLUDES[*]}"
    [[ -n "$EXCLUDE_DIRS" ]] && printf "Exclude Dirs: \t (%s)\n" "${EXCLUDE_DIRS[*]}"
    echo ""

    # --- RSYNC PASS 1: Copy files BEFORE docker stop (with pre-excludes) ---
    LogInfo "$op: RSYNC Run 1 - Copy files BEFORE docker stop"
    if [[ "$RUNNING" == "true" && "$TIMEOUT" != "0" ]]; then
        LogVerbose "$op: rsync -a $PROGRESS -h ${pre_excludes[*]} $DRYRUN $S_PATH/ $D_PATH/"
        rsync -a $PROGRESS -h "${pre_excludes[@]}" $DRYRUN "$S_PATH/" "$D_PATH/"
        if [[ $? -ne 0 ]]; then
            LogWarning "$op: RSYNC RUN 1 Failed"
        fi
        stop_docker "$D_NAME" "$TIMEOUT"
    else
        LogInfo "$op: Skipped Docker Stop (State=$RUNNING, Timeout=$TIMEOUT)"
    fi

    # --- RSYNC PASS 2: Authoritative copy AFTER docker stop ---
    # --backup --backup-dir moves changed/deleted files to Changes/YYYY-MM-DD/
    # before overwriting them. Works on any filesystem (no hard links needed).
    LogInfo "$op: RSYNC RUN 2 - Copy files AFTER docker stop"
    local backup_dir_opts=()
    if [[ "$snapshot_backups" == "1" ]]; then
        mkdir -p "$CHANGES_PATH"
        backup_dir_opts=(--backup --backup-dir "$CHANGES_PATH")
    fi
    LogVerbose "$op: rsync -a $PROGRESS -h ${full_excludes[*]} ${backup_dir_opts[*]} --delete --delete-excluded $DRYRUN $S_PATH/ $D_PATH/"
    rsync -a $PROGRESS -h "${full_excludes[@]}" "${backup_dir_opts[@]}" --delete --delete-excluded $DRYRUN "$S_PATH/" "$D_PATH/"
    if [[ $? -ne 0 ]]; then
        LogError "$op: RSYNC RUN 2 Failed"
    fi

    # --- Restart docker ---
    LogInfo "$op: Start docker if previously running, autostart enabled, or forcestart is true"
    local autostart=""
    if [[ -f /var/lib/docker/unraid-autostart ]]; then
        autostart=$(cut -f 1 -d " " /var/lib/docker/unraid-autostart | grep -E "^${D_NAME}$")
    fi
    LogVerbose "$op: autostart = $autostart"

    if [[ "$FORCESTART" != "false" ]] || [[ "$autostart" == "$D_NAME" ]] || [[ "$RUNNING" == "true" && "$TIMEOUT" != "0" ]]; then
        start_docker "$D_NAME"
    else
        LogInfo "$op: Docker Start Skipped. FORCESTART=$FORCESTART, RUNNING=$RUNNING, TIMEOUT=$TIMEOUT"
    fi

    # --- Prune old local Changes/ dirs beyond retention ---
    if [[ "$snapshot_backups" == "1" ]]; then
        prune_local_changes "$T_PATH/Changes" "$LOCAL_SNAPSHOTS" "$D_NAME"
    fi

    echo ""
    echo "End Time: $(date) [Elapsed $((SECONDS - START_TIME)) Seconds]"
    echo "================================================================="
    echo ""
}

###############################################################################
# BACKUP EXTRA DIRECTORIES (non-Docker)
###############################################################################

function backup_extra_dirs() {
    local op="[EXTRA DIRS]"

    [[ ${#EXTRA_DIRS[@]} -eq 0 ]] && return
    [[ "$create_only" == "1" ]] && return

    LogInfo ""
    LogInfo "================================================================="
    LogInfo "Extra Directories Backup [$(date)]"
    LogInfo "================================================================="
    LogInfo ""

    for entry in "${EXTRA_DIRS[@]}"; do
        # Parse colon-separated format: source:dest_name:local_snapshots:remote_snapshots
        IFS=':' read -r src_path dest_name local_snaps remote_snaps <<< "$entry"

        if [[ -z "$src_path" || -z "$dest_name" ]]; then
            LogWarning "$op: Invalid EXTRA_DIRS entry: $entry (need at least source:dest_name)"
            continue
        fi

        # Fall back to global defaults
        [[ -z "$local_snaps" || "$local_snaps" == "0" ]] && local_snaps=$DEFAULT_LOCAL_SNAPSHOTS
        [[ -z "$remote_snaps" || "$remote_snaps" == "0" ]] && remote_snaps=$DEFAULT_REMOTE_SNAPSHOTS

        local base_dir="$BACKUP_LOCATION/ExtraDirs/$dest_name"
        local live_dir="$base_dir/Live"
        local changes_dir="$base_dir/Changes/$now"

        LogInfo "$op: Backing up $src_path -> $dest_name"
        LogInfo "$op:   Live: $live_dir"
        LogInfo "$op:   Snapshots: $snap_dir (keep $local_snaps)"
        LogInfo "$op:   Remote snapshots: $remote_snaps"

        if [[ ! -d "$src_path" ]]; then
            LogWarning "$op: Source path $src_path does not exist, skipping"
            continue
        fi

        [[ ! -d "$live_dir" ]] && mkdir -p "$live_dir"

        # Rsync source to Live/, using --backup-dir to capture deltas
        LogInfo "$op: Syncing $src_path -> $live_dir"
        local extra_backup_opts=()
        if [[ "$snapshot_backups" == "1" ]]; then
            mkdir -p "$changes_dir"
            extra_backup_opts=(--backup --backup-dir "$changes_dir")
        fi
        rsync -a $PROGRESS -h "${exclude_opts[@]}" "${extra_backup_opts[@]}" --delete --delete-excluded $DRYRUN "$src_path/" "$live_dir/"
        if [[ $? -ne 0 ]]; then
            LogError "$op: rsync failed for $dest_name"
        fi

        # Prune old local Changes/ dirs beyond retention
        if [[ "$snapshot_backups" == "1" ]]; then
            prune_local_changes "$base_dir/Changes" "$local_snaps" "$dest_name"
        fi

        # Rclone upload (incremental)
        if [[ -n "$GDRIVE_LOCATION" && "$skip_gdrive" != "1" ]]; then
            local remote_path="$GDRIVE_LOCATION/ExtraDirs/$dest_name"
            rclone_upload_app "$live_dir" "$remote_path" "$remote_snaps" "$dest_name"
        fi

        echo ""
    done
}

###############################################################################
# FLASH DRIVE BACKUP
###############################################################################

function BackupFlash() {
    local op="[BACKUP FLASH]"

    if [[ "$create_only" != "1" && -z "$docker_name" ]]; then
        LogInfo "$op: Starting Flash Backup..."
        if [[ "$dry_run" != "0" ]]; then
            LogInfo "$op: Skipping flash_backup in dry run"
        else
            local backup_file
            backup_file=$(/usr/local/emhttp/webGui/scripts/flash_backup 2>/dev/null)
            if [[ $? -ne 0 ]]; then
                LogError "$op: flash_backup failed"
            fi

            if [[ -f "/$backup_file" ]]; then
                mkdir -p "$BACKUP_LOCATION/Flash"
                find /usr/local/emhttp/ -maxdepth 1 -name '*flash-backup-*.zip' -delete
                mv "/$backup_file" "$BACKUP_LOCATION/Flash/"
                find "$BACKUP_LOCATION/Flash" -mtime +${DEFAULT_LOCAL_SNAPSHOTS} -name '*.zip' -delete
            fi
        fi
        LogInfo "$op: Flash Backup completed."
    fi
}

###############################################################################
# GET DOCKER CONTAINER LIST
###############################################################################

function GetDockerList() {
    local containers=""

    # Prefer Unraid user prefs ordering
    if [[ -f /boot/config/plugins/dockerMan/userprefs.cfg ]]; then
        containers=$(cut -f 2 -d '"' /boot/config/plugins/dockerMan/userprefs.cfg | grep -Ev '\-folder$')
    fi

    local containers_from_docker
    containers_from_docker=$(docker ps -a --format '{{.Names}}' | sort -f)

    if [[ -n "$containers" ]]; then
        echo "$containers"
        for container_from_docker in $containers_from_docker; do
            local already_found
            already_found=$(echo "$containers" | grep -E "$container_from_docker")
            if [[ -z "$already_found" ]]; then
                echo "$container_from_docker"
            fi
        done
    else
        echo "$containers_from_docker"
    fi
}

###############################################################################
# MAIN EXECUTION
###############################################################################

echo ""
echo "---- Backup Started [$(date)] ----"
echo ""

# Flash backup first
BackupFlash

# Docker container backups
if [[ -z "$docker_name" ]]; then
    for container in $(GetDockerList); do
        backup_docker "$container"
    done
else
    container=$(docker ps -a --format '{{.Names}}' | grep -iE "^${docker_name}$")
    if [[ -n "$container" ]]; then
        backup_docker "$container"
    else
        LogWarning "Could not find $docker_name. Run 'docker ps -a' to check."
        echo
    fi
fi

# Extra directories backup
backup_extra_dirs

echo "---- Backup Complete [$(date)] ----"
echo ""

###############################################################################
# GOOGLE DRIVE UPLOAD (Docker containers)
###############################################################################

if [[ "$create_only" == "1" || "$dry_run" == "1" || "$skip_gdrive" == "1" || -z "$GDRIVE_LOCATION" ]]; then
    SUCCESS="true"
    exit
fi

echo "---- Starting Google Drive upload [$(date)] ----"
echo ""

# Upload each Docker container's Live/ directory individually
# This enables per-app --backup-dir versioning
if [[ -d "$BACKUP_LOCATION/Docker" ]]; then
    for app_dir in "$BACKUP_LOCATION/Docker"/*/; do
        [[ ! -d "$app_dir" ]] && continue
        local_app_name=$(basename "$app_dir")
        live_dir="$app_dir/Live"

        [[ ! -d "$live_dir" ]] && continue

        # Load per-app remote snapshot count
        local app_remote_snaps=$DEFAULT_REMOTE_SNAPSHOTS
        local app_conf="$app_dir/${local_app_name}-backup.conf"
        if [[ -f "$app_conf" ]]; then
            # Source just REMOTE_SNAPSHOTS if set
            local _rs
            _rs=$(grep -E '^\s*REMOTE_SNAPSHOTS=' "$app_conf" 2>/dev/null | tail -1 | cut -d= -f2)
            [[ -n "$_rs" ]] && app_remote_snaps=$_rs
        fi

        remote_path="$GDRIVE_LOCATION/Docker/$local_app_name"
        rclone_upload_app "$live_dir" "$remote_path" "$app_remote_snaps" "$local_app_name"
    done
fi

# Upload Flash backups
if [[ -d "$BACKUP_LOCATION/Flash" ]]; then
    LogInfo "[RCLONE]: Uploading Flash backups"
    if [[ "$dry_run" == "0" ]]; then
        /usr/sbin/rclone copy \
            --drive-chunk-size 64M \
            --retries 3 \
            --fast-list \
            --copy-links \
            $PROGRESS \
            "$BACKUP_LOCATION/Flash/" "$GDRIVE_LOCATION/Flash/"
        if [[ $? -ne 0 ]]; then
            LogError "[RCLONE]: Flash upload failed"
        fi
    fi
fi

# Note: ExtraDirs are uploaded inline during backup_extra_dirs()

SUCCESS="true"
echo ""
echo "---- Google Drive upload Complete [$(date)] ----"
echo ""
