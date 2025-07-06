#!/bin/bash

GADGET_PATH="/sys/kernel/config/usb_gadget/g1"
UDC_PATH="$GADGET_PATH/UDC"
BACKING_FILES_DIR="/piusb"
BACKUP_DIR="/piusb/backup"
TRANSFER_DIR="/piusb/transfer"
LOGGING_FILE="/piusb/log.txt"

FILES=(sync_sparse_1.bin sync_sparse_2.bin sync_sparse_3.bin)
INDEX_FILE="/piusb/rotation_index.txt"
RETRY_DELAY=5  # seconds
MAX_RETRIES=6  # max wait 30 seconds to unbind

function wait_for_file_stability() {
    local file="$1"
    local WAIT_TIME=10
    local STABILITY_COUNT=3
    local stable=0

    echo "$(date '+%Y-%m-%d %H:%M:%S') Checking for file stability on $file" >> "$LOGGING_FILE"
    local prev_size=$(stat -c %s "$file")

    while [[ $stable -lt $STABILITY_COUNT ]]; do
        sleep $WAIT_TIME
        local new_size=$(stat -c %s "$file")
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

function wait_for_unbind() {
    local retries=0
    while [[ -n "$(cat $UDC_PATH 2>/dev/null)" ]]; do
        if (( retries >= MAX_RETRIES )); then
            echo "Failed to unbind gadget after $((RETRY_DELAY * MAX_RETRIES)) seconds"
            echo "$(date '+%Y-%m-%d %H:%M:%S') Failed to unbind gadget after $((RETRY_DELAY * MAX_RETRIES)) seconds" >> $LOGGING_FILE
			return 1
        fi
        echo "Waiting for gadget to unbind..."
		echo "$(date '+%Y-%m-%d %H:%M:%S') Waiting for gadget to unbind..." >> $LOGGING_FILE
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
echo "$(date '+%Y-%m-%d %H:%M:%S') Starting USB gadget rotation..." >> $LOGGING_FILE

# Step 0: Check for file stability before proceeding to unbinding file
echo "$(date '+%Y-%m-%d %H:%M:%S') Waiting for $BACKING_FILES_DIR/$CURRENT_FILE to be stable before unbinding..." >> $LOGGING_FILE
wait_for_file_stability "$BACKING_FILES_DIR/$CURRENT_FILE"

# Step 1: Unbind gadget (tell kernel gadget to detach)
echo "" > $UDC_PATH

# Wait until unbound (Blink should have released USB gadget)
if ! wait_for_unbind; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Error: Could not unbind gadget, aborting!" >> $LOGGING_FILE
    echo "Error: Could not unbind gadget, aborting!"
    exit 1
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') Unbound successfully." >> $LOGGING_FILE
echo "Gadget unbound successfully."

sleep 5
# Step 2: Change backing file to next sparse file
echo "$(date '+%Y-%m-%d %H:%M:%S') Switching backing file to: $BACKING_FILES_DIR/$NEXT_FILE" >> $LOGGING_FILE
echo "$BACKING_FILES_DIR/$NEXT_FILE" > "$GADGET_PATH/functions/mass_storage.usb0/lun.0/file" 

# Step 3: Bind gadget back to UDC (use detected UDC device)
UDC_DEVICE=$(ls /sys/class/udc/ | head -n1)
echo "$(date '+%Y-%m-%d %H:%M:%S') Binding back to UDC: $UDC_DEVICE:$UDC_PATH" >> $LOGGING_FILE
echo "$UDC_DEVICE" > $UDC_PATH 
echo "$(date '+%Y-%m-%d %H:%M:%S') Gadget bound to $UDC_DEVICE with file $NEXT_FILE" >> $LOGGING_FILE
echo "Gadget bound to $UDC_DEVICE with file $NEXT_FILE"

# Step 4: Update index file for next rotation
echo "$(date '+%Y-%m-%d %H:%M:%S') Switching to next index file: $NEXT_INDEX/$INDEX_FILE" >> $LOGGING_FILE
echo "$NEXT_INDEX" > $INDEX_FILE

# Step 5: After remount, copy previous file to backup and transfer directories, then clear it
PREV_FILE="$BACKING_FILES_DIR/$CURRENT_FILE"
BACKUP_FILE="$BACKUP_DIR/$CURRENT_FILE.$(date +%Y%m%d-%H%M%S)"
TRANSFER_FILE="$TRANSFER_DIR/transfer.bin"

echo "Copying $PREV_FILE to backup and transfer folders..."
echo "$(date '+%Y-%m-%d %H:%M:%S') Backing up and transfering files to NAS: $PREV_FILE" >> $LOGGING_FILE
echo "$(date '+%Y-%m-%d %H:%M:%S') Copying $PREV_FILE to $BACKUP_FILE" >> $LOGGING_FILE

if cp -v "$PREV_FILE" "$BACKUP_FILE" >> "$LOGGING_FILE" 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Copy succeeded" >> $LOGGING_FILE
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Copy failed!" >> $LOGGING_FILE
fi

#echo "$(date '+%Y-%m-%d %H:%M:%S') Copying $PREV_FILE to $TRANSFER_FILE" >> $LOGGING_FILE
#if cp -v "$PREV_FILE" "$TRANSFER_FILE" >> "$LOGGING_FILE" 2>&1; then
#    echo "$(date '+%Y-%m-%d %H:%M:%S') Copy succeeded" >> $LOGGING_FILE
#else
#    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Copy failed!" >> $LOGGING_FILE
#fi
#echo "$(date '+%Y-%m-%d %H:%M:%S') Starting transfer of $TRANSFER_FILE" >> $LOGGING_FILE

sleep 5
echo "$(date '+%Y-%m-%d %H:%M:%S') Mounting file to extract videos." >> $LOGGING_FILE
mkdir -p /mnt/sparse_mount
mount -o loop,offset=31744 "$PREV_FILE" /mnt/sparse_mount
sync
sleep 5

echo "$(date '+%Y-%m-%d %H:%M:%S') Entering Blink storage directory" >> $LOGGING_FILE
cd /mnt/sparse_mount/blink

# Step 6: Rename files in-place to convert UTC timestamps to local time
cd /mnt/sparse_mount/blink || exit 1

TIME_OFFSET=4  # Number of hours to subtract from HH

find . -type f -name "*.mp4" | while read -r file; do
    dir=$(dirname "$file")
    base=$(basename "$file")

    # Extract time prefix (HH-MM-SS) and rest of filename
    timepart=${base%%_*}   # "HH-MM-SS"
    rest=${base#*_}        # "CameraName_XXX.mp4"

    # Split timepart into HH, MM, SS
    IFS='-' read -r HH MM SS <<< "$timepart"

    # Subtract TIME_OFFSET from HH modulo 24 with zero-padding
    HH_NUM=$(( 10#${HH#0} ))
    newHH=$(( (HH_NUM - TIME_OFFSET + 24) % 24 ))
    if (( newHH < 10 )); then
        newHH="0$newHH"
    fi

    new_time="${newHH}-${MM}-${SS}"
    newname="${new_time}_$rest"

    # Rename only if different and target doesn't exist
    if [[ "$base" != "$newname" && ! -e "$dir/$newname" ]]; then
        echo "Renaming: $base → $newname"
		echo "$(date '+%Y-%m-%d %H:%M:%S') Renaming: $base → $newname" >> $LOGGING_FILE
        mv "$dir/$base" "$dir/$newname"
    fi
done

sleep 5
sync

# Step 7: Transfer files via SSH to NAS keeping the directory structure the same as it normally would be on real USB drive
echo "$(date '+%Y-%m-%d %H:%M:%S') Starting Transfer of files" >> $LOGGING_FILE
echo "Starting Transfer of Files."
tar -cf - . | ssh -p 52125 blinkpi@192.168.0.5 'tar -xpf - -C /volume1/blink/video/'

cd /piusb

echo "$(date '+%Y-%m-%d %H:%M:%S') Unmounting Loop Device" >> $LOGGING_FILE
umount /mnt/sparse_mount
sleep 5

echo "Clearing old file content for reuse..."
echo "$(date '+%Y-%m-%d %H:%M:%S') Clearing $PREV_FILE of videos and empty folders" >> $LOGGING_FILE
if mount -o loop,offset=31744 "$PREV_FILE" /mnt/sparse_mount; then
    echo "Mounted successfully. Cleaning files..."
    echo "$(date '+%Y-%m-%d %H:%M:%S') Clearing out $PREV_FILE of video contents..." >> $LOGGING_FILE
    find /mnt/sparse_mount/blink -type f \( -name "*.mp4" -o -name "*.ts" \) -delete
    find /mnt/sparse_mount/blink -type d -empty -delete
    sync
    if umount /mnt/sparse_mount; then
	echo "Unmounted cleanly."
	echo "$(date '+%Y-%m-%d %H:%M:%S') Unmounting of sparse file successful..." >> $LOGGING_FILE
    else
	echo "Warning: Failed to unmount." >&2
	echo "$(date '+%Y-%m-%d %H:%M:%S') Failed to unmount sparse file..." >> $LOGGING_FILE
    fi
else
    echo "Failed to mount $PREV_FILE for cleanup." >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') Failed to mount $PREV_FILE..." >> $LOGGING_FILE
fi

echo "Rotation complete."
echo "$(date '+%Y-%m-%d %H:%M:%S') Rotation Complete..." >> $LOGGING_FILE
