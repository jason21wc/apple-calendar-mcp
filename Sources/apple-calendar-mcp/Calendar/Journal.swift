// A record of every change this server makes to the calendar.
//
// WRITE-AHEAD, TWO ENTRIES PER MUTATION.
//
// The intent is written BEFORE the save and the outcome AFTER. Not a single entry afterwards:
// a crash, a hang, or a partial EventKit failure between the two would otherwise leave no
// record that anything was attempted -- which is precisely the situation where a record is
// worth having. An orphaned intent with no outcome is itself the signal that something went
// wrong mid-write.
//
// WHAT THIS IS AND IS NOT.
//
// It is a record for the human: what changed, when, on which calendar, and enough detail to
// put it back by hand. It is append-only BY CONVENTION -- a file owned by the user, in the
// user's home directory, which any same-uid process can rewrite or truncate. PROJECT-MEMORY
// says this plainly about the allowlist and snapshots, and it is equally true here.
//
// So: not evidence against an attacker, and nothing downstream should treat a journal entry
// as proof that this server made a change. Anything needing that guarantee has to hold it in
// process memory, where a file writer cannot reach it.

import Foundation

/// How EventKit's save actually reported. Three outcomes, not two.
///
/// `saveEvent:span:error:` returns NO with a NIL error when the event "wasn't dirty and
/// didn't need saving" -- a success. The header states the correct test is "NO **and** a
/// non-nil error". A naive `if !saved { throw }` reports failure on a successful no-op, and
/// checking only `error != nil` misses real failures.
enum SaveOutcome: String, Codable, Sendable {
    case saved
    case noChangeNeeded
    case failed
}

struct JournalEntry: Codable, Sendable {
    let entryId: String
    let recordedAt: String
    /// `intent` is written before the save; `outcome` after. An intent with no matching
    /// outcome means the process died mid-write.
    let phase: Phase
    let operation: String
    let calendarId: String
    let calendarTitle: String
    let calendarSource: String
    /// Present on the outcome entry once EventKit has assigned one.
    let eventId: String?
    /// Everything needed to reconstruct the change without consulting EventKit. For create
    /// this is what was written; for a future update or delete it is the pre-state.
    let payload: [String: String]
    let saveOutcome: SaveOutcome?
    let errorDescription: String?
    /// Whether this process owned its own privacy identity at the time. An entry written
    /// under an inherited identity means the change was attributed to the host app.
    let privacyIdentity: String

    enum Phase: String, Codable, Sendable {
        case intent
        case outcome
    }

    enum CodingKeys: String, CodingKey {
        case entryId = "entry_id"
        case recordedAt = "recorded_at"
        case phase, operation, payload
        case calendarId = "calendar_id"
        case calendarTitle = "calendar_title"
        case calendarSource = "calendar_source"
        case eventId = "event_id"
        case saveOutcome = "save_outcome"
        case errorDescription = "error_description"
        case privacyIdentity = "privacy_identity"
    }
}

enum Journal {

    /// Serialises appends.
    ///
    /// `seekToEnd` followed by `write` is two operations, not one: two concurrent callers can
    /// interleave and produce a corrupt line, losing BOTH records. Found by the tests before
    /// this shipped -- parallel test execution reproduced exactly the race that concurrent
    /// tool handlers would.
    ///
    /// The file is also opened with O_APPEND, so the kernel positions each write at the end
    /// atomically. Belt and braces: the lock orders writers within this process, O_APPEND
    /// protects against a second process sharing the file.
    private static let writeQueue = DispatchQueue(label: "com.collierhmg.apple-calendar-mcp.journal")

    static var directory: URL {
        Runtime.stateDirectory.appendingPathComponent("journal", isDirectory: true)
    }

    /// Monthly files, so a long-lived install does not accumulate one unbounded file and a
    /// human looking for "what happened in August" has somewhere obvious to look.
    static func currentFile(now: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeSemantics.systemZone
        f.dateFormat = "yyyy-MM"
        return directory.appendingPathComponent("\(f.string(from: now)).jsonl")
    }

    /// Record an intent and return its id. Call BEFORE mutating.
    @discardableResult
    static func recordIntent(operation: String,
                             calendarId: String, calendarTitle: String, calendarSource: String,
                             payload: [String: String]) -> String {
        let id = UUID().uuidString
        append(JournalEntry(
            entryId: id,
            recordedAt: TimeSemantics.format(Date()),
            phase: .intent,
            operation: operation,
            calendarId: calendarId,
            calendarTitle: calendarTitle,
            calendarSource: calendarSource,
            eventId: nil,
            payload: payload,
            saveOutcome: nil,
            errorDescription: nil,
            privacyIdentity: Runtime.disclaimMode))
        return id
    }

    /// Record what actually happened. Call AFTER the save, whatever the result.
    static func recordOutcome(entryId: String, operation: String,
                              calendarId: String, calendarTitle: String, calendarSource: String,
                              eventId: String?, payload: [String: String],
                              outcome: SaveOutcome, error: String?) {
        append(JournalEntry(
            entryId: entryId,
            recordedAt: TimeSemantics.format(Date()),
            phase: .outcome,
            operation: operation,
            calendarId: calendarId,
            calendarTitle: calendarTitle,
            calendarSource: calendarSource,
            eventId: eventId,
            payload: payload,
            saveOutcome: outcome,
            errorDescription: error,
            privacyIdentity: Runtime.disclaimMode))
    }

    // MARK: - Writing

    private static func append(_ entry: JournalEntry) {
        writeQueue.sync { appendLocked(entry) }
    }

    private static func appendLocked(_ entry: JournalEntry) {
        Runtime.ensureStateDirectory()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // one line per entry; stable field order
        guard var line = try? encoder.encode(entry) else {
            log("journal: could not encode a \(entry.phase.rawValue) entry for \(entry.operation)")
            return
        }
        line.append(0x0A)   // newline

        let file = currentFile()

        // O_APPEND makes each write land at the end atomically, rather than the
        // seek-then-write pair which another writer can slip between. Created 0600 from the
        // outset -- it holds event titles and times, so it must never exist world-readable
        // even briefly.
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            log("journal: could not open \(file.path): \(String(cString: strerror(errno)))")
            return
        }
        defer { close(fd) }

        line.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                // A short write is legal and must be resumed, not treated as done.
                if n <= 0 {
                    if errno == EINTR { continue }
                    log("journal: write failed: \(String(cString: strerror(errno)))")
                    return
                }
                written += n
            }
        }
    }

    // MARK: - Reading

    /// Entries for the current month, oldest first. Malformed lines are skipped rather than
    /// aborting the read -- a truncated final line from an interrupted write must not make
    /// the whole history unreadable.
    static func entries(limit: Int = 100) -> [JournalEntry] {
        guard let data = try? Data(contentsOf: currentFile()),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n")
            .compactMap { try? decoder.decode(JournalEntry.self, from: Data($0.utf8)) }
            .suffix(limit)
    }

    /// Intents with no matching outcome: writes that began and never reported back.
    static func orphanedIntents() -> [JournalEntry] {
        let all = entries(limit: 1000)
        let completed = Set(all.filter { $0.phase == .outcome }.map(\.entryId))
        return all.filter { $0.phase == .intent && !completed.contains($0.entryId) }
    }
}
