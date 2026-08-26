<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Architecture

**Status:** Phases 1-4 built, tested, published and in daily use. **Five read-only tools are
shipped; no write tool exists.** The Phase 5 journal substrate is built but has no caller.
Full detail in `docs/IMPLEMENTATION-PLAN.md`, which is the repository-owned canonical plan.
This file is the summary; the plan is authoritative. Deliberately no revision number here —
naming one is how this line went stale before.

---

## Shape

A single pure-Swift executable. Local stdio MCP server over Apple EventKit. Read access is
built and shipped; write access is designed and gated (see the plan §6).

```
MCPLayer         tool contracts, JSON schemas, request wiring   (never sees an EK* type)
   ↓
CalendarKit      limits, search, time semantics, journal        (immutable DTOs only)
   ↓
EventKitAdapter  the only file that touches calendar CONTENT
```

These are conceptual layers. **On disk they are `Sources/apple-calendar-mcp/{MCP,Calendar,
EventKit,Diagnostics}` and the on-disk names win** — the directories were never renamed to
match, and the layer names survive here as vocabulary.

`EKEventStore` is confined to one dedicated thread behind an actor with a custom
`SerialExecutor`; EventKit objects never cross the adapter boundary, and callers receive
immutable DTOs.

**On "the only file that imports EventKit":** it was never true and is now stated correctly.
Four files import EventKit — `main.swift`, `CalendarStore`, `AuthorizationState` and
`SetupFlow` — but three of them use only the authorization API. No `EKEvent` or `EKCalendar`
exists outside `CalendarStore`. The invariant is about event objects, not import statements.

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
| One guarded mutation path, separate thin tool names | One place for guards; distinct names permit per-tool host policy where supported. No host policy is configured or verified today |
| Nothing cached | EventKit identifiers change on sync; fetched objects go stale after `EKEventStoreChangedNotification` |
| Custom `SerialExecutor` over a continuation bridge | An actor releases isolation at every `await`, so it would not serialize; a custom executor makes synchronous EventKit calls genuinely non-reentrant. **Built in Phase 4 and it did not need `@unchecked Sendable`** |
| Serving is the argless default | There is no `serve` subcommand; a bare `serve` argument exits `EX_USAGE`. MCP clients launch the binary with no arguments |
| One rendering zone per response | `effective_time_zone` reports the zone every timestamp was rendered in. Previously the field named the caller's zone while timestamps used the machine's — a claim nothing downstream could detect as false, since each timestamp still carried a valid offset |

## The security boundary

macOS has no read-only calendar permission. `requestFullAccessToEvents` is the only
authorization that permits fetching and it confers read *and* write. **Every safety
property is a property of this implementation, never of the OS.**

Calendar content — titles, notes, locations, organizer and attendee names, calendar and
source names — is attacker-influenceable through inbound invitations and is treated as
`external_untrusted` throughout. It is never interpreted as instructions, configuration,
paths, or shell input.

Containment controls live in `_ai-context/PROJECT-MEMORY.md` and are governed: amending one
requires a fresh `evaluate_governance` and a same-turn memory write. The adopted set, unchanged since
2026-08-20: **C3, C4, C5, C6, C7** — see the plan's §4 table for the state of each. **None is
in force today**: they govern mutation, and this server has no mutation path, so there is
nothing for them to gate. They bind the write surface when it is built. C1 (writable-calendar allowlist) was withdrawn by the
user's decision; C2/C2a/C4a were superseded by C7 and the later write design. The enforced
human-approval mechanism remains an open gate for the write surface.

**C7 — every mutation must be restorable**, where restorable means the *information* returns,
not the original object. A new event carrying the same field values satisfies it. This is
achievable only because C6 refuses events with attendees, and `attendees` is the single field
a snapshot cannot reproduce (`readonly`, `EKCalendarItem.h:97`).

**What the controls do not do.** They reduce blast radius and make each mutation
individually reviewable. They do not prevent a model acting on injected instructions from
running find → propose → commit. And because the config, journal and snapshots are files
owned by the user's own uid, they defend against a mistaken or manipulated model, not a
compromised one.

## The shipped surface

Five tools, all read-only, all annotated `readOnlyHint: true` / `destructiveHint: false`:
`calendar_permission_status`, `calendar_list_calendars`, `calendar_list_events`,
`calendar_find_events`, `calendar_busy_intervals`. Each declares an `outputSchema` and returns
`structuredContent` alongside a text summary. Failures carry a stable `UPPER_SNAKE` code.

Tools returning externally-authored text — event titles and notes, and calendar and source
titles, all of which arrive from other people — carry `openWorldHint: true`.
The two that do not are `calendar_busy_intervals`, which returns times and counts with no
text at all, and `calendar_permission_status`, which returns only this machine's own state.

The fourteen-tool surface with propose/commit pairs is the **plan**, not the server.

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
