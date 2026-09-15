// Harmless opt-in measurement. No EventKit or journal dependency and no approval token.
import MCP

actor ApprovalProbe {
    enum Outcome: String, Sendable, CaseIterable {
        case accepted, declined, canceled, unsupported, busy, error
        case timedOut = "timed_out"
        case disconnected
        case invalidResponse = "invalid_response"
    }

    private var pending = false

    static let message = """
        Apple Calendar approval test. This changes no calendar data and grants no permission \
        for future writes. To test acceptance, check the confirmation box and accept. You can \
        decline or cancel instead. This test expires after 30 seconds.
        """
    static let schema = Elicitation.RequestSchema(
        title: "Harmless Calendar approval test",
        properties: ["confirm": .object([
            "type": .string("boolean"),
            "title": .string("I confirm this harmless test"),
            "default": .bool(false)
        ])], required: ["confirm"])

    static let tool = Tool(
        name: "calendar_approval_probe",
        description: "Ask the human to confirm a harmless diagnostic. Changes no calendar data, "
            + "grants no future write permission, and expires after 30 seconds. "
            + "Run only when the human is ready to test their client's approval UI.",
        inputSchema: .object([
            "type": .string("object"), "properties": .object([:]),
            "additionalProperties": .bool(false)
        ]),
        annotations: .init(readOnlyHint: true, destructiveHint: false,
                           idempotentHint: false, openWorldHint: false),
        outputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "outcome": .object(["type": .string("string"), "enum": .array([
                    "accepted", "declined", "canceled", "unsupported", "busy", "error",
                    "timed_out", "disconnected", "invalid_response"
                ].map(Value.string))]),
                "calendar_changed": .object(["type": .string("boolean"), "const": .bool(false)]),
                "authorizes_writes": .object(["type": .string("boolean"), "const": .bool(false)])
            ]),
            "required": .array(["outcome", "calendar_changed", "authorizes_writes"].map(Value.string)),
            "additionalProperties": .bool(false)
        ]))

    /// The SDK owns the deadline and resource cleanup. A wrapper race must not abandon it.
    func run(formSupported: Bool,
             request: @Sendable () async throws -> CreateElicitation.Result) async throws -> Outcome {
        try Task.checkCancellation()
        guard formSupported else { return .unsupported }
        guard !pending else { return .busy }
        pending = true
        defer { pending = false }
        do {
            let response = try await request()
            // If cancellation beat delivery back to the handler, acceptance is no longer valid.
            try Task.checkCancellation()
            switch response.action {
            case .decline: return .declined
            case .cancel: return .canceled
            case .accept:
                guard response.content == ["confirm": .bool(true)] else { return .invalidResponse }
                return .accepted
            }
        } catch is CancellationError {
            // Let the SDK honor cancellation of the enclosing tools/call without a reply.
            throw CancellationError()
        } catch Server.RequestLifecycleError.timedOut {
            return .timedOut
        } catch Server.RequestLifecycleError.disconnected {
            return .disconnected
        } catch {
            return .error
        }
    }

    static func result(_ outcome: Outcome) -> CallTool.Result {
        .init(content: [.text("Approval test: \(outcome.rawValue). No calendar data changed; "
                            + "this does not authorize writes.")],
              structuredContent: ["outcome": .string(outcome.rawValue),
                                  "calendar_changed": .bool(false),
                                  "authorizes_writes": .bool(false)], isError: false)
    }
}
