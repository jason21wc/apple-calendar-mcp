import Foundation
import Logging
import MCP
import Testing
@testable import apple_calendar_mcp

@Suite("Initialize compatibility", .timeLimit(.minutes(1)))
struct InitializeCompatibilityTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func request(capabilities: String) -> Data {
        data("""
        {"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{
        "protocolVersion":"2025-11-25","clientInfo":{"name":"fixture","version":"1"},
        "capabilities":\(capabilities)}}
        """)
    }

    @Test("experimental objects cannot prevent a real SDK handshake and tool discovery")
    func sdkHandshake() async throws {
        let pair = await InMemoryTransport.createConnectedPair()
        let transport = await InitializeCompatibilityTransport(base: pair.server)
        let server = MCP.Server(name: "fixture", version: "1",
                                capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolRegistry.all()) }
        try await pair.client.connect()
        try await server.start(transport: transport)
        do {
            try await pair.client.send(request(capabilities: """
            {"experimental":{"codex/fixture":{"nested":[true,1,null]}},"elicitation":{"form":{}}}
            """))
            let initialized = try object(await nextMessage(pair.client))
            #expect(initialized["error"] == nil)
            #expect(initialized["id"] as? String == "init-1")
            #expect(initialized["result"] != nil)
            try await pair.client.send(data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
            try await pair.client.send(data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#))
            let listed = try object(await nextMessage(pair.client))
            let result = try #require(listed["result"] as? [String: Any])
            let tools = try #require(result["tools"] as? [[String: Any]])
            #expect(Set(tools.compactMap { $0["name"] as? String }) == Set(ToolRegistry.all().map(\.name)))
        } catch {
            await server.stop()
            await pair.client.disconnect()
            throw error
        }
        await pair.client.disconnect()
        await server.waitUntilCompleted()
        await server.stop()
    }

    @Test("standard capabilities and request identity survive unchanged",
          arguments: [#"{}"#, #"{"elicitation":{"url":{}}}"#,
                      #"{"elicitation":{"form":{}},"roots":{"listChanged":true},"sampling":{}}"#])
    func preservesCapabilities(standard: String) throws {
        var caps = try object(data(standard))
        caps["experimental"] = ["optional/feature": ["enabled": true]]
        let input = request(capabilities: String(decoding: try JSONSerialization.data(withJSONObject: caps), as: UTF8.self))
        let output = try InitializeCompatibilityTransport.normalizeInitialize(input)
        let original = try object(input)
        let rewritten = try object(output)
        #expect(rewritten["id"] as? String == original["id"] as? String)
        var params = try #require(rewritten["params"] as? [String: Any])
        var actualCaps = try #require(params["capabilities"] as? [String: Any])
        actualCaps.removeValue(forKey: "experimental")
        #expect(NSDictionary(dictionary: actualCaps).isEqual(to: try object(data(standard))))
        params["capabilities"] = caps
        #expect(NSDictionary(dictionary: params).isEqual(to: try #require(original["params"] as? [String: Any])))
        let typed = try JSONDecoder().decode(Request<Initialize>.self, from: output)
        #expect((typed.params.capabilities.elicitation?.form != nil) == standard.contains("form"))
    }

    @Test("unrelated messages and malformed values remain byte-for-byte unchanged")
    func passthrough() throws {
        let values = [data("not JSON"), request(capabilities: "{}"),
                      request(capabilities: #"{"experimental":{"legacy":"value"}}"#),
                      request(capabilities: #"{"experimental":{"invalid":true}}"#),
                      data(#"{"jsonrpc":"2.0","method":"initialize","params":{"capabilities":{"experimental":{"x":{}}}}}"#),
                      data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"fixture","arguments":{"experimental":{"x":{}}}}}"#)]
        for input in values {
            #expect(try InitializeCompatibilityTransport.normalizeInitialize(input) == input)
        }
    }

    @Test("mixed entries preserve legacy strings and SDK rejection of malformed values")
    func mixedEntries() throws {
        let input = request(capabilities: #"{"experimental":{"unknown":{},"legacy":"ok","invalid":true}}"#)
        let output = try InitializeCompatibilityTransport.normalizeInitialize(input)
        let params = try #require(object(output)["params"] as? [String: Any])
        let caps = try #require(params["capabilities"] as? [String: Any])
        let experimental = try #require(caps["experimental"] as? [String: Any])
        #expect(experimental["unknown"] == nil)
        #expect(experimental["legacy"] as? String == "ok")
        #expect(experimental["invalid"] as? Bool == true)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Request<Initialize>.self, from: output) }
    }

    @Test("batch siblings preserve their content")
    func batch() throws {
        let initData = request(capabilities: #"{"experimental":{"x":{}}}"#)
        let sibling = #"{"jsonrpc":"2.0","id":9007199254740993,"method":"ping","params":{"text":"unchanged"}}"#
        let input = data("[\(String(decoding: initData, as: UTF8.self)),\(sibling)]")
        let output = try InitializeCompatibilityTransport.normalizeInitialize(input)
        let batch = try #require(JSONSerialization.jsonObject(with: output) as? [[String: Any]])
        #expect(NSDictionary(dictionary: batch[1]).isEqual(to: try object(data(sibling))))
        _ = try JSONDecoder().decode(Request<Initialize>.self, from: JSONSerialization.data(withJSONObject: batch[0]))
    }

    @Test("EOF, upstream errors, and outbound bytes cross the adapter unchanged")
    func lifecycle() async throws {
        for fail in [false, true] {
            let base = StreamFixture()
            let transport = await InitializeCompatibilityTransport(base: base)
            try await transport.connect()
            let outbound = data("outbound bytes")
            try await transport.send(outbound)
            #expect(await base.sent == outbound)
            await base.finish(fail: fail)
            var iterator = await transport.receive().makeAsyncIterator()
            do {
                let end = try await iterator.next()
                #expect(!fail)
                #expect(end == nil)
            } catch {
                #expect(fail)
                #expect(error is StreamFixture.Failure)
            }
            await transport.disconnect()
            #expect(await base.disconnected)
        }
    }

    @Test("cancelled consumption stops the mapper; disconnect releases the upstream")
    func cancellation() async throws {
        let base = StreamFixture()
        let transport = await InitializeCompatibilityTransport(base: base)
        try await transport.connect()
        let stream = await transport.receive()
        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        consumer.cancel()
        _ = try await consumer.value
        // A bounded wait on the upstream stream's termination callback proves cancellation
        // reached the mapper even before explicitly disconnecting the transport.
        _ = try await nextData(base.termination)
        await transport.disconnect()
        #expect(await base.disconnected)
    }

    private actor StreamFixture: Transport {
        enum Failure: Error { case upstream }
        nonisolated let logger = Logger(label: "fixture", factory: { _ in SwiftLogNoOpLogHandler() })
        nonisolated let termination: AsyncThrowingStream<Data, Error>
        let stream: AsyncThrowingStream<Data, Error>
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
        var sent: Data?
        var disconnected = false

        init() {
            (stream, continuation) = AsyncThrowingStream.makeStream()
            let ended = AsyncThrowingStream<Data, Error>.makeStream()
            termination = ended.stream
            continuation.onTermination = { _ in
                ended.continuation.yield(Data())
                ended.continuation.finish()
            }
        }
        func connect() {}
        func disconnect() { disconnected = true; continuation.finish() }
        func send(_ data: Data) { sent = data }
        func receive() -> AsyncThrowingStream<Data, Error> { stream }
        func finish(fail: Bool) {
            if fail { continuation.finish(throwing: Failure.upstream) }
            else { continuation.finish() }
        }
    }

    private enum WaitError: Error { case timeout, closed }
    private func nextMessage(_ transport: any Transport) async throws -> Data {
        try await nextData(transport.receive())
    }
    private func nextData(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let message = try await iterator.next() else { throw WaitError.closed }
                return message
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw WaitError.timeout
            }
            defer { group.cancelAll() }
            return try await #require(group.next())
        }
    }
}
