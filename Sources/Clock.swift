//
//  Clock.swift
//  Peakbar
//
//  The injectable time, wake and ticker seam, plus the system and manual
//  implementations.
//
//  The seam exists so the scheduler can be driven deterministically from the
//  test harness.  `Resolver` needs none of it; it is pure over an instant.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Lifecycle event

enum LifecycleEvent: Equatable {
    case wake
    case clockChanged
    case timezoneChanged
    case dayChanged
}

// MARK: - Protocols

/// Wall-clock source.  Injected so tests can set the instant.
protocol Clock {
    func now() -> Date
}

/// A one-shot timer.  `schedule(at:fire:)` replaces any pending timer; there
/// is never more than one.
protocol Ticker {
    func schedule(at date: Date, _ fire: @escaping () -> Void)
    func cancel()
}

/// System events that must force a recompute.
protocol Lifecycle {
    func onEvent(_ handler: @escaping (LifecycleEvent) -> Void)
}

// MARK: - System implementations

final class SystemClock: Clock {
    func now() -> Date { Date() }
}

/// A single one-shot `DispatchSourceTimer` on the main queue.  Rescheduled on
/// every fire; cancelled and replaced on every lifecycle event.
final class DispatchTicker: Ticker {
    private var timer: DispatchSourceTimer?
    private let queue: DispatchQueue

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    func schedule(at date: Date, _ fire: @escaping () -> Void) {
        cancel()
        let delay = max(0, date.timeIntervalSinceNow)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in
            // Drop our reference first so a re-entrant `schedule` from inside
            // `fire` cannot cancel the source we are currently running on.
            self?.timer = nil
            fire()
        }
        source.resume()
        timer = source
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }
}

/// Bridges the four system notifications to `LifecycleEvent`s.
final class SystemLifecycle: Lifecycle {
    private var observers: [NSObjectProtocol] = []

    func onEvent(_ handler: @escaping (LifecycleEvent) -> Void) {
        let center = NotificationCenter.default
        let main = OperationQueue.main

        func observe(_ name: Notification.Name, _ event: LifecycleEvent) {
            let token = center.addObserver(forName: name, object: nil, queue: main) { _ in
                handler(event)
            }
            observers.append(token)
        }

        #if canImport(AppKit)
        observe(NSWorkspace.didWakeNotification, .wake)
        #endif
        observe(Notification.Name.NSSystemClockDidChange, .clockChanged)
        observe(Notification.Name.NSSystemTimeZoneDidChange, .timezoneChanged)
        observe(Notification.Name.NSCalendarDayChanged, .dayChanged)
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }
}

// MARK: - Manual implementations (test doubles)

/// A clock whose instant the test sets.
final class ManualClock: Clock {
    var current: Date

    init(_ start: Date) { self.current = start }

    func now() -> Date { current }

    func set(_ date: Date) { current = date }

    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

/// Records the instant it was asked to fire at, and fires on demand.
final class ManualTicker: Ticker {
    private(set) var scheduledDate: Date?
    private(set) var scheduleCount: Int = 0
    private(set) var cancelCount: Int = 0
    private var handler: (() -> Void)?

    func schedule(at date: Date, _ fire: @escaping () -> Void) {
        scheduledDate = date
        handler = fire
        scheduleCount += 1
    }

    func cancel() {
        cancelCount += 1
        handler = nil
        scheduledDate = nil
    }

    /// Invokes the pending handler exactly once, as a real one-shot timer
    /// would, and clears it.
    func fire() {
        let pending = handler
        handler = nil
        pending?()
    }

    var hasPendingFire: Bool { handler != nil }
}

/// Emits lifecycle events on demand.
final class ManualLifecycle: Lifecycle {
    private var handlers: [(LifecycleEvent) -> Void] = []

    func onEvent(_ handler: @escaping (LifecycleEvent) -> Void) {
        handlers.append(handler)
    }

    func emit(_ event: LifecycleEvent) {
        for handler in handlers { handler(event) }
    }

    var hasHandler: Bool { !handlers.isEmpty }
}
