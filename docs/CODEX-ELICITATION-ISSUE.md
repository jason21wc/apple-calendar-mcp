# Draft upstream report: expired MCP elicitation form remains interactive

Status: prepared for review; **not submitted** to OpenAI or GitHub.

## Environment

- ChatGPT desktop for macOS: `26.915.31945`.
- Bundled Codex backend: `0.155.0-alpha.9.2`.
- Local stdio MCP server: `apple-calendar-mcp 0.2.3`, opt-in harmless approval probe.
- The probe has no Calendar mutation path or reusable write approval.

## Reproduction

1. Connect the server with form elicitation enabled and invoke `calendar_approval_probe`.
2. The server sends a standard form elicitation with a required boolean, initially false.
3. Leave the form unanswered. The server expires its request after 30 seconds, removes its
   pending continuation and sends a best-effort `notifications/cancelled` for that request ID.
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

## Source-supported diagnosis

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
