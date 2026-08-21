<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Backlog

**Memory Type:** Prospective (intentions to act)
**Lifecycle:** Items are removed when done or abandoned — completion is the point.

> This file tracks discussion items and deferred work. It is **NOT** session state — session state lives in `SESSION-STATE.md`. Prospective memory that persists across sessions lives here.

## Active (Implement Now/Soon)

- **#1 — CONFIRM WRITES PROMPT. Blocks all write work.** Ask Cowork to *draft* (not send) an
  email via `apple-mail`'s `create_draft`; its proxy auto-approves only read tools. If no
  prompt appears, the human's stated requirement is unmet and no write tool should be built
  until a mechanism that does prompt is found. ~2 minutes, no new code.

- **#2 — Switch `toolPolicy` from `{"*": "ask"}` to per-tool.** Write tools `"ask"`, read tools
  unlisted. Encodes "never prompt on read, always prompt on write" directly instead of relying
  on `readOnlyHint` overriding a wildcard — a mechanism never confirmed from the minified
  bundle. Backup of `claude_desktop_config.json` already taken.

- **#3 — README destructive-capability warning.** Must state plainly: the server can delete
  calendar events; restore **recreates an equivalent event with the same information — it is
  not the original object**, and the event identifier will differ. Say why that is sufficient:
  the only field a snapshot cannot reproduce is `attendees`, and C6 refuses those events
  outright, so nothing this tool can delete is anything it cannot put back. A license warranty
  disclaimer is not a substitute for this.

- **#8 — Confirm C6 (attendee refusal) formally**, and verify the premise in Phase 6 with a
  second account: does deleting an invited event actually send a decline to the organizer
  and attendees? The refusal is cheap enough to keep either way, but the README rationale
  should not state an unverified claim as fact.
- **#9 — Answer whether Cowork runs locally or remotely.** A remote sandbox cannot reach a
  local `EKEventStore`, which would undo the justification for keeping restore model-callable.

- **#17 — Restore must ship in the SAME change as delete, never after.** C7 is the primary
  user-facing control now that C1 is withdrawn; shipping the destructive half first leaves a
  window with no way back. Test it end to end against a disposable calendar: create → delete →
  restore → diff every persisted field.

- **#18 — Snapshot must capture every field needed to reconstruct**, not just the DTO's default
  set: `title`, `startDate`, `endDate`, `isAllDay`, `timeZone`, `location`, `notes`, `url`,
  `availability`, `calendar_id`, and the recurrence rule. The read DTO withholds `notes`, `url`
  and `location` unless requested — a snapshot built from it would silently drop them and the
  loss would only appear at restore time, when the original is already gone.
- **#10 — Verify `calshow:` opens Calendar.app at a date.** If it works, the C6 refusal can
  hand the user a clickable jump instead of just coordinates.
- **#7 — Third-party attribution file.** If any expression is borrowed from either MIT
  reference repo, add a `NOTICE` / `THIRD-PARTY-NOTICES.md` carrying the original MIT text
  and copyright line, and mark provenance in the borrowing file's header. Not needed if
  only ideas are adopted.

- **#11 — Verify supervisor/child orphan behaviour under SIGTERM and SIGKILL.** Signal
  forwarding is implemented in `Reexec.swift` but **could not be empirically confirmed** —
  the probe exits in milliseconds, so there is no live child to observe. Requires a
  long-running process, so test in **Phase 4** when the server loop exists: `kill -TERM` and `kill -KILL` the supervisor, then
  check with `ps -o pid,ppid,pgid` that no child survives holding the client's stdout pipe.
  A surviving orphan means a Calendar-authorized process the client thinks is dead.
- **#12 — The Phase 4 server loop MUST treat stdin EOF as unconditional shutdown.** This is the
  only defence against the SIGKILL case, which no signal handler can cover: stdin is
  inherited directly, so the client's pipe closure reaches the child even when the
  supervisor is already gone.
- **#13 — Decide whether `unsafeFlags` in `Package.swift` is acceptable.** SwiftPM refuses
  to resolve any package using `unsafeFlags` as a *dependency*, so this repo can never be
  consumed via `.package(url:)` — clone-and-build only. Fine if that is the intended
  distribution, but it should be a stated decision, and the `-sectcreate` path is relative
  to the invoker's cwd so builds must run from the package root.

- **#15 — CI on a macOS runner, once tests exist.** GitHub Actions running `swift build`,
  `swift test`, `bash -n` on every script, and a grep gate for the recurring traps
  (unguarded `| grep -q` under `pipefail`, unpinned PATH in scripts that invoke `codesign`
  or `security`). Every defect found so far was caught by a human or an agent reading code;
  none by automation. Signing and Calendar access cannot run in CI, so the matrix stops at
  "builds, unit-tests pass, scripts parse".
- **#16 — The `security-scan` skill is broken.** Invoking it fails with
  `command not found: cmd` — a malformed shell substitution in the skill definition, not in
  this project. It has never actually run here; the security coverage to date came from the
  `security-auditor` agent instead. Either repair the skill or stop reaching for it.

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

---

*Convention: items move Active ↔ Deferred as priorities shift. Shipped or migrated items are removed from this file — no redirect stubs (commit history is the record).*
