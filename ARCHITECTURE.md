<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Architecture

**Status:** Designed, not yet built. Full detail in `docs/IMPLEMENTATION-PLAN.md` (rev. 3,
approved 2026-08-18). This file is the summary; the plan is authoritative.

---

## Shape

A single pure-Swift executable. Local stdio MCP server over Apple EventKit, giving Claude
Code and Codex read and write access to the user's macOS Calendar.

```
MCPLayer         tool contracts, JSON schemas, request wiring   (never sees an EK* type)
   ↓
CalendarKit      allowlist, limits, tokens, journal,
                 recurrence policy, guards                      (immutable DTOs only)
   ↓
EventKitAdapter  the ONLY file that imports EventKit
```

These names become directory names. `EKEventStore` is confined to one dedicated thread
behind an actor; EventKit objects never cross the adapter boundary.

**Why pure Swift, not Node+helper or Python/PyObjC.** TCC binds the Calendar permission to
the executable's code-signing identity. Any design where the signed thing is an interpreter
or a wrapper makes the grant fragile and — because macOS 26.5 refuses to re-prompt a
hardened-runtime binary missing the calendars entitlement — potentially unrecoverable.

## Load-bearing decisions

| Decision | Why |
|---|---|
| MCP Swift SDK pinned `.exact("0.12.1")` | Pre-1.0; minors break. One spec revision behind (SDK tops out at `2025-11-25`, spec is at `2026-07-28`); clients negotiate down |
| Info.plist embedded via `-sectcreate __TEXT __info_plist` | An SPM executable has no bundle and so cannot otherwise carry `NSCalendarsFullAccessUsageDescription` |
| Stable self-signed cert + hardened runtime + entitlement | The TCC grant is checked against the **designated requirement**, which for a certificate-signed binary is `identifier "..." and certificate root = H"..."` — identity-based, so rebuilds keep the grant. Ad-hoc signing yields a **cdhash-based** requirement instead, which breaks on every build. Measured 2026-08-19 |
| **Self-disclaiming re-exec at startup** | A plain executable never gets its own TCC identity — the grant is attributed to whoever spawned it, and an `.app` wrapper does not change that. Re-spawning once with `responsibility_spawnattrs_setdisclaim` makes the child its own responsible process. Verified 2026-08-19; the private symbol is resolved via `dlsym`, so its removal degrades to inherited mode rather than failing to launch |
| One guarded `commit()`, four thin tool names | One place for guards; four separately-allowlistable names so a single "always allow" cannot authorize everything |
| Nothing cached | EventKit identifiers change on sync; fetched objects go stale after `EKEventStoreChangedNotification` |
| Custom `SerialExecutor` preferred over continuation bridge | An actor releases isolation at every `await`, so it would not serialize; a custom executor makes synchronous EventKit calls genuinely non-reentrant. Decided in Phase 4 — fall back if it needs `@unchecked Sendable` |

## The security boundary

macOS has no read-only calendar permission. `requestFullAccessToEvents` is the only
authorization that permits fetching and it confers read *and* write. **Every safety
property is a property of this implementation, never of the OS.**

Calendar content — titles, notes, locations, organizer and attendee names, calendar and
source names — is attacker-influenceable through inbound invitations and is treated as
`external_untrusted` throughout. It is never interpreted as instructions, configuration,
paths, or shell input.

Containment controls C1–C6 live in `_ai-context/PROJECT-MEMORY.md` and are governed:
amending one requires a fresh `evaluate_governance`.

**What the controls do not do.** They reduce blast radius and make each mutation
individually reviewable. They do not prevent a model acting on injected instructions from
running find → propose → commit. And because the config, journal and snapshots are files
owned by the user's own uid, they defend against a mistaken or manipulated model, not a
compromised one.

## Settled by Phase 1 (2026-08-19)

**TCC responsible-process attribution — resolved.** A correctly signed bare executable gets
**no TCC identity of its own**; the grant attaches to the spawning app. A signed `.app`
wrapper does not fix it, because bundling only earns an independent identity when
LaunchServices performs the launch, and an MCP client never does — it needs stdio pipes.

The adopted fix is the self-disclaiming re-exec above. Two operational consequences:

- The grant is keyed to the binary's **absolute path** (`client_type=1`), so `--setup` must
  run at the final installed location and client configs must name that same path.
- A changed cdhash at the same path is harmless; the designated requirement is
  identity-based.
