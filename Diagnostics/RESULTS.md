# SaneSideButtons side-button findings (for the extra-credit report)

Setup: MacBook Pro (Mac15,6), macOS 27.2.1 (26B131), SaneSideButtons 1.4.1 (Homebrew) and a
patched debug build of `main` (459c703). Mouse: Delux, through a 2.4 GHz "Wireless Receiver",
USB VID 0x248A / PID 0x8566. All runs were recorded on 2026-11-11.

## 1. The side buttons reach macOS as a middle click (1.4.1, unpatched)

Tool: `swiperecorder` (listen-only CGEvent tap). Run: `runs/buttons.jsonl`.
Pressed in order: wheel click, back side button, forward side button.

| Press | CGEvent seen | Button number |
|---|---|---|
| Wheel click | otherMouseDown/Up | 2 |
| Back side button | otherMouseDown/Up | 2 |
| Forward side button | otherMouseDown/Up | 2 |

SaneSideButtons only acts on button numbers 3 and 4 (`SwipeSimulator.handleMouseEvent`), so it
never triggers with this mouse. That matches the user ratings in `runs/20261111-135554/ratings.csv`
("nothing happened" for the side button in Safari, Chrome and Finder).

## 2. The hardware does tell them apart

Receiver HID report descriptor (mouse interface, report ID 1):
`05 09 19 01 29 03 ... 75 01 95 05 81 02` means 5 button bits, but only usages Button 1 to 3.
Under the HID rules for that, the 4th and 5th bits get the last usage, Button 3 (middle).

Tool: `hidraw` (IOHIDManager raw input reports). Run: `runs/rawbuttons.txt`.

| Press | Raw button byte | Bit set |
|---|---|---|
| Wheel click | `04` | 3 |
| Back side button | `08` | 4 |
| Forward side button | `10` | 5 |

macOS's parsed HID values only reported the wheel bit (usage 3, cookie 18). Bits 4 and 5 produced
no parsed value of their own.

## 3. Patch: RawButtonMonitor

- Parses each mouse's report descriptor and only watches devices with button bits that have no usage.
- Unit check of the descriptor parser: 4/4 pass (Delux receiver, standard 5-button mouse,
  3-button mouse, keyboard receiver with the same flaw).
- In the running patched app, a stack sample shows the monitor thread receiving raw reports from the
  receiver (`reportReceived` -> `handleReport`).
- With the patch, the session-level recorder saw only the wheel click's button-2 event in Safari
  (1 of 3 presses), so the side-button middle clicks were blocked
  (`runs/patched-safari.jsonl`). In Chrome, 2 of 3 presses still came through as button 2
  (`runs/patched-google-chrome.jsonl`).
- Not achieved: back/forward navigation. The user reported it didn't navigate in Safari or Chrome,
  and the recorder never captured a synthetic swipe event in any run, before or after the patch.
  It is not yet known whether that is because the 2010-era swipe events no longer work on
  macOS 27, because the recorder can't see them, or because of local setup.

## Open items

- Add public `Logger` lines to the patch to confirm each step (press seen, click swallowed,
  swipe posted), then re-test. The rebuild needs the permissions granted again.
- Chrome run: find out why one side press still passed through (timing window or press order).
- SwiftLint warnings in `RawButtonMonitor.swift` (function length, complexity, parameter count).
- `use.swift` at the repo root is a personal note and must not go upstream.
