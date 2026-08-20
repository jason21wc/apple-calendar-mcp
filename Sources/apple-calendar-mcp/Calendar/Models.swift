// Immutable data-transfer objects.
//
// These are the ONLY calendar types that cross out of the EventKit adapter. EK* objects stay
// behind that boundary: they are not thread-safe, they go stale after a store change
// notification, and their identifiers move under you on sync.
//
// Every field here is derived from a header-verified fact. Where a value looks oddly typed --
// a nullable time zone, an approximate occurrence count -- the comment says which fact forced
// it, because the obvious type is wrong in each case.

import Foundation

/// Calendar text is written by other people. Invitations arrive from strangers and carry
/// attacker-chosen titles, notes, locations and names. Every payload says so explicitly, so a
/// model reading it has no excuse for treating it as instruction.
let untrustedMarker = "external_untrusted"

struct CalendarRef: Codable, Sendable, Hashable {
    let id: String
    let title: String
    let sourceTitle: String
    let sourceType: String
    /// Whether EventKit itself permits adding or changing items here. Subscribed, holiday and
    /// birthday calendars report false.
    let allowsContentModifications: Bool
    let isSubscribed: Bool
    /// EventKit's permission AND our allowlist. `isImmutable` is deliberately NOT consulted:
    /// the header says it governs renaming or deleting the calendar and explicitly "does NOT
    /// imply that you cannot add events" -- including it would reject calendars the user
    /// allowlisted and EventKit accepts.
    let writable: Bool
    /// Why `writable` is false, when it is. Without this, a calendar reporting
    /// `allows_content_modifications: true` alongside `writable: false` reads as a
    /// contradiction rather than as "EventKit would allow it; the allowlist does not".
    let writableReason: String
    let trust: String

    enum CodingKeys: String, CodingKey {
        case id, title, trust
        case sourceTitle = "source_title"
        case sourceType = "source_type"
        case allowsContentModifications = "allows_content_modifications"
        case isSubscribed = "is_subscribed"
        case writable
        case writableReason = "writable_reason"
    }
}

// DATES ARE STRINGS HERE, DELIBERATELY.
//
// Swift's default Codable encoding for `Date` is a NUMBER -- seconds since the 2001 reference
// date -- so a `Date` field silently violates a schema promising a string. The MCP SDK
// validates structuredContent against outputSchema in memory, before serialization, using an
// encoder we do not configure, so there is no encoder setting to reach for.
//
// Formatting at construction makes the wire format explicit and impossible to get wrong by
// forgetting a strategy somewhere.
struct EventDTO: Codable, Sendable, Hashable {
    let id: String
    /// The stable key for one occurrence of a recurring series. `EKEvent.occurrenceDate`
    /// "will remain the same even if the event has been detached and its start date has
    /// changed", which is exactly why start date cannot be used for this. Null for
    /// non-recurring events.
    let occurrenceDate: String?
    let calendarId: String
    let title: String
    /// RFC 3339 with an explicit offset, rendered in the machine's current zone.
    ///
    /// TWO CONVENTIONS MEET HERE, so read carefully. Query windows are half-open --
    /// `[start, end)` -- but EventKit stores an all-day event's `end` INCLUSIVELY, as
    /// 23:59:59 on the final day. A one-day all-day event on the 20th therefore reports
    /// `end: 2026-08-20T23:59:59-06:00`, not midnight on the 21st.
    ///
    /// This is reported as EventKit stores it rather than normalised, because rewriting it to
    /// an exclusive midnight would misstate what is actually in the user's calendar. Anything
    /// computing durations across all-day events must account for the missing second.
    let start: String
    let end: String
    let isAllDay: Bool
    /// For all-day events ONLY: the calendar date in the effective time zone, `YYYY-MM-DD`.
    ///
    /// `all_day_end_date` is the LAST day the event covers, inclusive -- an event spanning
    /// the 20th to the 22nd reports `2026-08-22`, matching how a human reads "20th-22nd" and
    /// how EventKit stores it. Deliberately NOT the exclusive convention used by query
    /// windows; a consumer that assumes exclusivity will be a day short.
    ///
    /// Both are provided because neither alone is safe. The instant is machine-comparable but
    /// renders as the wrong DAY for anyone in a different zone -- the classic all-day bug,
    /// where a midnight boundary moves the date. The date string is correct to display but
    /// cannot be ordered against timed events. Use `is_all_day` to choose.
    let allDayStartDate: String?
    let allDayEndDate: String?
    /// The event's OWN time zone, as stored -- not the zone it is being displayed in.
    ///
    /// Null means the event floats with whatever zone the machine is in: a 9am local meeting
    /// stays 9am wherever you are. Non-null means it is PINNED, e.g. a call created in
    /// America/New_York stays at that New York instant no matter where you travel.
    ///
    /// That distinction is the whole travel question. `start` always renders in your current
    /// zone; this field says whether the event itself moves with you.
    ///
    /// Also null for all-day events, which have no time zone at all.
    let timeZone: String?
    let status: String
    let availability: String
    let isRecurring: Bool
    /// True when this occurrence's attributes differ from the series default -- NOT when an
    /// occurrence has been deleted, which produces an exclusion rather than a detached event.
    let isDetached: Bool
    /// A boolean, never the attendee list. `attendees` is readonly in EventKit and is
    /// withheld by default anyway; the count of people involved is what a scheduling decision
    /// actually needs.
    let hasAttendees: Bool

    // Opt-in only, via `include_fields`. Withheld by default because they are the richest
    // source of attacker-controlled text and the least often needed.
    let notes: String?
    let url: String?
    let location: String?
    let attendeeCount: Int?
    let organizerName: String?

    let trust: String

    /// Hand-written so nullable-by-nature fields emit an explicit `null`, while fields the
    /// caller did not request are simply ABSENT.
    ///
    /// Swift's synthesized encoder omits every nil optional, which erases that distinction.
    /// It matters: `occurrence_date: null` means "this event does not recur", whereas a
    /// missing `notes` means "you did not ask for notes" -- not "this event has none".
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(calendarId, forKey: .calendarId)
        try c.encode(title, forKey: .title)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(isAllDay, forKey: .isAllDay)
        try c.encode(status, forKey: .status)
        try c.encode(availability, forKey: .availability)
        try c.encode(isRecurring, forKey: .isRecurring)
        try c.encode(isDetached, forKey: .isDetached)
        try c.encode(hasAttendees, forKey: .hasAttendees)
        try c.encode(trust, forKey: .trust)

        // Always present, null when not applicable.
        try c.encode(occurrenceDate, forKey: .occurrenceDate)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encode(allDayStartDate, forKey: .allDayStartDate)
        try c.encode(allDayEndDate, forKey: .allDayEndDate)

        // Present only when requested.
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(attendeeCount, forKey: .attendeeCount)
        try c.encodeIfPresent(organizerName, forKey: .organizerName)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, start, end, status, availability, notes, url, location, trust
        case occurrenceDate = "occurrence_date"
        case calendarId = "calendar_id"
        case isAllDay = "is_all_day"
        case allDayStartDate = "all_day_start_date"
        case allDayEndDate = "all_day_end_date"
        case timeZone = "time_zone"
        case isRecurring = "is_recurring"
        case isDetached = "is_detached"
        case hasAttendees = "has_attendees"
        case attendeeCount = "attendee_count"
        case organizerName = "organizer_name"
    }
}

/// A merged busy period. Titles are deliberately absent: "when am I free" is answerable
/// without disclosing what the commitments are, and that is the whole point of the tool.
struct BusyInterval: Codable, Sendable, Hashable {
    /// RFC 3339 strings for the same reason as EventDTO: a `Date` encodes as a number.
    let start: String
    let end: String
    /// How many events contributed. Useful for spotting double-bookings without naming them.
    let eventCount: Int

    enum CodingKeys: String, CodingKey {
        case start, end
        case eventCount = "event_count"
    }
}

/// Wraps every read result.
///
/// `truncated` and `totalMatched` exist so a caller can tell "you are free" from "I stopped
/// looking". Silent truncation is how a scheduling assistant confidently books over
/// something.
struct ReadEnvelope<Item: Codable & Sendable>: Codable, Sendable {
    let items: [Item]
    let truncated: Bool
    let totalMatched: Int
    /// The zone `start` and `end` were rendered in: the machine's CURRENT zone, tracked live.
    /// Travel and it changes with no restart.
    let effectiveTimeZone: String
    let limitsApplied: LimitsApplied
    let trust: String

    enum CodingKeys: String, CodingKey {
        case items, truncated, trust
        case totalMatched = "total_matched"
        case effectiveTimeZone = "effective_time_zone"
        case limitsApplied = "limits_applied"
    }
}

struct LimitsApplied: Codable, Sendable, Hashable {
    let limit: Int
    let maxIntervalDays: Int

    enum CodingKeys: String, CodingKey {
        case limit
        case maxIntervalDays = "max_interval_days"
    }
}
