<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Session State

**Last Updated:** 2026-08-17
**Memory Type:** Working (transient)
**Lifecycle:** Prune at session start per §7.0.4

> This file tracks CURRENT work state only.
> Historical information → PROJECT-MEMORY.md (decisions) or LEARNING-LOG.md (lessons)

---

## Current Position

- **Phase:** **Phase 1 COMPLETE (gate passed after a design change).** Ready for Phase 2.
- **Mode:** Standard
- **Active Task:** None in flight.

## Quick Reference

| Metric | Value |
|--------|-------|
| Project | **apple-calendar-mcp** |
| Code written | Phase 1 probe + `Reexec.swift` + 3 scripts |
| Builds | Clean, no warnings |
| Signed | Yes — stable self-signed cert, entitlement, hardened runtime |
| TCC identity | **Own row confirmed** (path-keyed) |
| Plan | rev. 3, approved 2026-08-18 |
| Containment controls | C1-C6 (C6 pending confirmation) |
| Governance audits | 5 logged; latest `gov-f551d84f9142` |
| Tool surface | 14 (6 read, 4 propose, 4 commit) |

## Phase 1 Result — gate PASSED, but only after an architecture change

The original design **failed** the gate: a correctly signed binary (embedded Info.plist,
calendars entitlement, hardened runtime, stable cert) still got **no TCC identity of its
own**. Granting from a terminal created a TCC row for **that terminal app** and zero rows
for us; the binary reported `fullAccess` purely by inheritance. A signed `.app` wrapper —
the plan's designated fallback — **did not fix it either**.

Fix adopted: **self-disclaiming re-exec** (`Sources/apple-calendar-mcp/Reexec.swift`). The
process re-spawns itself once with the private `responsibility_spawnattrs_setdisclaim`
attribute, making the child its own responsible process. Verified end to end.

| Check | Result |
|---|---|
| `__TEXT,__info_plist` embedded via `sectcreate` | Works — runtime reads its own bundle id |
| Signed: identity + entitlement + hardened runtime | `Authority=apple-calendar-mcp local signing`, `flags=0x10000(runtime)` |
| Status before disclaim | `fullAccess` — inherited from the host terminal, misleading |
| Status after disclaim | `notDetermined` — our own identity |
| Grant under disclaim | **TCC row created for our binary** |
| Rebuild, same path, new cdhash | Grant **survives** (identity-based designated requirement) |
| Same binary, different path | Grant **lost** (`client_type=1`, path-keyed) |

Binary currently granted at `<repo>/.build/arm64-apple-macosx/release/apple-calendar-mcp`.
**Installing elsewhere will require a fresh `--setup` at the final path.**

## Carry Into Phase 2

- `--setup` must run at the **final installed path**, never from `.build`.
- Client configs must name that exact absolute path.
- `--doctor` must report: disclaim mode active vs inherited, whether a TCC row exists for
  our own path (read `TCC.db`, not `authorizationStatus` — status cannot tell them apart),
  and say plainly when the grant belongs to a different path.
- Signing needs one interactive keychain setup per machine before it works unattended.

## Blocked On (human decisions)

| # | Decision | Blocks |
|---|---|---|
| ~~1~~ | ~~Bundle identifier~~ — **settled**: `com.collierhmg.apple-calendar-mcp`, now baked into the designated requirement | done |
| 2 | **Does Cowork run locally or remotely?** | Phase 5 — decides whether undo guards 5-9 are built at all |
| 3 | **Confirm C6** (attendee refusal) formally | Phase 6 |
| 4 | **Default allowlist empty** ⇒ all writes fail closed on a fresh install | Phase 5 |

## Plan of Record

**`docs/IMPLEMENTATION-PLAN.md`** (rev. 3) — approved 2026-08-18, copied into the repo so
it survives session restarts. Read it before touching code: tool contract, field-level
schemas, the nine guards, recurrence semantics, phase gates. Summaries live in
`ARCHITECTURE.md` and `SPECIFICATION.md`; the plan is authoritative where they differ.

## Resuming After a Restart

1. Read `AGENTS.md` → `_ai-context/PROJECT-MEMORY.md` (controls C1-C6, 18 gotchas, open
   questions) → `docs/IMPLEMENTATION-PLAN.md`.
2. Nothing is built yet. No `Package.swift`, no sources. Next work is Phase 1.
3. Four decisions are waiting on the human — see Blocked On below.

## Session Summary

**2026-08-17 — onboarding.** Scaffolded `standard` kit (11 files). Captured founding
context in `PROJECT-MEMORY.md`. Three scope reversals landed mid-session and are all
recorded: read-only → read+write, personal-only → likely public open source, and the
resulting distribution/signing correction.

**2026-08-18 — planning.** Plan taken to rev. 3 through three independent reviews
(adversarial, cold-context validation, coherence audit). Five claims previously recorded as
"verified" were **wrong** and were corrected against the local EventKit headers — see
Gotchas 1 and 10-15. Structural fixes: `create` was a second ungated write path; the
journal-reading tool leaked every field the privacy policy withholds; undo of a
`futureEvents` delete would have produced two competing masters; undo-of-create could
destroy later human edits. Two overstated security claims withdrawn (§10 of the plan).

Governance: `gov-03e091f8d62b` PROCEED (onboarding) · `gov-84360fe55592` REVIEW (scaffold +
plan) · `gov-cec3bcaf6e71` **ESCALATE** on write capability
(`meta-safety-non-maleficence-privacy-security`, S-Series), cleared by explicit human
approval under C1-C5 · `gov-f551d84f9142` REVIEW amending C1/C2/C3, carving out C5, adding
C6, and recording the same-uid residual risk. Reasoning traces logged against each ID.

## Next Actions

1. **Phase 2 — Skeleton.** Promote the probe into the real package: arg dispatch,
   `--version`, and keep `Reexec` as the first thing `main` does. Gate: `otool -s __TEXT
   __info_plist` shows the section and `codesign -d --entitlements` verifies.

<details><summary>Phase 1 (complete) — original instructions</summary>

1. **Phase 1 — TCC spawn-path gate.** Build a minimal stub that calls
   `requestFullAccessToEvents` and prints `authorizationStatus(for:.event)`. Embed the
   Info.plist via `-sectcreate`, sign with a stable self-signed cert + entitlement +
   hardened runtime. Grant from Terminal, then have Claude Code and Codex each spawn the
   same binary and print status again.
   **Gate:** all hosts report `fullAccess` AND System Settings → Privacy → Calendars lists
   *apple-calendar-mcp*, not Terminal.

   *Outcome: failed as written, passed after adding the self-disclaiming re-exec.*
</details>
2. Answer Open Question #1 (Cowork local or remote) before Phase 5 — it decides whether
   several undo guards get built at all.
3. Confirm the bundle identifier before Phase 1 (it is fixed by the TCC grant).
