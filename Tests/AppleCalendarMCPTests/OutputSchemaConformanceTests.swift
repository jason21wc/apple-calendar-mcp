import Testing
import Foundation
import MCP
@testable import apple_calendar_mcp

// The test that would have caught the bug that shipped.
//
// Phase 4 went out with every event tool returning `start`, `end` and `occurrence_date` as
// NUMBERS while its own outputSchema promised strings -- because Swift's default Codable
// encoding for `Date` is seconds since the 2001 reference date. tools/list passed, the
// handshake passed, 73 tests passed, and every real query failed validation at the client.
//
// Nothing caught it because nothing ever encoded a payload and compared it to the schema the
// server itself advertises. That needs no calendar access and no permission: synthetic DTOs
// are enough, which is what makes the omission inexcusable rather than unlucky.

/// Minimal JSON Schema *type* checker. Deliberately not a full validator -- `type` is the
/// assertion that was violated, and a small checker that runs is worth more than a complete
/// one that is never written.
enum SchemaCheck {

    static func typeMismatches(value: Any, schema: [String: Any], path: String = "") -> [String] {
        var problems: [String] = []

        if let declared = schema["type"] {
            let allowed: Set<String>
            if let one = declared as? String { allowed = [one] }
            else if let many = declared as? [String] { allowed = Set(many) }
            else { allowed = [] }

            if !allowed.isEmpty, !allowed.contains(actualType(of: value)) {
                problems.append("\(path.isEmpty ? "<root>" : path): declared \(allowed.sorted()), "
                                + "got \(actualType(of: value)) (\(value))")
            }
        }

        if let props = schema["properties"] as? [String: Any], let obj = value as? [String: Any] {
            for (key, sub) in props {
                guard let subSchema = sub as? [String: Any] else { continue }
                // An absent key is not a type error -- optional fields are allowed to be
                // missing. Only present values are checked.
                if let v = obj[key] {
                    problems += typeMismatches(value: v, schema: subSchema, path: "\(path)/\(key)")
                }
            }
        }

        if let itemSchema = schema["items"] as? [String: Any], let arr = value as? [Any] {
            for (i, element) in arr.enumerated() {
                problems += typeMismatches(value: element, schema: itemSchema, path: "\(path)/\(i)")
            }
        }

        return problems
    }

    private static func actualType(of value: Any) -> String {
        if value is NSNull { return "null" }
        if let n = value as? NSNumber {
            // CFBoolean bridges to NSNumber, so bools must be separated by their type encoding
            // or every boolean reads as a number.
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? "boolean"
                : (CFNumberIsFloatType(n) ? "number" : "integer")
        }
        if value is String { return "string" }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "object" }
        return "unknown"
    }
}

@Suite("Output schema conformance")
struct OutputSchemaConformanceTests {

    /// Encode through the same path the server uses, then read back as plain JSON.
    private func encoded<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func schema(forTool name: String) throws -> [String: Any] {
        let tool = try #require(ToolRegistry.all().first { $0.name == name })
        let out = try #require(tool.outputSchema, "\(name) declares no outputSchema")
        let data = try JSONEncoder().encode(out)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sampleEvent(allDay: Bool, recurring: Bool) -> EventDTO {
        EventDTO(
            id: "EVT-1",
            occurrenceDate: recurring ? "2026-08-20T14:00:00Z" : nil,
            calendarId: "CAL-1",
            title: "Standup",
            start: "2026-08-20T14:00:00Z",
            end: "2026-08-20T14:30:00Z",
            isAllDay: allDay,
            allDayStartDate: allDay ? "2026-08-20" : nil,
            allDayEndDate: allDay ? "2026-08-21" : nil,
            timeZone: allDay ? nil : "America/Denver",
            status: "confirmed",
            availability: "busy",
            isRecurring: recurring,
            isDetached: false,
            hasAttendees: false,
            notes: nil, url: nil, location: nil, attendeeCount: nil, organizerName: nil,
            trust: untrustedMarker)
    }

    @Test("an event payload matches the schema calendar_list_events advertises")
    func eventPayloadMatchesItsSchema() throws {
        let envelope = ReadEnvelope(
            items: [sampleEvent(allDay: false, recurring: false),
                    sampleEvent(allDay: true, recurring: false),
                    sampleEvent(allDay: false, recurring: true)],
            truncated: false, totalMatched: 3,
            effectiveTimeZone: "America/Denver",
            limitsApplied: Limits.applied, trust: untrustedMarker)

        let problems = SchemaCheck.typeMismatches(
            value: try encoded(envelope), schema: try schema(forTool: "calendar_list_events"))
        #expect(problems.isEmpty, "schema violations:\n\(problems.joined(separator: "\n"))")
    }

    @Test("find_events advertises the same event shape, so the same payload must satisfy it")
    func findEventsSharesTheEventShape() throws {
        let envelope = ReadEnvelope(
            items: [sampleEvent(allDay: false, recurring: true)],
            truncated: true, totalMatched: 99,
            effectiveTimeZone: "UTC", limitsApplied: Limits.applied, trust: untrustedMarker)

        let problems = SchemaCheck.typeMismatches(
            value: try encoded(envelope), schema: try schema(forTool: "calendar_find_events"))
        #expect(problems.isEmpty, "schema violations:\n\(problems.joined(separator: "\n"))")
    }

    @Test("busy intervals match their schema — they have a separate serializer that broke identically")
    func busyPayloadMatchesItsSchema() throws {
        let envelope = ReadEnvelope(
            items: [BusyInterval(start: "2026-08-20T14:00:00Z",
                                 end: "2026-08-20T15:00:00Z", eventCount: 2)],
            truncated: false, totalMatched: 1,
            effectiveTimeZone: "America/Denver",
            limitsApplied: Limits.applied, trust: untrustedMarker)

        let problems = SchemaCheck.typeMismatches(
            value: try encoded(envelope), schema: try schema(forTool: "calendar_busy_intervals"))
        #expect(problems.isEmpty, "schema violations:\n\(problems.joined(separator: "\n"))")
    }

    @Test("dates serialise as STRINGS, not as the numbers Swift produces by default")
    func datesAreStringsOnTheWire() throws {
        let json = try #require(try encoded(sampleEvent(allDay: false, recurring: true)) as? [String: Any])
        for key in ["start", "end", "occurrence_date"] {
            let actual = type(of: json[key] ?? "absent")
            #expect(json[key] is String,
                    "\(key) encoded as \(actual); a Swift Date would land here as a number")
        }
    }

    @Test("a field that is null by nature is PRESENT and null; one that was not requested is absent")
    func nullVersusAbsent() throws {
        let json = try #require(try encoded(sampleEvent(allDay: false, recurring: false)) as? [String: Any])
        // Not recurring: the key exists and carries null, so a reader can tell "does not
        // recur" from "the server did not say".
        #expect(json.keys.contains("occurrence_date"))
        #expect(json["occurrence_date"] is NSNull)
        // Not requested: absent entirely, which is not the same as "this event has no notes".
        #expect(!json.keys.contains("notes"))
        #expect(!json.keys.contains("organizer_name"))
    }

    @Test("the checker itself catches a Date, so a passing suite means something")
    func checkerDetectsTheOriginalBug() throws {
        // Positive control. Without this, all of the above pass equally well against a
        // checker that silently does nothing.
        struct Broken: Encodable { let start: Date }
        let schema: [String: Any] = ["type": "object",
                                     "properties": ["start": ["type": "string"]]]
        let problems = SchemaCheck.typeMismatches(
            value: try encoded(Broken(start: Date())), schema: schema)
        #expect(!problems.isEmpty, "the checker must reject a raw Date where a string is declared")
    }
}
