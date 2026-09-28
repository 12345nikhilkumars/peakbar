//
//  App.swift
//  Peakbar
//
//  The status item, the `StatusModel` scheduler, the menu and every piece of
//  display formatting.  See ARCHITECTURE.md §4.5, §4.6 and §5.
//
//  Build note: the test harness compiles this file too, with `-D PEAKCHECK`,
//  which suppresses the `@main` entry point so `StatusModel` can be driven from
//  `Tests/TestMain.swift` without a second entry point.  Everything else in
//  the file is unchanged between the two builds.
//
//  Memory note.  This file deliberately imports **AppKit only**: no SwiftUI,
//  no Combine.  Measured on macOS 27 / arm64, physical footprint at idle:
//
//      AppKit + NSStatusItem, no clickable UI .......... 11.5 MB
//      + an NSMenu ..................................... 12.3 MB
//      + notifications + launch-at-login ............... 12.3 MB  (free)
//      + an initialised URLSession ..................... 13.7 MB
//      SwiftUI MenuBarExtra instead of NSStatusItem .... 16.7 MB
//
//  `MenuBarExtra` keeps a SwiftUI scene alive for the process's whole life and
//  drags in Metal and simd.  Dropping SwiftUI entirely is worth ~2.2 MB, and
//  deferring the network session is worth a further ~1.4 MB.
//

import Foundation
import AppKit
import ServiceManagement

// MARK: - Paths

enum AppPaths {
    static let bundleIdentifierFallback = "dev.nick.peakbar"

    /// `~/Library/Application Support/<CFBundleIdentifier>/` (§5.1, §8).
    static func applicationSupportDirectory(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleIdentifier ?? bundleIdentifierFallback)
    }
}

// MARK: - Formatting

/// Every string the app shows, in one place, so the menu bar, the menu and the
/// notifications cannot drift apart (§4.5, §4.6).
///
/// All clock times are 12-hour with an AM/PM suffix.
enum Format {

    /// Beijing is a fixed UTC+8 offset with no DST (§3.1, A4).
    static let beijingOffsetSeconds = 8 * 3600

    /// `2h45m` / `1h05m` / `45m`.  Minute resolution, never seconds.
    static func remaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h" + String(format: "%02dm", minutes) }
        return "\(minutes)m"
    }

    /// `6:00 PM` / `12:00 AM` at an arbitrary fixed offset.  12-hour clock.
    static func clockString(_ date: Date, offsetSeconds: Int) -> String {
        let secondsIntoDay = floorMod(Int(date.timeIntervalSince1970.rounded(.down)) + offsetSeconds, 86_400)
        let hour24 = secondsIntoDay / 3600
        let minute = (secondsIntoDay % 3600) / 60
        let suffix = hour24 < 12 ? "AM" : "PM"
        var hour12 = hour24 % 12
        if hour12 == 0 { hour12 = 12 }
        return String(format: "%d:%02d %@", hour12, minute, suffix)
    }

    /// `Mon 6:00 PM` at an arbitrary fixed offset.
    static func dayAndTime(_ date: Date, offsetSeconds: Int) -> String {
        let day = Day.from(date: date, offsetHours: offsetSeconds / 3600)
        return "\(day.shortWeekdayName) \(clockString(date, offsetSeconds: offsetSeconds))"
    }

    /// The menu bar title.  One `⚠` glyph for either warning cause (§4.5).
    static func menuBarTitle(phase: Phase, remaining: TimeInterval, warning: Bool) -> String {
        (warning ? "⚠ " : "") + phase.display + " " + Format.remaining(remaining)
    }

    /// Title for a flip notification (§4.6).
    static func notificationTitle(to phase: Phase) -> String {
        phase == .peak ? "Peak started" : "Off-peak started"
    }

    /// Body for a flip notification (§4.6).
    static func notificationBody(to phase: Phase, boundary: Date, now: Date) -> String {
        let price = (phase == .peak) ? "Full price" : "Half price"
        let boundaryDay = Day.from(date: boundary, offsetHours: 8)
        let nowDay = Day.from(date: now, offsetHours: 8)

        var body = "\(price) until "
        if boundaryDay != nowDay { body += "\(boundaryDay.shortWeekdayName) " }
        body += clockString(boundary, offsetSeconds: beijingOffsetSeconds)

        let localOffset = TimeZone.current.secondsFromGMT(for: boundary)
        if localOffset != beijingOffsetSeconds {
            body += " (local \(clockString(boundary, offsetSeconds: localOffset)))"
        }
        return body
    }
}

// MARK: - StatusModel

/// The scheduler of §5.  Holds no cached state that can go stale: every wake
/// recomputes from the injected clock, which is why a wake after three days of
/// sleep costs one `resolve` plus one `nextChange` and needs no catch-up.
///
/// Not `ObservableObject`: the UI is a plain `NSMenu` rebuilt on each open, so
/// there is nothing to observe and no reason to link Combine.
final class StatusModel {

    /// A flip older than this is not announced: the Mac was asleep across the
    /// boundary and the menu bar already shows the current state (§4.6, §6
    /// case 18).
    static let suppressionWindow: TimeInterval = 5 * 60

    private(set) var statusText: String
    private(set) var resolution: Resolution
    private(set) var nextChange: Date
    var notifyOnFlip: Bool

    /// Called after every recompute that changes what the menu bar shows.
    /// The status item is plain AppKit and has no observation of its own, so
    /// the title is pushed rather than bound.
    var onStatusTextChange: ((String) -> Void)?

    let schedule: Schedule
    private var resolver: Resolver

    private let clock: Clock
    private let ticker: Ticker
    private let lifecycle: Lifecycle
    private let notifier: Notifier
    private let holidaySource: HolidaySource

    /// A single serial queue for holiday work.  `HolidaySource` owns mutable
    /// state (the current table, the last-attempt instant, the conditional
    /// validators) and is documented as single-queue; routing every fetch
    /// through one serial queue is what makes that true.
    private static let holidayQueue = DispatchQueue(label: "dev.nick.peakbar.holiday", qos: .utility)

    private let runBackground: (@escaping () -> Void) -> Void
    private let runMain: (@escaping () -> Void) -> Void

    private var lastPhase: Phase?
    private var lastBoundary: Date?

    init(schedule: Schedule,
         holidays: HolidayTable,
         clock: Clock,
         ticker: Ticker,
         lifecycle: Lifecycle,
         notifier: Notifier,
         holidaySource: HolidaySource,
         notifyOnFlip: Bool = true,
         runBackground: @escaping ((@escaping () -> Void) -> Void) = { StatusModel.holidayQueue.async(execute: $0) },
         runMain: @escaping ((@escaping () -> Void) -> Void) = { DispatchQueue.main.async(execute: $0) }) {
        self.schedule = schedule
        self.resolver = Resolver(schedule: schedule, holidays: holidays)
        self.clock = clock
        self.ticker = ticker
        self.lifecycle = lifecycle
        self.notifier = notifier
        self.holidaySource = holidaySource
        self.notifyOnFlip = notifyOnFlip
        self.runBackground = runBackground
        self.runMain = runMain

        let now = clock.now()
        let boundary = self.resolver.nextChange(at: now).date
        let resolution = self.resolver.resolve(at: now, nextChangeTarget: boundary)
        self.resolution = resolution
        self.nextChange = boundary
        self.statusText = Format.menuBarTitle(
            phase: resolution.phase,
            remaining: boundary.timeIntervalSince(now),
            warning: resolution.hasWarning
        )
    }

    /// Wires the lifecycle seam and requests notification authorization once.
    func start() {
        notifier.requestAuthorization()
        lifecycle.onEvent { [weak self] event in self?.handle(event) }
        refresh()
    }

    /// The launch / day-change holiday fetch (§5.1).  Runs off the main queue
    /// in the app; inline in the harness.
    func refreshHolidaysIfDue(isLaunch: Bool) {
        // Nothing to do (and no reason to initialise a network session)
        // when a fetch cannot change an answer.
        guard holidaySource.needsFetch(isLaunch: isLaunch, now: clock.now()) else { return }

        runBackground { [weak self] in
            guard let self = self else { return }
            _ = self.holidaySource.refreshIfDue(isLaunch: isLaunch)
            let table = self.holidaySource.currentTable
            self.runMain { [weak self] in
                guard let self = self else { return }
                self.applyHolidayTable(table)
                self.refresh()
            }
        }
    }

    private func handle(_ event: LifecycleEvent) {
        switch event {
        case .wake, .clockChanged, .timezoneChanged:
            refresh()
        case .dayChanged:
            // The fetch rides the existing day-change event; no timer is
            // added (§5, §6 case 28).
            refreshHolidaysIfDue(isLaunch: false)
            refresh()
        }
    }

    private func applyHolidayTable(_ table: HolidayTable) {
        resolver.holidays = table
    }

    /// The single recompute path: timer fire, wake, clock change, timezone
    /// change and day change all land here (§5, §10).
    func onTick() { refresh() }

    func refresh() {
        let now = clock.now()
        let boundary = resolver.nextChange(at: now).date
        let resolution = resolver.resolve(at: now, nextChangeTarget: boundary)

        let previousPhase = lastPhase
        let crossedBoundary = lastBoundary

        self.resolution = resolution
        self.nextChange = boundary
        let title = Format.menuBarTitle(
            phase: resolution.phase,
            remaining: boundary.timeIntervalSince(now),
            warning: resolution.hasWarning
        )
        if title != self.statusText {
            self.statusText = title
            onStatusTextChange?(title)
        }

        if let previousPhase = previousPhase, previousPhase != resolution.phase, notifyOnFlip {
            let flipInstant = crossedBoundary ?? now
            if now.timeIntervalSince(flipInstant) <= StatusModel.suppressionWindow {
                onPhaseFlip(from: previousPhase, to: resolution.phase, at: now)
            }
        }

        // Wake at the earlier of the next minute (the countdown text changes)
        // and the exact next phase boundary (§5).
        let wake = min(StatusModel.nextMinuteBoundary(now), boundary)
        ticker.schedule(at: wake) { [weak self] in self?.onTick() }

        lastPhase = resolution.phase
        lastBoundary = boundary
    }

    /// Posts the flip notification.  `nextChange` already holds the boundary
    /// the new phase runs until.
    func onPhaseFlip(from: Phase, to: Phase, at: Date) {
        notifier.post(title: Format.notificationTitle(to: to),
                      body: Format.notificationBody(to: to, boundary: nextChange, now: at))
    }

    /// `now` truncated to the minute, plus 60 s.
    static func nextMinuteBoundary(_ now: Date) -> Date {
        let truncated = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
        return Date(timeIntervalSince1970: truncated + 60)
    }

    /// Seconds remaining until the next change, clamped at zero.
    var remaining: TimeInterval { max(0, nextChange.timeIntervalSince(clock.now())) }

    var localOffsetSeconds: Int { TimeZone.current.secondsFromGMT(for: clock.now()) }
}

// MARK: - Launch at login

enum LaunchAtLogin {
    static let defaultsKey = "launchAtLogin"

    /// Best effort: registering fails when the bundle is not in an
    /// applications folder or the user has not approved it, and a menu bar
    /// utility must not die over that.
    static func apply(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            FileHandle.standardError.write(Data("Peakbar: launch-at-login \(enabled ? "register" : "unregister") failed: \(error)\n".utf8))
        }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }
}

// MARK: - Status item controller

/// Owns the menu bar item and the menu.
///
/// The menu is an `NSMenu` rather than a SwiftUI popover: it is the lightest
/// thing that can present this information, it needs no view hosting, and it
/// removes SwiftUI and Combine from the binary entirely.
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let model: StatusModel
    private let menu = NSMenu()

    init(model: StatusModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        statusItem.menu = menu

        applyTitle()

        model.onStatusTextChange = { [weak self] _ in self?.applyTitle() }
    }

    /// Red while peak is in force, green while off-peak.
    ///
    /// Red here means "expensive", not "up", so it reads the same way as the
    /// app's own status colour rather than as a market ticker.
    ///
    /// A pure function so both branches are testable: the app's self-test can
    /// only exercise whichever phase is current when it runs.
    static func menuBarColor(for phase: Phase) -> NSColor {
        phase == .peak ? .systemRed : .systemGreen
    }

    /// Uses `attributedTitle`, not `contentTintColor`: a status item's *image*
    /// is template-rendered and would be recoloured by the system, but text
    /// drawn through `attributedTitle` keeps the colour it is given. The font
    /// is monospaced-digit so the countdown does not jitter as its width
    /// changes each minute.
    private func applyTitle() {
        guard let button = statusItem.button else { return }
        button.attributedTitle = NSAttributedString(
            string: model.statusText,
            attributes: [
                .foregroundColor: StatusItemController.menuBarColor(for: model.resolution.phase),
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ]
        )
    }

    /// Rebuilt on every open, so the times and toggle states are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let resolution = model.resolution

        header("\(resolution.phase.display): \(Format.remaining(model.remaining))")

        menu.addItem(.separator())

        disabled("Next change (Beijing)", Format.dayAndTime(model.nextChange, offsetSeconds: Format.beijingOffsetSeconds))
        disabled("Next change (local)", Format.dayAndTime(model.nextChange, offsetSeconds: model.localOffsetSeconds))

        if resolution.stale || resolution.sourceWarning {
            menu.addItem(.separator())
            if resolution.stale {
                disabled(nil, "Holidays for this year are not yet published. Assuming peak.")
            }
            if resolution.sourceWarning {
                disabled(nil, "Holiday data could not be read. Using the bundled table.")
            }
        }

        menu.addItem(.separator())

        let notify = NSMenuItem(title: "Notify on rate change",
                                action: #selector(toggleNotify),
                                keyEquivalent: "")
        notify.target = self
        notify.state = model.notifyOnFlip ? .on : .off
        menu.addItem(notify)

        let login = NSMenuItem(title: "Launch at login",
                               action: #selector(toggleLaunchAtLogin),
                               keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Peakbar",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func header(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func disabled(_ label: String?, _ value: String) {
        let title = label.map { "\($0): \(value)" } ?? value
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func toggleNotify() {
        model.notifyOnFlip.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        let enabled = !LaunchAtLogin.isEnabled
        UserDefaults.standard.set(enabled, forKey: LaunchAtLogin.defaultsKey)
        LaunchAtLogin.apply(enabled)
    }

    /// Builds the menu without a click, for verification.  Returns the item
    /// titles so a caller can assert on them.
    func selfTestBuildMenu() -> [String] {
        menuNeedsUpdate(menu)
        return menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    /// The menu bar button, for geometry reporting.
    var statusButton: NSStatusBarButton? { statusItem.button }

    /// The colour the title is currently drawn in, and the phase it was chosen
    /// for, so the colour rule can be asserted without a screenshot.
    func selfTestTitleAppearance() -> (color: NSColor?, phase: Phase, text: String) {
        let title = statusItem.button?.attributedTitle
        let color = title?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        return (color, model.resolution.phase, title?.string ?? "")
    }
}

// MARK: - Model construction

/// One place that wires the schedule, the holiday source and the scheduler, so
/// the app and the self-test cannot drift apart.
@discardableResult
func makeStatusModel() -> (model: StatusModel, holidaySource: HolidaySource) {
    let schedule = Schedule.loadBundled()
    let bundled = HolidayTable.loadBundled()
    let cacheDirectory = AppPaths.applicationSupportDirectory()

    let holidaySource = HolidaySource(
        transport: URLSessionTransport(),
        clock: SystemClock(),
        cacheDirectory: cacheDirectory,
        bundled: bundled
    )

    let model = StatusModel(
        schedule: schedule,
        holidays: holidaySource.currentTable,
        clock: SystemClock(),
        ticker: DispatchTicker(),
        lifecycle: SystemLifecycle(),
        notifier: UserNotifier(),
        holidaySource: holidaySource,
        notifyOnFlip: true
    )
    return (model, holidaySource)
}

// MARK: - Entry point

#if !PEAKCHECK

@main
enum PeakbarMain {
    /// `NSApplication.delegate` is not retained by the application, so the
    /// delegate is held here for the process's lifetime.
    private static var delegate: AppDelegate?

    static func main() {
        if CommandLine.arguments.contains("--self-test-menu") {
            runMenuSelfTest()
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        PeakbarMain.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Builds the menu once, prints its items, and exits non-zero if it is
    /// missing the rows that must always be there.
    ///
    /// Deliberately synchronous: no run loop, no timers.  The menu contents
    /// are what needs verifying, and they can be built directly; a run-loop
    /// version reports success or hangs for reasons unrelated to the menu.
    ///
    /// A menu bar item is composited by `MenuBarAgent`, so it never appears in
    /// `CGWindowList`, and synthetic clicks need Accessibility permission.
    /// Without this, the menu is unverifiable.
    private static func runMenuSelfTest() -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let (model, _) = makeStatusModel()
        let controller = StatusItemController(model: model)
        let titles = controller.selfTestBuildMenu()

        let required = ["Quit Peakbar", "Launch at login", "Notify on rate change"]
        var problems = required.filter { !titles.contains($0) }

        // The colour rule: red in peak, green in off-peak.  Asserted here
        // because the menu bar cannot be screenshotted (§7.4).
        let appearance = controller.selfTestTitleAppearance()
        let expectedColour: NSColor = (appearance.phase == .peak) ? .systemRed : .systemGreen
        let colourOK = appearance.color == expectedColour
        if !colourOK { problems.append("title colour for \(appearance.phase)") }

        var report = "menu_items=\(titles.count)\n"
        for t in titles { report += "  \(t)\n" }
        report += "title=\"\(appearance.text)\" phase=\(appearance.phase) "
        report += "colour=\(appearance.color.map { $0 == .systemRed ? "red" : ($0 == .systemGreen ? "green" : "other") } ?? "none")"
        report += " expected=\(appearance.phase == .peak ? "red" : "green")\n"
        report += problems.isEmpty
            ? "MENU_SELFTEST_OK"
            : "MENU_SELFTEST_FAILED: \(problems)"
        let out = report + "\n"
        FileHandle.standardError.write(Data(out.utf8))
        try? out.write(toFile: "/tmp/peakbar-selftest.log", atomically: true, encoding: .utf8)
        exit(problems.isEmpty ? 0 : 1)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: StatusItemController?
    private var model: StatusModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (model, _) = makeStatusModel()
        self.model = model
        self.controller = StatusItemController(model: model)

        model.start()
        model.refreshHolidaysIfDue(isLaunch: true)

        if LaunchAtLogin.isEnabled { LaunchAtLogin.apply(true) }
    }
}

#endif
