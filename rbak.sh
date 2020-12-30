#!/bin/bash
###############################################################################
# rbak.sh - Creates a backup of the currently running system with rsync
###############################################################################
# copy(l)eft - 2020 - https://harald.ist.org/ - harald@ist.org
###############################################################################
#
# 1. OVERVIEW
# ===========
#
# Creating a backup of an operating system, while it runs, can be dangerous.
#
# When parts of the file system have already been copied to the backup, changes
# to those parts will not be reflected in the copy, and inconsistensies may
# may lead to an unusable backup. Specific programs may no longer work
# correctly, when the disk is restored from that inconsistent backup, and in
# the worst case, the system may not be able to boot up.
#
# The guaranteed way to create a clean backup of your OS is to shut down the
# computer, boot from an external drive and clone the whole disk. This
# obviously takes a long time and you also need to end all programs, which may
# be inconvenient.
#
# Another way to do it, without closing all windows, is to pause everything
# that runs, and then simply copying things over. When everything is stopped,
# we can take our time to create a backup without the risk of data being
# changed under our feet.
#
# There are several solutions that can back up your live system rather well,
# but I don't want to rely on such programs. Especially if these programs try
# to be "smart" (Restore Points under Windows).
#
# rbak.sh keeps things really simple and does not require special file systems
# (like zfs) or other means of live backup. It is a rather crude way of doing
# it, but at least you don't need to close all your windows.
#
###############################################################################
#
# 2. USAGE
# ========
#
# PREREQUISITES
# -------------
# You need to have rsync installed. inotify-tools is optional, but recommended.
#
# sudo apt install rsync inotify-tools
# sudo pacman -S rsync inotify-tools
#
# CONFIGURE THE SCRIPT
# --------------------
# You need to configure this script to your needs, before using it.
# Set the path to your backup directory and adjust, which directories are
# excluded from the backup.
#
# START IT FROM THE CONSOLE
# -------------------------
# rbak.sh must be run from the console and will refuse to do anything, when it
# is being called from within a terminal window.
#
# When the script is started with the required parameters, all userland
# processes of your user(s) and a select group of services will be halted
# temporarily. This includes your X Desktop!
#
# You *MUST NOT* switch back to the X screen, you will not be able to switch
# back. To resolve such a situation, you'd need to ssh in from the outside.
#
# MONITOR WRITE ACCESS
# --------------------
# To help identify system services that cause writes to the disk, inotify-watch
# is started before the backup starts. Any change to the disk will be shown
# on screen and you can add the service to the script's configuration.
#
###############################################################################


###############################################################################
# SETTINGS
# ADJUST BEFORE USING rbak.sh!
###############################################################################

# BACKUP BASE NAME
# The name of the target directory for you backup will be created from this
# base name. You will have at least one backup in the form of $basename.1
# like /data/backup/myhostname.rbak.1
backup_basename="/data/backup/$(hostname).rbak"

# EXCLUDE DIRS
# Certain things don't belong in a system backup. Especially the backup
# folder itself :) This script comes with /etc/fstab excluded, because
# I have to manage several copies and different distros. You will probably
# want to actually NOT exclude it.
exclude_dirs='{"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/var/cache/pacman/*","/lost+found","/data/*","/etc/fstab"}'

# EXCLUDE NOTIFY
# Writes to mounted partitions like RAM disks, don't need to be reported.
# The same goes for your backup directory. We will write to it, obviously.
exclude_notify='(/dev|/proc|/sys|/tmp|/run|/mnt|/media|/lost+found|/data)'

# RSYNC COMMAND
# How rsync is started. The script will append the target directory later on.
rsync_cmd="rsync -axHAWX --info=progress2 --delete --exclude=$exclude_dirs /"

# HALT USERS
# Used to find all userland processes to pause. Usually just your user name.
# Space delimited list.
halt_users="hmw"

# HALT SERVICES
# Names of all services, that may write to the disk while the backup is running
halt_services="NetworkManager.service httpd.service"

# USE INOTIFY
# Whether to show all write accesses.
# Recommended setting: true
# When set to false, rbak.sh will start up quicker, but you may miss write
# accesses from newly installed programs and serives.
use_inotify_watch=false

# VERIFY THAT YOU HAVE READ THIS
# Set the following to  true
script_is_configured=true


###############################################################################
# YOU CAN SAFELY IGNORE THE REST OF THIS FILE
###############################################################################

# Colored output
TEXT_UNDERLINE="$(tput smul)"
TEXT_endUNDERLINE="$(tput rmul)"
TEXT_STANDOUT="$(tput smso)"       # Inverse colors on my terminal
TEXT_endSTANDOUT="$(tput rmso)"
TEXT_DIM="$(tput dim)"
TEXT_BOLD="$(tput bold)"
TEXT_BLINK="$(tput blink)"
TEXT_REVERSE="$(tput rev)"
TEXT_RED="$(tput setaf 1)"
TEXT_GREEN="$(tput setaf 2)"
TEXT_YELLOW="$(tput setaf 3)"
TEXT_BLUE="$(tput setaf 4)"
TEXT_MAGENTA="$(tput setaf 5)"
TEXT_CYAN="$(tput setaf 6)"
TEXT_WHITE="$(tput setaf 7)"
TEXT_RESET="$(tput sgr0)"

sanity_checks()
{
	if [ "$script_is_configured" != "true" ] ; then
		echo "This script needs to be configured first."
		echo "Please read the instructions in $0"
		exit 1
	fi

	if [ "$(whoami)" != "root" ] ; then
		echo "Error: This script must be run as root!"
		exit 2
	fi

	if [ "$1" != "" ] ; then
		backup_dir="$backup_basename.$1"
	else
		# WHEN CALLED WITHOUT PARAMETERS, SHOW USAGE HINTS AND EXISTING BACKUPS

		echo "Usage: $(basename $0) <suffix>"
		echo "Backup directory base name: $backup_basename"
		echo "Excluded directories: $exclude_dirs"
		echo "Example: '$(basename $0) 1' will rsync the current system to $backup_basename.1"

		if ls -U "$backup_basename".* 1> /dev/null 2>&1 ; then
			echo "Existing backups:"
			ls -lad "$backup_basename".*
		else
			echo "Warning: No backup directories found: $backup_basename.*"
		fi

		exit
	fi

	if [ ! -d "$backup_dir" ] ; then
		echo "Error: Backup directory not found: $backup_dir"
		echo "mkdir -p $backup_dir"
		exit 3
	fi

	if [ $DISPLAY ] ; then
		echo "Error: This script must not be run from an X terminal!"
		exit 4
	fi
}

halt_user_processes()
{
	# CALL  pkill -e STOP  FOR EVERY CONFIGURED USER NAME
	echo -e "Halting user processes:${TEXT_YELLOW}"
	echo $halt_users | tr ' ' "\n" | xargs -I % sh -c 'echo -n "%: " ; pkill -e -STOP -u % | wc -l'
	echo -e "${TEXT_RESET}"
}

resume_user_processes()
{
	# CALL  pkill -e CONT  FOR EVERY CONFIGURED USER NAME
	echo -e "Resuming user processes:${TEXT_YELLOW}"
	echo $halt_users | tr ' ' "\n" | xargs -I % sh -c 'echo -n "%: " ; pkill -e -CONT -u % | wc -l'
	echo -e "${TEXT_RESET}"
}

do_backup()
{
	echo "About to ${TEXT_BOLD}CREATE BACKUP${TEXT_RESET} of ${TEXT_BOLD}/${TEXT_RESET} to ${TEXT_BOLD}${backup_dir}${TEXT_RESET}"

	# SHOW COMMANDS THAT WILL BE ISSUED
	echo "${TEXT_YELLOW}$rsync_cmd $backup_dir${TEXT_RESET}"
	# Optionally back up other partitions:
	#echo "${TEXT_YELLOW}${rsync_cmd}boot/* $backup_dir/boot${TEXT_RESET}"
	if [ "$use_inotify_watch" != "false" ] ; then
		echo "${TEXT_YELLOW}inotifywait -e modify -e attrib -e move -e create -e delete -m -r --exclude \"$exclude_notify\" > >(ts) &${TEXT_RESET}"
	fi

	echo -e "Stopping ${TEXT_YELLOW}$halt_services${TEXT_RESET}"
	systemctl stop $halt_services

	if [ "$use_inotify_watch" != "false" ] ; then
		echo "Wait for watches to be established, then press Enter to continue or Ctrl+C to abort"

		echo 999999 > /proc/sys/fs/inotify/max_user_watches
		inotifywait \
			-e modify -e attrib -e move -e create -e delete -m -r / \
			--exclude "$exclude_notify" \
			> >(ts ' %H:%M:%S') &
		inotify_pid=$!

		read        # Wait for user to press return
		tput cuu1   # Move cursor up one line
	fi

	echo -e $(halt_user_processes)
	halted_user_processes=true

	echo "Backing up ${TEXT_BOLD}${TEXT_YELLOW}/${TEXT_RESET}"
	eval $rsync_cmd $backup_dir

	# Optionally back up other partitions:
	#echo "Backing up ${TEXT_BOLD}${TEXT_YELLOW}/boot${TEXT_RESET}"
	#eval ${rsync_cmd}boot/* $backup_dir/boot/
}

cleanup()
{
	if [ "$use_inotify_watch" != "false" ] ; then
		kill $inotify_pid > /dev/null 2>&1
	fi

	# Resume user processes, if there were any
	[ $halted_user_processes ] && echo -e $(resume_user_processes)

	echo -e "Starting ${TEXT_YELLOW}$halt_services${TEXT_RESET}"
	systemctl start $halt_services

	touch $backup_dir
	echo "Done."
	exit
}


echo "${TEXT_YELLOW}${TEXT_BOLD}$(basename $0)${TEXT_RESET} (Backup the current system via rsync)"
sanity_checks $1
trap cleanup SIGINT
do_backup
cleanup
