// --doctor: explain why Calendar access is or is not working.
//
// This exists because the failure mode is silent. On macOS 26.5, a hardened-runtime binary
// missing the calendars entitlement gets no prompt at all -- the request is policy-blocked
// and the denial is permanent, while every status API still reports green. And a binary
// spawned by an authorized host reports full access it does not own. Both look identical
// from inside the process, so something has to check the underlying facts and say plainly
// which one is happening.

import Foundation

enum Verdict {
    case ok(String)
    case warn(String)
    case fail(String)

    var marker: String {
        switch self {
        case .ok:   return "ok  "
        case .warn: return "warn"
        case .fail: return "FAIL"
        }
    }
    var text: String {
        switch self { case .ok(let t), .warn(let t), .fail(let t): return t }
    }
    var isFailure: Bool { if case .fail = self { return true }; return false }
}

enum Doctor {

    static func run() -> Int32 {
        let path = Meta.executablePath
        var checks: [(String, Verdict)] = []

        // 1. Identity: without the embedded plist there is no usage string, and macOS will
        //    not present a meaningful prompt.
        checks.append(("embedded Info.plist", Bundle.main.bundleIdentifier == nil
            ? .fail("no bundle identifier -- Info.plist is not embedded in __TEXT,__info_plist")
            : .ok(Meta.bundleIdentifier)))

        checks.append(("usage description", Bundle.main
            .object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") == nil
            ? .fail("NSCalendarsFullAccessUsageDescription missing -- macOS may refuse to prompt")
            : .ok("present")))

        // 2. Are we our own responsible process? If not, any access we appear to have
        //    belongs to whoever launched us and vanishes under a different host.
        let verified = Reexec.disclaimStateIsVerified
        checks.append(("privacy identity", Runtime.ownsPrivacyIdentity
            ? (verified
                ? .ok("disclaimed-child -- confirmed with the kernel, not inferred")
                : .warn("disclaimed-child, but UNVERIFIED (responsibility API unavailable)"))
            : .warn("""
                \(Runtime.disclaimMode) -- running under the LAUNCHING app's identity. Any Calendar \
                access shown below is inherited and will disappear under a different host.
                """)))

        // 3. Ownership of the grant.
        //
        // A disclaimed process is its own responsible process, so the status it sees is its
        // OWN grant and nothing else -- measured in Phase 1, where the disclaimed child read
        // notDetermined while the inherited path read fullAccess from the host terminal.
        // That pairing is the actual proof of ownership, and it needs no special privilege.
        //
        // Reading TCC.db would be more direct but requires Full Disk Access, which this tool
        // does not have and should not ask for. It is attempted only as corroboration and
        // its absence is not a problem.
        let state = AuthorizationState.current
        let owned = (Runtime.ownsPrivacyIdentity) && state.canReadEvents

        if owned {
            checks.append(("grant ownership", .ok("this binary's own grant (disclaimed identity + full access)")))
        } else if Runtime.ownsPrivacyIdentity {
            checks.append(("grant ownership", .fail("""
                no usable grant of our own (status: \(state.rawValue)). Run --setup from \
                this exact path: \(path)
                """)))
        } else {
            checks.append(("grant ownership", .fail("""
                cannot own a grant while running under the launching app's identity. Any \
                access reported below is inherited and will vanish under a different host.
                """)))
        }

        switch TCCInspector.calendarGrant(forPath: path) {
        case .found(let grant) where grant.isAllowed:
            checks.append(("TCC row (extra)", .ok("row present for this path")))
        case .found(let grant):
            checks.append(("TCC row (extra)", .warn("row present but auth_value=\(grant.authValue)")))
        case .noRowForUs:
            checks.append(("TCC row (extra)", owned
                ? .warn("no row found, though ownership is otherwise confirmed")
                : .warn("no row for this path")))
        case .unreadable:
            // Expected: reading TCC.db needs Full Disk Access. Not a finding.
            checks.append(("TCC row (extra)", .ok("skipped -- needs Full Disk Access, which this tool does not request")))
        }

        checks.append(("tool surface", Runtime.isReadOnly
            ? .ok("read-only -- no mutating tool is exposed on this connection")
            : .ok("read and write")))

        // 4. Raw status, listed last: on its own it cannot distinguish an owned grant from
        //    an inherited one, which is why ownership above is the check that matters.
        checks.append(("authorization status", state.canReadEvents
            ? .ok(state.rawValue)
            : .fail("\(state.rawValue) -- \(state.guidance)")))

        // Report
        log("apple-calendar-mcp \(Meta.version) -- diagnostics")
        log("path: \(path)")
        log("")
        for (name, verdict) in checks {
            log("  [\(verdict.marker)] \(name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(verdict.text)")
        }
        log("")

        let failures = checks.filter { $0.1.isFailure }
        if failures.isEmpty {
            log("No blocking problems found.")
        } else {
            log("\(failures.count) blocking problem(s). Calendar access will not work reliably.")
        }

        // The grant is path-keyed, which is the single most common way this breaks after it
        // once worked, so say it every time rather than only on failure.
        log("")
        log("Reminder: the grant belongs to this binary at this PATH. Moving or reinstalling")
        log("it requires running --setup again at the new location.")

        return failures.isEmpty ? 0 : 1
    }
}
