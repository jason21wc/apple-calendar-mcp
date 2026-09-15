# Approval probe: bounded request lifecycle before live measurement

Status: design precursor for implementation; no probe, cleanup fix, or write approval is
implemented by this document. Canonical gate: [implementation plan §6](IMPLEMENTATION-PLAN.md#6-the-write-surface--redesigned-2026-08-20), BACKLOG #24b.

## Intent and scope

Prove that this server can ask a human through the current MCP client and refuse when a
valid answer does not arrive. The experiment must never read or mutate EventKit content,
append to the mutation journal, mint a reusable approval token, or enable a write tool.
Read connection evidence is sufficient to start this work: Codex was measured natively,
Cowork visibility is user-confirmed, and Claude Code registration was reported successful.
Approval behavior remains unmeasured in all three clients.

Implement and test request cleanup first. A promptly returned timeout is not enough if it
leaves a suspended task or pending continuation behind. No normal refusal or timeout may
require quitting the AI app or disconnect the healthy read connection.

## SDK facts and selected direction

Pinned Swift SDK `0.12.1`, `Sources/MCP/Server/Server.swift`:

- `requestElicitation` creates a request internally, so callers cannot retain its ID.
- `send` schedules response registration asynchronously; `sendAndAwait` waits on an
  unstructured task with no deadline or caller-cancellation cleanup.
- `cancelRequest(id)` sends a cancellation notification only. Local pending state is not
  removed and its continuation is not resumed by that operation.
- `stop()` fails currently registered requests, but a previously scheduled registration can
  arrive after that sweep. Whole-server shutdown also interrupts unrelated reads.

These are source findings, not live proof of a host's prompt UI. The
[MCP cancellation specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation)
describes cooperative cancellation; sending a notice cannot guarantee local resource cleanup.

**Recommended implementation direction: repair lifecycle ownership in the SDK request
layer**, where request registration, result delivery, cancellation, and disconnection can
be coordinated together. Prefer a maintained upstream change; if unavailable, evaluate a
minimal, explicitly pinned patch/fork with attribution and a removal condition. Never edit
`.build/checkouts` as the deliverable or silently float the dependency to upstream main.
The exact dependency source/revision must be selected and tested before adopting it.

Alternatives considered:

- Host-native approval remains the other canonical §6 candidate and could avoid an SDK
  patch. It depends on separately verified host configuration and behavior. Server elicitation
  is the next experiment because the signed server can enforce its own per-request refusal
  contract across compatible clients; this choice does not claim host-native approval cannot
  work or that elicitation has already been proved.

- A process-terminating diagnostic bounds lifetime but forces reconnection and interrupts
  reads. Do not use it for this workflow given the observed Codex recovery problem.
- A separate transport broker could own elicitation IDs and cleanup, but would duplicate
  protocol routing and require response/batch/collision/late-message tests. Keep it as a
  fallback if the SDK change cannot be maintained; do not expand the initialize adapter
  into an unrelated approval mechanism by accident.

## Required lifecycle contract

1. Register each request and its continuation before making it sendable. Bind it to a
   connection generation; disconnection closes that generation before draining requests.
2. Use one actor-owned terminal transition for response, cancellation, timeout, send error,
   and disconnection. Remove pending state and resume exactly once. Reject late registration
   into a closed generation; cancellation before registration must prevent subsequent send.
3. Include sending and waiting within one monotonic deadline. The probe's initial response
   budget is **30 seconds**, not a production write-policy decision. Verify that the host's
   tool-call timeout leaves room for that budget; an earlier host cancellation still refuses.
   Progress notifications do not extend it. Test clocks/deadlines may be shortened/injected.
4. Check expiry again when processing a response. Timer scheduling must not admit a late
   acceptance. After cancellation or any terminal outcome, late or duplicate responses
   cannot change the result or authorize anything.
5. Local cleanup does not wait for the remote UI to dismiss. A cancellation notification is
   best effort and secondary to settling the local request. Its own send must not leave an
   unbounded accumulation of cleanup tasks when transport is stalled.
6. One locally pending elicitation per connection; no prompt queue or automatic retry. An
   overlapping call returns busy without emitting another request. A refused request must
   release its bookkeeping so another deliberate test can run while reads stay available.
   Give each attempt a unique request ID. A late answer from an older prompt cannot settle a
   newer request. Local cleanup does not prove UI dismissal: record whether a timed-out
   prompt remains visible, and verify the cross-attempt late-answer case.
7. Propagate wire-level cancellation of the enclosing `tools/call` to its nested approval
   request. Track outer handler and inner request lifecycles separately; cancellation
   before handler/inner registration must not later emit a prompt or accepted result.
   Test cancellation notifications for the outer ID before dispatch, during waiting, and
   racing acceptance. Do not assume canceling an inner task exercises this path.
8. Prove cleanup through settled request tasks and an empty pending registry, including
   cancellation-before-registration and disconnect-during-registration races. If the send
   path itself cannot be bounded, resolve that in the lifecycle layer before enabling the
   probe; do not claim a timeout wrapper solves it.

## Harmless probe contract

The future probe is opt-in diagnostic functionality, absent from the default tool catalog.
Keep the default read-only surface unchanged. Enabling a probe is not enabling writes.

- Require known form support before sending. Use the current explicit form-capability check;
  URL-only or absent support refuses. The protocol also defines legacy empty elicitation
  capabilities as form support: any compatibility change to our current conservative check
  requires separate decoder/negotiation tests, not an inference from calendar visibility.
- Use a fixed prompt explaining that this is an approval test and changes no calendar data.
  No model-supplied event text, secrets, client identity strings, or private metadata appears.
- Request one required boolean confirmation, initially false. Only a timely `accept` action
  with exactly valid, affirmative confirmation counts as this diagnostic's acceptance.
  A response does not itself prove a human saw the UI; pair it with observed user interaction.
- Return a bounded result: accepted, declined, canceled, unsupported, timed_out, disconnected,
  invalid_response, error, or busy. Only accepted is a positive diagnostic result, never
  reusable permission. Redact raw transport errors and returned content.
- Caller cancellation, non-response, malformed content and late acceptance must all refuse.
  Record outcome and cleanup evidence without preserving prompt contents or calendar data.

The [elicitation specification](https://modelcontextprotocol.io/specification/2025-11-25/client/elicitation)
provides accept/decline/cancel actions and separate form/URL capability declarations. UI
behavior must still be measured through the actual connected client.

## Acceptance checks and implementation order

First implement the request lifecycle and run fake-client tests for valid acceptance,
decline, cancel, missing form support, malformed response, send error, silence, caller
cancellation (including the enclosing tool call's wire-level cancellation), deadline/response
races, late and duplicate responses, cancellation before
registration, disconnect during registration, and concurrent prompt refusal. Assert no
retained pending entries or suspended request tasks and successful subsequent diagnostics.
A deliberately broken cleanup path must make the relevant test fail.

Then add the opt-in harmless probe with synthetic-only tests and verify the ordinary catalog
and read behavior remain unchanged. Build/sign/install at the existing final path only after
review and CI. Finally measure human accept and refusal through the current host; repeat
approval verification before enabling writes in each other client. Do not use a sibling
server's write tool as a substitute experiment.

This document advances design work; §6 Gate 1 remains open until the implementation and
actual human round trip are demonstrated. Afterwards the planned write sequence is create,
then delete **with restore in the same change**, then update, subject to the other §6 gates.
