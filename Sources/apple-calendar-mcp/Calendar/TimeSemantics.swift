// Parsing and formatting the time values that cross the MCP boundary.
//
// Calendars are where time-handling shortcuts go to die, so every rule here is explicit and
// each exists because the obvious alternative is wrong:
//
//   - Offsets are REQUIRED on input. "2026-09-03T14:00" means different instants in different
//     places, and guessing the caller's zone silently produces an off-by-hours answer.
//   - Intervals are half-open [start, end) and match by OVERLAP, mirroring
//     predicateForEventsWithStartDate:endDate:. A meeting straddling the window edge is IN.
//   - All-day events are date-only and never round-tripped through UTC, which shifts the
//     calendar date either side of midnight depending on the observer's offset.

import Foundation

enum TimeError: Error, CustomStringConvertible {
    case badTimestamp(String)
    case badTimeZone(String)
    case endNotAfterStart
    case intervalTooLong(days: Int, max: Int)

    var description: String {
        switch self {
        case .badTimestamp(let v):
            return "not an RFC 3339 timestamp with an explicit offset: \(v). "
                + "Example: 2026-09-03T14:00:00-06:00"
        case .badTimeZone(let v):
            return "not an IANA time zone identifier: \(v). Example: America/Denver"
        case .endNotAfterStart:
            return "end must be after start"
        case .intervalTooLong(let days, let max):
            return "interval is \(days) days; the maximum is \(max). Narrow the window."
        }
    }
}

enum TimeSemantics {

    /// The machine's current time zone, tracked LIVE.
    ///
    /// `TimeZone.current` is a snapshot taken at first access. This server is long-running --
    /// a client keeps it alive for the whole session -- so with `.current` a user who flies
    /// from Denver to London would keep seeing times in Denver's offset until the process was
    /// restarted, with nothing to indicate it. `autoupdatingCurrent` follows the OS, so
    /// crossing a time zone (or a DST boundary) is picked up with no action from anyone.
    static var systemZone: TimeZone { TimeZone.autoupdatingCurrent }

    /// RFC 3339 with an explicit offset. Fractional seconds accepted, not required.
    static func parseTimestamp(_ raw: String) throws -> Date {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: raw) { return d }

        // Deliberately NOT falling back to a zone-less parse. A timestamp without an offset
        // is ambiguous, and resolving it against the machine's zone is the kind of guess that
        // produces an answer that looks right and is an hour out twice a year.
        throw TimeError.badTimestamp(raw)
    }

    /// RFC 3339 rendered in the machine's CURRENT zone, with a real offset.
    ///
    /// `ISO8601DateFormatter` defaults to GMT, so the previous version emitted `20:53:20Z`
    /// for a 2:53pm Denver meeting. The instant was right and the output was unreadable, and
    /// a reader converting it by hand is a reader who will get it wrong.
    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = systemZone
        return f.string(from: date)
    }

    /// All-day events are date-only. Formatting one as an instant invites the reader to
    /// convert it, which is precisely the bug.
    static func formatAllDay(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func parseTimeZone(_ raw: String?) throws -> TimeZone {
        guard let raw else { return systemZone }
        guard let zone = TimeZone(identifier: raw) else { throw TimeError.badTimeZone(raw) }
        return zone
    }

    /// Validate a query window. Returns the interval in days for the error message.
    static func validateInterval(start: Date, end: Date, maxDays: Int) throws {
        guard end > start else { throw TimeError.endNotAfterStart }
        let days = Int(end.timeIntervalSince(start) / 86_400)
        guard days <= maxDays else { throw TimeError.intervalTooLong(days: days, max: maxDays) }
    }

    /// Half-open overlap: the event touches [windowStart, windowEnd) at some point.
    ///
    /// Note this matches EventKit's own predicate rather than testing containment. An event
    /// running 13:00-15:00 overlaps a 14:00-16:00 window and must be returned -- a
    /// containment test would drop exactly the meeting a user is asking about.
    static func overlaps(eventStart: Date, eventEnd: Date,
                         windowStart: Date, windowEnd: Date) -> Bool {
        eventStart < windowEnd && eventEnd > windowStart
    }
}
