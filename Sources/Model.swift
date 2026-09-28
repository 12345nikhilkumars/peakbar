//
//  Model.swift
//  Peakbar
//
//  Value types for the billing schedule and the holiday table, plus the
//  loaders for the bundled data files.  See ARCHITECTURE.md §3 and §4.1.
//
//  Nothing in this file performs I/O beyond reading a bundled JSON file that
//  the caller names explicitly.  `Schedule` and `HolidayTable` are plain
//  values: `Resolver` consumes them, `HolidaySource` produces them.
//

import Foundation

// MARK: - Integer helpers

/// Floor division for positive divisors.  Swift's `/` truncates toward zero,
/// which is wrong for the negative epoch instants that precede 1970.
@inline(__always)
func floorDiv(_ a: Int, _ b: Int) -> Int {
    precondition(b > 0, "floorDiv requires a positive divisor")
    let q = a / b
    return (a % b != 0 && (a < 0)) ? q - 1 : q
}

/// Floor modulo for positive divisors.  Result is always in `0..<b`.
@inline(__always)
func floorMod(_ a: Int, _ b: Int) -> Int {
    precondition(b > 0, "floorMod requires a positive divisor")
    let r = a % b
    return r < 0 ? r + b : r
}

// MARK: - Phase

/// The two billing phases DeepSeek publishes.  Raw values double as the
/// on-disk representation used by the conformance vectors.
enum Phase: String, Equatable, Hashable {
    case peak
    case offpeak

    /// Upper-case label used in the menu bar title and the popover.
    var display: String {
        switch self {
        case .peak: return "PEAK"
        case .offpeak: return "OFF-PEAK"
        }
    }
}

// MARK: - Basis

/// Why a resolution came out the way it did.  Purely diagnostic: it never
/// changes the phase, only the explanation attached to it.
enum Basis: String, Equatable, Hashable {
    /// The UTC minute-of-day window test decided it.
    case window
    /// The weekend rule decided it (Beijing weekday not in `peakWeekdays`).
    case weekend
    /// A Beijing public holiday suppressed an otherwise-peak weekday.
    case holiday
    /// The holiday table could not vouch for this year, so peak was assumed.
    case assumedPeak
}

// MARK: - Window

/// A half-open `[start, end)` minute range measured on the UTC minute-of-day.
struct Window: Equatable, Hashable {
    let startMinute: Int
    let endMinute: Int

    init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// Parses `"HH:MM"` into minutes past midnight.  Returns nil when the
    /// string is not a well-formed 24-hour time.
    static func minutes(fromHHMM hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// Builds a window from the `[start, end]` pair the schedule file uses.
    static func parsePair(_ pair: [String]) -> Window? {
        guard pair.count == 2,
              let start = Window.minutes(fromHHMM: pair[0]),
              let end = Window.minutes(fromHHMM: pair[1]) else { return nil }
        return Window(startMinute: start, endMinute: end)
    }

    /// Half-open containment on the minute-of-day.
    func contains(minuteOfDay m: Int) -> Bool {
        startMinute <= m && m < endMinute
    }
}

// MARK: - Day

/// A civil calendar date with no time zone and no time of day.
///
/// Deliberately not a `Date`: the whole point of §4.2 is that the weekday is
/// read off the *Beijing* civil date, never off a UTC instant.
struct Day: Hashable, Comparable, CustomStringConvertible {
    let y: Int
    let m: Int
    let d: Int

    init(_ y: Int, _ m: Int, _ d: Int) {
        self.y = y
        self.m = m
        self.d = d
    }

    var year: Int { y }
    var month: Int { m }
    var day: Int { d }

    var description: String { String(format: "%04d-%02d-%02d", y, m, d) }
    /// The compact `yyyyMMdd` form used by iCalendar `VALUE=DATE` values.
    var icsString: String { String(format: "%04d%02d%02d", y, m, d) }

    static func < (a: Day, b: Day) -> Bool {
        if a.y != b.y { return a.y < b.y }
        if a.m != b.m { return a.m < b.m }
        return a.d < b.d
    }

    // MARK: Parsing

    /// Parses `"yyyy-MM-dd"`.
    static func parseISODate(_ s: String) -> Day? {
        let parts = s.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return Day(y, m, d)
    }

    /// Parses `"yyyyMMdd"` (the iCalendar `VALUE=DATE` form).
    static func parseICSDate(_ s: String) -> Day? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count == 8, let n = Int(t) else { return nil }
        let y = n / 10_000, m = (n / 100) % 100, d = n % 100
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        return Day(y, m, d)
    }

    // MARK: Epoch conversion

    /// Days since 1970-01-01 for this civil date (Howard Hinnant's
    /// `days_from_civil`).  Exact for the whole supported range.
    var epochDay: Int {
        var yy = y
        if m <= 2 { yy -= 1 }
        let era = floorDiv(yy >= 0 ? yy : yy - 399, 400)
        let yoe = yy - era * 400                                   // [0, 399]
        let mp = m > 2 ? m - 3 : m + 9                             // [0, 11]
        let doy = (153 * mp + 2) / 5 + d - 1                       // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy            // [0, 146096]
        return era * 146_097 + doe - 719_468
    }

    /// The civil date `n` days after 1970-01-01 (`civil_from_days`).
    static func fromEpochDay(_ n: Int) -> Day {
        let z = n + 719_468
        let era = floorDiv(z >= 0 ? z : z - 146_096, 146_097)
        let doe = z - era * 146_097                                // [0, 146096]
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)          // [0, 365]
        let mp = (5 * doy + 2) / 153                               // [0, 11]
        let d = doy - (153 * mp + 2) / 5 + 1                       // [1, 31]
        let m = mp < 10 ? mp + 3 : mp - 9                          // [1, 12]
        return Day(m <= 2 ? y + 1 : y, m, d)
    }

    /// The Beijing (or any fixed-offset) civil date containing `date`.
    static func from(date: Date, offsetHours: Int) -> Day {
        let shifted = date.timeIntervalSince1970 + Double(offsetHours * 3600)
        return fromEpochDay(floorDiv(Int(shifted.rounded(.down)), 86_400))
    }

    // MARK: Arithmetic

    var nextDay: Day { Day.fromEpochDay(epochDay + 1) }
    var previousDay: Day { Day.fromEpochDay(epochDay - 1) }

    // MARK: Weekday

    /// ISO-8601 weekday: 1 = Monday … 7 = Sunday.  Zeller's congruence,
    /// so no `Calendar` allocation on the hot predicate path.
    var isoWeekday: Int {
        var yy = y
        var mm = m
        if mm < 3 { mm += 12; yy -= 1 }
        let k = yy % 100
        let j = yy / 100
        // h: 0 = Saturday, 1 = Sunday, … 6 = Friday
        let h = floorMod(d + (13 * (mm + 1)) / 5 + k + k / 4 + j / 4 + 5 * j, 7)
        return floorMod(h + 5, 7) + 1
    }

    private static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    var shortWeekdayName: String { Day.weekdayNames[isoWeekday - 1] }
}

// MARK: - Schedule

/// The billing schedule.  Field names mirror the CC0 suite so the port stays
/// mechanical (ARCHITECTURE.md §3.1).
struct Schedule: Equatable {
    let calendarTimezone: String
    let calendarUTCOffsetHours: Int
    let peakWindowsUTC: [Window]
    let peakWeekdays: Set<Int>
    let weekendOffpeakEffectiveUTC: Date
    let offpeakMultiplier: Double

    /// The bundled schedule, used when the resource cannot be read.  Mirrors
    /// `Resources/schedule.json` exactly so the app degrades to a working
    /// (if unmaintainable) state rather than crashing.
    static let fallback = Schedule(
        calendarTimezone: "Asia/Shanghai",
        calendarUTCOffsetHours: 8,
        peakWindowsUTC: [
            Window(startMinute: 60, endMinute: 240),
            Window(startMinute: 360, endMinute: 600)
        ],
        peakWeekdays: [1, 2, 3, 4, 5],
        weekendOffpeakEffectiveUTC: Date(timeIntervalSince1970: 1_787_414_400), // 2026-08-22T16:00:00Z
        offpeakMultiplier: 0.5
    )

    /// Reads the schedule from the running app bundle.
    static func loadBundled() -> Schedule {
        guard let url = Bundle.main.url(forResource: "schedule", withExtension: "json") else {
            FileHandle.standardError.write(Data("Peakbar: schedule.json missing from bundle; using built-in fallback\n".utf8))
            return .fallback
        }
        return load(from: url)
    }

    /// Reads the schedule from an explicit file.  Returns `.fallback` on any
    /// parse failure rather than trapping.
    static func load(from url: URL) -> Schedule {
        guard let data = try? Data(contentsOf: url) else { return .fallback }
        return parse(data: data) ?? .fallback
    }

    /// Parses the schedule JSON.  Returns nil when required fields are absent
    /// or malformed.
    static func parse(data: Data) -> Schedule? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tz = raw["calendar_timezone"] as? String,
              let offset = raw["calendar_utc_offset_hours"] as? Int,
              let windowsRaw = raw["peak_windows_utc"] as? [[String]],
              let weekdaysRaw = raw["peak_weekdays"] as? [Int],
              let effectiveRaw = raw["weekend_offpeak_effective_utc"] as? String,
              let multiplier = raw["offpeak_multiplier"] as? Double else { return nil }

        var windows: [Window] = []
        for pair in windowsRaw {
            guard let w = Window.parsePair(pair) else { return nil }
            windows.append(w)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let effective = formatter.date(from: effectiveRaw) else { return nil }

        return Schedule(
            calendarTimezone: tz,
            calendarUTCOffsetHours: offset,
            peakWindowsUTC: windows,
            peakWeekdays: Set(weekdaysRaw),
            weekendOffpeakEffectiveUTC: effective,
            offpeakMultiplier: multiplier
        )
    }
}

// MARK: - HolidayTable

/// A holiday table: the union of what every available source vouches for.
/// See ARCHITECTURE.md §3.2 and §3.3.
///
/// `sourceWarning` is a deviation from the class diagram in §4.1: the diagram
/// lists only `daysOff`, `makeupWorkdays`, `coveredYears` and `source`, but
/// `Resolution.sourceWarning` (§4.1, §4.5, §6 case 21) has to reach the
/// resolver, and the only value the resolver ever sees is this table.  Riding
/// the flag on the table keeps `Resolver` a pure function of
/// `(instant, schedule, table)`, which is what §4.2 requires, instead of
/// widening `Resolver`'s interface.  See NOTES in the final report.
struct HolidayTable: Equatable {
    let daysOff: Set<Day>
    let makeupWorkdays: Set<Day>
    let coveredYears: Set<Int>
    let source: String
    let sourceWarning: Bool

    init(daysOff: Set<Day> = [],
         makeupWorkdays: Set<Day> = [],
         coveredYears: Set<Int> = [],
         source: String = "",
         sourceWarning: Bool = false) {
        self.daysOff = daysOff
        self.makeupWorkdays = makeupWorkdays
        self.coveredYears = coveredYears
        self.source = source
        self.sourceWarning = sourceWarning
    }

    /// A copy carrying a different warning flag.
    func withSourceWarning(_ flag: Bool) -> HolidayTable {
        HolidayTable(daysOff: daysOff,
                     makeupWorkdays: makeupWorkdays,
                     coveredYears: coveredYears,
                     source: source,
                     sourceWarning: flag)
    }

    /// Union-on-days, top-down: `self` is the higher-precedence source and
    /// wins on `source` (§3.3).
    func merge(lower: HolidayTable) -> HolidayTable {
        HolidayTable(
            daysOff: daysOff.union(lower.daysOff),
            makeupWorkdays: makeupWorkdays.union(lower.makeupWorkdays),
            coveredYears: coveredYears.union(lower.coveredYears),
            source: source.isEmpty ? lower.source : source,
            sourceWarning: sourceWarning || lower.sourceWarning
        )
    }

    /// Reads the bundled offline floor from the running app bundle.
    ///
    /// If the resource cannot be read the result has no `coveredYears`, which
    /// drives `stale` on every instant and therefore "assume peak"; the
    /// conservative direction (§4.2, A6).  That is the safe failure mode.
    static func loadBundled() -> HolidayTable {
        guard let url = Bundle.main.url(forResource: "holidays-2026", withExtension: "json") else {
            FileHandle.standardError.write(Data("Peakbar: holidays-2026.json missing from bundle; assuming no coverage\n".utf8))
            return HolidayTable(source: "unavailable")
        }
        return load(from: url)
    }

    /// Reads a table from an explicit JSON file.
    static func load(from url: URL) -> HolidayTable {
        guard let data = try? Data(contentsOf: url) else {
            return HolidayTable(source: "unavailable")
        }
        return parse(data: data)
    }

    /// Parses the `holidays-2026.json` shape.  Never throws: malformed dates
    /// are skipped, and a wholly unreadable payload yields an uncovered table.
    static func parse(data: Data) -> HolidayTable {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HolidayTable(source: "unavailable")
        }
        let source = (raw["source"] as? String) ?? ""
        let covered = Set((raw["covered_years"] as? [Int]) ?? [])
        let daysOff = Set(((raw["days_off"] as? [String]) ?? []).compactMap(Day.parseISODate))
        let makeup = Set(((raw["makeup_workdays"] as? [String]) ?? []).compactMap(Day.parseISODate))
        return HolidayTable(daysOff: daysOff,
                            makeupWorkdays: makeup,
                            coveredYears: covered,
                            source: source)
    }
}

// MARK: - Resolution

/// The full answer for one instant: the phase, why, and the two independent
/// warning flags (§4.1).
struct Resolution: Equatable {
    let phase: Phase
    let basis: Basis
    /// A year needed now (or by the next-boundary lookahead) is not covered.
    let stale: Bool
    /// A nominally-available higher-precedence source could not be parsed.
    let sourceWarning: Bool

    /// True when either flag is set: the menu bar shows one `⚠` glyph for
    /// both causes (§4.5).
    var hasWarning: Bool { stale || sourceWarning }
}
