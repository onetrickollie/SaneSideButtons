# SaneSideButtons contribution: side buttons that arrive as a middle click

Course: CSCI 566 optional extra credit. Upstream project: https://github.com/thealpa/SaneSideButtons
(GPL-2.0). Base commit: `459c703` on `main`. The installed release used for testing was 1.4.1.

## Contents
| Path | What it is |
|---|---|
| `draft-issue.md` | Bug report draft with the evidence (not posted upstream) |
| `raw-side-buttons.patch` | Prototype fix (`git apply` on 459c703) |
| `RESULTS.md` | All measurements and what is and isn't verified |
| `tools/swiperecorder.swift` | Listen-only CGEvent logger (scroll, other-mouse, gesture events) |
| `tools/hidraw.swift` | Raw HID input-report reader for one VID/PID |
| `tools/parser_test.swift` | Unit check for the descriptor parser (4 cases) |
| `tools/*.sh`, `tools/analyze.py` | Guided recording sessions and the summary script |
| `recordings/` | Raw logs from every run on 2026-11-11 |

## Reproduce
```bash
cd tools
swiftc -O -o swiperecorder swiperecorder.swift
swiftc -O -o hidraw hidraw.swift
./swiperecorder buttons 20 buttons.jsonl   # press wheel, back, forward
./hidraw 248a 8566 20                      # same presses, raw report bytes
```
Both need Input Monitoring permission for the terminal app that runs them.

Parser check (from a SaneSideButtons checkout with the patch applied):
```bash
swiftc -parse-as-library -o parser_test SaneSideButtons/RawButtonMonitor.swift path/to/tools/parser_test.swift && ./parser_test
```
Expected output: `ALL PASS`.

Note: in `recordings/buttons.jsonl` the `front_app` field is redacted. It only records which window was in front during the button test and is not used by any result.
