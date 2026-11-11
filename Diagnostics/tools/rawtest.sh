#!/bin/bash
# Raw HID test: are the side buttons distinguishable from the wheel click?
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/runs"
echo "Raw button test. After Enter you get 20 seconds. Slowly, about 2s apart,"
echo "and hold each button for about half a second:"
echo "  1) wheel click   2) BACK side button   3) FORWARD side button"
echo "Don't move or scroll the mouse more than you need to."
read -r -p "Press Enter to start... "
"$HERE/hidraw" 248a 8566 20 | tee "$HERE/runs/rawbuttons.txt"
