import Foundation
import Logging
import Testing
@testable import MCP
@testable import apple_calendar_mcp

/// These tests exercise the SDK's real JSON-RPC dispatch against a synthetic peer.
/// No process, EventKit store, user approval UI, or persistent state is involved.
@Suite("MCP request lifecycle", .timeLimit(.minutes(1)))
struct MCPRequestLifecycleTests {
    @Test("all protocol actions settle exactly once", arguments: ["accept", "decline", "cancel"])
    func actions(action: String) async throws {
        let fixture = try await Fixture.start()
        do {
            let attempt = Attempt(server: fixture.server)
            let request = try await fixture.transport.elicitation()
            try await fixture.transport.reply(request, action: action)
            let result = try await attempt.result()
            #expect(result.action.rawValue == action)
            try await fixture.assertSettled()
            try await fixture.assertReadable()
        } catch { await fixture.server.stop(); throw error }
        await fixture.server.stop()
    }

    @Test("silence times out, late and duplicate answers cannot settle a newer attempt")
    func silenceAndLateResponses() async throws {
        let fixture = try await Fixture.start()
        do {
            let first = Attempt(server: fixture.server, timeout: .milliseconds(100))
            let old = try await fixture.transport.elicitation()
            await #expect(throws: Server.RequestLifecycleError.timedOut) { try await first.result() }
            try await fixture.assertSettled()
            try await fixture.assertReadable()
            let second = Attempt(server: fixture.server)
            let current = try await fixture.transport.elicitation(after: 1)
            #expect(old.id != current.id)
            try await fixture.transport.reply(old, action: "accept")
            try await fixture.transport.reply(old, action: "accept")
            // A ping response is an event barrier: the receive loop processed old replies.
            try await fixture.assertReadable()
            #expect(await second.completion.value == nil)
            try await fixture.transport.reply(current, action: "decline")
            #expect(try await second.result().action == .decline)
            try await fixture.transport.reply(current, action: "accept")
            try await fixture.assertReadable()
            try await fixture.assertSettled()
        } catch { await fixture.server.stop(); throw error }
        await fixture.server.stop()
    }

    @Test("cancellation before outgoing registration emits no request")
    func alreadyCancelled() async throws {
        let fixture = try await Fixture.start()
        do {
            let attempt = Attempt(server: fixture.server, cancelBeforeRequest: true)
            await #expect(throws: CancellationError.self) { try await attempt.result() }
            try await fixture.assertSettled()
            #expect(await fixture.transport.elicitationCount == 0)
            try await fixture.assertReadable()
        } catch { await fixture.server.stop(); throw error }
        await fixture.server.stop()
    }

    @Test("cancellation while waiting settles the task and preserves ordinary requests")
    func waitingCancellation() async throws {
        let fixture = try await Fixture.start()
        do {
            let attempt = Attempt(server: fixture.server)
            let request = try await fixture.transport.elicitation()
            attempt.task.cancel()
            await #expect(throws: CancellationError.self) { try await attempt.result() }
            try await fixture.transport.reply(request, action: "accept")
            try await fixture.assertReadable()
            try await fixture.assertSettled()
        } catch { await fixture.server.stop(); throw error }
        await fixture.server.stop()
    }

    @Test("stop and receive EOF settle outgoing tasks", arguments: [false, true])
    func disconnect(eof: Bool) async throws {
        let fixture = try await Fixture.start()
        let attempt = Attempt(server: fixture.server)
        _ = try await fixture.transport.elicitation()
        if eof { await fixture.transport.finish() }
        else { await fixture.server.stop() }
        await #expect(throws: Server.RequestLifecycleError.disconnected) { try await attempt.result() }
        try await fixture.assertSettled()
        await fixture.server.stop()
    }

    @Test("deadline includes a suspended send and releases the sending task")
    func stalledSend() async throws {
        let fixture = try await Fixture.start()
        do {
            await fixture.transport.setSendMode(.stallElicitation)
            let attempt = Attempt(server: fixture.server, timeout: .milliseconds(100))
            await #expect(throws: Server.RequestLifecycleError.timedOut) { try await attempt.result() }
            try await fixture.assertSettled()
            #expect(await fixture.transport.activeSends == 0)
            await fixture.transport.setSendMode(.normal)
            try await fixture.assertReadable()
        } catch { await fixture.server.stop(); throw error }
        await fixture.server.stop()
    }

    @Test("send failure and malformed result release pending state", arguments: [false, true])
    func failures(sendError: Bool) async throws {
        let fixture = try await Fixture.start()
        do {
            if sendError { await fixture.transport.setSendMode(.failElicitation) }
            let attempt = Attempt(server: fixture.server)
            if !sendError {
                let request = try await fixture.transport.elicitation()
                let id = String(decoding: try JSONEncoder().encode(request.id), as: UTF8.self)
                await fixture.transport.push(Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"action\":\"not-an-action\"}}".utf8))
                do {
                    _ = try await attempt.result()
                    Issue.record("Malformed action was accepted")
                } catch {
                    #expect(!(error is Server.RequestLifecycleError))
                    #expect(!(error is WaitFailure))
                }
            } else {
                do {
                    _ = try await attempt.result()
                    Issue.record("Failed transport send succeeded")
                } catch {
                    #expect(!(error is Server.RequestLifecycleError))
                    #expect(!(error is WaitFailure))
                }
            }
            try await fixture.assertSettled()
            await fixture.transport.setSendMode(.normal)
            try await fixture.assertReadable()
        } catch { await fixture.server.stop(); throw error }
        await fixture.server.stop()
    }

    @Test("outer wire cancellation reaches nested request", arguments: [false, true])
    func outerWireCancellation(beforeInnerRegistration: Bool) async throws {
        let fixture = try await Fixture.start()
        let gate = Gate()
        let entered = Completion<Bool>()
        let completed = Completion<Bool>()
        await fixture.server.withMethodHandler(CallTool.self) { _ in
            await entered.set(true)
            if beforeInnerRegistration { await gate.wait() }
            do {
                _ = try await fixture.server.requestElicitation(
                    message: "Synthetic lifecycle test", requestedSchema: .init(), timeout: .seconds(2))
                await completed.set(true)
                return .init(content: [.text(text: "accepted", annotations: nil, _meta: nil)])
            } catch {
                await completed.set(false)
                throw error
            }
        }
        do {
            await fixture.transport.push(Data(#"{"jsonrpc":"2.0","id":"outer","method":"tools/call","params":{"name":"fixture"}}"#.utf8))
            try await MCPRequestLifecycleTests.eventually { await entered.value == true }
            if !beforeInnerRegistration { _ = try await fixture.transport.elicitation() }
            await fixture.transport.push(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"outer"}}"#.utf8))
            // This barrier observes cancellation delivery before releasing the handler.
            try await fixture.assertReadable()
            await gate.release()
            try await MCPRequestLifecycleTests.eventually { await completed.value != nil }
            #expect(await completed.value == false)
            try await fixture.assertSettled()
            if beforeInnerRegistration { #expect(await fixture.transport.elicitationCount == 0) }
            #expect(await fixture.transport.messages.contains { $0.id == .string("outer") && $0.result != nil } == false)
            try await fixture.assertReadable()
        } catch { await gate.release(); await fixture.server.stop(); throw error }
        await fixture.server.stop()
    }

    @Test("response processing rechecks expiry even before the real timer wakes")
    func expiredResponse() async throws {
        let fixture = try await Fixture.start()
        do {
            let now = ContinuousClock.now
            await fixture.server._setRequestLifecycleNow { now }
            let attempt = Attempt(server: fixture.server, timeout: .seconds(60))
            let request = try await fixture.transport.elicitation()
            await fixture.server._setRequestLifecycleNow { now.advanced(by: .seconds(61)) }
            try await fixture.transport.reply(request, action: "accept")
            await #expect(throws: Server.RequestLifecycleError.timedOut) { try await attempt.result() }
            try await fixture.assertSettled()
            try await fixture.assertReadable()
        } catch { await fixture.server.stop(); throw error }
        await fixture.server.stop()
    }

    @Test("stalled cancellation notices stay bounded and do not block local cleanup")
    func stalledCancellationNotice() async throws {
        let fixture = try await Fixture.start()
        do {
            await fixture.transport.setSendMode(.stallCancellation)
            for index in 0..<4 {
                let attempt = Attempt(server: fixture.server)
                _ = try await fixture.transport.elicitation(after: index)
                attempt.task.cancel()
                await #expect(throws: CancellationError.self) { try await attempt.result() }
                let counts = await fixture.server.requestLifecycleDiagnostics()
                #expect(counts.pendingOutgoingRequests == 0)
                #expect(counts.cancellationNotificationTasks <= 1)
                try await fixture.assertReadable()
            }
            try await fixture.assertSettled()
            #expect(await fixture.transport.activeSends == 0)
        } catch { await fixture.server.stop(); throw error }
        await fixture.server.stop()
    }

    @Test("an expired budget refuses before any send")
    func expiredBeforeSend() async throws {
        let fixture = try await Fixture.start()
        do {
            let attempt = Attempt(server: fixture.server, timeout: .zero)
            await #expect(throws: Server.RequestLifecycleError.timedOut) { try await attempt.result() }
            try await fixture.assertSettled()
            #expect(await fixture.transport.elicitationCount == 0)
            try await fixture.assertReadable()
        } catch { await fixture.server.stop(); throw error }
        await fixture.server.stop()
    }

    @Test("disconnect racing registration leaves neither tasks nor pending entries")
    func disconnectRacingRegistration() async throws {
        for _ in 0..<12 {
            let fixture = try await Fixture.start()
            let attempt = Attempt(server: fixture.server)
            await fixture.server.stop()
            do {
                _ = try await attempt.result()
                Issue.record("An unanswered request succeeded while its connection closed")
            } catch {
                #expect(!(error is WaitFailure))
            }
            try await fixture.assertSettled()
        }
    }

    @Test("outer cancellation racing acceptance never retains inner or handler tasks")
    func outerCancellationRacingAcceptance() async throws {
        for _ in 0..<8 {
            let fixture = try await Fixture.start()
            await fixture.server.withMethodHandler(CallTool.self) { _ in
                _ = try await fixture.server.requestElicitation(message: "Synthetic lifecycle test",
                    requestedSchema: .init(), timeout: .seconds(2))
                return .init(content: [.text(text: "accepted", annotations: nil, _meta: nil)])
            }
            do {
                await fixture.transport.push(Data(#"{"jsonrpc":"2.0","id":"race","method":"tools/call","params":{"name":"fixture"}}"#.utf8))
                let request = try await fixture.transport.elicitation()
                await fixture.transport.push(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"race"}}"#.utf8))
                try await fixture.transport.reply(request, action: "accept")
                try await fixture.assertReadable()
                try await fixture.assertSettled()
                #expect(await fixture.transport.messages.contains { $0.id == .string("race") && $0.result != nil } == false)
            } catch { await fixture.server.stop(); throw error }
            await fixture.server.stop()
        }
    }

    @Test("two probes in one wire batch overlap and refuse busy without queuing")
    func batchProbeOverlap() async throws {
        let fixture = try await Fixture.start()
        let probe = ApprovalProbe()
        let busy = Completion<Bool>()
        await fixture.server.withMethodHandler(CallTool.self) { _ in
            let outcome = try await probe.run(formSupported: true) {
                try await fixture.server.requestElicitation(message: ApprovalProbe.message,
                    requestedSchema: ApprovalProbe.schema, timeout: .seconds(2))
            }
            if outcome == .busy { await busy.set(true) }
            return ApprovalProbe.result(outcome)
        }
        do {
            await fixture.transport.push(Data(#"[{"jsonrpc":"2.0","id":"one","method":"tools/call","params":{"name":"calendar_approval_probe"}},{"jsonrpc":"2.0","id":"two","method":"tools/call","params":{"name":"calendar_approval_probe"}}]"#.utf8))
            let request = try await fixture.transport.elicitation()
            // Busy must be computed while the only prompt remains unanswered. A
            // sequential dispatcher would queue the second prompt instead.
            try await MCPRequestLifecycleTests.eventually { await busy.value == true }
            #expect(await fixture.transport.elicitationCount == 1)
            try await fixture.transport.reply(request, action: "accept")
            try await MCPRequestLifecycleTests.eventually { await fixture.transport.batches.count == 1 }
            let batch = try #require(await fixture.transport.batches.first)
            let outcomes = batch.compactMap { envelope -> String? in
                guard case .object(let result)? = envelope.result,
                      case .object(let content)? = result["structuredContent"],
                      case .string(let outcome)? = content["outcome"] else { return nil }
                return outcome
            }
            #expect(outcomes.sorted() == ["accepted", "busy"])
            try await fixture.assertSettled()
            try await fixture.assertReadable()
        } catch { await fixture.server.stop(); throw error }
        await fixture.server.stop()
    }

    @Test("wire cancellation discards an accepted batch result held before aggregate flush")
    func cancelBufferedBatchAcceptance() async throws {
        let fixture = try await Fixture.start()
        let probe = ApprovalProbe()
        let gate = Gate()
        let held = Completion<Bool>()
        await fixture.server.withMethodHandler(CallTool.self) { params in
            if params.name == "hold" {
                await held.set(true)
                await gate.wait()
                return .init(content: [])
            }
            let outcome = try await probe.run(formSupported: true) {
                try await fixture.server.requestElicitation(message: ApprovalProbe.message,
                    requestedSchema: ApprovalProbe.schema, timeout: .seconds(2))
            }
            return ApprovalProbe.result(outcome)
        }
        do {
            await fixture.transport.push(Data(#"[{"jsonrpc":"2.0","id":"accepted-first","method":"tools/call","params":{"name":"calendar_approval_probe"}},{"jsonrpc":"2.0","id":"held-second","method":"tools/call","params":{"name":"hold"}}]"#.utf8))
            let request = try await fixture.transport.elicitation()
            try await fixture.transport.reply(request, action: "accept")
            try await MCPRequestLifecycleTests.eventually { await held.value == true }
            try await MCPRequestLifecycleTests.eventually {
                await fixture.server._completedBatchResponseCountForTesting > 0
            }
            #expect(await fixture.transport.batches.isEmpty)
            await fixture.transport.push(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"accepted-first"}}"#.utf8))
            try await fixture.assertReadable()
            await gate.release()
            try await MCPRequestLifecycleTests.eventually { await fixture.transport.batches.count == 1 }
            let batch = try #require(await fixture.transport.batches.first)
            #expect(batch.map(\.id) == [.string("held-second")])
            try await fixture.assertSettled()
            try await fixture.assertReadable()
        } catch { await gate.release(); await fixture.server.stop(); throw error }
        await fixture.server.stop()
    }

    private struct Fixture: Sendable {
        let server: MCP.Server
        let transport: PeerTransport

        static func start() async throws -> Fixture {
            let server = MCP.Server(name: "lifecycle-fixture", version: "1", configuration: .strict)
            let transport = PeerTransport()
            await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
            try await server.start(transport: transport)
            await transport.push(Data(#"{"jsonrpc":"2.0","id":"initialize","method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"synthetic","version":"1"},"capabilities":{"elicitation":{"form":{}}}}}"#.utf8))
            try await MCPRequestLifecycleTests.eventually { await transport.messages.contains { $0.id == .string("initialize") } }
            await transport.push(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
            return Fixture(server: server, transport: transport)
        }

        func assertReadable() async throws {
            let id = UUID().uuidString
            await transport.push(Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"method\":\"tools/list\",\"params\":{}}".utf8))
            try await MCPRequestLifecycleTests.eventually { await transport.messages.contains { $0.id == .string(id) && $0.result != nil } }
        }

        func assertSettled() async throws {
            try await MCPRequestLifecycleTests.eventually {
                let counts = await server.requestLifecycleDiagnostics()
                return counts.pendingOutgoingRequests == 0 && counts.outgoingSendTasks == 0
                    && counts.deadlineTasks == 0 && counts.incomingRequestTasks == 0
                    && counts.cancellationNotificationTasks == 0 && counts.responseSendTasks == 0
            }
        }
    }

    private struct Attempt: Sendable {
        let task: Task<CreateElicitation.Result, Error>
        let completion: Completion<Bool>
        init(server: MCP.Server, timeout: Duration = .seconds(2), cancelBeforeRequest: Bool = false) {
            let completion = Completion<Bool>()
            self.completion = completion
            task = Task {
                if cancelBeforeRequest { withUnsafeCurrentTask { $0?.cancel() } }
                do {
                    let response = try await server.requestElicitation(message: "Synthetic lifecycle test",
                        requestedSchema: .init(), timeout: timeout)
                    await completion.set(true)
                    return response
                } catch {
                    await completion.set(false)
                    throw error
                }
            }
        }
        func result() async throws -> CreateElicitation.Result {
            // Poll completion before task.value: a broken continuation must fail boundedly
            // rather than hanging a task group while it waits for its canceled child.
            try await MCPRequestLifecycleTests.eventually { await completion.value != nil }
            return try await task.value
        }
    }

    private actor Completion<T: Sendable> {
        var value: T?
        func set(_ value: T) { self.value = value }
    }

    private actor Gate {
        private let stream: AsyncStream<Bool>
        private let continuation: AsyncStream<Bool>.Continuation
        init() { (stream, continuation) = AsyncStream.makeStream() }
        func wait() async { for await _ in stream { break } }
        func release() { continuation.yield(true); continuation.finish() }
    }

    private struct Envelope: Decodable, Sendable {
        let id: ID?
        let method: String?
        let result: Value?
    }

    private actor PeerTransport: Transport {
        enum SendMode { case normal, stallElicitation, failElicitation, stallCancellation }
        enum Failure: Error { case send }
        let logger = Logger(label: "synthetic-lifecycle", factory: { _ in SwiftLogNoOpLogHandler() })
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
        var messages: [Envelope] = []
        var batches: [[Envelope]] = []
        var requests: [Request<CreateElicitation>] = []
        var activeSends = 0
        private var mode = SendMode.normal
        var elicitationCount: Int { requests.count }
        init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
        func connect() {}
        func disconnect() { continuation.finish() }
        func receive() -> AsyncThrowingStream<Data, Error> { stream }
        func push(_ data: Data) { continuation.yield(data) }
        func finish() { continuation.finish() }
        func setSendMode(_ value: SendMode) { mode = value }
        func send(_ data: Data) async throws {
            activeSends += 1
            defer { activeSends -= 1 }
            if data.first == UInt8(ascii: "[") {
                let batch = try JSONDecoder().decode([Envelope].self, from: data)
                batches.append(batch)
                messages.append(contentsOf: batch)
                return
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            if envelope.method == "notifications/cancelled", mode == .stallCancellation {
                try await Task.sleep(for: .seconds(30))
            }
            if envelope.method == CreateElicitation.name {
                if mode == .failElicitation { throw Failure.send }
                if mode == .stallElicitation { try await Task.sleep(for: .seconds(30)) }
                requests.append(try JSONDecoder().decode(Request<CreateElicitation>.self, from: data))
            }
            messages.append(envelope)
        }
        func elicitation(after count: Int = 0) async throws -> Request<CreateElicitation> {
            try await MCPRequestLifecycleTests.eventually { await self.elicitationCount > count }
            return requests[count]
        }
        func reply(_ request: Request<CreateElicitation>, action: String) throws {
            let result = CreateElicitation.Result(action: .init(rawValue: action)!, content: ["confirm": .bool(true)])
            push(try JSONEncoder().encode(CreateElicitation.response(id: request.id, result: result)))
        }
    }

    private enum WaitFailure: Error { case deadline }
    private static func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw WaitFailure.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
