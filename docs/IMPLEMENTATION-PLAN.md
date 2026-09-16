# apple-calendar-mcp — Implementation Plan (rev. 7)

## Context

A local stdio MCP server letting Claude Code, Codex and Claude Desktop work with the macOS
user's Apple Calendar through native EventKit. Personal use, public at
`github.com/jason21wc/apple-calendar-mcp` under Apache-2.0.

**Why this is a rewrite rather than another revision.** Rev. 4 patched by adding banners that
pointed at other sections instead of editing them. A coherence audit found 11 dangerous
contradictions and named the cause: *every correction announced elsewhere drifted; every
correction applied in place held.* From rev. 5 onward — including this one — corrections are
applied at each site and superseded material is deleted rather than marked. The withdrawn designs and the reasoning that
killed them are preserved in `_ai-context/LEARNING-LOG.md` and `PROJECT-MEMORY.md`, which is
where reasoning belongs.

**Single source of truth: this file, in the repository, as of rev. 7.** It was previously a
*copy* of a plan held outside the repo in a private directory, to be re-copied on every
revision — and that arrangement failed exactly as designed to: a stale rev. 3 copy sat in the
repo while `OPERATIONS.md` named it authoritative. A canonical document that lives where
nobody can review it, and is kept current by remembering to copy it, is not canonical. This
file is now the original: version-controlled, reviewable in a diff, and the only one. Every
other document in this repo summarises or links here rather than restating what is here.

---

## 1. Status

| Phase | State |
|---|---|
| 1 — TCC identity | **Complete.** Gate passed only after adding the self-disclaiming re-exec |
| 2 — Skeleton | **Complete.** Command dispatch, embedded plist, signing scripts |
| 3 — Permission lifecycle | **Complete.** `--setup`, `--doctor`, five authorization states |
| 4 — Read surface | **Complete.** Five read-only tools, in daily use. Orphan behaviour verified 2026-08-22, closing the last blocking exit criterion. One non-blocking criterion — the 250 ms concurrency measurement — remains unmeasured and is recorded as such in §5 |
| 5 — Guards and substrate | **Substrate built** (`Journal.swift`). The guards land with the write tools they guard |
| 6 — Write surface | **Not started, and gated** — §6 Gate 1 is unanswered |
| 7 — Hardening and release | Not started |

**Nothing this server exposes today can change a calendar.** The five shipped tools are all
read-only; no write tool exists.

Shipped and installed at `/usr/local/bin/apple-calendar-mcp` (root-owned), holding the only
live Calendar grant. `./scripts/test.sh` is green. Security-audited; all HIGH and MEDIUM
findings fixed.

A count of passing tests is deliberately not recorded here or in any other document. It was
written down in four places, drifted to four different numbers, and none of them was checkable
without running the suite that reports it anyway.

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
MCP/                ServerBootstrap (server loop, stdin-EOF shutdown), ToolRegistry
                    (names, schemas, annotations), ToolHandlers (dispatch, ToolError codes)
Calendar/           Models (DTOs), Limits, TimeSemantics, CalendarScope, EventSearch, Journal
EventKit/           CalendarStore (the adapter), AuthorizationState (five states)
Diagnostics/        Doctor, SetupFlow, TCCInspector
```

The directory names do **not** mirror the conceptual layer names (`MCPLayer → CalendarKit →
EventKitAdapter`), and the on-disk layout wins. `CalendarStore` is the only file that touches
calendar CONTENT; three others import EventKit for the authorization API alone, which is a
narrower and truer claim than "the only file that imports EventKit" — that one was wrong for
four revisions.

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
with `EKEventStore` confined to one serial executor and EventKit objects never crossing the
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
| ~~C1~~ | Writable-calendar allowlist | **WITHDRAWN** 2026-08-20 by human decision (`gov-120ca260c415`). Writable = `allowsContentModifications`, whatever EventKit says — including calendars shared with the user later, with no config change |
| ~~C2~~ | `confirm_summary` echo | **SUPERSEDED**, but NOT by what was recorded. The stated replacement was host-enforced `toolPolicy: "ask"` — which has never been configured on this machine (§6). No verified human-approval mechanism has replaced it yet; see BACKLOG #1 |
| ~~C2a~~ | Always confirm, even on a single match | **SUPERSEDED** on the same false premise, and the requirement it encoded — never mutate without a fresh confirmation — is carried forward into the write design's elicit-inside-the-mutating-call shape (§6) |
| C3 | Two-phase propose/commit plus a per-event JSON pre-state snapshot | **Adopted; not in force.** No propose/commit path and no snapshot code exists |
| C4 | Append-only journal sufficient to reverse | **Substrate built, no caller.** `Journal.swift` is never invoked |
| ~~C4a~~ | Undo semantics | **SUPERSEDED by C7** |
| **C7** | **Every mutation must be restorable**, except attendee/invitation state — restore means *the information is back*, not that the original object returns | **Adopted with a named exception 2026-08-25**; not in force until the first write tool. See §4a and §6 |
| C5 | No bulk mutation; one event identifier per call, which may span occurrences of that one series | **Adopted; not in force** |
| C6 | Events with attendees or an external organizer: **confirm, do not refuse** | **Amended and CONFIRMED by the human 2026-08-25** (`gov-800ad831a848`). The blanket refusal is withdrawn; see §4a |

### 4a. The permission model — decided 2026-08-25

Three tiers. This supersedes the vaguer "every mutation is gated" language elsewhere.

| Tier | Covers | Mechanism |
|---|---|---|
| **Silent** | All reads | Shipped. `readOnlyHint: true`; no prompt |
| **Confirm** | **Every write** — create, update, delete and restore, including group events and shared or network calendars | **Not yet built or measured.** BACKLOG #1 |
| **Refuse** | Only what EventKit cannot express or the tool cannot safely bound: setting `attendees`, setting RSVP status explicitly, bulk deletion across distinct events, and `futureEvents` deletion while restoration is unsolved | Server-side, unconditional |

**Reads are untouched by all of this.** Every event remains fully readable, including meetings
with attendees and ones organised by other people. The tiers govern changes only.

**The confirmation must say what is actually true.** For a group event: *"This will remove
'<title>' through EventKit. It may notify other participants, and the attendee/invitation state
cannot be restored. Continue?"* The operation is called **remove**. It is not called Decline and
must not be presented as equivalent to Calendar.app's Decline, because EventKit exposes no RSVP
setter and what an account server does with a removal is unmeasured.

**Nothing in the Confirm tier may ship until a human-approval round trip is demonstrated**
(BACKLOG #1). The policy is decided; the mechanism is not.

**"Adopted" is not "enforced", and this table said "Live" until 2026-08-22.** There is no
mutation path in the shipped server, so there is nothing for any of these to gate: no guard in
this table appears in `Sources/`. They are decisions binding the write surface when it is
built, and a fresh `evaluate_governance` is required to weaken one — which is exactly why they
are recorded now. But a reader who took "Live" as "running" would have believed mutation
guards were already enforced, when they enforce nothing today because the server changes nothing.

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

## 5. Phase 4 — the read surface (complete)

The first phase that delivers usable value: ask what is on the calendar and when you are free.
Shipped, published, and in daily use.

### Tools (five, all read-only)

| Tool | Purpose |
|---|---|
| `calendar_permission_status` | Report state. Never prompts |
| `calendar_list_calendars` | Event-supporting calendars, with true writability (`allowsContentModifications`, **not** `isImmutable`) |
| `calendar_list_events` | Bounded interval query |
| `calendar_find_events` | Search by term → candidates |
| `calendar_busy_intervals` | Availability without titles |

`calendar_recent_mutations` moves to Phase 6 — it reads the journal, which Phase 5 builds.
**These five are the default surface.** Installed 0.2.2 also provides an opt-in harmless
approval diagnostic (§6). The propose/commit tools described in §6 do not
exist; anything describing a fourteen-tool surface is describing the plan, not the server.

### Data model

**`EventDTO`, default field set:** `id`, `occurrence_date` (null for non-recurring),
`calendar_id`, `title`, `start`, `end`, `is_all_day`, `time_zone` (**nullable** — all-day
events have none), `status`, `availability`, `is_recurring`, `is_detached`, `has_attendees`,
`trust: "external_untrusted"`.

**Opt-in only** via `include_fields`: `notes`, `url`, `location`, `attendee_count`,
`organizer_name`. `attendees` as a list is never returned — it is readonly in EventKit.

**Response envelope:** `items`, `truncated`, `total_matched`, `effective_time_zone`,
`limits_applied`, `trust` — all six declared in the schema and all six `required`. Every tool
declares an `outputSchema` and returns `structuredContent` plus a serialized text result.

`limits_applied` reports what THIS call applied: `limit` is the effective per-call cap (null
when none was applied), `max_result_limit` is the ceiling a caller may request, and
`max_interval_days` is the window cap (null for calls taking no window).

`effective_time_zone` is the zone every timestamp in the response was rendered in — the
caller's `time_zone` when given, the machine's live zone otherwise. One zone per response.

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

`CalendarStore` owns a lazily initialized `EKEventStore` on a custom `SerialExecutor`
backed by a serial dispatch queue. It guarantees serialization, not affinity to one permanent
OS thread. EventKit explicitly recommends dispatch queues for synchronous queries
(`EKEventStore.h:291-293` in the local SDK). EventKit objects never cross the adapter boundary.

`CalendarReadGate` is a separate actor outside that executor. It admits one content read;
overlap returns `CALENDAR_STORE_BUSY` without submitting another operation. An admitted read
has a 15-second monotonic deadline. Expiry returns `CALENDAR_TIMEOUT` and permanently closes
admission; later reads return `CALENDAR_STORE_WEDGED` and request a server restart. Completion
checks the actual clock too, so delayed timer delivery cannot turn an overdue result into
success. Caller cancellation returns promptly to the MCP SDK, but the active slot and timer
remain until the underlying operation ends. Late completion never reopens a wedged gate.
Permission status and `tools/list` remain outside the gate.

The worker is unstructured: a task group would wait for a noncancellable child before exiting
and defeat the timeout. EventKit execution itself is not canceled. This wrapper is read-only;
future mutations require uncertain-outcome reconciliation, and elicitation needs separate
SDK pending-request cleanup. Neither may reuse the read gate by analogy.

### Server loop

**stdin EOF is unconditional shutdown.** This is the only defence against the supervisor being
SIGKILLed, which no signal handler can cover: stdin is inherited directly, so the client's
pipe closure reaches the child even when the supervisor is gone.

### Exit criteria

Met, except where stated. MCP Inspector lists five tools and returns schema-conforming results. stdout carries protocol
messages only. **Orphan behaviour verified 2026-08-22**, after being carried as an open gate
for three phases: `ServerLifecycleTests` launches the real binary, waits for the disclaimed
child to appear, and asserts that closing stdin, `SIGTERM`, and `SIGKILL`-then-EOF each leave
no surviving child. It was untestable before only because every earlier subprocess test
invoked `--version`, which exits in milliseconds — the criterion needed a command that stays
up, and `serve` is the first one. Mutation-checked in both directions: disabling signal
forwarding fails the `SIGTERM` case and leaves the other two passing, which is the correct
separation, since EOF covers `SIGKILL` independently of any handler.

The concurrency criterion — a 500-event fetch not delaying a concurrent `tools/list` by more
than 250 ms — is **not measured**. It needs a populated real calendar, and integration work
runs against a disposable calendar only. Recorded as unmet rather than assumed.

### The read-surface audit (2026-08-22)

Phase 4 shipped, and a contract audit against the implementation found the claims below false.
All were fixed rather than documented around; each has a synthetic test needing no Calendar
grant. None came from a bug report — they came from reading each tool's contract against what
the code does.

| Claim | Reality as shipped | Now |
|---|---|---|
| Every tool declares an `outputSchema` | `calendar_permission_status` and `calendar_list_calendars` returned `structuredContent` with none | Both declare one; a test asserts every tool does |
| The envelope is declared | `limits_applied` was emitted and declared nowhere, so nothing validated it | Declared and `required`; the schema checker now also rejects emitted-but-undeclared fields |
| `effective_time_zone` names the zone timestamps were rendered in | It reported the caller's `time_zone` while `start`/`end` rendered in the machine's | One zone per request renders every timestamp, and is what gets reported |
| `limits_applied.limit` is the limit in force | Always the hard ceiling, so a default query claimed 500 and returned 100 | The effective per-call limit; null where no cap applies |
| A search reports what it matched | It filtered the first 500 events only, so `total_matched` counted matches within a page and "no matches" could be false | Filter the whole window, then cap; truncation is applied after matching |
| Untrusted text carries `openWorldHint` | `calendar_list_calendars` returns calendar and source titles — attacker-influenceable — with `openWorldHint: false` | Marked open-world |
| Failures carry stable codes | Text-only prose, no code anywhere in the source | Every failure leads with a stable `UPPER_SNAKE` code (§8) |
| An unknown tool name is reported as such | The access gate ran first, so a typo'd name without a grant returned `PERMISSION_DENIED` — pointing the caller at a permission that was not the problem | The name is checked against the registry before the gate, and the refusal lists the tools that do exist |

---

## 6. The write surface — redesigned 2026-08-20

### The reframing that unblocked it

Three write designs died on making delete reversible. All three assumed *reversible* meant
**the original event comes back** — and under that assumption it is genuinely impossible:
`eventIdentifier` changes on sync, invitation state cannot be reconstructed, and series
membership cannot be restored.

The human, asked directly, wanted something weaker and entirely achievable:

> *"I don't specifically need it to 'revert'. I need to be able to put things back the way it
> was, but it doesn't have to be the exact calendar event — it can be a new one with all the
> same info."*

**C7: every mutation must be restorable, where restorable means the information is back.** A
new event carrying the same field values satisfies it. Identity is not the requirement.

**Named exception, approved 2026-08-25.** `attendees` is the one field a snapshot cannot
reproduce (`readonly`, `EKCalendarItem.h:97`). C6 now permits attendee/external-organizer
removal behind per-call confirmation that states the EventKit action may notify participants,
that invitation state cannot be restored, and that recovery may require asking to be
re-invited. Exact EventKit removal semantics remain unmeasured; the tool must call the action
*remove* and never claim equivalence to Calendar.app's Decline.

**Shape, from `acct-ledger-integrity-le2-audit-trail-immutability`** (surfaced by
`gov-120ca260c415`): *corrections are made through reversing entries, never by editing or
deleting the original record.* Restore is a **new forward operation that references the original
journal entry** — not a rollback. The journal keeps both. Delete-and-recreate would lose the
history; a reversing entry keeps it, and `calendar_recent_mutations` can then show a human what
happened and what undid it.

### Approval: reads silent, writes gated — MECHANISM UNRESOLVED

**Nothing in this section has been demonstrated end to end.** Read it as two candidate paths,
not as a design decision. Corrected 2026-08-22/23 after the premise it rested on collapsed.

**What is actually known about `toolPolicy`.** Strings exist in Claude Desktop's bundle:
`"Allow once"` / `"Allow for this task"` / `"Allow for all tasks"`; `"running unattended —
nobody is present to approve it."`; `readOnlyHint` 35 refs, `destructiveHint` 30, `toolPolicy`
5. The key is documented as per-server, `blocked > ask > ask-session > allow`, strictest wins.

**What was wrongly recorded as known.** That `toolPolicy: {"*": "ask"}` was configured here and
that a read query had been measured against it. **It has never been set** — absent from every
server, from `config.json`, and from both August backups. The 2026-08-20 "measurement" observed
the no-policy default and proves nothing about `readOnlyHint` exemption or write prompting.
BACKLOG #23 exists to establish whether the key does anything at all.

**The second candidate: server-initiated elicitation.** The SDK exposes
`Server.requestElicitation`. Its appeal is that it lives in the binary we sign rather than in a
config key that must be remembered — the failure that produced this entire correction. Three
constraints, verified in the original upstream 0.12.1 SDK rather than assumed:

- **It does not fail closed as shipped.** `validateClientCapability` is wrapped in
  `if configuration.strict`, and `Configuration.default` is `strict: false`. We pass no
  configuration, so the check is a no-op. Any refusal must be **ours**, written explicitly.
- **The capability has sub-capabilities.** `Client.Capabilities.Elicitation` carries separate
  `form` and `url`. Form confirmation requires `elicitation?.form != nil`; the top-level check
  is insufficient, and strict mode only tests the top level anyway.
- **There is no timeout.** `sendAndAwait` awaits `task.value` unbounded, so a client that never
  answers strands the tool call and leaves a `pendingRequests` entry. Racing a task around it
  abandons the request rather than cancelling it. The public `cancelRequest(id)` only sends a remote
  cancellation notice; it does not remove/resume the local pending request. Same class of
  external wait as the read gate (§5), with different cleanup requirements.

The `0.2.2` candidate now repairs that request lifecycle in an attributed, pinned local
SDK source snapshot and wires `calendar_approval_probe` behind `--enable-approval-probe`.
The probe requires explicit form support, admits one pending question, and uses a 30-second
monotonic deadline. It cannot access Calendar content, append to the journal or grant future
write permission. See [the implementation design](APPROVAL-PROBE-DESIGN.md) and
[SDK provenance](../Vendor/swift-sdk/README.md). Final validation and live measurement remain
separate gates. Installed `0.2.2` exposes the opt-in probe in Codex; its first result was
`canceled`, with human UI observation still pending. Subsequent diagnostics succeeded.

**A capability declaration is not a human.** It says the client claims support. Only an
observed round trip returning `.accept` demonstrates a person answered, and even that
demonstrates it for one client at one version.

**Host approval is also client-specific.** Claude Desktop's `toolPolicy` is one candidate,
not the portable interface. The [OpenAI MCP guide](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)
documents Codex `default_tools_approval_mode = "writes"` and per-tool `approval_mode` overrides.
These are unverified candidates here, not settings applied by this project. A false form
elicitation flag does not establish that a client lacks its own tool-approval mechanism.
Whichever path is selected must demonstrate the same human-confirmation and refusal contract.

**Gate 1, before any write code: demonstrate an enforced human-approval round trip**, and
demonstrate that absence, refusal, cancellation, error and non-response all fail to a refusal.

**Do not borrow a sibling server's write tool for this.** It was tried twice and failed twice.
The 2026-08-19 attempt ran through the remote-devices bridge and measured this project's own
governance hook. The 2026-08-22 attempt ran in Cowork against `apple-mail` and produced a null
result with **three sufficient explanations**: `toolPolicy` was absent, that server's proxy
only order-gates and consumes no verdict, and the two tools chosen never elicit server-side at
all. A null result standing on a stack of sufficient causes is evidence about none of them.

The experiment belongs in **our** binary, where every layer is ours to control — and asking a
human is orthogonal to mutating anything, so it needs no write tool to exist. See BACKLOG #24.
If host policy is selected, verify that host's per-tool configuration: writes confirmed,
reads silent. Writes `"ask"` with reads unlisted is a candidate for hosts supporting that
setting, not a portable configuration or a requirement to use Claude Desktop/Cowork.

### Status

**Built:** `Journal.swift` records intent before a future save and outcome after. Both calls
throw on storage failure; a returned intent ID acknowledges a complete record followed by
`fsync` of the file and directory entries, including newly created ancestors. This is an OS
flush acknowledgement, not protection against hardware failure. No mutation may follow a
failed intent write. If outcome recording fails after a future save, callers must report an
uncertain recorded outcome and reconcile it, never blindly repeat the mutation.

Appends use O_APPEND plus in-process serialization and nonblocking cross-process file locks.
Readers take shared locks; active writers produce `storageBusy`, not corrupt-history errors.
The reader scans fixed-size blocks backwards across monthly files, with optional `since`
filtering for a recovery horizon. Display tails stop when enough entries are found; orphan
reconciliation never uses a display cutoff. Scans have an explicit byte budget and oversized,
unreadable, or corrupt history throws rather than silently becoming empty. New rotation uses
UTC; horizon selection includes a margin for older files rotated in the local zone. No
production caller exists and no live journal cleanup is performed by these changes.

**Not built:** every guard in §6, and every write tool. The journal is substrate with no
caller. Nothing reverses anything yet.

### Remaining gates before `calendar_create_event`

1. **Write-prompt confirmation** (above). Blocking.
2. ~~`source_type` guard~~ — **WITHDRAWN with C1.** Its entire rationale was CalDAV propagation
   on shared calendars, which the human now explicitly wants.
3. **Explicit rejection of `alarms` and `recurrence`** on create, alongside `attendees`. `alarms`
   is read-write and is the one field that makes a created event actively interrupt a human on
   every device. Rejecting by omission means a later revision adds it as "just another optional
   field".
4. **Reversal keys recorded by content, not identifier alone.** `eventIdentifier` changes on
   sync and EventKit re-syncs immediately after a successful save, so the id in an outcome entry
   can be stale within seconds on a CalDAV calendar. Record
   `(calendar_id, title, start, end, creationDate)` so a reversal can re-find by content.
5. **All-day construction tested before written.** `isAllDay = true` does not normalise the
   dates, and EventKit stores all-day `end` **inclusively** — a naive `[midnight, midnight+24h)`
   produces a **two-day** event.
6. **Snapshots must capture every reconstructable field**, not the read DTO's default set. The
   DTO withholds `notes`, `url` and `location` unless requested; a snapshot built from it would
   drop them silently, and the loss would surface at restore time, when the original is gone.
   Include existing alarms and structured locations. The complete snapshot and supported-field
   matrix must be verified before delete; rejecting alarms on create does not preserve alarms
   on an existing event. A field outside the attendee/invitation exception that cannot be
   reconstructed makes that particular mutation unrestorable and therefore refused.

### Build order

`calendar_create_event` → `calendar_delete_event` **with restore in the same change** →
`calendar_update_event`. Delete never ships ahead of its restore path. `destructiveHint: true`
on delete; `readOnlyHint: true` stays on all five read tools.

**Idempotency.** An in-memory dedupe does not stop the realistic retry: clients respawn stdio
servers without warning, so the retry reaches a fresh process with an empty set. And returning
the prior identifier silently reports success for work not done — two identical 30-minute blocks
is a legitimate request. Return a distinct `DUPLICATE_SUPPRESSED` outcome carrying the prior id,
keyed on the journal tail so it survives a respawn.

**What the journal is not.** It is substrate and a user-facing record. Until restore is written,
nothing reverses anything: the honest claim is that a human can undo one additive event by hand
in Calendar.app, which was true before the journal existed.

### EventKit specifics to honour when create is written

`event.calendar` must be assigned from a refetched calendar or the save fails. `EKEvent` must be
constructed on the store's serial executor, or EventKit objects cross the adapter boundary the
architecture forbids. `title` is nullable and EventKit will happily save an empty one, producing
a near-invisible event the user cannot find to delete. `timeZone` does not move the event —
`startDate` is the instant — so setting one without the other is a silent offset error. `url` is
an `NSURL` and a malformed string becomes nil rather than erroring. `span` is required and
meaningless on a new event; pass `EKSpanThisEvent`. Use `saveEvent:span:error:`, not the
`commit:NO` variant, or write-ahead ordering is fiction. Set `availability` explicitly — a silent
`.busy` default changes the user's free/busy for anyone querying it.

## 7. Trust boundary and privacy

Calendar-derived text — titles, notes, locations, organizer and attendee names, calendar and
source names — is `external_untrusted` and may never be interpreted as instructions,
configuration, paths or shell input. `openWorldHint: true` on invitation-derived tools. Typed
DTOs and schemas throughout; minimal field set by default.

Annotations are hints, not enforcement, and **host-side approval is not a control** — it is an
assumption about the user's configuration the server cannot observe.

**The controls live inside the agent's blast radius**, and the README carries this in
substance: *These controls reduce the blast radius of a mistaken or manipulated model. They do
not defend against an attacker with filesystem write access as your user — such an attacker
can truncate the journal and delete snapshots. Same-uid containment is not achievable without
a privilege boundary this project does not have.*

(The clause "edit the allowlist" was part of this paragraph until 2026-08-22 and is gone with
C1. Naming a file that no longer exists in a security disclosure teaches a reader to look for
the wrong thing.)

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

**Failures lead with a stable code**, as `CODE: what went wrong, and what a correct call
looks like`. The code is contractual; the prose after the colon is free to be reworded. It
travels in the text rather than in `structuredContent`, because a tool declaring an
`outputSchema` promises that its structured output conforms to it and an error payload does
not have the shape of a success — emitting one anyway hands a strict client a validation
failure on top of the error it was already reporting.

**Shipped codes** (the read surface can produce these): `PERMISSION_DENIED`,
`BAD_TIMESTAMP`, `BAD_TIME_ZONE`, `END_NOT_AFTER_START`, `INTERVAL_TOO_LARGE`,
`MISSING_ARGUMENT`, `UNKNOWN_TOOL`, `CALENDAR_STORE_UNAVAILABLE`, `CALENDAR_STORE_BUSY`,
`CALENDAR_TIMEOUT`, `CALENDAR_STORE_WEDGED`. Canceled requests propagate cancellation to the
SDK so it suppresses their replies.

**Planned, for the write surface, and not emitted by anything today:**
`CALENDAR_NOT_WRITABLE`, `EVENT_HAS_ATTENDEES`, `SPAN_REQUIRED`, `TOKEN_EXPIRED`,
`TOKEN_ALREADY_USED`, `TOKEN_INVALID`, `CONFIRM_SUMMARY_MISMATCH`,
`EVENT_CHANGED_SINCE_PROPOSE`, `EVENT_NOT_FOUND`, `DUPLICATE_SUPPRESSED` (§6). Advertising a
code no tool can emit is the
same class of claim as a phase marked complete before it was built, so the two lists are kept
apart. The allowlist refusal code that used to head this list is **deleted, not planned** —
C1 was withdrawn, and a stale code sends a user hunting for a config file that does not exist.
The literal is left out on purpose so a grep for it finds nothing anywhere in the repository.

Clean shutdown when stdin closes.

---

## 9. Client integration

Connection loading, runtime updates, and recovery follow [CLIENT-LIFECYCLE.md](CLIENT-LIFECYCLE.md).
The host owns stdio startup and reconnection; a server self-respawn loop cannot refresh the
host's registration/catalog. Keep the current EOF shutdown and one-time identity re-exec.

**Client neutrality is a project requirement.** Claude Cowork, Claude Code, Claude Desktop,
and ChatGPT/Codex Work are peer targets. The server's tool contracts and C3–C7 safeguards
remain the same for equivalent launch configuration. Each client must reach the local macOS
stdio process; local execution and client-specific connection support must be verified rather
than inferred from the product name. No particular client is a prerequisite for development.

Run `calendar_permission_status` through the current client first. Its capability flags
describe that connection, not universal support; a direct stdio harness describes only its
own supplied handshake. Current evidence: native Codex reads verified; Cowork read visibility
confirmed by the human; Claude Code user-scope registration reported successful, native call
not yet reported. None clears the approval gate. Approval acceptance and all refusal paths
must be demonstrated in each client before enabling writes there. A client that cannot enforce approval keeps reads
available and must refuse writes. Historical Cowork observations elsewhere are scoped evidence.

Absolute path always — the TCC grant is keyed to it. **Serving is what happens with NO
arguments**; there is no `serve` subcommand, and passing one exits `EX_USAGE` as an unknown
flag.

**Claude Code** — `claude mcp add --transport stdio --scope user apple-calendar -- /usr/local/bin/apple-calendar-mcp --read-only`
**Codex** — `[mcp_servers.apple-calendar]` in `~/.codex/config.toml`
**Claude Desktop** — `mcpServers` in `claude_desktop_config.json`, currently with `--read-only`

---

## 10. Tests

`./scripts/test.sh` (not `swift test` — Command Line Tools ships `Testing.framework` but no
XCTest, and the module and dyld paths need deriving). The wrapper explicitly selects the
native SwiftPM engine: the Swift 6.4 default swiftbuild engine on a Command Line Tools-only
install failed to load TestingMacros. Compiler caches default to `.build`, and framework
arguments preserve paths with spaces. CI runs the same script; see §16.

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

**Contract, continued** — the block above is the protocol layer; this is the payload layer.
Every tool declares an `outputSchema`; every payload validates
against the schema its own tool advertises, including fields the schema does NOT declare
(an undeclared field is validated by nobody, which is how `limits_applied` drifted); every
`required` field is present. Two positive controls prove the checker can fail.

**Lifecycle** — the real binary launched as a server, then shut down by stdin EOF, by SIGTERM,
and by SIGKILL-then-EOF, asserting in each case that the disclaimed child does not survive.

**Not covered, honestly:** the `dlsym`-failure branch cannot be exercised and is guarded by a
source-text assertion. The CLOEXEC exemption is still not directly observed. The 250 ms
concurrency criterion in §5 needs a populated real calendar and is unmeasured. Signal
forwarding **is** now covered (§5).

---

## 11. Risks

| Risk | Mitigation |
|---|---|
| Moving the binary to a different path loses the grant | Path-keyed by design; `--setup` runs at the final path; `--doctor` says so in plain English. A same-path replacement signed by the same identity retains the grant |
| Hardened runtime without the entitlement → silent permanent denial | Ship both always; `sign.sh` asserts both on the signed binary |
| Removing an invited event may notify real people or behave differently from Calendar.app's Decline | C6 requires per-call confirmation that discloses the uncertainty and C7's attendee-state exception. A second-account test is optional characterization, not a release gate |
| Prompt injection driving a mutation | The guarded commit path, refetched ground-truth checks, per-call confirmation, and C7 restorability with its named attendee-state exception. **Not** the allowlist (C1 withdrawn 2026-08-20), and **not yet** any human-approval mechanism — `toolPolicy` was never configured and elicitation is unmeasured (§6, BACKLOG #1). Reduces blast radius and improves reviewability; does **not** prevent a find → propose → commit chain |
| Controls sit inside the agent's blast radius | Stated verbatim in README and memory; startup-only config load |
| Same-uid impersonation of this binary's identity | Root-owned install path; never grant to `.build` |
| Server restart invalidates in-flight tokens | Expected; surfaced as `TOKEN_INVALID` |
| Permission model verified only on macOS 26.5 | Target is macOS 14; 14.0–26.4 unverified and `--doctor` must not claim otherwise |
| SDK pre-1.0 | Exact pin; `Package.resolved` committed |
| `unsafeFlags` blocks consumption as a dependency | **Decided 2026-08-22: accepted, clone-and-build only.** SwiftPM refuses to resolve a package using `unsafeFlags` as a dependency, and `-sectcreate` is the only way an SPM executable can carry the Info.plist TCC needs. A transitive dependency would be meaningless anyway: the grant is keyed to an absolute path and needs its own signing and `--setup`. Builds must run from the package root, since the `-sectcreate` path is relative to the invoker's cwd |

---

## 12. Definition of done (v1 = read surface)

| Criterion | State |
|---|---|
| Discovery works in Claude Code, Codex and Claude Desktop from one absolute-path config | **Met** — in daily use |
| Bounded queries, search and busy intervals return schema-conforming results against the real calendar | **Met**, and now asserted synthetically as well (§10) |
| stdout carries protocol only | **Met**, test-enforced |
| Orphan behaviour verified under SIGTERM and SIGKILL | **Met 2026-08-22** (§5) |
| The permission smoke matrix passes with the §10 expected outcomes | **Met** for the states exercised on this machine; 14.0–26.4 remain unverified |
| README carries the destructive-capability warning and the containment paragraph verbatim | **Met** |
| `./scripts/test.sh` green | **Met** |
| A 500-event fetch does not delay a concurrent `tools/list` by 250 ms | **Not measured** — needs a populated calendar (§5) |

The last line of the old wording — "`docs/IMPLEMENTATION-PLAN.md` matches this file" — is
retired: as of rev. 7 this **is** that file.

---

## 13. Open decisions

1. **Does a write tool prompt?** The one blocking unknown — §6, Gate 1. Everything in §6
   waits on it.
2. ~~C2/C2a/C4a under review~~ — C4a replaced by C7, and that stands (`gov-120ca260c415`).
   **C2/C2a's supersession does NOT stand as recorded**: it named `toolPolicy` as the
   replacement, and `toolPolicy` was never configured. The requirement they encoded — no
   mutation without a fresh, per-call confirmation — is unmet until BACKLOG #1 closes.
3. ~~Adopt C6 formally~~ — **RESOLVED 2026-08-25.** The human confirmed it, and in doing so
   amended it: attendee events are **confirmed, not refused** (§4a), with a named exception in
   C7 for unrestorable attendee state. The Phase 6 second-account test becomes optional
   characterisation rather than a release gate.
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

---

## 15. Phase 5 and 6 — what the next work actually is

**Read hardening is implemented:** conservative unsupported-availability handling, the
bounded read gate in §5, escaped diagnostics, and acknowledged journal storage with
cross-month history. These are prerequisites, not evidence that write approval or restore
works. Next is the harmless human-approval round trip after the elicitation cleanup design;
continue to enforce §6 Gate 1 before adding a mutating caller.

**Current work:** the `0.2.2` source candidate implements the opt-in harmless probe and
SDK lifecycle cleanup described in [the design](APPROVAL-PROBE-DESIGN.md). Complete final
review/verification, install the signed candidate at the existing path, then measure actual
human interaction. Fake-client tests do not clear the approval gate.

**Then, and only after §6 Gate 1 is answered:** `calendar_create_event` →
`calendar_delete_event` **with restore in the same change** → `calendar_update_event`.

---

## 16. CI

`.github/workflows/ci.yml`, on a macOS runner: build, `./scripts/test.sh`, `bash -n` over
every script, and `./scripts/test-shell.sh`. Deliberately **no signing, no keychain, no TCC
and no Calendar access** — none of them can work on a hosted runner, and a workflow that
appears to check them would be worse than one that does not. The matrix stops at "builds,
unit tests pass, scripts parse". Every defect found in this project so far was caught by a
human or an agent reading code; this is the first automation.
