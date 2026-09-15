import Foundation
import MCP
import Testing
@testable import apple_calendar_mcp

@Suite("Harmless approval diagnostic", .timeLimit(.minutes(1)))
struct ApprovalProbeTests {
    @Test("probe is absent by default and opt-in is independent of read-only")
    func catalog() {
        #expect(!ToolRegistry.names.contains("calendar_approval_probe"))
        #expect(ToolRegistry.all(approvalProbeEnabled: true).count == ToolRegistry.all().count + 1)
        #expect(ApprovalProbe.tool.annotations.readOnlyHint == true)
        #expect(ApprovalProbe.tool.annotations.destructiveHint == false)
        #expect(ApprovalProbe.tool.annotations.idempotentHint == false)
        if case .serve = Command.parse(["--read-only", "--enable-approval-probe"]) {} else {
            Issue.record("probe and read-only flags must both be accepted")
        }
    }

    @Test("every outcome matches the diagnostic output schema")
    func schema() throws {
        let schemaValue = try #require(ApprovalProbe.tool.outputSchema)
        let schema = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(schemaValue)) as? [String: Any])
        for outcome in ApprovalProbe.Outcome.allCases {
            let payload = try #require(ApprovalProbe.result(outcome).structuredContent)
            let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
            #expect(SchemaCheck.typeMismatches(value: value, schema: schema).isEmpty)
        }
    }

    @Test("absent form support refuses before invoking the SDK")
    func unsupported() async throws {
        let result = try await ApprovalProbe().run(formSupported: false) {
            Issue.record("unsupported client was asked")
            return .init(action: .accept, content: ["confirm": .bool(true)])
        }
        #expect(result == .unsupported)
    }

    @Test("only explicit valid affirmative acceptance counts")
    func responses() async throws {
        let values: [(CreateElicitation.Result, ApprovalProbe.Outcome)] = [
            (.init(action: .accept, content: ["confirm": .bool(true)]), .accepted),
            (.init(action: .accept, content: ["confirm": .bool(false)]), .invalidResponse),
            (.init(action: .accept, content: ["confirm": .string("true")]), .invalidResponse),
            (.init(action: .accept), .invalidResponse),
            (.init(action: .accept, content: ["confirm": .bool(true), "extra": .bool(true)]), .invalidResponse),
            (.init(action: .decline), .declined), (.init(action: .cancel), .canceled)
        ]
        let probe = ApprovalProbe()
        for (response, expected) in values {
            #expect(try await probe.run(formSupported: true) { response } == expected)
            guard case .object(let payload)? = ApprovalProbe.result(expected).structuredContent else {
                Issue.record("diagnostic lacks structured content"); continue
            }
            #expect(payload["calendar_changed"] == .bool(false))
            #expect(payload["authorizes_writes"] == .bool(false))
        }
    }

    @Test("timeouts disconnects and errors refuse without exposing details")
    func errors() async throws {
        let probe = ApprovalProbe()
        #expect(try await probe.run(formSupported: true) {
            throw Server.RequestLifecycleError.timedOut
        } == .timedOut)
        #expect(try await probe.run(formSupported: true) {
            throw Server.RequestLifecycleError.disconnected
        } == .disconnected)
        #expect(try await probe.run(formSupported: true) {
            throw MCPError.internalError("private fixture marker")
        } == .error)
        #expect(try await probe.run(formSupported: true) {
            .init(action: .accept, content: ["confirm": .bool(true)])
        } == .accepted, "refusal must release admission")
    }

    @Test("overlap refuses and canceled caller cannot accept a late answer")
    func overlapAndLateAnswer() async throws {
        let probe = ApprovalProbe(), held = HeldApproval()
        let first = Task { try await probe.run(formSupported: true) { await held.wait() } }
        let bound = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await held.started), ContinuousClock.now < bound {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await held.started else {
            first.cancel()
            await held.release()
            _ = try? await first.value
            Issue.record("first request never started")
            return
        }
        #expect(try await probe.run(formSupported: true) {
            Issue.record("overlap emitted a second prompt")
            return .init(action: .accept, content: ["confirm": .bool(true)])
        } == .busy)
        first.cancel()
        await held.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await probe.run(formSupported: true) { .init(action: .decline) } == .declined)
    }

    @Test("already canceled caller cannot send or produce acceptance")
    func canceled() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ApprovalProbe().run(formSupported: true) {
                Issue.record("canceled caller invoked SDK")
                return .init(action: .accept, content: ["confirm": .bool(true)])
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private actor HeldApproval {
    private var continuation: CheckedContinuation<CreateElicitation.Result, Never>?
    private(set) var started = false
    private var released = false
    func wait() async -> CreateElicitation.Result {
        if released { return .init(action: .accept, content: ["confirm": .bool(true)]) }
        return await withCheckedContinuation {
            continuation = $0
            started = true
        }
    }
    func release() {
        released = true
        continuation?.resume(returning: .init(action: .accept, content: ["confirm": .bool(true)]))
        continuation = nil
    }
}
