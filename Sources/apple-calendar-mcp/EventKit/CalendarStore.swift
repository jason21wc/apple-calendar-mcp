// The only file that touches calendar CONTENT. EK* objects never leave it.
//
// Three other files import EventKit -- main.swift, AuthorizationState and SetupFlow -- but
// only for the authorization API (`EKAuthorizationStatus`, `authorizationStatus(for:)`,
// `requestFullAccessToEvents`). No EKEvent or EKCalendar exists outside this file, and
// nothing that does exist here crosses the boundary: callers get immutable DTOs. The
// invariant is about event objects, not about the import statement, and it was written the
// other way round for four revisions.
//
// WHY A CUSTOM EXECUTOR RATHER THAN AN ACTOR + CONTINUATION BRIDGE
//
// EventKit's fetches are synchronous and blocking, and EK* objects are not thread-safe, so
// all access is serialized on a dedicated dispatch queue. The obvious shape -- a plain actor whose
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
/// This guarantees serialization, not affinity to a permanent OS thread. EventKit
/// explicitly supports dispatch queues for synchronous fetches (EKEventStore.h).
final class SerialQueueExecutor: SerialExecutor {
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
    nonisolated let readGate: CalendarReadGate
    private let executor = SerialQueueExecutor(label: "com.collierhmg.apple-calendar-mcp.eventkit")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    private lazy var store = EKEventStore()

    init(readGate: CalendarReadGate = CalendarReadGate()) {
        self.readGate = readGate
    }

    // MARK: - Calendars

    func calendars() -> [CalendarRef] {
        store.calendars(for: .event).map { cal in
            // `allowsContentModifications` is EventKit's own answer, and as of 2026-08-20 it is
            // the ONLY answer -- the writable-calendar allowlist (C1) was withdrawn by the
            // user's decision. If macOS lets them write to a calendar, so does this server,
            // including one shared with them tomorrow, with no config change.
            //
            // `isImmutable` is NOT consulted: its header says it governs renaming or deleting
            // the calendar and "does NOT imply that you cannot add events or reminders to the
            // calendar". Consulting it would reject the user's own writable calendars.
            let permitted = cal.allowsContentModifications
            return CalendarRef(
                id: cal.calendarIdentifier,
                title: cal.title,
                sourceTitle: cal.source?.title ?? "",
                sourceType: Self.describe(cal.source?.sourceType),
                allowsContentModifications: permitted,
                isSubscribed: cal.isSubscribed,
                writable: permitted,
                writableReason: Self.writableReason(permitted: permitted),
                trust: untrustedMarker)
        }
    }

    // MARK: - Events

    /// Fetch events overlapping [start, end), sorted deterministically.
    ///
    /// Returns everything matching plus the total, so the caller can distinguish "nothing
    /// found" from "stopped counting".
    /// `limit` is optional and nil means "every match in the window". Searching needs the
    /// whole window before it filters -- capping first would make the match count a count of
    /// the first N events rather than of the query -- and the window itself is already
    /// bounded to `Limits.maxIntervalDays`, so nil is bounded in time, not unbounded.
    func events(start: Date, end: Date, calendarIds: [String]?,
                includeFields: Set<String>, zone: TimeZone,
                limit: Int?) -> (items: [EventDTO], total: Int, unmatchedCalendarIds: [String]) {
        let all = store.calendars(for: .event)
        let scope = CalendarScope.resolve(requested: calendarIds,
                                          available: all.map(\.calendarIdentifier))
        // An id that matched nothing is REPORTED, not swallowed. EventKit identifiers change
        // on a full sync, so a caller holding a stale one would otherwise get an empty result
        // indistinguishable from an empty week -- a false absence, the dangerous kind.
        if scope.matchesNothing { return ([], 0, scope.unmatchedIds) }
        let scoped = scope.selectedIds.map { ids in all.filter { ids.contains($0.calendarIdentifier) } }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: scoped ?? all)
        let matched = store.events(matching: predicate)

        let sorted = matched.sorted(by: Self.deterministicOrder)

        let kept = limit.map { Array(sorted.prefix($0)) } ?? sorted
        return (kept.map { dto(from: $0, includeFields: includeFields, zone: zone) },
                sorted.count,
                scope.unmatchedIds)
    }

    /// Text search, matched BEFORE conversion.
    ///
    /// Filtering happens on the `EKEvent`, so only events that actually match are ever turned
    /// into DTOs. The handler used to convert the whole window and filter the DTOs, which
    /// built -- and immediately discarded -- one object per non-matching event, carrying the
    /// notes and location strings fetched purely so they could be searched.
    ///
    /// `total` counts every match in the window, not the returned page: capping before
    /// matching is what let a populated month answer "no matching events".
    func searchEvents(start: Date, end: Date, calendarIds: [String]?,
                      query: String, searchFields: Set<String>,
                      includeFields: Set<String>, zone: TimeZone,
                      limit: Int) -> (items: [EventDTO], total: Int, unmatchedCalendarIds: [String]) {
        let all = store.calendars(for: .event)
        let scope = CalendarScope.resolve(requested: calendarIds,
                                          available: all.map(\.calendarIdentifier))
        if scope.matchesNothing { return ([], 0, scope.unmatchedIds) }
        let scoped = scope.selectedIds.map { ids in all.filter { ids.contains($0.calendarIdentifier) } }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: scoped ?? all)
        let needle = query.lowercased()

        let (kept, total) = EventSearch.filterCountCap(
            store.events(matching: predicate), limit: limit,
            matches: { event in
                EventSearch.matches(title: event.title ?? "", notes: event.notes,
                                    location: event.location, needle: needle,
                                    fields: searchFields)
            },
            orderedBy: Self.deterministicOrder)

        // Convert only what is returned.
        return (kept.map { dto(from: $0, includeFields: includeFields, zone: zone) },
                total,
                scope.unmatchedIds)
    }

    /// Merged busy periods. Titles never leave this function.
    func busyIntervals(start: Date, end: Date, calendarIds: [String]?,
                       zone: TimeZone) -> (intervals: [BusyInterval], unmatchedCalendarIds: [String]) {
        let all = store.calendars(for: .event)
        let scope = CalendarScope.resolve(requested: calendarIds,
                                          available: all.map(\.calendarIdentifier))
        // "You are free" is the single most dangerous thing this tool can say wrongly.
        if scope.matchesNothing { return ([], scope.unmatchedIds) }
        let scoped = scope.selectedIds.map { ids in all.filter { ids.contains($0.calendarIdentifier) } }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: scoped ?? all)

        let periods = store.events(matching: predicate)
            .filter { Self.countsAsBusy(status: $0.status, availability: $0.availability) }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
        return (BusyPeriods.merge(periods, zone: zone), scope.unmatchedIds)
    }

    /// Missing availability metadata does not establish that an appointment is free.
    /// EKEvent.h defines .notSupported as a calendar capability, not an event status.
    nonisolated static func countsAsBusy(status: EKEventStatus,
                                        availability: EKEventAvailability) -> Bool {
        status != .canceled && availability != .free
    }

    /// EventKit guarantees no ordering, so sort explicitly with a deterministic tie-breaker.
    /// Without the tie-breaker, two events at the same instant can swap places between calls
    /// and a caller diffing results sees phantom changes.
    private static func deterministicOrder(_ a: EKEvent, _ b: EKEvent) -> Bool {
        if a.startDate != b.startDate { return a.startDate < b.startDate }
        let at = a.title ?? "", bt = b.title ?? ""
        if at != bt { return at < bt }
        return (a.eventIdentifier ?? "") < (b.eventIdentifier ?? "")
    }

    // MARK: - Conversion

    /// `zone` renders EVERY timestamp in the result, not just the all-day dates. One zone
    /// per request, reported back as `effective_time_zone`, so that field is a fact about the
    /// payload rather than a restatement of the argument.
    private func dto(from event: EKEvent, includeFields: Set<String>, zone: TimeZone) -> EventDTO {
        let eventZone = event.isAllDay ? nil : (event.timeZone?.identifier)
        let occurrence = event.hasRecurrenceRules ? event.occurrenceDate : nil
        return EventDTO(
            id: event.eventIdentifier ?? "",
            // Explicitly nil, never absent -- a missing key and a null are different things to
            // a schema validator, and only one of them matches ["string","null"].
            // UTC, ALWAYS -- deliberately not the request's rendering zone.
            //
            // This is an identifier, not a display value: it is half of the
            // (eventIdentifier, occurrenceDate) key that addresses one occurrence of a
            // series. Rendering it in a caller-chosen zone would make the same occurrence
            // produce different STRINGS for different callers, so anything that stored the
            // key and compared it textually later would silently stop matching. The instant
            // is what identifies the occurrence; its offset is not part of the identity.
            occurrenceDate: occurrence.map { TimeSemantics.format($0, in: .gmt) },
            calendarId: event.calendar?.calendarIdentifier ?? "",
            title: event.title ?? "",
            start: TimeSemantics.format(event.startDate, in: zone),
            end: TimeSemantics.format(event.endDate, in: zone),
            isAllDay: event.isAllDay,
            allDayStartDate: event.isAllDay
                ? TimeSemantics.formatAllDay(event.startDate, in: zone) : nil,
            allDayEndDate: event.isAllDay
                ? TimeSemantics.formatAllDay(event.endDate, in: zone) : nil,
            timeZone: eventZone,
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

    // Internal rather than private so the reason strings are testable without a calendar.
    static func writableReason(permitted: Bool) -> String {
        permitted
            ? "writable"
            : "EventKit does not permit writing here (subscribed, holiday or birthday calendar)"
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
