// Phase 1 probe. This is NOT the MCP server -- it exists to answer one question before any
// of the server gets built:
//
//   When Claude Code or Codex spawns this binary, does macOS attribute the Calendar grant
//   to THIS binary, or to the app that launched it?
//
// macOS commonly credits a TCC grant to the "responsible process", which for a bare
// executable spawned from a shell is often the launching app rather than the executable.
// If the grant lands on Terminal, everything works during setup and every client-spawned
// call fails -- silently, per the entitlement note. That would kill the bare-executable
// design and force an .app wrapper, so nothing else is built until this is settled.
//
// Because MCP clients speak JSON-RPC over stdout, the probe must never print to stdout.
// It writes a JSON record to disk and logs to stderr, so the answer survives regardless of
// who spawned it or whether the MCP handshake failed.

import Foundation
import EventKit
import Darwin

// MARK: - Earn our own TCC identity BEFORE touching EventKit
//
// Must run first. Once EventKit is used under inherited responsibility, the grant is
// already attributed to the host. See Reexec.swift for the full reasoning.

// A closed stderr pipe would otherwise kill us on the first diagnostic write.
signal(SIGPIPE, SIG_IGN)

let disclaimMode: String
if Reexec.isDisclaimedChild {
    disclaimMode = "disclaimed-child"          // we are the re-spawned, self-responsible process
} else if Reexec.respawnDisclaimed() {
    disclaimMode = "unreachable"               // respawnDisclaimed() exits on success
} else {
    disclaimMode = Reexec.disclaimAvailable
        ? "inherited-respawn-failed"
        : "inherited-symbol-missing"           // private API gone; degrade, do not crash
}

// MARK: - Authorization states
//
// EKAuthorizationStatus has FIVE distinct values, not six. `Authorized` is a deprecated
// alias equal to `FullAccess` -- same raw value, runtime-indistinguishable. Any code or
// test expecting six states can never pass. (EKTypes.h:27-35)

func describe(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted:    return "restricted"
    case .denied:        return "denied"
    case .fullAccess:    return "fullAccess"
    case .writeOnly:     return "writeOnly"
    @unknown default:    return "unknown(\(status.rawValue))"
    }
}

func processPath(_ pid: pid_t) -> String {
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return "unknown" }
    return String(decoding: buf[..<Int(n)], as: UTF8.self)
}

func log(_ message: String) {
    // fputs, not FileHandle.write: the latter raises an uncatchable Objective-C exception
    // on I/O failure. Paired with the SIGPIPE ignore below, a client that closes or
    // discards stderr can no longer turn a diagnostic line into a fatal.
    fputs("[apple-calendar-mcp] " + message + "\n", stderr)
}

// MARK: - Probe record

let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/apple-calendar-mcp", isDirectory: true)

/// Labels become filenames, so anything outside a safe set is replaced rather than trusted.
func sanitize(_ label: String) -> String {
    let safe = label.map { c -> Character in
        c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" ? c : "-"
    }
    return String(safe.prefix(64))
}

func writeProbe(label rawLabel: String, status: EKAuthorizationStatus, note: String) {
    let label = sanitize(rawLabel)
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

    let ppid = getppid()
    let record: [String: Any] = [
        "label": label,
        "recorded_at": ISO8601DateFormatter().string(from: Date()),
        "authorization_status": describe(status),
        "self_path": processPath(getpid()),
        "parent_pid": Int(ppid),
        "parent_path": processPath(ppid),          // who spawned us -- the whole point
        "bundle_identifier": Bundle.main.bundleIdentifier ?? "<none: Info.plist not embedded>",
        "usage_description_present":
            Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil,
        "note": note,
        "disclaim_mode": disclaimMode,
        "disclaim_symbol_available": Reexec.disclaimAvailable,
    ]

    let file = stateDir.appendingPathComponent("probe-\(label).json")
    do {
        let data = try JSONSerialization.data(withJSONObject: record,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file)
        log("probe written -> \(file.path)")
    } catch {
        // The JSON file IS this tool's deliverable. Claiming one that does not exist would
        // invert its purpose.
        log("probe write FAILED (\(file.path)): \(error.localizedDescription)")
    }
    log("status=\(describe(status)) parent=\(processPath(ppid)) mode=\(disclaimMode)")
}

// MARK: - Modes

let args = Array(CommandLine.arguments.dropFirst())
let store = EKEventStore()

switch args.first {

case "--grant":
    // Run this from Terminal, in the foreground. A TCC prompt needs a foreground process;
    // a stdio-spawned server cannot reliably present one, which is why permission setup is
    // a CLI command and never an MCP tool.
    let before = EKEventStore.authorizationStatus(for: .event)
    log("status before request: \(describe(before))")

    if before == .notDetermined {
        do {
            let granted = try await store.requestFullAccessToEvents()
            log("requestFullAccessToEvents returned granted=\(granted)")
        } catch {
            log("requestFullAccessToEvents threw: \(error.localizedDescription)")
        }
    } else {
        log("not requesting -- status is already decided. Reset with:")
        let bundleID = Bundle.main.bundleIdentifier ?? "<unknown>"
        log("  tccutil reset Calendar \(bundleID)")
    }

    let after = EKEventStore.authorizationStatus(for: .event)
    writeProbe(label: "grant", status: after, note: "interactive grant attempt from a terminal")
    log("status after request: \(describe(after))")

case "--probe":
    let label = args.count > 1 ? args[1] : "manual"
    writeProbe(label: label,
               status: EKEventStore.authorizationStatus(for: .event),
               note: "explicit probe; no permission request made")

case .some(let unknown) where unknown.hasPrefix("-"):
    log("unknown option: \(unknown)")
    log("usage: apple-calendar-mcp [--grant | --probe <label>]")
    log("note: --setup and --doctor are Phase 3; they do not exist yet")
    exit(64)   // EX_USAGE

default:
    // No arguments is how an MCP client launches us. The real server will speak JSON-RPC
    // here. For now: record who spawned us and exit. The client will report a failed
    // connection -- expected, and not what we are measuring.
    writeProbe(label: "spawned",
               status: EKEventStore.authorizationStatus(for: .event),
               note: "launched with no arguments, as an MCP client would; not yet a server")
    log("Phase 1 probe only -- no MCP server yet. Exiting.")
}
