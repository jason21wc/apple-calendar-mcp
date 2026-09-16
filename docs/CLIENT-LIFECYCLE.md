# Connecting, refreshing, and updating clients

The goal is a repeatable connection workflow without routinely quitting the AI app.
Codex Settings Restart has caused a blank conversation twice on this machine; until that
host issue is resolved, use a full quit/reopen when a connection refresh is actually needed.
A healthy connection requires neither action.
Keep the signed Calendar server at one stable path and let each host manage its stdio
connection. No server watchdog, automatic grant request, or new network transport is needed.

## Match the action to the problem

| Observation | Action | Success evidence |
|---|---|---|
| Server is configured but its tools are absent | Load the effective host configuration and refresh its MCP catalog/connection | The current task exposes `calendar_permission_status` and can call it |
| Startup reports a handshake/data-format error | Read the host startup log and reproduce initialization; correct the server incompatibility before refreshing again | Initialization succeeds, then tools are listed |
| A new executable was installed | Refresh the host's server connection so it launches the installed executable | Check the server version reported at initialization, then permission status |
| A read reports `CALENDAR_STORE_WEDGED` | Refresh that server connection using the host's supported control | A fresh connection answers diagnostics; then a bounded read succeeds |
| Permission status reports unavailable access | Inspect the reported identity, installed path, signature, and authorization | `disclaimed-child` plus usable access in the actual host context |

Configuration, running executable, Calendar permission, and human approval are separate
checks. A restart does not install source changes, grant permission, or demonstrate approval.
If one controlled refresh fails, inspect its startup error and effective configuration;
do not keep restarting without new evidence. A full application restart is a fallback.

## Codex / ChatGPT desktop

For everyday use across projects, prefer one user-level registration in `~/.codex/config.toml`.
A `.codex/config.toml` entry is a narrower trusted-project registration. During migration,
keep it until the user-level entry is verified, then remove the duplicate. This repository
no longer supplies that override; avoid divergent definitions for the same server name.
The [OpenAI configuration guide](https://learn.chatgpt.com/docs/extend/mcp?surface=desktop)
describes both scopes and desktop/CLI sharing. Hosted web chats do not read those local files.

**Check editability first.** This desktop build makes project-origin MCP entries read-only:
both the gear and enable toggle are disabled. Restart is conditional on a successful
settings-page mutation; it is not an always-visible reconnect button. A file edited outside
Settings does not itself set that UI flag. The September 13 screenshot exposed this missing
precondition in the original runbook. Do not send the user looking for Save/Restart on a
read-only row or change unrelated settings just to reveal Restart.

For migration, create the user-level entry with the supported CLI:

```bash
codex mcp add apple-calendar -- /usr/local/bin/apple-calendar-mcp --read-only
```

If the agent cannot write the user configuration, run this in the user's Terminal. Verify
the resulting user-level entry, then remove the matching project override so Settings can
manage it. The Add UI generates a suffixed key when that name already exists; do not create
an accidental `apple-calendar-2` registration. CLI registration alone does not prove that an
existing task has reloaded its tools or make the Restart control visible. First inspect
the host's connection status or startup log. `/mcp` is documented by OpenAI but was absent
from this desktop's composer; do not prescribe it unless the command is actually offered.
Use launch evidence to choose a refresh or resolve a failure, rather than assuming either
from missing tools.

**Current local exception (2026-09-14).** The human reports that Settings Restart twice
left prompt history blank and new text invisible. A full quit/reopen restored the display.
After installing `0.2.1` and completing that recovery, this task exposed Calendar tools;
native permission status returned `fullAccess`, `disclaimed-child`, and form/URL elicitation
declarations. A bounded busy-interval read also succeeded without truncation. This verifies
read access, not a human-approval round trip or a reliable Settings-only refresh. Do not
repeat the broken UI workflow or add a Calendar watchdog to repair it. The precise cause
of the host display failure remains unconfirmed. Host logs show Calendar `ready` for the
current task at 2026-09-15 02:01:16 UTC, after Settings Restart and before the full relaunch
at 02:04:49 UTC. Task resume/read requests also returned no error. Thus MCP recovery
succeeded independently of the failed display; a renderer ResizeObserver error nearby is
only correlated evidence, not an established cause.

The inspected Settings workflow below is retained for reference and other builds; it is
**not the recommended refresh on this affected installation**:

For an editable user-level entry:

1. When active work is idle, open **Settings → Plugins → MCPs** and inspect `apple-calendar`.
   If absent, add a STDIO server named `apple-calendar` with command
   `/usr/local/bin/apple-calendar-mcp` and argument `--read-only`, then save.
2. After a successful settings-page change, use its **Restart** control. In the inspected desktop build,
   this restarts the selected host's **backend connection**, not the desktop application.
   Its scope is broader than Calendar alone; do not describe it as a per-server restart.
3. Return to the task and have it call `calendar_permission_status` if exposed. If tools
   remain absent, inspect the host startup log before any further restart. Configuration
   visible on disk alone is insufficient.
4. Record authorization/identity separately from `client.elicitation_form_supported`.
   That flag describes the actual connection's declaration, not a human approval round trip.
   A shell harness reports the capabilities supplied by the harness, not the desktop UI.

**Verification scope (2026-09-13).** Online instructions say Settings → MCP servers → save →
Restart. Read-only inspection of desktop version `26.908.40834` (build `8881`, bundle ID
`com.openai.codex`) traced the Restart action to `codex-app-server-restart`, then the selected
connection's `restart(...)`, `stopProcess()`, and `ensureReady()`. This path does not invoke
Electron quit/relaunch. The UI's descriptive string says “restart the app,” so the event path
is the stronger evidence. This is implementation inspection, not a completed live UI test.

**Observed refresh (2026-09-14).** After migration to user-level registration, the human
successfully toggled Calendar off/on and used Settings Restart. The tool catalog still
lacked Calendar. Host logs for the actual task then showed a launch followed by JSON-RPC
`-32603` during initialization: “The data couldn’t be read because it isn’t in the correct
format.” This is a handshake failure, not evidence that the refresh control was unavailable.

The installed `0.2.0` reproduced that exact error when a synthetic initialize request
contained an object-valued experimental capability; an otherwise identical empty-capability
request succeeded. Swift SDK `0.12.1` incorrectly models those values as strings. The
`0.2.1` source adapter ignores unsupported experimental objects only at initialization,
preserving standard capabilities and normal SDK state. Tests cover tool discovery,
elicitation declarations, malformed values, EOF, errors, and cancellation. Remove the
adapter when a pinned upstream SDK accepts protocol-correct experimental objects. A
synthetic fixture is not an exact capture of the desktop's handshake; verify the installed
replacement through the native host before calling this integration complete. That native
read verification passed on September 14 as recorded above; the exact original desktop
initialize payload remains uncaptured.

The [app-server API](https://learn.chatgpt.com/docs/app-server) also documents
`config/mcpServer/reload`, which queues a configuration refresh for loaded tasks, plus
`mcpServerStatus/list` and `mcpServer/tool/call` for verification. Use these only through an
available supported connection. A missing CLI control socket does not prove the desktop
lacks reload support. Do not automate private IPC or restart loops to work around host limits.

## Current client evidence

| Client | Read connection evidence | Approval evidence |
|---|---|---|
| Codex desktop | Native permission/identity checks pass on installed `0.2.2`; bounded busy read previously passed on `0.2.1` | Form/URL declared; native probe returned `canceled`, subsequent diagnostics passed. Human UI observation pending; no human approval proved |
| Claude Cowork | User confirms the calendar is visible; exact connection route and capability payload not supplied | Not measured |
| Claude Code CLI | User reports successful user-scope registration of the installed path with `--read-only`; native call not yet reported | Not measured |

Cowork visibility is accepted as the user's observation. Do not infer its mechanism from a
Desktop JSON entry or overwrite the working setup. Capability and approval checks remain
per-client; missing CLI evidence does not block design work in the currently connected client.

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
