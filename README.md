# unraid_backup

Efficient Docker + appdata backup for Unraid using rsync and rclone.

Forked from [vaparr/backuparr](https://github.com/vaparr/backuparr) and significantly extended.

---

## Features

- **Rsync delta versioning** — instead of daily full tarballs, only changed/deleted files are saved per day. Works on Unraid's multi-disk FUSE shares (no hard links required)
- **Incremental Google Drive uploads** — one current copy on Drive + dated diff directories. Stops N × 60GB uploads
- **Per-app subdirectory exclusion** — back up a container's config but skip its `uploads/` or `thumbnails/` contents
- **Per-app configurable retention** — different local and remote version counts per container
- **Extra directories** — back up arbitrary paths outside of Docker appdata (e.g. `/mnt/cache/project_triad`)
- **Centralised config** — all global defaults in `backuparr.conf`, overridden per-app via individual `.conf` files

---

## Backup Layout

All backups land under `BACKUP_LOCATION` (default `/mnt/user/backup`):

```
/mnt/user/backup/
  Docker/
    <appname>/
      <appname>-backup.conf         ← per-app config
      <appname>-dockerconfig.json   ← docker inspect snapshot
      Live/                         ← full current copy of appdata (restore source)
      Changes/
        2026-03-05/                 ← files changed/deleted on that day (delta only)
        2026-03-06/
  ExtraDirs/
    <dirname>/
      Live/                         ← full current copy
      Changes/
        2026-03-06/
  Flash/
    flash-backup-2026-03-06.zip     ← Unraid flash drive backup
```

On **Google Drive** (`gdrive:unraid_backup`):

```
  Docker/
    <appname>/          ← mirror of Live/ (current state)
  Versions/
    <appname>/
      2026-03-06/       ← files changed/deleted on Drive that day
  ExtraDirs/
    <dirname>/
  Flash/
```

> **`Live/` is always the complete, ready-to-restore copy.** `Changes/` and `Versions/` are safety nets for rolling back individual files.

---

## Quick Start

### 1. Configure rclone (one-time)

```bash
rclone config
# Add a remote named "gdrive" pointing to your Google Drive account
```

### 2. Set up `backuparr.conf`

Copy `backuparr.conf` from the repo into the **same directory as `user.script.sh`** on your Unraid server. The launcher automatically detects its own directory and passes the conf path to `backuparr.sh` via `-C`, so it works regardless of what the script directory is named.

Typical location:
```
/boot/config/plugins/user.scripts/scripts/<your_script_name>/backuparr.conf
```

Edit it to match your setup:

```bash
BACKUP_LOCATION=/mnt/user/backup
GDRIVE_LOCATION=gdrive:unraid_backup
DEFAULT_LOCAL_SNAPSHOTS=3     # how many daily Changes/ dirs to keep
DEFAULT_REMOTE_SNAPSHOTS=7    # how many remote Versions/ dirs to keep
GDRIVE_INCREMENTAL=true

# Optional: back up directories outside Docker appdata
EXTRA_DIRS=(
    "/mnt/cache/project_triad:project_triad:3:2"
)
```

### 3. Add to Unraid User.Scripts

In the Unraid UI, add `user.script.sh` as a new User Script and set it to run daily at 2am. It will auto-pull the latest version of the scripts from GitHub on each run.

### 4. Generate per-app config files

```bash
bash backuparr.sh -c
```

This creates `<appname>-backup.conf` for every container under `$BACKUP_LOCATION/Docker/<appname>/`. Edit them to customise per-app behaviour.

---

## Configuration

### Global (`backuparr.conf`)

| Variable | Default | Description |
|---|---|---|
| `BACKUP_LOCATION` | `/mnt/user/backup` | Local backup root |
| `GDRIVE_LOCATION` | `gdrive:unraid_backup` | rclone remote path |
| `DEFAULT_TIMEOUT` | `30` | Docker stop timeout (seconds). `0` = don't stop |
| `DEFAULT_LOCAL_SNAPSHOTS` | `3` | Daily `Changes/` dirs to keep locally |
| `DEFAULT_REMOTE_SNAPSHOTS` | `7` | Dated `Versions/` dirs to keep on Drive |
| `GDRIVE_INCREMENTAL` | `true` | Use `--backup-dir` on Drive. `false` = plain sync |
| `EXCLUDE` | `(profile/lock *.pid ...)` | Global rsync excludes (all containers) |
| `EXCLUDEPRE` | `(*.dat.old)` | Extra excludes for pre-stop rsync pass only |
| `EXTRA_DIRS` | `()` | Non-Docker dirs to back up (see below) |
| `EXCLUDE_CONTAINERS` | `()` | Container names to skip entirely (no backup, no dirs created) |

### Per-app (`<appname>-backup.conf`)

| Variable | Default | Description |
|---|---|---|
| `TIMEOUT` | `DEFAULT_TIMEOUT` | Docker stop timeout for this container |
| `BACKUP` | `"true"` | Set to `"false"` to skip this container |
| `FORCESTART` | `"false"` | Start container after backup even if it was stopped |
| `EXCLUDES` | `()` | Extra rsync file/pattern excludes for this app |
| `EXCLUDE_DIRS` | `()` | Exclude directory *contents* (keeps dir, drops files) |
| `LOCAL_SNAPSHOTS` | `DEFAULT_LOCAL_SNAPSHOTS` | Local `Changes/` dirs to keep for this app |
| `REMOTE_SNAPSHOTS` | `DEFAULT_REMOTE_SNAPSHOTS` | Remote `Versions/` dirs to keep for this app |

#### Example: bleeper

```bash
# Keep the uploads/ dir but not its contents (avoids backing up large uploads)
EXCLUDE_DIRS=(uploads/ thumbnails/)

# Keep more remote versions for this app
REMOTE_SNAPSHOTS=14

# Don't stop the container during backup
TIMEOUT=0
```

### Extra Directories

Add non-Docker paths to `backuparr.conf`:

```bash
EXTRA_DIRS=(
    "/mnt/cache/project_triad:project_triad:3:2"
    "/mnt/user/documents:documents:5:7"
)
```

Format: `"source_path:dest_name:local_snapshots:remote_snapshots"`

---

## CLI Flags

```
-d          Dry run (no changes made)
-v          Verbose output
-s          Skip Google Drive upload
-a          Enable delta versioning (saves Changes/ dirs locally)
-c          Create per-app .conf files only, no backup
-n <name>   Only back up this single container
-u          Running from Unraid User.Scripts (enables notify popups)
-b <path>   Override backup location
-g <remote> Override Google Drive rclone remote
-y <N>      Override default local snapshot count
```

---

## Restoring

### Restore a single file or small number of files

Use this when a config file was accidentally deleted or corrupted and you need to recover a previous version.

**From local backup (fastest):**

```bash
# Find which Changes/ dir contains the file you need
ls /mnt/user/backup/Docker/<appname>/Changes/

# Example: recover a specific file from yesterday's changes
cp /mnt/user/backup/Docker/<appname>/Changes/2026-03-05/config.xml \
   /mnt/cache/appdata/<appname>/config.xml
```

**From Google Drive (if local backup is gone):**

```bash
# List available version directories on Drive
rclone lsf gdrive:unraid_backup/Versions/<appname>/

# Copy a specific file from a dated version dir
rclone copy "gdrive:unraid_backup/Versions/<appname>/2026-03-05/config.xml" \
            /mnt/cache/appdata/<appname>/
```

> **Tip:** If the file exists in `Live/` and hasn't been corrupted, you can just copy directly from there without touching `Changes/` at all.

---

### Restore a full container (one app)

Use this to fully restore a single Docker container's appdata — e.g. after accidental deletion or a failed migration.

**Step 1: Stop the container**

```bash
docker stop <appname>
```

**Step 2: Restore from Live/**

`Live/` always holds the most recent complete copy:

```bash
rsync -a /mnt/user/backup/Docker/<appname>/Live/ \
         /mnt/cache/appdata/<appname>/
```

**Step 3: (Optional) Roll back to a specific date**

If today's `Live/` is already corrupted and you need an older state, reconstruct it from a previous day by replaying `Changes/` dirs in reverse:

```bash
# Start from Live/ as base, then overlay changes from the date you want to roll back to
# Example: roll back to state as of 2026-03-04
rsync -a /mnt/user/backup/Docker/<appname>/Live/ /tmp/<appname>-restore/
rsync -a /mnt/user/backup/Docker/<appname>/Changes/2026-03-05/ /tmp/<appname>-restore/
rsync -a /mnt/user/backup/Docker/<appname>/Changes/2026-03-06/ /tmp/<appname>-restore/
# /tmp/<appname>-restore/ now reflects the state before 2026-03-05's changes
rsync -a /tmp/<appname>-restore/ /mnt/cache/appdata/<appname>/
```

**Step 4: Start the container**

```bash
docker start <appname>
```

**Restoring from Google Drive (if local backup is unavailable):**

```bash
docker stop <appname>
rclone copy "gdrive:unraid_backup/Docker/<appname>/" \
            /mnt/cache/appdata/<appname>/
docker start <appname>
```

---

### Full restore on a fresh Unraid installation

Use this after a full system rebuild — new Unraid install, containers need to be re-created and data restored.

**Step 1: Restore the Unraid flash drive**

On the new system, restore the flash backup first so your array config, shares, and Docker templates are recovered:

```bash
# Flash backups are in $BACKUP_LOCATION/Flash/ or gdrive:unraid_backup/Flash/
# Unzip to a USB drive and boot from it, OR use Unraid's built-in flash restore tool
ls /mnt/user/backup/Flash/
# or
rclone ls gdrive:unraid_backup/Flash/
```

**Step 2: Restore the array and start Docker**

Boot Unraid, verify your array config came back correctly from the flash restore, start the array, and ensure the Docker service is running.

**Step 3: Re-create containers (templates)**

Your Docker templates are stored on the flash drive (restored in Step 1). In the Unraid UI, go to **Docker → Add Container** — your previous templates should be available. Add each container but **do not start them yet**.

**Step 4: Restore appdata for each container**

Pull `Live/` back to appdata from local backup (if the array/cache drive is intact):

```bash
for app in /mnt/user/backup/Docker/*/; do
    appname=$(basename "$app")
    echo "Restoring $appname..."
    mkdir -p /mnt/cache/appdata/$appname
    rsync -a "$app/Live/" /mnt/cache/appdata/$appname/
done
```

Or restore from Google Drive (if restoring to a completely new machine):

```bash
# Download all Docker Live/ dirs from Drive
rclone copy gdrive:unraid_backup/Docker/ /mnt/user/backup/Docker/ \
    --exclude "Versions/**"

# Then rsync to appdata as above
for app in /mnt/user/backup/Docker/*/; do
    appname=$(basename "$app")
    echo "Restoring $appname..."
    mkdir -p /mnt/cache/appdata/$appname
    rsync -a "$app/Live/" /mnt/cache/appdata/$appname/
done
```

**Step 5: Restore extra directories (if any)**

```bash
# Local
rsync -a /mnt/user/backup/ExtraDirs/project_triad/Live/ /mnt/cache/project_triad/

# Or from Drive
rclone copy gdrive:unraid_backup/ExtraDirs/project_triad/ /mnt/cache/project_triad/
```

**Step 6: Start containers**

Once all appdata is restored, start your containers:

```bash
# Start all at once via Unraid UI, or one by one:
docker start <appname>
```

**Step 7: Re-add the backup cron**

Add `user.script.sh` back as a User Script in the Unraid UI and set it to run daily.

---

## Troubleshooting

**Backup script exits with error 255**
Check the Unraid notification centre — the script sends an alert on abnormal exit. Look at the script output log in User.Scripts for the specific error.

**Container not stopping cleanly**
Set `TIMEOUT=0` in its `.conf` to skip stopping it (live rsync only — slightly less consistent but safe for most apps).

**rclone failing on large files**
Increase `--drive-chunk-size` in the rclone section of `backuparr.sh` (currently `64M`). For very large apps, `256M` can help.

**Changes/ dirs not being created**
Make sure you're passing the `-a` flag in `user.script.sh`. Without `-a`, only `Live/` is maintained (no versioning).
