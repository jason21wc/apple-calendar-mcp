// What these tests protect
//
// The disclaim mechanism is this project's whole permission model. If the process wrongly
// believes it is its own responsible process, it grants Calendar access under the LAUNCHING
// app's identity while telling the user it did not -- which defeats the user's revocation
// switch, because turning off Calendar access for this binary then stops nothing.
//
// Gotcha 30 records that this already happened once. The first implementation bound an
// environment marker to the supervisor's pid and called it unforgeable; every parent knows
// its own pid, so `APPLE_CALENDAR_MCP_DISCLAIMED=$$` defeated it in one line -- and the
// delivery path is the actor the threat model names, since both Claude Code and Codex
// accept an `env` block in same-uid-writable MCP config. Gotcha 35 records the second half:
// the fix left a fallback to the forgeable check on a path no test on a working machine can
// reach.
//
// WHAT IS DELIBERATELY NOT TESTED HERE, AND WHY
//
//   * `respawnDisclaimed()` is not called in this process. On the success path it never
//     returns -- it posix_spawns and exits with the child's status -- so an in-process call
//     that got past the depth guard would spawn a copy of the TEST HOST, with the test
//     host's argv. Using the guard as the safety net for the test of the guard is not a
//     test. The guard is exercised against the real binary in ReexecProcessTests instead.
//
//   * The unavailable-symbol branch of `isDisclaimedChild` cannot be exercised at runtime:
//     `responsibility_get_pid_responsible_for_pid` is present on this OS, and there is no
//     supported way to make dlsym fail for it. That is precisely the branch that carried the
//     reintroduced forgery, so it is guarded by reading the source instead. A source
//     assertion is a weak instrument and is used only because the alternative is nothing.
//
//   * Signal forwarding to the supervised child (SIGTERM/SIGINT/SIGHUP), the CLOEXEC_DEFAULT
//     stdio exemption, the environment allowlist, and the waitpid/exit-status translation
//     all require a real spawn plus signal delivery and process inspection. None of them are
//     covered by this file. They are the largest untested surface in Reexec.swift.

import Testing
import Foundation
import Darwin
@testable import apple_calendar_mcp

/// Serialised because the tests mutate the process environment, which every test in the run
/// shares. `setenv` is visible to `ProcessInfo.processInfo.environment` on Darwin (measured),
/// so this is not theoretical.
@Suite("Reexec: in-process invariants", .serialized)
struct ReexecInProcessTests {

    @Test("the disclaim marker cannot change what isDisclaimedChild reports")
    func markerCannotForgeDisclaimedIdentity() {
        let kernelAnswer = Reexec.responsibleProcess(of: getpid()) == getpid()
        let before = Reexec.isDisclaimedChild
        #expect(before == kernelAnswer, "isDisclaimedChild disagreed with the kernel before any tampering")

        // The exact one-line forgery from gotcha 30, performed in-process.
        setenv(Reexec.marker, String(getpid()), 1)
        defer { unsetenv(Reexec.marker) }
        #expect(ProcessInfo.processInfo.environment[Reexec.marker] == String(getpid()),
                "the forgery was not actually planted, so the assertion below would prove nothing")

        #expect(Reexec.isDisclaimedChild == before,
                "the environment marker changed the verdict; this is the gotcha 30 forgery")
        #expect(Reexec.isDisclaimedChild == kernelAnswer,
                "isDisclaimedChild must equal the kernel's answer and nothing else")
    }

    @Test("no plausible marker value moves the verdict")
    func noMarkerValueMovesTheVerdict() {
        let truth = Reexec.responsibleProcess(of: getpid()) == getpid()
        defer { unsetenv(Reexec.marker) }
        for value in [String(getpid()), String(getppid()), "1", "0", "-1", "true", "yes", ""] {
            setenv(Reexec.marker, value, 1)
            #expect(Reexec.isDisclaimedChild == truth,
                    "marker=\(String(reflecting: value)) changed the verdict")
        }
    }

    @Test("the depth variable is not mistaken for evidence of disclaim state")
    func depthVariableIsNotEvidence() {
        let truth = Reexec.responsibleProcess(of: getpid()) == getpid()
        defer { unsetenv(Reexec.depthKey) }
        for value in ["0", "1", "2", "99", "not-a-number"] {
            setenv(Reexec.depthKey, value, 1)
            #expect(Reexec.isDisclaimedChild == truth,
                    "depth=\(value) changed the verdict; depth is a fork-bomb backstop, not proof")
        }
    }

    @Test("the marker and depth keys keep the names the shipped scripts and docs use")
    func environmentKeyNamesAreStable() {
        // Renaming either silently disables the fork-bomb backstop for anything that sets
        // the old name, and invalidates the subprocess tests below.
        #expect(Reexec.marker == "APPLE_CALENDAR_MCP_DISCLAIMED")
        #expect(Reexec.depthKey == "APPLE_CALENDAR_MCP_REEXEC_DEPTH")
        #expect(Reexec.marker != Reexec.depthKey)
    }

    @Test("an unanswerable responsibility query reads as not-disclaimed rather than as disclaimed")
    func unverifiedStateIsNotTreatedAsDisclaimed() {
        // disclaimStateIsVerified is the honest report of "can we answer at all". Whenever
        // it is false, isDisclaimedChild must be false -- failing closed. On a machine where
        // the symbol resolves this only pins the implication; the source assertion in
        // ReexecSourceTests is what covers the branch itself.
        if !Reexec.disclaimStateIsVerified {
            #expect(!Reexec.isDisclaimedChild)
        }
        #expect(Reexec.disclaimStateIsVerified == (Reexec.responsibleProcess(of: getpid()) != nil))
    }

    @Test("the responsibility lookup returns a real pid or nothing, never a junk value")
    func responsibleProcessReturnsAPlausiblePid() {
        guard let responsible = Reexec.responsibleProcess(of: getpid()) else { return }
        #expect(responsible > 0)
        // kill(pid, 0) succeeds for a live process we may signal, and fails with EPERM for a
        // live process we may not. ESRCH would mean the API handed back a dead pid.
        let probe = kill(responsible, 0)
        #expect(probe == 0 || errno == EPERM,
                "responsible pid \(responsible) does not refer to a live process (errno \(errno))")
    }
}

@Suite("Reexec: source-level guards for branches no runtime test can reach")
struct ReexecSourceTests {

    /// Extract a brace-balanced declaration body by header text. Crude on purpose -- it is a
    /// backstop for an unreachable code path, not a parser.
    private func body(of header: String, in source: String) throws -> String {
        guard let start = source.range(of: header) else {
            throw SourceGuardError.declarationNotFound(header)
        }
        var depth = 0
        var body = ""
        for character in source[start.lowerBound...] {
            if character == "{" { depth += 1 }
            if depth > 0 { body.append(character) }
            if character == "}" {
                depth -= 1
                if depth == 0 { return body }
            }
        }
        throw SourceGuardError.unbalancedBraces(header)
    }

    @Test("isDisclaimedChild has no fallback to the forgeable environment marker")
    func isDisclaimedChildDoesNotConsultTheEnvironment() throws {
        // Gotcha 35: "a security fallback on an unreachable path cannot be tested and must
        // not be trusted." The dlsym-failure branch is dead code on any working machine, and
        // that is exactly where the forgery was reintroduced last time. Reading the source is
        // the only instrument available, so it is used explicitly rather than pretended
        // otherwise.
        let source = try Repo.source("Sources/apple-calendar-mcp/Reexec.swift")
        let implementation = try body(of: "static var isDisclaimedChild: Bool", in: source)

        // Strip comments first: the doc comment on this property talks about the marker at
        // length, and it should keep doing so.
        let code = implementation
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return line }
                return String(line[..<comment.lowerBound])
            }
            .joined(separator: "\n")

        for forbidden in ["marker", "depthKey", "ProcessInfo", "environment", "getenv", "APPLE_CALENDAR_MCP"] {
            #expect(!code.contains(forbidden), """
                isDisclaimedChild references \(forbidden). Its verdict must come from \
                responsibleProcess(of:) alone -- any environment input reinstates the \
                one-line forgery of gotcha 30 on the branch no test can reach.
                Body was:\n\(code)
                """)
        }
        #expect(code.contains("responsibleProcess"), "the kernel check itself has gone missing")
        #expect(code.contains("return false"), "the unanswerable case must still fail closed")
    }

    @Test("the depth guard runs before anything is spawned")
    func depthGuardPrecedesTheSpawn() throws {
        let source = try Repo.source("Sources/apple-calendar-mcp/Reexec.swift")
        let implementation = try body(of: "static func respawnDisclaimed() -> Bool", in: source)

        guard let guardIndex = implementation.range(of: "reexecDepth == 0")?.lowerBound,
              let spawnIndex = implementation.range(of: "posix_spawn(")?.lowerBound else {
            Issue.record("could not locate the depth guard or the spawn in respawnDisclaimed()")
            return
        }
        #expect(guardIndex < spawnIndex,
                "the depth guard must short-circuit before posix_spawn, or each level leaves a live process in waitpid")
    }
}

enum SourceGuardError: Error, CustomStringConvertible {
    case declarationNotFound(String)
    case unbalancedBraces(String)
    var description: String {
        switch self {
        case .declarationNotFound(let h): return "declaration not found: \(h) (was it renamed?)"
        case .unbalancedBraces(let h): return "could not find a balanced body for: \(h)"
        }
    }
}
