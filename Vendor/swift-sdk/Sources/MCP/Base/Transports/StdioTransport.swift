import Logging

import struct Foundation.Data

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

// Import for specific low-level operations not yet in Swift System
#if canImport(Darwin)
    import Darwin.POSIX
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    /// An implementation of the MCP stdio transport protocol.
    ///
    /// This transport implements the [stdio transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#stdio)
    /// specification from the Model Context Protocol.
    ///
    /// The stdio transport works by:
    /// - Reading JSON-RPC messages from standard input
    /// - Writing JSON-RPC messages to standard output
    /// - Using newline characters as message delimiters
    /// - Supporting non-blocking I/O operations
    ///
    /// This transport is the recommended option for most MCP applications due to its
    /// simplicity and broad platform support.
    ///
    /// - Important: This transport is available on Apple platforms and Linux distributions with glibc
    ///   (Ubuntu, Debian, Fedora, CentOS, RHEL).
    ///
    /// ## Example Usage
    ///
    /// ```swift
    /// import MCP
    ///
    /// // Initialize the client
    /// let client = Client(name: "MyApp", version: "1.0.0")
    ///
    /// // Create a transport and connect
    /// let transport = StdioTransport()
    /// try await client.connect(transport: transport)
    /// ```
    public actor StdioTransport: Transport {
        private let input: FileDescriptor
        private let output: FileDescriptor
        /// Logger instance for transport-related events
        public nonisolated let logger: Logger

        private var isConnected = false
        private var isSending = false
        // Internal observation for synthetic full-pipe cancellation tests.
        var _isSendingForTesting: Bool { isSending }
        private var readTask: Task<Void, Never>?
        private let messageStream: AsyncThrowingStream<Data, Swift.Error>
        private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

        /// Creates a new stdio transport with the specified file descriptors
        ///
        /// - Parameters:
        ///   - input: File descriptor for reading (defaults to standard input)
        ///   - output: File descriptor for writing (defaults to standard output)
        ///   - logger: Optional logger instance for transport events
        public init(
            input: FileDescriptor = FileDescriptor.standardInput,
            output: FileDescriptor = FileDescriptor.standardOutput,
            logger: Logger? = nil
        ) {
            self.input = input
            self.output = output
            self.logger =
                logger
                ?? Logger(
                    label: "mcp.transport.stdio",
                    factory: { _ in SwiftLogNoOpLogHandler() })

            // Create message stream
            var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
            self.messageStream = AsyncThrowingStream { continuation = $0 }
            self.messageContinuation = continuation
        }

        /// Establishes connection with the transport
        ///
        /// This method configures the file descriptors for non-blocking I/O
        /// and starts the background message reading loop.
        ///
        /// - Throws: Error if the file descriptors cannot be configured
        public func connect() async throws {
            guard !isConnected else { return }

            // Set non-blocking mode
            try setNonBlocking(fileDescriptor: input)
            try setNonBlocking(fileDescriptor: output)

            isConnected = true
            logger.debug("Transport connected successfully")

            // Start reading loop in background
            readTask = Task { await readLoop() }
        }

        /// Configures a file descriptor for non-blocking I/O
        ///
        /// - Parameter fileDescriptor: The file descriptor to configure
        /// - Throws: Error if the operation fails
        private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                // Get current flags
                let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
                guard flags >= 0 else {
                    throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                }

                // Set non-blocking flag
                let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
                guard result >= 0 else {
                    throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                }
            #else
                // For platforms where non-blocking operations aren't supported
                throw MCPError.internalError(
                    "Setting non-blocking mode not supported on this platform")
            #endif
        }

        /// Continuous loop that reads and processes incoming messages
        ///
        /// This method runs in the background while the transport is connected,
        /// parsing complete messages delimited by newlines and yielding them
        /// to the message stream.
        private func readLoop() async {
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            var pendingData = Data()

            while isConnected && !Task.isCancelled {
                do {
                    let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                        try input.read(into: UnsafeMutableRawBufferPointer(pointer))
                    }

                    if bytesRead == 0 {
                        logger.notice("EOF received")
                        break
                    }

                    pendingData.append(Data(buffer[..<bytesRead]))

                    // Process complete messages
                    while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                        let messageData = pendingData[..<newlineIndex]
                        pendingData = pendingData[(newlineIndex + 1)...]

                        if !messageData.isEmpty {
                            logger.trace(
                                "Message received", metadata: ["size": "\(messageData.count)"])
                            messageContinuation.yield(Data(messageData))
                        }
                    }
                } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                } catch {
                    if !Task.isCancelled {
                        logger.error("Read error occurred", metadata: ["error": "\(error)"])
                    }
                    break
                }
            }

            messageContinuation.finish()
        }

        /// Disconnects from the transport
        ///
        /// This stops the message reading loop and releases associated resources.
        public func disconnect() async {
            // Also drain the reader after a partial-write failure already marked
            // the connection closed.
            isConnected = false
            messageContinuation.finish()
            let reader = readTask
            readTask = nil
            reader?.cancel()
            await reader?.value
            logger.debug("Transport disconnected")
        }

        /// Sends a message over the transport.
        ///
        /// This method supports sending both individual JSON-RPC messages and JSON-RPC batches.
        /// Batches should be encoded as a JSON array containing multiple request/notification objects
        /// according to the JSON-RPC 2.0 specification.
        ///
        /// - Parameter message: The message data to send (without a trailing newline)
        /// - Throws: Error if the message cannot be sent
        public func send(_ message: Data) async throws {
            // Actor reentrancy while waiting for writable output must not interleave
            // two JSON frames. Waiting callers remain cancellation-cooperative.
            while isSending {
                try Task.checkCancellation()
                guard isConnected else {
                    throw MCPError.transportError(Errno(rawValue: ENOTCONN))
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            guard isConnected else {
                throw MCPError.transportError(Errno(rawValue: ENOTCONN))
            }
            isSending = true
            defer { isSending = false }
            var frame = message
            frame.append(UInt8(ascii: "\n"))
            var remaining = frame
            do {
                while !remaining.isEmpty {
                    try Task.checkCancellation()
                    guard isConnected else {
                        throw MCPError.transportError(Errno(rawValue: ENOTCONN))
                    }
                    do {
                        let written = try remaining.withUnsafeBytes {
                            try output.write(UnsafeRawBufferPointer($0))
                        }
                        if written > 0 { remaining = remaining.dropFirst(written) }
                        else { try await Task.sleep(for: .milliseconds(10)) }
                    } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            } catch {
                // A partial line cannot be abandoned and followed by another JSON
                // message. Close this stream instead of corrupting its framing.
                // Cancellation before any byte was written leaves it healthy.
                if remaining.count != frame.count {
                    isConnected = false
                    messageContinuation.finish(throwing: error)
                    readTask?.cancel()
                }
                throw error
            }
        }

        /// Receives messages from the transport.
        ///
        /// Messages may be individual JSON-RPC requests, notifications, responses,
        /// or batches containing multiple requests/notifications encoded as JSON arrays.
        /// Each message is guaranteed to be a complete JSON object or array.
        ///
        /// - Returns: An AsyncThrowingStream of Data objects representing JSON-RPC messages
        public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
            return messageStream
        }
    }
#endif
