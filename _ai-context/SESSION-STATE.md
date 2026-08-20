<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Session State

**Last Updated:** 2026-08-17
**Memory Type:** Working (transient)
**Lifecycle:** Prune at session start per §7.0.4

> This file tracks CURRENT work state only.
> Historical information → PROJECT-MEMORY.md (decisions) or LEARNING-LOG.md (lessons)

---

## Current Position

- **Phase:** Phases 1-3 complete, published, and security-audited. **Phase 4 is next.**
- **Mode:** Standard
- **Repo:** https://github.com/jason21wc/apple-calendar-mcp (public, Apache-2.0)
- **Active Task:** None in flight. Phase 4 is the read surface: DTOs, schemas,
  `CalendarStore` actor, `TimeSemantics`, `Limits`, and five read tools.

## Quick Reference

| Metric | Value |
|--------|-------|
| Project | **apple-calendar-mcp** |
| Code written | Probe, `Reexec`, `CLI`, `AuthorizationState`, `TCCInspector`, `Doctor`, `SetupFlow`, 3 scripts |
| Installed at | `/usr/local/bin/apple-calendar-mcp` (root:wheel), granted, `--doctor` clean |
| Security audit | Complete — 3 HIGH, 4 MEDIUM, 5 LOW; all HIGH and MEDIUM fixed |
| Builds | Clean, no warnings |
| Signed | Yes — stable self-signed cert, entitlement, hardened runtime |
| TCC identity | **Own row confirmed** (path-keyed) |
| Plan | rev. 5, approved 2026-08-19 |
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

**Superseded:** the `.build` grant was revoked 2026-08-19. The only live grant is
`/usr/local/bin/apple-calendar-mcp` (root-owned). Installing elsewhere requires a fresh
`--setup` at that path — the grant is path-keyed.

## Published 2026-08-19

Public at `github.com/jason21wc/apple-calendar-mcp`, Apache-2.0, copyright Jason Collier
(personal, not Collier HMG). `_ai-context/` is published deliberately — the gotchas are the
most valuable content in the repo. **Sanitised before publishing**: absolute home paths, the
host terminal's bundle identifier, and this machine's certificate fingerprint were
generalised. Keep it that way — re-check before each push.

A code review before publishing found two real security defects in the setup scripts (the
login password reaching argv, and a private key surviving Ctrl-C) plus a broken handoff
between two scripts. All fixed; see LEARNING-LOG.

## Phase 2 Result — gate passed

Skeleton complete. `Command` enum with dispatch (`serve` / `--grant` / `--probe` /
`--version` / `--help`), metadata read from the embedded Info.plist rather than hardcoded,
and honest exit codes: 64 for a bad flag, 69 for `serve` (not implemented until Phase 4), so
a client sees a real failure rather than a silent exit that looks like a crash.

Gate: `__TEXT,__info_plist` present, entitlement verified on the signed binary, signature
valid, stdout clean.

## Phase 3 Result — gate passed

`AuthorizationState` (five states, `.writeOnly` handled distinctly), `TCCInspector`,
`Doctor`, `SetupFlow`. `--grant` is now `--setup` and the old name still works.

**Design correction found while building:** the plan had `--doctor` compare cdhashes. That
is the wrong check — rebuilds keep the grant; what breaks it is the **path** changing. And
`TCC.db` turned out to be unreadable by our own binary (needs Full Disk Access, which the
terminal has and we do not). The replacement is better and needs no privilege: a disclaimed
process sees only its own grant, so `disclaimed-child` + `fullAccess` **is** proof of
ownership. See gotchas 28-29.

`--setup` refuses to proceed under inherited identity, which structurally prevents the exact
Phase 1 failure — granting to the terminal instead of to us.

Verified failure paths: inherited identity → exit 1; binary at an ungranted path → exit 1
naming the path to fix it; `--setup` under inherited identity → refuses.

## Verified 2026-08-20 — the last Phase 1 gap is closed

The disclaim was only ever tested from a shell. It is now verified under a real MCP client:
Claude Desktop spawned `/usr/local/bin/apple-calendar-mcp` and the probe recorded
`mode=disclaimed-child`, `status=fullAccess`, `parent=/Applications/Claude.app/Contents/Helpers/disclaimer`.

Claude Desktop ships its own Anthropic-signed `disclaimer` helper using the same private API
(gotcha 44), so it had already made us self-responsible and our re-exec correctly did not
fire. The connection then closed as designed — there is no server loop until Phase 4, so the
binary writes its probe and exits 69.

## Carry Into Phase 4

- Server loop MUST treat stdin EOF as unconditional shutdown (BACKLOG #12).
- Orphan behaviour under SIGTERM/SIGKILL is still **unverified** — needs the long-running
  server to test (BACKLOG #11).
- Refuse to serve when `--doctor` would fail: serving without an owned grant produces
  silent, confusing failures for the user.

## Carry Into Phase 3 (complete)

- `--doctor` must read `TCC.db` for a row matching **our own path**. `authorizationStatus`
  cannot distinguish our grant from an inherited one, so a status-based check is worthless.
- `--doctor` must report `disclaim_mode`; `inherited-*` means the re-exec is not working and
  Calendar access belongs to the host.
- `--grant` becomes `--setup`; it already warns that the grant is path-keyed.
- Handle all **five** authorization states (`Authorized` is a deprecated alias for
  `FullAccess`, runtime-indistinguishable).

## Carry Into Phase 2 (complete)

- `--setup` must run at the **final installed path**, never from `.build`.
- Client configs must name that exact absolute path.
- `--doctor` must report: disclaim mode active vs inherited, whether a TCC row exists for
  our own path (read `TCC.db`, not `authorizationStatus` — status cannot tell them apart),
  and say plainly when the grant belongs to a different path.
- Signing needs one interactive keychain setup per machine before it works unattended.

## Security Posture (closed 2026-08-19)

The stale `.build` Calendar grant is **revoked** (auth_value 0); `/usr/local/bin/apple-calendar-mcp`
holds the only live grant. That closes the impersonation exposure the audit found: a
user-writable path with a Calendar grant, combined with a certificate that signs without a
prompt, let any same-uid process hold calendar access under this tool's name.

Note for anyone repeating this: System Settings shows the display name only, so two grants
for the same binary at different paths are visually identical. Distinguish them by querying
`TCC.db`; `tccutil` cannot target either (gotcha 32).

Audit outcome: 3 HIGH, 4 MEDIUM, 5 LOW — all HIGH and MEDIUM fixed, plus a second review
round that found the first fix had reinstated the bypass it replaced.

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
schemas, the guard set (under review — see plan §4), recurrence semantics, phase gates. Summaries live in
`ARCHITECTURE.md` and `SPECIFICATION.md`; the plan is authoritative where they differ.

## Resuming After a Restart

1. Read `AGENTS.md` → `_ai-context/PROJECT-MEMORY.md` (controls C1-C6, 43 gotchas, open
   questions) → `docs/IMPLEMENTATION-PLAN.md`.
2. Phases 1-3 are built, tested and published. Next work is **Phase 4** (read surface).
3. See Blocked On below for what needs a human.

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

1. **Phase 4 — read surface.** Five read tools, DTOs, schemas, the CalendarStore actor,
   time semantics, and stdin-EOF shutdown. See plan §5.

<details><summary>Superseded next-actions</summary>

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
