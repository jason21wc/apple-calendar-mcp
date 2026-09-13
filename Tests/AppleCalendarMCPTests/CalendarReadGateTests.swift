import Testing
import Foundation
import MCP
@testable import apple_calendar_mcp

/// A controllable external operation that deliberately ignores caller cancellation.
private actor HeldRead {
    private var continuation: CheckedContinuation<Int, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false

    func run() async -> Int {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            for waiter in startedWaiters { waiter.resume() }
            startedWaiters = []
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func release() { continuation?.resume(returning: 42); continuation = nil }
}

/// Observes actual timer cancellation without assuming how quickly tasks are scheduled.
private actor TimerCancellationObserver {
    private var completions: [Bool] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Bool, Never>)] = []

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        do {
            try await ContinuousClock().sleep(until: deadline)
        } catch is CancellationError {
            recordCompletion(canceled: true)
            throw CancellationError()
        } catch {
            recordCompletion(canceled: false)
            throw error
        }
        // A missing cancellation must fail the assertion after the generous deadline,
        // rather than leave the test waiting on a continuation forever.
        recordCompletion(canceled: false)
    }

    private func recordCompletion(canceled: Bool) {
        completions.append(canceled)
        let ready = waiters.filter { $0.count <= completions.count }
        waiters.removeAll { $0.count <= completions.count }
        for waiter in ready {
            waiter.continuation.resume(returning: completions[waiter.count - 1])
        }
    }

    func wasCanceled(_ count: Int) async -> Bool {
        if completions.count >= count { return completions[count - 1] }
        return await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

@Suite("Bounded Calendar reads", .timeLimit(.minutes(1)))
struct CalendarReadGateTests {
    @Test("ordinary failures release admission without arming a later false timeout")
    func failureReleasesSlot() async throws {
        let timer = TimerCancellationObserver()
        let gate = CalendarReadGate(timeout: .seconds(5), sleepUntil: {
            try await timer.sleep(until: $0)
        })
        await #expect(throws: CalendarReadError.busy) {
            try await gate.run { () -> Int in throw CalendarReadError.busy }
        }
        #expect(await timer.wasCanceled(1))
        #expect(try await gate.run { 7 } == 7)
        #expect(await timer.wasCanceled(2))
    }

    @Test("overdue completion fails even when delivery of the deadline timer is delayed")
    func delayedTimer() async {
        let gate = CalendarReadGate(timeout: .milliseconds(30), sleepUntil: { _ in
            try await Task.sleep(for: .seconds(10))
        })
        await #expect(throws: CalendarReadError.timedOut) {
            try await gate.run { try await Task.sleep(for: .milliseconds(60)); return 9 }
        }
        await #expect(throws: CalendarReadError.wedged) { try await gate.run { 0 } }
    }

    @Test("synchronously blocked adapter work does not block deadlines or diagnostics")
    func blockingAdapter() async throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let adapter = BlockingRead(started: started, release: release)
        // Lazy: no EventKit content operation is invoked, even through the real handler.
        let store = CalendarStore(readGate: CalendarReadGate(timeout: .milliseconds(100)))
        let began = ContinuousClock.now
        let first = Task {
            try await store.readGate.run { await adapter.run() }
        }
        defer { release.signal() }
        let didStart = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: started.wait(timeout: .now() + 2) == .success)
            }
        }
        try #require(didStart)
        let status = try await ToolHandlers.dispatch(.init(name: "calendar_permission_status"), store: store)
        #expect(status.isError != true)
        #expect(ToolRegistry.all().contains { $0.name == "calendar_list_events" })
        await #expect(throws: CalendarReadError.timedOut) { try await first.value }
        #expect(began.duration(to: .now) < .seconds(2),
                "the deadline must return before the fake's five-second emergency release")
        await #expect(throws: CalendarReadError.wedged) { try await store.readGate.run { 0 } }
        let afterTimeout = try await ToolHandlers.dispatch(
            .init(name: "calendar_permission_status"), store: store)
        #expect(afterTimeout.isError != true)
    }

    @Test("completed operations release admission and canceled timers never wedge")
    func success() async throws {
        let timer = TimerCancellationObserver()
        let gate = CalendarReadGate(timeout: .seconds(5), sleepUntil: {
            try await timer.sleep(until: $0)
        })
        #expect(try await gate.run { 1 } == 1)
        #expect(await timer.wasCanceled(1))
        #expect(try await gate.run { 2 } == 2)
        #expect(await timer.wasCanceled(2))
    }

    @Test("overlap fails immediately instead of submitting a second adapter operation")
    func overlappingRead() async throws {
        let gate = CalendarReadGate(timeout: .seconds(5)), held = HeldRead()
        let first = Task { try await gate.run { await held.run() } }
        await held.waitUntilStarted()
        await #expect(throws: CalendarReadError.busy) {
            try await gate.run { Issue.record("overlapping work was submitted"); return 0 }
        }
        await held.release()
        #expect(try await first.value == 42)
    }

    @Test("timeout returns without external completion and late success never reopens admission")
    func timeout() async throws {
        let gate = CalendarReadGate(timeout: .milliseconds(80)), held = HeldRead()
        let first = Task { try await gate.run { await held.run() } }
        await held.waitUntilStarted()
        await #expect(throws: CalendarReadError.timedOut) { try await first.value }
        await #expect(throws: CalendarReadError.wedged) { try await gate.run { 1 } }
        await held.release()
        try await Task.sleep(for: .milliseconds(30))
        await #expect(throws: CalendarReadError.wedged) { try await gate.run { 2 } }
    }

    @Test("canceling an active caller does not free the adapter slot")
    func cancellation() async throws {
        let gate = CalendarReadGate(timeout: .seconds(5)), held = HeldRead()
        let first = Task { try await gate.run { await held.run() } }
        await held.waitUntilStarted()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CalendarReadError.busy) { try await gate.run { 0 } }
        await held.release()
        // Allow the worker to deliver completion; don't conflate task scheduling with failure.
        for _ in 0..<100 {
            do { #expect(try await gate.run { 3 } == 3); return }
            catch CalendarReadError.busy { try await Task.sleep(for: .milliseconds(5)) }
        }
        Issue.record("completed external operation never released the slot")
    }

    @Test("canceling a caller does not cancel the operation deadline")
    func canceledOperationStillWedges() async throws {
        let gate = CalendarReadGate(timeout: .milliseconds(80)), held = HeldRead()
        let first = Task { try await gate.run { await held.run() } }
        await held.waitUntilStarted()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await Task.sleep(for: .milliseconds(120))
        await #expect(throws: CalendarReadError.wedged) { try await gate.run { 0 } }
        await held.release()
    }

    @Test("already canceled requests never invoke the adapter")
    func canceledBeforeAdmission() async {
        let gate = CalendarReadGate()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await gate.run { Issue.record("canceled work was admitted"); return 0 }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("read failures use stable text errors without a success-schema payload")
    func wireErrors() {
        for (error, code) in [(CalendarReadError.busy, "CALENDAR_STORE_BUSY"),
                              (.timedOut, "CALENDAR_TIMEOUT"), (.wedged, "CALENDAR_STORE_WEDGED")] {
            let result = ToolHandlers.readFailure(error)
            #expect(result.isError == true)
            #expect(result.structuredContent == nil)
            guard case .text(let text, _, _) = result.content.first else {
                Issue.record("missing error text"); continue
            }
            #expect(text.hasPrefix(code + ":"))
        }
    }
}

private actor BlockingRead {
    private let executor = SerialQueueExecutor(label: "test.blocked-calendar")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    let started: DispatchSemaphore
    let release: DispatchSemaphore
    init(started: DispatchSemaphore, release: DispatchSemaphore) {
        self.started = started; self.release = release
    }
    func run() -> Int {
        started.signal()
        _ = release.wait(timeout: .now() + 5)
        return 1
    }
}
