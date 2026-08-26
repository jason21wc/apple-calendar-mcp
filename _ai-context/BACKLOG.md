<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Backlog

**Memory Type:** Prospective (intentions to act)
**Lifecycle:** Items are removed when done or abandoned — completion is the point.

> This file tracks discussion items and deferred work. It is **NOT** session state — session state lives in `SESSION-STATE.md`. Prospective memory that persists across sessions lives here.

## Active (Implement Now/Soon)

- **#1 — PROVE AN ENFORCED HUMAN-APPROVAL ROUND TRIP. Blocks all write work.** Before any
  write tool ships, demonstrate that Claude Desktop/Cowork reaches a human and that absence,
  refusal, cancellation, error or non-response cannot proceed to mutation. Candidate paths
  are measured host `toolPolicy` (#23) and explicitly guarded server elicitation (#24). The
  prior `apple-mail` experiment is not to be repeated as evidence: three independent confounds
  made its null result attribute to nothing (gotcha 83).

- **#26 — journal test isolation. (a) DONE 2026-08-26; (b) still open.**
  **(a) Test isolation — fixed.** `Journal`'s storage location is now an explicit `root:`
  parameter defaulting to `Runtime.stateDirectory`, threaded through `directory`,
  `currentFile`, `recordIntent`, `recordOutcome`, `entries` and `orphanedIntents`. Production
  call sites are unchanged; the tests pass a temporary directory they own and delete.
  Deliberately **not** a settable static — a mutable global redirecting where calendar history
  is written is the shape this project has twice been bitten by. A guard test asserts no
  journal test can resolve a path beneath the real state directory, so dropping the argument
  fails the suite rather than silently writing to the user's home. **Verified: three
  consecutive full runs added zero lines to the live journal** (was ~10 per run).
  **(b) `entries()` still reads and decodes the ENTIRE monthly file on every call**, then
  discards all but `.suffix(limit)`; `orphanedIntents()` does it at `limit: 1000`. Cost grows
  without bound within a month, and this is the read path `calendar_recent_mutations` would
  use. Fix before the journal has a caller.
  Do not delete the live journal as part of a code fix — that is a separate, explicit
  operation, even though inspection found only test output.

- **#24 — Measure server elicitation, then decide whether it replaces or supplements
  `toolPolicy`.** The pinned SDK supports `Server.requestElicitation`, but its validator is a
  no-op under this server's effective default (`strict: false`; gotcha 84). Sequence:
  **(1)** capture the connected client's declared **form** elicitation capability at initialize
  and surface it through `calendar_permission_status`; **(2)** pending human approval to add
  a sixth public tool, run one harmless form-elicitation round trip; **(3)** for future writes,
  explicitly require the needed form capability and refuse on absence, decline, cancellation,
  error or non-response. A declaration is eligibility to try, not proof that a human responded,
  and a successful diagnostic probe is not authorization for a later write.

- **#25 — Verify what this project's OWN governance hook actually enforces.** `CLAUDE.md`
  describes a PreToolUse hook that "BLOCKS Bash/Edit/Write until the required governance tools
  are called" — which is the **same order-gate shape** the `apple-mail` proxy turned out to
  have (gotcha 67): it gates on a call having been *made*, not on the verdict that call
  returned. If so, this project's own enforcement claim ("structural, not advisory") needs the
  same correction I just applied to the sibling's, and `CLAUDE.md` overstates it. Read the hook
  implementation before repeating the claim. Not urgent, but it is a stated control and this
  project has now mis-stated three.

- **#23 — `toolPolicy` has never been set on this machine. Establish whether it works at all
  before designing around it.** Verified 2026-08-22: absent from all nine servers in
  `claude_desktop_config.json`, from `config.json`, and from both August backups. Two
  "measurements" were taken on top of the assumption that it was configured, and both actually
  measured the no-policy default. Sequence: add `toolPolicy` to ONE server entry, restart
  Desktop (stdio servers respawn, but the config is read at launch), call a read tool and a
  write tool, and record what each does. **Choose the write tool so the result attributes:**
  the 2026-08-22 attempt used two tools that never elicit server-side, on a server whose proxy
  only order-gates, with no policy set — three sufficient explanations for one silence
  (gotcha 83). A tool that does NOT elicit is the right probe once the policy IS set, because
  then any prompt is attributable to the host. If the key is silently ignored by the installed
  Desktop version, then the compensating control the whole write design rests on does not
  exist, and the design needs a different one — that is a stop-and-redesign outcome, not a
  detail. Human's call: it is an edit to their host configuration.

- **#2 — If #23 proves `toolPolicy` and the human retains it, configure it per-tool.** There is
  nothing to switch from today. Write tools `"ask"`, read tools
  unlisted. Encodes "never prompt on read, always prompt on write" directly instead of relying
  on `readOnlyHint` overriding a wildcard — a mechanism never confirmed from the minified
  bundle. Backup of `claude_desktop_config.json` already taken.

- **#17 — Restore must ship in the SAME change as delete, never after.** C7 is the primary
  user-facing control now that C1 is withdrawn; shipping the destructive half first leaves a
  window with no way back. Test it end to end against a disposable calendar: create → delete →
  restore → diff every persisted field.

- **#18 — Snapshot must capture every field needed to reconstruct**, not just the DTO's default
  set: `title`, `startDate`, `endDate`, `isAllDay`, `timeZone`, `location`, `notes`, `url`,
  `availability`, `calendar_id`, and the recurrence rule. The read DTO withholds `notes`, `url`
  and `location` unless requested — a snapshot built from it would silently drop them and the
  loss would only appear at restore time, when the original is already gone.
- **#22 — Decide whether an unknown tool should be a JSON-RPC protocol error rather than
  `isError`.** Raised by an independent review (Codex, 2026-08-22), citing the MCP spec, which
  classifies unknown tools as protocol errors and reserves `isError` for validation, API and
  business-logic failures. We return `isError` with `UNKNOWN_TOOL: ... This server provides:
  <list>`. **Not** changed on the spot, because it predates the read-surface work and the
  trade-off is unmeasured: a JSON-RPC error can carry the same message, but hosts surface
  protocol errors differently from tool errors and some may not return the text to the model
  at all — which would cost a caller the list of valid tool names precisely when it has just
  used a wrong one. Settle by checking what Claude Desktop and Claude Code actually show the
  model for each, then pick. Low severity either way.

- **#7 — Third-party attribution file.** If any expression is borrowed from either MIT
  reference repo, add a `NOTICE` / `THIRD-PARTY-NOTICES.md` carrying the original MIT text
  and copyright line, and mark provenance in the borrowing file's header. Not needed if
  only ideas are adopted.

- **#19 — Bound every EventKit operation, and fail fast once wedged.** No call in `CalendarStore` has a
  timeout (gotcha 64). Because the store is a serial actor on one dedicated thread, a single blocked call
  takes the whole calendar surface down for the process's lifetime. A blocking synchronous EventKit call
  **cannot be cancelled**, so the timeout cannot free the thread — the design has to be: bound the
  *caller's* wait (well under the client's 60s ceiling), return a structured `error_type: "timeout"`, then
  **mark the store wedged** so subsequent calls fail immediately with "calendar subsystem is blocked,
  restart the server" instead of each burning another full timeout. Affects shipped read-only code today,
  and gets more dangerous the moment writes exist.

- **#20 — Test the create→delete→restore round trip using only ids the tools themselves return.** Gotcha
  65: a sibling server shipped a create whose returned id its own delete could not consume, and the
  mismatch surfaced as a hang. Our equivalent risk is real and known — `eventIdentifier` changes on sync —
  so the test must construct nothing by hand: create, take the returned id, delete with it, restore with
  what delete returns, then diff every persisted field.

- **#21 — Consider an explicit `security_notice` string alongside `trust: "external_untrusted"`.**
  `apple-mail`'s `search_messages` returns both, and the reviewer singled it out as real
  prompt-injection defence placed at the boundary where untrusted content enters. Our DTOs carry the trust
  marker but no human-readable notice telling the caller what to do with it. Cheap; decide whether the
  marker alone is doing the work.

## Deferred/Future — Discussion

- **#4 — Bulk mutation.** Explicitly out of v1 (decision C5). Revisit only after the
  propose/commit flow (C3) and the reversal journal (C4) are demonstrated working end to
  end, including a real restore exercised against a disposable calendar. Requires its own
  governance evaluation.
- **#5 — Prebuilt binary distribution.** Would require Developer ID signing, hardened
  runtime, and notarization. Not needed for source-only publication. Separate approved
  phase if ever wanted.
- **#6 — Reminders (`EKReminder`) support.** Out of scope for v1; would widen the
  entitlement and tool surface.

## Not this repository's work

- **The `security-scan` skill is broken** — invoking it fails with `command not found: cmd`,
  a malformed shell substitution in the **skill definition**, which lives outside this repo.
  It has never run here; the security coverage to date came from the `security-auditor` agent
  instead. Kept as a note so nobody reaches for the skill again expecting it to work, and
  removed from Active because it is not implementation work for this project. Fixing it means
  editing files this project does not own.

## Closed 2026-08-22

Removed after verifying each against the repository rather than against memory:

| Was | Why it is closed |
|---|---|
| #3 README destructive-capability warning | The README carries it: the warning block, "restore recreates an equivalent event... it is not the original object", and the C6 rationale for why that suffices |
| #9 Does Cowork run locally or remotely | Answered 2026-08-19 and recorded in PROJECT-MEMORY Open Questions #1: locally, inside Claude Desktop on this Mac. It was open in two files with different answers |
| #11 Orphan behaviour under SIGTERM / SIGKILL | Verified and automated — `ServerLifecycleTests` launches the real binary, waits for the disclaimed child, and asserts no survivor under stdin EOF, SIGTERM, and SIGKILL-then-EOF. Mutation-checked: disabling signal forwarding fails the SIGTERM case |
| #12 stdin EOF as unconditional shutdown | Implemented in `ServerBootstrap.run()` and now covered by the same lifecycle test |
| #13 `unsafeFlags` decision | Decided and recorded in PROJECT-MEMORY: accepted, clone-and-build only |
| #15 CI on a macOS runner | `.github/workflows/ci.yml` — build, `./scripts/test.sh`, `bash -n`, shell checks. No signing, keychain, TCC or Calendar access, none of which can work on a hosted runner |
| #16 `security-scan` skill | Routed above as external; not this repo's work |
| #8/#8a attendee-refusal decision and mandatory second-account test | Resolved 2026-08-25 by the C6/C7 amendment (`gov-800ad831a848`): confirmed removal with disclosed uncertainty and a named restorability exception. A second-account test is optional characterization, not a release gate |
| #10 `calshow:` handoff for refused attendee events | Obsolete with the withdrawal of blanket C6 refusal; do not keep infrastructure for a handoff policy no longer adopted |

---

*Convention: items move Active ↔ Deferred as priorities shift. Shipped or migrated items are removed from this file — no redirect stubs (commit history is the record).*
