<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Session State

**Last Updated:** 2026-08-27
**Memory Type:** Working (transient)
**Lifecycle:** Prune at session start per §7.0.4

> CURRENT state only. Decisions → `PROJECT-MEMORY.md` · lessons → `LEARNING-LOG.md` ·
> deferred work → `BACKLOG.md` · recurring commitments → `OPERATIONS.md`.
>
> **Pruned 2026-08-27.** This file had grown to 275 lines, most of it a narrative of the
> 2026-08-22→27 work — history it explicitly says belongs elsewhere. Every fact was checked as
> present in `PROJECT-MEMORY` (gotchas 68–95), `LEARNING-LOG`, or the plan before removal.

---

## Where things stand

- **Phases 1–4 complete**, published, in daily use. **Five read-only tools; no write tool
  exists.** Phase 5 substrate (`Journal.swift`) is built and has no caller.
- **`main` is at `3a7fb8a`, pushed, tree clean, CI green** on a macOS runner.
- **`0.2.0` is installed and verified** at `/usr/local/bin/apple-calendar-mcp`.
- **Nothing is in flight.** The next action belongs to the human (below).

| | |
|---|---|
| Repo | https://github.com/jason21wc/apple-calendar-mcp (public, Apache-2.0) |
| Installed | `/usr/local/bin/apple-calendar-mcp`, root:wheel, **0.2.0**, 2026-08-27 |
| Install verified | signature verifies strictly · `disclaimed-child` · **`fullAccess`** · read-only tool surface. The grant survived the same-path replacement with no `--setup` — gotcha 26 confirmed a second time |
| Tests | `./scripts/test.sh` — green. No count here on purpose; it drifted to four values across four files |
| CI | `.github/workflows/ci.yml` — build, tests, shell checks. No signing, TCC or Calendar; none can work on a hosted runner |
| Tool surface | **5, all read-only** |
| Desktop config | `--read-only` only. **`toolPolicy` is NOT set, and never has been** |
| Controls | C3, C4, C5, **C6 and C7 as amended 2026-08-25**. C1 withdrawn; C2/C2a/C4a superseded |
| Plan | `docs/IMPLEMENTATION-PLAN.md` — repo-canonical. Permission model is §4a |
| Latest governance | `gov-800ad831a848` (PROCEED) — the C6/C7 amendment |

## The decision that governs the write surface

**Decided 2026-08-25 by the human** (`gov-800ad831a848`), replacing C6's blanket refusal:

| Tier | Covers |
|---|---|
| **Silent** | All reads. Shipped |
| **Confirm** | **Every write** — create, update, delete, restore — including group events and shared/network calendars |
| **Refuse** | Only what EventKit cannot express or the tool cannot bound: setting `attendees`, setting RSVP status, bulk deletion, `futureEvents` deletion while restoration is unsolved |

Removing an event with attendees is permitted behind a confirmation that says plainly it
removes through EventKit, may notify participants, and cannot restore invitation state. The
operation is called **remove** and is never presented as Calendar.app's Decline. C7 carries a
named exception: attendee state is unrestorable, recovery is social.

**This authorizes the policy, not the shipping of writes.** The Confirm tier has no verified
mechanism. Nothing mutating may ship until an approval round trip is demonstrated.

## Next actions, in order

1. **HUMAN — read `calendar_permission_status` from Cowork** and report
   `client.elicitation_form_supported`. Restart/reconnect Cowork first so it picks up 0.2.0.
   **`true`** → Desktop claims it can put a question to a human; the Confirm tier has a
   candidate and #24b becomes worth designing. **`false`** → server elicitation is closed for
   Cowork and `toolPolicy` (#23) is the only remaining candidate. Either answer is progress.
   *A declaration establishes eligibility to try, never that a human is reachable.*
2. **BACKLOG #19** — bound EventKit operations, fail fast once wedged. Architecture-bearing:
   plan it, contrarian-review it, then build. A live defect in shipped read-only code, and the
   design precedent for the elicitation wait.
3. **#27** — escape control characters in `log()` before any mutating code logs.
4. **#24b** — the live elicitation round trip, only after timeout and abandoned-request
   cleanup are designed. Same policy problem as #19, different cleanup problem.
5. **Build order when unblocked:** `calendar_create_event` → `calendar_delete_event` **with
   restore in the same change** → `calendar_update_event`.

## Blocked on the human

| # | Decision |
|---|---|
| **1** | **Demonstrate an enforced human-approval round trip.** Blocks every write tool. Two candidates: server elicitation (#24a measured, #24b unbuilt) and host `toolPolicy` (#23, never configured). Do not re-run the `apple-mail` experiment — three independent confounds made its null result attribute to nothing (gotcha 83) |
| 2 | Whether to prune the live journal — 571 lines, all test output. A deliberate operation, not a code fix |

## Not measured — do not assume

- **Whether any client actually prompts for a write.** Both candidate mechanisms are unproven.
- The §5 concurrency criterion (500-event fetch vs a concurrent `tools/list`) — needs a
  populated real calendar.
- What `removeEvent` does to an invited event over CalDAV. Optional characterisation since the
  C6 amendment, not a release gate.
- The CLOEXEC exemption; macOS 14.0–26.4 permission behaviour.

## Resuming after a restart

1. `AGENTS.md` → `PROJECT-MEMORY.md` (controls, gotchas 1–95) → `docs/IMPLEMENTATION-PLAN.md`.
2. `./scripts/test.sh` for a known-good baseline. Never plain `swift test`.
3. Start at **Next action 1** if the human is present, otherwise **#19**.

## Security posture

The stale `.build` Calendar grant is **revoked** (`auth_value 0`) and that deny row must stay —
removing it would let a user-writable path be re-granted. `/usr/local/bin/apple-calendar-mcp`
holds the only live grant. **Never grant Calendar access to a binary under `.build`.**

System Settings shows the display name only, so two grants for one binary at different paths
look identical; distinguish via `TCC.db` (`tccutil` cannot target either — gotcha 32).

The journal and snapshots are **same-uid writable** — reductions, not boundaries. With
`toolPolicy` unset there is currently **no host-level gate on writes for any MCP server on this
machine**, which is why the write surface stays blocked rather than merely careful.

**Unrelated to this project, still true:** a plaintext iCloud app-specific password sits in
`claude_desktop_config.json` under `apple-mail` → `APPLE_MAIL_MCP_IMAP_PASSWORD_ICLOUD`.

## Phase results (condensed)

**Phase 1** — passed only after an architecture change: a signed binary got no TCC identity of
its own, and an `.app` wrapper did not fix it. The **self-disclaiming re-exec** did.

**Phase 2** — command dispatch, embedded plist, honest exit codes.

**Phase 3** — five authorization states, `TCCInspector`, `Doctor`, `SetupFlow`. `--setup`
refuses to run under inherited identity, structurally preventing the Phase 1 failure.

**Phase 4** — shipped, failed in real use, was fixed, then audited. Twelve false contract
claims found by reading each tool's promises against its implementation; all fixed with
synthetic tests. The orphan exit criterion, open for three phases, is met. See plan §5.

**Phase 5** — `Journal.swift` only. Write-ahead, concurrency-safe, test-isolated. No caller.
