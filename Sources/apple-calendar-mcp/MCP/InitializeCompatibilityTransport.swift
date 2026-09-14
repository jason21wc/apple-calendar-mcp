import Foundation
import Logging
import MCP

/// Workaround for swift-sdk 0.12.1's `experimental: [String: String]?` decoder.
/// MCP permits object-valued experimental capabilities. We implement/advertise none, so
/// ignore those optional entries before the SDK decodes initialize. Standard capabilities
/// (especially elicitation) and the SDK's negotiated-session state remain untouched.
/// Remove this adapter when the pinned SDK accepts protocol-correct experimental objects.
actor InitializeCompatibilityTransport: Transport {
    nonisolated let logger: Logger
    private let base: any Transport
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var pump: Task<Void, Never>?

    init(base: any Transport) async {
        self.base = base
        self.logger = await base.logger
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func connect() async throws {
        try await base.connect()
        guard pump == nil else { return }
        let source = await base.receive()
        let continuation = self.continuation
        let task = Task {
            do {
                for try await data in source {
                    try Task.checkCancellation()
                    let normalized = try Self.normalizeInitialize(data)
                    if normalized != data {
                        log("initialize: ignored unsupported experimental objects (SDK compatibility)")
                    }
                    continuation.yield(normalized)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        pump = task
        continuation.onTermination = { _ in task.cancel() }
    }

    func disconnect() async {
        let task = pump
        pump = nil
        task?.cancel()
        await base.disconnect()
        continuation.finish()
        await task?.value
    }

    func send(_ data: Data) async throws { try await base.send(data) }
    func receive() -> AsyncThrowingStream<Data, Error> { stream }

    /// Return original bytes unless a request contains an unsupported experimental object.
    /// Invalid JSON/invalid capability values go to the SDK unchanged for normal rejection.
    /// For SDK-supported batches, only initialize entries change semantically.
    nonisolated static func normalizeInitialize(_ data: Data) throws -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return data }
        var changed = false
        func normalize(_ value: Any) -> Any {
            guard var request = value as? [String: Any],
                  request["jsonrpc"] as? String == "2.0",
                  request["method"] as? String == "initialize", request["id"] != nil,
                  var params = request["params"] as? [String: Any],
                  var capabilities = params["capabilities"] as? [String: Any],
                  let experimental = capabilities["experimental"] as? [String: Any]
            else { return value }
            let retained = experimental.filter { !($0.value is [String: Any]) }
            guard retained.count != experimental.count else { return value }
            capabilities["experimental"] = retained
            params["capabilities"] = capabilities
            request["params"] = params
            changed = true
            return request
        }
        let result: Any
        if let batch = json as? [Any] {
            result = batch.map(normalize)
        } else {
            result = normalize(json)
        }
        return changed ? try JSONSerialization.data(withJSONObject: result) : data
    }
}
