# Blink Pi USB Gadget Setup Documentation

## 1. Overview
This system uses a Raspberry Pi Zero W in USB gadget mode to emulate a 4GB FAT32 mass storage device using sparse `.bin` files for a Blink camera sync module. It rotates between three files every hour to offload videos, back them up to a NAS, and prepare the Pi for the next recording cycle without user interaction.

---

## 2. Hardware Requirements and Configuration
| Component         | Purpose / Details                                                                 |
|------------------|-------------------------------------------------------------------------------------|
| Raspberry Pi Zero W | Primary controller running in USB gadget mode. Emulates a FAT32 USB drive.      |
| MicroSD Card      | Holds the OS, rotation script, and sparse `.bin` backing files (min 16GB recommended). |
| Blink Sync Module | Connects via USB OTG. Detects the emulated drive for motion video storage.        |
| USB OTG Cable     | Connects Pi Zero’s micro-USB port to Blink Sync’s USB-A port.                     |
| Wi-Fi Network     | Provides wireless access for file transfer to NAS or other storage.               |
| NAS / Server      | Destination for archived clips. Must support SSH for `scp` or `rsync`.            |

---

## 3. Key Directories and Files

| Path                | Purpose                                                                |
|---------------------|------------------------------------------------------------------------|
| `/piusb/`           | Base folder for sparse backing files                                   |
| `/piusb/backup/`    | Stores historical copies of used `.bin` for error recovery             |
| `/mnt/sparse_mount/`| Mount point for file parsing/cleaning                                  | 
| `/sys/kernel/config/usb_gadget/g1/` | USB gadget config directory                            |
| `/sys/kernel/config/usb_gadget/g1/UDC` | USB Device Controller binding interface             |
| `/etc/cron.d/` or user crontab | Location where cron jobs are set up                         |
| `/piusb/log.txt`           | Log file for rotation script status                             |
| `/piusb/rotation_index.txt` | Keeps track of which sparse file to rotate next                |

---

## 4. Creation and Purpose of Backing Files

The system uses three sparse backing files named `sync_sparse_1.bin`, `sync_sparse_2.bin`, and `sync_sparse_3.bin`. These files act as virtual USB storage devices that the Blink Sync Module sees when connected to the Pi Zero USB gadget.  

### Key points about these backing files:
- Sparse file format:
Each .bin file is created as a sparse file, which means it reserves a large file size (e.g., 4GB) without physically occupying all the disk space immediately. This efficiently simulates a USB drive.  
- File size and structure:
The files are formatted with a FAT32 filesystem starting at a fixed offset (31744 bytes) to match the Blink device expectations.  
- Rotation mechanism:
The rotation index (`rotation_index.txt`) keeps track of which sparse file is currently in use. Each hour, the script rotates to the next file in the list to offload videos from the Blink device to the Pi. 
- Backup and reuse:
After rotation, the previously used .bin file is backed up to /piusb/backup/, transferred to the NAS, cleaned (old video files removed), and reused in the next rotation cycle.

### Creating the sparse files
To create these backing files, run the following commands:
```bash
truncate -s 4G /piusb/sync_sparse_1.bin
truncate -s 4G /piusb/sync_sparse_2.bin
truncate -s 4G /piusb/sync_sparse_3.bin

mkfs.vfat -F 32 -n BLINK /piusb/sync_sparse_1.bin
mkfs.vfat -F 32 -n BLINK /piusb/sync_sparse_2.bin
mkfs.vfat -F 32 -n BLINK /piusb/sync_sparse_3.bin
```
-You can name the files as you see fit.  I used the `sync_sparse_X.bin` format of naming to make it easier to keep track of what file was being used at the time of creation of the project, as I was working through various ideas.  If you do change the name of the files, you will need to edit the files in the `piusb.sh` script to reflect the new naming of the files.  I do recommend using at least 4GB files as the smallest, as the Sync Module will not write to the USB drive if less than 375MB of free space exists.  4GB will give plenty of head room for using 30sec recordings.

_(Note: The exact offset and filesystem parameters should match the Blink device requirements.)_

---

## 5. Main Script: `piusb.sh`

Purpose: Rotate backing files, wait for file stability, mount old file, extract videos, rename timestamps (UTC to local), send to NAS, and clean up.

Run as: `root` (via cron or manually)

Key Functions:

- `wait_for_file_stability()`  
  Waits until no changes in file size for 3 checks, 10 seconds apart.

- `wait_for_unbind()`  
  Waits for USB gadget unbind; mostly for logging.

---

## 6. Cron Setup

Run every hour at minute 0.

Edit root cron with:

    sudo crontab -e

Add this line:

    0 * * * * /piusb/piusb.sh >> /piusb/cron.log 2>&1

---

## 7. Blink Settings

| Setting     | Value          | Reasoning                                         |
|-------------|----------------|--------------------------------------------------|
| Clip Length | 20 seconds     | Capture motion clips long enough for sync        |
| Rearm Time  | 10 seconds     | Minimum allowed; balances clip frequency and sync stability |

---

## 8. Log File

- Location: `/piusb/log.txt`  
- Contains: Rotation status, file stability checks, copying logs, transfer info, and errors.

---

## 9. Troubleshooting Notes

| Symptom                          | Likely Cause                          | Fix                                   |
|---------------------------------|-------------------------------------|-------------------------------------|
| `File shrank by ...` tar errors | Rotation during file write           | Increase stability delay or clip length |
| Permission denied on `/sys/...`  | Script run as non-root                | Run script as root or with sudo      |
| Files named `_XXX.mp4` only      | Rename script parsing issues          | Check file name parsing logic        |
| Read-only file system errors     | File still in use during unmount      | Confirm file stability before unmount|

---

## 10. To Do / Improvements

- [ ] Auto-detect DST offset  
- [ ] Switch to `rsync` for differential sync  
- [ ] Implement daily archive rotation on NAS  

---

## Appendix: Script Location

- Path: `/piusb/piusb.sh`  
- Permissions: Owned by `root`, executable (`chmod +x`)  
- Consider adding sudoers NOPASSWD for ease of manual runs without full root login.

---

