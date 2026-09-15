# Local Swift MCP SDK lifecycle patch

Upstream: https://github.com/modelcontextprotocol/swift-sdk
Version: 0.12.1
Revision: a0ae212ebf6eab5f754c3129608bc5557637e605
License: MIT, retained verbatim in `LICENSE`.

This directory vendors upstream `Sources/MCP` without changing its public protocol
models. Its minimal manifest retains the MCP library, platform minimums and upstream
swift-system, swift-log and eventsource dependency constraints; documentation,
conformance executables and their unrelated dependencies are omitted. The root
`Package.resolved` pins the remaining dependencies.

## Local changes

`Sources/MCP/Server/Server.swift`:

- Both `requestElicitation` overloads add a trailing `timeout: Duration? = nil`.
  A monotonic deadline includes send and response wait. The request layer is also
  shared by sampling and roots requests, which retain their no-deadline defaults.
- Outgoing registration and continuation ownership are actor-atomic before sending.
  One terminal transition removes the entry, cancels tracked send/timer work and
  resumes exactly once for response, error, cancellation, expiry or disconnect.
  Responses check the deadline again. A locked caller-cancellation flag makes
  cancellation visible before the asynchronous actor cleanup hop.
- Incoming request tasks are registered before dispatch. Wire cancellation cancels
  the registered task before any logging suspension and propagates through direct
  handler awaits into nested outgoing requests. Canceled handlers cannot emit success.
  Batch request handlers run concurrently, so application overlap guards also cover
  batch calls. Completed batch handlers retain their cancellation slots until the
  aggregate is committed; canceled IDs are filtered immediately before transport
  handoff. Response collection runs outside the receive loop so nested outgoing
  responses and cancellation can be received. Cancellation cannot retract bytes
  already handed to the transport. The elicitation deadline governs the client's
  answer, not the later delivery of its enclosing application's batch result.
- Explicit stop and receive EOF/error close the generation before draining outgoing,
  incoming and batch work. A started server cannot be restarted; create a new instance.
- Incoming work has a 16-slot connection limit, counting individual handlers and
  reserved batch collectors. Exceeding it closes the connection, rather than silently
  dropping a JSON-RPC request or retaining an unbounded queue. Responses have a
  separate 5-second send budget, including waiting for writable output. A response
  send deadline or transport failure closes admission and cancels the receive loop;
  that owner then disconnects and drains the tasks. This avoids shutdown awaiting
  the same handler that initiated it. Response sends use structured child tasks and
  an additional send-count cap, so a stalled output cannot accumulate timer work.
  These limits are local stdio policy and require review for other deployments.
- Cancellation notices use one occupied slot and a 100 ms cooperative send budget.
  Extra notices are dropped while the slot is occupied. Local completion does not
  wait for that notice. `cancelRequest` now settles its local request and schedules
  this bounded best-effort notice; delivery errors are not surfaced by that API.
- Errors are `Server.RequestLifecycleError.timedOut`, `.disconnected`, and Swift
  `CancellationError`; other send/decode errors retain their existing types.
- `requestLifecycleDiagnostics()` exposes only counts: pendingOutgoingRequests,
  outgoingSendTasks, deadlineTasks, incomingRequestTasks, responseSendTasks and
  cancellationNotificationTasks. Send/timer counts remain occupied until work exits.
  Internal `_setRequestLifecycleNow` is a deterministic response-expiry test seam
  available to `@testable import MCP`; production uses `ContinuousClock.now`.
  Internal response-limit and buffered-batch observation seams support synthetic
  backpressure and cancellation tests without changing production limits.

`Sources/MCP/Base/Transports/StdioTransport.swift`:

- Serialize outgoing frames across actor suspension, check task cancellation and
  connection state before writing, and track/cancel/drain the input reader on
  disconnect. This avoids interleaved JSON lines under backpressure.
- A canceled send that has written no bytes preserves the connection. Any failed or
  canceled partial frame finishes the stream and prevents further writes: otherwise
  the next JSON object would complete a corrupt line. This exceptional transport
  failure requires reconnecting. A full output pipe that exceeds the response-send
  deadline, or incoming work beyond the fixed limit, also requires reconnecting.
  Ordinary unanswered prompt timeouts on a healthy transport do not.

`Sources/MCP/Base/Transport.swift` documents the cooperation requirement below.

## Transport cooperation and limits

A bounded request lifecycle requires `Transport.send` to observe cancellation
promptly, including while blocked, and `disconnect` to terminate pending I/O.
Incoming application handlers likewise must cooperate with cancellation for stop to
drain them. Stdio implements this with nonblocking I/O and cancellable polling.
The lifecycle deliberately waits for owned send work to terminate rather than hiding
it behind a task that returns early. Swift cannot forcibly terminate an arbitrary
uncooperative transport/handler: such an implementation can delay request completion
and shutdown beyond the requested deadline. The single cancellation-notice slot
still prevents per-request accumulation, but cannot kill a noncooperative send.

## Verification and removal condition

Synthetic lifecycle tests live in the owning application's
`Tests/AppleCalendarMCPTests/MCPRequestLifecycleTests.swift`, alongside its ordinary
stdio/read-contract tests. Run the application's `./scripts/test.sh`; no live Calendar
query, approval prompt or install is required. Count assertions verify settled local
work, not whether a host dismissed its human-facing UI.

Replace this copy with a pinned upstream release only when upstream provides the
same atomic registration, deadline, cancellation propagation, disconnect draining
and safe cooperative transport behavior, and the application regression suite passes
against that release. Compare the entire source tree against the revision above
before updating; never apply a patch to `.build/checkouts` as a deliverable.

## Reproducible upstream comparison

`UPSTREAM.sha256` records every copied source file, LICENSE and the original
Package.swift. `LOCAL.patch` is the complete diff from those originals to this
copy (including the reduced manifest); added provenance files are not in the patch.
The only modified upstream files are Package.swift, Server/Server.swift,
Base/Transport.swift and Base/Transports/StdioTransport.swift under Sources/MCP.
To validate the baseline without changing this directory, copy it to a temporary
directory, run `patch -R -p1 < LOCAL.patch` there, then `shasum -a 256 -c UPSTREAM.sha256`.
Refresh both provenance artifacts whenever updating this vendored patch.
