// Which calendars may ever be written to.
//
// Read ONCE at process start and never re-read. That is deliberate: re-reading would let a
// same-uid process widen the set mid-session by editing a file. Reading once means widening
// it requires a restart, which requires the user to act.
//
// Be clear about what this is worth. The config file is owned by the user, so an attacker
// with filesystem write can edit it and wait for the next respawn -- and clients respawn
// stdio servers without warning. This narrows the blast radius of a mistaken or manipulated
// model. It is not a boundary against a compromised machine.
//
// In Phase 4 there are no write tools, so this only decides the `writable` flag reported by
// calendar_list_calendars. It ships now so the file format and the load-once rule are settled
// before anything depends on them.

import Foundation

struct AllowlistEntry: Codable, Sendable, Hashable {
    let calendarIdentifier: String
    let expectedTitle: String
    let expectedSource: String

    enum CodingKeys: String, CodingKey {
        case calendarIdentifier = "calendar_identifier"
        case expectedTitle = "expected_title"
        case expectedSource = "expected_source"
    }
}

enum Allowlist {

    static let configPath: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/apple-calendar-mcp/allowlist.json", isDirectory: false)

    /// Loaded once, on first access, and cached for the process's lifetime.
    private static let entries: [AllowlistEntry] = {
        guard let data = try? Data(contentsOf: configPath) else { return [] }
        guard let decoded = try? JSONDecoder().decode([AllowlistEntry].self, from: data) else {
            // A malformed file means NO writable calendars, not "all of them". Failing open
            // here would turn a typo into unrestricted write access.
            log("allowlist at \(configPath.path) could not be parsed; treating as empty")
            return []
        }
        return decoded
    }()

    /// Identifiers permitted for writing, subject to the title and source also matching.
    ///
    /// All three must match. An identifier alone is fragile -- EventKit identifiers change on
    /// a full sync -- and a title alone is attacker-influenceable, since calendar names are
    /// untrusted external data. Requiring both means a mismatch fails closed rather than
    /// resolving to the wrong calendar.
    static var writableCalendarIds: Set<String> {
        Set(entries.map(\.calendarIdentifier))
    }

    static func verify(identifier: String, title: String, source: String) -> Bool {
        entries.contains {
            $0.calendarIdentifier == identifier
                && $0.expectedTitle == title
                && $0.expectedSource == source
        }
    }

    static var isEmpty: Bool { entries.isEmpty }
}
