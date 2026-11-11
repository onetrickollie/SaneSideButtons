//
//  SwipeSimulator.swift
//  SaneSideButtons
//
//  Created by Jan Hülsmann on 16.10.22.
//

import AppKit
import Synchronization

final class SwipeSimulator: Sendable {

    enum EventTap: Error {
        case failedSetup
    }

    private enum Keys {
        static let ignored: String = "ignoredApplications"
        static let reverse: String = "reverseButtons"
    }

    private let swipeBegin: [String: Int] = [
        kTLInfoKeyGestureSubtype as String: kTLInfoSubtypeSwipe,
        kTLInfoKeyGesturePhase as String: 1
    ]

    private let swipeLeft: [String: Int] = [
        kTLInfoKeyGestureSubtype as String: kTLInfoSubtypeSwipe,
        kTLInfoKeySwipeDirection as String: kTLInfoSwipeLeft,
        kTLInfoKeyGesturePhase as String: 4
    ]

    private let swipeRight: [String: Int] = [
        kTLInfoKeyGestureSubtype as String: kTLInfoSubtypeSwipe,
        kTLInfoKeySwipeDirection as String: kTLInfoSwipeRight,
        kTLInfoKeyGesturePhase as String: 4
    ]

    static let shared = SwipeSimulator()

    // MARK: - Internal State

    /// Whether the CGEvent tap is currently active.
    private let eventTapIsRunning: Mutex<Bool> = Mutex(false)

    /// A set of bundle identifiers that are ignored.
    private let ignoredApplications: Mutex<Set<String>> = Mutex(
        Set(UserDefaults.standard.stringArray(forKey: Keys.ignored) ?? [])
    )

    /// Whether the swipe direction is reversed (e.g. right <-> left).
    private let reverseButtons: Mutex<Bool> = Mutex(UserDefaults.standard.bool(forKey: Keys.reverse))

    /// Middle-button releases still to swallow after a side button was turned into a swipe.
    private let swallowedMiddleUps: Mutex<Int> = Mutex(0)

    private init() { }

    // MARK: - Public

    func areButtonsReversed() -> Bool {
        self.reverseButtons.withLock { $0 }
    }

    func toggleReverseButtons() {
        self.reverseButtons.withLock { reversed in
            reversed.toggle()
            UserDefaults.standard.set(reversed, forKey: Keys.reverse)
        }
    }

    func isEventTapRunning() -> Bool {
        self.eventTapIsRunning.withLock { $0 }
    }

    func addIgnoredApplication(bundleID: String) {
        self.ignoredApplications.withLock { applications in
            applications.insert(bundleID)
            UserDefaults.standard.set(Array(applications), forKey: Keys.ignored)
        }
    }

    func removeIgnoredApplication(bundleID: String) {
        self.ignoredApplications.withLock { applications in
            applications.remove(bundleID)
            UserDefaults.standard.set(Array(applications), forKey: Keys.ignored)
        }
    }

    func ignoredApplicationsContain(_ bundleID: String) -> Bool {
        self.ignoredApplications.withLock { $0.contains(bundleID) }
    }

    func setupEventTap() throws {
        try self.eventTapIsRunning.withLock { isRunning in
            guard !isRunning else { return }
            let eventMask = CGEventMask(
                1 << CGEventType.otherMouseDown.rawValue | 1 << CGEventType.otherMouseUp.rawValue
            )

            guard let eventTap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: mouseEventCallBack,
                userInfo: nil)
            else {
                isRunning = false
                throw EventTap.failedSetup
            }

            let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            isRunning = true
        }
    }

    func recreateEventTap() {
        self.eventTapIsRunning.withLock { $0 = false }
        try? self.setupEventTap()
    }

    func markEventTapAsInactive() {
        self.eventTapIsRunning.withLock { $0 = false }
    }

    private func fakeSwipe(direction: TLInfoSwipeDirection) {
        let eventBegin: CGEvent = tl_CGEventCreateFromGesture(self.swipeBegin as CFDictionary,
                                                              [] as CFArray).takeRetainedValue()

        let swipeDirection = self.reverseButtons.withLock { $0 ? direction.reversed : direction }
        let eventSwipe: CGEvent? = switch swipeDirection {
        case TLInfoSwipeDirection(kTLInfoSwipeLeft):
            tl_CGEventCreateFromGesture(self.swipeLeft as CFDictionary, [] as CFArray).takeRetainedValue()
        case TLInfoSwipeDirection(kTLInfoSwipeRight):
            tl_CGEventCreateFromGesture(self.swipeRight as CFDictionary, [] as CFArray).takeRetainedValue()
        default:
            nil
        }

        guard let eventSwipe else { return }
        eventBegin.post(tap: .cghidEventTap)
        eventSwipe.post(tap: .cghidEventTap)
    }

    fileprivate func handleMouseEvent(type: CGEventType, cgEvent: CGEvent) -> CGEvent? {
        let number = CGEvent.getIntegerValueField(cgEvent)(.mouseEventButtonNumber)

        // Mice whose side buttons arrive as a middle click (see RawButtonMonitor).
        if number == 2, let handled = self.handleMiddleButtonFromQuirkyMouse(type: type) {
            return handled ? nil : cgEvent
        }

        guard type == .otherMouseDown && self.isValidApplication() else {
            return cgEvent
        }

        if number == 3 {
            self.fakeSwipe(direction: TLInfoSwipeDirection(kTLInfoSwipeLeft))
            return nil
        } else if number == 4 {
            self.fakeSwipe(direction: TLInfoSwipeDirection(kTLInfoSwipeRight))
            return nil
        }
        return cgEvent
    }

    /// Returns nil when no quirky mouse is connected (normal handling),
    /// true when the event was a side button and should be swallowed,
    /// false when it was a real middle click and should pass through.
    private func handleMiddleButtonFromQuirkyMouse(type: CGEventType) -> Bool? {
        let monitor = RawButtonMonitor.shared
        guard monitor.hasQuirkyDevice else { return nil }

        if type == .otherMouseUp {
            // Swallow the release that belongs to a swallowed press.
            return self.swallowedMiddleUps.withLock { count in
                guard count > 0 else { return false }
                count -= 1
                return true
            }
        }
        guard type == .otherMouseDown else { return false }

        // The raw report and the CGEvent come from the same USB report, but
        // either can arrive first, so wait briefly for the raw side.
        guard let side = monitor.consumeSidePress(waitingUpTo: 0.02) else { return false }
        guard self.isValidApplication() else { return false }
        self.swallowedMiddleUps.withLock { $0 += 1 }
        self.fakeSwipe(direction: TLInfoSwipeDirection(side == .back ? kTLInfoSwipeLeft : kTLInfoSwipeRight))
        return true
    }

    private func isValidApplication() -> Bool {
        guard let frontAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return true }
        return self.ignoredApplications.withLock { !$0.contains(frontAppBundleID) }
    }
}

// swiftlint:disable private_over_fileprivate
fileprivate func mouseEventCallBack(proxy: CGEventTapProxy,
                                    type: CGEventType,
                                    cgEvent: CGEvent,
                                    userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let cgEvent = SwipeSimulator.shared.handleMouseEvent(type: type, cgEvent: cgEvent) else { return nil }
    return Unmanaged.passRetained(cgEvent)
}

fileprivate extension TLInfoSwipeDirection {
    var reversed: TLInfoSwipeDirection {
        switch self {
        case TLInfoSwipeDirection(kTLInfoSwipeLeft):
            return TLInfoSwipeDirection(kTLInfoSwipeRight)
        case TLInfoSwipeDirection(kTLInfoSwipeRight):
            return TLInfoSwipeDirection(kTLInfoSwipeLeft)
        default:
            return self
        }
    }
}
// swiftlint:enable private_over_fileprivate
