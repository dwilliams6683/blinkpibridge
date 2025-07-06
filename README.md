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

Because the script transfers files via SSH, you must set up a passwordless SSH connection on the NAS/server for headless operation.

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
_*NOTE:*_ If you do change the location of the sparse files, make sure to adjust this further on in the `piusb.sh` script.
- You can name the files as you prefer.  I used the `sync_sparse_X.bin` format of naming to make it easier to keep track of what file was being used at the time of creation of the project, as I was working through various ideas.  If you do change the name of the files, you will need to edit the files in the `piusb.sh` script to reflect the new naming of the files.  I do recommend using at least 4GB files as the smallest, as the Sync Module will not write to the USB drive if less than 375MB of free space exists.  4GB will give plenty of head room for using 30sec recordings.


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
- Click Save, then Write

### 🔌Step 2: Boot the Pi
- Insert the SD card
- Power the Pi Zero via micro USB (use the PWR port)
- Wait 60–90 seconds for it to boot

### 🔍Step 3: Find the IP Address
- Log in to your router and find the hostname or MAC address
- Or use a network scanner like nmap:
```
nmap -sn 192.168.1.0/24
```

### 🔐Step 4: Connect via SSH
```
ssh pi@<IP-address>
```
OR
```
ssh pi@raspberrypi.local
```

Default password is `raspberry` (change it after logging in!)
```
passwd
```

### Step 5: Update the system and install the needed software
First, we need to use `raspi-config` and expand the filesystem to use the entire microSD card.  Failure to do so will result in running out of space on the creation of the backing files
```
sudo raspi-config
```
- Go to Advanced Options → Expand Filesystem
- Reboot after doing this.

Next, do a full system update to make sure the everything is updated
```
sudo apt update && sudo apt upgrade -y
```

Then we need to install the following: rsync, git, screen
```
sudo apt install rsync git screen -y
```

### Step 6: Enable USB OTG mode on the device
On Raspberry Pi OS, enabling USB OTG gadget mode is usually done by manually:
- Adding `dtoverlay=dwc2` in /boot/firmware/config.txt
- Ensuring the kernel module dwc2 loads at boot (by adding it to /etc/modules or via modules-load kernel parameter).
- Loading the USB gadget module you want (e.g., g_mass_storage, g_ether, g_serial, etc).
_*NOTE:*_ Note: This guide assumes Raspberry Pi OS Bullseye or newer. Older versions may use /boot instead of /boot/firmware.  Please verify existance before making modifications to the files.
  
1. Add `dtoverlay=dwc2` in /boot/firmware/config.txt.
```
sudo nano /boot/firmware/config.txt
```
Add the `dtoverlay=dwc2` at the top of the file.  Be sure to `Ctrl+X` and press `Y` to save changes to the file.

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
echo 0 > functions/mass_storage.usb0/lun.0/nofua

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

_(NOTE: I recommend using the /stall set to 0.  Setting it to 1 can cause the backing file to corrupt out or the update script to hang.)_

7. Setup passwordless SSH on your NAS / Server
 - *NOTE*: I am not going to give directions for creating user accounts or enabling Authorized Key SSH login.  There are too many different ways that this is done, and varies from NAS to NAS and Server to Server.  Please look this up in the documentation if you are not aware of how to do it.

The first thing that will need to be done is creating a user account and shared folder that can be accessed and written to via that user account.  This is how the video's will be transferred from the RPiZero to the NAS.

Next, we need to on the RPiZero create an SSH key.  This will take a few minutes as the key generation takes place. Use the command to generate the key.
```
ssh-keygen -t rsa -b 4096
```

Now, we need to transfer that key to the NAS / Server to allow for the transfer to take place without needing us to enter a password each time.  Run the following command from the RPiZero, replacing the `user` and `ip` with the username of the account you created on the NAS / Server, and the IP address of the NAS / Server.
```
ssh-copy-id user@ip
```
*NOTE*: If you are using non-standard ports, you will need to use the following command below instead to transfer the key.  Failing to specify the correct port will fail out in the transfer.
```
ssh-copy-id -p PORT user@ip
```

---
### Step 7: PIUSB.SH
This is the main script that does the magic.  This is what handles the swapping of the backing files, assigning indexing, extracting videos, uploading, and cleanup of the backing files.  

The folloiwng can be customized within the script by editing the following at the top:
```
GADGET_PATH="/sys/kernel/config/usb_gadget/g1"
UDC_PATH="$GADGET_PATH/UDC"
UDC_DEV="/sys/class/udc/"
BACKING_FILES_DIR="/piusb"
BACKUP_DIR="/piusb/backup"
TRANSFER_DIR="/piusb/transfer"
TRANSFER_FILE="transfer.bin"
LOGGING_FILE="/piusb/log.txt"
FILES=(sync_sparse_1.bin sync_sparse_2.bin sync_sparse_3.bin)
INDEX_FILE="/piusb/rotation_index.txt"
RETRY_DELAY=5  # seconds
MAX_RETRIES=6  # max wait to unbind
TIME_OFFSET=4
WAIT_TIME=10
STABILITY_COUNT=3
USER_NAME="user"
IP_ADDRESS="192.168.0.0"
STORAGE_PATH="/volume/blink/video"
SSH_PORT=22
```

- GADGET_PATH & UDC_PATH:
This is the path that you created in step 6.  If you named it differently or your variant of Linux has different pathing, this must match the path used
- UDC_DEV:
This is the absolute path to the UDC device.  If you `ls` on this path, you should recieve a result similar to ```20980000.usb```
- BACKING_FILES_DIR:
The directory in use for the backing files.  This can be anywhere as long as the script can access it
- BACKUP_DIR: 
The directory where backups of the backing files will be placed.  These will be named with a date/time of the copy into the folder.  
- TRANSFER_DIR & TRANSFER_FILE:
These determine the directory of transfering the raw .bin file.  Useful if you want to offload the processing of the backing file to another device with more power
- LOGGING_FILE
The file that will store any messages with timestamps throughout the process
- FILES
These are the files names that will be used as the backing files for the USB gadget.  These files _**MUST**_ match the files that were created with as the backing files.  You can add as many files here as you prefer, just leave a single space between the file names.
- INDEX_FILE:
This file keeps track of the file rotation.  This is _**REQUIRED**_ for the script to rotate files properly.
- RETRY_DELAY:
This variable keeps track of the number of seconds to wait on a failed unbind attempt.  
- MAX_RETRIES
This variable keeps the total number of attempts to cleanly unbind before exiting the script with an error.
- TIME_OFFSET:
This is the time offset from UTC. When Blink stores files on a local storage device, it uses UTC time to name the files. It does not name them based on the user's local time zone settings. To correct the file naming properly, this offset must be set. This can be disabled by specifying `0` in the field.
- WAIT_TIME:
This is the total time to wait between stability checks.  Because this is being used as an emulated USB drive, the RPiZero does not have the ability to see when Blink's Sync Module is physically accessing the drive.  By using the sparse files, we get around this by seeing when the filesize of the sparse file changed.  If we do not see any change in this time frame, we are assuming that the Sync Module is no longer actively writing video files to the backing file
- STABILITY_COUNT:
This is the max number of stability checks to perform to make sure that the device does not unbind the backing file while the Sync Module is currently accessing the device.  The higher the number of checks, the longer the system must no be actively writing to the file before it will be unbound.
- `USER_NAME`:
This is the username of the account for the storage device such as a NAS.
- `IP_ADDRESS`:
This is the IP Address of the storage
- `STORAGE_PATH`:
This is the path of the folder that the media will be transferred to.  This must be accessable via the `USER_NAME`'s account.
- `SSH_PORT`:
This is the port that will be used via SSH to transfer the files.

The way that this script works is the script will:
1. Check to see if the log file exists, then will either append to the log or start a new log file
2. Reads the index file to determine what backing file should be used to mount
3. Begins the backing file rotation by checking for file stability to see if Blink is currently recording to the file
   - If it is recording, the script will wait and then attempt to check the stability again.  If the backing file is not accessed by the sync module after this point in time, the system will then proceed.  If not, it will reset the stability check, holding off on unbinding the file until it detects that the file size of the backing file has not changed.
4. Next it will attempt to unbind the backing file
   - *NOTE*: If the script is not run as root or with elevated permissions (`sudo`), the script will not be able to unbind the file and instead will error out with a failure.
5. The script will then remount the next backing file to record.  This keeps the total downtime of recording to a matter of seconds.
6. Once done, the script will then update the index file to the mark the next file that needs to be loaded in
7. Next, the backing file that was just unbound will be copied to the backup folder (and transfer folder if enabled), and then processed.
8. The script will then create a loop device to mount the backing file on so that it can access the files stored within.
9. The script will then attempt to rename the files to account for UTC offset.  Since the files are of a standard naming (HH-MM-SS_CameraName_XXX.mp4), we seperate out the file name using REGEX and then adjust the HH portion of the filename to account for UTC offset.
    - This will only happen if the filename does not exist already.  If the filename exists, it will skip to the next file in the process.
10.  Next the entire process will transfer the files to the storage you have defined in the variables above using `tar -cf - . | ssh -p $SSH_PORT "$USER_NAME@$IP_ADDRESS" "tar -xpf - -C '$STORAGE_PATH'"`.  This will transfer the files in the exact directory structure of the /blink directory, retaining the entire directory structure that exists beyond the /blink folder.
11. Once the transfer is complete, the script will do a unmount of the loop device then remount the device and clear out any of the files that were transferred before doing a final unmounting of the loop device.  This is done in this manner to prevent any write locks being encountered on the device and the backing file that is being mounted as a loop device, from getting corrupted via a unclean unmount.

Run as: `root` or `sudo` (if run by cron, run as root).

Key Functions:

- `wait_for_file_stability()`  
  Waits until no changes in file size for 3 checks, 10 seconds apart.

- `wait_for_unbind()`  
  Waits for USB gadget unbind; mostly for logging.

_*NOTE:*_ For this script to properly run, the script must be set as executable.  To do this, use the following in the directory you placed the script:
```
chmod +x ./piusb.sh
```

---

## 8. Cron Setup

-Edit root cron with:
```
sudo crontab -e
```
Add this line:
```
0 * * * * /piusb/piusb.sh >> /piusb/cron.log 2>&1
```
What this does is tells cron to schedule the tasking every hour and run at minute 0.

The way cron works is by taking the `0 * * * *` as the scheduling.  If we seperate it out into the following vertically it will appear like.
| VALUE | MEANING |
|-------|---------|
|  0    | Minute  |
|  *    | Hour    |
|  *    | Day     |
|  *    | Month   |
|  *    | Day of the week|

I advise reading more on cron scheduling if you are looking to do more than just modifying the script to run on more advanced timing. But for example if we wanted the script to run every two hours, we would use the following `0 */2 * * *` instead.  

---
## 9. Loading on Boot

The script will not load on boot when the RPiZero is first powered up.  This means that until the script is called via cron job or manually run, the USB emulated drive will not exist for Blink to access if the PI reboots.  To fix this, we need to create a service for systemd that will load on startup of the RPiZero. To do this we need to do the following:
- Create a script that will load on startup.
```
#!/bin/bash

LOG="/piusb/boot_gadget.log"
exec > "$LOG" 2>&1
set -e

echo "$(date) - Starting usb-gadget-boot.sh"

modprobe libcomposite

# Wait up to 10 seconds for configfs to be ready
for i in {1..10}; do
    if [[ -d /sys/kernel/config/usb_gadget ]]; then
        break
    fi
    echo "$(date) - Waiting for configfs to be ready..."
    sleep 1
done

# If gadget already exists, skip
if [[ -d /sys/kernel/config/usb_gadget/g1 ]]; then
    echo "$(date) - Gadget already exists, skipping setup"
    exit 0
fi

# BEGIN GADGET CREATION
mkdir -p /sys/kernel/config/usb_gadget/g1
cd /sys/kernel/config/usb_gadget/g1

echo 0x1d6b > idVendor    # Linux Foundation
echo 0x0104 > idProduct   # Multifunction Composite Gadget
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "1234567890" > strings/0x409/serialnumber #You can put anything here you like to distinguish it
echo "BlinkPi" > strings/0x409/manufacturer #You can put anything here you like to distinguish it
echo "Blink USB Drive" > strings/0x409/product #You can put anything here you like to distinguish it

mkdir -p configs/c.1/strings/0x409
echo "Config 1: Mass Storage" > configs/c.1/strings/0x409/configuration
echo 120 > configs/c.1/MaxPower

mkdir -p functions/mass_storage.usb0
echo 0 > functions/mass_storage.usb0/stall
echo 1 > functions/mass_storage.usb0/lun.0/removable
echo 0 > functions/mass_storage.usb0/lun.0/cdrom
echo 0 > functions/mass_storage.usb0/lun.0/nofua
echo /piusb/sync_sparse_1.bin > functions/mass_storage.usb0/lun.0/file

ln -s functions/mass_storage.usb0 configs/c.1/

UDC_DEVICE=$(ls /sys/class/udc | head -n 1)
echo "$UDC_DEVICE" > UDC
echo "$(date) - Gadget bound to $UDC_DEVICE"
```
*NOTE: Some of the variable names are referrenced as the same method as above. You can change these as you need to.*
- Save that file as a shell script in the `/usr/local/bin/` folder. For my use, I used `/usr/local/bin/usb-gadget-boot.sh`.
- Next we need to make the script executable:
```
chmod +x /usr/local/bin/usb-gadget-boot.sh
```
- Now edit/create the .service file for the service, located in the `/etc/systemd/system/` folder.  In my use case, I used `/etc/systemd/system/usb-gadget.service`.  This is an example of what I used to create the service on my RPiZero.
```
[Unit]
Description=USB Gadget Setup on Boot
After=multi-user.target sys-kernel-config.mount
Requires=sys-kernel-config.mount

[Service]
Type=oneshot
ExecStart=/usr/local/bin/usb-gadget-boot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

- Once that's saved, run the following commands to enable the service
```
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable usb-gadget.service
```

---

## 10. Blink Settings

You can use whatever settings you prefer for the Clip Length and Rearm Time for the cameras. I found these to be the best for my particular use case.  

I recommend keeping the Clip Length shorter than the WAIT_TIME defined in the script. If the Clip Length exceeds WAIT_TIME (especially at 60 seconds), the system may delay unbinding. If you raise Clip Length, adjust WAIT_TIME accordingly.

| Setting     | Value          | Reasoning                                         |
|-------------|----------------|--------------------------------------------------|
| Clip Length | 20 seconds     | Capture motion clips long enough for use        |
| Rearm Time  | 10 seconds     | Minimum allowed; balances clip frequency and sync stability |

---

## 11. To Do / Improvements

- [ ] Implement daily archive rotation on NAS
- [ ] Implement cleanup of backups to last 24 hours
- [ ] Implement monitoring via advanced logging via toggle in script
- [ ] Separate script into various parts to improve portability and modification

---

