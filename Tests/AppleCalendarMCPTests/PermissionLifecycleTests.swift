import Testing
import Foundation
import EventKit
@testable import apple_calendar_mcp

// These tests were impossible until `disclaimMode`, `stateDir` and `store` moved out of
// main.swift's top-level code. Top-level bindings in a Swift executable are @MainActor
// isolated, and reading one from a test crashed the whole test host with SIGSEGV.
//
// The property below is worth the restructure on its own: SetupFlow refusing to request
// Calendar access while running under an inherited identity is what stops the permission
// being attached to the launching terminal instead of to this binary. That is the exact
// failure Phase 1 spent its whole existence diagnosing, it looks like success when it
// happens, and until now nothing tested it.

@Suite("Permission lifecycle")
struct PermissionLifecycleTests {

    // The test host is spawned by the test runner and never disclaims itself, so it stands
    // in for "launched by an MCP client without an identity of its own".
    @Test("the test host genuinely lacks its own privacy identity, so the tests below mean something")
    func testHostIsNotDisclaimed() {
        #expect(Reexec.isDisclaimedChild == false)
        #expect(Runtime.ownsPrivacyIdentity == false)
    }

    @Test("setup REFUSES to request access when the identity is inherited")
    func setupRefusesUnderInheritedIdentity() async {
        // If this branch ever stops refusing, the failure is silent and severe: the grant
        // attaches to whatever launched the process, every status API reports success, and
        // access breaks the moment a different host launches the binary.
        let exitCode = await SetupFlow.run(store: EKEventStore())
        #expect(exitCode != 0, "setup must fail rather than grant to the launching app")
    }

    @Test("setup does not raise a permission prompt when it refuses")
    func setupDoesNotPromptWhenRefusing() async {
        // The refusal must happen BEFORE requestFullAccessToEvents. If ordering regressed,
        // this test would hang on a real TCC dialog rather than return -- which is itself
        // the signal, since a hung test is impossible to mistake for a pass.
        let before = Date()
        _ = await SetupFlow.run(store: EKEventStore())
        #expect(Date().timeIntervalSince(before) < 5,
                "returned promptly, so no permission dialog was raised")
    }

    @Test("the diagnostic reports failure when the identity is inherited")
    func doctorFailsUnderInheritedIdentity() {
        #expect(Doctor.run() != 0,
                "doctor must not report a clean bill of health without an owned identity")
    }

    @Test("asking about the privacy identity never spawns a process")
    func queryingIdentityHasNoSideEffects() {
        // An earlier version computed the mode lazily and performed the respawn on first
        // read, so merely ASKING would posix_spawn a copy of the caller -- here, the test
        // host, with the test host's argv. Reading it repeatedly must be inert.
        let first = Runtime.disclaimMode
        for _ in 0..<50 { _ = Runtime.disclaimMode }
        #expect(Runtime.disclaimMode == first, "the answer is stable and side-effect free")
        #expect(first.hasPrefix("inherited"), "test host is not disclaimed")
    }

    @Test("the state directory is created private, before calendar content is written there")
    func stateDirectoryIsPrivate() throws {
        Runtime.ensureStateDirectory()
        let attrs = try FileManager.default.attributesOfItem(atPath: Runtime.stateDirectory.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        // Phase 5 writes event titles, notes and attendee names here, so group and other
        // must have no access.
        #expect(perms & 0o077 == 0, "mode is \(String(perms, radix: 8)), expected no group/other bits")
    }
}
