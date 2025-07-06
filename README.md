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
- You can name the files as you see fit.  I used the `sync_sparse_X.bin` format of naming to make it easier to keep track of what file was being used at the time of creation of the project, as I was working through various ideas.  If you do change the name of the files, you will need to edit the files in the `piusb.sh` script to reflect the new naming of the files.  I do recommend using at least 4GB files as the smallest, as the Sync Module will not write to the USB drive if less than 375MB of free space exists.  4GB will give plenty of head room for using 30sec recordings.

_(Note: The exact offset and filesystem parameters should match the Blink device requirements.)_

---

## 5. Main Setup: 

### 📥Step 1: Flash Raspberry Pi OS Lite
Download Raspberry Pi Imager from raspberrypi.com

Choose:
- OS: Raspberry Pi OS Lite (headless, no desktop)
- Storage: Your microSD card

Click the gear icon ⚙️ before clicking “Write” to:

- Set hostname (e.g., raspberrypi)
- Enable SSH
- Configure Wi-Fi (SSID, password, country code)
- Set locale, timezone, keyboard layout

Click Save, then Write

### 🔌Step 2: Boot the Pi
Insert the SD card

Power the Pi Zero via micro USB (use the PWR port)

Wait 60–90 seconds for it to boot

### 🔍Step 3: Find the IP Address
Log in to your router and find the hostname or MAC address

Or use a network scanner like nmap:
```nmap -sn 192.168.1.0/24```

### 🔐Step 4: Connect via SSH
```ssh pi@<IP-address>```
OR
```ssh pi@raspberrypi.local```

Default password is `raspberry` (change it after logging in!)
```passwd```

### Step 5: Update the system and install the needed software
First, we need to use `raspi-config` and expand the filesystem to use the entire microSD card.  Failure to do so will result in running out of space on the creation of the backing files
```sudo raspi-config```
- Go to Advanced Options → Expand Filesystem
- Reboot after doing this.

Next, do a full system update to make sure the everything is updated
```sudo apt update && sudo apt upgrade -y```

Then we need to install the following: rsync, git, screen
```sudo apt install rsync git screen -y```

### Step 6: Enable USB OTG mode on the device
On Raspberry Pi OS, enabling USB OTG gadget mode is usually done by manually:
- Adding `dtoverlay=dwc2` in /boot/firmware/config.txt
- Ensuring the kernel module dwc2 loads at boot (by adding it to /etc/modules or via modules-load kernel parameter).
- Loading the USB gadget module you want (e.g., g_mass_storage, g_ether, g_serial, etc).
  
1. Add `dtoverlay=dwc2` in /boot/firmware/config.txt.
```
sudo nano /boot/firmware/config.txt
```
Add the 'dtoverlay=dwc2' at the top of the file.  Be sure to `Ctrl+X` and press `Y` to save changes to the file.

2. Edit modules to load dwc2 on boot:
```
echo "dwc2" | sudo tee -a /etc/modules
```

3. Edit /boot/firmware/cmdline.txt (one line only!) and add:
```
modules-load=dwc2,g_mass_storage
```
Make sure to separate from other parameters with spaces. Use:
```
sudo nano /boot/firmware/cmdline.txt
```
_REMEMBER TO SAVE YOUR CHANGES_

4. Reboot:
```
sudo reboot
```

5. Make sure that libcomposite is loaded
```sudo modprobe libcomposite```

6. Create the configfs USB gadget that will act as the emulated USB drive
```
cd /sys/kernel/config/usb_gadget
sudo mkdir g1
cd g1

echo 0x1d6b > idVendor        # Linux Foundation
echo 0x0104 > idProduct       # Multifunction Composite Gadget (example)
echo 0x0100 > bcdDevice       # Device release number
echo 0x0200 > bcdUSB          # USB 2.0

mkdir strings/0x409
echo "1234567890" > strings/0x409/serialnumber #You can put anything here you like to distinguish it
echo "BlinkPi" > strings/0x409/manufacturer #You can put anything here you like to distinguish it
echo "Blink USB Drive" > strings/0x409/product #You can put anything here you like to distinguish it

mkdir configs/c.1
mkdir configs/c.1/strings/0x409
echo "Config 1" > configs/c.1/strings/0x409/configuration

mkdir functions/mass_storage.usb0
echo /piusb/sync_sparse_1.bin > functions/mass_storage.usb0/lun.0/file
echo 0 > functions/mass_storage.usb0/stall
echo 1 > functions/mass_storage.usb0/lun.0/removable
echo 0 > functions/mass_storage.usb0/lun.0/cdrom
echo 0 > functions/mass_storage.usb0/lun.0/ro

ln -s functions/mass_storage.usb0 configs/c.1/

# Find your UDC device:
ls /sys/class/udc/

# Bind gadget to UDC (replace YOUR_UDC_NAME with what you found above):
echo YOUR_UDC_NAME | sudo tee UDC #This should look like echo 20980000.usb or similar.
```
- After this:
Your Pi Zero will expose the sync_sparse_1.bin file as a USB mass storage device.
You can unbind by writing an empty string to UDC:
```
echo "" | sudo tee UDC
```
This lets you safely unmount before syncing.

_(NOTE: I personally recommend using the /stall set to 0.  Setting it to 1 can cause the backing file to corrupt out or the update script to hang.)_

---
### Step 7: PIUSB.SH

Purpose: Rotate backing files, wait for file stability, mount old file, extract videos, rename timestamps (UTC to local), send to NAS, and clean up.

Run as: `root` or `sudo` (if run by cron, run as root).

Key Functions:

- `wait_for_file_stability()`  
  Waits until no changes in file size for 3 checks, 10 seconds apart.

- `wait_for_unbind()`  
  Waits for USB gadget unbind; mostly for logging.

---

## 8. Cron Setup

Run every hour at minute 0.

Edit root cron with:

    sudo crontab -e

Add this line:

    0 * * * * /piusb/piusb.sh >> /piusb/cron.log 2>&1

---

## 9. Blink Settings

| Setting     | Value          | Reasoning                                         |
|-------------|----------------|--------------------------------------------------|
| Clip Length | 20 seconds     | Capture motion clips long enough for sync        |
| Rearm Time  | 10 seconds     | Minimum allowed; balances clip frequency and sync stability |

---

## 10. Log File

- Location: `/piusb/log.txt`  
- Contains: Rotation status, file stability checks, copying logs, transfer info, and errors.

---

## 11. Troubleshooting Notes

| Symptom                          | Likely Cause                          | Fix                                   |
|---------------------------------|-------------------------------------|-------------------------------------|
| `File shrank by ...` tar errors | Rotation during file write           | Increase stability delay or clip length |
| Permission denied on `/sys/...`  | Script run as non-root                | Run script as root or with sudo      |
| Files named `_XXX.mp4` only      | Rename script parsing issues          | Check file name parsing logic        |
| Read-only file system errors     | File still in use during unmount      | Confirm file stability before unmount|

---

## 12. To Do / Improvements

- [ ] Auto-detect DST offset  
- [ ] Switch to `rsync` for differential sync  
- [ ] Implement daily archive rotation on NAS  

---

## Appendix: Script Location

- Path: `/piusb/piusb.sh`  
- Permissions: Owned by `root`, executable (`chmod +x`)  
- Consider adding sudoers NOPASSWD for ease of manual runs without full root login.

---

