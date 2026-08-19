// What these tests protect
//
// The Calendar authorization state is the only thing standing between "this server can read
// your calendar" and "this server cannot". Two ways it has historically degraded:
//
//   * treating something other than .fullAccess as usable -- .writeOnly in particular, which
//     permits saving items but not reading them, so every read fails while writes appear to
//     work (gotcha 1);
//   * telling the user to run a recovery command that cannot work. `tccutil reset Calendar
//     <bundle-id>` fails with OSStatus -10814 against our row, because the row is keyed to
//     the binary's absolute PATH (client_type=1) and tccutil accepts bundle identifiers
//     only. That advice shipped in this exact file and was corrected (gotcha 32).
//
// Neither failure is visible at runtime, so both need a test that fails loudly.

import Testing
import EventKit
@testable import apple_calendar_mcp

@Suite("Calendar authorization state")
struct AuthorizationStateTests {

    // MARK: - Five states, not six

    @Test("EKAuthorizationStatus offers five distinct values, so no six-state gate can pass")
    func fiveDistinctStatusValues() {
        // EKTypes.h: NotDetermined=0, Restricted=1, Denied=2, FullAccess=3, WriteOnly=4,
        // and Authorized (deprecated) = FullAccess = 3.
        let mapped = (0...4).map { AuthorizationState(EKAuthorizationStatus(rawValue: $0)!) }

        #expect(mapped == [.notDetermined, .restricted, .denied, .fullAccess, .writeOnly],
                "raw value -> state mapping changed; check EKTypes.h before touching this")
        #expect(Set(mapped).count == 5, "two raw values collapsed onto one state")
        #expect(!mapped.contains(.unknown),
                ".unknown is a sentinel for a FUTURE macOS value; no shipping raw value may map to it")
    }

    @Test("`authorized` is an alias of `fullAccess`, not a sixth state that can be told apart")
    @available(*, deprecated, message: "deliberately references the deprecated alias; that IS the property under test")
    func authorizedIsIndistinguishableFromFullAccess() {
        // If a future SDK ever gives `Authorized` its own raw value, this fails and every
        // switch in the codebase needs revisiting. That is exactly the alarm we want.
        #expect(EKAuthorizationStatus.authorized.rawValue == EKAuthorizationStatus.fullAccess.rawValue)
        #expect(AuthorizationState(.authorized) == AuthorizationState(.fullAccess))
        #expect(AuthorizationState(.authorized) == .fullAccess)
    }

    @Test("an unrecognised OS value degrades to .unknown instead of being mistaken for a real state")
    func futureStatusValueBecomesUnknown() {
        // 99 stands in for a value a later macOS adds. @unknown default must catch it.
        guard let future = EKAuthorizationStatus(rawValue: 99) else {
            Issue.record("EKAuthorizationStatus rejected an out-of-range raw value; rewrite this test")
            return
        }
        #expect(AuthorizationState(future) == .unknown)
        #expect(!AuthorizationState(future).canReadEvents,
                "an unrecognised state must never be treated as usable")
    }

    // MARK: - Only .fullAccess is usable

    @Test("only .fullAccess permits reading events")
    func onlyFullAccessCanReadEvents() {
        #expect(AuthorizationState.fullAccess.canReadEvents)

        // Named individually rather than only as a loop, so the intent survives a future
        // rewrite of the enum and so a reviewer can see which states are being excluded.
        #expect(!AuthorizationState.writeOnly.canReadEvents,
                "writeOnly permits SAVING items and not reading them; it is not usable here")
        #expect(!AuthorizationState.notDetermined.canReadEvents)
        #expect(!AuthorizationState.denied.canReadEvents)
        #expect(!AuthorizationState.restricted.canReadEvents)
        #expect(!AuthorizationState.unknown.canReadEvents)
    }

    @Test("exactly one state is usable, whatever states exist in future")
    func exactlyOneUsableState() {
        let usable = AuthorizationState.allCases.filter(\.canReadEvents)
        #expect(usable == [.fullAccess],
                "adding a second usable state is a permission widening and must be deliberate")
    }

    @Test(".writeOnly is a state of its own and is never folded into .denied")
    func writeOnlyIsNotConflatedWithDenied() {
        #expect(AuthorizationState.writeOnly != AuthorizationState.denied)
        #expect(AuthorizationState(EKAuthorizationStatus(rawValue: 4)!) == .writeOnly)
        #expect(AuthorizationState(EKAuthorizationStatus(rawValue: 2)!) == .denied)
        #expect(AuthorizationState.writeOnly.rawValue != AuthorizationState.denied.rawValue,
                "the rawValue string is what --doctor prints; two states must not print the same word")
        #expect(AuthorizationState.writeOnly.guidance != AuthorizationState.denied.guidance,
                "identical guidance means the user is being told to fix the wrong thing")
        #expect(AuthorizationState.writeOnly.guidance.lowercased().contains("write"),
                "writeOnly guidance must explain that writes work and reads do not")
    }

    // MARK: - Guidance

    @Test("every state gives the user something to read", arguments: AuthorizationState.allCases)
    func everyStateHasGuidance(state: AuthorizationState) {
        let trimmed = state.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!trimmed.isEmpty, "\(state.rawValue) has no guidance")
        #expect(trimmed.count >= 20,
                "\(state.rawValue) guidance is a stub (\(trimmed.count) chars): \(trimmed)")
    }

    @Test("no two states share guidance, so no state's advice can be silently inherited")
    func guidanceIsDistinctPerState() {
        let all = AuthorizationState.allCases.map(\.guidance)
        #expect(Set(all).count == all.count,
                "two states return the same guidance string")
    }

    // MARK: - Gotcha 32: tccutil cannot reset a path-keyed grant

    /// A guidance string RECOMMENDS tccutil when it names the command without, in the same
    /// breath, saying it cannot work here. Mentioning it in order to warn the user off is
    /// the desired behaviour and must keep passing; mentioning it as the remedy must not.
    private func recommendsTccutilReset(_ guidance: String) -> Bool {
        let lower = guidance.lowercased()
        guard lower.contains("tccutil") else { return false }
        let disclaimed = lower.contains("does not work")
            || lower.contains("cannot")
            || lower.contains("will not work")
        return !disclaimed
    }

    @Test("no state's guidance recommends `tccutil reset Calendar <bundle-id>`",
          arguments: AuthorizationState.allCases)
    func guidanceNeverRecommendsTccutilReset(state: AuthorizationState) {
        #expect(!recommendsTccutilReset(state.guidance), """
            \(state.rawValue) guidance names tccutil without saying it cannot work. \
            Our TCC row is client_type=1 (absolute path); tccutil accepts bundle \
            identifiers only and fails with OSStatus -10814. Gotcha 32.
            """)
    }

    @Test("tccutil is never part of the remedy a user is asked to follow",
          arguments: AuthorizationState.allCases)
    func tccutilNeverAppearsInTheActionableAdvice(state: AuthorizationState) {
        // Everything before the first "Note:" is what the user is being told to DO. A
        // disclaimer may live after it; an instruction may not live before it. This is the
        // assertion that fires if somebody moves the command back up into the advice while
        // leaving the warning wording somewhere lower down.
        let advice = state.guidance.components(separatedBy: "Note:").first ?? state.guidance
        #expect(!advice.lowercased().contains("tccutil"), """
            \(state.rawValue) guidance offers tccutil as an action before any disclaimer: \
            \(advice)
            """)
    }

    @Test("the recoverable states point at the remedy that actually works")
    func recoverableStatesPointAtSystemSettings() {
        // System Settings is the only per-app reset that works for a path-keyed row. Bare
        // `tccutil reset Calendar` also works but wipes every application's calendar access,
        // so it must never be the headline instruction.
        for state in [AuthorizationState.denied, .writeOnly] {
            #expect(state.guidance.contains("System Settings"),
                    "\(state.rawValue) does not name the one remedy that works")
        }
    }

    @Test(".notDetermined is the only state that tells the user to run --setup")
    func setupIsOfferedOnlyWhereItCanHelp() {
        #expect(AuthorizationState.notDetermined.guidance.contains("--setup"))

        // --setup cannot lift an MDM or parental-controls restriction, and offering it there
        // sends the user round a loop that always fails.
        #expect(!AuthorizationState.restricted.guidance.contains("--setup"),
                "restricted is policy-imposed; --setup can never clear it")
        #expect(!AuthorizationState.fullAccess.guidance.contains("--setup"))
    }

    @Test("only the usable state reports success")
    func onlyFullAccessReadsAsSuccess() {
        #expect(AuthorizationState.fullAccess.guidance.lowercased().contains("granted"))
        for state in AuthorizationState.allCases where !state.canReadEvents {
            let lower = state.guidance.lowercased()
            #expect(!(lower.contains("access granted") || lower.contains("access is granted")),
                    "\(state.rawValue) guidance reads as success but the state is unusable")
        }
    }

    @Test("the rawValue strings --doctor prints stay distinct and stable")
    func rawValueStringsAreDistinct() {
        let names = AuthorizationState.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        // These strings appear in --doctor output and in the probe JSON, which is the
        // project's record of measured platform behaviour. Renaming one silently
        // invalidates every record already on disk.
        #expect(names == ["notDetermined", "restricted", "denied", "writeOnly", "fullAccess", "unknown"])
    }
}
