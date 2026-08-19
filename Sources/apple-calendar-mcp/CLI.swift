// Command-line surface.
//
// Permission setup is a COMMAND, not an MCP tool, and that is a design constraint rather
// than a convenience: a TCC prompt requires a foreground process, and a server launched
// over stdio by an MCP client cannot reliably present one. `--doctor` is its companion --
// when Calendar access misbehaves, the failure is usually silent, so there has to be
// something that says why.

import Foundation

enum Command {
    case serve                    // default; how an MCP client launches us
    case grant                    // interactive permission request (Phase 3: --setup)
    case probe(label: String)     // diagnostic record, used to answer Phase 1
    case version
    case help
    case unknown(String)

    static func parse(_ args: [String]) -> Command {
        guard let first = args.first else { return .serve }
        switch first {
        case "--grant":            return .grant
        case "--probe":            return .probe(label: args.count > 1 ? args[1] : "manual")
        case "--version", "-v":    return .version
        case "--help", "-h":       return .help
        default:                   return .unknown(first)
        }
    }
}

enum Meta {
    /// Read from the embedded Info.plist rather than hardcoded, so a fork that changes the
    /// identifier gets correct output -- including in the tccutil instructions, where a
    /// wrong identifier would tell the user to reset someone else's grant.
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "<no embedded Info.plist>"
    }

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "unknown"
    }

    static var executablePath: String { processPath(getpid()) }
}

func printHelp() {
    // stderr, not stdout: stdout belongs to the MCP protocol and nothing else may touch it.
    log("""
        apple-calendar-mcp \(Meta.version)

        A local MCP server for the macOS Calendar. Run with no arguments to serve over
        stdio -- that is how Claude Code and Codex launch it.

          (no arguments)     serve over stdio
          --grant            request Calendar access (run this in a terminal)
          --probe <label>    write a diagnostic record to ~/.local/state/apple-calendar-mcp
          --version          print version and identity
          --help             this text

        Calendar access is granted to this binary at its ABSOLUTE PATH. Install it where it
        will live permanently, then run --grant there; moving it afterwards loses access.
        """)
}

func printVersion() {
    log("""
        apple-calendar-mcp \(Meta.version)
          identifier: \(Meta.bundleIdentifier)
          path:       \(Meta.executablePath)
          mode:       \(disclaimMode)
        """)
}
