<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Session State

**Last Updated:** 2026-08-20
**Memory Type:** Working (transient)
**Lifecycle:** Prune at session start per §7.0.4

> This file tracks CURRENT work state only.
> Historical information → PROJECT-MEMORY.md (decisions) or LEARNING-LOG.md (lessons)

---

## Current Position

- **Phase:** Phases 1–4 complete, published, in daily use. Phase 5 substrate (`Journal.swift`)
  built. **Next work is the write surface**, redesigned this session.
- **Mode:** Standard
- **Repo:** https://github.com/jason21wc/apple-calendar-mcp (public, Apache-2.0)
- **Active Task:** None in flight. Next code is `calendar_create_event` — but see
  **Blocked On #1**, a two-minute human check that gates it.

## Quick Reference

| Metric | Value |
|--------|-------|
| Project | **apple-calendar-mcp** |
| Installed at | `/usr/local/bin/apple-calendar-mcp` (root:wheel), granted, `--doctor` clean |
| Tests | **99 passing** via `./scripts/test.sh` |
| Tool surface | **5, all read-only.** No write tool exists yet |
| Desktop config | `--read-only`, `toolPolicy: {"*": "ask"}` (backup taken before edit) |
| Containment controls | C3, C4, C5, C6, **C7 (new)**. C1 withdrawn; C2/C2a/C4a superseded |
| Governance audits | 6 logged; latest `gov-120ca260c415` (REVIEW, no veto) |
| Plan | **rev. 6** — §4, §6, §13 rewritten 2026-08-20 |

## What changed this session — the write design was reframed twice

Both changes came from the human, and both **removed** design surface rather than adding it.

### 1. Reads must never prompt; writes must always prompt

Confirmed working: a read query in Cowork returned results with no approval prompt.
`readOnlyHint: true` is doing that. What is **not yet confirmed** is that a write tool *does*
prompt under the same config — see Blocked On #1.

### 2. "Full ability to revert" was a symptom, not a specification

> *"I don't specifically need it to 'revert'. I need to be able to put things back the way it
> was, but it doesn't have to be the exact calendar event — it can be a new one with all the
> same info."*

This dissolved the problem three previous designs died on. Every blocker — `eventIdentifier`
changing on sync, invitation state being unrecoverable, series membership being unrestorable —
exists **only** if restoration must return the original object. It does not have to.

**And the boundary was already drawn.** Attendees are the single field a snapshot cannot
reproduce (`readonly` in EventKit), and **C6 already refuses to touch events with attendees**.
So the set of events this tool may delete is exactly the set it can fully put back. Two
constraints drawn for unrelated reasons landed on the same line.

Recorded as **C7** in PROJECT-MEMORY, replacing C2/C2a/C4a.

### 3. C1 (writable-calendar allowlist) withdrawn — and it was a live defect, not just a decision

Human's decision, governance-evaluated (`gov-120ca260c415`, REVIEW, no S-Series veto).
Writable now means whatever EventKit reports via `allowsContentModifications` — including
calendars shared with the user later, with no config change. Their reasoning: the OS already
decides what they may write to, and a second gate only this tool honours adds friction without
changing who can reach the data.

**This also kills the `source_type == .local` guard** proposed earlier the same day. Its whole
rationale was CalDAV propagation on shared calendars — which is now explicitly wanted.

**Grepping before recording the reversal found the allowlist live in shipped code.** It decided
`calendar_list_calendars`'s `writable` flag, defaulted to empty, and failed closed — so with no
config file present (this machine included) **every calendar was reported `writable: false`,
reason "not in the allowlist"**. `Allowlist.swift` is deleted; `writable` is now
`allowsContentModifications` alone. Four regression tests added, including one asserting no
refusal string mentions an allowlist — the reason text is user-facing, and a stale one sends
someone hunting for a config file that no longer exists. **Not yet verified live:** the
installed binary at `/usr/local/bin` still predates this fix (see Next Actions).

The governance evaluation surfaced `acct-ledger-integrity-le2-audit-trail-immutability`, and it
is the right frame for C7: *corrections are made through reversing entries, never by editing or
deleting the original record.* Restoration is a **new forward operation that references the
original journal entry**, not a rollback.

## Blocked On (human decisions)

| # | Decision | Blocks |
|---|---|---|
| **1** | **Does a WRITE tool actually prompt?** Ask Cowork to *draft* (not send) an email. `apple-mail`'s `create_draft` is installed and its proxy auto-approves only read tools. Report whether it prompted. ~2 minutes, no new code, nothing created but a deletable draft. | Everything below |
| 2 | Does Cowork run locally or remotely? | Whether restore needs to be model-callable at all |
| 3 | Confirm C6 formally, and verify in Phase 6 that deleting an invited event really does notify the organizer | README wording |

## Next Actions

1. **Reinstall so the writability fix is live** — the granted binary still reports every
   calendar as non-writable:
   `swift build -c release && ./scripts/sign.sh && sudo cp .build/release/apple-calendar-mcp /usr/local/bin/apple-calendar-mcp`
   Sign **before** copying: `cp` preserves signatures, so signing after installing signs the
   wrong file. Then ask Cowork to list calendars and confirm `writable: true` on yours.
2. **Blocked on #1.** Nothing else should be built until it is answered — a write tool that
   does not prompt fails the human's stated requirement outright.
3. **Switch `toolPolicy` from `{"*": "ask"}` to per-tool.** Write tools `"ask"`; read tools
   left unlisted so they stay silent. Encodes the requirement exactly rather than by side
   effect, and removes the open question of whether the `*` wildcard was even honoured.
4. **Build in this order:** `calendar_create_event` → `calendar_delete_event` **with restore in
   the same change** → `calendar_update_event`. Delete must never ship before its restore path.
5. **Re-run the §6 gates** — items 1, 3, 4, 5 still apply; item 2 (`source_type`) is withdrawn.

## Plan of Record

**`docs/IMPLEMENTATION-PLAN.md`** — **rev. 6**, §4/§6/§13 rewritten 2026-08-20. It is a **copy**
of `~/.claude/plans/proceed-with-writing-the-linear-iverson.md`; replace it from there on every
revision (a stale rev. 3 copy was once live while `OPERATIONS.md` named it authoritative).

## Resuming After a Restart

1. Read `AGENTS.md` → `_ai-context/PROJECT-MEMORY.md` (controls, 63 gotchas, the human's stated
   requirements table) → `docs/IMPLEMENTATION-PLAN.md` §6.
2. Phases 1–4 are built, tested, published and in daily use. The journal is built.
3. **Start at Blocked On #1.** It is the only thing in the way.

## Security Posture

The stale `.build` Calendar grant is **revoked** (`auth_value 0`) and that deny row must stay —
removing it would let a user-writable path be re-granted. `/usr/local/bin/apple-calendar-mcp`
holds the only live grant. Never grant Calendar access to a binary under `.build`.

System Settings shows the display name only, so two grants for the same binary at different
paths look identical; distinguish via `TCC.db` (`tccutil` cannot target either — gotcha 32).

**Unrelated to this project, still true:** a plaintext iCloud app-specific password sits in
`claude_desktop_config.json` under `apple-mail` → `APPLE_MAIL_MCP_IMAP_PASSWORD_ICLOUD`. Raised;
the human has scoped Apple Mail and QuickBooks guardrails to their own projects.

The allowlist is gone, but the journal and snapshots remain **same-uid writable** — reductions,
not boundaries. `toolPolicy` is the one control in this project the model cannot reach, because
it is enforced in the host process.

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

**Phase 4 — passed, then failed in real use, then fixed.** Five read tools shipped with every
event tool returning numbers where its own schema promised strings — Swift encodes `Date` as
seconds since 2001, and the SDK validates `structuredContent` in memory before serialization.
DTOs now carry pre-formatted RFC 3339 strings; 6 schema-conformance tests added with a positive
control. A second real-use report found timestamps pinned to `Z`: `ISO8601DateFormatter` defaults
to GMT, and `TimeZone.current` is a snapshot that would keep the departure city's offset after a
flight. Now `autoupdatingCurrent` with an explicit formatter zone, so travel adjusts by itself.

**Verified 2026-08-20:** the disclaim works under a real MCP client. Claude Desktop ships its own
Anthropic-signed `disclaimer` helper using the same private API (gotcha 44), so it had already
made us self-responsible and our re-exec correctly idled.
