import Foundation

enum CalendarReadError: Error, Equatable {
    case busy, timedOut, wedged
}

/// Bounds READ callers, not EventKit execution. Never use this for mutations or
/// elicitation: abandoning either has different outcome and cleanup semantics.
///
/// One adapter call may be in flight. Overlap is rejected instead of building a queue
/// behind a noncancellable operation. This actor never executes synchronous EventKit
/// work; the adapter runs on its own executor. A task group would wait for its stuck
/// child at scope exit, defeating the deadline, so the worker is unstructured.
actor CalendarReadGate {
    private struct Active {
        let id: UUID
        let deadline: ContinuousClock.Instant
        let fail: @Sendable (any Error) -> Void
        let timer: Task<Void, Never>
        var callerCompleted = false
    }

    private let timeout: Duration
    private let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void
    private let clock = ContinuousClock()
    private var active: Active?
    private var wedged = false

    init(timeout: Duration = .seconds(15),
         sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
             try await ContinuousClock().sleep(until: $0)
         }) {
        precondition(timeout > .zero)
        self.timeout = timeout
        self.sleepUntil = sleepUntil
    }

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !wedged else { throw CalendarReadError.wedged }
        guard active == nil else { throw CalendarReadError.busy }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let deadline = clock.now.advanced(by: timeout)
                let timer = Task {
                    do { try await sleepUntil(deadline) }
                    catch { return } // A canceled timer must not wedge a healthy store.
                    expire(id)
                }
                active = Active(id: id, deadline: deadline,
                                fail: { continuation.resume(throwing: $0) }, timer: timer)
                Task {
                    let result: Result<T, any Error>
                    do { result = .success(try await operation()) }
                    catch { result = .failure(error) }
                    // Also check the clock here: a delayed timer cannot admit overdue success.
                    if complete(id) { continuation.resume(with: result) }
                }
            }
        } onCancel: {
            Task { await self.cancelCaller(id) }
        }
    }

    private func complete(_ id: UUID) -> Bool {
        guard let current = active, current.id == id else { return false }
        if clock.now >= current.deadline {
            expire(id)
            return false
        }
        active = nil
        current.timer.cancel()
        return !current.callerCompleted
    }

    private func expire(_ id: UUID) {
        guard let current = active, current.id == id else { return }
        wedged = true
        active = nil
        current.timer.cancel()
        if !current.callerCompleted { current.fail(CalendarReadError.timedOut) }
        // The worker may still be running. Its eventual result can never reopen this gate.
    }

    private func cancelCaller(_ id: UUID) {
        guard var current = active, current.id == id, !current.callerCompleted else { return }
        current.callerCompleted = true
        active = current
        current.fail(CancellationError())
        // Keep the slot and timer until the underlying operation finishes or times out.
    }
}
