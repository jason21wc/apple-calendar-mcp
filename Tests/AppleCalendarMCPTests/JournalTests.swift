import Testing
import Foundation
@testable import apple_calendar_mcp

// The journal exists so a human can see what changed and put it back by hand. These tests
// protect the properties that make it worth having at all -- chiefly that an interrupted
// write leaves a visible trace rather than nothing.

@Suite("Mutation journal")
struct JournalTests {

    @Test("an intent is recorded BEFORE the outcome, so an interrupted write leaves a trace")
    func intentPrecedesOutcome() {
        // The whole point of write-ahead: if the process dies between the two, the intent
        // survives and says what was being attempted. A single after-the-fact entry would
        // leave exactly nothing in the case that most needs a record.
        let id = Journal.recordIntent(
            operation: "test_create", calendarId: "CAL-1", calendarTitle: "Test",
            calendarSource: "Local", payload: ["title": "Interrupted"])

        let orphans = Journal.orphanedIntents()
        #expect(orphans.contains { $0.entryId == id },
                "an intent with no outcome must be visible as orphaned")

        Journal.recordOutcome(
            entryId: id, operation: "test_create", calendarId: "CAL-1", calendarTitle: "Test",
            calendarSource: "Local", eventId: "EVT-1", payload: ["title": "Interrupted"],
            outcome: .saved, error: nil)

        #expect(!Journal.orphanedIntents().contains { $0.entryId == id },
                "once the outcome lands the intent is no longer orphaned")
    }

    @Test("an entry carries enough to reconstruct the change without EventKit")
    func entryIsSelfContained() throws {
        let id = Journal.recordIntent(
            operation: "test_create", calendarId: "CAL-2", calendarTitle: "Jason",
            calendarSource: "iCloud",
            payload: ["title": "Dentist", "start": "2026-08-21T14:00:00-06:00",
                      "end": "2026-08-21T15:00:00-06:00"])

        let entry = try #require(Journal.entries(limit: 500).last { $0.entryId == id })
        // Calendar identity is recorded as all three fields, not just the identifier --
        // identifiers change on a full sync, so an id alone may not resolve later.
        #expect(entry.calendarTitle == "Jason")
        #expect(entry.calendarSource == "iCloud")
        #expect(entry.payload["title"] == "Dentist")
        #expect(entry.payload["start"] == "2026-08-21T14:00:00-06:00")
        // Whether we owned our privacy identity matters when reading history back: an entry
        // written under an inherited identity means the change was attributed to the host.
        #expect(!entry.privacyIdentity.isEmpty)
    }

    @Test("all three save outcomes round-trip — a no-op is not a failure")
    func saveOutcomesAreDistinct() throws {
        // EventKit returns NO with a nil error when nothing needed saving. Collapsing that
        // into "failed" would report a false failure on every unchanged save.
        for outcome in [SaveOutcome.saved, .noChangeNeeded, .failed] {
            let id = Journal.recordIntent(
                operation: "test_outcome", calendarId: "C", calendarTitle: "T",
                calendarSource: "S", payload: [:])
            Journal.recordOutcome(
                entryId: id, operation: "test_outcome", calendarId: "C", calendarTitle: "T",
                calendarSource: "S", eventId: nil, payload: [:],
                outcome: outcome, error: outcome == .failed ? "boom" : nil)

            let entry = try #require(Journal.entries(limit: 500).last { $0.entryId == id && $0.phase == .outcome })
            #expect(entry.saveOutcome == outcome)
        }
    }

    @Test("a malformed line does not make the rest of the history unreadable")
    func corruptLineIsSkipped() throws {
        // An interrupted write can leave a half-written final line. Aborting the whole read
        // would turn one bad byte into total history loss.
        let id = Journal.recordIntent(
            operation: "test_corrupt", calendarId: "C", calendarTitle: "T",
            calendarSource: "S", payload: [:])

        let file = Journal.currentFile()
        if let handle = try? FileHandle(forWritingTo: file) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("{ this is not json\n".utf8))
            try? handle.close()
        }

        let entries = Journal.entries(limit: 500)
        #expect(entries.contains { $0.entryId == id }, "valid entries survive a corrupt neighbour")
    }

    @Test("the journal file is not readable by other users")
    func journalIsPrivate() throws {
        Journal.recordIntent(operation: "test_perms", calendarId: "C", calendarTitle: "T",
                             calendarSource: "S", payload: [:])
        let attrs = try FileManager.default.attributesOfItem(atPath: Journal.currentFile().path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        // It records event titles and times -- real calendar content.
        #expect(perms & 0o077 == 0, "mode is \(String(perms, radix: 8))")
    }
}
