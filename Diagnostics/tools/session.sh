#!/bin/bash
# Guided recording session: trackpad swipe vs. side button, per app.
# Run from macOS Terminal (which needs Input Monitoring permission).
# Usage: ./session.sh [output-dir]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/runs/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
REC="$HERE/swiperecorder"
SECS=8

APPS=("Safari" "Google Chrome" "Finder" "Muse")
echo "Output: $OUT"
echo "Before starting: SaneSideButtons is running, and each app has a page/folder"
echo "with some history so 'back' has somewhere to go."
echo

{
  echo "macos=$(sw_vers -productVersion) build=$(sw_vers -buildVersion)"
  echo "ssb_version=$(defaults read /Applications/SaneSideButtons.app/Contents/Info CFBundleShortVersionString 2>/dev/null)"
  echo "date=$(date)"
} > "$OUT/env.txt"
echo "label,app,input,rating,notes" > "$OUT/ratings.csv"

for app in "${APPS[@]}"; do
  for input in trackpad sidebutton; do
    slug="$(echo "$app" | tr 'A-Z ' 'a-z-')-$input"
    if [ "$input" = trackpad ]; then
      what="swipe BACK once with two fingers on the trackpad"
    else
      what="press the mouse BACK side button once"
    fi
    echo "=== $app / $input"
    echo "Switch to $app. Press Enter here, then within 2s click into $app and $what."
    echo "(Recording lasts ${SECS}s. Type s + Enter to skip.)"
    read -r ans; [ "$ans" = s ] && continue
    "$REC" "$slug" "$SECS" "$OUT/$slug.jsonl"
    echo "How did it feel? 1=smooth like before  2=works but jumpy/not smooth  3=nothing happened  4=wrong/funky"
    read -r rating
    echo "Any notes? (Enter to skip)"
    read -r notes
    printf '%s,"%s",%s,%s,"%s"\n' "$slug" "$app" "$input" "$rating" "${notes//\"/\'}" >> "$OUT/ratings.csv"
    echo
  done
done
echo "Done. Results in $OUT"
