#!/usr/bin/env bash
# sync-mods.sh - Simple Mod Sync
set -u

# Defaults to server-mods.csv if no file is passed
CSV="${1:-server-mods.csv}"
MODS="./mods"
UA="OmarLawaty/mod-sync"

echo "==> Syncing mods to $MODS using $CSV"

if [ ! -f "$CSV" ]; then
    echo "[FAIL] Cannot find $CSV"
    exit 1
fi

mkdir -p "$MODS"

# Setup temporary tracking file
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WANTED="$TMP/wanted.txt"
touch "$WANTED"

# Lowercase helper for macOS/Bash 3.2 compatibility 
lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 -A "$UA" -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -U "$UA" -t 3 -O "$2" "$1"
    else
        echo "[FAIL] curl or wget required" >&2
        exit 1
    fi
}

uptodate=0; downloaded=0; failed=0; removed=0

# 1. Parse CSV and download missing mods
# This cleanly extracts only HTTP links directly, avoiding messy CSV column parsing
while read -r link; do
    # Extract filename and decode URL (e.g., %20 to space, %2B to +)
    raw_name="${link%%[?#]*}"
    raw_name="${raw_name##*/}"
    file="$(printf '%b' "${raw_name//%/\\x}")"
    file_lower="$(lower "$file")"
    
    # Skip if the link doesn't result in a .jar
    if [[ "$file_lower" != *.jar ]]; then
        continue
    fi
    
    # Save to wanted list for the pruning step
    echo "$file_lower" >> "$WANTED"

    # Check if already downloaded
    if [ -f "$MODS/$file" ]; then
        uptodate=$((uptodate + 1))
    else
        echo "[..] Downloading $file"
        if fetch "$link" "$MODS/$file.part" && [ -s "$MODS/$file.part" ]; then
            mv -f "$MODS/$file.part" "$MODS/$file"
            echo "[OK] Saved $file"
            downloaded=$((downloaded + 1))
        else
            rm -f "$MODS/$file.part"
            echo "[FAIL] Failed to download $file"
            failed=$((failed + 1))
        fi
    fi
done < <(grep -oE 'https?://[^"]+' "$CSV")

# 2. Prune old/extra mods not in the CSV
BACKUP="./mods-removed/$(date +%Y-%m-%d_%H-%M-%S)"
for p in "$MODS"/*.jar; do
    [ -e "$p" ] || continue
    b="${p##*/}"
    if ! grep -Fxq -- "$(lower "$b")" "$WANTED"; then
        mkdir -p "$BACKUP"
        mv -f "$p" "$BACKUP/$b"
        echo "[--] Moved extra mod: $b"
        removed=$((removed + 1))
    fi
done

echo
echo "Done. $uptodate up to date, $downloaded downloaded, $removed removed, $failed failed."
[ "$failed" -eq 0 ]
