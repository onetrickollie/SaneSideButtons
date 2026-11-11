//
//  RawButtonMonitor.swift
//  SaneSideButtons
//
//  Some mice declare more button bits in their HID report descriptor than
//  they give button usages to. For example, a "Wireless Receiver"
//  (VID 0x248A, PID 0x8566) declares 5 button bits but only usages
//  Button 1...3. macOS gives the unnamed bits the last named usage
//  (Button 3, the middle button), so both side buttons reach the CGEvent
//  layer as `otherMouseDown` with button number 2 and can't be told apart
//  from a wheel click there.
//
//  This monitor reads raw input reports only from devices with such unnamed
//  button bits and records presses of them, so the event tap can turn the
//  matching "middle click" into a back/forward swipe instead.
//  Mice with complete descriptors are never opened by it.
//

import Foundation
import IOKit.hid
import os
import Synchronization

private let logger = Logger(subsystem: "com.janhuelsmann.SaneSideButtons", category: "RawButtonMonitor")

// MARK: - Descriptor parsing

/// A run of 1-bit button inputs in an input report.
struct HIDButtonField: Equatable, Sendable {
    /// Report ID, or 0 when the device doesn't use report IDs.
    let reportID: UInt8
    /// Bit offset of the first button inside the report payload (after the report ID byte).
    let bitOffset: Int
    /// Number of button bits in the field.
    let count: Int
    /// Number of those bits that have their own button usage.
    let namedCount: Int

    /// Payload bit positions with no usage of their own, in order (first = back, second = forward).
    var unnamedBitPositions: [Int] {
        guard self.count > self.namedCount else { return [] }
        return Array((self.bitOffset + self.namedCount)..<(self.bitOffset + self.count))
    }
}

enum HIDDescriptorParser {
    /// One short item of a report descriptor.
    private struct Item {
        let type: UInt8
        let tag: UInt8
        let value: UInt32
    }

    /// Global items that stay in effect until changed (or popped).
    private struct Globals {
        var usagePage: UInt32 = 0
        var reportSize: Int = 0
        var reportCount: Int = 0
        var reportID: UInt8 = 0
    }

    /// Parser state while walking the descriptor.
    private struct State {
        var globals = Globals()
        var stack: [Globals] = []
        var usages = 0
        var usageMin: UInt32?
        var usageMax: UInt32?
        var inputOffsets: [UInt8: Int] = [:]
        var fields: [HIDButtonField] = []

        mutating func apply(_ item: Item) {
            switch item.type {
            case 0: self.applyMain(item)
            case 1: self.applyGlobal(item)
            case 2: self.applyLocal(item)
            default: break
            }
        }

        private mutating func applyGlobal(_ item: Item) {
            switch item.tag {
            case 0x0: self.globals.usagePage = item.value
            case 0x7: self.globals.reportSize = Int(item.value)
            case 0x8: self.globals.reportID = UInt8(truncatingIfNeeded: item.value)
            case 0x9: self.globals.reportCount = Int(item.value)
            case 0xA: self.stack.append(self.globals)
            case 0xB: if let top = self.stack.popLast() { self.globals = top }
            default: break
            }
        }

        private mutating func applyLocal(_ item: Item) {
            switch item.tag {
            case 0x0: self.usages += 1
            case 0x1: self.usageMin = item.value
            case 0x2: self.usageMax = item.value
            default: break
            }
        }

        /// Input items add fields; every main item (Input, Output, Feature, Collection,
        /// End Collection) clears the local items.
        private mutating func applyMain(_ item: Item) {
            defer {
                self.usages = 0
                self.usageMin = nil
                self.usageMax = nil
            }
            guard item.tag == 0x8 else { return }
            let globals = self.globals
            let offset = self.inputOffsets[globals.reportID, default: 0]
            self.inputOffsets[globals.reportID] = offset + globals.reportSize * globals.reportCount

            let isConstant = item.value & 0x01 != 0
            let isVariable = item.value & 0x02 != 0
            guard !isConstant, isVariable, globals.usagePage == 0x09, globals.reportSize == 1 else { return }
            var named = self.usages
            if let min = self.usageMin, let max = self.usageMax, max >= min {
                named += Int(max - min + 1)
            }
            self.fields.append(HIDButtonField(reportID: globals.reportID,
                                              bitOffset: offset,
                                              count: globals.reportCount,
                                              namedCount: Swift.min(named, globals.reportCount)))
        }
    }

    /// Returns every Button-page (0x09) input field of 1-bit variables in a HID report descriptor.
    static func buttonFields(in descriptor: [UInt8]) -> [HIDButtonField] {
        var state = State()
        var index = 0
        while index < descriptor.count {
            let prefix = descriptor[index]
            if prefix == 0xFE { // long item: 0xFE, size, tag, data...
                guard index + 1 < descriptor.count else { break }
                index += 3 + Int(descriptor[index + 1])
                continue
            }
            let sizeCode = Int(prefix & 0x03)
            let size = sizeCode == 3 ? 4 : sizeCode
            guard index + size < descriptor.count else { break }
            var value: UInt32 = 0
            for byte in 0..<size {
                value |= UInt32(descriptor[index + 1 + byte]) << (8 * UInt32(byte))
            }
            index += 1 + size
            state.apply(Item(type: (prefix >> 2) & 0x03, tag: prefix >> 4, value: value))
        }
        return state.fields
    }
}

// MARK: - Raw report monitor

final class RawButtonMonitor: Sendable {

    enum Side: Sendable {
        case back
        case forward
    }

    /// Per-device data, only touched on the monitor thread.
    fileprivate final class DeviceBox {
        let fields: [HIDButtonField]
        let buffer: UnsafeMutablePointer<UInt8>
        let bufferSize: Int
        var previouslyPressed: Set<Int> = []

        init(fields: [HIDButtonField], bufferSize: Int) {
            self.fields = fields
            self.bufferSize = bufferSize
            self.buffer = .allocate(capacity: bufferSize)
        }

        deinit { self.buffer.deallocate() }
    }

    private struct State {
        var quirkyDevices: Int = 0
        var pending: [(side: Side, time: UInt64)] = []
    }

    static let shared = RawButtonMonitor()

    /// How long a raw side-button press stays valid for matching with a CGEvent.
    private static let pendingLifetimeNs: UInt64 = 150_000_000

    private let state: Mutex<State> = Mutex(State())
    /// Attached devices: device pointer bits -> retained DeviceBox pointer bits.
    private let attached: Mutex<[Int: Int]> = Mutex([:])
    private let started: Mutex<Bool> = Mutex(false)

    private init() { }

    /// True while at least one connected mouse has unnamed button bits.
    var hasQuirkyDevice: Bool {
        self.state.withLock { $0.quirkyDevices > 0 }
    }

    /// Starts listening on a background thread. Safe to call more than once.
    func start() {
        let shouldStart = self.started.withLock { started in
            defer { started = true }
            return !started
        }
        guard shouldStart else { return }
        let thread = Thread { RawButtonMonitor.shared.runMonitor() }
        thread.name = "SaneSideButtons.RawButtonMonitor"
        thread.start()
    }

    /// Waits up to `timeout` seconds for a raw side-button press and consumes it.
    /// Called from the event tap when a middle-button press arrives.
    func consumeSidePress(waitingUpTo timeout: TimeInterval) -> Side? {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        repeat {
            let now = DispatchTime.now().uptimeNanoseconds
            let side: Side? = self.state.withLock { state in
                state.pending.removeAll { now &- $0.time > Self.pendingLifetimeNs }
                return state.pending.isEmpty ? nil : state.pending.removeFirst().side
            }
            if let side { return side }
            usleep(500)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return nil
    }

    // MARK: - Monitor thread

    private func runMonitor() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let mouseMatch: [String: Int] = [kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
                                         kIOHIDPrimaryUsageKey: kHIDUsage_GD_Mouse]
        IOHIDManagerSetDeviceMatching(manager, mouseMatch as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatched, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemoved, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            // Usually missing Input Monitoring permission. Normal mice keep working.
            logger.error("Raw button monitor unavailable (IOHIDManagerOpen \(result, privacy: .public))")
            return
        }
        CFRunLoopRun()
    }

    fileprivate func attach(_ device: IOHIDDevice) {
        guard let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else {
            return
        }
        let fields = HIDDescriptorParser.buttonFields(in: [UInt8](descriptor))
            .filter { !$0.unnamedBitPositions.isEmpty }
        guard !fields.isEmpty else { return }

        let maxReport = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
        let box = DeviceBox(fields: fields, bufferSize: Swift.max(maxReport, 1))
        let key = Int(bitPattern: Unmanaged.passUnretained(device).toOpaque())
        let context = Unmanaged.passRetained(box).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, box.buffer, box.bufferSize, reportReceived, context)
        self.attached.withLock { $0[key] = Int(bitPattern: context) }
        self.state.withLock { $0.quirkyDevices += 1 }
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
        logger.notice("Reading unnamed side-button bits from \(name, privacy: .public)")
    }

    fileprivate func detach(_ device: IOHIDDevice) {
        let key = Int(bitPattern: Unmanaged.passUnretained(device).toOpaque())
        guard let boxBits = self.attached.withLock({ $0.removeValue(forKey: key) }),
              let pointer = UnsafeMutableRawPointer(bitPattern: boxBits) else { return }
        Unmanaged<DeviceBox>.fromOpaque(pointer).release()
        self.state.withLock { $0.quirkyDevices = Swift.max(0, $0.quirkyDevices - 1) }
    }

    fileprivate func handleReport(box: DeviceBox, reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        // With report IDs, byte 0 of the buffer is the ID itself.
        let payloadStart = reportID == 0 ? 0 : 1
        var pressedNow: Set<Int> = []
        var newPresses: [Side] = []
        for field in box.fields where UInt32(field.reportID) == reportID {
            for (order, bit) in field.unnamedBitPositions.prefix(2).enumerated() {
                let byteIndex = payloadStart + bit / 8
                guard byteIndex < length else { continue }
                let isDown = (report[byteIndex] >> UInt8(bit % 8)) & 1 == 1
                let key = Int(field.reportID) << 16 | bit
                if isDown {
                    pressedNow.insert(key)
                    if !box.previouslyPressed.contains(key) {
                        newPresses.append(order == 0 ? .back : .forward)
                    }
                }
            }
        }
        // Keep the pressed state of other report IDs untouched.
        box.previouslyPressed = box.previouslyPressed.filter { $0 >> 16 != Int(reportID) }.union(pressedNow)
        guard !newPresses.isEmpty else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        self.state.withLock { state in
            state.pending.append(contentsOf: newPresses.map { ($0, now) })
        }
    }
}

// MARK: - C callbacks

private func deviceMatched(context: UnsafeMutableRawPointer?, result: IOReturn,
                           sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    RawButtonMonitor.shared.attach(device)
}

private func deviceRemoved(context: UnsafeMutableRawPointer?, result: IOReturn,
                           sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    RawButtonMonitor.shared.detach(device)
}

// swiftlint:disable:next function_parameter_count
private func reportReceived(context: UnsafeMutableRawPointer?, result: IOReturn,
                            sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                            reportID: UInt32, report: UnsafeMutablePointer<UInt8>, reportLength: CFIndex) {
    guard let context else { return }
    RawButtonMonitor.shared.handleReportFromCallback(context: context, reportID: reportID,
                                                     report: report, length: reportLength)
}

extension RawButtonMonitor {
    fileprivate func handleReportFromCallback(context: UnsafeMutableRawPointer, reportID: UInt32,
                                              report: UnsafeMutablePointer<UInt8>, length: Int) {
        let box = Unmanaged<DeviceBox>.fromOpaque(context).takeUnretainedValue()
        self.handleReport(box: box, reportID: reportID, report: report, length: length)
    }
}
