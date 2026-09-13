// Turning tool calls into calendar reads.
//
// Error policy: a bad argument is a normal outcome, not a crash. Every failure returns
// isError with a message that says what was wrong AND what a correct call looks like, because
// the reader is a model that will otherwise retry the same malformed call.
//
// Every failure also leads with a STABLE CODE -- `INTERVAL_TOO_LARGE: interval is 45 days...`
// -- so a caller can branch on the cause without pattern-matching English prose that will be
// reworded. The codes are the enum in ToolError; the prose after the colon is free to change.
//
// The code travels in the text rather than in `structuredContent`, deliberately. A tool that
// declares an outputSchema promises that its structured output conforms to it, and an error
// payload does not have the shape of a successful one; emitting it anyway would hand a
// strict client a validation failure on top of the error it was already reporting.
//
// Framework errors never cross this boundary verbatim -- they leak paths and internal state,
// and they are not actionable.

import Foundation
import MCP

/// Stable failure codes. The wording after a code may change; the code may not.
///
/// Only the codes the READ surface can actually produce are listed. The write surface will
/// add its own when it exists -- a code advertised by a tool that cannot emit it is the same
/// class of claim as a phase marked complete before it was built.
enum ToolError: String {
    case permissionDenied = "PERMISSION_DENIED"
    case badTimestamp = "BAD_TIMESTAMP"
    case badTimeZone = "BAD_TIME_ZONE"
    case endNotAfterStart = "END_NOT_AFTER_START"
    case intervalTooLarge = "INTERVAL_TOO_LARGE"
    case missingArgument = "MISSING_ARGUMENT"
    case unknownTool = "UNKNOWN_TOOL"
    case storeUnavailable = "CALENDAR_STORE_UNAVAILABLE"
    case storeBusy = "CALENDAR_STORE_BUSY"
    case storeTimedOut = "CALENDAR_TIMEOUT"
    case storeWedged = "CALENDAR_STORE_WEDGED"

    /// Maps the time layer's errors onto the wire codes, so the two cannot drift apart
    /// silently -- a new TimeError case will not compile without a decision here.
    init(_ error: TimeError) {
        switch error {
        case .badTimestamp:     self = .badTimestamp
        case .badTimeZone:      self = .badTimeZone
        case .endNotAfterStart: self = .endNotAfterStart
        case .intervalTooLong:  self = .intervalTooLarge
        }
    }
}

enum ToolHandlers {

    static func dispatch(_ params: CallTool.Parameters, store: CalendarStore) async throws -> CallTool.Result {
        do {
            // Permission status is answerable in every state -- it is the tool you reach for
            // WHEN access is broken, so gating it behind access would be circular.
            if params.name == "calendar_permission_status" { return await permissionStatus() }

            // Name validity does not depend on permission. Checked BEFORE the access gate
            // because otherwise a typo'd tool name on a machine without a grant reports
            // PERMISSION_DENIED -- sending the caller to fix a permission that is not the
            // problem, and hiding a mistake it could have corrected itself.
            guard ToolRegistry.names.contains(params.name) else {
                return failure(.unknownTool, "unknown tool: \(params.name). This server "
                               + "provides: \(ToolRegistry.names.sorted().joined(separator: ", "))")
            }

            let state = AuthorizationState.current
            guard state.canReadEvents else {
                return failure(.permissionDenied, """
                    Calendar access unavailable (\(state.rawValue)).

                    \(state.guidance)

                    This binary: \(Meta.executablePath)
                    """)
            }

            // Every content read shares one gate. Diagnostic/protocol methods bypass it.
            // This closure must remain read-only; future writes need outcome reconciliation.
            return try await store.readGate.run {
                switch params.name {
                case "calendar_list_calendars": return try await listCalendars(store)
                case "calendar_list_events":    return try await listEvents(params, store)
                case "calendar_find_events":    return try await findEvents(params, store)
                case "calendar_busy_intervals": return try await busyIntervals(params, store)
                default:
                    return failure(.unknownTool, "tool \(params.name) is declared but not handled")
                }
            }
        } catch let e as TimeError {
            return failure(ToolError(e), e.description)
        } catch let error as CalendarReadError {
            return readFailure(error)
        } catch is CancellationError {
            throw CancellationError() // Let the MCP SDK suppress the canceled request's response.
        } catch {
            // Sanitised deliberately: framework errors carry paths and internal detail, and a
            // model cannot act on them anyway.
            return failure(.storeUnavailable, "the calendar store could not complete that request")
        }
    }

    static func readFailure(_ error: CalendarReadError) -> CallTool.Result {
        switch error {
        case .busy:
            return failure(.storeBusy, "another calendar read is still running; retry after it finishes")
        case .timedOut:
            return failure(.storeTimedOut, "calendar read exceeded its deadline; restart the server before retrying")
        case .wedged:
            return failure(.storeWedged, "calendar subsystem is blocked; restart the server")
        }
    }

    // MARK: - Tools

    /// Built from a typed DTO rather than assembled inline, so the payload this tool returns
    /// can be checked against the schema it advertises without a calendar or a grant.
    static func permissionPayload(now: Date = Date(),
                                  client: ClientSnapshot? = nil) -> PermissionStatusDTO {
        let state = AuthorizationState.current
        let zone = TimeSemantics.systemZone
        return PermissionStatusDTO(
            status: state.rawValue,
            canReadEvents: state.canReadEvents,
            guidance: state.guidance,
            identity: Runtime.disclaimMode,
            // The model needs to know where "now" and "today" are, and it cannot ask the OS
            // itself. Reported live rather than snapshotted, so it is right after travel.
            systemTimeZone: zone.identifier,
            systemUtcOffsetSeconds: zone.secondsFromGMT(),
            currentTime: TimeSemantics.format(now, in: zone),
            client: client)
    }

    private static func permissionStatus() async -> CallTool.Result {
        let payload = permissionPayload(client: await ClientSession.shared.current())
        do {
            return try CallTool.Result(
                content: [.text(
                    text: "Calendar authorization: \(payload.status). "
                        + "System time zone: \(payload.systemTimeZone), "
                        + "local time now \(payload.currentTime).",
                    annotations: nil, _meta: nil)],
                structuredContent: payload)
        } catch {
            // Encoding a struct of Strings, Bools and an Int cannot realistically fail, but
            // this tool is the one that has to answer when everything else is broken, so it
            // degrades to text rather than throwing into the generic store-unavailable path.
            return .init(content: [.text(
                text: "Calendar authorization: \(payload.status). \(payload.guidance)",
                annotations: nil, _meta: nil)])
        }
    }

    private static func listCalendars(_ store: CalendarStore) async throws -> CallTool.Result {
        let calendars = await store.calendars()
        let envelope = ReadEnvelope(
            items: calendars,
            truncated: false,
            totalMatched: calendars.count,
            // No window and no result cap: this tool takes no arguments at all, so the zone
            // is the machine's and both limits are honestly null.
            effectiveTimeZone: TimeSemantics.systemZone.identifier,
            limitsApplied: Limits.applied(limit: nil, windowed: false),
            // This tool takes no calendar_ids, so none can go unmatched.
            unmatchedCalendarIds: [],
            trust: untrustedMarker)
        return try result(envelope, summary: "\(calendars.count) calendar(s)")
    }

    private static func listEvents(_ params: CallTool.Parameters,
                                   _ store: CalendarStore) async throws -> CallTool.Result {
        let w = try window(from: params)
        let limit = Limits.clampResultLimit(params.arguments?["limit"]?.intValue)
        let include = fieldSet(params.arguments?["include_fields"])

        let (items, total, unmatched) = await store.events(
            start: w.start, end: w.end, calendarIds: w.calendarIds,
            includeFields: include, zone: w.zone, limit: limit)

        return try result(
            ReadEnvelope(items: items, truncated: total > items.count, totalMatched: total,
                         effectiveTimeZone: w.zone.identifier,
                         limitsApplied: Limits.applied(limit: limit),
                         unmatchedCalendarIds: unmatched, trust: untrustedMarker),
            summary: summarise(count: items.count, total: total, noun: "event",
                               unmatched: unmatched))
    }

    private static func findEvents(_ params: CallTool.Parameters,
                                   _ store: CalendarStore) async throws -> CallTool.Result {
        guard let query = params.arguments?["query"]?.stringValue, !query.isEmpty else {
            return failure(.missingArgument, "query is required and must not be empty")
        }
        let w = try window(from: params)
        let limit = Limits.clampResultLimit(params.arguments?["limit"]?.intValue)
        let searchFields = fieldSet(params.arguments?["search_fields"],
                                    default: EventSearch.defaultFields)

        // Match first, convert second, cap third -- and all three inside the adapter.
        //
        // Two separate bugs live at this boundary and only one is obvious. The obvious one:
        // capping BEFORE matching made `total_matched` a count of matches among the first 500
        // events by start order, so a populated month could answer "no matching events" with
        // a straight face. The quiet one: matching after CONVERSION built a DTO for every
        // event in the window -- including the notes and location strings fetched purely so
        // they could be searched -- and then discarded all but the matches. The window is
        // bounded in TIME, not in COUNT, and a dense shared calendar makes that gap real.
        //
        // Only matching events are converted now, and only the returned page of those.
        let requested = fieldSet(params.arguments?["include_fields"])
        let (matches, total, unmatched) = await store.searchEvents(
            start: w.start, end: w.end, calendarIds: w.calendarIds,
            query: query, searchFields: searchFields,
            // Notes and location are matched against the event itself, so they no longer need
            // requesting here merely to be searchable -- only to be RETURNED. Withholding is
            // therefore structural rather than a redaction pass that could be forgotten.
            includeFields: requested, zone: w.zone, limit: limit)

        return try result(
            ReadEnvelope(items: matches, truncated: total > matches.count,
                         totalMatched: total, effectiveTimeZone: w.zone.identifier,
                         limitsApplied: Limits.applied(limit: limit),
                         unmatchedCalendarIds: unmatched, trust: untrustedMarker),
            summary: summarise(count: matches.count, total: total, noun: "match",
                               unmatched: unmatched))
    }

    private static func busyIntervals(_ params: CallTool.Parameters,
                                      _ store: CalendarStore) async throws -> CallTool.Result {
        let w = try window(from: params)
        let (intervals, unmatched) = await store.busyIntervals(
            start: w.start, end: w.end, calendarIds: w.calendarIds, zone: w.zone)
        return try result(
            ReadEnvelope(items: intervals, truncated: false, totalMatched: intervals.count,
                         effectiveTimeZone: w.zone.identifier,
                         // Merged periods are never capped -- every one in the window is
                         // returned, so claiming a result limit would be false.
                         limitsApplied: Limits.applied(limit: nil),
                         unmatchedCalendarIds: unmatched, trust: untrustedMarker),
            summary: "\(intervals.count) busy period(s)"
                + Self.unmatchedNote(unmatched))
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
        // The zone chosen here renders EVERY timestamp in the response and is reported back
        // as `effective_time_zone`. Defaults to the machine's, tracked live.
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

    // `redact()` lived here and is GONE. It dropped unrequested fields from search results
    // after the fact, which was necessary only because the search fetched notes and location
    // in order to match them. The adapter now matches against the event itself, so those
    // fields are never requested unless the caller wants them returned -- withholding is a
    // property of what is asked for, not a pass that a later edit could forget to run.

    // MARK: - Results

    /// Returns BOTH structuredContent and a text summary. Clients at protocol revisions that
    /// do not surface structured output would otherwise show the user nothing at all.
    private static func result<T: Codable & Sendable>(_ envelope: ReadEnvelope<T>,
                                                      summary: String) throws -> CallTool.Result {
        try CallTool.Result(
            content: [.text(text: summary, annotations: nil, _meta: nil)],
            structuredContent: envelope)
    }

    private static func summarise(count: Int, total: Int, noun: String,
                                  unmatched: [String] = []) -> String {
        let base = count < total
            ? "\(count) of \(total) \(noun)(s) — TRUNCATED, narrow the window for the rest"
            : "\(count) \(noun)(s)"
        return base + unmatchedNote(unmatched)
    }

    /// Says so in the TEXT as well as the structured payload. A client that shows only the
    /// summary would otherwise read "0 events" and stop, which is the failure this exists to
    /// prevent.
    private static func unmatchedNote(_ unmatched: [String]) -> String {
        guard !unmatched.isEmpty else { return "" }
        return " — WARNING: \(unmatched.count) requested calendar id(s) matched no calendar "
            + "on this Mac, so those calendars were NOT searched. EventKit identifiers change "
            + "on sync; re-read them from calendar_list_calendars."
    }

    /// Errors lead with a stable code so a caller can branch on the cause without parsing
    /// prose. `structuredContent` is deliberately omitted: see the note at the top of the file.
    private static func failure(_ code: ToolError, _ message: String) -> CallTool.Result {
        .init(content: [.text(text: "\(code.rawValue): \(message)", annotations: nil, _meta: nil)],
              isError: true)
    }
}
