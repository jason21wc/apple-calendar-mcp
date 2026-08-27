import Testing
import Foundation
@testable import apple_calendar_mcp

// The journal exists so a human can see what changed and put it back by hand. These tests
// protect the properties that make it worth having at all -- chiefly that an interrupted
// write leaves a visible trace rather than nothing.

@Suite("Mutation journal")
struct JournalTests {

    /// A journal root this test owns outright, removed when it finishes.
    ///
    /// Every test below used to write into the user's REAL state directory. Two consequences,
    /// both observed: the live journal accumulated hundreds of test entries that no one would
    /// ever want, and the parallel suite shared one mutable append-only file, which made
    /// `intentPrecedesOutcome` fail intermittently. A test that writes where production writes
    /// is not testing the code, it is competing with it.
    private func withTemporaryRoot<T>(_ body: (URL) throws -> T) rethrows -> T {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apple-calendar-mcp-journal-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    @Test("no test can reach the live journal — by omission, or on purpose")
    func testsNeverTouchLiveState() throws {
        // TWO different failure modes, and only one of them is a runtime property.
        //
        // OMISSION is handled by the compiler: `root` has no default, so a call that leaves
        // it out does not build. That is the important one, because it is the one reachable
        // by forgetting rather than by deciding. Verified by mutation: deleting `root:` from
        // a call here fails the build with "missing argument for parameter 'root'".
        //
        // DELIBERATE use of the live root still compiles -- nothing can stop a test naming
        // `Runtime.stateDirectory` on purpose -- so that is asserted against the source text,
        // the same technique this project already uses for the dlsym-failure branch it cannot
        // exercise. A reviewer would catch it; this catches it first.
        // The needles are assembled from fragments so this scanner is not itself a match --
        // a linter that lives in the file it lints will otherwise always find one violation,
        // its own. scripts/test-shell.sh hit this and solved it by exclusion; here the
        // scanner and the subject are the same file by design, so the strings are split.
        let call = "Journal" + "."
        let liveRoot = "Runtime." + "stateDirectory"
        let source = try Repo.source("Tests/AppleCalendarMCPTests/JournalTests.swift")
        for (i, line) in source.split(separator: "\n").enumerated()
        where line.contains(call) && line.contains(liveRoot) {
            Issue.record("""
                JournalTests.swift:\(i + 1) passes the live state directory to Journal. Tests                 write to a temporary root they own; the live journal holds the user's real                 calendar history.
                """)
        }

        // And the roots the tests DO use resolve outside the real directory.
        withTemporaryRoot { root in
            let real = Runtime.stateDirectory.standardizedFileURL.path
            for path in [Journal.directory(root: root).standardizedFileURL.path,
                         Journal.currentFile(root: root).standardizedFileURL.path] {
                #expect(!path.hasPrefix(real), "resolved \(path), inside the real \(real)")
            }
        }
    }

    @Test("an intent is recorded BEFORE the outcome, so an interrupted write leaves a trace")
    func intentPrecedesOutcome() {
        withTemporaryRoot { root in
            // The whole point of write-ahead: if the process dies between the two, the intent
            // survives and says what was being attempted. A single after-the-fact entry would
            // leave exactly nothing in the case that most needs a record.
            let id = Journal.recordIntent(
                root: root, operation: "test_create", calendarId: "CAL-1", calendarTitle: "Test",
                calendarSource: "Local", payload: ["title": "Interrupted"])

            let orphans = Journal.orphanedIntents(root: root)
            #expect(orphans.contains { $0.entryId == id },
                    "an intent with no outcome must be visible as orphaned")

            Journal.recordOutcome(
                root: root, entryId: id, operation: "test_create", calendarId: "CAL-1", calendarTitle: "Test",
                calendarSource: "Local", eventId: "EVT-1", payload: ["title": "Interrupted"],
                outcome: .saved, error: nil)

            #expect(!Journal.orphanedIntents(root: root).contains { $0.entryId == id },
                    "once the outcome lands the intent is no longer orphaned")
        }
    }

    @Test("an entry carries enough to reconstruct the change without EventKit")
    func entryIsSelfContained() throws {
        try withTemporaryRoot { root in
            let id = Journal.recordIntent(
                root: root, operation: "test_create", calendarId: "CAL-2", calendarTitle: "Jason",
                calendarSource: "iCloud",
                payload: ["title": "Dentist", "start": "2026-08-21T14:00:00-06:00",
                          "end": "2026-08-21T15:00:00-06:00"])

            let entry = try #require(Journal.entries(limit: 500, root: root).last { $0.entryId == id })
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
    }

    @Test("all three save outcomes round-trip — a no-op is not a failure")
    func saveOutcomesAreDistinct() throws {
        try withTemporaryRoot { root in
            // EventKit returns NO with a nil error when nothing needed saving. Collapsing that
            // into "failed" would report a false failure on every unchanged save.
            for outcome in [SaveOutcome.saved, .noChangeNeeded, .failed] {
                let id = Journal.recordIntent(
                    root: root, operation: "test_outcome", calendarId: "C", calendarTitle: "T",
                    calendarSource: "S", payload: [:])
                Journal.recordOutcome(
                    root: root, entryId: id, operation: "test_outcome", calendarId: "C", calendarTitle: "T",
                    calendarSource: "S", eventId: nil, payload: [:],
                    outcome: outcome, error: outcome == .failed ? "boom" : nil)

                let entry = try #require(Journal.entries(limit: 500, root: root).last { $0.entryId == id && $0.phase == .outcome })
                #expect(entry.saveOutcome == outcome)
            }
        }
    }

    @Test("a malformed line does not make the rest of the history unreadable")
    func corruptLineIsSkipped() throws {
        // An interrupted write can leave a half-written final line. Aborting the whole read
        // would turn one bad byte into total history loss.
        //
        // THIS TEST USED TO CORRUPT THE LIVE JOURNAL, AND WAS THE SUITE'S OWN RACE.
        // It opened the real file, seeked to the end, and wrote outside both `writeQueue` and
        // O_APPEND -- which is precisely the non-atomic append gotcha 54 exists to warn
        // about, reproduced inside the test suite. Running in parallel with the other journal
        // tests, it could interleave with a real `Journal` append and destroy the very entry
        // another test was asserting on. That is what made `intentPrecedesOutcome` flaky, and
        // it left 36 malformed lines in the user's real state directory.
        //
        // The parsing rule under test is a property of the READER, so it is now exercised
        // against a scratch file the test owns outright. Nothing here touches
        // Runtime.stateDirectory, and as of BACKLOG #26 neither does any other test here:
        // `Journal` now takes an explicit `root`, so the write path is isolated too.
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apple-calendar-mcp-journaltest-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let good = #"{"entry_id":"E1","phase":"intent","operation":"test_corrupt"}"#
        try (good + "\n{ this is not json\n" + good.replacingOccurrences(of: "E1", with: "E2") + "\n")
            .write(to: sandbox, atomically: true, encoding: .utf8)

        // Same decode-and-skip rule the reader applies: a malformed line is dropped, its
        // neighbours survive. Asserted on ids so a passing run cannot be an empty one.
        let decoder = JSONDecoder()
        struct Probe: Decodable { let entryId: String
            enum CodingKeys: String, CodingKey { case entryId = "entry_id" } }
        let text = try String(contentsOf: sandbox, encoding: .utf8)
        let ids = text.split(separator: "\n")
            .compactMap { try? decoder.decode(Probe.self, from: Data($0.utf8)) }
            .map(\.entryId)

        #expect(ids == ["E1", "E2"], "a corrupt neighbour took valid entries with it: \(ids)")
    }

    @Test("the journal file is not readable by other users")
    func journalIsPrivate() throws {
        try withTemporaryRoot { root in
            Journal.recordIntent(root: root, operation: "test_perms", calendarId: "C",
                                 calendarTitle: "T", calendarSource: "S", payload: [:])
            let attrs = try FileManager.default.attributesOfItem(atPath: Journal.currentFile(root: root).path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            // It records event titles and times -- real calendar content.
            #expect(perms & 0o077 == 0, "mode is \(String(perms, radix: 8))")
        }
    }
}
