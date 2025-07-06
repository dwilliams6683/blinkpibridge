# 🔧 Blink Pi USB Gadget Setup Documentation

## 1. Overview  
This system uses a Raspberry Pi Zero W in USB gadget mode to emulate a 4GB FAT32 mass storage device (sparse `.bin` files) for a Blink camera sync module. It rotates between three files every hour to offload videos, back them up to a NAS, and prepare the Pi for the next recording cycle without user interaction.

---

## 2. Hardware  
- **Device**: Raspberry Pi Zero W  
- **Storage**: MicroSD + `/piusb` mount for backing files  
- **Connected Device**: Blink Sync Module via USB OTG  
- **Networking**: Wi-Fi for NAS access via SCP or rsync  

---

## 3. Key Directories  

| Path                  | Purpose                                   |  
|-----------------------|-------------------------------------------|  
| `/piusb/`             | Base folder for sparse backing files      |  
| `/piusb/backup/`      | Stores historical copies of used `.bin`   |  
| `/piusb/transfer/`    | Temporary location for processing         |  
| `/mnt/sparse_mount/`  | Mount point for file parsing/cleaning     |  

---

## 4. Backing Files (Rotation)  
- `sync_sparse_1.bin`  
- `sync_sparse_2.bin`  
- `sync_sparse_3.bin`  

Each is rotated in hourly intervals using `rotation_index.txt` to track position.

---

## 5. Main Script: `piusb.sh`  
**Purpose**: Rotate backing files, wait for file stability, mount old file, extract videos, rename timestamps (UTC to local), send to NAS, clean up.  
**Runs As**: `root` (via cron or manually)  

### Key Functions  
- `wait_for_file_stability()`  
  - Waits until no changes in file size for 3 checks, 10 seconds apart  
- `wait_for_unbind()`  
  - Waits for UDC unbind, used for logging (mostly legacy in current flow)  

---

## 6. Cron Setup  
Runs every hour at minute 0. Edit root’s crontab with:  
`sudo crontab -e`  

Add line:  
`0 * * * * /piusb/piusb.sh >> /piusb/cron.log 2>&1`  

---

## 7. Blink Settings  
- **Clip Length**: 20 seconds  
- **Rearm Time**: 10 seconds  
- **Reasoning**: Ensures full clips are captured with enough write time to allow the Pi Zero to detect file stability before rotation.  

---

## 8. Log File  
- **Location**: `/piusb/log.txt`  
- **Contents**:  
  - Rotation status and timing  
  - File stability checks  
  - File copying and renaming logs  
  - Transfer status  
  - Errors (e.g., mount failure, permission denied)  

---

## 9. Troubleshooting Notes  

| Symptom                                 | Likely Cause                               | Fix                                  |  
|------------------------------------------|---------------------------------------------|---------------------------------------|  
| `File shrank by ...` in `tar`            | Rotation happened during Blink write        | Increase stability delay or Blink clip time |  
| `Permission denied` on `/sys/.../UDC`    | Running script as non-root                  | Run as `root` via cron or `sudo`     |  
| Files show only `_XXX.mp4`               | Timestamps stripped or rename failed        | Check `basename` parsing & logic     |  
| `Read-only file system` errors           | USB backing file was in use during unmount  | Ensure full stability check before unmount |  

---

## 10. To Do / Improvements  
- [ ] Add auto detection for DST offset  
- [ ] Switch to `rsync` for differential sync instead of full `tar`  
- [ ] Add daily archive rotation on NAS  

---

## Appendix: Script Location  
- `/piusb/piusb.sh`  
- Should be owned by `root` with `chmod +x`  
- Consider `sudo visudo` with NOPASSWD rule if interactive use without full root login is needed  

---
