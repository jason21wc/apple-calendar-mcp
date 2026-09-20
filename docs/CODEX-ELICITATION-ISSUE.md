# Research and draft follow-up: expired MCP elicitation form remains interactive

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

| Case | MCP response from Codex | Tool result | Matching frontend resolution |
|------|-------------------------|-------------|------------------------------|
| Control: synthetic frontend decline | `decline` | Delivered | Observed normally |
| Server cancellation after frontend request observed | `cancel` | Delivered | Absent during the two-second observation |
| Late synthetic decline after that observation | Request already canceled | Already delivered | Observed 0.878 ms after sending the late response |

The MCP request ID is the string `synthetic-form-1`; the frontend request ID is integer `0`
in each fresh process. Matching resolution requires both the frontend ID and the thread ID.
The synthetic server sends the tool result only after receiving Codex's `cancel` response:
**this establishes client processing of cancellation, not merely notification emission.**
The answered control establishes that the event reader can observe frontend resolution.
The late-response timing is an observed ordering, not proof that no other scheduling race
is possible or that resolution could never occur after a longer wait.

This independently reproduces the backend lifecycle gap without our Calendar server. It
does not retrospectively trace earlier native incidents, inspect actual desktop rendering,
or exercise the separate code-mode timeout-pause path. Gate 1 remains open.

To reproduce, run `python3 scripts/reproduce-codex-elicitation.py --codex /absolute/path/to/codex`.
Use the app-bundled executable when comparing desktop versions. Exit zero means the fixture
completed with a valid control; inspect `cleanup_gap_reproduced` in the cancellation case
to distinguish a reproduced gap from timely cleanup. The script is opt-in, not normal CI.
Our normal Swift suite now also checks cancellation envelope version, absent notification ID,
and exact originating request ID/type on timeout. No installed server rebuild is needed.

### Proposed comment on existing issue #40390 (not posted)

Reproduced the remaining frontend-cleanup symptom with the backend bundled in ChatGPT
desktop 26.915.31945: Codex 0.155.0-alpha.9.2. This build includes #44238; the tool result
now returns promptly, but frontend resolution can remain pending after server cancellation.

An isolated stdio app-server reproduction uses `mcpServer/tool/call` with a synthetic MCP
server. After observing `mcpServer/elicitation/request`, the fixture sends a cancellation
targeting the original MCP request. Codex responds to that request with `action: cancel`;
only then does the fixture return the tool result. The app-server delivers that result,
but emits no matching `serverRequest/resolved` during a two-second observation. A later
synthetic frontend decline is followed by that resolution notification. A separate answered
control resolves normally. MCP and frontend IDs are tracked separately.

The tagged source [drops the internal response route](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/codex-mcp/src/elicitation.rs#L106)
on cancellation while its [separate app-server response task](https://github.com/openai/codex/blob/rust-v0.155.0-alpha.9.2/codex-rs/app-server/src/bespoke_event_handling.rs#L1713)
still awaits the frontend receiver before emitting resolution. This suggests cancellation
needs to resolve both lifetimes.

This reproduction does not run the desktop renderer or the model/code-mode path. No
Calendar data, personal paths, credentials, or real approvals are involved. The reproduction
script is [available here](https://github.com/jason21wc/apple-calendar-mcp/blob/main/scripts/reproduce-codex-elicitation.py).

## Research and assumption review (2026-09-19)

- **Closest existing report:** #40390 was opened August 24 and remains open when checked.
  It describes an undismissed server-originated form and a held tool result until manual
  cancellation, using backend `0.149.0-alpha.4.3` and Streamable HTTP. Its author reports
  matching cancellation IDs and working cancellation in Claude Code. Those are the
  reporter's observations, not measurements of this installation. Our stdio reproduction
  now differs: the tool result returns promptly, while the form remains editable.
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

The installed frontend handles `serverRequest/resolved` by removing the pending request
and rendering completed history. The source gap fits the observed result/UI split; a full
runtime notification trace was not captured, so exact runtime attribution remains an inference.

## Suggested fix and regression

Propagate internal elicitation cancellation to its associated frontend request, remove the
pending callback and emit `serverRequest/resolved` without waiting for a human response.
Test the complete app-server flow: server cancellation → tool result released → frontend
request resolved → late response cannot revive that request or settle a newer request.
The existing ordinary-form cancellation regression covers internal route/pause release,
but does not establish desktop prompt cleanup.
