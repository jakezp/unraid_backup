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
#
# CONFIGURATION:
#   Place backuparr.conf in the SAME directory as this script.
#   It will be passed to backuparr.sh via -C so it is always found
#   regardless of what this script's directory is named.
###############################################################################

REPO_NAME=unraid_backup
REPO_LOCATION=/tmp/$REPO_NAME
REPO_URL=https://github.com/jakezp/$REPO_NAME.git
SCRIPT_NAME=backuparr.sh

# Resolve the directory this script lives in — backuparr.conf should be here
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/backuparr.conf"

trap "kill -- $$" EXIT SIGINT SIGTERM SIGHUP SIGPIPE SIGQUIT

echo "Options:"
echo "  -d : Dry Run"
echo "  -v : Verbose"
echo "  -s : Skip Google Drive Upload"
echo "  -a : Enable delta versioning (saves Changes/ dirs)"
echo "  -c : Create per-app .conf files only"
echo "  -n [docker] : Only back up this single docker container"
echo "  -u : Running from Unraid User.Scripts (enables notify)"
echo "  -b : Backup location (Default: /mnt/user/backup)"
echo "  -g : Google Drive rclone remote (configure in rclone)"
echo "  -y : Override default local snapshot count"
echo "  -C : Explicit path to backuparr.conf (set automatically below)"

# Clone repo if it doesn't exist, then force-update to latest master
[ ! -d "$REPO_LOCATION" ] && mkdir -p "$REPO_LOCATION" && cd "$REPO_LOCATION" && git clone "$REPO_URL"
cd "$REPO_LOCATION/$REPO_NAME" && git fetch --all && git reset --hard origin/master && git pull --ff-only

# Make scripts executable
chmod +x "$REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME"

# Pass -C so backuparr.sh knows exactly where the conf is, regardless of
# where this script's directory is named or located on the system.
if [[ -f "$CONF_FILE" ]]; then
    exec /bin/bash "$REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME" -a -u -C "$CONF_FILE"
else
    echo "[WARNING] backuparr.conf not found at $CONF_FILE — running with defaults"
    echo "          Copy backuparr.conf from the repo to $SCRIPT_DIR/ to configure."
    exec /bin/bash "$REPO_LOCATION/$REPO_NAME/$SCRIPT_NAME" -a -u
fi
