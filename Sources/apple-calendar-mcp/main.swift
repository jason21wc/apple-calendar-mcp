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

// Claim our own privacy identity BEFORE touching EventKit. Once EventKit is used under
// inherited responsibility the grant is already attributed to the host. Does not return if
// the respawn succeeds -- the supervisor waits for the child and exits with its status.
Runtime.establishPrivacyIdentity()

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

/// Labels become filenames, so anything outside a safe set is replaced.
///
/// Two things this deliberately does NOT promise:
///   - `.` survives, so `sanitize("..") == ".."`. That is contained only because the caller
///     wraps the result as `probe-<label>.json`; a future caller that drops the prefix
///     reintroduces a parent reference.
///   - the cap is on BYTES, not characters. `prefix(64)` counts grapheme clusters, and a
///     single Character can carry hundreds of combining marks -- measured at ~1 kB from one
///     visible character, which exceeds the filesystem's name limit and makes the write
///     fail. Since the probe JSON is this tool's entire deliverable, that matters.
func sanitize(_ label: String) -> String {
    var out = ""
    var bytes = 0
    for c in label {
        let replacement: Character =
            (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-") ? c : "-"
        let width = String(replacement).utf8.count
        if bytes + width > 64 { break }
        out.append(replacement)
        bytes += width
    }
    // An empty result is left empty rather than substituted with a placeholder. A single
    // grapheme CAN exhaust the whole budget on its own (one letter carrying hundreds of
    // combining marks is ~1 kB), yielding "probe-.json". A default would not restore the
    // distinguishability that was lost -- every stripped label would collapse to the same
    // placeholder -- so it would add a magic value and buy nothing.
    return out
}

func writeProbe(label rawLabel: String, status: EKAuthorizationStatus, note: String) {
    let label = sanitize(rawLabel)
    Runtime.ensureStateDirectory()

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
        "disclaim_mode": Runtime.disclaimMode,
        "disclaim_symbol_available": Reexec.disclaimAvailable,
    ]

    let file = Runtime.stateDirectory.appendingPathComponent("probe-\(label).json")
    do {
        let data = try JSONSerialization.data(withJSONObject: record,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: file.path)
        log("probe written -> \(file.path)")
    } catch {
        // The JSON file IS this tool's deliverable. Claiming one that does not exist would
        // invert its purpose.
        log("probe write FAILED (\(file.path)): \(error.localizedDescription)")
    }
    log("status=\(describe(status)) parent=\(processPath(ppid)) mode=\(Runtime.disclaimMode)")
}

// MARK: - Dispatch

let store = EKEventStore()

switch Command.parse(Array(CommandLine.arguments.dropFirst())) {

case .setup:
    exit(await SetupFlow.run(store: store))

case .doctor:
    exit(Doctor.run())

case .probe(let label):
    writeProbe(label: label,
               status: EKEventStore.authorizationStatus(for: .event),
               note: "explicit probe; no permission request made")

case .version:
    printVersion()

case .help:
    printHelp()

case .unknown(let flag):
    log("unknown option: \(flag)")
    printHelp()
    exit(64)   // EX_USAGE

case .serve:
    // Phase 4 replaces this with the MCP server loop. When it does, that loop MUST treat
    // stdin EOF as unconditional shutdown -- it is the only defence against the supervisor
    // being SIGKILLed, which no signal handler can cover (BACKLOG #12).
    writeProbe(label: "spawned",
               status: EKEventStore.authorizationStatus(for: .event),
               note: "launched with no arguments, as an MCP client would; server not yet implemented")
    log("no MCP server yet -- this is Phase 2 of 7. Run --help for available commands.")
    exit(69)   // EX_UNAVAILABLE: honest failure, rather than a silent exit a client reads as a crash
}
