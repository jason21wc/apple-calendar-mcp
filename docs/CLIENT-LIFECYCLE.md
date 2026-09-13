# Connecting, refreshing, and updating clients

The goal is a repeatable connection workflow without routinely quitting the AI app.
Keep the signed Calendar server at one stable path and let each host manage its stdio
connection. No server watchdog, automatic grant request, or new network transport is needed.

## Match the action to the problem

| Observation | Action | Success evidence |
|---|---|---|
| Server is configured but its tools are absent | Load the effective host configuration and refresh its MCP catalog/connection | The current task exposes `calendar_permission_status` and can call it |
| A new executable was installed | Refresh the host's server connection so it launches the installed executable | Check the server version reported at initialization, then permission status |
| A read reports `CALENDAR_STORE_WEDGED` | Refresh that server connection using the host's supported control | A fresh connection answers diagnostics; then a bounded read succeeds |
| Permission status reports unavailable access | Inspect the reported identity, installed path, signature, and authorization | `disclaimed-child` plus usable access in the actual host context |

Configuration, running executable, Calendar permission, and human approval are separate
checks. A restart does not install source changes, grant permission, or demonstrate approval.
If one controlled refresh fails, inspect its startup error and effective configuration;
do not keep restarting without new evidence. A full application restart is a fallback.

## Codex / ChatGPT desktop

For everyday use across projects, prefer one user-level registration in `~/.codex/config.toml`.
The repository's `.codex/config.toml` is a narrower trusted-project registration. Keep it until
the user-level entry is verified; avoid divergent definitions for the same server name.
The [OpenAI configuration guide](https://learn.chatgpt.com/docs/extend/mcp?surface=desktop)
describes both scopes and desktop/CLI sharing. Hosted web chats do not read those local files.

1. When active work is idle, open **Settings → MCP servers** and inspect `apple-calendar`.
   If absent, add a STDIO server named `apple-calendar` with command
   `/usr/local/bin/apple-calendar-mcp` and argument `--read-only`, then save.
2. Use the MCP settings **Restart** control after saving. In the inspected desktop build,
   this restarts the selected host's **backend connection**, not the desktop application.
   Its scope is broader than Calendar alone; do not describe it as a per-server restart.
3. Return to the task and use `/mcp` to inspect connected servers. Have the task call
   `calendar_permission_status`. Configuration visible on disk alone is insufficient.
4. Record authorization/identity separately from `client.elicitation_form_supported`.
   That flag describes the actual connection's declaration, not a human approval round trip.
   A shell harness reports the capabilities supplied by the harness, not the desktop UI.

**Verification scope (2026-09-13).** Online instructions say Settings → MCP servers → save →
Restart. Read-only inspection of desktop version `26.908.40834` (build `8881`, bundle ID
`com.openai.codex`) traced the Restart action to `codex-app-server-restart`, then the selected
connection's `restart(...)`, `stopProcess()`, and `ensureReady()`. This path does not invoke
Electron quit/relaunch. The UI's descriptive string says “restart the app,” so the event path
is the stronger evidence. This is implementation inspection, not a completed live UI test.

The [app-server API](https://learn.chatgpt.com/docs/app-server) also documents
`config/mcpServer/reload`, which queues a configuration refresh for loaded tasks, plus
`mcpServerStatus/list` and `mcpServer/tool/call` for verification. Use these only through an
available supported connection. A missing CLI control socket does not prove the desktop
lacks reload support. Do not automate private IPC or restart loops to work around host limits.

## Server ownership and updates

Under the negotiated [MCP stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports),
the client launches the subprocess. The [client initiates initialization](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
and owns its catalog. Self-respawning into existing pipes would create a fresh server without
the old session/request state; it cannot make an unregistered server discoverable.
`tools/list_changed` applies to a changed tool list on an existing connection; this server's
registry is static. Keep EOF shutdown and the one-time privacy-identity re-exec unchanged.

For an update: build and sign the reviewed release, replace the executable at the existing
installed path using the same signing identity, verify its signature, then refresh the host
connection. A same-path replacement should retain the grant; inspect `--doctor` before
assuming `--setup` is needed. Never grant access to a `.build` executable. Other hosts must
use their own documented refresh controls; do not copy Codex's UI steps into Cowork guidance.
