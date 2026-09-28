//
//  TestMain.swift
//  Peakbar
//
//  Harness entry point.  A plain executable, not XCTest and not swift-testing:
//  `swift test` is unusable on this machine because the swift-testing macro
//  plugin fails to load without Xcode.
//
//  Runs every suite, prints pass/fail, and exits non-zero on any failure.
//

import Foundation
import Darwin

// MARK: - Locations

/// `<repo>/Tests/TestMain.swift` → `<repo>`
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tests/
    .deletingLastPathComponent()   // repo root

let resourcesDir = repoRoot.appendingPathComponent("Resources")

// MARK: - Assertions

var gTotal = 0
var gFailed = 0
var gFailures: [String] = []

func section(_ title: String) {
    print("\n── \(title) " + String(repeating: "─", count: max(0, 58 - title.count)))
}

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    gTotal += 1
    if ok {
        print("  ok    \(name)")
    } else {
        gFailed += 1
        let d = detail()
        gFailures.append(d.isEmpty ? name : "\(name): \(d)")
        print("  FAIL  \(name)\(d.isEmpty ? "" : "  [\(d)]")")
    }
}

func note(_ text: String) {
    print("  ·     \(text)")
}

// MARK: - Fixtures

func loadShippedSchedule() -> Schedule {
    Schedule.load(from: resourcesDir.appendingPathComponent("schedule.json"))
}

/// The shipped schedule with the effective gate moved far into the past, so
/// the weekend and holiday rules apply to every 2026 date.  Used to exercise
/// the holiday rule independently of the (deliberately not retroactive) gate.
func loadEarlyEffectiveSchedule() -> Schedule {
    var s = loadShippedSchedule()
    s = Schedule(calendarTimezone: s.calendarTimezone,
                 calendarUTCOffsetHours: s.calendarUTCOffsetHours,
                 peakWindowsUTC: s.peakWindowsUTC,
                 peakWeekdays: s.peakWeekdays,
                 weekendOffpeakEffectiveUTC: utcDate(2000, 1, 1, 0, 0),
                 offpeakMultiplier: s.offpeakMultiplier)
    return s
}

func loadBundledHolidays() -> HolidayTable {
    HolidayTable.load(from: resourcesDir.appendingPathComponent("holidays-2026.json"))
}

func loadICSFixture() -> String {
    (try? String(contentsOf: resourcesDir.appendingPathComponent("cn_zh.ics"), encoding: .utf8)) ?? ""
}

func loadVectorsRoot() -> [String: Any]? {
    guard let data = try? Data(contentsOf: resourcesDir.appendingPathComponent("vectors.json")),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return root
}

// MARK: - Time helpers

var utcCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// An instant given as a UTC wall clock.
func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    var comps = DateComponents()
    comps.year = y; comps.month = mo; comps.day = d
    comps.hour = h; comps.minute = mi; comps.second = s
    return utcCalendar.date(from: comps)!
}

/// An instant given as a Beijing (UTC+8) wall clock.
func beijingDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    utcDate(y, mo, d, h, mi, s).addingTimeInterval(-8 * 3600)
}

func parseISO(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func day(_ y: Int, _ mo: Int, _ d: Int) -> Day { Day(y, mo, d) }

// MARK: - Misc helpers

func makeTempDirectory(_ label: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("peakbar-tests-\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func removeTempDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// A well-formed two-event ICS with a range and a single-day event.
func sampleICS() -> String {
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    DTSTART;VALUE=DATE:20261224
    DTEND;VALUE=DATE:20261227
    X-APPLE-SPECIAL-DAY:WORK-HOLIDAY
    END:VEVENT
    BEGIN:VEVENT
    DTSTART;VALUE=DATE:20261228
    X-APPLE-SPECIAL-DAY:ALTERNATE-WORKDAY
    END:VEVENT
    END:VCALENDAR
    """
}

/// A deliberately truncated payload: no END:VEVENT, no END:VCALENDAR.
func truncatedICS() -> String {
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    DTSTART;VALUE=DATE:20260101
    """
}

// MARK: - Entry point

/// The harness entry point.  `@main` rather than top-level code so the file
/// can keep the name the design gives it; the test target is compiled with
/// `-parse-as-library` for the same reason the app is.
@main
struct PeakbarTestHarness {
    static func main() {
        print("Peakbar: test harness")
        print("repo root : \(repoRoot.path)")
        print("resources : \(resourcesDir.path)")

        runConformanceTests()
        runEdgeCaseTests()
        runHolidaySourceTests()

        print("\n" + String(repeating: "=", count: 64))
        print("TOTAL \(gTotal)   PASS \(gTotal - gFailed)   FAIL \(gFailed)")
        if !gFailures.isEmpty {
            print("\nFailures:")
            for failure in gFailures { print("  - \(failure)") }
        }
        print(String(repeating: "=", count: 64))

        exit(gFailed == 0 ? 0 : 1)
    }
}
