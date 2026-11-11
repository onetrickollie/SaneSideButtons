// hidraw: prints raw HID input reports from one device, to check whether
// the mouse's side buttons are distinguishable below the CGEvent layer.
// Usage: hidraw <vendorID hex> <productID hex> [seconds=20]
import Foundation
import IOKit.hid

let a = CommandLine.arguments
let vid = Int(a.count > 1 ? a[1] : "248a", radix: 16) ?? 0x248a
let pid = Int(a.count > 2 ? a[2] : "8566", radix: 16) ?? 0x8566
let secs = a.count > 3 ? (Double(a[3]) ?? 20) : 20

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: vid, kIOHIDProductIDKey: pid] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
guard r == kIOReturnSuccess, let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !devs.isEmpty else {
    fputs("could not open device (ret \(r)); permission or wrong IDs\n", stderr); exit(2)
}
let start = Date()
var lastButtons: [UInt32: UInt8] = [:]
var reportCount = 0
func stamp() -> String { String(format: "%7.0f", Date().timeIntervalSince(start) * 1000) }
// Raw reports: print only when the button byte changes, per report ID.
// With report IDs, byte 0 of the buffer is the report ID and byte 1 the buttons.
let cb: IOHIDReportCallback = { _, _, _, _, reportID, report, length in
    reportCount += 1
    let bytes = (0..<length).map { report[$0] }
    let idx = reportID == 0 ? 0 : 1
    guard bytes.count > idx else { return }
    let b = bytes[idx]
    guard b != lastButtons[reportID] else { return }
    lastButtons[reportID] = b
    let bits = (0..<5).map { (b >> $0) & 1 == 1 ? "\($0 + 1)" : "." }.joined(separator: " ")
    print("\(stamp())ms REPORT id=\(reportID) button bits [\(bits)]  raw=\(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
    fflush(stdout)
}
// Parsed values: every button-page element change, with its cookie, so two
// physical buttons that share a usage number still show up as different elements.
let vcb: IOHIDValueCallback = { _, _, _, value in
    let el = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(el)
    guard page == 9 else { return }
    print("\(stamp())ms VALUE button-usage=\(IOHIDElementGetUsage(el)) cookie=\(IOHIDElementGetCookie(el)) value=\(IOHIDValueGetIntegerValue(value))")
    fflush(stdout)
}
IOHIDManagerRegisterInputValueCallback(mgr, vcb, nil)
for d in devs {
    let size = 64
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    IOHIDDeviceRegisterInputReportCallback(d, buf, size, cb, nil)
    let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
    fputs("listening to \(name) (\(String(vid, radix: 16)):\(String(pid, radix: 16))) for \(Int(secs))s\n", stderr)
}
DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
    fputs("raw reports received: \(reportCount)\n", stderr); exit(0)
}
CFRunLoopRun()
