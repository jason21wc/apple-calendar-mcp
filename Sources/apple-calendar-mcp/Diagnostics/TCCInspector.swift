// Reading the TCC database to find out whether the Calendar grant is actually OURS.
//
// WHY THIS EXISTS
// `EKEventStore.authorizationStatus(for:)` cannot answer the question that matters. A child
// process inherits its parent's grant, so a binary spawned by an already-authorized app
// reports `.fullAccess` while owning no permission of its own. Measured during Phase 1: the
// probe reported `.fullAccess` purely because the terminal that launched it had access, and
// there was no TCC row for this binary at all.
//
// That is not a cosmetic distinction. Inherited access disappears the moment a different
// host launches the server -- and per Entitlements.plist the resulting denial is silent.
// Diagnosing it from `authorizationStatus` alone is impossible, so `--doctor` reads the
// database directly.
//
// The user-scoped TCC database is readable with ordinary file access; no Full Disk Access
// is required for the user's own file. If that changes on a future macOS, every lookup here
// degrades to `.unreadable` and the diagnostic says so rather than guessing.

import Foundation

struct TCCGrant {
    let client: String
    /// 0 = bundle identifier, 1 = absolute path. Ours is 1: measured, the grant is keyed to
    /// where the binary lives, so moving it loses access.
    let clientType: Int
    let authValue: Int

    var isAllowed: Bool { authValue == 2 }
}

enum TCCLookup {
    case found(TCCGrant)
    case noRowForUs
    case unreadable(String)
}

enum TCCInspector {

    static let databasePath = NSString(string: "~/Library/Application Support/com.apple.TCC/TCC.db")
        .expandingTildeInPath

    /// Look for a Calendar grant belonging to this exact binary path.
    static func calendarGrant(forPath path: String) -> TCCLookup {
        guard FileManager.default.isReadableFile(atPath: databasePath) else {
            return .unreadable("TCC database not readable at \(databasePath)")
        }

        // sqlite3 as a subprocess rather than linking SQLite: this is diagnostic-only code
        // that runs on an explicit --doctor invocation, never in the server hot path, and
        // avoids taking a dependency purely for one query.
        let query = """
            SELECT client, client_type, auth_value FROM access \
            WHERE service='kTCCServiceCalendar';
            """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = ["-readonly", "-separator", "|", databasePath, query]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                return .unreadable("sqlite3 exited \(task.terminationStatus)")
            }

            let rows = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }

            for row in rows where row.count >= 3 {
                // Exact match only. A prefix or contains match would report a grant that
                // belongs to a different binary as if it were ours.
                if row[0] == path {
                    return .found(TCCGrant(client: row[0],
                                           clientType: Int(row[1]) ?? -1,
                                           authValue: Int(row[2]) ?? -1))
                }
            }
            return .noRowForUs
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }
}
