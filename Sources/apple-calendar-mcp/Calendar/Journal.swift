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
// says this plainly about the snapshots, and it is equally true here.
//
// So: not evidence against an attacker, and nothing downstream should treat a journal entry
// as proof that this server made a change. Anything needing that guarantee has to hold it in
// process memory, where a file writer cannot reach it.

import Foundation
import Darwin

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

enum JournalError: Error, Equatable {
    case storageFailure
    case storageBusy
    case corruptHistory
    case readLimitExceeded
    case recordTooLarge
    case invalidLimit
}

enum Journal {
    static let maxRecordBytes = 1_048_576
    static let maxReadBytes = 16_777_216

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

    /// Where the journal lives.
    ///
    /// `root` is REQUIRED and has no default, deliberately.
    ///
    /// It began as a defaulted parameter, which fixed the tests that passed one and did
    /// nothing about the failure that actually matters: a test that simply OMITS it. With a
    /// default of `Runtime.stateDirectory`, omission is silent and writes calendar history
    /// into the user's home -- the exact bug this parameter exists to prevent, reachable by
    /// forgetting rather than by doing anything wrong. A runtime guard cannot see that; it
    /// can only check the roots it is handed.
    ///
    /// With no default, omission does not compile. `Journal` has no production caller yet, so
    /// this costs nothing today and obliges the write surface to state where it writes at
    /// every call site, which is the right thing to be explicit about.
    ///
    /// Deliberately NOT a settable static either. A mutable global redirecting where calendar
    /// history lands is the shape this project has twice been bitten by: a value handed to
    /// you cannot authenticate its own setter.
    static func directory(root: URL) -> URL {
        root.appendingPathComponent("journal", isDirectory: true)
    }

    /// Monthly files, so a long-lived install does not accumulate one unbounded file and a
    /// human looking for "what happened in August" has somewhere obvious to look.
    static func currentFile(now: Date = Date(), root: URL) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .gmt
        f.dateFormat = "yyyy-MM"
        return directory(root: root).appendingPathComponent("\(f.string(from: now)).jsonl")
    }

    /// Record an intent and return its id. Call BEFORE mutating.
    @discardableResult
    static func recordIntent(root: URL,
                             operation: String,
                             calendarId: String, calendarTitle: String, calendarSource: String,
                             payload: [String: String], now: Date = Date()) throws -> String {
        let id = UUID().uuidString
        try append(JournalEntry(
            entryId: id,
            recordedAt: TimeSemantics.format(now, in: .gmt),
            phase: .intent,
            operation: operation,
            calendarId: calendarId,
            calendarTitle: calendarTitle,
            calendarSource: calendarSource,
            eventId: nil,
            payload: payload,
            saveOutcome: nil,
            errorDescription: nil,
            privacyIdentity: Runtime.disclaimMode), now: now, root: root)
        return id
    }

    /// Record what actually happened. Call AFTER the save, whatever the result.
    static func recordOutcome(root: URL,
                              entryId: String, operation: String,
                              calendarId: String, calendarTitle: String, calendarSource: String,
                              eventId: String?, payload: [String: String],
                              outcome: SaveOutcome, error: String?, now: Date = Date()) throws {
        try append(JournalEntry(
            entryId: entryId,
            recordedAt: TimeSemantics.format(now, in: .gmt),
            phase: .outcome,
            operation: operation,
            calendarId: calendarId,
            calendarTitle: calendarTitle,
            calendarSource: calendarSource,
            eventId: eventId,
            payload: payload,
            saveOutcome: outcome,
            errorDescription: error,
            privacyIdentity: Runtime.disclaimMode), now: now, root: root)
    }

    // MARK: - Writing

    /// A successful return means the complete record and directory entry were fsynced.
    /// This is an OS durability acknowledgement, not a promise against disk failure.
    /// Callers MUST NOT mutate if intent recording throws. An outcome error after a future
    /// save means an uncertain recorded outcome, not permission to retry that save.
    private static func append(_ entry: JournalEntry, now: Date, root: URL) throws {
        try writeQueue.sync {
            do { try appendLocked(entry, now: now, root: root) }
            catch let error as JournalError { throw error }
            catch { throw JournalError.storageFailure }
        }
    }

    private static func appendLocked(_ entry: JournalEntry, now: Date, root: URL) throws {
        let fm = FileManager.default
        var parentsToSync = [directory(root: root), root, root.deletingLastPathComponent()]
        var ancestor = root
        while !fm.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent != ancestor else { throw JournalError.storageFailure }
            parentsToSync.append(parent)
            ancestor = parent
        }
        for dir in [root, directory(root: root)] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(entry)
        line.append(0x0A)
        guard line.count <= maxRecordBytes else { throw JournalError.recordTooLarge }

        let file = currentFile(now: now, root: root)
        let fd = open(file.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw JournalError.storageFailure }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              fchmod(fd, 0o600) == 0 else { throw JournalError.storageFailure }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw JournalError.storageBusy }
        defer { flock(fd, LOCK_UN) }
        // Never append a valid record onto an interrupted, unterminated one.
        let end = lseek(fd, 0, SEEK_END)
        guard end >= 0 else { throw JournalError.storageFailure }
        if end > 0 {
            var last: UInt8 = 0
            guard pread(fd, &last, 1, end - 1) == 1 else { throw JournalError.storageFailure }
            guard last == 0x0A else { throw JournalError.corruptHistory }
        }
        try line.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw JournalError.storageFailure }
                written += n
            }
        }
        guard fsync(fd) == 0 else { throw JournalError.storageFailure }
        // Persist file/directory creation as well, from the journal directory upwards.
        for dir in parentsToSync {
            let directoryFD = open(dir.path, O_RDONLY | O_DIRECTORY)
            guard directoryFD >= 0 else { throw JournalError.storageFailure }
            let synced = fsync(directoryFD)
            close(directoryFD)
            guard synced == 0 else { throw JournalError.storageFailure }
        }
    }

    // MARK: - Reading

    /// Recent records across monthly files, oldest first. Reads the tail in fixed-size
    /// blocks rather than decoding an entire month just to return its final records.
    /// A missing journal is empty; unreadable/corrupt/over-budget history is an error.
    /// `since` selects a recovery horizon; nil scans all history subject to the byte budget.
    static func entries(limit: Int = 100, since: Date? = nil, root: URL,
                        byteLimit: Int = maxReadBytes) throws -> [JournalEntry] {
        guard limit > 0 else { throw JournalError.invalidLimit }
        return try readEntries(limit: limit, since: since, root: root, byteLimit: byteLimit)
    }

    /// Do not use a display tail (e.g. 1000 records) to decide which intents lack outcomes.
    /// Every entry in the requested horizon is reconciled, or the call explicitly fails.
    static func orphanedIntents(since: Date? = nil, root: URL,
                               byteLimit: Int = maxReadBytes) throws -> [JournalEntry] {
        let all = try readEntries(limit: nil, since: since, root: root, byteLimit: byteLimit)
        let completed = Set(all.filter { $0.phase == .outcome }.map(\.entryId))
        return all.filter { $0.phase == .intent && !completed.contains($0.entryId) }
    }

    private static func readEntries(limit: Int?, since: Date?, root: URL,
                                    byteLimit: Int) throws -> [JournalEntry] {
        guard byteLimit > 0 else { throw JournalError.readLimitExceeded }
        do {
            // contentsOfDirectory throws for permissions/type errors. Only genuine absence
            // is empty history; fileExists would also return false for inaccessible paths.
            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(
                    at: directory(root: root), includingPropertiesForKeys: nil)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return []
            }
            // Include a boundary margin for older files rotated in the machine's local zone.
            let firstMonth = since.map {
                currentFile(now: $0.addingTimeInterval(-36 * 3600), root: root).lastPathComponent
            }
            let months = files.filter {
                $0.lastPathComponent.range(of: #"^\d{4}-\d{2}\.jsonl$"#,
                                            options: .regularExpression) != nil
                && (firstMonth == nil || $0.lastPathComponent >= firstMonth!)
            }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            var remaining = byteLimit
            var found: [JournalEntry] = []
            let decoder = JSONDecoder()
            for file in months {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                guard flock(handle.fileDescriptor, LOCK_SH | LOCK_NB) == 0 else {
                    throw JournalError.storageBusy
                }
                defer { flock(handle.fileDescriptor, LOCK_UN) }
                var offset = try handle.seekToEnd()
                var suffix = Data()
                var checkedTail = false
                while offset > 0 {
                    guard remaining > 0 else { throw JournalError.readLimitExceeded }
                    let count = Int(min(offset, UInt64(min(65_536, remaining))))
                    offset -= UInt64(count)
                    try handle.seek(toOffset: offset)
                    guard let chunk = try handle.read(upToCount: count), chunk.count == count else {
                        throw JournalError.storageFailure
                    }
                    remaining -= chunk.count
                    if !checkedTail {
                        guard chunk.last == 0x0A else { throw JournalError.corruptHistory }
                        checkedTail = true
                    }
                    var data = chunk
                    data.append(suffix)
                    let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
                    // The first fragment may start in the middle of a record.
                    let complete = offset == 0 ? lines[...] : lines.dropFirst()
                    for line in complete.reversed() where !line.isEmpty {
                        guard line.count <= maxRecordBytes else { throw JournalError.recordTooLarge }
                        guard let entry = try? decoder.decode(JournalEntry.self, from: Data(line)),
                              let recorded = try? TimeSemantics.parseTimestamp(entry.recordedAt) else {
                            throw JournalError.corruptHistory
                        }
                        if since == nil || recorded >= since! { found.append(entry) }
                        if let limit, found.count >= limit { return found.reversed() }
                    }
                    suffix = offset == 0 ? Data() : Data(lines[0])
                    guard suffix.count <= maxRecordBytes else { throw JournalError.recordTooLarge }
                }
            }
            return found.reversed()
        } catch let error as JournalError { throw error }
        catch { throw JournalError.storageFailure }
    }
}
