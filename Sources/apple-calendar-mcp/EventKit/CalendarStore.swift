// The ONLY file that imports EventKit. EK* objects never leave it.
//
// WHY A CUSTOM EXECUTOR RATHER THAN AN ACTOR + CONTINUATION BRIDGE
//
// EventKit's fetches are synchronous and blocking, and EK* objects are not thread-safe, so
// all of it has to happen on one dedicated thread. The obvious shape -- a plain actor whose
// methods `await withCheckedContinuation { queue.async { ... } }` -- looks right and is
// weaker than it appears: an actor releases its isolation at every suspension point, so two
// operations interleave freely and the actor guarantees nothing beyond protecting its own
// stored properties.
//
// Giving the actor a custom SerialExecutor backed by a dedicated queue changes that. The
// EventKit calls are synchronous, so they contain no suspension points, so the actor is
// genuinely non-reentrant for the duration of each operation. The blocking work never touches
// Swift's cooperative thread pool -- which matters, because a wide fetch parked on a
// cooperative thread can starve the protocol loop. And EKEventStore never crosses an
// isolation boundary, so strict concurrency passes honestly rather than via @unchecked.

import Foundation
import EventKit

/// Runs actor jobs on one dedicated dispatch queue.
///
/// Not the global concurrent pool: the point is a single thread that owns the EventKit store
/// for the process's lifetime.
final class DedicatedThreadExecutor: SerialExecutor {
    private let queue: DispatchQueue

    init(label: String) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { unowned.runSynchronously(on: executor) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

actor CalendarStore {
    private let executor = DedicatedThreadExecutor(label: "com.collierhmg.apple-calendar-mcp.eventkit")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    private let store = EKEventStore()

    // MARK: - Calendars

    func calendars(writableIds: Set<String>) -> [CalendarRef] {
        store.calendars(for: .event).map { cal in
            // `allowsContentModifications` is EventKit's own answer. `isImmutable` is NOT
            // consulted: its header says it governs renaming or deleting the calendar and
            // "does NOT imply that you cannot add events or reminders to the calendar".
            // Including it would reject calendars the user allowlisted that EventKit accepts.
            let permitted = cal.allowsContentModifications
            return CalendarRef(
                id: cal.calendarIdentifier,
                title: cal.title,
                sourceTitle: cal.source?.title ?? "",
                sourceType: Self.describe(cal.source?.sourceType),
                allowsContentModifications: permitted,
                isSubscribed: cal.isSubscribed,
                writable: permitted && writableIds.contains(cal.calendarIdentifier),
                trust: untrustedMarker)
        }
    }

    // MARK: - Events

    /// Fetch events overlapping [start, end), sorted deterministically.
    ///
    /// Returns everything matching plus the total, so the caller can distinguish "nothing
    /// found" from "stopped counting".
    func events(start: Date, end: Date, calendarIds: [String]?,
                includeFields: Set<String>, limit: Int) -> (items: [EventDTO], total: Int) {
        let all = store.calendars(for: .event)
        let scoped = calendarIds.map { ids in all.filter { ids.contains($0.calendarIdentifier) } }
        // nil means "every calendar"; an EMPTY array must mean "none", not "every". Passing
        // an empty array to the predicate would silently widen the search.
        if let scoped, scoped.isEmpty { return ([], 0) }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: scoped ?? all)
        let matched = store.events(matching: predicate)

        // EventKit guarantees no ordering, so sort explicitly with a deterministic
        // tie-breaker. Without the tie-breaker, two events at the same instant can swap
        // places between calls and a caller diffing results sees phantom changes.
        let sorted = matched.sorted { a, b in
            if a.startDate != b.startDate { return a.startDate < b.startDate }
            let at = a.title ?? "", bt = b.title ?? ""
            if at != bt { return at < bt }
            return (a.eventIdentifier ?? "") < (b.eventIdentifier ?? "")
        }

        return (sorted.prefix(limit).map { dto(from: $0, includeFields: includeFields) },
                sorted.count)
    }

    /// Merged busy periods. Titles never leave this function.
    func busyIntervals(start: Date, end: Date, calendarIds: [String]?) -> [BusyInterval] {
        let all = store.calendars(for: .event)
        let scoped = calendarIds.map { ids in all.filter { ids.contains($0.calendarIdentifier) } }
        if let scoped, scoped.isEmpty { return [] }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: scoped ?? all)

        // Availability decides what counts as busy, not mere existence. A declined meeting or
        // one marked free is not a commitment, and treating it as one is how an assistant
        // reports a full day that is actually open.
        let busy = store.events(matching: predicate).filter { event in
            if event.status == .canceled { return false }
            switch event.availability {
            case .free, .notSupported: return false
            default: return true
            }
        }

        let periods = busy.map { (start: $0.startDate!, end: $0.endDate!) }
            .sorted { $0.start < $1.start }

        var merged: [BusyInterval] = []
        for p in periods {
            if let last = merged.last, p.start <= last.end {
                merged[merged.count - 1] = BusyInterval(
                    start: last.start,
                    end: max(last.end, p.end),
                    eventCount: last.eventCount + 1)
            } else {
                merged.append(BusyInterval(start: p.start, end: p.end, eventCount: 1))
            }
        }
        return merged
    }

    // MARK: - Conversion

    private func dto(from event: EKEvent, includeFields: Set<String>) -> EventDTO {
        let zone = event.isAllDay ? nil : (event.timeZone?.identifier ?? TimeZone.current.identifier)
        return EventDTO(
            id: event.eventIdentifier ?? "",
            occurrenceDate: event.hasRecurrenceRules ? event.occurrenceDate : nil,
            calendarId: event.calendar?.calendarIdentifier ?? "",
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            timeZone: zone,
            status: Self.describe(event.status),
            availability: Self.describe(event.availability),
            isRecurring: event.hasRecurrenceRules,
            isDetached: event.isDetached,
            hasAttendees: event.hasAttendees,
            notes: includeFields.contains("notes") ? event.notes : nil,
            url: includeFields.contains("url") ? event.url?.absoluteString : nil,
            location: includeFields.contains("location") ? event.location : nil,
            attendeeCount: includeFields.contains("attendee_count") ? (event.attendees?.count ?? 0) : nil,
            organizerName: includeFields.contains("organizer_name") ? event.organizer?.name : nil,
            trust: untrustedMarker)
    }

    private static func describe(_ status: EKEventStatus) -> String {
        switch status {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ availability: EKEventAvailability) -> String {
        switch availability {
        case .notSupported: return "not_supported"
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ sourceType: EKSourceType?) -> String {
        switch sourceType {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "caldav"
        case .mobileMe: return "mobileme"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        default: return "unknown"
        }
    }
}
