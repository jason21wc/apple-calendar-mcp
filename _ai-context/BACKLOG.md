<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Backlog

**Memory Type:** Prospective (intentions to act)
**Lifecycle:** Items are removed when done or abandoned — completion is the point.

> This file tracks discussion items and deferred work. It is **NOT** session state — session state lives in `SESSION-STATE.md`. Prospective memory that persists across sessions lives here.

## Active (Implement Now/Soon)

- **#3 — README destructive-capability warning.** Must state plainly: the server can delete
  calendar events; restore is *recreate an equivalent event*, not true undo; event
  identifiers and invitation state (organizer, attendee list, RSVP responses) do not
  survive a restore. A license warranty disclaimer is not a substitute for this.

- **#8 — Confirm C6 (attendee refusal) formally**, and verify the premise in Phase 6 with a
  second account: does deleting an invited event actually send a decline to the organizer
  and attendees? The refusal is cheap enough to keep either way, but the README rationale
  should not state an unverified claim as fact.
- **#9 — Answer whether Cowork runs locally or remotely** before Phase 5. A remote sandbox
  cannot reach a local `EKEventStore`, which would undo the justification for keeping undo
  model-callable and let several guards be dropped.
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

- **#14 — Update README when `--grant` becomes `--setup` in Phase 3.** The README documents
  `--grant` today, which is accurate but will go stale the moment the command is renamed.
  A published README describing a flag that no longer exists is worse than no README.

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
