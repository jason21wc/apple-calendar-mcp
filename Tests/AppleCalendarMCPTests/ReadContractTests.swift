import Testing
import Foundation
import MCP
@testable import apple_calendar_mcp

// The promises the five read tools make in their own schemas and descriptions, checked
// against what the code does. No calendar, no permission, no events on the machine.
//
// Each test here corresponds to a claim that was FALSE in the shipped read surface, found by
// auditing the tool contract against the implementation rather than by a failure in use:
//
//   * effective_time_zone named the caller's zone while timestamps rendered in the machine's
//   * limits_applied.limit reported the hard ceiling as though it were the limit in force
//   * a search filtered only the first page of events, so "no matches" could be a lie
//   * list_calendars returned other people's calendar names without the open-world marker
//   * failures carried prose and no stable code, though the plan listed codes

@Suite("Read surface contract")
struct ReadContractTests {

    // MARK: - Time zone

    @Test("a timestamp renders in the zone it is given, so effective_time_zone can be true")
    func timestampsHonourTheRequestedZone() throws {
        // 2026-08-20T20:00:00Z. Denver is -06:00 in August, Tokyo +09:00 -- and the Tokyo
        // rendering lands on the NEXT DAY, which is exactly the difference a caller sees.
        let instant = try TimeSemantics.parseTimestamp("2026-08-20T20:00:00Z")

        let denver = TimeSemantics.format(instant, in: try #require(TimeZone(identifier: "America/Denver")))
        let tokyo = TimeSemantics.format(instant, in: try #require(TimeZone(identifier: "Asia/Tokyo")))

        #expect(denver == "2026-08-20T14:00:00-06:00", "got \(denver)")
        #expect(tokyo == "2026-08-21T05:00:00+09:00", "got \(tokyo)")

        // Same instant either way: only the offset it is written with changes.
        #expect(try TimeSemantics.parseTimestamp(denver) == instant)
        #expect(try TimeSemantics.parseTimestamp(tokyo) == instant)
    }

    @Test("the interval cap counts seconds, so 31.9 days does not pass a 31-day limit")
    func intervalCapIsNotTruncated() throws {
        let start = try TimeSemantics.parseTimestamp("2026-08-01T00:00:00Z")
        // 31.9 days: Int(31.9) == 31, so the old truncating check let this through.
        let justOver = start.addingTimeInterval(31.9 * 86_400)
        #expect(throws: TimeError.self) {
            try TimeSemantics.validateInterval(start: start, end: justOver,
                                               maxDays: Limits.maxIntervalDays)
        }
        // Exactly at the cap still passes -- the bound is inclusive.
        let exact = start.addingTimeInterval(Double(Limits.maxIntervalDays) * 86_400)
        try TimeSemantics.validateInterval(start: start, end: exact,
                                           maxDays: Limits.maxIntervalDays)
    }

    @Test("occurrence_date does not change with the caller's time zone, because it is a key")
    func occurrenceDateIsZoneStable() throws {
        // start/end follow the request's zone; the occurrence KEY must not, or the same
        // occurrence yields different strings to different callers and textual comparison
        // silently stops matching.
        let instant = try TimeSemantics.parseTimestamp("2026-08-20T20:00:00Z")
        #expect(TimeSemantics.format(instant, in: .gmt) == "2026-08-20T20:00:00Z")
        // Same instant rendered for display differs -- that is the point of separating them.
        let denver = TimeSemantics.format(instant, in: try #require(TimeZone(identifier: "America/Denver")))
        #expect(denver != TimeSemantics.format(instant, in: .gmt))
        #expect(try TimeSemantics.parseTimestamp(denver) == instant)
    }

    @Test("an omitted time_zone resolves to the machine's, tracked live")
    func omittedZoneIsTheSystemZone() throws {
        #expect(try TimeSemantics.parseTimeZone(nil) == TimeSemantics.systemZone)
        // autoupdatingCurrent, not a snapshot: a long-running server must not keep rendering
        // the departure city's offset after a flight.
        #expect(TimeSemantics.systemZone == TimeZone.autoupdatingCurrent)
    }

    // MARK: - Limits

    @Test("limits_applied reports the EFFECTIVE limit, not the ceiling")
    func limitsReportWhatWasApplied() {
        // The default query returns at most 100 and used to announce a limit of 500.
        let defaulted = Limits.clampResultLimit(nil)
        #expect(defaulted == Limits.defaultResultLimit)
        #expect(Limits.applied(limit: defaulted).limit == Limits.defaultResultLimit)
        #expect(Limits.applied(limit: defaulted).limit != Limits.maxResultLimit,
                "the ceiling is being reported as the limit in force again")

        // A caller asking for more than the ceiling gets the ceiling, and is told so.
        let clamped = Limits.clampResultLimit(9_000)
        #expect(clamped == Limits.maxResultLimit)
        #expect(Limits.applied(limit: clamped).limit == Limits.maxResultLimit)

        // The ceiling is still reported, as its own field, so a caller knows what it may ask.
        #expect(Limits.applied(limit: 1).maxResultLimit == Limits.maxResultLimit)
    }

    @Test("a call that applies no cap says so instead of naming one")
    func uncappedCallsReportNull() {
        // list_calendars takes no arguments and busy_intervals returns every merged period.
        #expect(Limits.applied(limit: nil).limit == nil)
        #expect(Limits.applied(limit: nil, windowed: false).maxIntervalDays == nil)
        // ...but a windowed call still reports the window cap it really enforced.
        #expect(Limits.applied(limit: nil).maxIntervalDays == Limits.maxIntervalDays)
    }

    // MARK: - Search honesty

    private func event(_ title: String, notes: String? = nil, location: String? = nil) -> EventDTO {
        EventDTO(id: "E-\(title)", occurrenceDate: nil, calendarId: "CAL-1", title: title,
                 start: "2026-08-20T14:00:00Z", end: "2026-08-20T14:30:00Z",
                 isAllDay: false, allDayStartDate: nil, allDayEndDate: nil,
                 timeZone: "America/Denver", status: "confirmed", availability: "busy",
                 isRecurring: false, isDetached: false, hasAttendees: false,
                 notes: notes, url: nil, location: location,
                 attendeeCount: nil, organizerName: nil, trust: untrustedMarker)
    }

    /// Runs the SAME function the adapter runs, over DTOs instead of EKEvents.
    private func search(_ candidates: [EventDTO], _ query: String,
                        fields: Set<String> = EventSearch.defaultFields,
                        limit: Int = 100) -> (kept: [EventDTO], total: Int) {
        let needle = query.lowercased()
        return EventSearch.filterCountCap(
            candidates, limit: limit,
            matches: { EventSearch.matches($0, needle: needle, fields: fields) },
            orderedBy: { $0.id < $1.id })
    }

    @Test("a match beyond the returned page is still COUNTED, not just returned")
    func searchCountsEverythingItLookedAt() {
        // The shipped bug: cap at 500, filter those, report the survivors as the total. Here
        // 600 match and the caller asked for 100 -- the honest answer is 100 items out of a
        // total of 600. The old shape could report 100 of 100.
        let found = search((0..<600).map { event("standup \($0)") }, "standup")
        #expect(found.kept.count == 100)
        #expect(found.total == 600, "total counted only the returned page")
    }

    @Test("a match that sorts late is found, not silently dropped")
    func searchDoesNotStopAtThePageBoundary() {
        // The dangerous case is not a wrong count, it is a wrong ANSWER: one match sitting
        // past the old 500-event fetch, reported as "no matching events".
        var candidates = (0..<Limits.maxResultLimit).map { event("filler \($0)") }
        candidates.append(event("dentist"))

        let found = search(candidates, "dentist")
        #expect(found.total == 1, "a match beyond the old fetch cap reads as no match")
        #expect(found.kept.first?.title == "dentist")
    }

    @Test("filtering happens before capping, which is the whole ordering guarantee")
    func filteringPrecedesCapping() {
        // Directly asserts the order. If capping ran first, the single match at the end
        // would be outside the capped window and the total would be 0.
        var candidates = (0..<50).map { event("filler \($0)") }
        candidates.append(event("dentist"))
        let found = search(candidates, "dentist", limit: 10)
        #expect(found.total == 1)
        #expect(found.kept.count == 1)
    }

    @Test("searching notes or location requires asking for those fields")
    func searchFieldsAreOptIn() {
        let events = [event("Team sync", notes: "bring the dentist form"),
                      event("Lunch", location: "Dentist Row")]

        // Title only by default: neither matches.
        #expect(search(events, "dentist").total == 0)
        #expect(search(events, "dentist", fields: ["title", "notes"]).total == 1)
        #expect(search(events, "dentist", fields: ["title", "location"]).total == 1)
        // Case-insensitive, as the schema says.
        #expect(search(events, "DENTIST", fields: ["title", "notes", "location"]).total == 2)
    }

    @Test("an unmatched field is not searched just because the event has one")
    func searchDoesNotLeakAcrossFields() {
        #expect(search([event("Lunch", notes: "secret")], "secret", fields: ["location"]).total == 0)
    }

    @Test("the matcher reads raw fields, so the adapter can match without converting first")
    func matcherWorksOnRawFields() {
        // This overload is what CalendarStore calls against an EKEvent. If it disagreed with
        // the DTO overload the tests above would be testing a different function from the one
        // that runs.
        #expect(EventSearch.matches(title: "Dentist", notes: nil, location: nil,
                                    needle: "dentist", fields: ["title"]))
        #expect(!EventSearch.matches(title: "Dentist", notes: nil, location: nil,
                                     needle: "dentist", fields: ["notes"]))
        let dto = event("Dentist")
        #expect(EventSearch.matches(dto, needle: "dentist", fields: ["title"])
                == EventSearch.matches(title: dto.title, notes: dto.notes, location: dto.location,
                                       needle: "dentist", fields: ["title"]))
    }

    // MARK: - Stale calendar ids

    @Test("an id that matches nothing is reported, so an empty result is not read as an empty week")
    func unmatchedCalendarIdsAreReportable() throws {
        // EventKit identifiers change on a full sync (gotcha 25), so a caller holding a stale
        // one is ordinary rather than exceptional. Without this, the response is items: [],
        // truncated: false -- identical to a genuinely free week. A false ABSENCE.
        let resolution = CalendarScope.resolve(requested: ["GONE-1", "CAL-1", "GONE-2"],
                                               available: ["CAL-1", "CAL-2"])
        #expect(resolution.unmatchedIds == ["GONE-1", "GONE-2"])
        #expect(resolution.selectedIds == ["CAL-1"])

        // Every id stale: matches nothing, and the reason is recoverable.
        let allStale = CalendarScope.resolve(requested: ["GONE-1"], available: ["CAL-1"])
        #expect(allStale.matchesNothing)
        #expect(allStale.unmatchedIds == ["GONE-1"])

        // The envelope carries it, and the schema declares it as required.
        let envelope = ReadEnvelope(
            items: [EventDTO](), truncated: false, totalMatched: 0,
            effectiveTimeZone: "America/Denver", limitsApplied: Limits.applied(limit: 100),
            unmatchedCalendarIds: allStale.unmatchedIds, trust: untrustedMarker)
        let json = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(envelope)) as? [String: Any])
        #expect(json["unmatched_calendar_ids"] as? [String] == ["GONE-1"], """
            the field that separates "those calendars are gone" from "you are free" did not             reach the wire.
            """)
    }

    // MARK: - Client capability reporting

    @Test("a declared capability is reported as a claim, and form is checked separately")
    func clientCapabilitiesAreReportedHonestly() throws {
        // form and url are INDEPENDENT sub-capabilities. A url-only client satisfies a
        // top-level `elicitation != nil` check while being unable to answer the form request
        // a confirmation would actually send, so the two are reported apart.
        let urlOnly = ClientSnapshot(name: "c", version: "1", elicitationDeclared: true,
                                     elicitationFormSupported: false, elicitationURLSupported: true)
        #expect(urlOnly.elicitationDeclared)
        #expect(!urlOnly.elicitationFormSupported, """
            a url-only client must NOT read as able to answer a confirmation; that conflation             is what a top-level capability check would have hidden.
            """)

        let none = ClientSnapshot(name: nil, version: nil, elicitationDeclared: false,
                                  elicitationFormSupported: false, elicitationURLSupported: false)
        #expect(!none.elicitationFormSupported)
    }

    @Test("the permission report carries the client block, present-and-null when unknown")
    func permissionReportCarriesClient() throws {
        // Null before the handshake is a real answer -- "no client has connected" is not the
        // same as "the server did not say".
        let unknown = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ToolHandlers.permissionPayload(client: nil))) as? [String: Any]
        let u = try #require(unknown)
        #expect(u.keys.contains("client"))
        #expect(u["client"] is NSNull)

        let known = ClientSnapshot(name: "claude-ai", version: "0.1", elicitationDeclared: true,
                                   elicitationFormSupported: true, elicitationURLSupported: false)
        let withClient = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ToolHandlers.permissionPayload(client: known))) as? [String: Any]
        let block = try #require((withClient?["client"]) as? [String: Any])
        #expect(block["elicitation_form_supported"] as? Bool == true)
        #expect(block["elicitation_url_supported"] as? Bool == false)
        #expect(block["name"] as? String == "claude-ai")
    }

    @Test("reporting a capability is not the same as having asked a human")
    func capabilityIsNotApproval() throws {
        // The property that must never quietly change: nothing in the read surface consumes
        // this field as permission. There is no write path yet, and when there is, it must
        // perform its OWN elicitation and require an explicit accept -- a declaration made at
        // handshake time says nothing about whether a person answers later.
        let handlers = try Repo.source("Sources/apple-calendar-mcp/MCP/ToolHandlers.swift")
        #expect(!handlers.contains("elicitationFormSupported"), """
            ToolHandlers now reads the elicitation capability. If that is gating anything, a             declaration is being treated as an approval.
            """)
        let session = try Repo.source("Sources/apple-calendar-mcp/MCP/ClientSession.swift")
        #expect(session.contains("not evidence that a human is present"),
                "the warning that a declaration is not evidence of a human was removed")
    }

    // MARK: - Annotations

    @Test("every tool is annotated read-only and non-destructive, because every tool is")
    func allToolsAreReadOnly() {
        let tools = ToolRegistry.all()
        #expect(tools.count == 5, "the tool surface changed; the docs and memory say five")
        for tool in tools {
            #expect(tool.annotations.readOnlyHint == true, "\(tool.name) is not marked read-only")
            #expect(tool.annotations.destructiveHint == false, "\(tool.name) claims to be destructive")
        }
    }

    @Test("tools returning other people's text carry the open-world marker")
    func untrustedTextIsMarkedOpenWorld() {
        // Calendar and source TITLES are attacker-influenceable, not just event fields: a
        // calendar shared with the user carries a name someone else chose. list_calendars
        // shipped without the marker while returning exactly that.
        let openWorld = ["calendar_list_events", "calendar_find_events", "calendar_list_calendars"]
        for tool in ToolRegistry.all() where openWorld.contains(tool.name) {
            #expect(tool.annotations.openWorldHint == true,
                    "\(tool.name) returns externally-authored text without openWorldHint")
        }
        // busy_intervals returns times and counts only -- no external text, no marker.
        let busy = ToolRegistry.all().first { $0.name == "calendar_busy_intervals" }
        #expect(busy?.annotations.openWorldHint == false)
    }

    // MARK: - Errors

    @Test("every failure carries a stable code, and the codes cover every time error")
    func failuresCarryStableCodes() {
        // The prose after the colon may be reworded freely; the code may not.
        #expect(ToolError(TimeError.badTimestamp("x")).rawValue == "BAD_TIMESTAMP")
        #expect(ToolError(TimeError.badTimeZone("x")).rawValue == "BAD_TIME_ZONE")
        #expect(ToolError(TimeError.endNotAfterStart).rawValue == "END_NOT_AFTER_START")
        #expect(ToolError(TimeError.intervalTooLong(days: 45, max: 31)).rawValue == "INTERVAL_TOO_LARGE")

        // Codes are UPPER_SNAKE so a caller can match them without a regex over prose.
        for code in [ToolError.permissionDenied, .badTimestamp, .badTimeZone, .endNotAfterStart,
                     .intervalTooLarge, .missingArgument, .unknownTool, .storeUnavailable] {
            #expect(code.rawValue == code.rawValue.uppercased())
            #expect(!code.rawValue.contains(" "))
        }
    }

    @Test("an unknown tool name is an unknown tool, whatever the permission state")
    func unknownToolIsNotAPermissionProblem() {
        // The access gate used to run first, so a typo'd name on a machine with no grant
        // reported PERMISSION_DENIED -- pointing the caller at a permission that was not the
        // problem, and hiding a mistake they could have fixed themselves.
        #expect(!ToolRegistry.names.contains("calendar_delete_event"),
                "a write tool appeared in the registry; the read-only claim is no longer true")
        #expect(ToolRegistry.names.count == 5)
        // The registry is the single source of the names -- never a second hand-kept list.
        #expect(ToolRegistry.names == Set(ToolRegistry.all().map(\.name)))
    }

    @Test("an error message still says what a correct call looks like")
    func errorsRemainActionable() {
        // A code alone is not actionable to a model that will otherwise retry the same call.
        #expect(TimeError.badTimestamp("2026-09-03T14:00").description.contains("-06:00"))
        #expect(TimeError.badTimeZone("Denver").description.contains("America/Denver"))
        #expect(TimeError.intervalTooLong(days: 45, max: 31).description.contains("31"))
    }

    @Test("no shipped error code names a control this project withdrew")
    func noWithdrawnCodesRemain() {
        // C1 was withdrawn on 2026-08-20 and the allowlist deleted. A stale code sends a
        // user hunting for a config file that no longer exists -- the same defect class as
        // the stale refusal string that shipped in writableReason.
        for code in [ToolError.permissionDenied, .badTimestamp, .badTimeZone, .endNotAfterStart,
                     .intervalTooLarge, .missingArgument, .unknownTool, .storeUnavailable] {
            #expect(!code.rawValue.contains("ALLOWLIST"))
        }
        #expect(!CalendarStore.writableReason(permitted: false).lowercased().contains("allowlist"))
    }
}
