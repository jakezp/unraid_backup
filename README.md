# UNRAID backup
Forked from *vaparr/backuparr* and tweaked for my specific use case

---
### To be updated
Backup dockers from unraid efficiently


Looking for help on writing the readme.  Please create an issue if you have ideas on what to add, or submit a PR!

        echo Options:
        echo "-d : Dry Run"
        echo "-v : Verbose"
        echo "-s : Skip OneDrive Upload"
        echo "-a : Archive live backup to tgz (configure ARCHIVE_DAYS in DockerName-backup.conf)"
        echo "-c : Create Backup.config files only"
        echo "-n [docker] : Only backup this single docker"
        echo "-u : Use when calling from Unraid User.Scripts to adjust output to not flood logs"
        echo "-b : Backup location (Default: /mnt/user/backup)"
        echo "-o : OneDrive location (configure in rclone)"
        echo "-y : Sets the number of archive days. Defaults to 3, can be overridden in .conf"


Clone repro, and run backuparr.sh -c

This will create the .conf files in /mnt/user/backup/Docker/<name>/<name>-backup.conf

It will look like this by default:

<p>  # docker timeout before force kill. Set to 0 to not stop the docker when backing it up</p>
<p>  #TIMEOUT=30</p>
<p></p>
<p>  #false will prevent the docker from being backed up. Default True</p>
<p>  #BACKUP="false"</p>
<p></p>
<p>  #true will start the docker even if it wasnt running when the backup started</p>
<p>  #FORCESTART="true"</p>
<p></p>
<p>  #Per Docker Excludes</p>
<p>  #EXCLUDES=(data/metadata cache/ '\*.tmp')</p>
<p></p>
 <p> #Number of Archive tarred backups</p>
 <p> #ARCHIVE_DAYS=3</p>

This is where you can override the defaults.  For example, if you change

  \#TIMEOUT=30

to

  TIMEOUT=0

this will tell the script NOT to stop the container before backing it up.  This is useful if you are sure no files are going to change while the backup is running.

