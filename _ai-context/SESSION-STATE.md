<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Session State

**Last Updated:** 2026-08-24
**Memory Type:** Working (transient)
**Lifecycle:** Prune at session start per §7.0.4

> This file tracks CURRENT work state only.
> Historical information → PROJECT-MEMORY.md (decisions) or LEARNING-LOG.md (lessons)

---

## Current Position

- **Phase:** Phases 1–4 complete, published, in daily use. **Five read-only tools shipped; no
  write tool exists.** Phase 5 substrate (`Journal.swift`) built, with no caller.
- **Mode:** Standard
- **Repo:** https://github.com/jason21wc/apple-calendar-mcp (public, Apache-2.0)
- **Active Task:** C6/C7 attendee-deletion policy reconsideration. The human's current leaning
  is that blanket refusal and a mandatory second-account test are stricter than needed, but no
  containment amendment is final yet.
- **Next code:** **BACKLOG #26** — isolate `JournalTests` from the live state directory before
  trusting another suite result. Then **BACKLOG #19** — bound EventKit operations, fail fast once wedged. A live
  defect in shipped read-only code, independent of the write blocker. It touches
  `DedicatedThreadExecutor` / `CalendarStore`, so plan it and get a contrarian review first.
- **After that:** `calendar_create_event`, gated on **Blocked On #1**.

## Quick Reference

| Metric | Value |
|--------|-------|
| Project | **apple-calendar-mcp** |
| Installed at | `/usr/local/bin/apple-calendar-mcp` (root:wheel), granted, `--doctor` clean |
| Install verified | **2026-08-20 18:33** — cdhash matched the signed build. **The installed binary now predates the 2026-08-22 read-surface fixes**; reinstall before relying on them in a client |
| Tests | **Baseline not trustworthy until BACKLOG #26 is fixed.** `JournalTests` writes to the live state directory and contains an unsynchronized corrupt-line fixture. No count recorded here on purpose |
| Tool surface | **5, all read-only.** No write tool exists |
| Desktop config | `--read-only` only. **`toolPolicy` is NOT set — for any server, and never was.** Verified 2026-08-22 against the live config, `config.json`, and both August backups. The previous entry here claimed it was configured; that was false when written |
| Containment controls | C3, C4, C5, C6, **C7**. C1 withdrawn; C2/C2a/C4a superseded |
| Latest governance | `gov-d463782d41dd` (REVIEW, no S-Series trigger) — evidence-layer and test-isolation corrections |
| Plan | `docs/IMPLEMENTATION-PLAN.md` — **now canonical and repo-owned.** The revision number lives in the plan itself and is not restated here |
| CI | `.github/workflows/ci.yml` — macOS runner, build + tests + shell checks, **no signing** |

## What changed 2026-08-22 — drift fixed at the cause, and the read contract audited

### 1. The plan is no longer a copy of a file outside the repository

It was a copy of a private plan, to be re-copied on every revision — and it failed exactly as
designed to: a stale rev. 3 copy sat in the repo while `OPERATIONS.md` named it authoritative.
`docs/IMPLEMENTATION-PLAN.md` is now the original. Every other document summarises or links to
it instead of restating volatile detail.

### 2. Volatile counts are gone from durable documents

The passing-test count had been written into four files and had drifted to four different
numbers. Durable docs now say "`./scripts/test.sh` is green". The tool count is asserted in
the suite (`ToolRegistry.all().count == 5`) rather than repeated in prose.

### 3. False claims in the SHIPPED read surface, found by audit and fixed

Not one of these came from a bug report — they came from reading each tool's contract against
its implementation. All are fixed, with synthetic tests that need no Calendar grant. The full
table is in plan §5:

- `calendar_permission_status` and `calendar_list_calendars` returned `structuredContent` with
  **no `outputSchema`** at all.
- `limits_applied` was **emitted and declared nowhere**, so the conformance suite skipped it —
  and it reported the hard ceiling (500) as the limit in force (100).
- `effective_time_zone` named the **caller's** zone while timestamps rendered in the machine's.
  Now one zone per request renders every timestamp and is what gets reported.
- `calendar_find_events` filtered only the **first 500 events**, so `total_matched` counted
  matches within a page and a real match at position 501 came back as *no matching events*.
- `calendar_list_calendars` returned calendar and source titles — attacker-influenceable —
  without `openWorldHint`.
- Failures carried prose and **no stable code**. Eight `UPPER_SNAKE` codes now lead every error.
- An unknown tool name returned **`PERMISSION_DENIED`** on a machine without a grant, because
  the access gate ran before the name check.

### 4. The Phase 4 orphan gate is met, after three phases open

`ServerLifecycleTests` launches the real binary, waits for the disclaimed child, and asserts no
survivor under stdin EOF, SIGTERM, and SIGKILL-then-EOF. It was never hard — it needed a
command that stays up, and every earlier subprocess test used `--version`. Mutation-checked:
disabling signal forwarding fails the SIGTERM case and leaves the other two passing.

### 5. A fresh-context coherence audit then found four more, and they were the worse ones

Run after the fixes above, by a subagent with no session context. All 21 findings were verified
independently against source and accepted; all are fixed. The four that mattered:

- The plan tabulated **C3–C6 as "Live"** while the server has no mutation path for any of them
  to gate, and `ARCHITECTURE.md` republished it. They are **adopted, not enforced**.
- **`--doctor` printed "tool surface: read and write"** on a build with no write tool, because
  it keyed off `--read-only` rather than off what is compiled in.
- **`CalendarScope.unmatchedIds`** was computed, tested, documented as "reported rather than
  swallowed" — and discarded by the adapter. A stale calendar id therefore returned an empty
  result indistinguishable from an empty week. Now surfaced as `unmatched_calendar_ids`.
- The **README said deleted events "can be recreated"** from the journal, present tense, in the
  paragraph that softens the deletion warning. Nothing can: the journal has no caller.

Also fixed: two superseded gotchas (16, 20) that contradicted later ones without a label, four
wrong section cross-references, the stale `Package.swift` testability comment, `main.swift`'s
"this is NOT the MCP server" header, and `--read-only` / `toolPolicy` being undocumented in the
README for a public repo.

### 6. An independent Codex review then found the search fix was bounded in the wrong dimension

- **The 31-day window bounds time, not count.** `eventsMatchingPredicate` returns an array, so
  EventKit always materialised every matching event; my change added a DTO per event on top.
  Fixed by ordering, not by a ceiling: `CalendarStore.searchEvents` now matches on the
  `EKEvent` and converts only the returned page. `redact()` became dead and was deleted —
  withholding is now structural rather than a pass that could be forgotten.
- **`occurrence_date` had become a zone-dependent key.** It is half of the
  `(eventIdentifier, occurrenceDate)` addressing key, and I had it following the caller's
  display zone. Now always UTC; `start`/`end` still follow `effective_time_zone`.
- **The interval cap truncated**, so 31.9 days passed a 31-day limit. Now compares seconds.
- **Bumped to 0.2.0** with a compatibility table in the README. The wire changes are not all
  purely additive: `time_zone` now governs every timestamp, and `limits_applied` changed shape.
- Declined, with reasons recorded: Codex's streaming `enumerateEventsMatchingPredicate` plus a
  `SEARCH_SCOPE_TOO_DENSE` error. The ordering fix removes the cost it was designed to bound
  without adding a new failure mode to the shipped surface. Its unknown-tool spec point is
  **BACKLOG #22**, not silently applied.

Codex could not run `./scripts/test.sh` (its toolchain reported Swift 6.3.3 against a 6.3.2
SDK), so its review is source-reasoning only. The suite runs clean here.

## Blocked On (human decisions)

| # | Decision | Blocks |
|---|---|---|
| **1** | **Demonstrate a real human-approval round trip in Claude Desktop/Cowork through an enforced mechanism before any write tool ships.** Candidate paths are measured host `toolPolicy` or explicitly guarded server elicitation; neither is proven today. The two prior experiments each measured the wrong layer (gotcha 83). | All write work |
| 2 | Confirm C6 formally, and verify in Phase 6 that deleting an invited event really notifies the organizer | README wording |

## The 2026-08-22 write-prompt result, and what it actually established

The human ran `apple-mail`'s `create_draft` twice and `delete_draft` once in Cowork. **No
approval prompt appeared.** Before recording that as the answer to Blocked On #1, the config
was checked — and `toolPolicy` is absent from all nine servers, from `config.json`, and from
both August backups taken during this project's own work. It has never been set here.

**So the gating question is still open**, and something worse is now known:

- **With no `toolPolicy`, there is no host-level gate on writes for any MCP server on this
  machine.** A mutating tool and a destructive tool both ran unprompted.
- `apple-mail` runs behind a governance proxy whose `--always-allow` list contains read tools
  only, so `create_draft` and `delete_draft` were **not** proxy-allowlisted — and executed
  anyway. The only thing between an injected instruction and a mutation was a model-reachable
  layer, which is the one already recorded as waving itself through an ESCALATE (gotcha 67).
- Gotcha 61 ("reads do not prompt even with `toolPolicy` set") is **retracted**: it measured
  the same absent control.

**This is the third control recorded as live while it was not** — after the C1 allowlist
deciding a shipped tool's `writable` flag while unconfigured, and C3–C6 tabulated "Live" with
no mutation path to gate. See gotcha 81.

**The `apple-mail` maintainers answered, and refuted the annotation hypothesis while supplying
a third confound.** Their write tools declare `readOnlyHint: false` and their deletes
`destructiveHint: true` — a host has everything it needs to classify them. But:

- Their governance proxy **consumes no verdict**. `--govern-all` checks whether
  `evaluate_governance` was called within a TTL and forwards if so. PROCEED/REVIEW/ESCALATE are
  advisory text nothing reads. There is no state in which an ESCALATE blocks a call. Gotcha 67
  is corrected accordingly — the model does not *bypass* the verdict; nothing consumes it.
- **The two tools tested never ask.** `create_draft` elicits only when `send_now=True`;
  `delete_draft` deliberately has no elicitation ("recoverable from Trash").

So the silence had three sufficient explanations and attributes to none (gotcha 83).

**The useful consequence: elicitation is a control we may be able to own.** The pinned SDK
0.12.1 exposes `Server.requestElicitation`, but its capability validator runs only in strict
mode; strict defaults false and this server supplies no strict configuration. Any future
mutation path must check the required client capability itself and refuse when absent.
Whether Desktop/Cowork declares the capability or completes a real round trip is unmeasured.
See **BACKLOG #24**.

## Next Actions

1. **Report Desktop/Cowork's declared elicitation sub-capabilities** through the existing
   permission-status surface (BACKLOG #24). If the human approves expanding the public tool
   surface, then add a harmless elicitation round-trip probe. Only after both measurements
   decide whether elicitation replaces or supplements `toolPolicy`.
2. **Set `toolPolicy` on one server and re-run the write test** (BACKLOG #23 — human's call,
   config edit). Until the key exists there is nothing to measure. Pick a probe tool that does
   NOT elicit server-side, so any prompt attributes to the host.
3. **Reinstall the signed binary** if the read-surface fixes should be live in clients — the
   copy at `/usr/local/bin` predates them. `./scripts/sign.sh`, then `sudo cp`, then verify
   with `codesign --verify --strict`. **No new grant is needed**: same path, and the
   designated requirement is identity-based.
4. **BACKLOG #19** — bound EventKit operations, fail fast once wedged. Architecture-bearing:
   plan it, contrarian-review it, then build.
5. **Blocked On #1** before any write tool.
6. If #23 proves host policy and the human retains it, move to per-tool `toolPolicy`
   (BACKLOG #2): writes `"ask"`, reads unlisted.
7. **Build order:** `calendar_create_event` → `calendar_delete_event` **with restore in the
   same change** → `calendar_update_event`.

## Not measured, and not to be assumed

- The §5 concurrency criterion (a 500-event fetch not delaying a concurrent `tools/list` by
  250 ms) needs a populated real calendar. **Unmeasured.**
- The CLOEXEC exemption is still not directly observed.
- macOS 14.0–26.4 permission behaviour is unverified; only 26.5 has been exercised.

## Open item belonging to the human, not to this repo

**A test draft is still sitting in iCloud Drafts** — subject "Test draft from apple-mail MCP",
addressed to the author's own iCloud address. `apple-mail`'s `delete_draft` hung twice and
never removed it. Needs deleting by hand in Mail.app. Nothing in this project can clear it.

(The address itself is not repeated here: `_ai-context/` ships with a public repository, and
`OPERATIONS.md` commits to sweeping personal addresses out of tracked files before every push.
It was committed once, in 934f7a8, so it is already in the public history — removing it here
stops it spreading, and only a history rewrite would remove it retroactively.)

## Resuming After a Restart

1. Read `AGENTS.md` → `_ai-context/PROJECT-MEMORY.md` (controls, gotcha table, the human's
   stated requirements) → `docs/IMPLEMENTATION-PLAN.md`.
2. Run `./scripts/test.sh` for a known-good baseline.
3. The read surface is shipped and audited. **Start at BACKLOG #19**, or at Blocked On #1 if
   the write path is what matters this session.

## Security Posture

The stale `.build` Calendar grant is **revoked** (`auth_value 0`) and that deny row must stay —
removing it would let a user-writable path be re-granted. `/usr/local/bin/apple-calendar-mcp`
holds the only live grant. Never grant Calendar access to a binary under `.build`.

System Settings shows the display name only, so two grants for the same binary at different
paths look identical; distinguish via `TCC.db` (`tccutil` cannot target either — gotcha 32).

**Unrelated to this project, still true:** a plaintext iCloud app-specific password sits in
`claude_desktop_config.json` under `apple-mail` → `APPLE_MAIL_MCP_IMAP_PASSWORD_ICLOUD`. Raised;
the human has scoped Apple Mail and QuickBooks guardrails to their own projects.

The journal and snapshots are **same-uid writable** — reductions, not boundaries. A configured
and verified host `toolPolicy` would be outside the model's reach because it is enforced in the
host process; no such policy is configured today.

## Phase Results (condensed)

**Phase 1 — passed only after an architecture change.** A correctly signed binary got no TCC
identity of its own; a signed `.app` wrapper did not fix it. Fix: **self-disclaiming re-exec**
(`Reexec.swift`). Grant survives rebuild at the same path (identity-based requirement); grant is
lost if the path changes (`client_type=1`).

**Phase 2 — passed.** Command dispatch, metadata from the embedded Info.plist, honest exit codes.

**Phase 3 — passed.** Five authorization states, `TCCInspector`, `Doctor`, `SetupFlow`. `--setup`
refuses to run under inherited identity, structurally preventing the Phase 1 failure. `--doctor`
proves ownership with no privilege: a disclaimed process sees only its own grant, so
`disclaimed-child` + `fullAccess` **is** the proof (gotchas 28–29).

**Phase 4 — passed, then failed in real use, then fixed, then audited.** Five read tools shipped
with every event tool returning numbers where its own schema promised strings (gotcha 46); DTOs
now carry pre-formatted RFC 3339 strings. A second real-use report found timestamps pinned to
`Z`; now `autoupdatingCurrent` with an explicit formatter zone. The 2026-08-22 contract audit
found seven further false claims — all fixed, and the orphan exit criterion finally met.

**Verified 2026-08-20:** the disclaim works under a real MCP client. Claude Desktop ships its own
Anthropic-signed `disclaimer` helper using the same private API (gotcha 44), so it had already
made us self-responsible and our re-exec correctly idled.
