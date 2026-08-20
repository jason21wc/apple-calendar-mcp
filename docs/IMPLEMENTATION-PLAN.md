# apple-calendar-mcp — Implementation Plan (rev. 5)

## Context

A local stdio MCP server letting Claude Code, Codex and Claude Desktop work with the macOS
user's Apple Calendar through native EventKit. Personal use, public at
`github.com/jason21wc/apple-calendar-mcp` under Apache-2.0.

**Why this is a rewrite rather than another revision.** Rev. 4 patched by adding banners that
pointed at other sections instead of editing them. A coherence audit found 11 dangerous
contradictions and named the cause: *every correction announced elsewhere drifted; every
correction applied in place held.* Rev. 5 applies corrections at each site and deletes
superseded material rather than marking it. The withdrawn designs and the reasoning that
killed them are preserved in `_ai-context/LEARNING-LOG.md` and `PROJECT-MEMORY.md`, which is
where reasoning belongs.

**Single source of truth:** this file. `docs/IMPLEMENTATION-PLAN.md` in the repo is a copy
and must be replaced from this one whenever it changes — a stale rev. 3 copy was live in the
repo while `OPERATIONS.md` named it authoritative.

---

## 1. Status

| Phase | State |
|---|---|
| 1 — TCC identity | **Complete.** Gate passed only after adding the self-disclaiming re-exec |
| 2 — Skeleton | **Complete.** Command dispatch, embedded plist, signing scripts |
| 3 — Permission lifecycle | **Complete.** `--setup`, `--doctor`, five authorization states |
| 4 — Read surface | **Next** |
| 5 — Guards and substrate | Not started |
| 6 — Write surface | **Deferred by decision (§6)** |
| 7 — Hardening and release | Not started |

Shipped and installed at `/usr/local/bin/apple-calendar-mcp` (root-owned), holding the only
live Calendar grant. 63 tests pass via `./scripts/test.sh`. Security-audited; all HIGH and
MEDIUM findings fixed.

---

## 2. Architecture as built

Rev. 1–4 never described this. It is the project's central result and it was absent from the
document for four revisions.

```
main.swift          SIGPIPE ignore → Runtime.applyStartupFlags → Runtime.establishPrivacyIdentity
                    → Command.parse → dispatch
Runtime.swift       process-wide facts: disclaim mode, state directory, --read-only
Reexec.swift        the self-disclaiming re-exec
CLI.swift           Command enum, help, version, Meta (identity from the embedded plist)
EventKit/           AuthorizationState (five states)
Diagnostics/        Doctor, SetupFlow, TCCInspector
```

**The self-disclaiming re-exec is the load-bearing mechanism.** macOS assigns TCC
responsibility at `posix_spawn` time based on the parent, so a bare executable spawned by a
terminal or an MCP client gets **no privacy identity of its own** — the Calendar grant
attaches to the host and the binary silently inherits it. A signed `.app` wrapper does not fix
this; bundling only earns an independent identity when LaunchServices performs the launch,
which an MCP client never does because it needs stdio pipes.

The process therefore re-spawns itself once with the private
`responsibility_spawnattrs_setdisclaim` attribute, resolved via `dlsym` so its removal on a
future macOS degrades rather than fails to launch. Disclaim state is asked of the **kernel**
(`responsibility_get_pid_responsible_for_pid`), never of the environment — an earlier version
trusted an environment marker and was forgeable in one line.

Planned layering for Phase 4 onward, unchanged: `MCPLayer → CalendarKit → EventKitAdapter`,
with `EKEventStore` confined to one dedicated thread and EventKit objects never crossing the
adapter boundary.

---

## 3. Verified facts

### Header-verified (local SDK, 2026-08-18/19)

| Fact | Header |
|---|---|
| `EKAuthorizationStatus` has **five** distinct values; `Authorized` is a deprecated alias for `FullAccess` | `EKTypes.h:27-35` |
| `EKSpan` has two values only, declared in `EKEventStore.h` (not `EKTypes.h`) | `EKEventStore.h:19-29` |
| `occurrenceDate` is the stable occurrence key; survives detachment when start date changes | `EKEvent.h:140-152` |
| `eventIdentifier` changes on calendar move **and** on sync | `EKEvent.h:45-61` |
| `attendees` is `readonly` — cannot be set on create, cannot be restored | `EKCalendarItem.h:97` |
| `eventWithIdentifier:` returns the **first occurrence** of a series | `EKEventStore.h:279` |
| `predicateForEventsWithStartDate:endDate:` matches **overlapping** events, capped at four years | `EKEventStore.h:297,323-325` |
| No guaranteed ordering of fetched events | `EKEventStore.h:297` |
| Saving a stale object **recreates it as a new event**, silently | `EKEventStore.h:240-243` |
| `EKCalendarItem` exposes **no creator field**; `creationDate` is readonly | `EKCalendarItem.h:82-83` |
| No ICS export API anywhere in EventKit | — |

### Measured on this machine

| Fact | Evidence |
|---|---|
| **The TCC grant is keyed to the binary's absolute path** (`client_type=1`) | Same signed binary at another path reports `notDetermined` |
| **A changed cdhash at the same path keeps the grant** | Measured across a real rebuild; the designated requirement is identity-based (`identifier "..." and certificate root = H"..."`) |
| macOS 26.5 `tccd` refuses to prompt a hardened-runtime binary lacking the calendars entitlement — silently and permanently | Incident notes in the reference implementation, reproduced |
| A disclaimed process sees only its OWN grant, so `disclaimed-child` + `fullAccess` proves ownership without any privilege | Pre-grant the disclaimed child read `notDetermined` while the inherited path read `fullAccess` |
| Our binary **cannot** read `TCC.db` — that needs Full Disk Access, which the terminal has and we do not | `--doctor` reports "skipped" |
| `tccutil` cannot reset a path-keyed grant; it accepts bundle identifiers only | Both forms fail with OSStatus -10814 |
| `FileManager.homeDirectoryForCurrentUser` reads the passwd database, not `$HOME` | `HOME=/tmp/fake` did not redirect state files |

### External

MCP Swift SDK latest **0.12.1** (pre-1.0), supporting protocol revisions up to `2025-11-25`;
the current spec revision is **2026-07-28**, so we run one behind and clients negotiate down.
Both reference repos are MIT. Codex uses `~/.codex/config.toml`; Claude Code uses
`claude mcp add` / `.mcp.json`; Claude Desktop uses `claude_desktop_config.json`.

---

## 4. Containment controls

Governed: amending one requires a fresh `evaluate_governance` and a same-turn memory write.
Full text in `_ai-context/PROJECT-MEMORY.md`; summarised here.

| | Control | State |
|---|---|---|
| C1 | Writable-calendar allowlist, `{identifier, title, source}` all three matching, fail closed, loaded once at startup | Live, applies from Phase 5 |
| C2 | Only the committing call is destructive; takes a token plus a server-minted `confirm_summary` echoed byte-exactly | **Under review** — its subject (the destructive call) is undefined while the write surface is deferred |
| C2a | Always confirm, even on a single match | Same |
| C3 | Two-phase propose/commit plus a per-event JSON pre-state snapshot | Live from Phase 5 |
| C4 | Append-only journal sufficient to reverse | Live from Phase 5 |
| C4a | Undo semantics | **Under review** — see §6 |
| C5 | No bulk mutation; one event identifier per call, which may span occurrences of that one series | Live |
| C6 | Refuse all mutation of events with attendees or an external organizer | Live, unaffected by §6 |

**`confirm_summary` is presentation, not enforcement.** It makes the host's approval prompt
display a real sentence instead of an identifier. It does not prove a human read it — the
model can call `propose`, read its own preview and echo it. Stated here because three
successive drafts overstated it.

**`--read-only` is a reduction, not a boundary.** Withheld tools never appear in `tools/list`,
so injected text has nothing to name — real protection against a *mistaken or manipulated*
model. It is read from argv, and argv comes from client config files a same-uid agent can
write, so it is nothing against a *compromised* one. If a host must be write-incapable, the
honest mechanism is a separate install with write support compiled out.

---

## 5. Phase 4 — the read surface (next)

The first phase that delivers usable value: ask what is on the calendar and when you are free.

### Tools (five, all read-only)

| Tool | Purpose |
|---|---|
| `calendar_permission_status` | Report state. Never prompts |
| `calendar_list_calendars` | Event-supporting calendars, with true writability (`allowsContentModifications`, **not** `isImmutable`) |
| `calendar_list_events` | Bounded interval query |
| `calendar_find_events` | Search by term → candidates |
| `calendar_busy_intervals` | Availability without titles |

`calendar_recent_mutations` moves to Phase 6 — it reads the journal, which Phase 5 builds.

### Data model

**`EventDTO`, default field set:** `id`, `occurrence_date` (null for non-recurring),
`calendar_id`, `title`, `start`, `end`, `is_all_day`, `time_zone` (**nullable** — all-day
events have none), `status`, `availability`, `is_recurring`, `is_detached`, `has_attendees`,
`trust: "external_untrusted"`.

**Opt-in only** via `include_fields`: `notes`, `url`, `location`, `attendee_count`,
`organizer_name`. `attendees` as a list is never returned — it is readonly in EventKit.

**Response envelope:** `items`, `truncated`, `total_matched`, `effective_time_zone`,
`limits_applied`, `trust`. Every tool declares an `outputSchema` and returns
`structuredContent` plus a serialized text result.

### Semantics

RFC 3339 with explicit offsets; an IANA zone is **required** when local interpretation is
needed, never guessed. Intervals are half-open `[start, end)` matching by **overlap**. All-day
events are date-only, never round-tripped through UTC. Explicit sort (`start`, `title`, `id`)
because EventKit guarantees none. Occurrences addressed by `(eventIdentifier, occurrenceDate)`,
resolved via a date-window predicate and filter, since EventKit has no composite lookup.
Recurring counts are **approximate** and reported as `~N` — the four-year predicate cap makes
exact counting impossible for open-ended series.

Max interval 31 days; default limit 100, hard cap 500; no unbounded query, no server-side
pagination, nothing cached.

### Concurrency

`EKEventStore` confined to one dedicated thread. Prefer an actor with a custom
`SerialExecutor`: synchronous EventKit calls then contain no suspension points, so the actor
is genuinely non-reentrant, and `EKEventStore` never crosses an isolation boundary. Fall back
to a continuation bridge only if the executor approach requires `@unchecked Sendable` — and
record why.

### Server loop

**stdin EOF is unconditional shutdown.** This is the only defence against the supervisor being
SIGKILLed, which no signal handler can cover: stdin is inherited directly, so the client's
pipe closure reaches the child even when the supervisor is gone.

### Exit criteria

MCP Inspector lists five tools and returns schema-conforming results. stdout carries protocol
messages only. A 500-event fetch does not delay a concurrent `tools/list` by more than 250 ms.
**Orphan behaviour verified at last** — `kill -TERM` and `kill -KILL` the supervisor, confirm
with `ps -o pid,ppid,pgid` that no child survives holding the client's stdout. This has been
untestable for three phases because nothing ran long enough to observe.

---

## 6. Phase 6 — the write surface is DEFERRED

Three write designs were proposed and all three were refuted before any code was written: a
propose/commit ceremony that is model-satisfiable; an archive-instead-of-delete scheme derived
from a premise the same document falsified; and a "no destructive verb" design whose own title
was false because it exposed unrestricted `update`.

**The pattern is the finding.** Each rested on an assumption about EventKit or host behaviour
that nobody had measured, and two were refuted by facts already in this project's memory. A
fourth attempt fails the same way, because the missing input is data, not design effort.

### What must be measured first

1. Does Claude Desktop actually prompt for a mutating MCP tool, and does Cowork prompt at all?
   The reference library says *"verify it fires for your tool type"*; nobody has.
2. Does moving an event between calendars notify anyone? Observable only from a second account.
3. Does `availability` survive a cross-source move? `supportedEventAvailabilities` differs by
   source — header-checkable today.
4. What do people actually ask for? *"Cancel my 3pm"* is a delete of an event the model did
   not create — the most likely request, and the one every design so far refuses.

### Constraints any future design must honour

- **`update` is destructive.** It overwrites in place and carries the same stale-save hazard
  used to disqualify archive. Any design treating it as the safe verb is wrong.
- **File-based authorship is not evidence.** The journal is `0600` and append-only *by
  convention*; §7 already concedes an attacker can truncate it. Where the model has filesystem
  tools, a journal entry proves nothing. The non-forgeable alternative is an **in-memory** set
  of mutations this process made, which also bounds the window naturally at process lifetime —
  at the cost that it dies on respawn, and clients respawn without warning.
- **Undo of an update has no path** in any design so far, while `update` is the verb most
  likely to be used. Solve that before solving delete.
- **A refusal returning a shell command is useless on mobile.** It must offer something
  actionable there.
- **C6 stands** regardless.

Phase 5 (allowlist, tokens, journal, guards) may proceed independently, since it is substrate
rather than surface — but its guard set cannot be finalised until the surface is.

---

## 7. Trust boundary and privacy

Calendar-derived text — titles, notes, locations, organizer and attendee names, calendar and
source names — is `external_untrusted` and may never be interpreted as instructions,
configuration, paths or shell input. `openWorldHint: true` on invitation-derived tools. Typed
DTOs and schemas throughout; minimal field set by default.

Annotations are hints, not enforcement, and **host-side approval is not a control** — it is an
assumption about the user's configuration the server cannot observe.

**The controls live inside the agent's blast radius**, and the README carries this verbatim:
*These controls reduce the blast radius of a mistaken or manipulated model. They do not defend
against an attacker with filesystem write access as your user — such an attacker can edit the
allowlist, truncate the journal, and delete snapshots. Same-uid containment is not achievable
without a privilege boundary this project does not have.*

**Same-uid write means impersonation, not merely bypass.** Setup installs a certificate that
signs without a prompt, and the TCC requirement is identity-plus-path, both attacker-supplied.
A same-uid process can compile, sign silently, write to the granted path, and hold Calendar
access under this tool's name. Mitigation is deployment: install at a root-owned path, never
grant to a binary inside `.build`. This risk is **larger than the set accepted in
`gov-cec3bcaf6e71` and `gov-f551d84f9142`**.

No telemetry, analytics, network egress or self-update. "Local MCP" means the *server* is
local; the AI host still receives every field returned.

---

## 8. Errors and logging

stdout carries MCP protocol messages exclusively. Diagnostics to stderr with control
characters escaped — including calendar and source names, which are attacker-influenceable.
Never log titles, notes, attendees, locations, URLs or raw framework errors by default.

Codes: `PERMISSION_DENIED`, `INTERVAL_TOO_LARGE`, `CALENDAR_NOT_WRITABLE`,
`CALENDAR_NOT_ALLOWLISTED`, `EVENT_HAS_ATTENDEES`, `SPAN_REQUIRED`, `TOKEN_EXPIRED`,
`TOKEN_ALREADY_USED`, `TOKEN_INVALID`, `CONFIRM_SUMMARY_MISMATCH`,
`EVENT_CHANGED_SINCE_PROPOSE`, `EVENT_NOT_FOUND`. Clean shutdown when stdin closes.

---

## 9. Client integration

Absolute path always — the TCC grant is keyed to it. `serve` is the argless default.

**Claude Code** — `claude mcp add --transport stdio apple-calendar -- /usr/local/bin/apple-calendar-mcp`
**Codex** — `[mcp_servers.apple-calendar]` in `~/.codex/config.toml`
**Claude Desktop** — `mcpServers` in `claude_desktop_config.json`, currently with `--read-only`

---

## 10. Tests

`./scripts/test.sh` (not `swift test` — Command Line Tools ships `Testing.framework` but no
XCTest, and the module and dyld paths need deriving). 63 tests today.

**Unit** — five authorization states; RFC 3339 parsing; caps; filtering; stable sort; all-day
across UTC boundaries; DST and ambiguous local times; occurrence resolution by
`occurrenceDate` including detached occurrences whose start moved; busy merging; schema
conformance; stable codes; control-character and log-injection handling; trust labelling;
truncation metadata.

**Contract** — initialize; `tools/list`; valid and invalid `tools/call`; annotations; schemas;
structured and text compatibility; stdout purity; graceful disconnect.

**Shell** — every script parses; no unguarded `| grep -q` in a conditional, which under
`pipefail` inverts a successful match into a failure.

**Permission smoke matrix**, with expected outcomes: first prompt → `fullAccess`; relaunch →
no prompt; rebuild in place → **grant retained** (identity-based requirement); binary moved →
**grant lost** (path-keyed); revoke mid-session → `PERMISSION_DENIED`, no crash, no stdout
pollution; TCC reset → prompts again.

**Not covered, honestly:** the `dlsym`-failure branch cannot be exercised and is guarded by a
source-text assertion; signal forwarding and the CLOEXEC exemption need the long-running
server Phase 4 provides.

---

## 11. Risks

| Risk | Mitigation |
|---|---|
| Reinstalling or moving the binary loses the grant | Path-keyed by design; `--setup` runs at the final path; `--doctor` says so in plain English |
| Hardened runtime without the entitlement → silent permanent denial | Ship both always; `sign.sh` asserts both on the signed binary |
| Deleting an invited event notifies real people | C6, checked against ground truth. **The notification claim is inference, not header-verified** — confirm in Phase 6 with a second account |
| Prompt injection driving a mutation | C1 allowlist, guarded commit path. Reduces blast radius and improves reviewability; does **not** prevent a find → propose → commit chain |
| Controls sit inside the agent's blast radius | Stated verbatim in README and memory; startup-only config load |
| Same-uid impersonation of this binary's identity | Root-owned install path; never grant to `.build` |
| Server restart invalidates in-flight tokens | Expected; surfaced as `TOKEN_INVALID` |
| Permission model verified only on macOS 26.5 | Target is macOS 14; 14.0–26.4 unverified and `--doctor` must not claim otherwise |
| SDK pre-1.0 | Exact pin; `Package.resolved` committed |
| `unsafeFlags` blocks consumption as a dependency | Deliberate — clone-and-build only; signing and per-path grants make a transitive dependency meaningless anyway |

---

## 12. Definition of done (v1 = read surface)

Discovery works in Claude Code, Codex and Claude Desktop from one absolute-path config.
Bounded queries, search and busy intervals return schema-conforming results against the real
calendar. stdout carries protocol only. Orphan behaviour verified under SIGTERM and SIGKILL.
The permission smoke matrix passes with the §10 expected outcomes. README carries the
destructive-capability warning and the containment paragraph verbatim. `./scripts/test.sh`
green. `docs/IMPLEMENTATION-PLAN.md` matches this file.

---

## 13. Open decisions

1. **Desktop write posture** — becomes live at Phase 6, not before. With no write tools built,
   `--read-only` is a statement of fact rather than a restriction.
2. **C2/C2a/C4a** are formally under review while the write surface is deferred; their subject
   does not currently exist. A governance evaluation is owed when the surface is redesigned.
3. **Adopt C6 formally** — currently recorded as pending human confirmation.
4. **Any borrowing of expression** from the MIT reference repos — flagged case by case.

## 14. Cleanup — complete 2026-08-20

All items done and verified by grep, not by memory: the repo plan copy replaced (it was rev. 3
while `OPERATIONS.md` named it authoritative); `Runtime.swift`'s public comment no longer
claims read-only configuration means "the question does not arise"; `CLI.swift` names
`--setup` and documents `--grant` as the former name; `SESSION-STATE` no longer says nothing
is built nor describes a revoked grant as live; `PROJECT-MEMORY`'s phase gates advanced and
its merged decision rows split; `ARCHITECTURE.md` reflects built state; `BACKLOG` #14 removed;
the layer-name directive now defers to the on-disk layout.

Worth noting how this list nearly rotted: the work was done and the list tracking it was not
updated, which is the same drift that produced the 11 contradictions this revision fixed —
one level up. **Re-verify a cleanup list by grep before believing it.**
