# Approval probe: bounded request lifecycle before live measurement

Status: installed `0.2.3` has demonstrated valid affirmative approval on the previous Codex
host, and timely native decline plus non-response refusal on the September 19 updated host.
The unanswered result returned in 30.040 seconds with healthy follow-up diagnostics.
Native UI cleanup has failed: the human confirms the expired form retained editable controls.
The backend-to-frontend resolution gap is documented below. Late-answer isolation and
current-version affirmative approval remain open. No Calendar content changed and no
write tool exists. See the current evidence
below and [implementation plan §6](IMPLEMENTATION-PLAN.md#6-the-write-surface--redesigned-2026-08-20).

## Updated host verification (2026-09-19)

The human reports the ChatGPT updater says `26.915.31945` is the newest available version.
The installed bundle matches that version and its Codex backend reports `0.155.0-alpha.9.2`.
The [matching source tag](https://github.com/openai/codex/tree/rust-v0.155.0-alpha.9.2)
resolves to `4607249e430dac1c961df4dc615beae88e33cec8` and includes upstream cancellation
fix `3436cad5abbe9199c061880421b16d96a9ba702b` by ancestry. Specifically:

- [Cancellation registration and both wait branches](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/rmcp-client/src/elicitation_client_service.rs#L145)
  now apply to ordinary forms; notification handling no longer requires user-verification support.
- [Regression coverage](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/rmcp-client/src/user_verification_cancellation_tests.rs#L155)
  checks ordinary form/URL cancellation and release of pending responses and timeout pauses.
  This upstream test was inspected, not executed locally.
- [Code-mode delivery](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/core/src/tools/code_mode/execute_handler.rs#L145)
  still waits for pending elicitations to clear, so native cleanup must still be measured.

Native permission diagnostics remain healthy (`fullAccess`, `disclaimed-child`, form support
declared). This is a verified relevant host change, not proof of live UI behavior.

The initial September 19 probe returned `invalid_response`. The desktop response at
`2026-09-20T03:20:01.873Z` was `action: accept` with `confirm: false`; the server correctly
refused it. **The human later clarified they were elsewhere and did not see that form.**
Do not attribute its protocol response to a human action. Updated UI source still maps Skip
directly to decline, while Continue submits accept; the cause of the unseen response is unknown.

At the human's request, the next attended retry returned `declined` in 12.5 seconds.
Desktop response ID 78 at `2026-09-20T03:32:55.231Z` records `action: decline`, `content: null`.
Follow-up native diagnostics succeeded. The immediately following unanswered probe returned
`timed_out` with measured tool-call elapsed time **30,040 ms**, and another native diagnostic
succeeded. This establishes timely refusal/result delivery on the updated host without a
restart. No additional form response appeared in the inspected desktop log for that timeout.
A repeated unanswered test returned in 30,042 ms. The human confirmed that its checkbox
and Continue/Skip controls remained editable, then reported using Skip. A late decline
was logged at `2026-09-20T04:44:00.975Z`; subsequent diagnostics stayed healthy. This is a
failed UI-cleanup observation, not merely a retained completed transcript card.
Late-answer isolation remains distinct. Affirmative human approval was proved on the prior
host version, so verify it on the updated host before closing Gate 1. No Calendar content
changed; no update, reinstall or restart is indicated. Stay in the conversation during an
attended test: the server's 30-second request deadline does not pause when the user leaves.

### Remaining app-server cleanup gap

Exact tagged source separates internal cancellation from frontend request resolution.
Dropping the internal elicitation removes its responder and releases tool delivery, but
the separately spawned app-server handler still waits for a frontend response before emitting
`serverRequest/resolved`. The installed frontend would remove pending controls on that
notification. This source gap fits the observed retained form; no runtime notification trace
was captured. See the [reviewable upstream report](CODEX-ELICITATION-ISSUE.md) for the source
chain, reproduction and evidence boundaries. Research found existing upstream issue #40390;
the reviewed follow-up is now posted there (link in the report). A healthy synthetic connection
verified the installed server emits the matching cancellation; native receipt remains
untraced, so exact incident attribution is still an inference. September 20's isolated
app-server test independently confirms client cancellation processing and reproduces
missing frontend resolution and stale waiting-on-approval state for ten seconds after
cancellation and MCP disconnect; answered controls return to idle. Turn transitions can
clear callbacks as a fallback, so this outside-turn fixture does not prove an indefinite
normal-chat hang. Its late old acceptance did not settle a newer form in the bounded check.
It uses no Calendar server or native renderer and does not exercise code-mode pause release.
The normal Swift suite now asserts cancellation envelope/ID/type. The user authorized the
September 20 submission; its exact body was verified after posting.

Do not repeat identical timeout probes or change server deadlines/restart behavior to mask
this host defect. Keep Gate 1 open. Normal reads remain available. Any alternative approval
mechanism would require its own verified contract; no bypass is selected here.

## Native Skip and timeout investigation (2026-09-16)

Observed on desktop `26.908.70816`, bundled Codex backend `0.154.0-alpha.6.2`:

- An attended probe returned `accepted`; the human confirmed seeing the form in this chat.
  The response carried `confirm: true`; the probe still reported no Calendar change and no
  authorization for future writes. Native diagnostics afterward remained healthy.
- The human saw a clickable checkbox statement, **Continue**, and **Skip**, with no visible
  Cancel button. They explicitly chose Skip with the checkbox unchecked. That is valid:
  installed UI source dispatches `decline` immediately, without checkbox validation.
  Only Continue validates the form. Do not instruct the human to check a refusal request.
- The explicit Skip attempt began at `2026-09-17T04:43:15.531Z`; the desktop logged
  `decline` at `04:58:49.858Z`, and the tool result appeared at `04:58:49.859Z`.
  The tool reported 30 seconds, while transcript timestamps span over 15 minutes.
  A prior refusal attempt likewise returned `timed_out`. These are not successful native
  decline/cancel results. No wire capture establishes the precise physical-click timing.
- Following diagnostics succeeded with `fullAccess` / `disclaimed-child`. This proves
  connection health after dismissal, not unattended prompt cleanup or timely result delivery.

The [backend matching the installed version](https://github.com/openai/codex/blob/rust-v0.154.0-alpha.6.2/codex-rs/rmcp-client/src/elicitation_client_service.rs#L144)
registers and awaits cancellation only for user-verification requests, excluding ordinary
forms. Its notification handler also gates cancellation on user-verification support.
Separately, [code-mode result delivery](https://github.com/openai/codex/blob/rust-v0.154.0-alpha.6.2/codex-rs/core/src/tools/code_mode/execute_handler.rs#L136)
waits until pending elicitations clear. The Calendar SDK expires its request and sends a
best-effort cancellation notification. **Inference:** the host can retain the form after
that deadline and hold an already-completed timeout result until Skip clears the pending
request. This fits the logs and source; exact on-wire ordering remains unmeasured.

OpenAI's [upstream cancellation fix](https://github.com/openai/codex/commit/3436cad5abbe9199c061880421b16d96a9ba702b)
removes these guards and adds ordinary-form cancellation regression coverage. Its presence
in a desktop release was unverified at that checkpoint; the September 19 source verification
above now supersedes that uncertainty. The
[official update instructions](https://help.openai.com/en/articles/20001275-chatgpt-work-and-codex)
establish the update control, not fix availability. No Calendar-server reinstall, deadline
extension, checkbox weakening, or server restart loop is indicated by these findings.

## Native cancellation investigation (2026-09-15)

The human observed no form and did not cancel anything. Reads and subsequent diagnostics
continued to work. The installed Calendar binary was `0.2.2`; the inspected desktop bundle
reported `26.908.70816` and its bundled Codex backend reported `0.154.0-alpha.6.2`.

The incompatibility is in the encoded request, not a missing Calendar grant:

1. `ApprovalProbe.schema` supplied a top-level `title`. The Swift SDK encodes it; RMCP
   `3.2.0` preserves it through its schema decode/re-encode boundary.
2. The exact installed backend's exported `McpElicitationSchema` allows only `$schema`,
   `type`, `properties` and `required` at the root (`additionalProperties: false`). Its
   [tagged typed schema](https://github.com/openai/codex/blob/rust-v0.154.0-alpha.6.2/codex-rs/app-server-protocol/src/protocol/v2/mcp.rs#L404)
   uses `deny_unknown_fields`; conversion deserializes into that type at line 824.
3. The [tagged backend dispatch](https://github.com/openai/codex/blob/rust-v0.154.0-alpha.6.2/codex-rs/app-server/src/bespoke_event_handling.rs#L889)
   resolves that parse failure as `Cancel` and returns before sending the UI request.
   This supplies a concrete cause matching immediate cancellation without a form.

`0.2.3` removes only the root title. The fixed message and boolean field title retain the
human-facing wording. Required `confirm`, default false, exact `confirm: true` acceptance,
30-second lifetime and no-write behavior remain unchanged. This is a portable schema subset,
not a Codex-only alternate tool contract. The general
[app-server documentation](https://learn.chatgpt.com/docs/app-server) describes the form
request/response path; its existence alone did not prove this payload would reach UI.

Validation: the encoded-request regression fails on the original source and passes after
the correction. The actual installed `0.2.2` wire payload fails the schema exported by the
installed backend, specifically for unexpected `title`; debug and signed release `0.2.3`
wire payloads pass. Local suite passes with the documented lifecycle sandbox exclusion.
Independent review confirms the parse-failure path and unchanged confirmation safeguards.
These synthetic/source checks established the payload correction. The September 16 native
acceptance above subsequently established rendering and a valid human response.
No personal Calendar data was queried by these checks.

The upstream cancellation fix does not explain this earlier schema rejection. It is relevant
to the separate September 16 timeout/Skip investigation above. Do not change host
approval settings, remove the required checkbox, or add a server restart loop for this defect.

### Installation handoff

**Completed September 16:** installed version/hash verified and the human confirmed full
quit/reopen. The commands below describe the completed handoff, not another required step.
The native client now returns form content; no further Calendar-server install is indicated.
The separate host cancellation investigation above supersedes the earlier refresh guidance.

The signed candidate is `.build/release/apple-calendar-mcp`, version `0.2.3`, SHA-256
`8e52a1ef7537c10d2a336ad3d628a4f0dc7d29837538e24912318d73e5509ff9`.
Its strict signature passes and its designated requirement matches installed `0.2.2`.
Backup: `.build/apple-calendar-mcp-0.2.2.backup`.

From the project terminal, install at the existing path:

```sh
sudo install -o root -g wheel -m 755 .build/release/apple-calendar-mcp /usr/local/bin/apple-calendar-mcp
```

Refresh the current host once to load the replacement. On this installation use full
quit/reopen, because Settings Restart previously broke conversation display. Do not run
`--setup` or re-register the server. Then verify native version/connection and run the
harmless probe with the human ready. Deliberate acceptance, decline/cancel, non-response,
UI dismissal and healthy follow-up reads remain Gate 1 measurements.

## Intent and scope

Prove that this server can ask a human through the current MCP client and refuse when a
valid answer does not arrive. The experiment must never read or mutate EventKit content,
append to the mutation journal, mint a reusable approval token, or enable a write tool.
Read connection evidence is sufficient to start this work: Codex was measured natively,
Cowork visibility is user-confirmed, and Claude Code registration was reported successful.
A valid affirmative form response is now measured in Codex. Its remaining lifecycle cases
and approval behavior in Cowork and Claude Code remain unproved.

Implement and test request cleanup first. A promptly returned timeout is not enough if it
leaves a suspended task or pending continuation behind. No normal refusal or timeout may
require quitting the AI app or disconnect the healthy read connection.

## SDK facts and selected direction

Unmodified upstream Swift SDK `0.12.1`, `Sources/MCP/Server/Server.swift`, had these defects:

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

**Selected implementation: repair lifecycle ownership in the SDK request layer.**
`Vendor/swift-sdk` contains MCP sources from upstream 0.12.1 revision
`a0ae212ebf6eab5f754c3129608bc5557637e605`, with the MIT license, original hashes and
reversible local patch. The root package uses that local dependency and pins transitive
versions. Upstream's latest release was still 0.12.1 when checked on September 14.
This keeps the correction reviewable and reproducible without publishing an external fork
or editing `.build/checkouts`. Replace it with a pinned upstream release once equivalent
lifecycle behavior passes our regression suite. See the vendor README for exact changes
and transport cooperation requirements.

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

### Response delivery limits

The local SDK patch retains incoming ownership through response delivery. It admits at most
16 slots (batch collectors also consume a slot), and response sending has a separate
5-second deadline. Overload or stalled/failed delivery closes the connection and drains
owned work. Partial-frame cancellation also closes stdio to prevent a corrupt next frame.
These are transport failures requiring reconnection, distinct from an ordinary unanswered
30-second approval prompt on a responsive connection. No background restart is introduced.
Batch requests run concurrently; canceled results are filtered at aggregate commitment.
The approval deadline measures the answer, not time waiting behind an unrelated batch result.

## Harmless probe contract

The candidate probe is opt-in diagnostic functionality, absent from the default tool catalog.
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

The implementation lives in `MCP/ApprovalProbe.swift`, wired by `ServerBootstrap.swift`
only with `--enable-approval-probe`. Synthetic checks live in `ApprovalProbeTests`,
`MCPRequestLifecycleTests` and `StdioWriteLifecycleTests`. They use fake clients and owned
pipes, never Calendar content. §6 Gate 1 remains open until final implementation validation
and the actual human round trip are demonstrated. Afterwards the planned write sequence is create,
then delete **with restore in the same change**, then update, subject to the other §6 gates.
