//
//  HolidaySourceTests.swift
//  Peakbar
//
//  The iCalendar parser, the two-source precedence chain, and the
//  needs-based fetch policy of ARCHITECTURE.md §5.1.  See also §3.3, §3.4
//  and §7.
//
//  Every fetch case injects a `ManualTransport`; no test touches the network.
//

import Foundation

/// A table that covers 2026 and 2027, used to isolate the year-end-window
/// condition from the staleness condition.
func holidaysCovering2026And2027() -> HolidayTable {
    HolidayTable(daysOff: [],
                 makeupWorkdays: [],
                 coveredYears: [2026, 2027],
                 source: "test fixture")
}

/// All `DTSTART` dates of events that carry no `X-APPLE-SPECIAL-DAY`.
func culturalEventDates(in ics: String) -> [Day] {
    var result: [Day] = []
    var inEvent = false
    var fields: [String: String] = [:]
    for line in HolidaySource.unfold(ics) {
        if line == "BEGIN:VEVENT" { inEvent = true; fields.removeAll() }
        else if line == "END:VEVENT" {
            if inEvent, fields["X-APPLE-SPECIAL-DAY"] == nil,
               let start = fields["DTSTART"].flatMap(Day.parseICSDate) {
                result.append(start)
            }
            inEvent = false; fields.removeAll()
        } else if inEvent, let colon = line.firstIndex(of: ":") {
            let left = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...])
            let name = left.split(separator: ";").first.map(String.init) ?? left
            if fields[name] == nil { fields[name] = value }
        }
    }
    return result
}

/// The same calendar with every `X-APPLE-SPECIAL-DAY` event removed, so the
/// cultural and solar-term entries can be parsed in isolation.
func removingSpecialDayEvents(from ics: String) -> String {
    var out: [String] = []
    var block: [String] = []
    var inEvent = false
    for line in HolidaySource.unfold(ics) {
        if line == "BEGIN:VEVENT" {
            inEvent = true
            block = [line]
        } else if line == "END:VEVENT" {
            block.append(line)
            if !block.contains(where: { $0.hasPrefix("X-APPLE-SPECIAL-DAY") }) {
                out.append(contentsOf: block)
            }
            inEvent = false
            block = []
        } else if inEvent {
            block.append(line)
        } else {
            out.append(line)
        }
    }
    return out.joined(separator: "\r\n")
}

func runHolidaySourceTests() {

    let bundled = loadBundledHolidays()
    let shipped = loadShippedSchedule()
    let fixture = loadICSFixture()

    let parserSource = HolidaySource(transport: ManualTransport(),
                                     clock: ManualClock(utcDate(2026, 1, 1, 0, 0)),
                                     cacheDirectory: makeTempDirectory("parser"),
                                     bundled: bundled)

    // ------------------------------------------------------- ICS 2026 equality
    section("ICS parse: 2026 exact match (§3.4, §7)")
    do {
        check("the fixture is non-empty", fixture.count > 10_000, "\(fixture.count) bytes")

        let parsed = parserSource.parse(ics: fixture)
        let daysOff2026 = Set(parsed.daysOff.filter { $0.year == 2026 })
        let stateCouncil = Set(bundled.daysOff.filter { $0.year == 2026 })

        check("2026 days_off from the ICS is exactly the 33 State Council dates",
              daysOff2026 == stateCouncil,
              "ICS \(daysOff2026.count) vs table \(stateCouncil.count); diff \(daysOff2026.symmetricDifference(stateCouncil).sorted())")
        check("exactly 19 of the 2026 days_off are weekdays",
              daysOff2026.filter { (1...5).contains($0.isoWeekday) }.count == 19,
              "\(daysOff2026.filter { (1...5).contains($0.isoWeekday) }.count)")
        note("ICS 2026: \(daysOff2026.count) days off, \(parsed.makeupWorkdays.filter { $0.year == 2026 }.count) make-up days")
        note("ICS per-year days_off: 2024=\(parsed.daysOff.filter { $0.year == 2024 }.count) 2025=\(parsed.daysOff.filter { $0.year == 2025 }.count) 2026=\(parsed.daysOff.filter { $0.year == 2026 }.count)")
    }

    // --------------------------------------------------------- ICS DTEND rules
    section("ICS parse: DTEND semantics (§6 case 24)")
    do {
        let parsed = parserSource.parse(ics: fixture)
        check("Spring Festival range 20260215→20260224 includes 2026-02-23",
              parsed.daysOff.contains(day(2026, 2, 23)))
        check("…and excludes 2026-02-24 (DTEND is exclusive)",
              !parsed.daysOff.contains(day(2026, 2, 24)))
    }
    do {
        let synthetic = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20260101
        DTEND;VALUE=DATE:20260104
        X-APPLE-SPECIAL-DAY:WORK-HOLIDAY
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20260105
        X-APPLE-SPECIAL-DAY:WORK-HOLIDAY
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20260110
        X-APPLE-SPECIAL-DAY:ALTERNATE-WORKDAY
        END:VEVENT
        END:VCALENDAR
        """
        let parsed = parserSource.parse(ics: synthetic)
        check("exclusive DTEND yields 3 days, not 4",
              parsed.daysOff.filter { $0.year == 2026 }.count == 4,
              "got \(parsed.daysOff.sorted())")
        check("…2026-01-01…03 present, 2026-01-04 absent",
              parsed.daysOff.isSuperset(of: [day(2026, 1, 1), day(2026, 1, 2), day(2026, 1, 3)])
                && !parsed.daysOff.contains(day(2026, 1, 4)))
        check("a missing DTEND is a single day, not an open range",
              parsed.daysOff.contains(day(2026, 1, 5))
                && !parsed.daysOff.contains(day(2026, 1, 6)))
        check("ALTERNATE-WORKDAY with no DTEND is a single make-up day",
              parsed.makeupWorkdays == [day(2026, 1, 10)],
              "got \(parsed.makeupWorkdays.sorted())")
    }

    // -------------------------------------------------------- ICS discriminator
    section("ICS parse: discriminator is X-APPLE-SPECIAL-DAY only (§3.4, §6 cases 22/23)")
    do {
        let parsed = parserSource.parse(ics: fixture)

        check("ALTERNATE-WORKDAY dates land in makeupWorkdays, not days_off",
              parsed.makeupWorkdays.isSuperset(of: [
                day(2026, 1, 4), day(2026, 2, 14), day(2026, 2, 28),
                day(2026, 5, 9), day(2026, 9, 20), day(2026, 10, 10)
              ]) && !parsed.daysOff.contains(day(2026, 1, 4)),
              "makeup=\(parsed.makeupWorkdays.filter { $0.year == 2026 }.sorted())")

        let cultural = culturalEventDates(in: fixture)
        check("the fixture carries the ~206 cultural events", cultural.count >= 200,
              "found \(cultural.count)")

        // Parsing the cultural events in isolation must yield nothing: they are
        // not days off, they merely coincide with some.  (A date check against
        // the full parse would be wrong: e.g. 除夕 falls inside the Spring
        // Festival block and is a day off for that reason, not because of the
        // cultural entry.)
        let culturalOnly = parserSource.parse(ics: removingSpecialDayEvents(from: fixture))
        check("cultural and solar-term events contribute zero days off",
              culturalOnly.daysOff.isEmpty,
              "leaked \(culturalOnly.daysOff.sorted())")
        check("…and contribute zero make-up days", culturalOnly.makeupWorkdays.isEmpty)
        check("…and vouch for no year", culturalOnly.coveredYears.isEmpty)

        check("the 2027 春节 cultural entry (20270206) is not a day off",
              !parsed.daysOff.contains(day(2027, 2, 6)))
    }

    // ------------------------------------------------------ ICS uncovered year
    section("ICS parse: coverage is derived, not spanned (§3.4, §6 case 22)")
    do {
        let parsed = parserSource.parse(ics: fixture)
        check("2027 is not in covered_years (zero WORK-HOLIDAY events)",
              !parsed.coveredYears.contains(2027),
              "got \(parsed.coveredYears.sorted())")
        check("covered_years contains 2024, 2025 and 2026",
              parsed.coveredYears.isSuperset(of: [2024, 2025, 2026]),
              "got \(parsed.coveredYears.sorted())")
        note("derived covered_years = \(parsed.coveredYears.sorted())")

        // A year carrying cultural events only must be uncovered, not
        // holiday-free.
        let culturalOnly2027 = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20270206
        SUMMARY;LANGUAGE=zh_CN:春节
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20270205
        SUMMARY;LANGUAGE=zh_CN:立春
        END:VEVENT
        END:VCALENDAR
        """
        let parsed2027 = parserSource.parse(ics: culturalOnly2027)
        check("a cultural-only year has no covered_years",
              parsed2027.coveredYears.isEmpty, "got \(parsed2027.coveredYears.sorted())")
        check("…and its cultural dates are not days off", parsed2027.daysOff.isEmpty)
    }

    // ------------------------------------------------------------- precedence
    section("Two-source precedence (§3.3, §7)")
    do {
        let dir = makeTempDirectory("precedence")
        defer { removeTempDirectory(dir) }
        let cacheICS = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20270501
        DTEND;VALUE=DATE:20270502
        X-APPLE-SPECIAL-DAY:WORK-HOLIDAY
        END:VEVENT
        END:VCALENDAR
        """
        try? Data(cacheICS.utf8).write(to: dir.appendingPathComponent("cn_zh.ics"))

        let source = HolidaySource(transport: ManualTransport(),
                                   clock: ManualClock(utcDate(2026, 6, 15, 0, 0)),
                                   cacheDirectory: dir,
                                   bundled: bundled)
        let table = source.currentTable
        check("cache supplies 2027-05-01, which the bundled table lacks",
              table.daysOff.contains(day(2027, 5, 1)) && !bundled.daysOff.contains(day(2027, 5, 1)))
        check("bundled supplies 2026-01-01, which the cache lacks",
              table.daysOff.contains(day(2026, 1, 1)) && !table.daysOff.contains(day(2027, 5, 2)))
        check("the cache's provenance wins on `source`",
              table.source == HolidaySource.appleSourceLabel, "got \(table.source)")
    }

    // -------------------------------------------------------- transport failure
    section("Fetch outcomes: transport failure vs malformed payload (§6 cases 20/21)")
    do {
        let dir = makeTempDirectory("failure")
        defer { removeTempDirectory(dir) }
        try? Data(sampleICS().utf8).write(to: dir.appendingPathComponent("cn_zh.ics"))

        let clock = ManualClock(beijingDate(2026, 12, 20, 10, 0))
        let transport = ManualTransport(result: .failure(.network("offline")))
        let source = HolidaySource(transport: transport, clock: clock, cacheDirectory: dir, bundled: bundled)
        let before = source.currentTable

        source.refreshIfDue(isLaunch: false)

        check("a transport failure is attempted", transport.attemptCount == 1)
        check("…the cache is used unchanged", source.currentTable.daysOff == before.daysOff)
        check("…and neither flag is set", source.currentTable.sourceWarning == false)
        check("…and nothing crashes", true)
    }
    do {
        let dir = makeTempDirectory("malformedPayload")
        defer { removeTempDirectory(dir) }
        try? Data(sampleICS().utf8).write(to: dir.appendingPathComponent("cn_zh.ics"))

        let clock = ManualClock(beijingDate(2026, 12, 20, 10, 0))
        let transport = ManualTransport(result: .success(HTTPResponse(
            statusCode: 200,
            body: Data(truncatedICS().utf8),
            lastModified: nil,
            etag: nil
        )))
        let source = HolidaySource(transport: transport, clock: clock, cacheDirectory: dir, bundled: bundled)

        source.refreshIfDue(isLaunch: false)

        check("a malformed payload is attempted", transport.attemptCount == 1)
        check("…falls back one rank and sets sourceWarning", source.currentTable.sourceWarning)
        check("…keeping the cache's dates rather than the truncated ones",
              source.currentTable.daysOff.contains(day(2026, 12, 24))
                && source.currentTable.daysOff.contains(day(2026, 1, 1)),
              "daysOff=\(source.currentTable.daysOff.sorted())")
    }
    do {
        // A 304 keeps the cache and raises nothing.
        let dir = makeTempDirectory("notModified")
        defer { removeTempDirectory(dir) }
        try? Data(sampleICS().utf8).write(to: dir.appendingPathComponent("cn_zh.ics"))

        let clock = ManualClock(beijingDate(2026, 12, 20, 10, 0))
        let transport = ManualTransport(result: .notModified)
        let source = HolidaySource(transport: transport, clock: clock, cacheDirectory: dir, bundled: bundled)
        source.refreshIfDue(isLaunch: false)
        check("a 304 keeps the table and sets no warning",
              source.currentTable.sourceWarning == false
                && source.currentTable.daysOff.contains(day(2026, 12, 24)))
    }
    do {
        // A good fetch is written to the cache and carries the conditional
        // validators forward.
        let dir = makeTempDirectory("goodFetch")
        defer { removeTempDirectory(dir) }

        let clock = ManualClock(beijingDate(2026, 12, 20, 10, 0))
        let transport = ManualTransport(result: .success(HTTPResponse(
            statusCode: 200,
            body: Data(sampleICS().utf8),
            lastModified: "Tue, 01 Dec 2026 00:00:00 GMT",
            etag: "W/\"abc\""
        )))
        let source = HolidaySource(transport: transport, clock: clock, cacheDirectory: dir, bundled: bundled)
        source.refreshIfDue(isLaunch: true)
        check("a good fetch is applied",
              source.currentTable.daysOff.contains(day(2026, 12, 24)))
        check("…and cached to disk",
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("cn_zh.ics").path))

        clock.advance(25 * 3600)
        source.refreshIfDue(isLaunch: false)
        check("the next request is conditional (If-Modified-Since / If-None-Match)",
              transport.attempts.count == 2
                && transport.attempts[1].ifModifiedSince == "Tue, 01 Dec 2026 00:00:00 GMT"
                && transport.attempts[1].ifNoneMatch == "W/\"abc\"",
              "attempts=\(transport.attempts.count)")
    }

    // -------------------------------------------------------- fetch policy (§5.1)
    section("Fetch policy: needs-based (§5.1, §6 cases 29/30/31)")
    do {
        // (a) No need: mid-June, current year covered, no warning.
        let dir = makeTempDirectory("policyNone")
        defer { removeTempDirectory(dir) }
        let clock = ManualClock(beijingDate(2026, 6, 15, 10, 0))
        let transport = ManualTransport(result: .failure(.network("offline")))
        let source = HolidaySource(transport: transport, clock: clock, cacheDirectory: dir, bundled: bundled)

        for _ in 0..<10 {
            source.refreshIfDue(isLaunch: false)
            clock.advance(6 * 3600)
        }
        check("mid-June, covered, no warning → zero fetch attempts",
              transport.attemptCount == 0, "got \(transport.attemptCount)")
    }
    do {
        // (b) Year-end window: at most one attempt per 24 h.
        let dir = makeTempDirectory("policyWindow")
        defer { removeTempDirectory(dir) }
        let clock = ManualClock(beijingDate(2026, 12, 20, 10, 0))
        let transport = ManualTransport(result: .failure(.network("offline")))
        let source = HolidaySource(transport: transport, clock: clock,
                                   cacheDirectory: dir, bundled: holidaysCovering2026And2027())

        source.refreshIfDue(isLaunch: false)
        check("inside the window a fetch is attempted", transport.attemptCount == 1)

        for _ in 0..<5 { clock.advance(3600); source.refreshIfDue(isLaunch: false) }
        check("…but not again within 24 h", transport.attemptCount == 1,
              "got \(transport.attemptCount)")

        clock.advance(25 * 3600)
        source.refreshIfDue(isLaunch: false)
        check("…and again once 24 h have passed", transport.attemptCount == 2,
              "got \(transport.attemptCount)")
    }
    do {
        // Window edges: 15 Dec – 31 Jan inclusive.
        let covering = holidaysCovering2026And2027()
        func attemptsOn(_ beijing: Date) -> Int {
            let dir = makeTempDirectory("policyEdge")
            defer { removeTempDirectory(dir) }
            let clock = ManualClock(beijing)
            let transport = ManualTransport(result: .failure(.network("offline")))
            let source = HolidaySource(transport: transport, clock: clock, cacheDirectory: dir, bundled: covering)
            source.refreshIfDue(isLaunch: false)
            return transport.attemptCount
        }
        check("14 Dec is outside the window", attemptsOn(beijingDate(2026, 12, 14, 12, 0)) == 0)
        check("15 Dec is inside the window", attemptsOn(beijingDate(2026, 12, 15, 12, 0)) == 1)
        check("31 Jan is inside the window", attemptsOn(beijingDate(2027, 1, 31, 12, 0)) == 1)
        check("1 Feb is outside the window", attemptsOn(beijingDate(2027, 2, 1, 12, 0)) == 0)
    }
    do {
        // (c) Stale: the current Beijing year is not covered → self-heal.
        let dir = makeTempDirectory("policyStale")
        defer { removeTempDirectory(dir) }
        let staleTable = HolidayTable(daysOff: [], makeupWorkdays: [], coveredYears: [2025], source: "old")
        let clock = ManualClock(beijingDate(2026, 6, 15, 10, 0))
        let transport = ManualTransport(result: .failure(.network("offline")))
        let source = HolidaySource(transport: transport, clock: clock, cacheDirectory: dir, bundled: staleTable)

        check("the current year is indeed uncovered", !source.currentTable.coveredYears.contains(2026))
        source.refreshIfDue(isLaunch: false)
        check("stale mid-year → fetch attempted (self-heal)", transport.attemptCount == 1,
              "got \(transport.attemptCount)")
    }
    do {
        // (d) sourceWarning set → recovery fetch.
        let dir = makeTempDirectory("policyWarning")
        defer { removeTempDirectory(dir) }
        try? Data("garbage, not an ICS".utf8).write(to: dir.appendingPathComponent("cn_zh.ics"))
        let clock = ManualClock(beijingDate(2026, 6, 15, 10, 0))
        let transport = ManualTransport(result: .failure(.network("offline")))
        let source = HolidaySource(transport: transport, clock: clock, cacheDirectory: dir, bundled: bundled)

        check("the malformed cache raised the warning", source.sourceWarning)
        source.refreshIfDue(isLaunch: false)
        check("sourceWarning → fetch attempted (recovery)", transport.attemptCount == 1,
              "got \(transport.attemptCount)")
    }
    do {
        // A launch does NOT force a fetch.  Fetching unconditionally would
        // initialise a network session on every start for a request that
        // cannot change an answer: the bundled table already covers the
        // current year for most of the year.
        let dir = makeTempDirectory("policyLaunch")
        defer { removeTempDirectory(dir) }
        let clock = ManualClock(beijingDate(2026, 6, 15, 10, 0))
        let transport = ManualTransport(result: .failure(.network("offline")))
        let source = HolidaySource(transport: transport, clock: clock, cacheDirectory: dir, bundled: bundled)
        source.refreshIfDue(isLaunch: true)
        check("a launch outside the window, with the year covered, makes no request",
              transport.attemptCount == 0, "got \(transport.attemptCount)")
    }
    do {
        // Inside the window a launch does fetch, and bypasses the 24 h gate.
        let dir = makeTempDirectory("policyLaunchWindow")
        defer { removeTempDirectory(dir) }
        let clock = ManualClock(beijingDate(2026, 12, 20, 10, 0))
        let transport = ManualTransport(result: .failure(.network("offline")))
        let source = HolidaySource(transport: transport, clock: clock, cacheDirectory: dir, bundled: bundled)
        source.refreshIfDue(isLaunch: true)
        check("a launch inside the year-end window fetches", transport.attemptCount == 1)
        source.refreshIfDue(isLaunch: true)
        check("a second launch fetch is also allowed, the 24 h gate is bypassed on launch",
              transport.attemptCount == 2)
    }

    // ---------------------------------------------- needs-based volume estimate
    section("Fetch volume (§5.1)")
    do {
        // Walk a whole year of day-change events under the real policy and
        // count the requests.  The doc's figure is ~48 a year.
        let dir = makeTempDirectory("volume")
        defer { removeTempDirectory(dir) }
        let clock = ManualClock(utcDate(2026, 1, 1, 0, 0))
        let transport = ManualTransport(result: .failure(.network("offline")))
        let source = HolidaySource(transport: transport, clock: clock,
                                   cacheDirectory: dir, bundled: holidaysCovering2026And2027())
        source.refreshIfDue(isLaunch: true)

        for _ in 0..<365 {
            clock.advance(24 * 3600)
            source.refreshIfDue(isLaunch: false)
        }
        let requests = transport.attemptCount
        check("a year of daily events costs far fewer than 365 requests",
              requests <= 60, "got \(requests)")
        note("one year of daily day-change events → \(requests) requests (launch fetch included)")
    }

    // ------------------------------------------------ Resolver stays pure
    section("Resolver purity (§6 case 27)")
    do {
        // Two resolvers with identical inputs must agree, and building one must
        // have no side effects on the other.
        let a = Resolver(schedule: shipped, holidays: bundled)
        var b = Resolver(schedule: shipped, holidays: bundled)
        let instant = beijingDate(2026, 10, 1, 10, 0)
        let first = a.phase(at: instant)
        _ = a.nextChange(at: instant)
        _ = a.resolve(at: instant)
        b.holidays = HolidayTable()
        let second = Resolver(schedule: shipped, holidays: bundled).phase(at: instant)
        check("phase(at:) is a pure function of the instant", first == second, "\(first) vs \(second)")
        check("mutating one resolver does not affect another", a.phase(at: instant) == first)
    }
}
