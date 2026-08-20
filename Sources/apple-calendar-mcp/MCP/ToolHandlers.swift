// Turning tool calls into calendar reads.
//
// Error policy: a bad argument is a normal outcome, not a crash. Every failure returns
// isError with a message that says what was wrong AND what a correct call looks like, because
// the reader is a model that will otherwise retry the same malformed call.
//
// Framework errors never cross this boundary verbatim -- they leak paths and internal state,
// and they are not actionable.

import Foundation
import MCP

enum ToolHandlers {

    static func dispatch(_ params: CallTool.Parameters, store: CalendarStore) async -> CallTool.Result {
        do {
            // Permission status is answerable in every state -- it is the tool you reach for
            // WHEN access is broken, so gating it behind access would be circular.
            if params.name == "calendar_permission_status" { return permissionStatus() }

            let state = AuthorizationState.current
            guard state.canReadEvents else {
                return failure("""
                    Calendar access unavailable (\(state.rawValue)).

                    \(state.guidance)

                    This binary: \(Meta.executablePath)
                    """)
            }

            switch params.name {
            case "calendar_permission_status": return permissionStatus()
            case "calendar_list_calendars":    return try await listCalendars(store)
            case "calendar_list_events":       return try await listEvents(params, store)
            case "calendar_find_events":       return try await findEvents(params, store)
            case "calendar_busy_intervals":    return try await busyIntervals(params, store)
            default:
                return failure("unknown tool: \(params.name)")
            }
        } catch let e as TimeError {
            return failure(e.description)
        } catch {
            // Sanitised deliberately: framework errors carry paths and internal detail, and a
            // model cannot act on them anyway.
            return failure("the calendar store could not complete that request")
        }
    }

    // MARK: - Tools

    private static func permissionStatus() -> CallTool.Result {
        let state = AuthorizationState.current
        let payload: [String: Value] = [
            "status": .string(state.rawValue),
            "can_read_events": .bool(state.canReadEvents),
            "guidance": .string(state.guidance),
            "identity": .string(Runtime.disclaimMode),
            // The model needs to know where "now" and "today" are, and it cannot ask the OS
            // itself. Reported live rather than snapshotted, so it is right after travel.
            "system_time_zone": .string(TimeSemantics.systemZone.identifier),
            "system_utc_offset_seconds": .int(TimeSemantics.systemZone.secondsFromGMT()),
            "current_time": .string(TimeSemantics.format(Date())),
        ]
        return .init(
            content: [.text(
                text: "Calendar authorization: \(state.rawValue). "
                    + "System time zone: \(TimeSemantics.systemZone.identifier), "
                    + "local time now \(TimeSemantics.format(Date())).",
                annotations: nil, _meta: nil)],
            structuredContent: .object(payload))
    }

    private static func listCalendars(_ store: CalendarStore) async throws -> CallTool.Result {
        let writable = Allowlist.writableCalendarIds
        let calendars = await store.calendars(writableIds: writable)
        let envelope = ReadEnvelope(
            items: calendars,
            truncated: false,
            totalMatched: calendars.count,
            effectiveTimeZone: TimeSemantics.systemZone.identifier,
            limitsApplied: Limits.applied,
            trust: untrustedMarker)
        return try result(envelope, summary: "\(calendars.count) calendar(s)")
    }

    private static func listEvents(_ params: CallTool.Parameters,
                                   _ store: CalendarStore) async throws -> CallTool.Result {
        let w = try window(from: params)
        let limit = Limits.clampResultLimit(params.arguments?["limit"]?.intValue)
        let include = fieldSet(params.arguments?["include_fields"])

        let (items, total) = await store.events(
            start: w.start, end: w.end, calendarIds: w.calendarIds,
            includeFields: include, zone: w.zone, limit: limit)

        return try result(
            ReadEnvelope(items: items, truncated: total > items.count, totalMatched: total,
                         effectiveTimeZone: w.zone.identifier,
                         limitsApplied: Limits.applied, trust: untrustedMarker),
            summary: summarise(count: items.count, total: total, noun: "event"))
    }

    private static func findEvents(_ params: CallTool.Parameters,
                                   _ store: CalendarStore) async throws -> CallTool.Result {
        guard let query = params.arguments?["query"]?.stringValue, !query.isEmpty else {
            return failure("query is required and must not be empty")
        }
        let w = try window(from: params)
        let limit = Limits.clampResultLimit(params.arguments?["limit"]?.intValue)
        let searchFields = fieldSet(params.arguments?["search_fields"], default: ["title"])

        // Fetch the window, then filter locally. Notes and location are needed to search them,
        // so they are requested here and then dropped unless the caller also asked for them --
        // searching a field is not a reason to disclose it.
        let needed: Set<String> = searchFields.union(fieldSet(params.arguments?["include_fields"]))
        let (candidates, _) = await store.events(
            start: w.start, end: w.end, calendarIds: w.calendarIds,
            includeFields: needed, zone: w.zone, limit: Limits.maxResultLimit)

        let needle = query.lowercased()
        let matched = candidates.filter { e in
            if searchFields.contains("title"), e.title.lowercased().contains(needle) { return true }
            if searchFields.contains("notes"), (e.notes ?? "").lowercased().contains(needle) { return true }
            if searchFields.contains("location"), (e.location ?? "").lowercased().contains(needle) { return true }
            return false
        }

        let requested = fieldSet(params.arguments?["include_fields"])
        let items = matched.prefix(limit).map { redact($0, keeping: requested) }

        return try result(
            ReadEnvelope(items: Array(items), truncated: matched.count > items.count,
                         totalMatched: matched.count, effectiveTimeZone: w.zone.identifier,
                         limitsApplied: Limits.applied, trust: untrustedMarker),
            summary: summarise(count: items.count, total: matched.count, noun: "match"))
    }

    private static func busyIntervals(_ params: CallTool.Parameters,
                                      _ store: CalendarStore) async throws -> CallTool.Result {
        let w = try window(from: params)
        let intervals = await store.busyIntervals(start: w.start, end: w.end, calendarIds: w.calendarIds)
        return try result(
            ReadEnvelope(items: intervals, truncated: false, totalMatched: intervals.count,
                         effectiveTimeZone: w.zone.identifier,
                         limitsApplied: Limits.applied, trust: untrustedMarker),
            summary: "\(intervals.count) busy period(s)")
    }

    // MARK: - Argument handling

    private struct Window {
        let start: Date, end: Date, zone: TimeZone, calendarIds: [String]?
    }

    private static func window(from params: CallTool.Parameters) throws -> Window {
        guard let startRaw = params.arguments?["start"]?.stringValue,
              let endRaw = params.arguments?["end"]?.stringValue else {
            throw TimeError.badTimestamp("start and end are both required")
        }
        let start = try TimeSemantics.parseTimestamp(startRaw)
        let end = try TimeSemantics.parseTimestamp(endRaw)
        try TimeSemantics.validateInterval(start: start, end: end, maxDays: Limits.maxIntervalDays)
        let zone = try TimeSemantics.parseTimeZone(params.arguments?["time_zone"]?.stringValue)

        let ids = params.arguments?["calendar_ids"]?.arrayValue?.compactMap { $0.stringValue }
        return Window(start: start, end: end, zone: zone, calendarIds: ids)
    }

    private static func fieldSet(_ value: Value?, default fallback: Set<String> = []) -> Set<String> {
        guard let arr = value?.arrayValue else { return fallback }
        let set = Set(arr.compactMap { $0.stringValue })
        return set.isEmpty ? fallback : set
    }

    /// Drop fields the caller did not ask for. Searching a field is not consent to see it.
    private static func redact(_ e: EventDTO, keeping: Set<String>) -> EventDTO {
        EventDTO(
            id: e.id, occurrenceDate: e.occurrenceDate, calendarId: e.calendarId,
            title: e.title, start: e.start, end: e.end, isAllDay: e.isAllDay,
            allDayStartDate: e.allDayStartDate, allDayEndDate: e.allDayEndDate,
            timeZone: e.timeZone, status: e.status, availability: e.availability,
            isRecurring: e.isRecurring, isDetached: e.isDetached, hasAttendees: e.hasAttendees,
            notes: keeping.contains("notes") ? e.notes : nil,
            url: keeping.contains("url") ? e.url : nil,
            location: keeping.contains("location") ? e.location : nil,
            attendeeCount: keeping.contains("attendee_count") ? e.attendeeCount : nil,
            organizerName: keeping.contains("organizer_name") ? e.organizerName : nil,
            trust: e.trust)
    }

    // MARK: - Results

    /// Returns BOTH structuredContent and a text summary. Clients at protocol revisions that
    /// do not surface structured output would otherwise show the user nothing at all.
    private static func result<T: Codable & Sendable>(_ envelope: ReadEnvelope<T>,
                                                      summary: String) throws -> CallTool.Result {
        try CallTool.Result(
            content: [.text(text: summary, annotations: nil, _meta: nil)],
            structuredContent: envelope)
    }

    private static func summarise(count: Int, total: Int, noun: String) -> String {
        count < total
            ? "\(count) of \(total) \(noun)(s) — TRUNCATED, narrow the window for the rest"
            : "\(count) \(noun)(s)"
    }

    private static func failure(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}
