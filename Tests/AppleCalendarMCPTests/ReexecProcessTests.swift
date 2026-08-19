// Subprocess tests against the real binary.
//
// These exist because the interesting parts of Reexec and of main.swift's dispatch cannot be
// reached in a test host: main.swift is top-level code, so `disclaimMode` and `stateDir` are
// initialised by `main` and reading them from a linked test bundle segfaults the run
// (measured). A real spawn is the only way to observe the mode the process actually chose.
//
// SAFETY RULES OBSERVED HERE, deliberately and without exception:
//   * only --version, --help and an unknown flag are ever invoked. --setup and --grant would
//     raise a real TCC prompt; --probe and the bare serve path both write into the user's
//     real ~/.local/state, and gotcha 37 means HOME cannot be redirected to stop them
//     (homeDirectoryForCurrentUser reads the passwd database, not $HOME).
//   * the child environment is set explicitly, never inherited, so a developer shell that
//     already exports APPLE_CALENDAR_MCP_DISCLAIMED cannot decide the result.
//   * nothing here reads or writes a calendar, and no test requires Calendar permission --
//     --version never calls requestFullAccessToEvents.

import Testing
import Foundation
@testable import apple_calendar_mcp

@Suite("Reexec: behaviour of the real process")
struct ReexecProcessTests {

    private func mode(of result: ProcessResult) -> String? {
        for line in result.combined.components(separatedBy: "\n") {
            guard let range = line.range(of: "mode:") else { continue }
            return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // The LITERAL variable names, not Reexec.marker / Reexec.depthKey.
    //
    // Found by mutation testing: with the constants, renaming depthKey in the source renamed
    // it in the test too, and every depth-guard test kept passing against a binary whose
    // guard no longer honoured the documented variable. A subprocess test must speak the
    // process's published interface, which is the literal string. ReexecInProcessTests
    // asserts that the constants still equal these literals, so the two stay tied together.
    private static let markerVariable = "APPLE_CALENDAR_MCP_DISCLAIMED"
    private static let depthVariable = "APPLE_CALENDAR_MCP_REEXEC_DEPTH"

    private func version(environment: [String: String]) throws -> (ProcessResult, String?) {
        let binary = try Repo.builtExecutable()
        let result = try Runner.run(binary, arguments: ["--version"], environment: environment)
        return (result, mode(of: result))
    }

    // MARK: - Positive control

    @Test("the disclaim mechanism actually works, so the refusal tests below mean something")
    func disclaimSucceedsWhenNothingBlocksIt() throws {
        // Without this, every assertion in this file could be satisfied by a build in which
        // disclaiming never works at all -- the tests would pass and the permission model
        // would be broken.
        try #require(Reexec.disclaimAvailable,
                     "responsibility_spawnattrs_setdisclaim is missing on this OS; the rest of this suite cannot distinguish a working guard from a dead mechanism")

        let (result, mode) = try version(environment: [:])
        #expect(result.exitCode == 0, "--version exited \(result.exitCode): \(result.combined)")
        #expect(mode == "disclaimed-child", """
            an unhindered launch reported mode=\(mode ?? "<none>"). If this says \
            inherited-*, the process is running under the launching app's Calendar identity \
            and the whole permission model is off.
            """)
    }

    // MARK: - The depth guard

    @Test("the depth guard refuses to respawn once depth is above zero")
    func depthGuardRefusesAboveZero() throws {
        for depth in ["1", "2", "17"] {
            let (result, mode) = try version(environment: [Self.depthVariable: depth])
            #expect(result.exitCode == 0)
            #expect(mode == "inherited-respawn-failed", """
                depth=\(depth) produced mode=\(mode ?? "<none>"). The guard is the only thing \
                stopping unbounded recursion, and every level holds a live process blocked in \
                waitpid.
                """)
            #expect(mode != "disclaimed-child",
                    "depth=\(depth) still claimed a disclaimed identity")
        }
    }

    @Test("a refused respawn is reported honestly rather than downgraded silently")
    func refusedRespawnIsReported() throws {
        let (result, mode) = try version(environment: [Self.depthVariable: "1"])
        #expect(mode == "inherited-respawn-failed")
        #expect(mode != "inherited-symbol-missing",
                "the symbol IS available here; reporting it as missing would misdirect --doctor")
        #expect(result.combined.contains("inherited"),
                "the printed identity must say inherited so a human reading --version is not misled")
    }

    // MARK: - Gotcha 30: the forgery

    @Test("a forged disclaim marker cannot make the process claim a disclaimed identity")
    func forgedMarkerCannotClaimDisclaimedIdentity() throws {
        // The attack, exactly as recorded: an MCP client config that sets
        // APPLE_CALENDAR_MCP_DISCLAIMED=$$ in the server's env block. Both Claude Code and
        // Codex accept one, and those files are same-uid writable by the coding agent this
        // server talks to.
        //
        // The depth key is set alongside it on purpose. Without it the process performs a
        // GENUINE disclaimed respawn and legitimately reports disclaimed-child, which would
        // make this test pass for a reason that has nothing to do with the marker. Blocking
        // the respawn is what isolates the marker as the only variable.
        let forgedPid = String(ProcessInfo.processInfo.processIdentifier)
        for forged in [forgedPid, "1", "99999", "0", "true"] {
            let (result, mode) = try version(environment: [
                Self.markerVariable: forged,
                Self.depthVariable: "1",
            ])
            #expect(result.exitCode == 0)
            #expect(mode != "disclaimed-child", """
                APPLE_CALENDAR_MCP_DISCLAIMED=\(forged) produced mode=\(mode ?? "<none>"). \
                An environment variable has been accepted as proof of privacy identity. \
                Any grant taken in this state belongs to the launching app, and the user's \
                revocation switch for this binary would no longer stop it. Gotcha 30.
                """)
            #expect(mode == "inherited-respawn-failed",
                    "expected an honest inherited report, got \(mode ?? "<none>")")
        }
    }

    @Test("the forged marker does not defeat the depth guard either")
    func forgedMarkerDoesNotUnblockTheSpawn() throws {
        // A marker that made the process think it was already the child would also make it
        // skip the respawn. Both effects are checked, because either one alone is a bypass.
        let (_, mode) = try version(environment: [
            Self.markerVariable: String(ProcessInfo.processInfo.processIdentifier),
            Self.depthVariable: "3",
        ])
        #expect(mode == "inherited-respawn-failed")
    }

    // MARK: - CLI dispatch, observed from outside

    @Test("an unknown flag exits EX_USAGE instead of entering the server loop")
    func unknownFlagExits64() throws {
        let binary = try Repo.builtExecutable()
        for flag in ["--nope", "--doctr", "--SETUP", "-x"] {
            let result = try Runner.run(binary, arguments: [flag],
                                        environment: [Self.depthVariable: "1"])
            #expect(result.exitCode == 64, """
                \(flag) exited \(result.exitCode), expected 64 (EX_USAGE). Exit 69 would mean \
                it fell through to the serve path, which is the defect this guards.
                """)
            #expect(result.combined.contains("unknown option: \(flag)"),
                    "the error message must name the flag that was typed")
        }
    }

    @Test("diagnostics never reach stdout, because stdout belongs to the MCP protocol")
    func nothingIsPrintedToStdout() throws {
        let binary = try Repo.builtExecutable()
        for arguments in [["--version"], ["--help"], ["--nope"]] {
            let result = try Runner.run(binary, arguments: arguments,
                                        environment: [Self.depthVariable: "1"])
            #expect(result.stdout.isEmpty, """
                \(arguments) wrote \(result.stdout.utf8.count) bytes to stdout: \
                \(String(reflecting: result.stdout)). A single stray byte corrupts the \
                JSON-RPC stream for every MCP client.
                """)
            #expect(!result.stderr.isEmpty, "\(arguments) produced no diagnostics at all")
        }
    }

    @Test("--version and --help succeed and --help documents the legacy --grant alias")
    func helpAndVersionSucceed() throws {
        let binary = try Repo.builtExecutable()
        let help = try Runner.run(binary, arguments: ["--help"], environment: [Self.depthVariable: "1"])
        #expect(help.exitCode == 0)
        for flag in ["--setup", "--doctor", "--probe", "--version", "--help"] {
            #expect(help.combined.contains(flag), "--help does not mention \(flag)")
        }
        // CommandParsingTests proves --grant still works; this proves the help text still
        // says so. If the alias is ever dropped, both must change together.
        #expect(help.combined.contains("--grant"),
                "--help references --grant; if the alias is removed this text must go too")

        let version = try Runner.run(binary, arguments: ["-v"], environment: [Self.depthVariable: "1"])
        #expect(version.exitCode == 0)
        #expect(version.combined.contains("identifier:"))
        #expect(version.combined.contains("path:"))
        #expect(version.combined.contains("mode:"))
    }

    @Test("the embedded Info.plist survives the build, so TCC can read the usage string")
    func infoPlistIsEmbedded() throws {
        // The -sectcreate linker flag resolves its path against the LINKER's working
        // directory, so building with --package-path silently produces a binary with no
        // __TEXT,__info_plist section. Without it there is no bundle identifier, no usage
        // description, and macOS may refuse to prompt at all.
        let binary = try Repo.builtExecutable()
        let result = try Runner.run(binary, arguments: ["--version"],
                                    environment: [Self.depthVariable: "1"])
        #expect(!result.combined.contains("<no embedded Info.plist>"), """
            the binary has no __TEXT,__info_plist section. Rebuild from the package root: \
            `swift build` with --package-path links without it.
            """)
        #expect(result.combined.contains("com.collierhmg.apple-calendar-mcp"),
                "bundle identifier missing or changed: \(result.combined)")
    }
}
