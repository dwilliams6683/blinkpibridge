#!/bin/bash

OLD_DIR="./old"
TIMESTAMP=$(date +"%m%d%Y")
DRY_RUN=0
HASH_CMD="sha256sum"
LOG="updatelog.txt"
VERBOSE=1

# Parse options
while getopts ":n" opt; do
  case $opt in
    n)
      DRY_RUN=1
      ;;
    \?)
      echo "Usage: $0 [-n]   Perform a dry run (no files will be moved)"
      exit 1
      ;;
  esac
done

echo "========== $(date '+%Y-%m-%d %H:%M:%S') STARTING UPDATE ==========" >> "$LOG"
if [ "$VERBOSE" -eq 1 ]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
else
  exec >> "$LOG_FILE" 2>&1
fi


mkdir -p "$OLD_DIR"

for newfile in *.new; do
    [[ -e "$newfile" ]] || continue

    base="${newfile%.new}"
    target="$base.sh"
    backup="$OLD_DIR/${base}_${TIMESTAMP}.sh"

    # If the .sh file exists, compare hashes
    if [[ -f "$target" ]]; then
        new_hash=$($HASH_CMD "$newfile" | cut -d ' ' -f1)
        old_hash=$($HASH_CMD "$target" | cut -d ' ' -f1)

        if [[ "$new_hash" == "$old_hash" ]]; then
            echo "No changes detected in $target — skipping."
            continue
        else
            echo "Change detected in $target — hashes differ."
        fi
    else
        echo "No existing $target — will install new version."
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        [[ -f "$target" ]] && echo "[Dry Run] Would back up '$target' to '$backup'"
        echo "[Dry Run] Would replace '$target' with '$newfile'"
        echo "[Dry Run] Would chmod +x '$target'"
    else
        [[ -f "$target" ]] && mv "$target" "$backup" && echo "Backed up $target to $backup"
        mv "$newfile" "$target"
        chmod +x "$target"
        echo "Updated $target with $newfile"
    fi
done
