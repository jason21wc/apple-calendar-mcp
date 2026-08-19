# apple-calendar-mcp — Implementation Plan (rev. 3)

## Context

A local stdio MCP server that lets Claude Code and Codex read **and write** the current macOS
user's Apple Calendar through native EventKit. Built for the author's own machine, intended for
public open-source release under Apache-2.0.

macOS has no read-only calendar permission — `requestFullAccessToEvents` is the only authorization
that permits fetching, and it confers read *and* write. Every safety property is therefore a
property of our implementation, never of the OS.

Rev. 3 folds in three independent reviews (adversarial, cold-context validation, coherence audit).
**Five claims in rev. 2's own "verified facts" table were wrong** — checked against the SDK headers
and corrected in §2. Changes are marked **[rev3]**.

This is a plan. No code, no repo init, no dependency install, no permission request, no client
config changes.

> **Governance gate — read before Phase 1.** Rev. 2 silently superseded three of the five
> containment controls recorded in `_ai-context/PROJECT-MEMORY.md` (C1's shared-calendar guarantee,
> C2's "identifiers only", C3's `.ics` backup), and §10 identifies a residual risk larger than the
> one governance approved. Memory's own rule — *"Any change that weakens a containment control
> requires a fresh governance evaluation"* — is triggered. **A fresh `evaluate_governance` and a
> memory reconciliation (§21) must complete before Phase 1 begins.**

---

## 1. Executive recommendation

A **single pure-Swift executable** using EventKit and the MCP Swift SDK pinned to **0.12.1**, three
internal layers, `EKEventStore` confined to one dedicated thread.

**The Info.plist problem has a proven solution.** SPM executables have no bundle, so they cannot
normally carry `NSCalendarsFullAccessUsageDescription`. `che-ical-mcp` embeds it into the Mach-O
`__TEXT,__info_plist` section via linker flags. Adopt the technique.

**The entitlement is mandatory and failure is silent.** macOS 26.5 `tccd` refuses to show any
Calendar prompt for a hardened-runtime binary missing
`com.apple.security.personal-information.calendars`; the denial is permanent while status APIs
report green. `--doctor` is a correctness requirement.

**TCC attribution is the project's single largest unknown.** macOS commonly attributes a grant to
the *responsible process* — for a bare executable spawned from a shell, often the launching app. If
the grant lands on Terminal, everything works at `--setup` and fails when a client spawns us.
**Phase 1's gate, and it decides bare-executable vs `.app` bundle.** Nothing downstream is built
until it is answered.

**The MCP spec has moved past the SDK.** Current revision is **2026-07-28**; SDK 0.12.1 supports up
to `2025-11-25`. Use the SDK and be one revision behind — clients negotiate down.

---

## 2. Verified facts, assumptions, uncertainties

### Header-verified (read directly from `$(xcrun --show-sdk-path)/.../EventKit.framework/Headers`, 2026-08-17)

| Fact | Header |
|---|---|
| **[rev3] `isImmutable` means the calendar *object* cannot be renamed/recolored/deleted. Header: "It does NOT imply that you cannot add events or reminders to the calendar."** | `EKCalendar.h:94-100` |
| **[rev3] `EKAuthorizationStatus` has FIVE distinct values** — `NotDetermined=0, Restricted, Denied, FullAccess, WriteOnly`. `Authorized` is a deprecated alias `= FullAccess`, runtime-indistinguishable | `EKTypes.h:27-35` |
| **[rev3] `EKSpan` is declared in `EKEventStore.h`, not `EKTypes.h`** (rev. 2 cited the wrong header). Two values: `EKSpanThisEvent`, `EKSpanFutureEvents` | `EKEventStore.h:19-29` |
| **[rev3] `occurrenceDate` is the stable occurrence key** — "will remain the same even if the event has been detached and its start date has changed". Nil until `startDate` is set | `EKEvent.h:140-152` |
| **[rev3] `eventIdentifier` also changes on sync** — "It is currently also possible for the ID to change due to a sync operation." Same defect rev. 2 used to disqualify the alternatives | `EKEvent.h:45-61` |
| **[rev3] `attendees` is `readonly`** — a restore can never reproduce attendees, and `create` can never set them | `EKCalendarItem.h:97` |
| `isDetached` = an occurrence whose attributes differ from the series default. **[rev3] A `EKSpanThisEvent` delete produces an *exclusion*, not a detached event** | `EKEvent.h:131-138` |
| `eventWithIdentifier:` returns the **first occurrence**; the identifier is shared across a series | `EKEventStore.h:279`, `EKCalendarItem.h` |
| `predicateForEventsWithStartDate:endDate:` returns **overlapping** events and is capped at **four years** | `EKEventStore.h:297,323-325` |
| No guaranteed ordering of fetched events | `EKEventStore.h:297` |
| `EKCalendar.allowsContentModifications`, `.isSubscribed`; `EKSource.sourceType` | `EKCalendar.h`, `EKSource.h` |
| `EKEvent.organizer`, `EKParticipant.isCurrentUser`, `EKParticipantStatus` | `EKEvent.h`, `EKParticipant.h` |
| **EventKit exposes no ICS export API** (grep across all headers: prose mentions only) | — |

### Externally verified (accessed 2026-08-17)

| Fact | Source |
|---|---|
| MCP Swift SDK latest **0.12.1** (2026-05-07), pre-1.0 | GitHub releases |
| SDK `Version.supported` = `2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05` | `Sources/MCP/Base/Versioning.swift` @ 0.12.1 |
| Current MCP spec revision **2026-07-28** | modelcontextprotocol.io/specification |
| Info.plist embeds via `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist` | `che-ical-mcp/Package.swift` |
| macOS 26.5+ `tccd` refuses to prompt for hardened-runtime binaries lacking the calendars entitlement; silent + permanent. Entitlement is unrestricted | `che-ical-mcp/.../Entitlements.plist` incident notes |
| Codex: `~/.codex/config.toml`, `[mcp_servers.<name>]` | learn.chatgpt.com/docs/extend/mcp |
| Claude Code: `claude mcp add [opts] <name> -- <cmd>`; `mcpServers: {name:{command,args,env}}` | code.claude.com/docs/en/mcp |
| Both reference repos MIT — `che-ical-mcp` © 2025 Che Cheng, `orchard-mcp` © 2025 l22.io GmbH | LICENSE @ pinned commits |

### **[rev3] Inference — stated with lower confidence than the above**

- **Deleting an event you were invited to sends a decline to the organizer; deleting one you
  organized sends a cancellation.** This is the entire justification for §7's hardest refusal, and
  rev. 2 stated it with the confidence of a header fact. It is not header-verified and no Apple doc
  was machine-readable. Plausible and consistent with Calendar.app behavior. **Verify in Phase 6
  with a second account before relying on the refusal's rationale in the README.** The refusal
  itself is cheap enough to keep regardless of the outcome.

### Assumptions

- Swift 6.x toolchain. **[rev3] Deployment target `.macOS(.v14)`** — the minimum for
  `requestFullAccessToEvents`. Note the TCC prompting behavior in §1 is verified only on macOS 26.5;
  behavior on 14.0–26.4 is **unverified**, and `--doctor` must not claim otherwise.
- Bundle identifier `com.collierhmg.apple-calendar-mcp`.
- v1 write surface: create, update, delete, undo — all recurrence-aware.

### Unresolved

1. **TCC responsible-process attribution.** Phase 1 gate.
2. **Does Cowork run locally or remotely?** A remote sandbox cannot reach a local `EKEventStore` at
   all. **[rev3] This is load-bearing**: keeping undo model-callable was justified by Cowork having
   no terminal. If Cowork is remote, that justification evaporates and undo could return to a CLI,
   deleting guards 5–7 and §7's undo complexity. **Answer before Phase 5.**
3. Does `calshow:` open Calendar.app at a date? Would let a refusal hand you a clickable jump.
   Verify, then add.
4. EventKit concurrency shape — §4, decided in Phase 4.
5. Do the clients surface `structuredContent`/`outputSchema` at revision 2025-11-25? Return both
   structured and text results regardless.

---

## 3. Alternatives considered

| Approach | Permission reliability | Packaging | Deps | Maintenance | Verdict |
|---|---|---|---|---|---|
| **Pure Swift + EventKit** | Best — one binary, one TCC identity | Medium | Minimal | Low | **Chosen** |
| Node MCP + Swift helper | Poor — two identities | Worse | Node | High | Rejected |
| Python / PyObjC | Worst — interpreter is the TCC subject | Worst | Python + PyObjC | High | Rejected |

TCC binds to the executable's signing identity; any design where the signed thing is an interpreter
or wrapper makes the grant fragile and potentially unrecoverable.

---

## 4. Architecture

```
MCPLayer        tool contracts, schemas, wiring     (never sees an EK* type)
   ↓
CalendarKit     allowlist, limits, tokens, journal,
                recurrence policy, guards            (DTOs only)
   ↓
EventKitAdapter the ONLY importer of EventKit
```

**Concurrency.** EventKit calls are synchronous and `EK*` objects are not thread-safe, so all of it
is confined to one dedicated thread. An actor bridging via `withCheckedThrowingContinuation` is
workable but weaker than it looks — an actor releases isolation at every `await`, so it would not
serialize operations, and non-`Sendable` `EKEventStore` forces `@unchecked` escapes.

**Preferred: an actor with a custom `SerialExecutor` backed by a dedicated `DispatchQueue`.**
Synchronous EventKit calls then contain no suspension points, so the actor is genuinely
non-reentrant per operation; the blocking call never touches the cooperative pool; `EKEventStore`
never crosses an isolation boundary. **[rev3] Phase 4 decision criteria, so the spike can actually
fail:** adopt the custom executor unless it requires any `@unchecked Sendable` or
`nonisolated(unsafe)` annotation, in which case fall back to the continuation bridge and record why.

Dependency: `modelcontextprotocol/swift-sdk` `.exact("0.12.1")`. Nothing else.

---

## 5. Repository structure

```
Package.swift                    exact pin; sectcreate linker flags
Sources/AppleCalendarMCP/
  main.swift                     [serve default] | --setup | --doctor | --version   [rev3]
  Info.plist / Entitlements.plist
  MCP/  ServerBootstrap · ToolRegistry · Schemas · Handlers+Read · Handlers+Write
  Calendar/
    Models.swift                 DTOs (§7)
    Allowlist.swift              C1 — loaded ONCE at startup
    Limits.swift                 caps, truncation, response budget
    Mutations.swift              proposal store: token → planned mutation
    Recurrence.swift             span policy, occurrence resolution, series summary
    Guards.swift                 §8 predicates
    Journal.swift                C4 — append-only JSONL + pre/post-state snapshots
    BusyIntervals.swift · TimeSemantics.swift
  EventKit/
    CalendarStore.swift          custom-executor actor; ONLY EventKit importer
    AuthorizationState.swift     five states (§2)
    ErrorSanitizer.swift
  Diagnostics/ Doctor · SetupFlow · Logging
Tests/ AppleCalendarMCPTests (unit + contract) · IntegrationTests (opt-in, env-gated)
scripts/sign.sh                  stable self-signed identity + entitlements + hardened runtime
docs/source-log.md               appended opportunistically, not a gate
LICENSE (Apache-2.0) · NOTICE (only if MIT expression borrowed) · README.md
```

**[rev3] `--journal` is cut** — it was an orphan referenced in no phase, test, or DoD clause. The
journal is read via `calendar_recent_mutations` (metadata) and `--doctor`.
**`IcsBackup.swift` stays cut** — EventKit has no ICS export API, so it was a hand-rolled RFC 5545
serializer, and it would have written the whole calendar to plaintext. Per-event JSON snapshots in
the journal carry the reversal data instead.

### **[rev3] On-disk artifacts — previously unspecified, and C1's entire substrate**

| Artifact | Path | Format | Notes |
|---|---|---|---|
| Config | `~/.config/apple-calendar-mcp/config.toml` | TOML | Read **once at startup**. Absent or empty ⇒ zero writable calendars, all writes fail closed |
| Journal | `~/.local/state/apple-calendar-mcp/journal/YYYY-MM.jsonl` | JSONL, mode `0600` | Append-only by convention; monthly rotation; no size cap in v1, entries are small |
| Doctor state | `~/.local/state/apple-calendar-mcp/setup.json` | JSON | cdhash + binary path recorded at `--setup`, compared by `--doctor` |

**Allowlist entry shape** — an identifier alone is fragile (identifiers are lost on full sync) and a
title alone is attacker-influenceable (calendar names are untrusted external data). Require both:

```toml
[[writable_calendar]]
calendar_identifier = "E1B2..."     # EKCalendar.calendarIdentifier
expected_title      = "Personal"
expected_source     = "iCloud"
```

Resolution requires the identifier to match **and** title+source to match. Any mismatch **fails
closed**, logs a plain-English line to stderr, and is reported by `--doctor`. **Never fall back to
title matching** — that would let a newly-added account silently make a calendar writable.

---

## 6. Tool contract

**[rev3] Every mutation — including create — is proposed first.** Rev. 2 claimed "exactly one
destructive call" while leaving `calendar_create_event` outside the guarded path; creating an event
with attendees is the same class of irreversible outbound act the guards exist to prevent. Now there
is one guarded implementation, `commit()`, reached through three thin tool names.

| Tool | Mutates | Annotations | Purpose |
|---|---|---|---|
| `calendar_permission_status` | no | `readOnlyHint:true` | State. **Never prompts.** |
| `calendar_list_calendars` | no | `readOnlyHint:true` | Calendars + true writability (§8.2) |
| `calendar_list_events` | no | `readOnlyHint:true`, `openWorldHint:true` | Bounded interval query |
| `calendar_find_events` | no | `readOnlyHint:true`, `openWorldHint:true` | Search → candidates |
| `calendar_busy_intervals` | no | `readOnlyHint:true` | Availability without titles |
| `calendar_recent_mutations` | no | `readOnlyHint:true` | Journal **metadata only** (§10) |
| `calendar_propose_create` | no | `readOnlyHint:false`, `destructiveHint:false`, `idempotentHint:true` | Preview + token |
| `calendar_propose_update` | no | same as above | Preview + token |
| `calendar_propose_delete` | no | same as above | Preview + token |
| `calendar_propose_undo` | no | same as above | Preview + token, from a journal entry id |
| `calendar_commit_create` | **yes** | `destructiveHint:false` | ~5 lines → `commit()` |
| `calendar_commit_update` | **yes** | `destructiveHint:true` | ~5 lines → `commit()` |
| `calendar_commit_delete` | **yes** | `destructiveHint:true` | ~5 lines → `commit()` |
| `calendar_commit_undo` | **yes** | `destructiveHint:true` | ~5 lines → `commit()` |

**[rev3] Why four commit names over one `calendar_commit`.** Host permission systems allowlist by
*tool name*. A single name means one "always allow" click authorizes every destructive operation the
server can perform, forever, and degrades the prompt text to something generic. Four thin wrappers
over one implementation keep the single guarded code path while preserving separately-allowlistable
names and legible prompts.

Renames from the brief: `find_busy_times` → `calendar_busy_intervals`; `calendar_find_events` added.
Permission setup is **not** a tool — a TCC prompt needs a foreground process, which a stdio-launched
server cannot reliably present. That is `--setup`, with `--doctor` alongside.

### The flow

```
calendar_find_events(query:"standup")          read-only → candidates + ids
calendar_propose_delete(event_id,               read-only → preview + confirm_summary + token
                        occurrence_date?, span)
        ⇩ preview states: "1 of ~155 occurrences, weekly, Jan 2025 → Dec 2027"
calendar_commit_delete(token, confirm_summary)  → commit()
```

### **[rev3] `confirm_summary`, specified — and its guarantee narrowed**

`propose_*` returns a **server-generated canonical summary string** (fixed format:
`"<title> — <ISO-8601 start> — <span in words>"`). `commit_*` requires a **byte-exact echo** of that
string; the string is bound into the token; verification is `==` against a value the server minted.
No fuzzy matching, no locale ambiguity, no threshold to slide down.

**What this does and does not buy.** It guarantees the sentence appearing in the host's approval
prompt is server-authored and accurately describes the pending mutation, instead of a UUID and an
opaque token. It does **not** guarantee a human read it — the model copies the string, and the
server cannot observe comprehension. Rev. 2 claimed "what you read is guaranteed to describe what
will happen"; the first half of that is unearnable and is withdrawn.

**Token semantics.** Opaque, single-use, 120 s TTL, held **in memory**. Bound to
`(operation, event_id, occurrence_date, span, changes, confirm_summary, hash(pre_state))`.
A pre-state hash mismatch ⇒ `EVENT_CHANGED_SINCE_PROPOSE`, narrowing (not closing) the TOCTOU window
against background sync. **[rev3]** The hashed field set explicitly **excludes** `lastModifiedDate`,
so benign sync churn does not break every commit. **[rev3]** Clients respawn stdio servers without
warning; a restart between propose and commit invalidates all tokens — expected, surfaced as
`TOKEN_INVALID`, listed in §17.

**[rev3] Undo token binding.** For undoing a *deletion* there is no live `event_id` and no
pre-state to hash. Undo tokens instead bind
`(operation:"undo", journal_entry_id, hash(recorded_state), confirm_summary)`. For undoing a
*creation*, the token additionally binds `hash(post_create_state)` and `commit()` compares it against
ground truth — see §8 guard 7.

**Honest limit, repeated in §17 and the README.** None of this prevents a model acting on injected
instructions from running find → propose → commit. It removes the one-call-wipes-everything shape,
forces every mutation to name a recognizable target, and makes each individually reviewable. It is
blast-radius and reviewability, not prevention.

---

## 7. **[rev3] Data model and schemas**

Rev. 2 referenced schemas that did not exist, so Phase 4 could not have begun.

**`CalendarRef`** — `id` (`calendarIdentifier`), `title`, `source_title`, `source_type`,
`allows_content_modifications`, `is_subscribed`, `writable` (§8.2), `trust:"external_untrusted"`.

**`EventDTO` — default (minimal) field set:** `id` (`eventIdentifier`), `occurrence_date`
(`EKEvent.occurrenceDate`, null for non-recurring), `calendar_id`, `title`, `start`, `end`,
`is_all_day`, `time_zone` (**nullable** — all-day events have none), `status`, `availability`,
`is_recurring`, `is_detached`, `has_attendees` (bool only), `trust:"external_untrusted"`.

**Opt-in only**, via `include_fields`: `notes`, `url`, `location`, `attendee_count`, `organizer_name`.
Never returned by default. `attendees` as a list is never returned or accepted — it is `readonly` in
EventKit, so `create` cannot set it and a restore cannot reproduce it.

**`calendar_list_events` input** — `start` (req), `end` (req), `calendar_ids?`, `limit`
(default 100, max 500), `include_fields?`.
**`calendar_propose_delete` input** — `event_id` (req), `occurrence_date?`, `span?` (see §9).
**`calendar_commit_*` input** — `token` (req), `confirm_summary` (req).
**`calendar_propose_create` input** — `calendar_id`, `title`, `start`, `end`, `is_all_day`,
`time_zone?`, `notes?`, `location?`. Rejects any `attendees` key outright.

**Response envelope (all read tools)** — `items`, `truncated`, `total_matched`,
`effective_time_zone`, `limits_applied`, `trust`.

Every tool declares an `outputSchema` and returns `structuredContent` plus a serialized text result.

---

## 8. Guards inside `commit()` **[rev3]**

Checked against freshly refetched ground truth. `confirm_summary` is the one model-supplied argument
in the path, and it is compared against a server-minted value, not trusted.

1. **Attendee guard.** Reject when `event.hasAttendees` or
   `organizer != nil && !organizer.isCurrentUser` → `EVENT_HAS_ATTENDEES`. Rationale is §2's
   inference (declines/cancellations propagate), to be confirmed in Phase 6.
   **The refusal is structured and actionable**, returning title, start, end, calendar name,
   organizer, and attendee count — enough to find and decline it by hand. This deliberately
   discloses fields §10 withholds; the disclosure is targeted to the moment of need and carries
   `trust:"external_untrusted"`, since organizer names are attacker-controlled invitation text.
2. **Writability guard. [rev3] `allowsContentModifications && inAllowlist` — `isImmutable` is NOT
   consulted.** Rev. 2 had `!isImmutable` in this expression, which is header-verified wrong:
   `isImmutable` governs renaming/recoloring/deleting the calendar object and explicitly "does NOT
   imply that you cannot add events". Including it would reject writable calendars.
   Subscribed/holiday/birthday calendars are excluded because they report
   `allowsContentModifications == false`. → `CALENDAR_NOT_WRITABLE`.
3. **Allowlist guard.** C1. Distinct code `CALENDAR_NOT_ALLOWLISTED`, because an empty allowlist is
   the default first-run experience and must be distinguishable from source immutability.
4. **Span guard.** `span` required whenever the target has recurrence rules → `SPAN_REQUIRED`.
5. **[rev3] `futureEvents` undo refusal.** Undo of any mutation whose span was `EKSpanFutureEvents`
   is refused → `UNDO_SPAN_UNSUPPORTED`, with a structured payload describing what was removed.
   Recreating a deleted series tail yields **two masters** for what the user thinks is one series —
   they drift, both render in Calendar.app, and edits to one never reach the other. That is a worse
   end state than the deletion, produced by the safety feature.
6. **Duplicate guard (undo).** Before recreating, search the target calendar for a matching
   title+start. **Best-effort, not prevention** — the store syncs asynchronously, so a resurrection
   may not have landed yet, and one landing in a different calendar is missed. → `DUPLICATE_EXISTS`.
7. **[rev3] Post-state guard (undo-of-create).** The pre-state hash protects propose→commit; nothing
   protected create→undo, which can span hours. If the model creates "Dentist 14:00", you move it to
   15:30 and add a note, then entry #7 is undone — guard 6 does not fire (start no longer matches)
   and your edits are destroyed. Undo-of-create compares `hash(post_create_state)` against ground
   truth → `EVENT_CHANGED_SINCE_MUTATION`.
8. **Idempotency guard (undo).** Undo targets a **journal entry id**; the entry is marked `undone`
   and a second undo is refused → `ALREADY_UNDONE`.
9. **[rev3] Undo horizon.** Entries older than **72 hours** are not undoable via the tool →
   `UNDO_WINDOW_EXPIRED`. Undoing a three-week-old delete is almost never intended and is exactly
   what an injected model would reach for.

---

## 9. Recurrence, time, and identifier semantics

`EKSpan` offers exactly the two choices Calendar.app asks you:

| Apple's dialog | `EKSpan` | Effect |
|---|---|---|
| "Delete This Event" | `EKSpanThisEvent` | **[rev3]** Adds an *exclusion* for this occurrence; the rest is untouched. (Rev. 2 called this "detaching", which is the wrong term — `isDetached` means an occurrence whose *attributes* were changed and which still exists.) |
| "Delete All Future Events" | `EKSpanFutureEvents` | Removes this and everything after; **past occurrences remain as history** |

- `propose_*` surfaces recurrence explicitly: which occurrence, approximate total, the rule in plain
  words, series bounds. `span` is required on recurring targets and named in words in
  `confirm_summary`.
- **[rev3] Occurrence addressing uses `occurrenceDate`, not start date.** The header is explicit that
  `occurrenceDate` "will remain the same even if the event has been detached and its start date has
  changed" — start would break exactly the detached case §16 tests. Composite key is
  `(eventIdentifier, occurrenceDate)`.
- **[rev3] Resolution method**, previously unstated: EventKit has no composite lookup.
  `eventWithIdentifier:` returns the *first* occurrence only. Resolve by running
  `predicateForEventsWithStartDate:endDate:` over `occurrenceDate ± 1 day` and filtering on the
  composite key. Not-found is a first-class result, not an error tail.
- **[rev3] Identifier rationale corrected.** `eventIdentifier` is chosen because it is the only
  identifier with a store lookup API — **not** because it is stable. The header states it can change
  on calendar move *and* on sync, the same defect rev. 2 wrongly used to disqualify
  `calendarItemIdentifier`. `calendarItemExternalIdentifier` is rejected because it can match
  multiple events.
- **[rev3] Occurrence counting within limits.** A three-year weekly series exceeds the 31-day query
  cap, and `predicateForEvents...` is capped at four years regardless, so open-ended series cannot be
  counted by query at all. `Recurrence.swift` therefore computes an **approximate** count from the
  rule (reported as `~N`, never an exact figure) and reports `unbounded` for series with no end.

**Time.** RFC 3339 with explicit offsets; an IANA time-zone identifier required when local
interpretation is needed, never guessed. Intervals are half-open `[start, end)`; **[rev3] matching
is *overlap*, not containment** — an event straddling the window edge is included, matching
`predicateForEventsWithStartDate:endDate:`. All-day events are date-only with `is_all_day:true`,
never round-tripped through UTC. Explicit sort (`start`, `title`, `id`). Max interval 31 days;
default limit 100, hard 500; no unbounded query, no server-side pagination. Nothing is cached;
every call refetches.

---

## 10. Trust boundary and privacy

All calendar-derived text is `external_untrusted` and may never be interpreted as instructions,
configuration, paths, or shell input (`meta-core-separation-of-instructions-and-data`,
`coding-quality-workflow-integrity`). Server instructions say so. `openWorldHint:true` on
invitation-derived tools. Typed DTOs and schemas throughout. Minimal field set by default (§7).

**[rev3] `calendar_recent_mutations` returns journal *metadata only*** — entry id, timestamp,
operation, span, calendar name, event title, start, `undone` flag. Never the reconstruction payload.
Rev. 2 cut the ICS backup for writing notes and attendee emails to readable plaintext, then exposed
a tool that read those same fields back out of the journal. The full snapshot stays server-side and
is consumed by `propose_undo`/`commit()` internally.

Annotations are hints, not enforcement. Host-side approval is **not** a control — it is an
assumption about your configuration the server cannot observe. If a commit tool is allowlisted in
`/permissions`, or approvals are bypassed, there is no prompt at all.

**The controls live inside the agent's blast radius.** The README and PROJECT-MEMORY must carry this
verbatim: *These controls reduce the blast radius of a mistaken or manipulated model. They do not
defend against an attacker with filesystem write access as your user — such an attacker can edit the
allowlist, truncate the journal, and delete snapshots. Same-uid containment is not achievable
without a privilege boundary this project does not have.*

**[rev3] Two hardening claims from rev. 2 were false and are withdrawn.** "A bypass needs a restart,
which needs you" — false: clients respawn stdio servers on session start, reconnect, crash, and
config reload, with no human action; an attacker edits the config and waits. And "logged to stderr
so tampering is visible in the transcript" — false: MCP server stderr goes to a log file, not the
transcript. Startup-only loading and startup logging are still worth having; the properties claimed
for them were not the ones they deliver.

No telemetry, analytics, network egress, or self-update. README documents what leaves the Mac:
"local MCP" means the *server* is local — the AI host still receives every field we return.

---

## 11. Errors and logging

stdout carries MCP protocol messages **exclusively**. Diagnostics to stderr with control characters
escaped. **[rev3]** Never log titles, notes, attendees, locations, URLs, **calendar or source names**
(also untrusted), or raw framework errors by default — this includes the startup allowlist line,
which must be escaped.

Codes: `PERMISSION_DENIED`, `INTERVAL_TOO_LARGE`, `CALENDAR_NOT_WRITABLE`,
**`CALENDAR_NOT_ALLOWLISTED`**, `EVENT_HAS_ATTENDEES`, `SPAN_REQUIRED`, `TOKEN_EXPIRED`,
**`TOKEN_ALREADY_USED`**, **`TOKEN_INVALID`**, `CONFIRM_SUMMARY_MISMATCH`,
`EVENT_CHANGED_SINCE_PROPOSE`, **`EVENT_CHANGED_SINCE_MUTATION`**, **`UNDO_SPAN_UNSUPPORTED`**,
`ALREADY_UNDONE`, **`UNDO_WINDOW_EXPIRED`**, `DUPLICATE_EXISTS`, `EVENT_NOT_FOUND`. Clean shutdown
when stdin closes.

---

## 12–13. Client integration

Absolute path, argument array, no shell-init or PATH dependence. **[rev3]** `serve` is the argless
default, so both configs pass no arguments.

**Claude Code** — `claude mcp add --transport stdio apple-calendar -- /usr/local/bin/apple-calendar-mcp`
or `.mcp.json`: `{"mcpServers":{"apple-calendar":{"command":"/usr/local/bin/apple-calendar-mcp","args":[]}}}`

**Codex** — `~/.codex/config.toml`:
```toml
[mcp_servers.apple-calendar]
command = "/usr/local/bin/apple-calendar-mcp"
args = []
```

Verify in both: discovery, permission status, bounded query, busy intervals, the full
find → propose → commit flow, the attendee refusal, undo, denied-permission behavior,
restart/disconnect, clean shutdown, no non-protocol stdout.

---

## 14. Containment controls (C1–C5, as amended) **[rev3]**

Rev. 2 referenced C1–C5 without defining C2 or C3, so governance compliance was unverifiable from
the plan alone.

| | Control | Status |
|---|---|---|
| **C1** | Writable-calendar allowlist | **Amended.** Memory claims Work/shared calendars are "read-only by construction"; nothing implements that. Reality: only calendars with `allowsContentModifications == false` are excluded at source. A shared iCloud calendar with write access is writable if allowlisted. |
| **C2** | Destructive calls take identifiers, never selectors | **Amended.** Now `(token, confirm_summary)`. The summary is calendar-derived text, but it is echo-verified against a server-minted value and is never a selector; the token is. |
| **C3** | Two-phase propose/commit + pre-op backup | **Amended.** The `.ics` clause is withdrawn — EventKit has no ICS export API, so it was never implementable. Replaced by per-event JSON pre-state snapshots in the journal. |
| **C4** | Append-only journal sufficient to reverse | Held, plus §8 guards 5–9. **[rev3]** Memory's C4a requires recording the old→new identifier mapping on restore; rev. 2 dropped it. Reinstated. |
| **C5** | No bulk mutation | **Carve-out required.** `EKSpanFutureEvents` mutates N occurrences in one call. C5 means *one event identifier per call*, which may span many occurrences of that one series. |
| **C6** | **[rev3] Attendee refusal** (§8.1) | **New.** Constrains the write surface the way C1–C5 do and is the only control a compromised model cannot argue past. Proposed for formal adoption in the §21 re-evaluation. |

---

## 15. Phases

**Phase 1 — TCC spawn-path gate.** *The whole architecture rests on this.* **[rev3] Explicitly pulls
forward from Phase 2:** `Package.swift` with the `sectcreate` flags, `Info.plist`,
`Entitlements.plist`, and `scripts/sign.sh` with the **stable self-signed certificate** (not ad-hoc —
the experiment is cdhash-sensitive). Build a stub that calls `requestFullAccessToEvents` directly
and prints `authorizationStatus(for:.event)` — **not** `--setup`, which does not exist yet. Grant
from Terminal. Then have Claude Code spawn the same binary and print status again; repeat for Codex.
*Exit:* all hosts report `fullAccess`, **and** System Settings → Privacy → Calendars lists
**apple-calendar-mcp**, not Terminal. *If they disagree, the bare executable is dead and the `.app`
wrapper lands before Phase 2.*

**Phase 2 — Skeleton.** Promote Phase 1's artifacts into the real package; arg dispatch, `--version`.
*Exit:* `otool -s __TEXT __info_plist` shows the section; `codesign -d --entitlements` verifies.

**Phase 3 — Permission lifecycle.** `AuthorizationState`, `SetupFlow`, `Doctor` incl. cdhash
comparison against `setup.json`. *Exit:* `--setup` prompts on clean TCC; **[rev3]** `--doctor`
reports all **five** states (rev. 2 said six, which is unpassable) and detects a cdhash mismatch.

**Phase 4 — Read surface + concurrency decision.** DTOs, schemas, `CalendarStore`, `TimeSemantics`,
`Limits`, **[rev3] five read tools** (`recent_mutations` moves to Phase 6 — it reads the journal,
which Phase 5 builds). Spike both concurrency shapes against §4's criteria. *Exit:* Inspector lists
five tools and returns schema-conforming results; stdout purity verified; **[rev3]** a 500-event
fetch does not delay a concurrent `tools/list` response by more than 250 ms.

**Phase 5 — Guards and substrate, before anything can mutate.** `Allowlist` (with the §5 config
format), `Mutations`, `Recurrence`, `Guards`, `Journal`. *Exit:* unit tests prove token
single-use/TTL/invalidation, pre-state-hash rejection, `confirm_summary` byte-exact rejection, and
**every §8 guard**. **[rev3] Unresolved #2 (Cowork) must be answered before this phase** — it decides
whether guards 5–9 are built at all.

**Phase 6 — Write surface.** Four `propose_*`, four `commit_*` over one `commit()`,
`recent_mutations`. **[rev3] Test data provisioned here:** a disposable calendar, a **second account
that sends a real invitation** (the only way to exercise `organizer != nil && !isCurrentUser`), and a
**subscribed calendar** (the only way to get `allowsContentModifications == false`). *Exit:* every
mutation guarded and journaled; a real restore performed; **a recurring `futureEvents` delete
followed by an attempted undo, which must be refused**; the attendee guard refuses a genuine
invitation; §2's decline/cancellation inference confirmed or corrected.

**Phase 7 — Hardening + release.** Error sanitization, escaping tests, README (destructive warning +
the §10 containment paragraph verbatim), LICENSE + NOTICE, client configs, both smoke tests, and the
**permission smoke matrix** (§16). **[rev3] *Exit:* every §17 DoD clause demonstrably met** — rev. 2
left this phase with no gate at all, so the DoD had nothing to hang from.

---

## 16. Tests

**Unit** — five authorization states; RFC 3339 parsing; caps; filtering; stable sort; all-day across
UTC boundaries; DST, ambiguous and nonexistent local times; **occurrence resolution by
`occurrenceDate` including detached occurrences whose start has moved**; both spans; busy merging;
schema conformance (against §7); stable codes; control-character and log-injection handling
including calendar names; trust labeling; truncation metadata; allowlist keying, startup-only load,
and fail-closed on title/source mismatch; token single-use/TTL/invalidation; `confirm_summary`
byte-exact echo; **every §8 guard**; journal reconstruction against the §7 field set.

**Contract** — initialize; `tools/list`; valid and invalid `tools/call`; annotations; schemas;
structured + text compatibility; stdout purity; stderr-only diagnostics; graceful disconnect.

**Structural** — mutation is reachable only through `commit()`, enforced by the adapter protocol
exposing no other write method. **[rev3]** This is an architectural invariant, not an assertion — a
compile error cannot be observed by a test. The executable check is a symbol scan for EventKit
save/remove outside `CalendarStore.swift`, and it is the *only* falsifiable part of this category;
rev. 2 called it "the backstop, not the mechanism", which left the category with zero executable
assertions.

**Integration (opt-in, env-gated, never against real personal data)** — Inspector; Claude Code and
Codex smoke tests; the Phase 6 fixtures; **history preservation under `futureEvents` asserted
against the store** (it is EventKit's behavior, not ours, so only integration can verify it).

**Hostile content** — (a) control characters and Unicode in titles pass through escaped and
unmodified, stderr uncorrupted — real and falsifiable; (b) an optional scored end-to-end eval
against a live host, **reported as an observation, never a passing gate, and never counted in §17**.

**[rev3] Permission smoke matrix — assigned to Phase 7, with expected outcomes** (rev. 2 listed six
scenarios and zero pass conditions, so any result could be called a pass):

| Scenario | Expected |
|---|---|
| First prompt | Prompt appears; status → `fullAccess` |
| Relaunch | No prompt; status stays `fullAccess` |
| Rebuild in place | **Grant retained** — measured across a real cdhash change (`6b0b4577` → `b772b4fb`). The designated requirement is `identifier "..." and certificate root = H"..."`, i.e. identity-based, so any build signed by the same cert satisfies it. If lost, the cert is not stable and Phase 2 regressed |
| Binary moved | **Grant LOST** — measured 2026-08-19. TCC keyed the row to the absolute path (`client_type=1`), so a moved or reinstalled binary needs a fresh `--setup`. `--doctor` must say this in plain English rather than reporting a generic denial |
| Revoke mid-session | Next call → `PERMISSION_DENIED`, no crash, no stdout pollution |
| TCC reset + re-grant | `--setup` prompts again; `--doctor` green afterward |

---

## 17. Definition of done

Phase 1's gate passed with the grant attributed to our binary under both hosts. Discovery works in
Claude Code and Codex from one absolute-path config. Bounded queries, busy intervals, and the full
find → propose → commit flow succeed against a disposable calendar. Recurring deletes honor both
spans, and history preservation under `futureEvents` is asserted against the store. Undo of a
`futureEvents` delete is refused. Undo is idempotent, horizon-bounded, and duplicate-guarded. The
attendee guard refuses a genuine invitation and returns the §8.1 field set. Writes to
non-allowlisted and to `allowsContentModifications == false` calendars are rejected with distinct
codes. Allowlist resolution fails closed on title/source mismatch. Every mutation is journaled with
the §7 field set, including the old→new identifier mapping on restore, and a real restore has been
performed. `calendar_recent_mutations` returns metadata only. stdout carries protocol only. The
permission matrix passes with the §16 expected outcomes. README carries the destructive-capability
warning **and** the §10 containment paragraph verbatim; **[rev3] PROJECT-MEMORY carries the same
paragraph** (rev. 2 mandated it in §10 and then omitted it from its own DoD). LICENSE is Apache-2.0
with any borrowed expression attributed via NOTICE. The §21 governance re-evaluation is recorded.

## 18. Risks

| Risk | Mitigation |
|---|---|
| **TCC grant attributes to the launching app** | **RESOLVED 2026-08-19.** Confirmed real; the `.app` wrapper fallback was tested and does **not** work. Fixed by a self-disclaiming re-exec (`Reexec.swift`). Residual risk: `responsibility_spawnattrs_setdisclaim` is private API, resolved via `dlsym` so its removal degrades to inherited-permission mode rather than failing; `--doctor` must report which mode is live |
| Hardened runtime without entitlement → silent permanent denial | Ship both always; `--doctor` verifies |
| Deleting an invited/organized event notifies real people | §8.1 guard, ground-truth-based |
| Prompt injection driving a destructive write | C1, single guarded `commit()`, echo-verified summary. **Reduces blast radius and improves reviewability; does NOT prevent find → propose → commit.** Host approvals are an assumption, not a control |
| Controls sit inside the agent's blast radius | Startup-only load; stated verbatim in README and memory (§10) |
| **[rev3] `create` was outside the guarded path** | Fixed — create now proposes and commits like everything else; `attendees` rejected outright |
| Wrong occurrence or span mutated | `occurrenceDate` composite key; span required and named in the verified summary |
| Reinstalling or moving the binary invalidates the grant | **The grant is path-keyed** (measured). `--setup` runs at the final installed path; `--doctor` reports plainly when the grant belongs to a different path. Rebuilds at the same path are safe |
| Undo duplicates or destroys later edits | Guards 5–9 |
| **[rev3] Server restart invalidates in-flight tokens** | Expected; surfaced as `TOKEN_INVALID` |
| **[rev3] `find_events` truncation hides the target** | 500-cap with truncation metadata; the model must narrow the window rather than assume completeness |
| **[rev3] Permission model verified only on macOS 26.5** | Target is macOS 14; 14.0–26.4 behavior unverified and `--doctor` must not claim otherwise |
| Pre-state hash too strict/loose vs sync churn | Excludes `lastModifiedDate`; tested against live iCloud sync |
| SDK pre-1.0 | `.exact("0.12.1")`; `Package.resolved` committed |

## 19. Source log

`docs/source-log.md`, appended opportunistically — **not a phase gate**. The local SDK headers are
the verification source of record; Apple's web docs are JavaScript-rendered and were not
machine-readable. Header-verified facts, external sources, and inference are kept separate (§2).

## 20. Decisions requiring human approval

**Settled:** Apache-2.0 · attendee events hard-refused with an actionable payload · recurrence
mirrors Apple's two-span dialog · undo stays model-callable behind guards 5–9 · update stays in v1
with recurrence.

**Open:**
1. Bundle identifier — proposed `com.collierhmg.apple-calendar-mcp`.
2. Default allowlist empty ⇒ writes fail closed on a fresh install. Confirm, or name a default.
3. **Does Cowork run locally or remotely?** Load-bearing for undo — answer before Phase 5.
4. Adopt the attendee refusal as **C6** in the governance re-evaluation.
5. Any borrowing of expression from the MIT references — flagged case by case.

## 21. **[rev3] Memory reconciliation — before Phase 1**

`_ai-context/PROJECT-MEMORY.md` now contradicts this plan in ten places and will mislead the next
session that loads it. Required edits, plus a fresh `evaluate_governance` covering the C1/C2/C3
amendments and the §10 residual risk:

- C1: replace the false "Work, shared, and subscribed calendars are read-only by construction" with
  the §14 amendment.
- C2: record the `(token, confirm_summary)` signature and correct the "ID + token ONLY" guarantee.
- C3: withdraw the `.ics` clause; record per-event JSON snapshots.
- C4a: reinstate the old→new identifier mapping; note undo is now a guarded propose/commit tool.
- C5: add the one-identifier-per-call carve-out for `EKSpanFutureEvents`.
- Add **C6** (attendee refusal) pending approval of §20.4.
- Replace "Done looks like" — it is read-only-era text that directs testing **at the real calendar**,
  which is now hazardous. Point at §17.
- Correct the signing rows: ad-hoc → stable self-signed cert; hardened runtime **is** required.
- Add the four decisions settled this session that never reached memory.
- Add the §10 containment paragraph verbatim.
