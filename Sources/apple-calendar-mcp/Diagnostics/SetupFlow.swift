// --setup: request Calendar access, interactively, from a terminal.
//
// This is a COMMAND rather than an MCP tool for a structural reason: a TCC prompt requires a
// foreground process, and a server launched over stdio by an MCP client cannot reliably
// present one. Exposing setup as a tool would produce a request that silently never prompts.

import Foundation
import EventKit

enum SetupFlow {

    static func run(store: EKEventStore) async -> Int32 {
        let path = Meta.executablePath

        log("apple-calendar-mcp \(Meta.version) -- setup")
        log("path: \(path)")
        log("")

        // Refuse to proceed under inherited identity. Granting here would attach the
        // permission to the launching app, which is the exact failure this project spent
        // Phase 1 diagnosing -- it looks like success and breaks under a different host.
        if disclaimMode != "disclaimed-child" {
            log("[FAIL] cannot claim an independent privacy identity (\(disclaimMode)).")
            log("       Granting now would attach Calendar access to whatever launched this")
            log("       process, not to apple-calendar-mcp. Run --doctor for detail.")
            return 1
        }

        let before = AuthorizationState.current
        log("current status: \(before.rawValue)")

        switch before {
        case .fullAccess:
            // Already granted is not necessarily granted TO US.
            if case .found(let g) = TCCInspector.calendarGrant(forPath: path), g.isAllowed {
                log("Already granted to this binary at this path. Nothing to do.")
                return 0
            }
            log("Status reads fullAccess but no grant exists for this path, so it is")
            log("inherited from the launching app. Reset and grant it properly with:")
            log("  tccutil reset Calendar \(Meta.bundleIdentifier)")
            log("then run --setup again.")
            return 1

        case .denied, .restricted, .writeOnly:
            log(before.guidance)
            return 1

        case .notDetermined:
            log("Requesting Calendar access. Approve the prompt that appears.")
            do {
                let granted = try await store.requestFullAccessToEvents()
                log(granted ? "Access granted." : "Access refused.")
            } catch {
                log("Request failed: \(error.localizedDescription)")
                return 1
            }

        case .unknown:
            log(before.guidance)
            return 1
        }

        let after = AuthorizationState.current
        log("status now: \(after.rawValue)")

        // Verify the grant landed on US rather than on the terminal. Because we are running
        // disclaimed, the status we just read IS our own grant -- a disclaimed process sees
        // nothing inherited. TCC.db would corroborate but needs Full Disk Access, so its
        // absence is expected and not treated as failure.
        guard after.canReadEvents else {
            log("[FAIL] status is \(after.rawValue) after the request; access not usable.")
            return 1
        }
        log("Verified: running under our own privacy identity with full access, so this")
        log("grant belongs to this binary at this path.")
        recordSetup(path: path)
        log("")
        log("Add to Claude Code:")
        log("  claude mcp add --transport stdio apple-calendar -- \(path)")
        log("Add to Codex (~/.codex/config.toml):")
        log("  [mcp_servers.apple-calendar]")
        log("  command = \"\(path)\"")
        return 0
    }

    /// Record what was granted and where, so --doctor can say "your grant belongs to a
    /// different path" instead of reporting a bare denial.
    private static func recordSetup(path: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/apple-calendar-mcp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "granted_path": path,
            "bundle_identifier": Meta.bundleIdentifier,
            "version": Meta.version,
            "recorded_at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("setup.json"))
        }
    }
}
