# Blink Pi USB Gadget Setup Documentation

## 1. Overview
This system uses a Raspberry Pi Zero W in USB gadget mode to emulate a 4GB FAT32 mass storage device using sparse `.bin` files for a Blink camera sync module. It rotates between three files every hour to offload videos, back them up to a NAS, and prepare the Pi for the next recording cycle without user interaction.

---

## 2. Hardware
- Device: Raspberry Pi Zero W  
- Storage: MicroSD + `/piusb` mount for backing files  
- Connected Device: Blink Sync Module via USB OTG  
- Networking: Wi-Fi for NAS access via SCP or rsync  

---

## 3. Key Directories

| Path                | Purpose                                 |
|---------------------|-----------------------------------------|
| `/piusb/`           | Base folder for sparse backing files    |
| `/piusb/backup/`    | Stores historical copies of used `.bin` |
| `/mnt/sparse_mount/`| Mount point for file parsing/cleaning   |

---

## 4. Backing Files (Rotation)
- `sync_sparse_1.bin`  
- `sync_sparse_2.bin`  
- `sync_sparse_3.bin`  

Each is rotated hourly using `rotation_index.txt` to track position.

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

