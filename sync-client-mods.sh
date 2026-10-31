#!/usr/bin/env bash
# sync-mods.sh - sync your mods folder with client-mods.csv (Linux / macOS)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UA="OmarLawaty/mod-sync"
CSV="https://raw.githubusercontent.com/galactics-minecraft/mods-collector/master/client-mods.csv"
DRY=0
PRUNE=1
LOCAL=0
case "$(uname -s)" in
  Darwin) MODS="$HOME/Library/Application Support/minecraft/mods" ;;
  *) MODS="$HOME/.minecraft/mods" ;;
esac

usage() {
  cat <<'EOF'
Usage: ./sync-mods.sh [options]
  --csv <path|url>    override CSV location
  --mods-dir <path>   mods folder (default: your .minecraft/mods)
  --dry-run           show what would change, change nothing
  --no-prune          only download missing mods, never remove anything
  --local             use "mods.csv" from the same folder as this script
keep.txt (optional, next to this script): one file name or part of a name
per line. Matching jars are never removed.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --csv) [ $# -ge 2 ] || { usage; exit 2; }; CSV="$2"; shift 2 ;;
    --mods-dir) [ $# -ge 2 ] || { usage; exit 2; }; MODS="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --no-prune) PRUNE=0; shift ;;
    --local) LOCAL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

if [ "$LOCAL" -eq 1 ]; then
  CSV="$HERE/mods.csv"
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

fetch() { # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSLg --retry 3 --retry-delay 2 -A "$UA" -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -U "$UA" -t 3 -O "$2" "$1"
  else
    echo "[FAIL] need curl or wget installed" >&2
    return 127
  fi
}

# File name = last part of the link, URL-decoded. Fails if it isn't a .jar link.
filename_of() {
  local link="${1%%[?#]*}" f
  case "$link" in http://*|https://*) ;; *) return 1 ;; esac
  f="${link##*/}"
  f="$(printf '%b' "$(printf '%s' "$f" | sed 's/%/\\x/g')")"
  case "$(lower "$f")" in *.jar) ;; *) return 1 ;; esac
  printf '%s' "$f" | tr '<>:"\\|?*' '________'
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "CSV:      $CSV"
echo "Mods dir: $MODS$([ "$DRY" -eq 1 ] && echo '   (dry run)')"
echo

# ---------- load csv ----------
case "$CSV" in
  http://*|https://*)
    fetch "$CSV" "$TMP/in.csv" || { echo "[FAIL] could not download the CSV"; exit 1; }
    CSV_FILE="$TMP/in.csv" ;;
  *) CSV_FILE="$CSV" ;;
esac
[ -r "$CSV_FILE" ] || { echo "[FAIL] cannot read $CSV_FILE"; exit 1; }

# Proper CSV parsing (quoted cells, commas and "" inside names). Prints: name <TAB> link
awk '
function parse(line,   i, c, cell, q, len) {
  nf = 0; cell = ""; q = 0; len = length(line)
  for (i = 1; i <= len; i++) {
    c = substr(line, i, 1)
    if (q) {
      if (c == "\"") { if (substr(line, i + 1, 1) == "\"") { cell = cell "\""; i++ } else q = 0 }
      else cell = cell c
    } else if (c == "\"") q = 1
    else if (c == ",") { f[++nf] = cell; cell = "" }
    else cell = cell c
  }
  f[++nf] = cell
}
NR == 1 {
  sub(/^\357\273\277/, ""); sub(/\r$/, ""); parse($0)
  for (i = 1; i <= nf; i++) { h = tolower(f[i]); if (h == "mod name") nc = i; if (h == "link") lc = i }
  if (!nc || !lc) { print "CSV needs \"mod name\" and \"link\" columns" > "/dev/stderr"; exit 1 }
  next
}
{ sub(/\r$/, ""); if ($0 == "") next; parse($0); print f[nc] "\t" f[lc] }
' "$CSV_FILE" > "$TMP/rows.tsv" || exit 1

: > "$TMP/wanted.tsv"; : > "$TMP/wanted_lc.txt"; : > "$TMP/manual.tsv"
while IFS=$'\t' read -r name link; do
  [ -z "$link" ] && continue
  if file="$(filename_of "$link")"; then
    lc="$(lower "$file")"
    grep -Fxq -- "$lc" "$TMP/wanted_lc.txt" && continue
    printf '%s\n' "$lc" >> "$TMP/wanted_lc.txt"
    printf '%s\t%s\t%s\n' "$file" "$name" "$link" >> "$TMP/wanted.tsv"
  else
    printf '%s\t%s\n' "$name" "$link" >> "$TMP/manual.tsv"
  fi
done < "$TMP/rows.tsv"

# ---------- existing jars ----------
[ -d "$MODS" ] || { [ "$DRY" -eq 1 ] || mkdir -p "$MODS"; }
: > "$TMP/existing.txt"; : > "$TMP/existing_lc.txt"
if [ -d "$MODS" ]; then
  for p in "$MODS"/*; do
    [ -f "$p" ] || continue
    b="${p##*/}"
    case "$(lower "$b")" in
      *.jar) printf '%s\n' "$b" >> "$TMP/existing.txt"; lower "$b" >> "$TMP/existing_lc.txt"; echo >> "$TMP/existing_lc.txt" ;;
    esac
  done
fi
sed -i.bak '/^$/d' "$TMP/existing_lc.txt" 2>/dev/null; rm -f "$TMP/existing_lc.txt.bak"

: > "$TMP/keep.txt"
[ -f "$HERE/keep.txt" ] && tr -d '\r' < "$HERE/keep.txt" | tr '[:upper:]' '[:lower:]' | sed '/^[[:space:]]*$/d' > "$TMP/keep.txt"

is_kept() {
  local l k
  l="$(lower "$1")"
  while IFS= read -r k; do
    [ -n "$k" ] && case "$l" in *"$k"*) return 0 ;; esac
  done < "$TMP/keep.txt"
  return 1
}

# ---------- download ----------
uptodate=0; downloaded=0; failed=0
while IFS=$'\t' read -r file name link; do
  if grep -Fxq -- "$(lower "$file")" "$TMP/existing_lc.txt"; then
    uptodate=$((uptodate + 1)); continue
  fi
  if [ "$DRY" -eq 1 ]; then
    echo "[..] would download $file"; downloaded=$((downloaded + 1)); continue
  fi
  if fetch "$link" "$MODS/$file.part" && [ -s "$MODS/$file.part" ]; then
    mv -f "$MODS/$file.part" "$MODS/$file"
    echo "[OK] downloaded $file"; downloaded=$((downloaded + 1))
  else
    rm -f "$MODS/$file.part"
    echo "[FAIL] $name ($file)"; failed=$((failed + 1))
  fi
done < "$TMP/wanted.tsv"

# ---------- prune ----------
: > "$TMP/extras.txt"
while IFS= read -r f; do
  grep -Fxq -- "$(lower "$f")" "$TMP/wanted_lc.txt" && continue
  is_kept "$f" && continue
  printf '%s\n' "$f" >> "$TMP/extras.txt"
done < "$TMP/existing.txt"

removed=0
extras_n="$(wc -l < "$TMP/extras.txt" | tr -d ' ')"
if [ "$extras_n" -gt 0 ]; then
  if [ "$PRUNE" -eq 0 ]; then
    echo; echo "[i] $extras_n jar(s) are not in the list and were left alone (--no-prune)."
  elif [ "$failed" -gt 0 ]; then
    echo; echo "[WARN] Skipping removal of $extras_n extra jar(s) because $failed download(s) failed."
  else
    BACKUP="$(dirname "$MODS")/mods-removed/$(date +%Y-%m-%d_%H-%M-%S)"
    [ "$DRY" -eq 1 ] || mkdir -p "$BACKUP"
    while IFS= read -r f; do
      if [ "$DRY" -eq 1 ]; then echo "[..] would move $f out of the mods folder"
      else mv -f "$MODS/$f" "$BACKUP/$f"; echo "[--] removed $f"; fi
      removed=$((removed + 1))
    done < "$TMP/extras.txt"
    [ "$DRY" -eq 1 ] || echo "     (moved to $BACKUP)"
  fi
fi

# ---------- manual rows ----------
manual_n="$(wc -l < "$TMP/manual.tsv" | tr -d ' ')"
if [ "$manual_n" -gt 0 ]; then
  echo
  echo "[WARN] No direct .jar link for these. Download them by hand and add their jar name to keep.txt:"
  while IFS=$'\t' read -r name link; do echo "   - $name: $link"; done < "$TMP/manual.tsv"
fi

echo
echo "Done. $uptodate up to date, $downloaded $([ "$DRY" -eq 1 ] && echo 'to download' || echo downloaded), $removed $([ "$DRY" -eq 1 ] && echo 'to remove' || echo removed), $failed failed, $manual_n manual."
[ "$failed" -eq 0 ]
