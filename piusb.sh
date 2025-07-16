#!/bin/bash

#*******************************USER VARIABLES********************************#
GADGET_PATH="/sys/kernel/config/usb_gadget/g1"
UDC_PATH="$GADGET_PATH/UDC"
UDC_DEV="/sys/class/udc/"
BACKING_FILES_DIR="/piusb"
BACKUP_DIR="/piusb/backup"
LOGGING_FILE="/piusb/log.txt"
FILES=(sync_sparse_1.bin sync_sparse_2.bin sync_sparse_3.bin)
INDEX_FILE="/piusb/rotation_index.txt"
RETRY_DELAY=5  # seconds
MAX_RETRIES=6  # max wait 30 seconds to unbind
USER_NAME="blinkpi"
IP_ADDRESS="192.168.0.5"
STORAGE_PATH="/volume1/blink/video"
SSH_PORT=52125
XFER_RETRY=3
SPARSE_MOUNT="/mnt/sparse_mount"
MIN_FREE_MB=4096  

#***************************DEFINE COMMAND OPTIONS*****************************#

VERBOSE=0

while getopts ":vF:" opt; do
  case $opt in
    v)
      VERBOSE=1
      ;;
    F)
      MIN_FREE_MB=$OPTARG
      ;;
    \?)
      echo "Usage: $0 [-v F {size}] "
	  echo "       -v        - Enables verbose output in logs."
      echo "                   Use with caution: log files can grow large if   "
      echo "                   this option is used frequently (e.g., with cron)."
	  echo "       -F {size} - Defines the minimum free space (in MB) for the "
	  echo "                   script to run. This defaults to 4096 MB (4GB) if"
	  echo "                   not specified."
      exit 1
      ;;
  esac
done

if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run as root or with sudo."
  exit 1
fi


if [ "$VERBOSE" -eq 1 ]; then
  # Redirect stdout and stderr through tee to duplicate output to logfile and terminal
  exec > >(tee -a "$LOGGING_FILE") 2>&1
  set -x  # optional: trace commands for verbose debug
fi

#******************************BEGIN INITIALIZATION****************************#

# Add lock file to prevent cron and manual run from running concurrently
LOCKFILE="/tmp/rotate_script.lock"

if [[ -e "$LOCKFILE" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Script already running. Aborting." >> "$LOGGING_FILE"
    exit 1
fi

touch "$LOCKFILE"

# Trap to ensure lock is removed on script exit
trap "rm -f $LOCKFILE" EXIT


# Check free space on device before attempting to swap.  If under threshold, log and exit script.
MIN_FREE_KB=$(( MIN_FREE_MB * 1024 ))
AVAIL=$(df --output=avail /piusb | tail -1)
if [ "$AVAIL" -lt "$MIN_FREE_KB" ]; then
    AVAIL_MB=$(( AVAIL / 1024 ))
    echo "$(date '+%Y-%m-%d %H:%M:%S') LOW DISK SPACE — Rotation skipped. Available: ${AVAIL_MB}MB, Required: ${MIN_FREE_MB}MB" >> "$LOGGING_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') LOW DISK SPACE — Rotation skipped. Available: ${AVAIL_MB}MB, Required: ${MIN_FREE_MB}MB"
    exit 1
fi

# Create directories as needed for proper runtime
if mkdir -p "$SPARSE_MOUNT"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') $SPARSE_MOUNT directory created successfully or exists already." >> "$LOGGING_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Unable to create $SPARSE_MOUNT!  Aborting!" >> "$LOGGING_FILE"
    echo "ERROR: Unable to create $SPARSE_MOUNT!  Aborting!"
    exit 1
fi
if mkdir -p "$BACKUP_DIR"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') $BACKUP_DIR directory created successfully or exists already." >> "$LOGGING_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Unable to create $BACKUP_DIR!" >> "$LOGGING_FILE"
    echo "ERROR: Unable to create $BACKUP_DIR!"
    exit 1
fi
if mkdir -p "$BACKING_FILES_DIR"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') $BACKING_FILES_DIR directory created successfully or exists already." >> "$LOGGING_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Unable to create $BACKING_FILES_DIR!" >> "$LOGGING_FILE"
    echo "ERROR: Unable to create $BACKING_FILES_DIR!"
    exit 1
fi

# This function checks to see if the backing file is still being written to via the Sync Module
# If so the function will attempt to loop until the file is stable for the number of checks 
# defined in STABILITY_COUNT
function wait_for_file_stability() {
    local file="$1"
    local WAIT_TIME=10
    local STABILITY_COUNT=3
    local stable=0

    echo "$(date '+%Y-%m-%d %H:%M:%S') Checking for file stability on $file" >> "$LOGGING_FILE"
    local prev_size=$(du "$file" | cut -f1)

    while [[ $stable -lt $STABILITY_COUNT ]]; do
        sleep $WAIT_TIME
        local new_size=$(du "$file" | cut -f1)
        if [[ "$new_size" == "$prev_size" ]]; then
            ((stable++))
            echo "$(date '+%Y-%m-%d %H:%M:%S') Stability check $stable/$STABILITY_COUNT passed." >> "$LOGGING_FILE"
        else
            stable=0
            echo "$(date '+%Y-%m-%d %H:%M:%S') File still changing... restarting stability check." >> "$LOGGING_FILE"
        fi
        prev_size=$new_size
    done
    echo "$(date '+%Y-%m-%d %H:%M:%S') File appears stable. Proceeding." >> "$LOGGING_FILE"
}

# This function makes sure that the UDC_PATH is fully unbound before proceeeding with the script
# in order to prevent data corruption on the backing files.
function wait_for_unbind() {
    local retries=0
    while [[ -n "$(cat $UDC_PATH 2>/dev/null)" ]]; do
        if (( retries >= MAX_RETRIES )); then
            echo "Failed to unbind gadget after $((RETRY_DELAY * MAX_RETRIES)) seconds"
            echo "$(date '+%Y-%m-%d %H:%M:%S') Failed to unbind gadget after $((RETRY_DELAY * MAX_RETRIES)) seconds" >> "$LOGGING_FILE"
            return 1
        fi
        echo "Waiting for gadget to unbind..."
        echo "$(date '+%Y-%m-%d %H:%M:%S') Waiting for gadget to unbind..." >> "$LOGGING_FILE"
        sleep $RETRY_DELAY
        ((retries++))
    done
    return 0
}

# Initialize or create log file
if [[ -f "$LOGGING_FILE" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Appending to existing log file: $LOGGING_FILE" >> "$LOGGING_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') Starting new log file: $LOGGING_FILE" > "$LOGGING_FILE"
fi

# Load current index or start at 0
if [[ -f $INDEX_FILE ]]; then
    CURRENT_INDEX=$(cat $INDEX_FILE)
else
    CURRENT_INDEX=0
fi

# Calculate next index
NEXT_INDEX=$(( (CURRENT_INDEX + 1) % ${#FILES[@]} ))
CURRENT_FILE="${FILES[$CURRENT_INDEX]}"
NEXT_FILE="${FILES[$NEXT_INDEX]}"


echo "Starting USB gadget rotation..."
echo "$(date '+%Y-%m-%d %H:%M:%S') Starting USB gadget rotation..." >> "$LOGGING_FILE"

# Step 1: Check for file stability before proceeding to unbinding file
echo "$(date '+%Y-%m-%d %H:%M:%S') Waiting for $BACKING_FILES_DIR/$CURRENT_FILE to be stable before unbinding..." >> "$LOGGING_FILE"
wait_for_file_stability "$BACKING_FILES_DIR/$CURRENT_FILE"

# Step 2: Unbind gadget (tell kernel gadget to detach)
echo "" > $UDC_PATH
sync
if ! wait_for_unbind; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Error: Could not unbind gadget, aborting!" >> "$LOGGING_FILE"
    echo "Error: Could not unbind gadget, aborting!"
    exit 1
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') Unbound successfully." >> "$LOGGING_FILE"
echo "Gadget unbound successfully."
# Pause for 5 seconds to allow for filesystem to stabilize and Sync Module to notice USB Device is not present
sleep 5

# Step 3: Change backing file to next sparse file
echo "$(date '+%Y-%m-%d %H:%M:%S') Switching backing file to: $BACKING_FILES_DIR/$NEXT_FILE" >> "$LOGGING_FILE"
echo "$BACKING_FILES_DIR/$NEXT_FILE" > "$GADGET_PATH/functions/mass_storage.usb0/lun.0/file" 
sync 
sleep 1

# Step 4: Bind gadget back to UDC (use detected UDC device)
UDC_DEVICE=$(ls $UDC_DEV | head -n1)
echo "$(date '+%Y-%m-%d %H:%M:%S') Binding back to UDC: $UDC_DEVICE:$UDC_PATH" >> "$LOGGING_FILE"
echo "$UDC_DEVICE" > $UDC_PATH 
echo "$(date '+%Y-%m-%d %H:%M:%S') Gadget bound to $UDC_DEVICE with file $NEXT_FILE" >> "$LOGGING_FILE"
echo "Gadget bound to $UDC_DEVICE with file $NEXT_FILE"

# Step 5: Update index file for next rotation
echo "$(date '+%Y-%m-%d %H:%M:%S') Switching to next index file: $NEXT_INDEX/$INDEX_FILE" >> "$LOGGING_FILE"
echo "$NEXT_INDEX" > $INDEX_FILE

# Step 6: After remount, copy previous file to backup and transfer directories, then clear it
PREV_FILE="$BACKING_FILES_DIR/$CURRENT_FILE"
BACKUP_FILE="$BACKUP_DIR/$CURRENT_FILE.$(date +%Y%m%d-%H%M%S)"

echo "Copying $PREV_FILE to backup folder..."
echo "$(date '+%Y-%m-%d %H:%M:%S') Copying $PREV_FILE to $BACKUP_FILE" >> "$LOGGING_FILE"

if cp -v "$PREV_FILE" "$BACKUP_FILE" >> "$LOGGING_FILE" 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Copy succeeded" >> "$LOGGING_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') Cycle complete: $PREV_FILE rotated and backed up." >> "$LOGGING_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Copy failed! Aborting script!" >> "$LOGGING_FILE"
    echo "ERROR: Copy failed! Aborting script!"
    exit 1
fi

sleep 15
echo "$(date '+%Y-%m-%d %H:%M:%S') Mounting file to extract videos." >> "$LOGGING_FILE"
if mount -o loop,offset=31744 "$PREV_FILE" "$SPARSE_MOUNT"; then
    echo "Backing file mounted successfully." >> "$LOGGING_FILE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Unable to mount backing file!  Aborting!" >> "$LOGGING_FILE"
    echo "ERROR: Unable to mount backing file!  Aborting!"
    exit 1
fi

sync
sleep 5

echo "$(date '+%Y-%m-%d %H:%M:%S') Entering Blink storage directory in backing file" >> "$LOGGING_FILE"
cd "$SPARSE_MOUNT/blink" || exit 1

# Rename files based on local time instead of the UTC time that the Sync Module uses to 
# name file and place them in the directories. This also places the files in the proper
# directories based on date, to match what the Blink App UX does.
find . -type f -name "*.mp4" | while read -r file; do
    mtime=$(stat -c %Y "$file")
    local_date=$(date -d "@$mtime" +%y-%m-%d)
    local_month=$(date -d "@$mtime" +%y-%m)
    local_time=$(date -d "@$mtime" +%H-%M-%S)
    filename=$(basename "$file")
    suffix="${filename#*_}"
    target_dir="./$local_month/$local_date"
    mkdir -p "$target_dir"
    target_file="$target_dir/${local_time}_$suffix"

    if [[ "$file" != "$target_file" && ! -e "$target_file" ]]; then
        mv "$file" "$target_file"
        echo "$(date '+%Y-%m-%d %H:%M:%S') Renamed $file → $target_file" >> "$LOGGING_FILE"
    fi
done

sleep 5
sync

# Step 7: Transfer files via SSH to NAS keeping the directory structure the same as it normally would be on real USB drive
echo "$(date '+%Y-%m-%d %H:%M:%S') Starting Transfer of files" >> "$LOGGING_FILE"
echo "Starting Transfer of Files."
echo "$(date '+%Y-%m-%d %H:%M:%S') Backing up and transfering files to NAS: $PREV_FILE" >> "$LOGGING_FILE"

success=0
retry_count=0
# Attempt to retry transfer if fails before exiting out of script.
while [[ $retry_count -lt $XFER_RETRY ]]; do
    TRANSFER_SIZE=$(du -sh . | cut -f1)
    echo "$(date '+%Y-%m-%d %H:%M:%S') Estimated transfer size: $TRANSFER_SIZE" >> "$LOGGING_FILE"
    start_time=$(date +%s)
    if tar -cf - . | ssh -p "$SSH_PORT" "$USER_NAME@$IP_ADDRESS" "tar -xpf - -C '$STORAGE_PATH'"; then
        end_time=$(date +%s)  # Record end time
        duration=$(( end_time - start_time ))  # Calculate duration in seconds
        echo "$(date '+%Y-%m-%d %H:%M:%S') Files transferred successfully.  $TRANSFER_SIZE sent in $duration seconds" >> "$LOGGING_FILE"
        echo "Files transferred successfully.  $TRANSFER_SIZE sent in $duration"
        success=1
        break
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: File transfer failed on attempt $((retry_count+1)). Retrying..." >> "$LOGGING_FILE"
        ((retry_count++))
        sleep 10
    fi
done

if [[ $success -ne 1 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: File transfer failed after $XFER_RETRY attempts. Aborting." >> "$LOGGING_FILE"
    exit 1
fi

#tar -cf - . | ssh -p "$SSH_PORT" "$USER_NAME@$IP_ADDRESS" "tar -xpf - -C '$STORAGE_PATH'"
#if tar -cf - . | ssh -p "$SSH_PORT" "$USER_NAME@$IP_ADDRESS" "tar -xpf - -C '$STORAGE_PATH'"; then
#    echo "Files transferred successfully." >> "$LOGGING_FILE"
#else
#    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: File transfer failed." >> "$LOGGING_FILE"
#    exit 1
#fi

# Step 8: Unmount before cleaning backing file of videos
cd /piusb
echo "$(date '+%Y-%m-%d %H:%M:%S') Unmounting Loop Device" >> "$LOGGING_FILE"
if umount "$SPARSE_MOUNT"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Unmounted Loop Device sucessfully." >> "$LOGGING_FILE"
    echo "Unmounted Loop Device sucessfully."
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Failed to unmount Loop Device! Aborting!" >> "$LOGGING_FILE"
    echo "ERROR: Failed to unmount Loop Device! Aborting!"
    exit 1
fi
sync
sleep 5

# Step 9: Remount backing file and clear out content
echo "Clearing old file content for reuse..."
echo "$(date '+%Y-%m-%d %H:%M:%S') Clearing $PREV_FILE of videos and empty folders" >> "$LOGGING_FILE"
if mount -o loop,offset=31744 "$PREV_FILE" "$SPARSE_MOUNT"; then
    echo "Mounted successfully. Cleaning files..."
    echo "$(date '+%Y-%m-%d %H:%M:%S') Clearing out $PREV_FILE of video contents..." >> "$LOGGING_FILE"
    find "$SPARSE_MOUNT/blink" -type f \( -name "*.mp4" -o -name "*.ts" \) -delete
    find "$SPARSE_MOUNT/blink" -type d -empty -delete
    sync
    if umount "$SPARSE_MOUNT"; then
    echo "Unmounted cleanly."
    echo "$(date '+%Y-%m-%d %H:%M:%S') Unmounting of sparse file successful..." >> "$LOGGING_FILE"
    else
    echo "Warning: Failed to unmount."
    echo "$(date '+%Y-%m-%d %H:%M:%S') Failed to unmount sparse file..." >> "$LOGGING_FILE"
    fi
else
    echo "Failed to mount $PREV_FILE for cleanup."
    echo "$(date '+%Y-%m-%d %H:%M:%S') Failed to mount $PREV_FILE..." >> "$LOGGING_FILE"
fi

echo "Rotation complete."
echo "$(date '+%Y-%m-%d %H:%M:%S') Rotation Complete..." >> "$LOGGING_FILE"