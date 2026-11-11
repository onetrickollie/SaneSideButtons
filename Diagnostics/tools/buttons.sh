#!/bin/bash
# Records which button numbers / scroll axes each physical mouse button sends.
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/runs"
echo "Button test. After you press Enter you get 20 seconds. Slowly, about 2s apart:"
echo "  1) wheel click   2) BACK side button   3) FORWARD side button"
echo "  4) tilt the wheel left, then right (skip if it can't tilt)"
echo "Don't scroll the wheel during the test."
read -r -p "Press Enter to start... "
"$HERE/swiperecorder" buttons 20 "$HERE/runs/buttons.jsonl"
