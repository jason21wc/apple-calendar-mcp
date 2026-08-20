// Process-wide runtime facts, held in a type rather than as top-level globals.
//
// WHY THIS TYPE EXISTS
// These started life as `let` bindings in main.swift. Top-level code in a Swift executable
// is @MainActor-isolated, and reading such a binding from a test crashes the test host with
// SIGSEGV -- taking the entire run with it, not just the one test. That made Doctor.run()
// and SetupFlow.run() unreachable from tests, and SetupFlow's refusal-under-inherited-
// identity branch is a real safety property: it is what stops Calendar permission being
// granted to the launching app instead of to this binary.
//
// Lazy statics are initialised on first use and are safe to read from any isolation
// context, so the same values are now testable.

import Foundation

enum Runtime {

    /// Why the respawn did not happen, recorded by `establishPrivacyIdentity()`.
    ///
    /// Write-once at startup, read-only afterwards. Deliberately NOT computed on demand:
    /// an earlier version performed the respawn lazily on first read, which meant that
    /// merely ASKING about the identity from a test would posix_spawn a copy of the test
    /// host with the test host's argv. A question must not have that side effect.
    nonisolated(unsafe) private static var respawnFailureReason: String?

    /// Perform the one-time respawn that gives this process its own privacy identity.
    /// Call once, first thing in main. Does not return if the respawn succeeds.
    static func establishPrivacyIdentity() {
        guard !Reexec.isDisclaimedChild else { return }
        _ = Reexec.respawnDisclaimed()        // exits the supervisor on success
        respawnFailureReason = Reexec.disclaimAvailable
            ? "inherited-respawn-failed"
            : "inherited-symbol-missing"
    }

    /// How this process obtained -- or failed to obtain -- its own privacy identity.
    ///
    /// `disclaimed-child` is the only value meaning Calendar access belongs to THIS binary.
    /// Anything else means it is inherited from whatever launched us and will vanish under
    /// a different host. Asks the kernel; never consults the environment, and never spawns.
    static var disclaimMode: String {
        if Reexec.isDisclaimedChild { return "disclaimed-child" }
        return respawnFailureReason ?? "inherited-not-attempted"
    }

    /// True only when the process owns its privacy identity.
    static var ownsPrivacyIdentity: Bool { disclaimMode == "disclaimed-child" }

    /// Whether this process may expose any mutating tool at all.
    ///
    /// Read ONCE from argv at startup and never re-read, so it is a property of the client's
    /// configuration rather than of model behaviour -- the model cannot argue its way past a
    /// value it never sees and cannot set.
    ///
    /// This exists because the human approval prompt is the only real gate, and some hosts
    /// do not have one. Scheduled and autonomous surfaces (Cowork tasks) can run with no
    /// human present, so "the host will ask" is not true there. Configure those hosts
    /// read-only and the question does not arise.
    ///
    /// Deliberately shipped BEFORE any write tool exists: a client configured today keeps
    /// its restriction when write tools arrive, instead of silently gaining them.
    nonisolated(unsafe) private static var readOnlyRequested = false

    static var isReadOnly: Bool { readOnlyRequested }

    static func applyStartupFlags(_ args: [String]) {
        readOnlyRequested = args.contains("--read-only")
    }

    /// Probe records, the setup fingerprint and (from Phase 5) the mutation journal.
    /// 0700 because Phase 5 puts real calendar content here.
    static let stateDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/apple-calendar-mcp", isDirectory: true)

    /// Create the state directory if absent, and ENFORCE 0700 whether or not it existed.
    ///
    /// The enforcement is the point. `createDirectory` succeeds on an existing directory
    /// without touching its attributes, so passing `posixPermissions` only ever protected a
    /// fresh install -- every machine that had already run an older build kept 0755, and
    /// Phase 5 writes event titles, notes and attendee names here.
    @discardableResult
    static func ensureStateDirectory() -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: stateDirectory.path) {
            guard (try? fm.createDirectory(
                at: stateDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])) != nil else { return false }
            return true
        }
        // Existing directory: tighten it. Cheap, idempotent, and the only thing that fixes
        // an install created before this was enforced.
        if let perms = (try? fm.attributesOfItem(atPath: stateDirectory.path))?[.posixPermissions]
            as? NSNumber, perms.intValue & 0o077 != 0 {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        }
        return true
    }
}
