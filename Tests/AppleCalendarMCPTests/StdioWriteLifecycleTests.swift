import Darwin
import Foundation
import Testing
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif
@testable import MCP
@testable import apple_calendar_mcp

/// Real, owned pipes verify byte framing and backpressure without launching processes.
@Suite("Stdio write lifecycle", .timeLimit(.minutes(1)))
struct StdioWriteLifecycleTests {
    @Test("concurrent large frames remain whole under pipe backpressure")
    func concurrentFrames() async throws {
        try await withPipes { fixture in
            let first = Data(repeating: UInt8(ascii: "a"), count: 300_000)
            let second = Data(repeating: UInt8(ascii: "b"), count: 300_000)
            let one = SendAttempt(transport: fixture.transport, data: first)
            // The actor can answer this only after the large send suspends on a full
            // pipe; start its competitor before allowing the reader to drain it.
            try await StdioWriteLifecycleTests.eventually { await fixture.transport._isSendingForTesting }
            let two = SendAttempt(transport: fixture.transport, data: second)
            let bytes = try await fixture.read(count: first.count + second.count + 2)
            try await one.result()
            try await two.result()
            let lines = bytes.split(separator: UInt8(ascii: "\n"))
            #expect(lines.count == 2)
            #expect(Set(lines.map { Data($0) }) == Set([first, second]))
        }
    }

    @Test("canceling a zero-byte blocked send preserves the connection")
    func cancelBeforeAnyByte() async throws {
        try await withPipes { fixture in
            let fillerCount = try fixture.fillOutput()
            let stalled = SendAttempt(transport: fixture.transport, data: Data("abandoned".utf8))
            try await StdioWriteLifecycleTests.eventually { await fixture.transport._isSendingForTesting }
            stalled.task.cancel()
            await #expect(throws: CancellationError.self) { try await stalled.result() }
            let filler = try await fixture.read(count: fillerCount)
            #expect(filler.allSatisfy { $0 == UInt8(ascii: "f") })
            let next = SendAttempt(transport: fixture.transport, data: Data("next-frame".utf8))
            let actual = try await fixture.read(count: 11)
            try await next.result()
            #expect(actual == Data("next-frame\n".utf8))
        }
    }

    @Test("canceling a partial frame closes the connection instead of corrupting a later frame")
    func cancelAfterPartialWrite() async throws {
        try await withPipes { fixture in
            let stalled = SendAttempt(transport: fixture.transport,
                                      data: Data(repeating: UInt8(ascii: "p"), count: 1_000_000))
            // Actual bytes are the barrier: the writer has begun a frame and cannot fit
            // its remainder while the reader deliberately stops draining the small pipe.
            let prefix = try await fixture.read(count: 1)
            #expect(prefix == Data("p".utf8))
            stalled.task.cancel()
            await #expect(throws: CancellationError.self) { try await stalled.result() }
            do {
                try await fixture.transport.send(Data("must-not-appear".utf8))
                Issue.record("Transport accepted a frame after abandoning a partial line")
            } catch {
                #expect(error is MCPError)
            }
            let remaining = try fixture.drainAvailable()
            #expect(remaining.allSatisfy { $0 == UInt8(ascii: "p") })
            #expect(!remaining.contains(UInt8(ascii: "\n")))
        }
    }

    @Test("full stdout bounds outer response tasks and closes a stalled connection", arguments: [false, true])
    func boundedOuterResponses(overflow: Bool) async throws {
        try await withPipes { fixture in
            let server = MCP.Server(name: "pipe-lifecycle", version: "1")
            await server._setResponseLifecycleLimitsForTesting(
                timeout: overflow ? .seconds(30) : .milliseconds(100), maximumIncomingRequests: 4)
            let probe = ApprovalProbe()
            let calls = InvocationCounter()
            await server.withMethodHandler(CallTool.self) { _ in
                await calls.increment()
                let outcome = try await probe.run(formSupported: false) {
                    Issue.record("Unsupported synthetic peer must not receive elicitation")
                    return .init(action: .accept)
                }
                return ApprovalProbe.result(outcome)
            }
            try await server.start(transport: fixture.transport)
            let completed = Completion()
            let serving = Task { await server.waitUntilCompleted(); await completed.set() }
            do {
                _ = try fixture.fillOutput()
                try fixture.submitToolCall(id: 0)
                try await StdioWriteLifecycleTests.eventually { await fixture.transport._isSendingForTesting }
                let blocked = await server.requestLifecycleDiagnostics()
                #expect(blocked.incomingRequestTasks == 1)
                if overflow {
                    for id in 1..<8 { try fixture.submitToolCall(id: id) }
                }
                try await StdioWriteLifecycleTests.eventually { await completed.value }
                await serving.value
                let counts = await server.requestLifecycleDiagnostics()
                #expect(counts.incomingRequestTasks == 0)
                #expect(counts.pendingOutgoingRequests == 0)
                #expect(counts.outgoingSendTasks == 0)
                #expect(counts.deadlineTasks == 0)
                #expect(counts.cancellationNotificationTasks == 0)
                #expect(counts.responseSendTasks == 0)
                #expect(await calls.value <= 4)
                #expect(await fixture.transport._isSendingForTesting == false)
            } catch { await server.stop(); throw error }
            await server.stop()
        }
    }

    private struct Pipes: Sendable {
        let inputRead: Int32
        let inputWrite: Int32
        let outputRead: Int32
        let outputWrite: Int32
        let transport: StdioTransport

        init() throws {
            var input = [Int32](repeating: 0, count: 2)
            var output = [Int32](repeating: 0, count: 2)
            guard pipe(&input) == 0 else { throw PipeFailure.system }
            guard pipe(&output) == 0 else {
                close(input[0]); close(input[1]); throw PipeFailure.system
            }
            inputRead = input[0]; inputWrite = input[1]
            outputRead = output[0]; outputWrite = output[1]
            transport = StdioTransport(input: FileDescriptor(rawValue: input[0]),
                                       output: FileDescriptor(rawValue: output[1]))
            let flags = fcntl(outputRead, F_GETFL)
            guard flags >= 0, fcntl(outputRead, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                close(input[0]); close(input[1]); close(output[0]); close(output[1])
                throw PipeFailure.system
            }
        }

        func finish() async {
            await transport.disconnect()
            close(inputRead); close(inputWrite); close(outputRead); close(outputWrite)
        }

        func submitToolCall(id: Int) throws {
            let data = Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"name\":\"calendar_approval_probe\"}}\n".utf8)
            let written = data.withUnsafeBytes { Darwin.write(inputWrite, $0.baseAddress, $0.count) }
            guard written == data.count else { throw PipeFailure.system }
        }

        func fillOutput() throws -> Int {
            let bytes = [UInt8](repeating: UInt8(ascii: "f"), count: 4096)
            var total = 0
            while total < 4_000_000 {
                let count = bytes.withUnsafeBytes { Darwin.write(outputWrite, $0.baseAddress, $0.count) }
                if count > 0 { total += count }
                else if count < 0 && errno == EAGAIN { return total }
                else { throw PipeFailure.system }
            }
            throw PipeFailure.unboundedPipe
        }

        func read(count: Int) async throws -> Data {
            var result = Data()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while result.count < count {
                var buffer = [UInt8](repeating: 0, count: min(8192, count - result.count))
                let received = buffer.withUnsafeMutableBytes { Darwin.read(outputRead, $0.baseAddress, $0.count) }
                if received > 0 { result.append(contentsOf: buffer.prefix(received)) }
                else if received < 0 && errno == EAGAIN {
                    guard ContinuousClock.now < deadline else { throw PipeFailure.deadline }
                    try await Task.sleep(for: .milliseconds(1))
                } else { throw PipeFailure.system }
            }
            return result
        }

        func drainAvailable() throws -> Data {
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let received = buffer.withUnsafeMutableBytes { Darwin.read(outputRead, $0.baseAddress, $0.count) }
                if received > 0 { result.append(contentsOf: buffer.prefix(received)) }
                else if received < 0 && errno == EAGAIN { return result }
                else { throw PipeFailure.system }
            }
        }
    }

    private struct SendAttempt: Sendable {
        let task: Task<Void, Error>
        let completed: Completion
        init(transport: StdioTransport, data: Data) {
            let completed = Completion()
            self.completed = completed
            task = Task {
                do {
                    try await transport.send(data)
                    await completed.set()
                } catch {
                    await completed.set()
                    throw error
                }
            }
        }
        func result() async throws {
            try await StdioWriteLifecycleTests.eventually { await completed.value }
            try await task.value
        }
    }
    private actor InvocationCounter {
        var value = 0
        func increment() { value += 1 }
    }
    private actor Completion {
        var value = false
        func set() { value = true }
    }
    private enum PipeFailure: Error { case system, deadline, unboundedPipe }
    private static func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw PipeFailure.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func withPipes(_ operation: (Pipes) async throws -> Void) async throws {
        let fixture = try Pipes()
        do {
            try await fixture.transport.connect()
            try await operation(fixture)
        } catch {
            await fixture.finish()
            throw error
        }
        await fixture.finish()
    }
}
