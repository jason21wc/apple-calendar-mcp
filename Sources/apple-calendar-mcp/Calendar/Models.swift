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
    let trust: String

    enum CodingKeys: String, CodingKey {
        case id, title, trust
        case sourceTitle = "source_title"
        case sourceType = "source_type"
        case allowsContentModifications = "allows_content_modifications"
        case isSubscribed = "is_subscribed"
        case writable
    }
}

struct EventDTO: Codable, Sendable, Hashable {
    let id: String
    /// The stable key for one occurrence of a recurring series. `EKEvent.occurrenceDate`
    /// "will remain the same even if the event has been detached and its start date has
    /// changed", which is exactly why start date cannot be used for this. Null for
    /// non-recurring events.
    let occurrenceDate: Date?
    let calendarId: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// NULLABLE on purpose: an all-day event has no time zone. A non-optional field here
    /// would force a fabricated value into exactly the case where time zones cause bugs.
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

    enum CodingKeys: String, CodingKey {
        case id, title, start, end, status, availability, notes, url, location, trust
        case occurrenceDate = "occurrence_date"
        case calendarId = "calendar_id"
        case isAllDay = "is_all_day"
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
    let start: Date
    let end: Date
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
