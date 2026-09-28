//
//  Holiday.swift
//  Peakbar
//
//  The holiday data pipeline: the `Transport` seam, the iCalendar parser, and
//  `HolidaySource`: the two-source chain with its cache and needs-based
//  fetch policy.  See ARCHITECTURE.md §3.3, §3.4 and §5.1.
//
//  All I/O lives here.  `HolidaySource` produces a `HolidayTable` value;
//  `Resolver` consumes one.  The phase path therefore never blocks (§4.2).
//

import Foundation

// MARK: - Transport

/// A minimal HTTP response.
struct HTTPResponse {
    let statusCode: Int
    let body: Data?
    let lastModified: String?
    let etag: String?
}

enum TransportError: Error, Equatable {
    case network(String)
    case http(Int)
}

enum TransportResult {
    case success(HTTPResponse)
    case notModified
    case failure(TransportError)
}

/// The single network seam (§4.4).  Everything above it is pure.
protocol Transport {
    func get(url: URL, ifModifiedSince: String?, ifNoneMatch: String?) -> TransportResult
}

extension Transport {
    /// The two-argument shape named in §4.1's class diagram.
    func get(url: URL, ifModifiedSince: String?) -> TransportResult {
        get(url: url, ifModifiedSince: ifModifiedSince, ifNoneMatch: nil)
    }
}

/// The real transport: one conditional HTTPS GET, synchronous, meant to be
/// called from a background queue (§5.1).
///
/// The session is created **on first use**, not at init.  Touching
/// `URLSession.shared` initialises CFNetwork, which costs about 1.4 MB of
/// physical footprint. It is measurable, and pointless for the ~10 months a year
/// when no fetch is warranted.  The transport object itself is free to
/// construct.
final class URLSessionTransport: Transport {
    private var session: URLSession?
    private let injectedSession: URLSession?
    private let timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 30) {
        self.injectedSession = session
        self.timeout = timeout
    }

    private func currentSession() -> URLSession {
        if let injected = injectedSession { return injected }
        if let existing = session { return existing }
        let created = URLSession.shared
        session = created
        return created
    }

    func get(url: URL, ifModifiedSince: String?, ifNoneMatch: String?) -> TransportResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        if let ims = ifModifiedSince { request.setValue(ims, forHTTPHeaderField: "If-Modified-Since") }
        if let etag = ifNoneMatch { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let semaphore = DispatchSemaphore(value: 0)
        // `box.value` is written on the URLSession delegate queue and read
        // after the semaphore, which is a happens-before edge.
        let box = ResultBox()

        let task = currentSession().dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                box.value = .failure(.network(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                box.value = .failure(.network("no HTTP response"))
                return
            }
            switch http.statusCode {
            case 304:
                box.value = .notModified
            case 200:
                box.value = .success(HTTPResponse(
                    statusCode: 200,
                    body: data,
                    lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                    etag: http.value(forHTTPHeaderField: "ETag")
                ))
            default:
                box.value = .failure(.http(http.statusCode))
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 5)
        return box.value
    }
}

/// Small reference box so the completion handler can hand a value back across
/// the semaphore.
private final class ResultBox {
    var value: TransportResult = .failure(.network("no response"))
}

/// Test double: records every attempt and returns a canned result.  Never
/// touches the network (§4.4).
final class ManualTransport: Transport {
    var result: TransportResult

    private(set) var attempts: [(url: URL, ifModifiedSince: String?, ifNoneMatch: String?)] = []

    init(result: TransportResult = .failure(.network("offline"))) {
        self.result = result
    }

    func get(url: URL, ifModifiedSince: String?, ifNoneMatch: String?) -> TransportResult {
        attempts.append((url: url, ifModifiedSince: ifModifiedSince, ifNoneMatch: ifNoneMatch))
        return result
    }

    var attemptCount: Int { attempts.count }
    func reset() { attempts.removeAll() }
}

// MARK: - HolidaySource

/// Produces the `HolidayTable` the resolver consumes.
///
/// Precedence (§3.3): Apple China calendar (fetched, cached) > bundled floor.
/// The fetch is needs-based (§5.1): on launch, then at most once per 24 h and
/// only inside the year-end window, or when `stale` / `sourceWarning` is set.
///
/// **Not thread-safe.**  It owns mutable state (the current table, the
/// last-attempt instant and the conditional validators), so every call must
/// come from one queue.  `StatusModel` satisfies that by routing all fetches
/// through a single serial queue.
final class HolidaySource {

    /// The only outbound endpoint in the app (§8).
    static let calendarURL = URL(string: "https://calendars.icloud.com/holidays/cn_zh.ics")!

    /// 24 h between attempts once the launch fetch has happened (§5.1).
    static let minimumFetchInterval: TimeInterval = 86_400

    private let transport: Transport
    private let clock: Clock
    private let cacheURL: URL
    private let bundled: HolidayTable
    private let url: URL

    private(set) var currentTable: HolidayTable
    private var lastFetchAttempt: Date?
    private var lastModified: String?
    private var etag: String?

    init(transport: Transport,
         clock: Clock,
         cacheDirectory: URL,
         bundled: HolidayTable,
         url: URL = HolidaySource.calendarURL) {
        self.transport = transport
        self.clock = clock
        self.cacheURL = cacheDirectory.appendingPathComponent("cn_zh.ics")
        self.bundled = bundled
        self.url = url
        self.currentTable = bundled
        // Rank 1 (cache) if present and readable, else rank 2 (bundled).
        resolveTable()
    }

    var sourceWarning: Bool { currentTable.sourceWarning }

    // MARK: Cache

    private func readCache() -> String? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeCache(_ text: String) {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: cacheURL, options: .atomic)
        } catch {
            // A cache we cannot write is not fatal: the in-memory table is
            // already correct and the phase path is unaffected.
            FileHandle.standardError.write(Data("Peakbar: could not write holiday cache: \(error)\n".utf8))
        }
    }

    // MARK: Two-source resolution

    /// Builds the table from the cache and the bundled floor.
    ///
    /// - Valid cache: rank-1 union rank-2, no warning.
    /// - Present but malformed cache: fall back one rank (the bundled floor)
    ///   and raise `sourceWarning` (§3.3, §6 case 8).
    /// - No cache at all: the bundled floor, no warning, the expected
    ///   first-run state (§6 case 9).
    @discardableResult
    func resolveTable() -> HolidayTable {
        if let text = readCache() {
            if HolidaySource.isWellFormed(ics: text) {
                let cached = parse(ics: text)
                currentTable = cached.merge(lower: bundled).withSourceWarning(false)
            } else {
                // Fall back one rank and say so.
                currentTable = bundled.withSourceWarning(true)
            }
        } else {
            currentTable = bundled.withSourceWarning(false)
        }
        return currentTable
    }

    // MARK: Needs-based refresh

    /// Whether a fetch is warranted *right now*, ignoring the 24 h gate.
    /// Exposed for tests and for the menu's diagnostics.
    ///
    /// A launch does **not** force a fetch.  Fetching unconditionally at
    /// launch would initialise a network session on every start for a request
    /// that cannot change an answer: the bundled table already covers the
    /// current year for most of the year.  `isLaunch` is retained because it
    /// bypasses the 24 h gate when a fetch *is* warranted.
    func needsFetch(isLaunch: Bool, now: Date) -> Bool {
        let beijing = Day.from(date: now, offsetHours: 8)
        let inYearEndWindow = (beijing.month == 12 && beijing.day >= 15) || beijing.month == 1
        let stale = !currentTable.coveredYears.contains(beijing.year)
        return inYearEndWindow || stale || currentTable.sourceWarning
    }

    /// The whole §5.1 policy.  Synchronous: the app calls it from a background
    /// queue, the tests call it directly.  Returns the table in force
    /// afterwards.
    @discardableResult
    func refreshIfDue(isLaunch: Bool = false) -> HolidayTable {
        let now = clock.now()

        guard needsFetch(isLaunch: isLaunch, now: now) else { return currentTable }

        // "Fetch on launch, then at most once per 24 h". The gate applies to
        // everything except the launch fetch itself.
        if !isLaunch, let last = lastFetchAttempt,
           now.timeIntervalSince(last) < HolidaySource.minimumFetchInterval {
            return currentTable
        }

        lastFetchAttempt = now
        performFetch()
        return currentTable
    }

    /// The name used in §4.1's class diagram.
    @discardableResult
    func fetchIfDue() -> HolidayTable { refreshIfDue(isLaunch: false) }

    private func performFetch() {
        let result = transport.get(url: url, ifModifiedSince: lastModified, ifNoneMatch: etag)

        switch result {
        case .notModified:
            // Cache is still current.  Nothing to do, no warning.
            break

        case .failure:
            // No network: keep the cache unchanged.  Sets *neither* flag:
            // the cache is still the best available source (§3.3, §6 case 20).
            break

        case .success(let response):
            guard let data = response.body,
                  let text = String(data: data, encoding: .utf8),
                  HolidaySource.isWellFormed(ics: text) else {
                // A payload arrived but is unreadable: fall back one rank (the
                // cache, i.e. leave the table as it is) and raise the warning
                // (§3.3, §6 case 21).
                currentTable = currentTable.withSourceWarning(true)
                return
            }
            lastModified = response.lastModified ?? lastModified
            etag = response.etag ?? etag
            writeCache(text)
            let fetched = parse(ics: text)
            currentTable = fetched.merge(lower: bundled).withSourceWarning(false)
        }
    }

    // MARK: Parsing

    /// Cheap structural sanity check.  A truncated download is missing its
    /// closing markers and must not be allowed to overwrite a good cache
    /// (§6 case 21).
    static func isWellFormed(ics: String) -> Bool {
        ics.contains("BEGIN:VCALENDAR")
            && ics.contains("END:VCALENDAR")
            && ics.contains("BEGIN:VEVENT")
            && ics.contains("END:VEVENT")
    }

    /// The source label attached to tables parsed from the Apple calendar.
    static let appleSourceLabel = "Apple 中国大陆节假日 (calendars.icloud.com)"

    /// Pure function of the ICS text (§3.4).
    ///
    /// Discriminates **only** on `X-APPLE-SPECIAL-DAY`.  `WORK-HOLIDAY` events
    /// contribute days off (DTSTART→DTEND, **DTEND exclusive**);
    /// `ALTERNATE-WORKDAY` events contribute make-up workdays; everything else
    /// , the 206 cultural and solar-term events, is ignored (§3.4, §6
    /// cases 22/23).
    ///
    /// `covered_years` is derived from the data, not from the file's span: a
    /// year counts only if a `WORK-HOLIDAY` event lands in it.  A year with
    /// cultural events but no `WORK-HOLIDAY` event is *uncovered*, not
    /// holiday-free (§3.4, §6 case 22).
    func parse(ics: String) -> HolidayTable {
        var daysOff = Set<Day>()
        var makeup = Set<Day>()
        var covered = Set<Int>()

        var inEvent = false
        var fields: [String: String] = [:]

        func finishEvent() {
            guard let special = fields["X-APPLE-SPECIAL-DAY"] else { return }

            let start = fields["DTSTART"].flatMap(Day.parseICSDate)
            let end = fields["DTEND"].flatMap(Day.parseICSDate)

            switch special {
            case "WORK-HOLIDAY":
                guard let start = start else { return }
                if let end = end {
                    // DTEND is exclusive: 20260215 → 20260224 is Feb 15–23.
                    var cursor = start
                    while cursor < end {
                        daysOff.insert(cursor)
                        cursor = cursor.nextDay
                    }
                    // The year the arrangement concludes in.  For the one
                    // range that straddles New Year (2023-12-30 → 2024-01-02,
                    // the 元旦 2024 block) this attributes it to 2024, which
                    // is the year the arrangement names.
                    covered.insert(end.previousDay.year)
                } else {
                    // A missing DTEND is a single day, not an open range.
                    daysOff.insert(start)
                    covered.insert(start.year)
                }

            case "ALTERNATE-WORKDAY":
                guard let start = start else { return }
                if let end = end {
                    var cursor = start
                    while cursor < end {
                        makeup.insert(cursor)
                        cursor = cursor.nextDay
                    }
                } else {
                    makeup.insert(start)
                }

            default:
                // Any other value (or none) is not a discriminator we act on.
                break
            }
        }

        for line in HolidaySource.unfold(ics) {
            if line == "BEGIN:VEVENT" {
                inEvent = true
                fields.removeAll(keepingCapacity: true)
            } else if line == "END:VEVENT" {
                if inEvent { finishEvent() }
                inEvent = false
                fields.removeAll(keepingCapacity: true)
            } else if inEvent {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let left = String(line[line.startIndex..<colon])
                let value = String(line[line.index(after: colon)...])
                let name = left.split(separator: ";").first.map(String.init) ?? left
                // First occurrence wins; iCalendar properties are unique per
                // component in practice.
                if fields[name] == nil { fields[name] = value }
            }
        }

        return HolidayTable(daysOff: daysOff,
                            makeupWorkdays: makeup,
                            coveredYears: covered,
                            source: HolidaySource.appleSourceLabel)
    }

    /// Splits the ICS into logical lines, undoing RFC 5545 line folding (a
    /// continuation line begins with a space or a tab).
    static func unfold(_ ics: String) -> [String] {
        let normalised = ics.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let first = line.first, first == " " || first == "\t" {
                if !lines.isEmpty {
                    lines[lines.count - 1] += String(line.dropFirst())
                } else {
                    lines.append(String(line.dropFirst()))
                }
            } else {
                lines.append(line)
            }
        }
        return lines
    }
}
