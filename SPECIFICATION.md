<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Specification

**Status:** Specified, not yet built. Field-level schemas, guards, error codes and phase
gates are in `docs/IMPLEMENTATION-PLAN.md` (rev. 3) §6–§11 — authoritative. This is the
summary.

---

## What it does

Lets an AI assistant inspect calendars, retrieve bounded sets of events, reason about
availability, and create, update, delete and undo events on the user's macOS Calendar —
with every mutation proposed first and confirmed second.

## Tool surface (14)

**Read (6)** — `permission_status` (never prompts), `list_calendars`, `list_events`,
`find_events`, `busy_intervals`, `recent_mutations` (journal **metadata only**).

**Propose (4)** — `propose_create`, `propose_update`, `propose_delete`, `propose_undo`.
Read-only; each returns a preview plus a single-use token and a server-minted
`confirm_summary` string.

**Commit (4)** — `commit_create`, `commit_update`, `commit_delete`, `commit_undo`. Each is
~5 lines over one guarded `commit()`. Takes `(token, confirm_summary)`; the summary must
be echoed byte-exactly and is verified against the server's own value.

Permission setup is **not** a tool — a TCC prompt needs a foreground process, which a
stdio-launched server cannot present. That is `--setup`, with `--doctor` alongside.

## The mutation flow

```
find_events(query:"standup")     → candidates + ids
propose_delete(id, occurrence_date?, span)
                                 → preview + confirm_summary + token
                                   "1 of ~155 occurrences, weekly, Jan 2025 → Dec 2027"
commit_delete(token, confirm_summary)
```

## Guards (all inside `commit()`, all against refetched ground truth)

1. **Attendees / external organizer → refuse.** Deleting an invited event sends a decline
   to the organizer and everyone invited; deleting one you organized sends a cancellation.
   Irreversible, with a human audience. The refusal returns title, start, calendar,
   organizer and attendee count so the user can find and decline it by hand.
2. **Writability** — `allowsContentModifications && inAllowlist`. Not `isImmutable`, which
   governs the calendar object, not its contents.
3. **Allowlist** — distinct error from (2), since an empty allowlist is the default.
4. **Span required** on any recurring target.
5. **Undo of a `futureEvents` delete → refuse** (recreating a series tail yields two masters).
6. **Duplicate check** before recreating (best-effort; sync is asynchronous).
7. **Post-state hash** on undo-of-create, so later human edits are not destroyed.
8. **Idempotency** by journal-entry id.
9. **72-hour undo horizon.**

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
server-side pagination, no caching.

## Out of scope for v1

Reminders. Bulk mutation across distinct events. Network listener, telemetry, CalDAV,
iCloud credentials, self-update. Prebuilt binary distribution.
