// SwipeRecorder: a listen-only event logger for comparing a real trackpad
// "swipe back/forward" with the synthetic swipe SaneSideButtons posts.
//
// Usage: swiperecorder <label> [seconds=15] [out.jsonl]
// Needs Input Monitoring permission for the process that runs it.
// It never modifies or blocks events (listenOnly tap).

import AppKit
import Foundation

let args = CommandLine.arguments
let label = args.count > 1 ? args[1] : "run"
let seconds = args.count > 2 ? (Double(args[2]) ?? 15) : 15
let outPath = args.count > 3 ? args[3] : "\(label).jsonl"

guard CGPreflightListenEventAccess() else {
    CGRequestListenEventAccess()
    fputs("ERROR: no Input Monitoring permission for this process.\n", stderr)
    exit(2)
}

// Event types we care about (raw CGEventType values).
// 22 scrollWheel, 25 otherMouseDown, 26 otherMouseUp,
// 29 gesture (NSEventTypeGesture family), 30 dock/fluid swipe, 31+ other private.
func isInteresting(_ t: UInt32) -> Bool {
    t == 22 || t == 25 || t == 26 || (t >= 27 && t < 0xFFFF_FFFE)
}

let out = FileHandle(forWritingAtPath: outPath) ?? {
    FileManager.default.createFile(atPath: outPath, contents: nil)
    return FileHandle(forWritingAtPath: outPath)!
}()
out.truncateFile(atOffset: 0)

var firstTimestamp: UInt64 = 0
var counts: [String: Int] = [:]
var tapRef: CFMachPort?

func nsTypeName(_ e: NSEvent?) -> String {
    guard let e else { return "-" }
    return String(describing: e.type)
}

func phaseName(_ p: NSEvent.Phase) -> String {
    var parts: [String] = []
    if p.contains(.began) { parts.append("began") }
    if p.contains(.stationary) { parts.append("stationary") }
    if p.contains(.changed) { parts.append("changed") }
    if p.contains(.ended) { parts.append("ended") }
    if p.contains(.cancelled) { parts.append("cancelled") }
    if p.contains(.mayBegin) { parts.append("mayBegin") }
    return parts.isEmpty ? "none" : parts.joined(separator: "|")
}

func record(_ type: CGEventType, _ event: CGEvent) {
    let raw = type.rawValue
    guard isInteresting(raw) else { return }
    if firstTimestamp == 0 { firstTimestamp = event.timestamp }
    let tMs = Double(event.timestamp &- firstTimestamp) / 1_000_000.0

    // Field 41 = kCGEventSourceUnixProcessID: tells real hardware (pid 0 / WindowServer)
    // apart from events posted by an app such as SaneSideButtons.
    let srcPID = event.getIntegerValueField(CGEventField(rawValue: 41)!)
    var srcName = "?"
    if srcPID > 0, let app = NSRunningApplication(processIdentifier: pid_t(srcPID)) {
        srcName = app.localizedName ?? app.bundleIdentifier ?? "\(srcPID)"
    } else if srcPID == 0 {
        srcName = "hardware"
    }

    // Dump every non-zero integer and double field. Gesture details live in
    // undocumented fields (e.g. 110 HID subtype, 132 phase, 123/124 swipe data).
    var ints: [String: Int64] = [:]
    var dbls: [String: Double] = [:]
    for f in 0..<256 {
        guard let field = CGEventField(rawValue: UInt32(f)) else { continue }
        let i = event.getIntegerValueField(field)
        if i != 0 { ints[String(f)] = i }
        let d = event.getDoubleValueField(field)
        if d != 0, Double(i) != d { dbls[String(f)] = d }
    }

    let ns = NSEvent(cgEvent: event)
    var row: [String: Any] = [
        "label": label,
        "t_ms": (tMs * 1000).rounded() / 1000,
        "cg_type": raw,
        "ns_type": nsTypeName(ns),
        "source_pid": srcPID,
        "source": srcName,
        "front_app": NSWorkspace.shared.frontmostApplication?.localizedName ?? "?",
        "int_fields": ints,
        "double_fields": dbls,
    ]
    if let ns {
        if [.scrollWheel, .swipe, .gesture, .beginGesture, .endGesture, .magnify, .smartMagnify].contains(ns.type) {
            row["phase"] = phaseName(ns.phase)
            row["momentum_phase"] = phaseName(ns.momentumPhase)
        }
        if ns.type == .scrollWheel {
            row["scroll_dx"] = ns.scrollingDeltaX
            row["scroll_dy"] = ns.scrollingDeltaY
        }
        if ns.type == .otherMouseDown || ns.type == .otherMouseUp {
            row["button"] = ns.buttonNumber
        }
        if ns.type == .swipe {
            row["swipe_dx"] = ns.deltaX
        }
    }
    let key = "\(row["ns_type"]!) from \(srcName)"
    counts[key, default: 0] += 1

    if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
        out.write(data)
        out.write("\n".data(using: .utf8)!)
    }
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tapRef { CGEvent.tapEnable(tap: tapRef, enable: true) }
        fputs("note: recorder tap was disabled by macOS (\(type.rawValue)); re-enabled\n", stderr)
        return Unmanaged.passUnretained(event)
    }
    record(type, event)
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .listenOnly,
                                  // Scroll, other-mouse buttons and gesture types only.
                                  // Keyboard events are never requested.
                                  eventsOfInterest: [22, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40]
                                      .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) },
                                  callback: callback,
                                  userInfo: nil) else {
    fputs("ERROR: could not create event tap (permission?)\n", stderr)
    exit(3)
}
tapRef = tap
let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

fputs("recording '\(label)' for \(Int(seconds))s -> \(outPath)\n", stderr)
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    out.closeFile()
    fputs("done. event counts:\n", stderr)
    for (k, v) in counts.sorted(by: { $0.key < $1.key }) { fputs("  \(v)\t\(k)\n", stderr) }
    exit(0)
}
CFRunLoopRun()
