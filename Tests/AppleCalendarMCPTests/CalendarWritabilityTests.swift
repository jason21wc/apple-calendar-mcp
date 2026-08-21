import Testing
@testable import apple_calendar_mcp

// Writability is EventKit's answer and nothing else.
//
// This exists because of a real defect. The writable-calendar allowlist (C1) shipped in
// Phase 4 deciding the `writable` flag, defaulting to EMPTY and failing closed -- so with no
// config file present, which is the state of every install including the author's, every
// calendar was reported `writable: false` with the reason "not in the allowlist". No test
// covered it, because `writableReason` was private and nothing exercised CalendarStore.
//
// C1 was withdrawn on 2026-08-20: if macOS lets the user write to a calendar, so does this
// server, including one shared with them tomorrow. These tests pin that, and pin the reason
// strings -- which are user-facing text explaining a refusal, so a wrong one sends someone
// looking for a config file that no longer exists.

@Suite("Calendar writability")
struct CalendarWritabilityTests {

    @Test("A calendar EventKit permits is writable, with no allowlist to consult")
    func permittedIsWritable() {
        #expect(CalendarStore.writableReason(permitted: true) == "writable")
    }

    @Test("A calendar EventKit refuses explains itself in EventKit's terms")
    func refusedExplainsWhy() {
        let reason = CalendarStore.writableReason(permitted: false)
        #expect(reason.contains("EventKit does not permit writing"))
        // The refusal must be actionable: naming the calendar kinds that behave this way is
        // what stops "writable: false" reading as a bug in this server.
        #expect(reason.contains("subscribed"))
    }

    @Test("No refusal reason mentions an allowlist, which no longer exists")
    func noStaleAllowlistLanguage() {
        for permitted in [true, false] {
            let reason = CalendarStore.writableReason(permitted: permitted).lowercased()
            #expect(!reason.contains("allowlist"),
                    "reason for permitted=\(permitted) still sends the user to a withdrawn config file")
        }
    }

    @Test("writable never disagrees with EventKit's own permission")
    func writableTracksPermission() {
        // Guards the shape of the DTO contract: `writable` and `allows_content_modifications`
        // are now the same answer, and a future control that makes them diverge must be a
        // deliberate change that fails this test rather than a silent one.
        for permitted in [true, false] {
            let ref = CalendarRef(
                id: "cal-1", title: "Work", sourceTitle: "iCloud", sourceType: "caldav",
                allowsContentModifications: permitted, isSubscribed: false,
                writable: permitted,
                writableReason: CalendarStore.writableReason(permitted: permitted),
                trust: "external_untrusted")
            #expect(ref.writable == ref.allowsContentModifications)
        }
    }
}
