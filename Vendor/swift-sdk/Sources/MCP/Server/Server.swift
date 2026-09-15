import Logging
import class Foundation.NSLock

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Model Context Protocol server
public actor Server {
    /// The server configuration
    public struct Configuration: Hashable, Codable, Sendable {
        /// The default configuration.
        public static let `default` = Configuration(strict: false)

        /// The strict configuration.
        public static let strict = Configuration(strict: true)

        /// When strict mode is enabled, the server:
        /// - Requires clients to send an initialize request before any other requests
        /// - Rejects all requests from uninitialized clients with a protocol error
        ///
        /// While the MCP specification requires clients to initialize the connection
        /// before sending other requests, some implementations may not follow this.
        /// Disabling strict mode allows the server to be more lenient with non-compliant
        /// clients, though this may lead to undefined behavior.
        public var strict: Bool
    }

    /// Implementation information
    public struct Info: Hashable, Codable, Sendable {
        /// The server name
        public let name: String
        /// A human-readable server title for display
        public let title: String?
        /// The server version
        public let version: String
        /// Optional description of the server
        public let description: String?
        /// Optional website URL for the server
        public let websiteUrl: String?
        /// Optional set of sized icons for display in a user interface
        public let icons: [Icon]?

        public init(
            name: String,
            version: String,
            title: String? = nil,
            description: String? = nil,
            websiteUrl: String? = nil,
            icons: [Icon]? = nil
        ) {
            self.name = name
            self.title = title
            self.version = version
            self.description = description
            self.websiteUrl = websiteUrl
            self.icons = icons
        }
    }

    /// Server capabilities
    public struct Capabilities: Hashable, Codable, Sendable {
        /// Resources capabilities
        public struct Resources: Hashable, Codable, Sendable {
            /// Whether the resource can be subscribed to
            public var subscribe: Bool?
            /// Whether the list of resources has changed
            public var listChanged: Bool?

            public init(
                subscribe: Bool? = nil,
                listChanged: Bool? = nil
            ) {
                self.subscribe = subscribe
                self.listChanged = listChanged
            }
        }

        /// Tools capabilities
        public struct Tools: Hashable, Codable, Sendable {
            /// Whether the server notifies clients when tools change
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Prompts capabilities
        public struct Prompts: Hashable, Codable, Sendable {
            /// Whether the server notifies clients when prompts change
            public var listChanged: Bool?

            public init(listChanged: Bool? = nil) {
                self.listChanged = listChanged
            }
        }

        /// Logging capabilities
        public struct Logging: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Completions capabilities
        public struct Completions: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Completions capabilities
        public var completions: Completions?
        /// Logging capabilities
        public var logging: Logging?
        /// Prompts capabilities
        public var prompts: Prompts?
        /// Resources capabilities
        public var resources: Resources?
        /// Tools capabilities
        public var tools: Tools?

        public init(
            completions: Completions? = nil,
            logging: Logging? = nil,
            prompts: Prompts? = nil,
            resources: Resources? = nil,
            tools: Tools? = nil
        ) {
            self.completions = completions
            self.logging = logging
            self.prompts = prompts
            self.resources = resources
            self.tools = tools
        }
    }

    /// Server information
    private let serverInfo: Server.Info
    /// The server connection
    private var connection: (any Transport)?
    /// The server logger
    private var logger: Logger? {
        get async {
            await connection?.logger
        }
    }

    /// The server name
    public nonisolated var name: String { serverInfo.name }
    /// A human-readable server title
    public nonisolated var title: String? { serverInfo.title }
    /// The server version
    public nonisolated var version: String { serverInfo.version }
    /// Instructions describing how to use the server and its features
    ///
    /// This can be used by clients to improve the LLM's understanding of
    /// available tools, resources, etc.
    /// It can be thought of like a "hint" to the model.
    /// For example, this information MAY be added to the system prompt.
    public nonisolated let instructions: String?
    /// The server capabilities
    public var capabilities: Capabilities
    /// The server configuration
    public var configuration: Configuration

    /// Request handlers
    private var methodHandlers: [String: RequestHandlerBox] = [:]
    /// Notification handlers
    private var notificationHandlers: [String: [NotificationHandlerBox]] = [:]
    /// Pending request tasks (for cancellation support)
    private var pendingRequestTasks: [ID: Task<Response<AnyMethod>?, Error>] = [:]
    // Batch handlers can finish before their response is committed. Retain a
    // cancellation flag as well as their task until the aggregate is handed off.
    private var incomingCancellationFlags: [ID: CancellationFlag] = [:]
    private var batchTasks: [ID: Task<Void, Never>] = [:]
    private var batchReservations: Set<ID> = []
    private var responseSendTasks = 0
    private var responseSendTimeout: Duration = .seconds(5)
    private var maximumIncomingRequests = 16

    // Local stdio defaults are conservative; tests use short, observable budgets.
    func _setResponseLifecycleLimitsForTesting(timeout: Duration, maximumIncomingRequests: Int) {
        precondition(timeout > .zero && maximumIncomingRequests > 1)
        responseSendTimeout = timeout
        self.maximumIncomingRequests = maximumIncomingRequests
    }
    private var completedBatchResponseIDs: Set<ID> = []
    // Observes fully computed results buffered behind another batch item.
    var _completedBatchResponseCountForTesting: Int { completedBatchResponseIDs.count }
    private var generation: UInt64 = 0
    private var isOpen = false
    private var hasStarted = false
    private var lifecycleNow: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }

    // Internal deterministic response-expiry seam, visible only to @testable clients.
    func _setRequestLifecycleNow(_ now: @escaping @Sendable () -> ContinuousClock.Instant) {
        lifecycleNow = now
    }
    private var outgoingSendTasks: [ID: Task<Void, Never>] = [:]
    private var deadlineTasks: [ID: Task<Void, Never>] = [:]
    private var cancellationNotificationTask: Task<Void, Never>?

    public enum RequestLifecycleError: Swift.Error, Sendable, Equatable {
        case timedOut
        case disconnected
    }

    public struct RequestLifecycleDiagnostics: Sendable {
        public let pendingOutgoingRequests: Int
        public let outgoingSendTasks: Int
        public let deadlineTasks: Int
        public let incomingRequestTasks: Int
        public let responseSendTasks: Int
        public let cancellationNotificationTasks: Int
    }

    public func requestLifecycleDiagnostics() -> RequestLifecycleDiagnostics {
        .init(pendingOutgoingRequests: pendingRequests.count,
              outgoingSendTasks: outgoingSendTasks.count, deadlineTasks: deadlineTasks.count,
              incomingRequestTasks: pendingRequestTasks.count + batchReservations.count,
              responseSendTasks: responseSendTasks,
              cancellationNotificationTasks: cancellationNotificationTask == nil ? 0 : 1)
    }

    /// Shared with the synchronous cancellation handler: an actor hop cannot delay
    /// cancellation visibility until after a racing successful response.
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct OutgoingRequest {
        let continuation: AnyPendingRequest
        let deadline: ContinuousClock.Instant?
        let cancellation: CancellationFlag
        let generation: UInt64
    }

    /// Pending requests sent to the client, awaiting responses
    private var pendingRequests: [ID: OutgoingRequest] = [:]

    /// Whether the server is initialized
    private var isInitialized = false
    /// The client information
    private var clientInfo: Client.Info?
    /// The client capabilities
    private var clientCapabilities: Client.Capabilities?
    /// The protocol version
    private var protocolVersion: String?
    /// The list of subscriptions
    private var subscriptions: [String: Set<ID>] = [:]
    /// The task for the message handling loop
    private var task: Task<Void, Never>?

    public init(
        name: String,
        version: String,
        title: String? = nil,
        instructions: String? = nil,
        capabilities: Server.Capabilities = .init(),
        configuration: Configuration = .default
    ) {
        self.serverInfo = Server.Info(name: name, version: version, title: title)
        self.capabilities = capabilities
        self.configuration = configuration
        self.instructions = instructions
    }

    /// Start the server
    /// - Parameters:
    ///   - transport: The transport to use for the server
    ///   - initializeHook: An optional hook that runs when the client sends an initialize request
    public func start(
        transport: any Transport,
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)? = nil
    ) async throws {
        guard !hasStarted else { throw MCPError.internalError("Server cannot be restarted") }
        hasStarted = true
        generation &+= 1
        let currentGeneration = generation
        self.connection = transport
        registerDefaultHandlers(initializeHook: initializeHook)
        registerCancellationHandler()
        try await transport.connect()
        guard connection != nil, generation == currentGeneration else {
            await transport.disconnect()
            throw RequestLifecycleError.disconnected
        }
        isOpen = true

        await logger?.debug(
            "Server started", metadata: ["name": "\(name)", "version": "\(version)"]
        )

        guard isOpen, generation == currentGeneration else {
            throw RequestLifecycleError.disconnected
        }
        // Start message handling loop
        task = Task {
            do {
                let stream = await transport.receive()
                for try await data in stream {
                    if Task.isCancelled { break }  // Check cancellation inside loop

                    var requestID: ID?
                    do {
                        // Attempt to decode as batch first, then as individual response, request, or notification
                        let decoder = JSONDecoder()
                        if let batch = try? decoder.decode(Server.Batch.self, from: data) {
                            try await handleBatch(batch)
                        } else if let response = try? decoder.decode(AnyResponse.self, from: data) {
                            await handleResponse(response)
                        } else if let request = try? decoder.decode(AnyRequest.self, from: data) {
                            // Handle request in a separate task to avoid blocking the receive loop
                            _ = startIncomingRequest(request, sendResponse: true)
                        } else if let message = try? decoder.decode(AnyMessage.self, from: data) {
                            try await handleMessage(message)
                        } else {
                            // Try to extract request ID from raw JSON if possible
                            if let json = try? JSONDecoder().decode(
                                [String: Value].self, from: data),
                                let idValue = json["id"]
                            {
                                if let strValue = idValue.stringValue {
                                    requestID = .string(strValue)
                                } else if let intValue = idValue.intValue {
                                    requestID = .number(intValue)
                                }
                            }
                            throw MCPError.parseError("Invalid message format")
                        }
                    } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                        // Resource temporarily unavailable, retry after a short delay
                        try? await Task.sleep(for: .milliseconds(10))
                        continue
                    } catch {
                        await logger?.error(
                            "Error processing message", metadata: ["error": "\(error)"])
                        let response = AnyMethod.response(
                            id: requestID ?? .random,
                            error: error as? MCPError
                                ?? MCPError.internalError(error.localizedDescription)
                        )
                        try? await send(response)
                    }
                }
            } catch {
                await logger?.error(
                    "Fatal error in message handling loop", metadata: ["error": "\(error)"])
            }
            await closeGeneration()
            await logger?.debug("Server finished", metadata: [:])
        }
    }

    /// Stop the server
    public func stop() async {
        let receiveTask = task
        receiveTask?.cancel()
        await closeGeneration()
        await receiveTask?.value
        task = nil
    }

    /// Close before the first suspension, so no handler can register late work.
    private func closeGeneration() async {
        isOpen = false
        generation &+= 1
        let transport = connection
        connection = nil
        for id in Array(pendingRequests.keys) {
            finishOutgoing(id, error: RequestLifecycleError.disconnected)
        }
        let sends = Array(outgoingSendTasks.values)
        let timers = Array(deadlineTasks.values)
        let incoming = Array(pendingRequestTasks.values)
        let batches = Array(batchTasks.values)
        let notification = cancellationNotificationTask
        sends.forEach { $0.cancel() }
        timers.forEach { $0.cancel() }
        incoming.forEach { $0.cancel() }
        batches.forEach { $0.cancel() }
        notification?.cancel()
        await transport?.disconnect()
        for work in sends { await work.value }
        for work in timers { await work.value }
        for work in incoming { _ = try? await work.value }
        for work in batches { await work.value }
        await notification?.value
    }

    public func waitUntilCompleted() async {
        await task?.value
    }

    // MARK: - Request Context

    /// Per-dispatch context the SDK attaches to the currently executing handler.
    ///
    /// Exposed via the ``Server/currentHandlerContext`` task-local so method
    /// handlers can observe the originating HTTP request (headers, auth, path,
    /// body) without changing the `withMethodHandler` signature.
    public struct HandlerContext: Sendable {
        /// The JSON-RPC request id of the in-flight request. SDK-internal use
        /// (e.g. transports closing an SSE stream mid-call per SEP-1699).
        package let id: ID

        /// The originating HTTP request, if the active transport conforms to
        /// ``HTTPContextProviding``. `nil` for transports that don't carry HTTP
        /// context (stdio, in-memory) or for handlers reached off the dispatch
        /// path.
        public let httpContext: HTTPRequest?

        package init(id: ID, httpContext: HTTPRequest?) {
            self.id = id
            self.httpContext = httpContext
        }
    }

    /// The handler context for the currently executing method handler.
    ///
    /// Set via `@TaskLocal` before dispatching each request, so it propagates
    /// automatically into the handler task. `nil` outside of a handler.
    ///
    /// When spawning `Task.detached { … }` from inside a handler, capture the
    /// value up front — detached tasks do not inherit task-locals:
    ///
    /// ```swift
    /// let ctx = Server.currentHandlerContext
    /// Task.detached { await doWork(with: ctx?.httpContext) }
    /// ```
    @TaskLocal public static var currentHandlerContext: HandlerContext? = nil

    // MARK: - Registration

    /// Register a method handler
    @discardableResult
    public func withMethodHandler<M: Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self {
        methodHandlers[M.name] = TypedRequestHandler { (request: Request<M>) -> Response<M> in
            let result = try await handler(request.params)
            return Response(id: request.id, result: result)
        }
        return self
    }

    /// Register a notification handler
    @discardableResult
    public func onNotification<N: Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) -> Self {
        let handlers = notificationHandlers[N.name, default: []]
        notificationHandlers[N.name] = handlers + [TypedNotificationHandler(handler)]
        return self
    }

    // MARK: - Sending

    /// Send a response to a request
    public func send<M: Method>(_ response: Response<M>) async throws {
        guard connection != nil else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let responseData = try encoder.encode(response)
        try await sendResponseData(responseData)
    }

    /// A response belongs to its incoming task until delivery finishes. A full
    /// output pipe must not retain one new handler forever for every new request.
    private func sendResponseData(_ data: Data) async throws {
        try Task.checkCancellation()
        guard isOpen, let connection else { throw RequestLifecycleError.disconnected }
        guard responseSendTasks < maximumIncomingRequests else {
            invalidateForTransportFailure()
            throw RequestLifecycleError.disconnected
        }
        responseSendTasks += 1
        defer { responseSendTasks -= 1 }
        let timeout = responseSendTimeout
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await connection.send(data) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    // Close admission before canceling/draining the stalled send.
                    await self.invalidateForTransportFailure()
                    throw RequestLifecycleError.disconnected
                }
                do {
                    _ = try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } catch {
            // Task cancellation before any response bytes is an ordinary canceled
            // request. An actual transport failure or send deadline closes the stream.
            if !(error is CancellationError) { invalidateForTransportFailure() }
            throw error
        }
    }

    /// Do not await closeGeneration here: the caller can itself be an incoming task
    /// that shutdown must drain. Canceling the receive loop runs that shutdown from
    /// its owner, without a task awaiting its own completion.
    private func invalidateForTransportFailure() {
        guard isOpen else { return }
        isOpen = false
        generation &+= 1
        task?.cancel()
    }

    /// Send a notification to connected clients
    public func notify<N: Notification>(_ notification: Message<N>) async throws {
        guard let connection = connection else {
            throw MCPError.internalError("Server connection not initialized")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let notificationData = try encoder.encode(notification)
        try await connection.send(notificationData)
    }

    /// Registration is actor-atomic and precedes the send task becoming runnable.
    /// Transport sends must cooperate with task cancellation; see the local patch README.
    private func sendAndAwait<M: Method>(
        _ request: Request<M>, timeout: Duration? = nil
    ) async throws -> M.Result {
        try Task.checkCancellation()
        guard isOpen, let connection else { throw RequestLifecycleError.disconnected }
        let currentGeneration = generation
        let cancellation = CancellationFlag()
        let deadline = timeout.map { lifecycleNow().advanced(by: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let requestData = try encoder.encode(request)
        do {
            let result: M.Result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled, !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    guard isOpen, generation == currentGeneration else {
                        continuation.resume(throwing: RequestLifecycleError.disconnected); return
                    }
                    guard deadline.map({ lifecycleNow() < $0 }) ?? true else {
                        continuation.resume(throwing: RequestLifecycleError.timedOut); return
                    }
                    pendingRequests[request.id] = OutgoingRequest(
                        continuation: AnyPendingRequest(PendingRequest(continuation: continuation)),
                        deadline: deadline, cancellation: cancellation, generation: currentGeneration)
                    outgoingSendTasks[request.id] = Task {
                        defer { outgoingSendTasks.removeValue(forKey: request.id) }
                        do {
                            try Task.checkCancellation()
                            guard !cancellation.isCancelled else { throw CancellationError() }
                            guard isOpen, generation == currentGeneration,
                                  pendingRequests[request.id] != nil else {
                                throw RequestLifecycleError.disconnected
                            }
                            try await connection.send(requestData)
                        } catch {
                            finishOutgoing(request.id, error: error)
                        }
                    }
                    if let deadline {
                        deadlineTasks[request.id] = Task {
                            defer { deadlineTasks.removeValue(forKey: request.id) }
                            do { try await ContinuousClock().sleep(until: deadline) }
                            catch { return }
                            finishOutgoing(request.id, error: RequestLifecycleError.timedOut,
                                           notifyCancellation: true)
                        }
                    }
                }
            } onCancel: {
                cancellation.cancel()
                Task { await self.cancelOutgoing(request.id) }
            }
            await drainOutgoingWork(request.id)
            try Task.checkCancellation()
            return result
        } catch {
            await drainOutgoingWork(request.id)
            throw error
        }
    }

    private func drainOutgoingWork(_ id: ID) async {
        let send = outgoingSendTasks[id]
        let timer = deadlineTasks[id]
        await send?.value
        await timer?.value
    }

    private func cancelOutgoing(_ id: ID) {
        finishOutgoing(id, error: CancellationError(), notifyCancellation: true)
    }

    /// The sole outgoing terminal transition. Late/duplicate messages see no entry.
    private func finishOutgoing(
        _ id: ID, value: Value? = nil, error: Swift.Error? = nil,
        notifyCancellation: Bool = false
    ) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        outgoingSendTasks[id]?.cancel()
        deadlineTasks[id]?.cancel()
        var terminalError = error
        if !isOpen || pending.generation != generation {
            terminalError = RequestLifecycleError.disconnected
        } else if pending.cancellation.isCancelled {
            terminalError = CancellationError()
        } else if let deadline = pending.deadline, lifecycleNow() >= deadline {
            terminalError = RequestLifecycleError.timedOut
        }
        if let terminalError { pending.continuation.resume(throwing: terminalError) }
        else if let value { pending.continuation.resume(returning: value) }
        else { pending.continuation.resume(throwing: MCPError.internalError("Missing response")) }
        if notifyCancellation || terminalError is CancellationError ||
            (terminalError as? RequestLifecycleError) == .timedOut {
            sendCancellationBestEffort(id)
        }
    }

    /// At most one bounded notification operation per connection. Drop additional
    /// notices while this slot is occupied; local cancellation never waits on it.
    private func sendCancellationBestEffort(_ id: ID, reason: String? = nil) {
        guard isOpen, cancellationNotificationTask == nil, let connection else { return }
        let notification = CancelledNotification.message(.init(requestId: id, reason: reason))
        guard let data = try? JSONEncoder().encode(notification) else { return }
        cancellationNotificationTask = Task {
            defer { cancellationNotificationTask = nil }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await connection.send(data) }
                group.addTask { try? await Task.sleep(for: .milliseconds(100)) }
                _ = await group.next()
                group.cancelAll()
            }
        }
    }

    // MARK: - Sampling

    /// Request sampling from the connected client
    ///
    /// Sampling allows servers to request LLM completions through the client,
    /// enabling sophisticated agentic behaviors while maintaining human-in-the-loop control.
    ///
    /// The sampling flow follows these steps:
    /// 1. Server sends a `sampling/createMessage` request to the client
    /// 2. Client reviews the request and can modify it
    /// 3. Client samples from an LLM
    /// 4. Client reviews the completion
    /// 5. Client returns the result to the server
    ///
    /// - Parameters:
    ///   - messages: The conversation history to send to the LLM
    ///   - modelPreferences: Model selection preferences
    ///   - systemPrompt: Optional system prompt
    ///   - includeContext: What MCP context to include
    ///   - temperature: Controls randomness (0.0 to 1.0)
    ///   - maxTokens: Maximum tokens to generate
    ///   - stopSequences: Array of sequences that stop generation
    ///   - _meta: Optional request metadata
    /// - Returns: The sampling result containing the model used, stop reason, role, and content
    /// - Throws: MCPError if the request fails
    /// - SeeAlso: https://modelcontextprotocol.io/docs/concepts/sampling#how-sampling-works
    public func requestSampling(
        messages: [Sampling.Message],
        modelPreferences: Sampling.ModelPreferences? = nil,
        systemPrompt: String? = nil,
        includeContext: Sampling.ContextInclusion? = nil,
        temperature: Double? = nil,
        maxTokens: Int,
        stopSequences: [String]? = nil,
        _meta: Metadata? = nil
    ) async throws -> CreateSamplingMessage.Result {
        guard connection != nil else {
            throw MCPError.internalError("Server connection not initialized")
        }

        try validateClientCapability(\.sampling, "Sampling")

        let request = CreateSamplingMessage.request(
            .init(
                messages: messages,
                modelPreferences: modelPreferences,
                systemPrompt: systemPrompt,
                includeContext: includeContext,
                temperature: temperature,
                maxTokens: maxTokens,
                stopSequences: stopSequences,
                _meta: _meta
            )
        )

        let result = try await sendAndAwait(request)
        return result
    }

    // MARK: - Elicitation

    /// Request user input from the client using form-based elicitation
    ///
    /// Elicitation allows servers to request user input during operations.
    /// This is useful for collecting user feedback, confirmations, or data
    /// that the server needs but doesn't have.
    ///
    /// The flow:
    /// 1. Server requests elicitation with a message and optional schema
    /// 2. Client displays the request to the user
    /// 3. User provides input or declines
    /// 4. Client returns the result to the server
    ///
    /// - Parameters:
    ///   - message: The message to display to the user
    ///   - mode: The elicitation mode (form or url)
    ///   - requestedSchema: Optional JSON schema describing the expected response
    ///   - _meta: Optional request metadata
    /// - Returns: The elicitation result containing the action and optional content
    /// - Throws: MCPError if the request fails
    /// - SeeAlso: https://modelcontextprotocol.io/docs/concepts/elicitation
    public func requestElicitation(
        message: String,
        requestedSchema: Elicitation.RequestSchema,
        mode: Elicitation.Mode? = nil,
        _meta: Metadata? = nil,
        timeout: Duration? = nil
    ) async throws -> CreateElicitation.Result {
        guard connection != nil else {
            throw RequestLifecycleError.disconnected
        }

        try validateClientCapability(\.elicitation, "Elicitation")

        let request = CreateElicitation.request(
            .form(
                .init(
                    message: message,
                    mode: mode,
                    requestedSchema: requestedSchema,
                    _meta: _meta
                )
            )
        )

        let result = try await sendAndAwait(request, timeout: timeout)
        return result
    }

    /// Request user input from the client using URL-based elicitation
    ///
    /// URL-based elicitation directs the user to an external URL for authentication
    /// or data collection. This is useful for OAuth flows or other web-based input.
    ///
    /// - Parameters:
    ///   - message: The message to display to the user
    ///   - url: The URL to direct the user to
    ///   - elicitationId: Unique identifier for this elicitation
    ///   - _meta: Optional request metadata
    /// - Returns: The elicitation result containing the action and optional content
    /// - Throws: MCPError if the request fails
    /// - SeeAlso: https://modelcontextprotocol.io/docs/concepts/elicitation
    public func requestElicitation(
        message: String,
        url: String,
        elicitationId: String,
        _meta: Metadata? = nil,
        timeout: Duration? = nil
    ) async throws -> CreateElicitation.Result {
        guard connection != nil else {
            throw RequestLifecycleError.disconnected
        }

        try validateClientCapability(\.elicitation, "Elicitation")

        let request = CreateElicitation.request(
            .url(
                .init(
                    message: message,
                    url: url,
                    elicitationId: elicitationId,
                    _meta: _meta
                )
            )
        )

        let result = try await sendAndAwait(request, timeout: timeout)
        return result
    }

    // MARK: - Logging

    /// Send a log message notification to connected clients.
    ///
    /// Servers that declare the `logging` capability can send structured log messages
    /// to clients. The client controls which severity levels it wants to receive via
    /// the `logging/setLevel` request.
    ///
    /// - Parameters:
    ///   - level: The severity level of the log message
    ///   - logger: Optional logger name to identify the source
    ///   - data: Arbitrary JSON-serializable data for the log message
    /// - Throws: MCPError if the server is not connected
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
    public func log(
        level: LogLevel,
        logger: String? = nil,
        data: Value
    ) async throws {
        let notification = LogMessageNotification.message(
            .init(level: level, logger: logger, data: data)
        )
        try await notify(notification)
    }

    /// Send a log message notification with codable data.
    ///
    /// Convenience method that encodes data to JSON before sending.
    ///
    /// - Parameters:
    ///   - level: The severity level of the log message
    ///   - logger: Optional logger name to identify the source
    ///   - data: Any codable data for the log message
    /// - Throws: MCPError if the server is not connected or encoding fails
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/logging/
    public func log<T: Codable>(
        level: LogLevel,
        logger: String? = nil,
        data: T
    ) async throws {
        let value = try Value(data)
        try await log(level: level, logger: logger, data: value)
    }

    // MARK: - Roots

    /// Request the list of roots from the connected client
    ///
    /// Roots define filesystem boundaries that servers can operate within.
    /// The client must have declared the `roots` capability and registered
    /// a roots handler for this to work.
    ///
    /// - Returns: Array of Root objects representing accessible directories/files
    /// - Throws: MCPError if the client doesn't support roots or request fails
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/client/roots
    public func listRoots() async throws -> [Root] {
        guard connection != nil else {
            throw MCPError.internalError("Server connection not initialized")
        }

        try validateClientCapability(\.roots, "Roots")

        let request = ListRoots.request()
        let result = try await sendAndAwait(request)
        return result.roots
    }

    /// A JSON-RPC batch containing multiple requests and/or notifications
    struct Batch: Sendable {
        /// An item in a JSON-RPC batch
        enum Item: Sendable {
            case request(Request<AnyMethod>)
            case notification(Message<AnyNotification>)

        }

        var items: [Item]

        init(items: [Item]) {
            self.items = items
        }
    }

    /// Dispatch concurrently, so an overlap guard in an application handler observes
    /// overlapping batch calls too. Response collection leaves the receive loop free.
    private func handleBatch(_ batch: Batch) async throws {
        if batch.items.isEmpty {
            try await send(AnyMethod.response(id: .random,
                error: MCPError.invalidRequest("Batch array must not be empty")))
            return
        }
        guard isOpen else { return }
        guard pendingRequestTasks.count + batchReservations.count < maximumIncomingRequests else {
            invalidateForTransportFailure()
            return
        }
        let id = ID.random
        batchReservations.insert(id)
        var requests: [(id: ID, task: Task<Response<AnyMethod>?, Error>)] = []
        for item in batch.items {
            switch item {
            case .request(let request):
                if let work = startIncomingRequest(request, sendResponse: false) {
                    requests.append((request.id, work))
                }
            case .notification(let message): try? await handleMessage(message)
            }
        }
        guard isOpen else {
            // A notification handler may have suspended during disconnect.
            for request in requests {
                request.task.cancel()
                _ = try? await request.task.value
                releaseIncomingRequest(request.id)
            }
            batchReservations.remove(id)
            return
        }
        guard !requests.isEmpty else { batchReservations.remove(id); return }
        batchTasks[id] = Task {
            defer {
                for request in requests {
                    completedBatchResponseIDs.remove(request.id)
                    releaseIncomingRequest(request.id)
                }
                batchTasks.removeValue(forKey: id)
                batchReservations.remove(id)
            }
            var responses: [Response<AnyMethod>] = []
            for request in requests {
                do {
                    if let response = try await request.task.value {
                        responses.append(response)
                        completedBatchResponseIDs.insert(request.id)
                    }
                } catch is CancellationError {
                    // Canceled batch items have no response, including cancellations
                    // observed before the handler was dispatched.
                } catch {
                    responses.append(AnyMethod.response(id: request.id,
                        error: error as? MCPError ?? MCPError.internalError(error.localizedDescription)))
                }
            }
            guard !Task.isCancelled, isOpen else { return }
            // This is the response commitment point. No actor suspension occurs
            // between filtering canceled IDs and handing the encoded aggregate to
            // the transport. Already-written bytes cannot subsequently be retracted.
            responses.removeAll { incomingCancellationFlags[$0.id]?.isCancelled != false }
            guard !responses.isEmpty else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(responses) { try? await sendResponseData(data) }
        }
    }

    private func releaseIncomingRequest(_ id: ID) {
        pendingRequestTasks.removeValue(forKey: id)
        incomingCancellationFlags.removeValue(forKey: id)
    }

    private func startIncomingRequest(
        _ request: Request<AnyMethod>, sendResponse: Bool
    ) -> Task<Response<AnyMethod>?, Error>? {
        guard isOpen, pendingRequestTasks[request.id] == nil else { return nil }
        guard pendingRequestTasks.count + batchReservations.count < maximumIncomingRequests else {
            invalidateForTransportFailure()
            return nil
        }
        let currentGeneration = generation
        incomingCancellationFlags[request.id] = CancellationFlag()
        let work = Task<Response<AnyMethod>?, Error> {
            defer {
                // Batch slots belong to the aggregate response task until it commits.
                if sendResponse { releaseIncomingRequest(request.id) }
            }
            try Task.checkCancellation()
            guard isOpen, generation == currentGeneration else { throw CancellationError() }
            return try await handleRequest(request, sendResponse: sendResponse)
        }
        pendingRequestTasks[request.id] = work
        return work
    }

    // MARK: - Request and Message Handling

    /// Handle a request and either send the response immediately or return it
    ///
    /// - Parameters:
    ///   - request: The request to handle
    ///   - sendResponse: Whether to send the response immediately (true) or return it (false)
    /// - Returns: The response when sendResponse is false
    private func handleRequest(_ request: Request<AnyMethod>, sendResponse: Bool = true)
        async throws -> Response<AnyMethod>?
    {
        // Check if this is a pre-processed error request (empty method)
        if request.method.isEmpty && !sendResponse {
            // This is a placeholder for an invalid request that couldn't be parsed in batch mode
            return AnyMethod.response(
                id: request.id,
                error: MCPError.invalidRequest("Invalid batch item format")
            )
        }

        await logger?.trace(
            "Processing request",
            metadata: [
                "method": "\(request.method)",
                "id": "\(request.id)",
            ])

        try Task.checkCancellation()
        guard isOpen else { throw CancellationError() }
        if configuration.strict {
            // The client SHOULD NOT send requests other than pings
            // before the server has responded to the initialize request.
            switch request.method {
            case Initialize.name, Ping.name:
                break
            default:
                try checkInitialized()
            }
        }

        // Find handler for method name
        guard let handler = methodHandlers[request.method] else {
            let error = MCPError.methodNotFound("Unknown method: \(request.method)")
            let response = AnyMethod.response(id: request.id, error: error)

            if sendResponse {
                try await send(response)
                return nil
            }

            return response
        }

        // Ask the transport for the originating HTTP request so handlers can observe
        // headers/auth via `Server.currentHandlerContext?.httpContext`. Transports
        // that don't carry HTTP context (stdio, in-memory) don't conform.
        let httpContext = await (connection as? any HTTPContextProviding)?
            .httpRequestContext(for: request.id)
        let handlerContext = HandlerContext(id: request.id, httpContext: httpContext)

        do {
            try Task.checkCancellation()
            guard isOpen else { throw CancellationError() }
            let response = try await Server.$currentHandlerContext.withValue(handlerContext) {
                try await handler(request)
            }
            // A handler may catch cancellation itself. Never emit its result afterwards.
            try Task.checkCancellation()
            guard isOpen else { throw CancellationError() }
            if sendResponse { try await send(response); return nil }
            return response
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled, isOpen else { return nil }
            let mcpError = error as? MCPError ?? MCPError.internalError(error.localizedDescription)
            let response = AnyMethod.response(id: request.id, error: mcpError)
            if sendResponse { try await send(response); return nil }
            return response
        }
    }

    private func handleMessage(_ message: Message<AnyNotification>) async throws {
        // Observe wire cancellation before logging or any other suspension. The
        // request slot already exists even if its handler has not started yet.
        if message.method == CancelledNotification.name,
           let data = try? JSONEncoder().encode(message),
           let cancellation = try? JSONDecoder().decode(Message<CancelledNotification>.self, from: data),
           let id = cancellation.params.requestId {
            incomingCancellationFlags[id]?.cancel()
            pendingRequestTasks[id]?.cancel()
        }
        await logger?.trace(
            "Processing notification",
            metadata: ["method": "\(message.method)"])

        if configuration.strict {
            // Check initialization state unless this is an initialized notification
            if message.method != InitializedNotification.name {
                try checkInitialized()
            }
        }

        // Find notification handlers for this method
        guard let handlers = notificationHandlers[message.method] else { return }

        // Convert notification parameters to concrete type and call handlers
        for handler in handlers {
            do {
                try await handler(message)
            } catch {
                await logger?.error(
                    "Error handling notification",
                    metadata: [
                        "method": "\(message.method)",
                        "error": "\(error)",
                    ])
            }
        }
    }

    private func handleResponse(_ response: Response<AnyMethod>) async {
        switch response.result {
        case .success(let value): finishOutgoing(response.id, value: value)
        case .failure(let error): finishOutgoing(response.id, error: error)
        }
    }

    private func checkInitialized() throws {
        guard isInitialized else {
            throw MCPError.invalidRequest("Server is not initialized")
        }
    }

    /// Validate the client capabilities.
    /// Throws an error if the server is configured to be strict and the capability is not supported.
    private func validateClientCapability<T>(
        _ keyPath: KeyPath<Client.Capabilities, T?>,
        _ name: String
    )
        throws
    {
        if configuration.strict {
            guard let capabilities = clientCapabilities else {
                throw MCPError.methodNotFound("Client capabilities not initialized")
            }
            guard capabilities[keyPath: keyPath] != nil else {
                throw MCPError.methodNotFound("\(name) is not supported by the client")
            }
        }
    }

    private func registerDefaultHandlers(
        initializeHook: (@Sendable (Client.Info, Client.Capabilities) async throws -> Void)?
    ) {
        // Initialize
        withMethodHandler(Initialize.self) { [weak self] params in
            guard let self = self else {
                throw MCPError.internalError("Server was deallocated")
            }

            guard await !self.isInitialized else {
                throw MCPError.invalidRequest("Server is already initialized")
            }

            // Call initialization hook if registered
            if let hook = initializeHook {
                try await hook(params.clientInfo, params.capabilities)
            }

            // Perform version negotiation
            let clientRequestedVersion = params.protocolVersion
            let negotiatedProtocolVersion = Version.negotiate(
                clientRequestedVersion: clientRequestedVersion)

            // Set initial state with the negotiated protocol version
            await self.setInitialState(
                clientInfo: params.clientInfo,
                clientCapabilities: params.capabilities,
                protocolVersion: negotiatedProtocolVersion
            )

            return Initialize.Result(
                protocolVersion: negotiatedProtocolVersion,
                capabilities: await self.capabilities,
                serverInfo: self.serverInfo,
                instructions: self.instructions
            )
        }

        // Ping
        withMethodHandler(Ping.self) { _ in return Empty() }
    }

    private func setInitialState(
        clientInfo: Client.Info,
        clientCapabilities: Client.Capabilities,
        protocolVersion: String
    ) async {
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        self.protocolVersion = protocolVersion
        self.isInitialized = true
    }

    /// Cancel and remove a pending request task
    private func removePendingRequest(id: ID) -> Task<Response<AnyMethod>?, Error>? {
        // Retain until task completion so disconnect can drain canceled handlers.
        pendingRequestTasks[id]
    }

    private func registerCancellationHandler() {
        onNotification(CancelledNotification.self) { [weak self] message in
            guard let self = self else { return }

            let requestId = message.params.requestId
            let reason = message.params.reason

            await self.logger?.debug(
                "Received cancellation notification",
                metadata: [
                    "requestId": requestId.map { "\($0)" } ?? "none",
                    "reason": reason.map { "\($0)" } ?? "none",
                ]
            )

            guard let requestId = requestId else {
                await self.logger?.warning(
                    "Received cancellation notification with no requestId (violates spec MUST)",
                    metadata: ["reason": reason.map { "\($0)" } ?? "none"]
                )
                return
            }

            // Cancel the pending request task if it exists and remove from tracking
            if let task = await self.removePendingRequest(id: requestId) {
                task.cancel()
                await self.logger?.debug(
                    "Cancelled request",
                    metadata: ["requestId": "\(requestId)"]
                )
            } else {
                // Request may have already completed or is unknown
                // Per MCP spec, we should ignore this gracefully
                await self.logger?.trace(
                    "Cancellation notification for unknown or completed request",
                    metadata: ["requestId": "\(requestId)"]
                )
            }
        }
    }

    /// Cancel a request by sending a CancelledNotification to the client.
    ///
    /// This is used when the server needs to cancel an in-progress request it made to the client
    /// (e.g., a sampling request).
    ///
    /// According to the MCP specification, cancellation is advisory:
    /// - The client SHOULD stop processing and free resources
    /// - The client MAY ignore the cancellation if the request is unknown, already completed,
    ///   or cannot be cancelled
    /// - The server SHOULD ignore any response that arrives after cancellation
    ///
    /// - Parameters:
    ///   - requestID: The ID of the request to cancel
    ///   - reason: An optional human-readable reason for the cancellation
    /// - Throws: MCPError if the notification cannot be sent
    /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation
    public func cancelRequest(_ requestID: ID, reason: String? = nil) async throws {
        finishOutgoing(requestID, error: CancellationError())
        sendCancellationBestEffort(requestID, reason: reason)
    }
}

extension Server.Batch: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        var items: [Item] = []
        for item in try container.decode([Value].self) {
            let data = try encoder.encode(item)
            try items.append(decoder.decode(Item.self, from: data))
        }

        self.items = items
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(items)
    }
}

extension Server.Batch.Item: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Check if it's a request (has id) or notification (no id)
        if container.contains(.id) {
            self = .request(try Request<AnyMethod>(from: decoder))
        } else {
            self = .notification(try Message<AnyNotification>(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .request(let request):
            try request.encode(to: encoder)
        case .notification(let notification):
            try notification.encode(to: encoder)
        }
    }
}
