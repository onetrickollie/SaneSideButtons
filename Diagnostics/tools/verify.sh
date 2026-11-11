#!/bin/bash
# Verification run for the patched build: side buttons should become swipes,
# and a real wheel click should still pass through as button 2.
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="${1:-patched}"
mkdir -p "$HERE/runs"
APPS=("Safari" "Google Chrome" "Finder")
echo "label,app,did_back_work,did_forward_work,wheel_click_ok,notes" > "$HERE/runs/$LABEL-ratings.csv"
for app in "${APPS[@]}"; do
  slug="$LABEL-$(echo "$app" | tr 'A-Z ' 'a-z-')"
  echo "=== $app"
  echo "Open a page/folder in $app that has back history. Press Enter, then within 2s click into $app and,"
  echo "about 2s apart: press BACK side button, press FORWARD side button, then click the WHEEL once on empty space."
  echo "(12s recording. Type s + Enter to skip.)"
  read -r ans; [ "$ans" = s ] && continue
  "$HERE/swiperecorder" "$slug" 12 "$HERE/runs/$slug.jsonl"
  read -r -p "Did BACK navigate back? (y/n) " b
  read -r -p "Did FORWARD navigate forward? (y/n) " f
  read -r -p "Did the wheel click behave normally (no back/forward)? (y/n) " w
  read -r -p "Notes (Enter to skip): " n
  printf '%s,"%s",%s,%s,%s,"%s"\n' "$slug" "$app" "$b" "$f" "$w" "${n//\"/\'}" >> "$HERE/runs/$LABEL-ratings.csv"
  echo
done
echo "Done."
