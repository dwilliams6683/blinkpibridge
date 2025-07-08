#!/bin/bash

LOG="/piusb/boot_gadget.log"
GADGET_PATH="/sys/kernel/config/usb_gadget/g1"
VID="0x1d6b"
PID="0x0104"
SERIAL_NUMBER="0123456789"
MANUFACTURER="BlinkPi"
PRODUCT="Blink Pi USB Drive"
BACKING_FILE="/piusb/sync_sparse_1.bin"
UDC_PATH="/sys/class/udc"

echo "=============================="
echo "$(date) - Starting USB Gadget Setup"
echo "=============================="
echo "$(date) - Kernel cmdline: $(cat /proc/cmdline)"

exec > "$LOG" 2>&1
set -e

echo "$(date) - Starting usb-gadget-boot.sh"

modprobe libcomposite

# Check for backing file to exist
if [[ ! -f "$BACKING_FILE" ]]; then
    echo "$(date) - ERROR: Backing file $BACKING_FILE not found. Exiting."
    exit 1
fi

# Wait up to 10 seconds for configfs to be ready
for i in {1..10}; do
    if [[ -d /sys/kernel/config/usb_gadget ]]; then
        break
    fi
    echo "$(date) - Waiting for configfs to be ready..."
    sleep 1
done

# If gadget already exists, skip
if [[ -d $GADGET_PATH ]]; then
    echo "$(date) - Gadget already exists, skipping setup"
    exit 0
fi

# BEGIN GADGET CREATION
mkdir -p $GADGET_PATH
cd $GADGET_PATH

echo "$VID" > idVendor    # Linux Foundation
echo "$PID" > idProduct   # Multifunction Composite Gadget
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "$SERIAL_NUMBER" > strings/0x409/serialnumber #You can put anything here you like to distinguish it
echo "$MANUFACTURER" > strings/0x409/manufacturer #You can put anything here you like to distinguish it
echo "$PRODUCT" > strings/0x409/product #You can put anything here you like to distinguish it

mkdir -p configs/c.1/strings/0x409
echo "Config 1: Mass Storage" > configs/c.1/strings/0x409/configuration
echo 120 > configs/c.1/MaxPower

mkdir -p functions/mass_storage.usb0
echo 0 > functions/mass_storage.usb0/stall
echo 1 > functions/mass_storage.usb0/lun.0/removable
echo 0 > functions/mass_storage.usb0/lun.0/cdrom
echo 0 > functions/mass_storage.usb0/lun.0/nofua
echo "$BACKING_FILE" > functions/mass_storage.usb0/lun.0/file

ln -s functions/mass_storage.usb0 configs/c.1/

UDC_DEVICE=$(ls "$UDC_PATH" | head -n 1)
if [[ -z "$UDC_DEVICE" ]]; then
    echo "$(date) - ERROR: No UDC device found. Exiting."
    exit 1
fi
echo "$UDC_DEVICE" > UDC
echo "$(date) - Gadget bound to $UDC_DEVICE"