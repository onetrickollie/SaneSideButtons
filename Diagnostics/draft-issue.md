# Draft issue for thealpa/SaneSideButtons (not posted)

**Title:** Side buttons arrive as middle click (button 2) on mice whose HID descriptor names only Button 1–3

### Description
With my Delux mouse, the back and forward side buttons do nothing in Safari, Chrome or Finder.
The cause is not the event tap. The mouse's 2.4 GHz receiver declares 5 button bits in its HID
report descriptor but only gives usages Button 1–3. macOS gives the extra bits the last usage
(Button 3, the middle button), so both side buttons reach the CGEvent layer as
`otherMouseDown` with button number **2**. They are identical to a wheel click, and
`handleMouseEvent` only acts on 3 and 4.

This may be related to #40 (Microsoft mouse whose side buttons send pan left/right). It is a
different mapping, but the same kind of problem: the buttons never arrive as 3 and 4.

### Environment
- macOS 27.2.1 (26B131), MacBook Pro (Apple Silicon)
- SaneSideButtons 1.4.1 (Homebrew), also tested on `main` (459c703)
- Mouse: Delux, through a "Wireless Receiver" with USB VID `0x248A`, PID `0x8566`

### Evidence
1. **CGEvent level** (listen-only session tap, `swiperecorder.swift`). Pressing wheel, back, then
   forward gives three `otherMouseDown`/`otherMouseUp` pairs, all with `mouseEventButtonNumber == 2`.
2. **Descriptor** (mouse interface, report ID 1):
   `05 09 19 01 29 03 15 00 25 01 75 01 95 05 81 02`, which is Usage Min 1, Usage Max 3,
   Report Count **5**.
3. **Raw input reports** (IOHIDManager, `hidraw.swift`):

   | Press | Button byte |
   |---|---|
   | Wheel | `0x04` (bit 3) |
   | Back | `0x08` (bit 4) |
   | Forward | `0x10` (bit 5) |

   The hardware does tell them apart. The information is lost when macOS maps the bits to usages.

### Possible fix (prototype attached)
`RawButtonMonitor.swift` parses each mouse's report descriptor and only opens devices that have
unnamed button bits. It reads their raw reports, and when a button-2 press arrives it checks
whether an unnamed bit was just pressed. If so, it posts the swipe and swallows the middle click
and its release. Mice with complete descriptors are untouched.

Status: the monitor attaches to the receiver and blocks the side-button middle clicks in Safari.
Back/forward navigation did not happen in my tests. I have not yet confirmed whether the posted
swipe is delivered on macOS 27, so this needs more testing before it is merge-ready. It also needs
the Input Monitoring permission and the `device.usb` / `device.bluetooth` sandbox entitlements.
