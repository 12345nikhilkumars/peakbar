//
//  ConformanceTests.swift
//  Peakbar
//
//  The 20 CC0 conformance vectors: 15 `phase_at`, 3 `next_boundary`, and 2
//  `config_check` (one per schedule in the vendored file).
//
//  The suite is used unmodified from
//  github.com/xyzs996/deepseek-peak-hours (CC0-1.0).  See NOTICE.
//

import Foundation

func runConformanceTests() {
    section("Conformance: CC0 suite (20 vectors)")

    guard let root = loadVectorsRoot(),
          let schedulesRaw = root["schedules"] as? [String: [String: Any]],
          let phaseVectors = root["vectors"] as? [[String: Any]],
          let boundaryVectors = root["next_boundary_vectors"] as? [[String: Any]] else {
        check("vectors.json is readable", false, "missing or malformed")
        return
    }

    let holidays = loadBundledHolidays()

    func schedule(named name: String) -> Schedule? {
        guard let raw = schedulesRaw[name],
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return Schedule.parse(data: data)
    }

    // ---------------------------------------------------------------- config
    // Two config checks, one per schedule in the file.

    if let live = schedule(named: "deepseek-live-2026-08-23") {
        let windowsOK = live.peakWindowsUTC == [
            Window(startMinute: 60, endMinute: 240),
            Window(startMinute: 360, endMinute: 600)
        ]
        check("config_check[deepseek-live-2026-08-23]",
              live.calendarTimezone == "Asia/Shanghai"
                && live.calendarUTCOffsetHours == 8
                && live.peakWeekdays == [1, 2, 3, 4, 5]
                && windowsOK
                && live.offpeakMultiplier == 0.5
                && abs(live.weekendOffpeakEffectiveUTC.timeIntervalSince1970 - 1_787_414_400) < 0.5,
              "tz=\(live.calendarTimezone) offset=\(live.calendarUTCOffsetHours) weekdays=\(live.peakWeekdays.sorted()) windows=\(live.peakWindowsUTC)")
    } else {
        check("config_check[deepseek-live-2026-08-23]", false, "schedule did not parse")
    }

    if let synthetic = schedule(named: "synthetic-overnight-peak") {
        check("config_check[synthetic-overnight-peak]",
              synthetic.calendarTimezone == "Asia/Shanghai"
                && synthetic.calendarUTCOffsetHours == 8
                && synthetic.peakWeekdays == [1, 2, 3, 4, 5]
                && synthetic.peakWindowsUTC == [Window(startMinute: 960, endMinute: 1320)]
                && synthetic.offpeakMultiplier == 0.5,
              "windows=\(synthetic.peakWindowsUTC)")
    } else {
        check("config_check[synthetic-overnight-peak]", false, "schedule did not parse")
    }

    // The shipped schedule must be the live one; otherwise every other test
    // here could pass while the app bills off a stale config.
    if let live = schedule(named: "deepseek-live-2026-08-23") {
        check("shipped Resources/schedule.json equals the live vector schedule",
              loadShippedSchedule() == live)
    }

    // ------------------------------------------------------------ phase_at
    for (index, vector) in phaseVectors.enumerated() {
        guard let scheduleName = vector["schedule"] as? String,
              let atString = vector["at_utc"] as? String,
              let expected = vector["expect"] as? String,
              let at = parseISO(atString),
              let sched = schedule(named: scheduleName) else {
            check("phase_at[\(index)] parses", false, "malformed vector")
            continue
        }
        let resolver = Resolver(schedule: sched, holidays: holidays)
        let got = resolver.phase(at: at).rawValue
        let local = (vector["beijing_local"] as? String) ?? ""
        check("phase_at[\(index)] \(scheduleName) @ \(atString) (\(local))",
              got == expected,
              "expected \(expected), got \(got)")
    }

    // ------------------------------------------------------ next_boundary
    for (index, vector) in boundaryVectors.enumerated() {
        guard let scheduleName = vector["schedule"] as? String,
              let fromString = vector["from_utc"] as? String,
              let expectedChangeString = vector["expect_next_change_utc"] as? String,
              let expectedPhase = vector["expect_next_phase"] as? String,
              let from = parseISO(fromString),
              let expectedChange = parseISO(expectedChangeString),
              let sched = schedule(named: scheduleName) else {
            check("next_boundary[\(index)] parses", false, "malformed vector")
            continue
        }
        let resolver = Resolver(schedule: sched, holidays: holidays)
        let (change, phase) = resolver.nextChange(at: from)
        let delta = change.timeIntervalSince(expectedChange)
        check("next_boundary[\(index)] \(scheduleName) from \(fromString) → \(expectedChangeString)",
              abs(delta) < 0.5 && phase.rawValue == expectedPhase,
              "expected \(expectedChangeString)/\(expectedPhase), got \(ISO8601DateFormatter().string(from: change))/\(phase.rawValue)")
    }

    note("\(phaseVectors.count) phase_at + \(boundaryVectors.count) next_boundary + 2 config_check")
}
