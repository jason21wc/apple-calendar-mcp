import Testing
import Foundation
import Darwin
@testable import apple_calendar_mcp

// The journal exists so a human can see what changed and put it back by hand. These tests
// protect the properties that make it worth having at all -- chiefly that an interrupted
// write leaves a visible trace rather than nothing.

@Suite("Mutation journal")
struct JournalTests {
    @Test("an in-progress append is busy, not corrupt, for readers and other writers")
    func concurrentLock() throws {
        try withTemporaryRoot { root in
            _ = try intent(root)
            let fd = open(Journal.currentFile(root: root).path, O_RDWR)
            try #require(fd >= 0)
            defer { close(fd) }
            try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
            defer { flock(fd, LOCK_UN) }
            #expect(throws: JournalError.storageBusy) { try Journal.entries(root: root) }
            #expect(throws: JournalError.storageBusy) { try intent(root) }
        }
    }

    @Test("a record larger than one reader block survives stitching and exact byte budgets")
    func multiBlockRecord() throws {
        try withTemporaryRoot { root in
            let nested = root.appendingPathComponent("nested/state/calendar")
            let payload = ["notes": String(repeating: "z", count: 150_000)]
            let id = try Journal.recordIntent(root: nested, operation: "create", calendarId: "C",
                                              calendarTitle: "T", calendarSource: "S", payload: payload)
            let size = try Data(contentsOf: Journal.currentFile(root: nested)).count
            let entries = try Journal.entries(limit: 1, root: nested, byteLimit: size)
            #expect(entries.first?.entryId == id)
            #expect(entries.first?.payload == payload)
            #expect(throws: JournalError.readLimitExceeded) {
                try Journal.entries(limit: 1, root: nested, byteLimit: size - 1)
            }
        }
    }

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

    @Test("an intent precedes its outcome and both are acknowledged")
    func intentPrecedesOutcome() throws {
        try withTemporaryRoot { root in
            let id = try intent(root)
            #expect(try Journal.orphanedIntents(root: root).map(\.entryId) == [id])
            try Journal.recordOutcome(root: root, entryId: id, operation: "create",
                                      calendarId: "C", calendarTitle: "T", calendarSource: "S",
                                      eventId: "E", payload: ["title": "Appointment"],
                                      outcome: .saved, error: nil)
            #expect(try Journal.orphanedIntents(root: root).isEmpty)
            #expect(try Journal.entries(root: root).map(\.phase) == [.intent, .outcome])
        }
    }

    private func intent(_ root: URL, now: Date = Date()) throws -> String {
        try Journal.recordIntent(root: root, operation: "create", calendarId: "C",
                                 calendarTitle: "T", calendarSource: "S",
                                 payload: ["title": "Appointment"], now: now)
    }

    @Test("failed intent and outcome storage throws instead of acknowledging a record")
    func failedStorage() throws {
        try withTemporaryRoot { root in
            try Data().write(to: root) // A file cannot serve as a directory.
            #expect(throws: JournalError.storageFailure) { try intent(root) }
            #expect(throws: JournalError.storageFailure) {
                try Journal.recordOutcome(root: root, entryId: "E", operation: "create",
                                          calendarId: "C", calendarTitle: "T", calendarSource: "S",
                                          eventId: nil, payload: [:], outcome: .failed, error: nil)
            }
            #expect(throws: JournalError.storageFailure) { try Journal.entries(root: root) }
        }
    }

    @Test("missing history is empty, but corruption is never mistaken for empty history")
    func corruptHistory() throws {
        try withTemporaryRoot { root in
            #expect(try Journal.entries(root: root).isEmpty)
            _ = try intent(root)
            let file = Journal.currentFile(root: root)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{bad record}\n".utf8))
            try handle.close()
            #expect(throws: JournalError.corruptHistory) { try Journal.entries(root: root) }
            #expect(throws: JournalError.corruptHistory) { try Journal.orphanedIntents(root: root) }
        }
    }

    @Test("a torn append blocks reading and further appends without altering the evidence")
    func tornRecord() throws {
        try withTemporaryRoot { root in
            _ = try intent(root)
            let file = Journal.currentFile(root: root)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{partial".utf8))
            try handle.close()
            let before = try Data(contentsOf: file)
            #expect(throws: JournalError.corruptHistory) { try Journal.entries(root: root) }
            #expect(throws: JournalError.corruptHistory) { try intent(root) }
            #expect(try Data(contentsOf: file) == before)
        }
    }

    @Test("month-end intent/outcome pairing and a 72-hour horizon include yesterday")
    func monthRollover() throws {
        try withTemporaryRoot { root in
            let before = try TimeSemantics.parseTimestamp("2026-08-31T23:59:59Z")
            let after = before.addingTimeInterval(2)
            let id = try intent(root, now: before)
            try Journal.recordOutcome(root: root, entryId: id, operation: "create",
                                      calendarId: "C", calendarTitle: "T", calendarSource: "S",
                                      eventId: "E", payload: [:], outcome: .saved, error: nil,
                                      now: after)
            let since = after.addingTimeInterval(-72 * 3600)
            #expect(try Journal.entries(since: since, root: root).count == 2)
            #expect(try Journal.orphanedIntents(since: since, root: root).isEmpty)
        }
    }

    @Test("all outcomes round-trip, including a successful no-op")
    func saveOutcomes() throws {
        try withTemporaryRoot { root in
            for outcome in [SaveOutcome.saved, .noChangeNeeded, .failed] {
                let id = try intent(root)
                try Journal.recordOutcome(root: root, entryId: id, operation: "create",
                                          calendarId: "C", calendarTitle: "T", calendarSource: "S",
                                          eventId: nil, payload: [:], outcome: outcome, error: nil)
                #expect(try Journal.entries(root: root).last?.saveOutcome == outcome)
            }
        }
    }

    @Test("existing journal permissions are tightened, not just creation defaults")
    func journalIsPrivate() throws {
        try withTemporaryRoot { root in
            _ = try intent(root)
            let file = Journal.currentFile(root: root)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            _ = try intent(root)
            for path in [root, Journal.directory(root: root), file] {
                let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
                let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
                #expect(perms & 0o077 == 0)
            }
        }
    }

    @Test("large histories use a bounded tail; orphan reconciliation cannot silently truncate")
    func boundedHistory() throws {
        try withTemporaryRoot { root in
            let now = Date()
            _ = try intent(root, now: now)
            // Test-owned, synthetic history spanning several reader chunks and the old
            // 1000-entry cutoff. No repeated durable writes are needed to fabricate it.
            let template = try #require(try Journal.entries(root: root).first)
            let encoder = JSONEncoder()
            var data = Data()
            for i in 0..<1200 {
                let entry = JournalEntry(entryId: "entry-\(i)", recordedAt: template.recordedAt,
                                         phase: .intent, operation: "create", calendarId: "C",
                                         calendarTitle: "T", calendarSource: "S", eventId: nil,
                                         payload: ["padding": String(repeating: "x", count: 100)],
                                         saveOutcome: nil, errorDescription: nil, privacyIdentity: "test")
                data.append(try encoder.encode(entry)); data.append(0x0A)
            }
            try data.write(to: Journal.currentFile(now: now, root: root))
            let tail = try Journal.entries(limit: 2, root: root, byteLimit: 65_536)
            #expect(tail.map(\.entryId) == ["entry-1198", "entry-1199"])
            #expect(try Journal.orphanedIntents(root: root).count == 1200)
            #expect(throws: JournalError.readLimitExceeded) {
                try Journal.orphanedIntents(root: root, byteLimit: 65_536)
            }
            #expect(throws: JournalError.invalidLimit) { try Journal.entries(limit: 0, root: root) }
        }
    }
}
