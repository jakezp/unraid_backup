#!/bin/bash
#arrayStarted=true
###############################################################################
# user.script.sh — Unraid User.Scripts launcher for backuparr
#
# This script:
#   1. Clones/updates the unraid_backup repo from GitHub
#   2. Makes the backup script executable
#   3. Executes backuparr.sh with the desired flags
#
# Runs as a daily cron via Unraid's User.Scripts plugin.
###############################################################################

REPO_NAME=unraid_backup
REPO_LOCATION=/tmp/$REPO_NAME
REPO_URL=https://github.com/jakezp/$REPO_NAME.git
SCRIPT_NAME=backuparr.sh
CONF_NAME=backuparr.conf

trap "kill -- $$" EXIT SIGINT SIGTERM SIGHUP SIGPIPE SIGQUIT

echo "Options:"
echo "  -d : Dry Run"
echo "  -v : Verbose"
echo "  -s : Skip Google Drive Upload"
echo "  -a : Enable snapshot creation (hard-link snapshots instead of tarballs)"
echo "  -c : Create per-app .conf files only"
echo "  -n [docker] : Only back up this single docker container"
echo "  -u : Running from Unraid User.Scripts (enables notify)"
echo "  -b : Backup location (Default: /mnt/user/backup)"
echo "  -g : Google Drive rclone remote (configure in rclone)"
echo "  -y : Override default local snapshot count"

# Clone repo if it doesn't exist, then force-update to latest master
[ ! -d "$REPO_LOCATION" ] && mkdir -p "$REPO_LOCATION" && cd "$REPO_LOCATION" && git clone "$REPO_URL"
cd "$REPO_LOCATION/$REPO_NAME" && git fetch --all && git reset --hard origin/master && git pull --ff-only

# Make scripts executable
chmod +x "$REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME"

# If a local backuparr.conf exists in the backup location, copy it next to the
# script so it gets sourced. This lets you customise without forking the repo.
# The script also checks /boot/config/plugins/user.scripts/backuparr.conf and
# $BACKUP_LOCATION/backuparr.conf as fallback locations.

# Execute the backup script.
#
# Flags always needed:
#   -a   Enable delta versioning (saves Changes/ dirs). Remove to run Live/-only backups.
#   -u   Running from Unraid User.Scripts (enables notify popups in the UI).
#
# Flags NOT needed if backuparr.conf is configured on this server:
#   -g   Overrides GDRIVE_LOCATION from backuparr.conf (omit if conf is set up)
#   -y   Overrides DEFAULT_LOCAL_SNAPSHOTS from backuparr.conf (omit if conf is set up)
#
# Recommended: place backuparr.conf at /boot/config/plugins/user.scripts/backuparr.conf
# and set GDRIVE_LOCATION + DEFAULT_LOCAL_SNAPSHOTS there instead of using -g/-y here.
exec /bin/bash "$REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME" -a -u

# Legacy examples (use these only if you are NOT using backuparr.conf):
# exec /bin/bash "$REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME" -a -u -g gdrive:unraid_backup -y 3
# exec /bin/bash "$REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME" -a -u -b /path/to/backupFolder -g gdrive:unraid_backup
