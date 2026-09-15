<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Specification

**Status:** the read surface is **built and shipped**; the write surface is **specified and
not built**. This document separates the two throughout — an earlier version described the
whole fourteen-tool design under a single "not yet built" banner, which made the shipped
half invisible and the unbuilt half look imminent.

Field-level schemas, guards, error codes and phase gates live in
`docs/IMPLEMENTATION-PLAN.md` — the repository-owned canonical plan, and authoritative. This
is the summary.

---

## What it does today

Lets an AI assistant inspect calendars, retrieve bounded sets of events, and reason about
availability on the user's macOS Calendar. **Nothing it exposes can change a calendar.**

## What it is specified to do later

Create, update, delete and restore events, with every mutation proposed first and confirmed
second, under containment controls C3–C7. Gated: see "Not built" below.

## Shipped tool surface (5, all read-only)

| Tool | Purpose |
|---|---|
| `calendar_permission_status` | Authorization state, identity, and where the machine thinks it is. Never prompts |
| `calendar_list_calendars` | Event-supporting calendars and whether each is writable |
| `calendar_list_events` | Bounded interval query |
| `calendar_find_events` | Text search across the whole window |
| `calendar_busy_intervals` | Availability without titles |

Each declares an `outputSchema` and returns `structuredContent` plus a text summary. Each is
annotated `readOnlyHint: true`, `destructiveHint: false`; the three returning
externally-authored text also carry `openWorldHint: true`.

Failures return `isError` with a stable code leading the message:
`PERMISSION_DENIED`, `BAD_TIMESTAMP`, `BAD_TIME_ZONE`, `END_NOT_AFTER_START`,
`INTERVAL_TOO_LARGE`, `MISSING_ARGUMENT`, `UNKNOWN_TOOL`, `CALENDAR_STORE_UNAVAILABLE`,
`CALENDAR_STORE_BUSY`, `CALENDAR_TIMEOUT`, `CALENDAR_STORE_WEDGED`.
The code is contractual; the prose after it is not.

**Response envelope:** `items`, `truncated`, `total_matched`, `effective_time_zone`,
`limits_applied`, `trust` — all declared and all required. `effective_time_zone` is the zone
every timestamp in that response was rendered in. `limits_applied` reports what the call
actually applied, with `null` where a limit does not apply to it.

## Optional approval diagnostic (0.2.2 candidate)

`calendar_approval_probe` is absent unless launched with `--enable-approval-probe`, including
when combined with `--read-only`. It accepts an empty argument object only and requires
explicit form support. A fixed form requests required boolean `confirm`, initially false.
Only a timely `accept` with exactly `{"confirm": true}` yields diagnostic acceptance.

The result has exactly `outcome`, `calendar_changed: false`, and `authorizes_writes: false`.
Outcomes: `accepted`, `declined`, `canceled`, `unsupported`, `busy`, `error`, `timed_out`,
`disconnected`, `invalid_response`. Outer-call cancellation suppresses its response before
transport commitment. No response can retract bytes already handed to the transport.
A 30-second monotonic deadline includes elicitation sending and answer waiting. An overlap
returns `busy` without queuing another prompt. No Calendar content is accessed or changed;
no mutation journal entry or authorization token is created. A synthetic accepted response
is not proof that a human interacted with the client.

## Not built

**No write tool exists.** The propose/commit design below is specification. `Journal.swift`
is built as substrate and has no caller, so nothing reverses anything yet.

`calendar_recent_mutations` — reading the journal — arrives with the write surface.

Permission setup is **not** a tool and never will be — a TCC prompt needs a foreground
process, which a stdio-launched server cannot present. That is `--setup`, with `--doctor`
alongside.

## The planned mutation flow

```
find_events(query:"standup")     → candidates + ids
propose_delete(id, occurrence_date?, span)
                                 → preview + confirm_summary + token
                                   "1 of ~155 occurrences, weekly, Jan 2025 → Dec 2027"
commit_delete(token, confirm_summary)
```

## Planned guards (all inside `commit()`, all against refetched ground truth)

1. **Attendees / external organizer → CONFIRM, not refuse** *(amended 2026-08-25)*. Removing
   such an event is permitted behind a per-call human confirmation stating plainly that the
   tool will remove it through EventKit, that this may notify other participants, and that
   attendee/invitation state cannot be restored. The operation is called **remove** — never
   presented as equivalent to Calendar.app's Decline, because EventKit exposes no RSVP setter
   (`participantStatus` is `readonly`) and what an account server does with a removal has not
   been measured here. The confirmation carries title, start, calendar, organizer and attendee
   count. What stays **refused**: setting `attendees`, and setting RSVP status explicitly —
   neither is expressible in EventKit at all.

2. **Writability** — `allowsContentModifications`, EventKit's own answer and nothing else.
   Not `isImmutable`, which governs the calendar object rather than its contents. The
   writable-calendar allowlist was **withdrawn 2026-08-20**; a calendar shared with the user
   is writable the moment macOS says so, with no config change.
3. **Span required** on any recurring target.
4. **A `futureEvents` deletion → refuse while restoration is unsolved.** Do not permit
   deletion and refuse only its restore; recreating a series tail yields two competing masters.
5. **Duplicate check** before recreating (best-effort; sync is asynchronous).
6. **Post-state hash** on restore-of-create, so later human edits are not destroyed.
7. **Idempotency** by journal-entry id, keyed on the journal tail so it survives a respawn.
8. **72-hour restore horizon.**

## Snapshot completeness gate

Before delete or update, define and test a typed snapshot for every reconstructable field:
calendar identity, title, start/end, all-day state, time zone, location, notes, URL,
availability, recurrence, structured location, and existing alarms (including their timing
and supported location/action metadata). The read DTO is not a snapshot. Apple exposes
`alarms` as writable (`EKCalendarItem.h:101`) and structured location as writable
(`EKEvent.h:96`); omission from a create schema does not justify losing them during restore.
For any populated field not yet reconstructable, refuse that mutation under C7; only the
already-approved attendee/invitation exception is exempt. The field matrix and disposable
calendar round trip remain prerequisites, not implemented recovery guarantees.

## Semantics

**Recurrence** mirrors Apple's own dialog. `EKSpan` has exactly two values:
`ThisEvent` (adds an exclusion for that occurrence) and `FutureEvents` (removes this and
all after, **preserving past occurrences as history**). There is no "all events" span.

**Occurrences** are addressed by `(eventIdentifier, occurrenceDate)` — `occurrenceDate`,
not start date, because it survives detachment.

**Time** — RFC 3339 with explicit offsets; IANA zone required when local interpretation is
needed, never guessed. Half-open `[start, end)`, matching by *overlap*. All-day events are
date-only and never round-tripped through UTC. Explicit sort; EventKit guarantees no order.

**Limits** — 31-day max interval, 100 default / 500 hard result cap, no unbounded query, no
server-side pagination, no caching. A search covers the **whole** window before it filters and
caps, so `total_matched` counts every match rather than the matches in the first page.

## Out of scope for v1

Reminders. Bulk mutation across distinct events. Network listener, telemetry, CalDAV,
iCloud credentials, self-update. Prebuilt binary distribution.
