# Research and draft follow-up: MCP elicitation request cleanup

Status: **not submitted** to OpenAI or GitHub. Research found an existing matching symptom
report, [openai/codex #40390](https://github.com/openai/codex/issues/40390). Prefer a qualified
follow-up there, with human authorization, over creating a duplicate issue.

## Automated backend reproduction (2026-09-20)

The bundled `0.155.0-alpha.9.2` backend reproduces the missing frontend resolution using
an isolated stdio app-server, temporary configuration, and a synthetic MCP server.
`scripts/reproduce-codex-elicitation.py` uses the direct `mcpServer/tool/call` API, following
the [tagged app-server integration test](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/app-server/tests/suite/v2/mcp_tool.rs#L634).
It uses no model turn, account credentials, native UI, Calendar connection or network listener.
Deliberately unusable `file:` service endpoints prevent startup HTTP calls; this is fixture
isolation, not recommended end-user configuration. The host's configuration is unchanged.

| Case | Protocol outcome | Frontend resolution and thread status |
|------|------------------|---------------------------------------|
| Normal synthetic decline | MCP `decline`; tool result delivered | One resolution; thread idle |
| Cancellation, no later answer | MCP `cancel`; tool result delivered | No resolution over ten seconds; active / waitingOnApproval |
| Late synthetic decline after cancellation | Internal request already canceled | One frontend resolution; thread returns to idle |
| MCP fixture disconnect while form pending | Tool error delivered | No resolution over ten seconds; active / waitingOnApproval |
| New form followed by old form's late acceptance | Old request stays canceled; new request's own decline completes it | No new-form settlement during one-second negative observation; one resolution per form; final idle |

The first MCP request ID is string `synthetic-form-1`; its frontend ID is integer `0`
in each fresh process. The successive case uses `synthetic-form-2` and frontend ID `1`.
Matching resolution requires both the frontend ID and the thread ID.
The synthetic server sends the tool result only after receiving Codex's `cancel` response:
**this establishes client processing of cancellation, not merely notification emission.**
The answered control establishes that the event reader can observe frontend resolution.
The observations are bounded, not proof of infinite retention or every possible race.
The first two-second baseline check is retained; `--extended` adds the ten-second silent
cancellation/disconnect observations and newer-request isolation. Results describe the
installed backend; future builds can legitimately report timely cleanup instead.

This independently reproduces the backend lifecycle gap without our Calendar server. It
does not retrospectively trace earlier native incidents, inspect actual desktop rendering,
or exercise the separate code-mode timeout-pause path. Gate 1 remains open.

To reproduce, run `python3 scripts/reproduce-codex-elicitation.py --codex /absolute/path/to/codex --extended`.
Use the app-bundled executable when comparing desktop versions. Exit zero means the fixture
completed with a valid control; inspect `cleanup_gap_reproduced` in the cancellation case
to distinguish a reproduced gap from timely cleanup. The script is opt-in, not normal CI.
Our normal Swift suite now also checks cancellation envelope version, absent notification ID,
and exact originating request ID/type on timeout. No installed server rebuild is needed.

### Proposed comment on existing issue #40390 (not posted)

Related remaining cleanup failure on Codex `0.155.0-alpha.9.2`, bundled in ChatGPT desktop
`26.915.31945`. This build includes #44238. Unlike the original report, the synthetic tool
result returns promptly; the frontend request and waiting-on-approval status remain pending.

An isolated stdio app-server fixture calls `mcpServer/tool/call` outside a model turn.
After observing `mcpServer/elicitation/request`, it cancels the original MCP request and
waits for Codex's `action: cancel` before returning the tool result. The result arrives,
but no matching `serverRequest/resolved` appears over ten seconds without a frontend reply;
`thread/read` still reports `active` with `waitingOnApproval`. Terminating the MCP fixture
while its form is pending similarly delivers a tool error but leaves resolution absent
and the same approval status over ten seconds.

Controls: a normal decline resolves and returns the thread to idle. A late decline after
cancellation also clears the stale frontend request and returns it to idle. With a newer
form pending, a late acceptance for the old frontend ID did not settle the new request
during a one-second observation; its own decline then settled it exactly once. MCP and
frontend IDs are correlated separately. This test found no cross-request approval failure.

The tagged source [drops the internal responder](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/codex-mcp/src/elicitation.rs#L106),
while the [frontend task and approval guard](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/app-server/src/bespoke_event_handling.rs#L1713)
have a separate lifetime. [Turn transitions](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/app-server/src/bespoke_event_handling.rs#L155)
can clear callbacks, so this direct-call reproduction does **not** establish an indefinite
hang during an ordinary chat turn. It isolates a missing per-request termination path.
A fix should retire the callback, waiter, approval guard and replay eligibility together,
and emit resolution once, including registration/cancellation/answer races.

Reproduction: run [this script](https://github.com/jason21wc/apple-calendar-mcp/blob/main/scripts/reproduce-codex-elicitation.py)
with `--codex /absolute/path/to/codex --extended`. It uses temporary configuration and a
synthetic server, without a model service, account credentials, Calendar or real approvals.
The native renderer, model/code-mode path and reconnect replay are not tested here.

## Systemic review (2026-09-20)

**Recommendation:** add a qualified follow-up to #40390, with the reproduction and the
request-lifetime finding. The report should ask for complete per-request cleanup, not merely
hiding a form. Do not change this Calendar server's restart behavior or approval deadline.

The source exposes two lifetimes for one elicitation. MCP cancellation ends the internal
request; a separately registered app-server callback waits for a frontend response. That
callback's task also owns the approval-status guard. The existing cleanup at
[turn start/completion](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/app-server/src/bespoke_event_handling.rs#L155)
and [interruption](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/app-server/src/bespoke_event_handling.rs#L1204)
can eventually clear it. This is a mismatch between request lifetime and turn lifetime.

That distinction corrects an important assumption in the first draft: the direct API test
runs outside a model turn. It shares the elicitation response handler, but has no turn
completion to trigger the fallback. It establishes a per-request cleanup gap, not an
infinite hang in an ordinary chat turn. We have not reproduced the full native renderer or
code-mode execution path. The earlier native incident remains consistent with this cause,
not conclusively attributed to it.

State beyond the visible form matters. Source shows pending callbacks remain eligible for
[replay](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/app-server/src/outgoing_message.rs#L446),
while the retained permission guard contributes to
[waiting-on-approval status](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/app-server/src/thread_status.rs#L443).
[Idle unloading](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/app-server/src/request_processors/thread_lifecycle.rs#L56)
requires an inactive thread. Replay and unload consequences are source-supported risks,
not runtime measurements or a demonstrated memory leak. Other approval handlers use similar
callback machinery, but this does not establish that they have the same defect: their
lifetime can legitimately belong to the enclosing turn.

### Broader duplicate and fix search

The closest report remains #40390, open with no comments when checked on September 20.
Its older Streamable HTTP reproduction held both the form and the tool result; our newer
stdio result returns. Report a related remaining failure, not an identical full symptom set.

- [PR #44238](https://github.com/openai/codex/pull/44238) changed RMCP cancellation,
  shutdown and reconnect handling. It is present in the installed backend and addresses
  the lower-level wait. It did not modify the app-server frontend callback lifetime.
- [PR #43708](https://github.com/openai/codex/pull/43708) adds TUI user-verification request
  bookkeeping; [PR #43925](https://github.com/openai/codex/pull/43925) cancels native
  verification operations separately. They illustrate distinct operation owners, but do
  not establish a fix for ordinary form cleanup.
- [#39149](https://github.com/openai/codex/issues/39149) concerns a host with no approval
  surface; [#39346](https://github.com/openai/codex/issues/39346) concerns missing mobile
  approval controls. Neither demonstrates the same cancellation path.
- [#39426](https://github.com/openai/codex/issues/39426) requests paired human-input lifecycle
  events, and [#37995](https://github.com/openai/codex/issues/37995) requests structured
  cross-thread answers. Those are related feature requests, not duplicates of this bug.

Targeted issue and PR searches covered elicitation, cancellation, disconnect, stale approval
and `serverRequest/resolved`. Inspected upstream main
`a2de8fedcc3abe3cdde09b43515db820fb6b95b5` retains the
[internal responder-only drop](https://github.com/openai/codex/blob/a2de8fedcc3abe3cdde09b43515db820fb6b95b5/codex-rs/codex-mcp/src/elicitation.rs#L121)
and [separate frontend wait](https://github.com/openai/codex/blob/a2de8fedcc3abe3cdde09b43515db820fb6b95b5/codex-rs/app-server/src/bespoke_event_handling.rs#L1713).
No closer report or applicable later fix was found in this bounded search. This is not a
claim that every build or unmerged change was inspected.

### Repair contract and remaining verification

When an originating elicitation ends, retire its associated frontend registration,
callback/waiter, approval guard and replay eligibility exactly once. Notify the frontend
through the normal resolution path. A display-only notification could leave the other
state behind. Preserve routed identity across reconnects; an old response must not affect
another request that reused an MCP number.

An upstream repair should test cancellation before/after frontend registration, cancellation
racing an answer, transport loss, and a newer concurrent request. Also test cancellation
*during* a model turn followed by turn completion, so the broad fallback cannot hide missing
per-request cleanup. These are repair acceptance criteria; this project's synthetic test
does not claim coverage of every race. A frontend reconnect/replay check and native UI
verification would establish those additional boundaries after a fix is available.

## Research and assumption review (2026-09-19)

- **Closest existing report:** #40390 was opened August 24 and remains open when checked.
  It describes an undismissed server-originated form and a held tool result until manual
  cancellation, using backend `0.149.0-alpha.4.3` and Streamable HTTP. Its author reports
  matching cancellation IDs and working cancellation in Claude Code. Those are the
  reporter's observations, not measurements of this installation. Our stdio reproduction
  now differs: the tool result returns promptly, while frontend resolution remains pending.
  The editable native form is a separate human observation.
- **Relevant merged fix:** [PR #44238](https://github.com/openai/codex/pull/44238), merged
  September 9, fixes internal form/URL cancellation and timeout-pause release. Its presence
  in our installed backend was verified earlier. It does not establish desktop cleanup.
- **Current upstream source:** main at `5c5308fc9a9ee789049d646ef11e5400384b9c6f` still has
  the [internal responder-only drop](https://github.com/openai/codex/blob/5c5308fc9a9ee789049d646ef11e5400384b9c6f/codex-rs/codex-mcp/src/elicitation.rs#L121)
  and [separate frontend-response wait](https://github.com/openai/codex/blob/5c5308fc9a9ee789049d646ef11e5400384b9c6f/codex-rs/app-server/src/bespoke_event_handling.rs#L1713).
  Targeted issue/PR searches found no later fix for this path. This is bounded source
  inspection, not an assertion that every release or unreleased desktop build was tested.
- **Similar but distinct:** [#39149](https://github.com/openai/codex/issues/39149) concerns
  a hidden host with no approval surface and no MCP request reaching its server. Our form
  appears and our server returns a result; that issue's pre-approval workaround does not
  address this failure or satisfy our per-write human confirmation requirement.
- **Protocol expectation:** [MCP cancellation](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation)
  permits a server to cancel its own outgoing elicitation and recommends resource cleanup,
  ignoring late responses, and indicating cancellation in the UI. It does not mandate a
  particular form-removal animation or control layout. Describe this as stale actionable
  UI and incomplete lifetime propagation, not a violation of a specific visual MUST.
- **Deadline:** [MCP lifecycle guidance](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#timeouts)
  recommends bounded requests and cancellation on expiry, without choosing thirty seconds.
  The disclosed diagnostic deadline is reasonable. Future production approval timing is
  a separate usability decision; increasing this deadline does not repair cleanup.

### Evidence strengthened, and limits retained

A fresh synthetic stdio client exercised installed `0.2.3` with form capability and the
harmless approval probe. At measured **30,023 ms**, it received a correctly correlated
`notifications/cancelled` (same string ID as `elicitation/create`), followed by the
`timed_out` tool result. Ping succeeded afterward and the owned process exited zero on EOF.
No Calendar content, live journal, native approval UI, or app configuration was accessed.
This verifies cancellation emission on a healthy synthetic connection. It does **not**
prove receipt by Codex during the earlier native incidents.

The server's notification is deliberately best-effort (`Server.swift:639`): one occupied
notification slot suppresses another notice, send failures are ignored, and sending has a
100 ms budget. At the September 19 review, lifecycle tests established refusal and
late-answer isolation but did not yet assert the outgoing cancellation's ID. Thus undelivered cancellation remains an
alternative explanation for an individual native run. Also, frontend response ID `8` is
not the MCP elicitation ID; their mapping was not captured.

**September 19 conclusion (before the automated reproduction above):** the client lifetime gap is source-supported and is the leading
explanation, corroborated by an existing report. Exact attribution of our native incidents
remains unproved. An independent review reached that distinction; its findings were checked
against our server, tests, tagged client source, and the protocol.

**Verification selected on September 19 and now completed above:** an automated, isolated app-server reproduction using
a harmless synthetic server should capture the MCP cancellation arriving and require a
matching `serverRequest/resolved` before any human response. It must map the MCP and
frontend IDs separately. This tests the suspected propagation gap without another manual
timeout trial. A permanent server regression should additionally assert cancellation ID
and type on the healthy path. Both checks were subsequently implemented and passed on
September 20; the app-server check reproduces the gap rather than a repair.

## Environment

- ChatGPT desktop for macOS: `26.915.31945`.
- Bundled Codex backend: `0.155.0-alpha.9.2`.
- Local stdio MCP server: `apple-calendar-mcp 0.2.3`, opt-in harmless approval probe.
- The probe has no Calendar mutation path or reusable write approval.

## Reproduction

1. Connect the server with form elicitation enabled and invoke `calendar_approval_probe`.
2. The server sends a standard form elicitation with a required boolean, initially false.
3. Leave the form unanswered. The server expires its request after 30 seconds, removes its
   pending continuation and attempts a best-effort `notifications/cancelled` for that request ID.
4. The outer tool returns `timed_out`. Observe the still-editable checkbox and Continue/Skip
   controls in the desktop UI.
5. A late Skip produces a frontend decline response even though the server request expired.

## Expected and observed

Expected: cancellation also resolves the associated frontend request without user action.
Retaining an inactive completed transcript card is fine; actionable expired controls are not.

Observed: two unanswered runs returned in measured 30,040 ms and 30,042 ms. Native permission
queries succeeded afterward. The human reported that the form remained editable and later
used Skip. A desktop log recorded that late decline at `2026-09-20T04:44:00.975Z`, after
post-timeout diagnostics at `04:42:44Z`. No Calendar data changed; the probe accesses no Calendar content and this report contains none.

## Source-supported candidate cause

The earlier RMCP cancellation fix is present in this backend tag, but cancellation does not
propagate through the separate frontend-request lifetime:

1. [RMCP cancellation](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/rmcp-client/src/elicitation_client_service.rs#L163)
   returns cancel, dropping the elicitation future.
2. [PendingElicitationRequest::drop](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/codex-mcp/src/elicitation.rs#L106)
   removes the internal response route without emitting a completion event. The request's
   [registration lifetime](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/codex-mcp/src/elicitation.rs#L477)
   ends, allowing tool-result delivery to resume.
3. App-server has already [spawned a separate frontend response task](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/app-server/src/bespoke_event_handling.rs#L918)
   and retained a [frontend callback](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/app-server/src/outgoing_message.rs#L357).
4. [on_mcp_server_elicitation_response](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/app-server/src/bespoke_event_handling.rs#L1713)
   awaits that frontend receiver before calling the resolver that
   [emits serverRequest/resolved](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/app-server/src/request_processors/thread_lifecycle.rs#L849).

Turn start/completion/interruption and thread teardown can also remove the callback and
wake its receiver. The source chain above describes missing per-request propagation, not
the absence of every cleanup path.

The installed frontend handles `serverRequest/resolved` by removing the pending request
and rendering completed history. The source gap fits the observed result/UI split; a full
runtime notification trace was not captured, so exact runtime attribution remains an inference.

## Suggested fix and regression

Use the repair contract in the systemic review above. Resolve the linked request state
on originating-request termination, with exactly-once handling of cancellation/answer races.
Test both direct calls and model turns, plus late response isolation. The existing RMCP
regression establishes internal route/pause release; it does not establish app-server
status, replay or native prompt cleanup.
