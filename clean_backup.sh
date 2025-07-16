#!/bin/bash

BACKUP_DIR="/piusb/backup"
LOG_FILE="/piusb/backup_cleanup.log"

usage() {
  echo "Usage: $0 [-t HOURS] [-s SIZE_MB]"
  echo "  -t HOURS   Delete files older than HOURS"
  echo "  -s SIZE_MB Delete oldest files until total size <= SIZE_MB"
  exit 1
}

if [ ! -d "$BACKUP_DIR" ]; then
  echo "$(date) ERROR: Backup directory $BACKUP_DIR does not exist." >&2
  exit 1
fi

# Parse args
TIME_HOURS=""
SIZE_MB=""

while getopts ":t:s:" opt; do
  case $opt in
    t) TIME_HOURS=$OPTARG ;;
    s) SIZE_MB=$OPTARG ;;
    *) usage ;;
  esac
done

if [[ -n $TIME_HOURS && -n $SIZE_MB ]]; then
  echo "Error: Please specify only one of -t or -s" >&2
  usage
fi

if [[ -z $TIME_HOURS && -z $SIZE_MB ]]; then
  echo "Error: You must specify either -t or -s" >&2
  usage
fi

echo "$(date) Starting backup cleanup in $BACKUP_DIR" >> "$LOG_FILE"

if [[ -n $TIME_HOURS ]]; then
  # Delete files older than TIME_HOURS hours
  echo "$(date) Deleting files older than $TIME_HOURS hours" >> "$LOG_FILE"
  find "$BACKUP_DIR" -type f -mmin +$(( TIME_HOURS * 60 )) -print -exec rm -f {} \; >> "$LOG_FILE" 2>&1

elif [[ -n $SIZE_MB ]]; then
  # Delete oldest files until total size <= SIZE_MB

  # Get total size in KB
  total_kb=$(du -sk "$BACKUP_DIR" | cut -f1)
  max_kb=$(( SIZE_MB * 1024 ))


  echo "$(date) Current backup size: $(( total_kb / 1024 )) MB, target max size: $SIZE_MB MB" >> "$LOG_FILE"

  while [[ $total_kb -gt $max_kb ]]; do
    # Find oldest file
    oldest_file=$(find "$BACKUP_DIR" -type f -printf '%T+ %p\n' | sort | head -n 1 | cut -d' ' -f2-)

    if [[ -z $oldest_file ]]; then
      echo "$(date) No more files to delete but size still above target." >> "$LOG_FILE"
      break
    fi

    echo "$(date) Deleting oldest file $oldest_file" >> "$LOG_FILE"
    rm -f "$oldest_file"

    total_kb=$(du -sk "$BACKUP_DIR" | cut -f1)
  done
fi

echo "$(date) Cleanup completed." >> "$LOG_FILE"
