//
//  EdgeCaseTests.swift
//  Peakbar
//
//  The behavioural suites: weekend, holiday, make-up, the effective-date gate,
//  coverage and the fail-safe, cache merge and fallback, the next-change walk,
//  the lookahead bound sweep, the lifecycle seam and the notification rules.
//

import Foundation

// MARK: - Model factory

/// Builds a `StatusModel` driven entirely by manual doubles.  The background
/// and main-queue hops are made inline so the harness is deterministic.
func makeModel(clock: ManualClock,
               schedule: Schedule = loadShippedSchedule(),
               holidays: HolidayTable = loadBundledHolidays(),
               ticker: ManualTicker = ManualTicker(),
               notifier: ManualNotifier = ManualNotifier(),
               lifecycle: ManualLifecycle = ManualLifecycle(),
               notifyOnFlip: Bool = true,
               holidaySource: HolidaySource? = nil) -> StatusModel {
    let source: HolidaySource
    if let provided = holidaySource {
        source = provided
    } else {
        source = HolidaySource(transport: ManualTransport(),
                               clock: clock,
                               cacheDirectory: makeTempDirectory("model"),
                               bundled: holidays)
    }
    return StatusModel(schedule: schedule,
                       holidays: source.currentTable,
                       clock: clock,
                       ticker: ticker,
                       lifecycle: lifecycle,
                       notifier: notifier,
                       holidaySource: source,
                       notifyOnFlip: notifyOnFlip,
                       runBackground: { $0() },
                       runMain: { $0() })
}

/// The nearest Mon–Fri date that is not a public holiday.
func nearestNormalWeekday(from start: Day, table: HolidayTable) -> Day? {
    for delta in 1...21 {
        for candidate in [Day.fromEpochDay(start.epochDay + delta),
                          Day.fromEpochDay(start.epochDay - delta)] {
            if (1...5).contains(candidate.isoWeekday) && !table.daysOff.contains(candidate) {
                return candidate
            }
        }
    }
    return nil
}

// MARK: - Suite

func runEdgeCaseTests() {

    let shipped = loadShippedSchedule()
    let early = loadEarlyEffectiveSchedule()
    let bundled = loadBundledHolidays()

    // ------------------------------------------------------------ 1. weekend
    section("Weekend rule")
    do {
        let resolver = Resolver(schedule: shipped, holidays: bundled)
        var checked = 0
        var firstBad = ""
        var cursor = Day(2026, 9, 1)
        while cursor < Day(2026, 12, 31) {
            if cursor.isoWeekday >= 6 {
                let instant = beijingDate(cursor.y, cursor.m, cursor.d, 10, 0)
                let (phase, basis) = resolver.classify(at: instant)
                if phase != .offpeak || basis != .weekend {
                    if firstBad.isEmpty { firstBad = "\(cursor) \(phase)/\(basis)" }
                }
                checked += 1
            }
            cursor = cursor.nextDay
        }
        check("every Sat/Sun in Sep–Dec 2026 is off-peak by the weekend rule (\(checked) days)",
              checked > 30 && firstBad.isEmpty, firstBad)
    }

    // The 16:00–24:00 UTC stretch is the only place the UTC and Beijing
    // calendars disagree.  The live schedule has no window there, so the
    // discriminating fixture is the synthetic overnight schedule, the same
    // one conformance vectors 13/14 use.
    do {
        let resolver = Resolver(schedule: shipped, holidays: bundled)
        // Beijing Sat 2026-08-29 00:30 == UTC Fri 2026-08-28 16:30.
        let lateNightSaturday = beijingDate(2026, 8, 29, 0, 30)
        check("Beijing Sat 00:30 is off-peak (outside both live windows)",
              resolver.phase(at: lateNightSaturday) == .offpeak,
              "got \(resolver.phase(at: lateNightSaturday))")

        let synthetic = Schedule(calendarTimezone: "Asia/Shanghai",
                                 calendarUTCOffsetHours: 8,
                                 peakWindowsUTC: [Window(startMinute: 960, endMinute: 1320)],
                                 peakWeekdays: [1, 2, 3, 4, 5],
                                 weekendOffpeakEffectiveUTC: parseISO("2026-08-22T16:00:00Z")!,
                                 offpeakMultiplier: 0.5)
        let overnight = Resolver(schedule: synthetic, holidays: bundled)

        // Beijing Sat 00:30 → UTC still Friday.  Reading the weekday off the
        // unshifted instant would say Friday and return peak.
        check("overnight schedule: Beijing Sat 00:30 (UTC Friday) is off-peak",
              overnight.phase(at: beijingDate(2026, 8, 29, 0, 30)) == .offpeak,
              "got \(overnight.phase(at: beijingDate(2026, 8, 29, 0, 30)))")
        // Beijing Mon 00:30 → UTC still Sunday.  Reading the weekday off the
        // unshifted instant would say Sunday and return off-peak.
        check("overnight schedule: Beijing Mon 00:30 (UTC Sunday) is peak",
              overnight.phase(at: beijingDate(2026, 8, 31, 0, 30)) == .peak,
              "got \(overnight.phase(at: beijingDate(2026, 8, 31, 0, 30)))")
    }

    // ------------------------------------------------------------ 2. holiday
    section("Holiday rule")
    do {
        // Gate neutralised so every 2026 weekday holiday is testable.
        let resolver = Resolver(schedule: early, holidays: bundled)
        let weekdayHolidays = bundled.daysOff.filter { (1...5).contains($0.isoWeekday) }.sorted()
        check("the bundled 2026 table carries 19 weekday holidays",
              weekdayHolidays.count == 19, "found \(weekdayHolidays.count)")

        var bad: [String] = []
        for holiday in weekdayHolidays {
            let instant = beijingDate(holiday.y, holiday.m, holiday.d, 10, 0)
            let (phase, basis) = resolver.classify(at: instant)
            if phase != .offpeak || basis != .holiday {
                bad.append("\(holiday) → \(phase)/\(basis)")
            }
        }
        check("each of the 19 weekday holidays is off-peak (.holiday)",
              bad.isEmpty, bad.joined(separator: ", "))

        var badAdjacent: [String] = []
        for holiday in weekdayHolidays {
            guard let normal = nearestNormalWeekday(from: holiday, table: bundled) else { continue }
            let instant = beijingDate(normal.y, normal.m, normal.d, 10, 0)
            if resolver.phase(at: instant) != .peak {
                badAdjacent.append("\(holiday) → adjacent \(normal) not peak")
            }
        }
        check("the adjacent normal weekday is peak for every holiday",
              badAdjacent.isEmpty, badAdjacent.joined(separator: ", "))
    }

    // The shipped gate: only holidays on or after the effective instant are
    // suppressed.  The rule is not retroactive.
    do {
        let resolver = Resolver(schedule: shipped, holidays: bundled)
        let effective = shipped.weekendOffpeakEffectiveUTC

        let postEffective = bundled.daysOff
            .filter { (1...5).contains($0.isoWeekday) }
            .filter { beijingDate($0.y, $0.m, $0.d, 10, 0) >= effective }
            .sorted()
        check("6 weekday holidays fall after the effective instant",
              postEffective.count == 6, "found \(postEffective.count): \(postEffective)")

        var bad: [String] = []
        for holiday in postEffective {
            let instant = beijingDate(holiday.y, holiday.m, holiday.d, 10, 0)
            if resolver.phase(at: instant) != .offpeak { bad.append("\(holiday)") }
        }
        check("post-effective weekday holidays are off-peak under the shipped gate",
              bad.isEmpty, bad.joined(separator: ", "))

        // 2026-01-01 is a Thursday holiday, but it precedes the gate.
        let newYear = beijingDate(2026, 1, 1, 10, 0)
        check("pre-effective weekday holiday (2026-01-01, Thu) is peak, not retroactive",
              resolver.phase(at: newYear) == .peak,
              "got \(resolver.phase(at: newYear))")
    }

    // ------------------------------------------------------------ 3. make-up
    section("Make-up workdays")
    do {
        let resolver = Resolver(schedule: early, holidays: bundled)
        let makeups = bundled.makeupWorkdays.sorted()
        check("the bundled table records 6 make-up workdays",
              makeups.count == 6, "found \(makeups.count)")

        var bad: [String] = []
        for makeup in makeups {
            let instant = beijingDate(makeup.y, makeup.m, makeup.d, 10, 0)
            let (phase, basis) = resolver.classify(at: instant)
            // Every 2026 make-up day is a Saturday or Sunday, so the weekend
            // rule supersedes and it stays off-peak.
            if phase != .offpeak || basis != .weekend { bad.append("\(makeup) → \(phase)/\(basis)") }
        }
        check("every make-up day is off-peak via the weekend rule, not peak",
              bad.isEmpty, bad.joined(separator: ", "))
        check("all 6 make-up days fall on Sat/Sun",
              makeups.allSatisfy { $0.isoWeekday >= 6 })
    }

    // ------------------------------------------- 4. coverage and fail-safe
    section("Coverage, fail-safe and flag distinction")
    do {
        let resolver = Resolver(schedule: shipped, holidays: bundled)
        // Monday 2027-06-07, 10:00 Beijing, inside the first peak window.
        let uncovered = beijingDate(2027, 6, 7, 10, 0)
        let resolution = resolver.resolve(at: uncovered)

        check("uncovered year inside a window on a weekday → phase peak",
              resolution.phase == .peak, "got \(resolution.phase)")
        check("uncovered year → stale", resolution.stale)
        check("uncovered year → basis .assumedPeak",
              resolution.basis == .assumedPeak, "got \(resolution.basis)")
        check("uncovered year → warning shown", resolution.hasWarning)
        check("uncovered year → sourceWarning NOT set (flag distinction a)",
              resolution.sourceWarning == false)
        check("fail-safe never reports off-peak on an unverifiable in-window weekday",
              resolution.phase != .offpeak)

        // The fail-safe must stay narrow: outside a window the same stale day
        // is still off-peak.  Widening it to "the whole stale day is peak"
        // would report PEAK on a Saturday, which is provably wrong (A6).
        let staleEvening = beijingDate(2027, 6, 7, 20, 0)
        check("stale day outside a window is still off-peak (fail-safe not widened)",
              resolver.phase(at: staleEvening) == .offpeak,
              "got \(resolver.phase(at: staleEvening))")

        // A Saturday in an uncovered year is off-peak by the weekend rule.
        let staleSaturday = beijingDate(2027, 6, 5, 10, 0)
        check("stale Saturday is off-peak, not peak",
              resolver.phase(at: staleSaturday) == .offpeak,
              "got \(resolver.phase(at: staleSaturday))")
    }

    // --------------------------------- 4b. the flag covers the target year
    section("Display staleness covers the countdown target")
    do {
        // 2026-12-31 18:00 Beijing is the first instant whose next change
        // lands in 2027.  The current year is covered; the target year
        // is not.  A now-only flag would stay silent here.
        let instant = beijingDate(2026, 12, 31, 18, 0)

        let uncovered2027 = Resolver(schedule: shipped, holidays: bundled)

        // Verify the "first instant" claim: one minute earlier the target is
        // still inside 2026, so the case only opens up at 18:00.
        let justBefore = instant.addingTimeInterval(-60)
        let targetBefore = uncovered2027.nextChange(at: justBefore).date
        check("17:59's target is still inside 2026; 18:00 is the first such instant",
              uncovered2027.beijingDay(at: targetBefore).year == 2026,
              "got \(ISO8601DateFormatter().string(from: targetBefore))")

        let resolution1 = uncovered2027.resolve(at: instant)
        let target1 = uncovered2027.nextChange(at: instant).date

        check("bundled table covers only 2026", bundled.coveredYears == [2026],
              "got \(bundled.coveredYears.sorted())")
        check("current year covered but target year not → stale", resolution1.stale)
        check("…and the warning is therefore visible", resolution1.hasWarning)
        check("…phase at that instant is off-peak", resolution1.phase == .offpeak,
              "got \(resolution1.phase)")
        check("assume-peak target is 2027-01-01 09:00 Beijing",
              abs(target1.timeIntervalSince(parseISO("2027-01-01T01:00:00Z")!)) < 0.5,
              "got \(ISO8601DateFormatter().string(from: target1))")

        // Now vouch for 2027 and add 元旦.  The phase must not move; the
        // countdown must move by exactly three days: the holiday plus the
        // weekend.  This is what proves the flag is doing real work rather
        // than firing decoratively.
        let with2027 = HolidayTable(daysOff: bundled.daysOff.union([day(2027, 1, 1)]),
                                    makeupWorkdays: bundled.makeupWorkdays,
                                    coveredYears: [2026, 2027],
                                    source: "test fixture with 2027 元旦")
        let covered2027 = Resolver(schedule: shipped, holidays: with2027)
        let resolution2 = covered2027.resolve(at: instant)
        let target2 = covered2027.nextChange(at: instant).date

        check("both years covered → not stale", resolution2.stale == false)
        check("…phase is unchanged by the flag (still off-peak)",
              resolution2.phase == .offpeak, "got \(resolution2.phase)")
        check("real target with 元旦 2027 is 2027-01-04 09:00 Beijing",
              abs(target2.timeIntervalSince(parseISO("2027-01-04T01:00:00Z")!)) < 0.5,
              "got \(ISO8601DateFormatter().string(from: target2))")
        check("the two targets differ by exactly three days",
              abs(target2.timeIntervalSince(target1) - 3 * 86_400) < 0.5,
              "\(target2.timeIntervalSince(target1) / 86_400) days")

        // The fail-safe must be untouched: the widened flag is display-only.
        // A candidate in the uncovered year still degrades to assume-peak.
        let candidateIn2027 = beijingDate(2027, 1, 1, 10, 0)
        check("per-candidate staleness still degrades to assume-peak in 2027",
              uncovered2027.classify(at: candidateIn2027).phase == .peak
                && uncovered2027.classify(at: candidateIn2027).basis == .assumedPeak,
              "got \(uncovered2027.classify(at: candidateIn2027))")

        note("uncovered 2027 → target \(ISO8601DateFormatter().string(from: target1)); covered 2027 with 元旦 → target \(ISO8601DateFormatter().string(from: target2))")
    }

    // -------------------------------------------------- 5. cache merge / bad
    section("Cache merge and malformed cache")
    do {
        let dir = makeTempDirectory("merge")
        defer { removeTempDirectory(dir) }
        let cacheICS = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20270101
        DTEND;VALUE=DATE:20270102
        X-APPLE-SPECIAL-DAY:WORK-HOLIDAY
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20270205
        X-APPLE-SPECIAL-DAY:ALTERNATE-WORKDAY
        END:VEVENT
        END:VCALENDAR
        """
        try? Data(cacheICS.utf8).write(to: dir.appendingPathComponent("cn_zh.ics"))

        let source = HolidaySource(transport: ManualTransport(),
                                   clock: ManualClock(utcDate(2026, 6, 15, 0, 0)),
                                   cacheDirectory: dir,
                                   bundled: bundled)
        let merged = source.currentTable

        check("cache merge unions days_off (2027-01-01 present, bundled 2026 intact)",
              merged.daysOff.contains(day(2027, 1, 1)) && merged.daysOff.contains(day(2026, 1, 1)))
        check("cache merge unions covered_years ({2026, 2027})",
              merged.coveredYears == [2026, 2027], "got \(merged.coveredYears.sorted())")
        check("cache merge unions make-up days",
              merged.makeupWorkdays.contains(day(2027, 2, 5)))
        check("higher-precedence source wins on `source`",
              merged.source == HolidaySource.appleSourceLabel, "got \(merged.source)")
        check("a valid cache raises no warning", merged.sourceWarning == false)
    }
    do {
        let dir = makeTempDirectory("malformed")
        defer { removeTempDirectory(dir) }
        try? Data("this is not an iCalendar file at all".utf8)
            .write(to: dir.appendingPathComponent("cn_zh.ics"))

        let source = HolidaySource(transport: ManualTransport(),
                                   clock: ManualClock(utcDate(2026, 6, 15, 0, 0)),
                                   cacheDirectory: dir,
                                   bundled: bundled)
        let table = source.currentTable

        check("malformed cache falls back to the bundled floor",
              table.daysOff == bundled.daysOff && table.coveredYears == bundled.coveredYears)
        check("malformed cache → sourceWarning (flag distinction b)", table.sourceWarning)
        check("malformed cache → bundled provenance string kept",
              table.source == bundled.source, "got \(table.source)")

        let resolver = Resolver(schedule: shipped, holidays: table)
        let resolution = resolver.resolve(at: beijingDate(2026, 6, 15, 10, 0))
        check("malformed cache → sourceWarning true and stale false (never both)",
              resolution.sourceWarning == true && resolution.stale == false,
              "sourceWarning=\(resolution.sourceWarning) stale=\(resolution.stale)")
    }
    do {
        // No cache and no network: the bundled floor, and no warning: the
        // expected first-run state.
        let dir = makeTempDirectory("empty")
        defer { removeTempDirectory(dir) }
        let source = HolidaySource(transport: ManualTransport(),
                                   clock: ManualClock(utcDate(2026, 6, 15, 0, 0)),
                                   cacheDirectory: dir,
                                   bundled: bundled)
        check("first launch with no cache and no network uses the bundled floor silently",
              source.currentTable.daysOff == bundled.daysOff && source.sourceWarning == false)
    }

    // ------------------------------------------------- 6. next-change walk
    section("Next-change walk")
    do {
        let resolver = Resolver(schedule: shipped, holidays: bundled)
        let fridayEvening = parseISO("2026-08-28T10:30:00Z")!   // Beijing Fri 18:30
        let (change, phase) = resolver.nextChange(at: fridayEvening)
        let expected = parseISO("2026-08-31T01:00:00Z")!        // Beijing Mon 09:00
        let hours = change.timeIntervalSince(fridayEvening) / 3600

        check("Beijing Fri 18:30 → next change is Monday 09:00",
              abs(change.timeIntervalSince(expected)) < 0.5,
              "got \(ISO8601DateFormatter().string(from: change))")
        check("…and that change is into peak", phase == .peak, "got \(phase)")
        check("…about 63 hours out, not a weekend-resident edge",
              abs(hours - 62.5) < 0.01, "\(hours) h")

        // The weekend-resident edges must yield no change: every candidate
        // between Friday evening and Monday morning has off-peak on both sides.
        let saturdayMorning = beijingDate(2026, 8, 29, 10, 0)
        let (satChange, _) = resolver.nextChange(at: saturdayMorning)
        check("from Beijing Sat 10:00 the next change is still Monday 09:00",
              abs(satChange.timeIntervalSince(expected)) < 0.5,
              "got \(ISO8601DateFormatter().string(from: satChange))")
    }
    do {
        // Pre-rule: the gate is evaluated per candidate, so a pre-rule walk
        // must not skip the weekend.
        let resolver = Resolver(schedule: shipped, holidays: bundled)
        let from = parseISO("2026-08-21T18:00:00Z")!            // Beijing Sat 02:00, pre-rule
        let (change, phase) = resolver.nextChange(at: from)
        let expected = parseISO("2026-08-22T01:00:00Z")!
        check("pre-rule walk finds the next window edge, not the weekend",
              abs(change.timeIntervalSince(expected)) < 0.5 && phase == .peak,
              "got \(ISO8601DateFormatter().string(from: change))/\(phase)")
    }

    // ---------------------------------------------- 7. lookahead bound sweep
    section("Lookahead bound: minute sweep of the shipped coverage range")
    do {
        let resolver = Resolver(schedule: shipped, holidays: bundled)
        let start = shipped.weekendOffpeakEffectiveUTC
        let end = utcDate(2027, 1, 1, 0, 0)
        let totalMinutes = Int(end.timeIntervalSince(start) / 60)

        var longestStretch = 0
        var currentStretch = 0
        var stretches = 0
        for minute in 0...totalMinutes {
            let instant = start.addingTimeInterval(TimeInterval(minute * 60))
            if resolver.phase(at: instant) == .offpeak {
                currentStretch += 1
            } else {
                if currentStretch > 0 { stretches += 1; longestStretch = max(longestStretch, currentStretch) }
                currentStretch = 0
            }
        }
        if currentStretch > 0 { stretches += 1; longestStretch = max(longestStretch, currentStretch) }

        let longestDays = Double(longestStretch) / 1440.0
        note("swept \(totalMinutes + 1) minutes (\(String(format: "%.1f", Double(totalMinutes) / 1440)) days), \(stretches) off-peak stretches")
        note("longest off-peak stretch \(String(format: "%.3f", longestDays)) days (bound \(Resolver.lookaheadDays))")

        check("no off-peak stretch exceeds lookaheadDays",
              longestDays <= Double(Resolver.lookaheadDays),
              "\(longestDays) days")

        // End-to-end: sampled instants must all reach a real change.
        var walkFailures = 0
        for minute in stride(from: 0, through: totalMinutes, by: 30) {
            let instant = start.addingTimeInterval(TimeInterval(minute * 60))
            let here = resolver.phase(at: instant)
            let there = resolver.phase(at: resolver.nextChange(at: instant).date)
            if here == there { walkFailures += 1 }
        }
        check("every sampled instant walks to a genuine phase change",
              walkFailures == 0, "\(walkFailures) instants saw no change")
    }

    // ------------------------------------------------------------ 8. lifecycle
    section("Lifecycle and rescheduling")
    do {
        let clock = ManualClock(beijingDate(2026, 8, 24, 10, 0))   // Beijing Mon 10:00
        let ticker = ManualTicker()
        let lifecycle = ManualLifecycle()
        let notifier = ManualNotifier()
        let model = makeModel(clock: clock, ticker: ticker, notifier: notifier, lifecycle: lifecycle)
        model.start()

        check("at Beijing Mon 10:00 the phase is peak", model.resolution.phase == .peak)
        check("lifecycle handler registered", lifecycle.hasHandler)
        check("authorization requested once on start", notifier.authorizationRequestCount == 1)

        let expectedWake = min(StatusModel.nextMinuteBoundary(clock.now()), model.nextChange)
        check("ticker scheduled at min(next minute, next boundary)",
              ticker.scheduledDate != nil && abs(ticker.scheduledDate!.timeIntervalSince(expectedWake)) < 0.5,
              "got \(ticker.scheduledDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil")")

        // Forward jump across a boundary, then a backward jump.
        clock.set(beijingDate(2026, 8, 24, 12, 30))
        lifecycle.emit(.clockChanged)
        check("clock jumped past 12:00 → off-peak", model.resolution.phase == .offpeak)

        clock.set(beijingDate(2026, 8, 24, 10, 30))
        lifecycle.emit(.wake)
        check("clock jumped back to 10:30 → peak again", model.resolution.phase == .peak)

        lifecycle.emit(.timezoneChanged)
        check("timezone change recomputes without crashing", model.resolution.phase == .peak)

        lifecycle.emit(.dayChanged)
        check("day change recomputes without crashing", model.resolution.phase == .peak)

        // The ticker is rescheduled exactly once per refresh path.
        let before = ticker.scheduleCount
        model.onTick()
        check("onTick reschedules the one-shot timer", ticker.scheduleCount == before + 1)
    }

    // ------------------------------------------------------- 9. notifications
    section("Notifications")
    do {
        let clock = ManualClock(beijingDate(2026, 8, 24, 11, 59, 30))   // Beijing Mon 11:59:30
        let ticker = ManualTicker()
        let notifier = ManualNotifier()
        let model = makeModel(clock: clock, ticker: ticker, notifier: notifier)
        model.start()

        check("no notification before any flip", notifier.postCount == 0)
        check("phase is peak just before the boundary", model.resolution.phase == .peak)

        // Cross the boundary: Beijing 12:00 ends the first window.
        clock.set(beijingDate(2026, 8, 24, 12, 0, 0))
        ticker.fire()
        check("peak → off-peak posts exactly one notification",
              notifier.postCount == 1, "got \(notifier.postCount)")
        check("…titled 'Off-peak started'",
              notifier.titles.first == "Off-peak started", "got \(notifier.titles)")
        check("…body states the new price and its horizon",
              notifier.bodies.first?.hasPrefix("Half price until ") == true,
              "got \(notifier.bodies)")

        // Cross back: Beijing 14:00 reopens the peak.
        clock.set(beijingDate(2026, 8, 24, 14, 0, 0))
        ticker.fire()
        check("off-peak → peak posts a second notification",
              notifier.postCount == 2, "got \(notifier.postCount)")
        check("…titled 'Peak started'",
              notifier.titles.last == "Peak started", "got \(notifier.titles)")
        check("…body states full price",
              notifier.bodies.last?.hasPrefix("Full price until ") == true,
              "got \(notifier.bodies)")

        // A refresh that crosses no boundary must not post again.
        clock.set(beijingDate(2026, 8, 24, 15, 0, 0))
        ticker.fire()
        check("a boundary-free refresh posts nothing", notifier.postCount == 2)
    }
    do {
        // The documented copy: a Friday-evening flip into the long weekend
        // off-peak names the weekday.
        let clock = ManualClock(beijingDate(2026, 8, 28, 17, 59, 30))
        let ticker = ManualTicker()
        let notifier = ManualNotifier()
        let model = makeModel(clock: clock, ticker: ticker, notifier: notifier)
        model.start()
        clock.set(beijingDate(2026, 8, 28, 18, 0, 0))
        ticker.fire()

        let body = notifier.bodies.first ?? ""
        check("Friday-evening flip copy is 'Half price until Mon 9:00 AM'",
              body.hasPrefix("Half price until Mon 9:00 AM"), "got '\(body)'")
        let localOffset = TimeZone.current.secondsFromGMT(for: model.nextChange)
        let expectLocalSuffix = localOffset != Format.beijingOffsetSeconds
        check("local time appended only when this Mac is not on Beijing time",
              body.contains("(local ") == expectLocalSuffix,
              "offset=\(localOffset) body='\(body)'")
    }
    do {
        // Asleep across the boundary: suppress.
        let clock = ManualClock(beijingDate(2026, 8, 24, 11, 59, 30))
        let ticker = ManualTicker()
        let notifier = ManualNotifier()
        let model = makeModel(clock: clock, ticker: ticker, notifier: notifier)
        model.start()

        clock.set(beijingDate(2026, 8, 24, 12, 10, 0))   // 10 minutes late
        ticker.fire()
        check("a flip more than 5 minutes old is suppressed", notifier.postCount == 0,
              "got \(notifier.postCount)")
        check("…but the phase display still updates", model.resolution.phase == .offpeak)

        // Just inside the window it must still post.
        let clock2 = ManualClock(beijingDate(2026, 8, 24, 11, 59, 30))
        let ticker2 = ManualTicker()
        let notifier2 = ManualNotifier()
        let model2 = makeModel(clock: clock2, ticker: ticker2, notifier: notifier2)
        model2.start()
        clock2.set(beijingDate(2026, 8, 24, 12, 4, 0))   // 4 minutes late
        ticker2.fire()
        check("a flip 4 minutes old is still announced", notifier2.postCount == 1,
              "got \(notifier2.postCount)")
    }
    do {
        // Authorization denied: no posts, no repeat prompts, no breakage.
        let clock = ManualClock(beijingDate(2026, 8, 24, 11, 59, 30))
        let ticker = ManualTicker()
        let notifier = ManualNotifier(grantsAuthorization: false)
        let model = makeModel(clock: clock, ticker: ticker, notifier: notifier)
        model.start()

        check("denied authorization does not post", notifier.postCount == 0)

        clock.set(beijingDate(2026, 8, 24, 12, 0, 0)); ticker.fire()
        clock.set(beijingDate(2026, 8, 24, 14, 0, 0)); ticker.fire()
        clock.set(beijingDate(2026, 8, 25, 9, 0, 0));  ticker.fire()

        check("…and still never posts, across several flips", notifier.postCount == 0)
        check("…and never re-prompts (requested exactly once)",
              notifier.authorizationRequestCount == 1,
              "got \(notifier.authorizationRequestCount)")
        check("…and the menu bar keeps working", model.resolution.phase == .peak,
              "got \(model.resolution.phase)")
    }

    // ------------------------------------------------------ 10. display text
    section("Display formatting")
    do {
        check("remaining 2h45m", Format.remaining(2 * 3600 + 45 * 60) == "2h45m")
        check("remaining 1h05m pads minutes", Format.remaining(3600 + 5 * 60) == "1h05m")
        check("remaining under an hour is minutes only", Format.remaining(45 * 60) == "45m")
        check("menu bar title", Format.menuBarTitle(phase: .peak, remaining: 2 * 3600 + 45 * 60, warning: false) == "PEAK 2h45m")
        check("menu bar title with warning",
              Format.menuBarTitle(phase: .offpeak, remaining: 3600 + 5 * 60, warning: true) == "⚠ OFF-PEAK 1h05m")
        // 12-hour clock.  Noon and midnight are the classic off-by-one traps:
        // 12:xx is PM and 00:xx is 12 AM, neither of which falls out of a
        // naive `hour % 12`.
        check("Beijing 09:00 → 9:00 AM",
              Format.clockString(utcDate(2026, 8, 24, 1, 0), offsetSeconds: 8 * 3600) == "9:00 AM")
        check("Beijing 12:00 → 12:00 PM, not 0:00 PM",
              Format.clockString(utcDate(2026, 8, 24, 4, 0), offsetSeconds: 8 * 3600) == "12:00 PM")
        check("Beijing 00:00 → 12:00 AM, not 0:00 AM",
              Format.clockString(utcDate(2026, 8, 23, 16, 0), offsetSeconds: 8 * 3600) == "12:00 AM")
        check("Beijing 13:00 → 1:00 PM",
              Format.clockString(utcDate(2026, 8, 24, 5, 0), offsetSeconds: 8 * 3600) == "1:00 PM")
        check("Beijing 23:59 → 11:59 PM",
              Format.clockString(utcDate(2026, 8, 24, 15, 59), offsetSeconds: 8 * 3600) == "11:59 PM")
        check("Beijing day and time",
              Format.dayAndTime(utcDate(2026, 8, 24, 1, 0), offsetSeconds: 8 * 3600) == "Mon 9:00 AM")
        check("negative offset still reads as a clock",
              Format.clockString(utcDate(2026, 8, 24, 1, 0), offsetSeconds: 0) == "1:00 AM")

        // Menu bar colour: red in peak, green in off-peak.  Both branches are
        // asserted here because the app's own self-test can only ever exercise
        // whichever phase happens to be current when it runs.
        check("peak title is red",
              StatusItemController.menuBarColor(for: .peak) == .systemRed)
        check("off-peak title is green",
              StatusItemController.menuBarColor(for: .offpeak) == .systemGreen)
        check("the two colours differ",
              StatusItemController.menuBarColor(for: .peak) != StatusItemController.menuBarColor(for: .offpeak))
    }
}
