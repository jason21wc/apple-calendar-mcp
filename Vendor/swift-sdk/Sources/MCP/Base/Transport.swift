import Logging

import struct Foundation.Data

/// Protocol defining the transport layer for MCP communication
public protocol Transport: Actor {
    var logger: Logger { get }

    /// Establishes connection with the transport
    func connect() async throws

    /// Disconnects from the transport
    func disconnect() async

    /// Sends data.
    /// Bounded server request lifecycles require this operation to promptly observe
    /// task cancellation, including while waiting on I/O. Implementations must not
    /// leave a partial protocol frame that a subsequent send could corrupt.
    /// Disconnect must terminate outstanding I/O. Arbitrary uncooperative transports
    /// cannot be forcibly canceled by Swift tasks.
    func send(_ data: Data) async throws

    /// Receives data in an async sequence
    func receive() -> AsyncThrowingStream<Data, Swift.Error>
}
