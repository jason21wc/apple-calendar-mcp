// Bridges scripts/test-shell.sh into `swift test`.
//
// The shell checks live in shell because that is where the bug class lives: the pipefail /
// SIGPIPE inversion of gotcha 34 is a property of bash and of process scheduling, and
// reimplementing the check in Swift would test a model of bash rather than bash. The script
// runs standalone too (./scripts/test-shell.sh) so it can be used from a git hook or CI
// without a Swift toolchain.
//
// Full output is attached to the failure, because "the shell suite failed" on its own tells
// a reader nothing.

import Testing
import Foundation

@Suite("scripts/*.sh")
struct ShellScriptTests {

    @Test("the shell suite passes, and its own SIGPIPE characterisation still reproduces")
    func shellSuitePasses() throws {
        let script = Repo.scriptsDirectory.appendingPathComponent("test-shell.sh")
        try #require(FileManager.default.isExecutableFile(atPath: script.path),
                     "scripts/test-shell.sh is missing or not executable")

        let result = try Runner.bash(script, workingDirectory: Repo.root)

        #expect(result.exitCode == 0, """
            scripts/test-shell.sh exited \(result.exitCode). These are defects in scripts/, \
            not in the tests.

            \(result.combined)
            """)

        // Guard against the suite passing because it silently checked nothing -- an empty
        // scripts directory, a failed glob, or an early exit would otherwise read as success.
        #expect(result.combined.contains("bash -n make-signing-cert.sh"))
        #expect(result.combined.contains("bash -n sign.sh"))
        #expect(result.combined.contains("bash -n trust-signing-cert.sh"))
        #expect(result.combined.contains("pipefail + early-exiting downstream"),
                "the platform characterisation probe did not run; every lint below it is unverified")
    }

    @Test("the shell suite reports a failure rather than swallowing it")
    func shellSuiteFailsLoudly() throws {
        // A test suite that cannot fail is decoration. This plants a script that violates a
        // rule and checks the suite notices, so a future refactor cannot quietly turn every
        // check into a no-op.
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apple-calendar-mcp-shelltest-\(UUID().uuidString)", isDirectory: true)
        let scripts = sandbox.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try FileManager.default.copyItem(
            at: Repo.scriptsDirectory.appendingPathComponent("test-shell.sh"),
            to: scripts.appendingPathComponent("test-shell.sh"))

        let offender = scripts.appendingPathComponent("offender.sh")
        try """
            #!/bin/bash
            set -euo pipefail
            if security find-identity -v -p codesigning | grep -q "something"; then
                echo found
            fi
            """.write(to: offender, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: offender.path)

        let result = try Runner.bash(scripts.appendingPathComponent("test-shell.sh"),
                                     workingDirectory: sandbox)

        #expect(result.exitCode != 0, "a script with an unguarded `| grep -q` was accepted:\n\(result.combined)")
        #expect(result.combined.contains("offender.sh"),
                "the failure did not name the offending script:\n\(result.combined)")
        #expect(result.combined.contains("gotcha 34"),
                "the failure did not explain the bug class:\n\(result.combined)")
    }
}
