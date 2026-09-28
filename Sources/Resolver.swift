//
//  Resolver.swift
//  Peakbar
//
//  The pure phase predicate and the next-change walk.  See ARCHITECTURE.md
//  §4.2 and §4.3.
//
//  `Resolver` is pure over an instant: no clock, no I/O, no network, no
//  mutable state.  It consumes a `HolidayTable` value; `HolidaySource` is the
//  thing that produces one.  This is what makes the phase path impossible to
//  block and the tests deterministic (§4.2, §6 case 27).
//

import Foundation

struct Resolver {

    /// Search ceiling for the next-change walk.  A *bound*, not a distance
    /// travelled and not a fetch cadence (§4.3, §5.1).  The longest reachable
    /// off-peak stretch is a holiday block ending on a Monday: last peak
    /// Friday 18:00 → next peak Tuesday 09:00 = 10.63 days, so the reference's
    /// 10 is not enough and 40 is.
    static let lookaheadDays = 40

    var schedule: Schedule
    var holidays: HolidayTable

    init(schedule: Schedule, holidays: HolidayTable) {
        self.schedule = schedule
        self.holidays = holidays
    }

    // MARK: - Calendar helpers

    /// The civil date in the schedule's calendar (UTC+8 for Asia/Shanghai).
    ///
    /// This is the load-bearing shift of §6 case 1: the weekday must be read
    /// off this date, never off the UTC instant.
    func beijingDay(at date: Date) -> Day {
        Day.from(date: date, offsetHours: schedule.calendarUTCOffsetHours)
    }

    /// Minute-of-day on the *UTC* clock, which is what the window test uses.
    func utcMinuteOfDay(_ date: Date) -> Int {
        floorMod(Int(date.timeIntervalSince1970.rounded(.down)), 86_400) / 60
    }

    /// The UTC midnight at or before `date`.
    func utcStartOfDay(_ date: Date) -> Date {
        let t = Int(date.timeIntervalSince1970.rounded(.down))
        return Date(timeIntervalSince1970: TimeInterval(t - floorMod(t, 86_400)))
    }

    /// True when the UTC minute-of-day falls in any peak window, half-open
    /// `start <= m < end` (§4.2, §6 case 4).
    func inPeakWindow(_ date: Date) -> Bool {
        let m = utcMinuteOfDay(date)
        for w in schedule.peakWindowsUTC where w.contains(minuteOfDay: m) {
            return true
        }
        return false
    }

    /// The **display** staleness flag: true when a year the app is currently
    /// putting a number on screen for is not vouched for by the holiday table.
    ///
    /// Two different notions of staleness live in this type, and the
    /// distinction is easy to lose:
    ///
    /// * `classify(at:)` uses **per-candidate** staleness.  A candidate whose
    ///   own Beijing year is uncovered skips holiday subtraction and degrades
    ///   to assume-peak.  That is the A6/A14 fail-safe; it is evaluated on the
    ///   candidate instant, and this flag does not touch it.
    /// * `Resolution.stale`, this function, answers a different question:
    ///   "may any number on screen be wrong?"  So it covers the **countdown
    ///   target** as well as "now" (§4.1).
    ///
    /// Why the target matters.  At 2026-12-31 18:00 Beijing the current year is
    /// covered, so a now-only flag stays silent, but the countdown is computed
    /// from 2027-01-01 09:00, and 2027 is not covered.  2027-01-01 is 元旦 and
    /// a Friday, so with 2027 covered the real next change is 2027-01-04 09:00:
    /// the holiday plus the weekend.  The countdown is wrong by three days and
    /// the app would say nothing.  A warning flag with a known blind spot is
    /// worse than no flag, because its absence implies coverage it does not
    /// have.
    ///
    /// The phase itself is never affected by this flag.
    func isStale(now: Date, nextChangeTarget: Date) -> Bool {
        let currentYear = beijingDay(at: now).year
        let targetYear = beijingDay(at: nextChangeTarget).year
        return !holidays.coveredYears.contains(currentYear)
            || !holidays.coveredYears.contains(targetYear)
    }

    // MARK: - Phase predicate

    /// The predicate of §4.2, returning the phase together with the reason.
    ///
    /// The effective-date gate is evaluated on `at`, the candidate, never
    /// once on "now" (§6 case 3, A9).
    func classify(at date: Date) -> (phase: Phase, basis: Basis) {
        let day = beijingDay(at: date)
        let weekday = day.isoWeekday
        let effective = date >= schedule.weekendOffpeakEffectiveUTC
        let stale = !holidays.coveredYears.contains(day.year)
        let inWindow = inPeakWindow(date)

        if effective {
            // Weekend rule first: it supersedes make-up workdays (§6 case 6).
            if !schedule.peakWeekdays.contains(weekday) {
                return (.offpeak, .weekend)
            }
            // Holiday subtraction, but only when the year is vouched for.
            if !stale && holidays.daysOff.contains(day) {
                return (.offpeak, .holiday)
            }
            if inWindow {
                // On a stale year the holiday table is skipped, so a peak
                // answer here is an assumption, not a fact (§4.2, A6).
                return (.peak, stale ? .assumedPeak : .window)
            }
            return (.offpeak, .window)
        }

        // Before the effective instant only the window test runs: the rule is
        // not retroactive, so a pre-rule Saturday inside a window is peak.
        return (inWindow ? .peak : .offpeak, .window)
    }

    /// `Resolver.phase(at:) -> Phase`, pure.
    func phase(at date: Date) -> Phase {
        classify(at: date).phase
    }

    /// The full resolution for an instant, including both warning flags.
    func resolve(at date: Date) -> Resolution {
        resolve(at: date, nextChangeTarget: nextChange(at: date).date)
    }

    /// As `resolve(at:)`, but with the next-change target supplied so a caller
    /// that has already computed it does not pay for the walk twice.
    /// `StatusModel.refresh()` is that caller: it needs the target for the
    /// countdown regardless.
    func resolve(at date: Date, nextChangeTarget: Date) -> Resolution {
        let (phase, basis) = classify(at: date)
        return Resolution(phase: phase,
                          basis: basis,
                          stale: isStale(now: date, nextChangeTarget: nextChangeTarget),
                          sourceWarning: holidays.sourceWarning)
    }

    // MARK: - Next change

    /// The candidate edges the phase can change on: every window edge, plus
    /// the Beijing midnight (the only place the calendar day, and therefore
    /// the weekday and the holiday test, flips).
    ///
    /// Beijing midnight is `((24 - offset) % 24) * 60` minutes past UTC
    /// midnight: 960 minutes, i.e. 16:00 UTC, for UTC+8.
    func candidateMinuteOffsets() -> [Int] {
        var set = Set<Int>()
        for w in schedule.peakWindowsUTC {
            set.insert(w.startMinute)
            set.insert(w.endMinute)
        }
        set.insert(((24 - schedule.calendarUTCOffsetHours) % 24) * 60)
        return set.filter { $0 >= 0 && $0 < 1440 }.sorted()
    }

    /// `Resolver.nextChange(at:) -> (Date, Phase)`, pure.
    ///
    /// Walks the candidate edges forward and compares the phase on either
    /// side.  Weekend- and holiday-resident edges produce no change and are
    /// skipped *without being special-cased*: that is the whole trick of §4.3
    /// and §6 case 2.
    func nextChange(at date: Date) -> (date: Date, phase: Phase) {
        let now = phase(at: date)
        let offsets = candidateMinuteOffsets()
        let day0 = utcStartOfDay(date)

        for d in 0..<Resolver.lookaheadDays {
            let dayBase = day0.addingTimeInterval(TimeInterval(d * 86_400))
            for e in offsets {
                let candidate = dayBase.addingTimeInterval(TimeInterval(e * 60))
                if candidate <= date { continue }
                let p = phase(at: candidate)
                if p != now { return (candidate, p) }
            }
        }
        // Unreachable for any non-wrapping schedule: the bound exceeds the
        // longest possible off-peak stretch (§4.3).
        return (date, now)
    }

    // NOTE on `stale`.  §4.1's flag table defines it as "a year required now,
    // *or by the next-boundary lookahead*, is not in `coveredYears`", while
    // §4.2's predicate and §3.4's factual claim key on the current Beijing year
    // alone.  §4.1 is the definition of the flag, and the wider reading is the
    // correct one: the countdown is a number on screen and it can be wrong for
    // days before the current year rolls over, so `Resolution.stale`
    // implements the union (§4.1).
    //
    // §4.2 stays authoritative for the *predicate*: `classify(at:)` keeps
    // per-candidate staleness, so a candidate in an uncovered year still skips
    // holiday subtraction and degrades to assume-peak.  Widening the display
    // flag must never widen the fail-safe.  The two are independent, and only
    // the flag changed here.
}
