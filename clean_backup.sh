#!/bin/bash

BACKUP_DIR="/piusb/backup"
SAVE_TIMEFRAME=2

# Delete files older than 2 days
find "$BACKUP_DIR" -type f -mtime +$SAVE_TIMEFRAME -exec rm -f {} \;
