<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Project Memory

**Memory Type:** Semantic (accumulates)
**Lifecycle:** Grows with project per §7.0.4
**Project:** apple-calendar-mcp
**Created:** 2026-08-17

> Record decisions and their rationale here. When in doubt, write it down.
> **What goes elsewhere:** what you are doing right now → `SESSION-STATE.md` · lessons from experience → `LEARNING-LOG.md` · work not started yet → `BACKLOG.md` · commitments that recur → `OPERATIONS.md`. Decisions accumulate here and are superseded, never deleted.

---

## Phase Gates

| Gate | Status | Date | Notes |
|------|--------|------|-------|
| Specify | Complete | 2026-08-17 | Founding context + containment controls |
| Plan | Complete | 2026-08-18 | rev. 3 approved; 3 independent reviews folded in |
| Implement | In progress | 2026-08-19 | Phases 1-3 complete and published; Phase 4 next |
| Validate | In progress | 2026-08-19 | 63 tests green; security audit closed |

## Founding Context

**Goal.** A local MCP server that lets Claude Code and Codex work with the current macOS
user's Apple Calendar — inspect calendars, retrieve bounded event sets, reason about
availability, and create, modify, and delete events under the containment controls
recorded in Key Decisions (C1-C5).

**Done looks like.** See the Definition of Done in the implementation plan
(`~/.claude/plans/proceed-with-writing-the-linear-iverson.md` §17) — it is the single
source of truth and covers the write path, the guards, and the permission matrix.

The earlier wording here was read-only-era text that directed testing **at the real
calendar**. That is now hazardous: the same executable can delete events. Integration
testing runs against a disposable calendar only, never real personal data.

**Non-goals (first release).** No network listener or remote transport. No telemetry or
analytics. No CalDAV connection. No Apple ID / iCloud credentials. No automatic update
mechanism. No reminders (`EKReminder`) — events only. No long-lived caching of EventKit
objects. No bulk mutation (see C5 carve-out). No prebuilt binary distribution
(source-only publication). No mutation of events with attendees or an external organizer (C6).

**Audience.** Built for the author's own use on a single machine, but **likely to be
published as open source on a public GitHub repository** (stated 2026-08-17). Not a SaaS,
not multi-tenant, no customer data, no money — hence `standard` tier, not `saas-ops`.

Publishing source is distinct from distributing binaries. Consumers clone and build
locally and sign with their own **stable self-signed certificate** (created once in the
login keychain), plus the hardened runtime and the calendars entitlement. No Apple
Developer ID and no notarization are required for that path — those become required only
if prebuilt release artifacts are ever shipped, which is a later, separately approved
phase. Note the earlier claim that hardened runtime was unnecessary was **wrong**; see
the signing decision below.

The public-release intent raises the security bar even though the deployment is personal:
defects protect (or fail to protect) strangers' calendars, not only the author's. Weigh
the write-capability decision below on that basis.

## Spec Summary

Native Swift stdio MCP server over EventKit, three internal layers — **`MCPLayer` →
`CalendarKit` → `EventKitAdapter`** as conceptual layers. On disk they are
`Sources/apple-calendar-mcp/{MCP,Calendar,EventKit,Diagnostics}` — the directory names do NOT
mirror the layer names, and the on-disk scheme wins. EventKit framework objects never leave the adapter boundary and are
converted to immutable DTOs before crossing it. `EKEventStore` is confined to one
dedicated thread behind an actor.

## Key Decisions

| Decision | Date | Rationale |
|----------|------|-----------|
| Native Swift + EventKit, not AppleScript / sqlite / CalDAV | 2026-08-16 | AppleScript automation is unreliable under TCC; direct `Calendar.sqlitedb` access is SIP-blocked and unsupported; CalDAV requires credentials we refuse to hold. EventKit is the only supported path. |
| Pure Swift executable, no Node→Swift bridge | 2026-08-16 | Bridge adds a runtime dependency and a second process identity, which complicates the TCC permission grant. Revisit only if a concrete MCP compatibility gap is proven. |
| Signing: **stable self-signed certificate + hardened runtime + entitlement**, no notarization | 2026-08-18 | **SUPERSEDES the ad-hoc signing decision of 2026-08-17.** Ad-hoc signatures have no stable identity and TCC pins to the **cdhash**, so *every* `swift build` would silently invalidate the Calendar grant — hundreds of times during development, and on every consumer's `git pull && swift build`. Hardened runtime **is** required (the earlier "not required" note was wrong): without it plus the entitlement, macOS 26.5 `tccd` refuses to prompt at all, permanently and silently. Developer ID + notarization remain necessary only for prebuilt release artifacts — a later, separately approved phase. |
| Events only, reminders out of scope | 2026-08-16 | Inferred from the founding brief and confirmed; keeps the entitlement and tool surface minimal. |
| Read-only v1 → **superseded**, read + write approved | 2026-08-17 | User reversed the original read-only position, then approved write under the five containment controls (C1-C5 below). Supersedes, does not delete, the prior decision. |
| C1 — Writable-calendar allowlist | 2026-08-18 | **AMENDED (gov-f551d84f9142).** Writes land only on calendars named in config. The earlier claim that "Work, shared, and subscribed calendars are read-only by construction" was **false and implemented nowhere** — header-verified, only calendars with `allowsContentModifications == false` are excluded at source, so a *shared iCloud calendar with write access IS writable if allowlisted*. Substrate, previously undefined: config at `~/.config/apple-calendar-mcp/config.toml`, loaded **once at startup**, entries keyed on `{calendar_identifier, expected_title, expected_source}` requiring **all three** to match, failing closed on any mismatch, **never** falling back to title matching (a new account could otherwise silently make a calendar writable). |
| C2 — Only the *committing* call is destructive; it takes a token plus a verified summary | 2026-08-18 | **AMENDED (gov-f551d84f9142).** Signature is now `(token, confirm_summary)`, not "ID + token ONLY". `confirm_summary` is a **server-minted canonical string** the caller must echo **byte-exactly**; verification is `==` against the server's own value. It is calendar-derived text entering the destructive call — which the original absolute guarantee forbade — but it is never a *selector*; the token is. Reason for the change: the original design put every human-readable field on the `propose` call, which is flagged `readOnlyHint` and therefore auto-approved and collapsed by hosts, leaving the call the human is actually prompted on showing only a UUID and an opaque token. That was an approval-surface inversion. Still a mitigation, not a block: it does not prevent a find → propose → commit chain. |
| C2a — Always confirm, even on a single match | 2026-08-17 | No auto-delete when the search returns exactly one candidate. A single match is precisely where skipping confirmation is most tempting and where injection would aim. |
| C3 — Two-phase propose/commit + per-event pre-state snapshot | 2026-08-18 | **AMENDED (gov-f551d84f9142).** `propose` returns a preview and a token; `commit` requires it. The `.ics` export clause is **withdrawn** — EventKit exposes **no ICS export API** (header-verified), so it was never implementable, and hand-rolling RFC 5545 would have written the entire calendar including notes and attendee email addresses to plaintext readable by the very agent being contained. Replaced by a **complete per-event JSON pre-state snapshot** in the journal, which carries the reversal data without the privacy regression. |
| C4 — Append-only mutation journal sufficient to reverse | 2026-08-17 | Every mutation records a complete pre-state field snapshot, the operation, and a timestamp — enough to reconstruct what the AI changed. |
| C4a — Undo restores an *equivalent* event, and is a fully governed write | 2026-08-18 | Restore reconstructs title, times, location, notes, and recurrence from the journal snapshot. It does NOT restore the original identifier or invitation state (`attendees` is `readonly` in EventKit — header-verified — so attendees can never be reproduced). **Undo is model-callable** and goes through the same propose/commit gate as every other mutation. It is journaled, **records the old→new identifier mapping**, and is bounded by guards: refused for `EKSpanFutureEvents` deletions (recreating a series tail yields two competing masters), idempotent by journal-entry id, duplicate-checked before recreating, post-state-hashed for undo-of-create, and limited to a 72-hour horizon. |
| C5 — No bulk mutation in v1 | 2026-08-18 | **CARVE-OUT (gov-f551d84f9142).** "One event per call" means **one event *identifier* per call**, which may span many occurrences of that one series: `EKSpanFutureEvents` removes this occurrence and every one after it in a single operation. That is intended (it mirrors Apple's own "Delete All Future Events") and is not the bulk mutation C5 excludes. What stays excluded: operating on multiple distinct events in one call. Still deferred until C3/C4 are demonstrated working, including a real restore. |
| **C6 — Attendee / external-organizer refusal** | 2026-08-18 | **NEW (gov-f551d84f9142), pending human confirmation.** Refuse all mutation where `event.hasAttendees` or `organizer != nil && !organizer.isCurrentUser`. Deleting an event you were invited to is believed to send a **decline to the organizer and every attendee**; deleting one you organized sends a **cancellation**. These are irreversible outbound acts with a human audience that no journal or snapshot can reverse. This is the only control that consults **ground truth (the event itself)** rather than model-supplied arguments, so a compromised model cannot argue past it. The refusal is *actionable*, returning title, start, end, calendar, organizer and attendee count so the human can find and decline it by hand. **The decline/cancellation behavior is inference, not header-verified** — confirm in Phase 6 with a second account. |
| License: **Apache-2.0 — CONFIRMED** | 2026-08-17 | Human decision. Explicit limitation-of-liability (§8) and express patent grant, chosen over MIT because this software can destroy user calendar data and will be publicly distributed. |
| Recurrence mirrors Apple's own two-span dialog | 2026-08-18 | `EKSpan` has exactly two values and they are the two choices Calendar.app already asks: "Delete This Event" (`EKSpanThisEvent`, adds an exclusion for that occurrence) and "Delete All Future Events" (`EKSpanFutureEvents`, removes this and everything after, **preserving past occurrences as history**). There is no "all events" span and none is needed. `span` is required on any recurring target and is named in words in the verified summary. |
| Update stays in v1, recurrence included | 2026-08-18 | Adversarial review recommended deferring update to v1.1 because recurrence span handling is where the pain concentrates. Overruled by the human: mirroring Apple's dialog makes the span choice explicit and legible rather than a hidden trap, so the hard case becomes tractable. |
| Undo stays model-callable rather than CLI-only | 2026-08-18 | Adversarial review recommended demoting undo to a CLI command outside the model's reach. Overruled by the human: it must work in Cowork, where there is no terminal, and model-driven undo is already in use for QuickBooks and Excel. Kept behind guards (see C4a) rather than removed. **Premise still unverified — see Open Questions.** |
| Occurrence addressing uses `occurrenceDate`, not start date | 2026-08-18 | Header-verified: `occurrenceDate` "will remain the same even if the event has been detached and its start date has changed". Using start would break exactly the detached-occurrence case. Composite key is `(eventIdentifier, occurrenceDate)`. `eventIdentifier` is chosen because it is the only identifier with a store lookup API — **not** because it is stable; it too can change on calendar move and on sync. |
| Every mutation, including create, is proposed then committed | 2026-08-18 | An earlier draft left `create` outside the guarded path while claiming there was only one destructive call. Creating an event with attendees sends invitations — the same irreversible outbound act C6 exists to prevent. One guarded `commit()` implementation, reached through four thin separately-allowlistable tool names so a single "always allow" cannot authorize every destructive operation at once. |
| **Self-disclaiming re-exec is required architecture** | 2026-08-19 | Human decision after Phase 1 measured that a plain executable never earns its own TCC identity, and that an `.app` wrapper does not fix it either (gotcha 19). Alternatives considered: accept inherited permission from the host app (simplest, but grants calendar access to the whole terminal, needs a separate grant per client, and depends on the host having a calendar usage string); ship read-only (does not help — attribution applies to reads too). Chosen because it is the only option where "grant access to apple-calendar-mcp" means what it says, which matters most for the public-release audience whose hosts we cannot predict. Cost: one private API behind `dlsym`, a thin supervisor process, and stdio passed through untouched. |
| Implementation sourced from Apple's own guidance; reference repos used for comparison only | 2026-08-17 | Build against Apple documentation as the primary source. Consult `che-ical-mcp` / `orchard-mcp` only to find concerns Apple's guidance does not cover, and to compare approaches. Adopting an *idea* is unrestricted; copying *expression* creates an obligation. Any actual borrowing must be flagged to the human at the time, with attribution and license implications, before it lands. |

## Tech Stack

Swift 6.x via Apple Command Line Tools · EventKit · MCP Swift SDK (exact version pin, no
floating branch) · Swift Package Manager. Node.js used only for MCP Inspector testing, not
required at runtime.

## Constraints

**macOS grants no read-only calendar permission.** `requestFullAccessToEvents` is the only
authorization that permits fetching events, and it confers read *and* write. Therefore any
read-only property is a property of our implementation, never of the OS. Corollary: the
original read-only stance bought zero privacy reduction — the full permission was always
going to be requested. It only ever bought blast-radius reduction.

**Write capability: APPROVED under the containment model below** (human decision
2026-08-17, clearing governance escalation `gov-cec3bcaf6e71`, which triggered
`meta-safety-non-maleficence-privacy-security`). Controls C1, C2, C3 were later amended
and C6 added under `gov-f551d84f9142` (2026-08-18). The residual risk is accepted
knowingly: untrusted calendar text, sensitive personal data, and mutation capability
coexist in one loop, and the containment below reduces blast radius and improves
reviewability without eliminating the injection path. Any further change that weakens a
containment control requires another fresh governance evaluation.

**Same-uid containment is not achievable — record this verbatim in the README (§10 of the
plan requires it):**

> These controls reduce the blast radius of a mistaken or manipulated model. They do not
> defend against an attacker with filesystem write access as your user — such an attacker
> can edit the allowlist, truncate the journal, and delete snapshots. Same-uid containment
> is not achievable without a privilege boundary this project does not have.

This residual risk was **not** among those named in the original `gov-cec3bcaf6e71`
approval and is larger than the ones that were. C1's config, C3's snapshots and C4's
journal are all files owned by the user's own uid, inside the blast radius of a coding
agent that has filesystem write access and can reach them without going through this
server at all. They defend against a *mistaken or manipulated* model, not a *compromised*
one. Recorded rather than left implicit, per `meta-safety-transparent-limitations`.

**Same-uid write means impersonation, not merely bypass.** Recorded 2026-08-19 after a
security audit; this is a residual risk larger than the one previously named, and it was
not among those accepted in `gov-cec3bcaf6e71` or `gov-f551d84f9142`. The setup chain
assembles a silent code-signing oracle: `make-signing-cert.sh` installs a **trusted root
for code signing**, `trust-signing-cert.sh` puts `codesign` on the key's partition list so
signing needs **no password and no dialog**, the TCC designated requirement is
**identity-based** (gotcha 26), and the grant is keyed to an **absolute path** (gotcha 25).
Both halves of the requirement are attacker-supplied. Any same-uid process can compile,
sign silently, write to the granted path, and hold Calendar access attributed to this
tool — no prompt, no journal, nothing unusual in System Settings. The property that makes
the design work (rebuilds keep the grant) is exactly what makes the grant stealable.
Mitigation is deployment, not code: **install at a root-owned path and never grant to a
binary inside `.build`.**

**Host-side approval is not a control.** It is an assumption about the user's
configuration that the server cannot observe. If a commit tool is allowlisted in
`/permissions`, or the session runs with approvals bypassed, there is no prompt at all.
Two hardening claims made on 2026-08-17 were false and are withdrawn: "a bypass needs a
restart, which needs you" (clients respawn stdio servers on session start, reconnect,
crash and config reload, with no human action) and "logged to stderr so tampering is
visible in the transcript" (MCP server stderr goes to a log file, not the transcript).

**Calendar content is untrusted external data.** Titles, notes, locations, URLs, organizer
and attendee names, and calendar/source names are all attacker-influenceable via inbound
invitations and synced calendars. Per `meta-core-separation-of-instructions-and-data` and
`coding-quality-workflow-integrity`, none of it may ever be interpreted as instructions,
configuration, file paths, or shell input.

**EventKit identifiers are not permanent.** They can change on calendar moves and full
syncs, and fetched objects go stale after `EKEventStoreChangedNotification`. No long-lived
caching in v1.

## Known Gotchas

| # | Gotcha | Date |
|---|--------|------|
| 1 | `EKAuthorizationStatus` has **FIVE** distinct values — `NotDetermined=0, Restricted, Denied, FullAccess, WriteOnly`. `Authorized` is a **deprecated alias** `= FullAccess`, runtime-indistinguishable, so "six states" is wrong and any gate requiring six can never pass. `writeOnly` permits writes but not reads and must not be collapsed into `denied`. (`EKTypes.h:27-35`) | 2026-08-18 |
| 2 | EventKit does not guarantee ordering of fetched events; results must be sorted explicitly with a deterministic tie-breaker. | 2026-08-16 |
| 3 | All-day events shift their calendar date if naively converted through UTC. | 2026-08-16 |
| 4 | The executable identity used at setup must match the one Claude Code and Codex launch, or the TCC grant will not apply. | 2026-08-16 |
| 5 | stdout is reserved exclusively for MCP protocol messages; all diagnostics go to stderr, control-character-escaped. | 2026-08-16 |
| 6 | Restore from journal/backup is *recreate an equivalent event*, not true undo. The original event identifier does not survive, and invitation state — organizer, attendee list, RSVP responses — is not recoverable. A recreated invite is a new invite. Detached occurrences of a recurring series are messier still. The README must say this plainly. | 2026-08-17 |
| 7 | **Resolved 2026-08-17.** Both reference repos are MIT: `che-ical-mcp` © 2025 Che Cheng; `orchard-mcp` © 2025 l22.io GmbH (verified at the pinned research commits). MIT is one-way compatible into Apache-2.0, so borrowing is permitted. The MIT notice and copyright line MUST travel with any borrowed portion — the project as a whole is Apache-2.0 while borrowed portions remain MIT-attributed. No copyleft exposure. | 2026-08-17 |
| 8 | Copyright covers *expression*, not ideas. Adopting an approach (an actor around the store, a result cap, an authorization-state taxonomy) carries no obligation. Reproducing specific code, comment text, string literals, error wording, test fixtures, or doc prose does — including close paraphrase written straight after reading. Read Apple first, write from Apple, consult the repos only for gaps. | 2026-08-17 |
| 9 | `orchard-mcp` is Node/TypeScript with a `swift/` helper directory — the very architecture this project rejected. Little of its code is transplantable; its value is policy patterns (caps, timeouts, stdio discipline), which are ideas. `che-ical-mcp` is pure Swift and is therefore where borrowing pressure and license discipline actually apply. | 2026-08-17 |
| 10 | **`isImmutable` does NOT govern whether you can add events.** Header: "If this is set to YES, it means you cannot modify any attributes of the calendar or delete it. It does NOT imply that you cannot add events or reminders to the calendar." A writability guard of `allowsContentModifications && !isImmutable` is **wrong** and would reject calendars the user allowlisted and EventKit accepts. Correct test is `allowsContentModifications && inAllowlist`. (`EKCalendar.h:94-100`) | 2026-08-18 |
| 11 | `EKSpan` is declared in **`EKEventStore.h`**, not `EKTypes.h`. Two values only: `EKSpanThisEvent`, `EKSpanFutureEvents` — there is no "all events" span. | 2026-08-18 |
| 12 | `EKSpanThisEvent` on a delete produces an **exclusion**, not a "detached" event. `isDetached` means an occurrence whose *attributes* were changed and which still exists. Do not use "detach" for deletion. (`EKEvent.h:131-138`) | 2026-08-18 |
| 13 | `attendees` is **`readonly`** — `create` can never set attendees and a restore can never reproduce them. (`EKCalendarItem.h:97`) | 2026-08-18 |
| 14 | `eventWithIdentifier:` returns the **first occurrence** of a series; the identifier is shared by all occurrences. There is no composite lookup — resolve `(eventIdentifier, occurrenceDate)` via a date-window predicate and filter. (`EKEventStore.h:279`) | 2026-08-18 |
| 15 | `predicateForEventsWithStartDate:endDate:` matches **overlapping** events (not contained) and is capped at **four years**, so open-ended recurring series cannot be counted by query at all — report approximate counts from the rule. (`EKEventStore.h:297,323-325`) | 2026-08-18 |
| 16 | TCC pins to the **cdhash**, and macOS commonly attributes a grant to the **responsible process** — for a bare executable spawned from a shell, often the launching app. If the grant lands on Terminal rather than our binary, `--setup` succeeds and every client-spawned call fails. Unverified; it is the Phase 1 gate and decides bare-executable vs `.app` bundle. | 2026-08-18 |
| 17 | Clients respawn stdio MCP servers without warning (session start, reconnect, crash, config reload). In-memory propose/commit tokens do not survive a restart. | 2026-08-18 |
| 18 | Calendar and source **names** are attacker-influenceable too, not just event fields — escape them before they reach a log line. | 2026-08-18 |
| 19 | **TCC attributes a grant to the spawning process, not to the executable — and an `.app` wrapper does NOT fix it.** Measured 2026-08-18: granting from a terminal created a TCC row for **that terminal app's** bundle identifier and **zero** rows for `com.collierhmg.apple-calendar-mcp`. Re-testing with a signed `.app` bundle whose inner binary was exec'd directly produced the same result. Responsibility is assigned at `posix_spawn` time by the parent; bundling only earns an independent identity when **LaunchServices** performs the launch, which an MCP client never does because it needs stdio pipes. A correctly signed binary with the entitlement, hardened runtime and an embedded Info.plist is **necessary but not sufficient**. | 2026-08-18 |
| 20 | Consequence of 19: a child process **inherits** the host's Calendar grant, so `authorizationStatus` reporting `fullAccess` proves nothing about our own identity. The only reliable check is whether a row for our bundle identifier exists in `~/Library/Application Support/com.apple.TCC/TCC.db` (readable without Full Disk Access). Any `--doctor` check based on status alone is worthless. | 2026-08-18 |
| 21 | Signing a self-signed identity from an automated agent hangs forever on a GUI keychain dialog the agent cannot answer. `security set-key-partition-list -S apple-tool:,apple:,codesign:` (or clicking **Always Allow**, not Allow) is required once, interactively, before any unattended signing works. | 2026-08-18 |
| 22 | Homebrew/conda OpenSSL 3 produces PKCS12 bundles the macOS Security framework rejects as "MAC verification failed (wrong password?)" — the cipher is the problem, not the password. Use `/usr/bin/openssl` (LibreSSL) and a non-empty password; an empty one fails the same misleading way. | 2026-08-18 |
| 23 | XML comments may not contain a double hyphen. AMFI's entitlement parser rejects the entire file with only a line number, which reads as a plist syntax error. `plutil -lint` passes on files AMFI rejects. | 2026-08-18 |
| 24 | **The fix for 19 is a self-disclaiming re-exec, and it is verified working.** The process posix_spawns itself once with the private `responsibility_spawnattrs_setdisclaim` attribute; the disclaimed child is its own responsible process. Measured: before disclaim the probe reported `fullAccess` (the host terminal's grant, inherited); after disclaim it reported `notDetermined`, and granting then created a TCC row for **our** binary. Symbol resolved via `dlsym`, never linked, so a future macOS removing it degrades to inherited mode instead of failing to launch. `--doctor` must report which mode is active. | 2026-08-19 |
| 25 | **TCC keyed our grant to the ABSOLUTE PATH (`client_type=1`), not the bundle identifier.** Measured: the same signed binary copied to another path reports `notDetermined`. Consequences: `--setup` must be run at the **final installed path**, never from `.build`; the client config must name that exact path; and moving or reinstalling the binary requires a fresh grant. An earlier plan claim that "TCC pins the cdhash, not the path" was **backwards** and is corrected. | 2026-08-19 |
| 26 | **A changed cdhash at the same path does NOT lose the grant** — measured across a real rebuild (`6b0b4577` → `b772b4fb`), still `fullAccess`. The reason is the designated requirement: `identifier "com.collierhmg.apple-calendar-mcp" and certificate root = H"<this machine's cert>"`. It is identity-based, so any build signed by the same cert satisfies it. This is what makes the stable self-signed certificate load-bearing: **ad-hoc signing would produce a cdhash-based requirement that breaks on every build.** Right decision, wrong reason originally recorded. | 2026-08-19 |
| 27 | The user TCC database at `~/Library/Application Support/com.apple.TCC/TCC.db` is readable with plain sqlite3 — no Full Disk Access needed — and is the **only** trustworthy way to tell whether a grant belongs to us or is inherited. `EKEventStore.authorizationStatus` cannot distinguish them. | 2026-08-19 |
| 28 | **Gotcha 27 was wrong for our own process.** `TCC.db` is readable from a *terminal* because the terminal app has Full Disk Access, not because the file is generally readable. Our disclaimed binary holds only a Calendar grant, so it **cannot** read `TCC.db`. Any diagnostic depending on it degrades to "skipped". Same error class as gotchas 19-26: measured from a privileged context and assumed to generalise. | 2026-08-19 |
| 29 | **The permission-free ownership test:** a disclaimed process is its own responsible process, so the authorization status it observes is its OWN grant and nothing inherited. Therefore `disclaimMode == "disclaimed-child" && status == .fullAccess` is proof of ownership, requiring no special privilege. This is what `--doctor` and `--setup` use; the `TCC.db` read is corroboration only. Proven in Phase 1: pre-grant the disclaimed child read `notDetermined` while the inherited path read `fullAccess`. | 2026-08-19 |
| 30 | **An environment variable can never prove disclaim state.** A first attempt bound the marker to the supervisor's pid and claimed it was unforgeable; every parent knows its own pid, so `VAR=$$` defeated it in one line — and both Claude Code and Codex accept an `env` block in MCP server config, files a same-uid agent can write. Ground truth is `responsibility_get_pid_responsible_for_pid(getpid()) == getpid()`, asked of the kernel via `dlsym`. **The first fix left a fallback to the forgeable check when the symbol was unavailable** — reinstating the vulnerability on the one path no test can reach on a working machine, and the claim recorded here was false as written. The fallback is now deleted: unanswerable means `false`, which degrades to an honest `inherited-respawn-failed`. | 2026-08-19 |
| 31 | `security set-key-partition-list -s` is a boolean match filter taking **no argument**; the keychain is the trailing positional. Without `-l <label>` it matches **every** sign-capable key in the keychain and **replaces** each partition list rather than appending — silently breaking other applications' access to their own signing keys. Always scope with `-l`. | 2026-08-19 |
| 32 | **A path-keyed TCC grant cannot be reset with `tccutil`.** Measured 2026-08-19: `tccutil reset Calendar <bundle-id>` and `tccutil reset Calendar <absolute-path>` both fail with `No such bundle identifier` (OSStatus -10814) — tccutil accepts bundle identifiers only, and our row is `client_type=1` (path). The only options are System Settings > Privacy & Security > Calendars, or bare `tccutil reset Calendar`, which wipes **every** app's calendar access. Earlier guidance in `--doctor`, `AuthorizationState.guidance` and `SetupFlow` told users to run a command that cannot work; corrected. | 2026-08-19 |
| 33 | **`cp` preserves an embedded code signature**, so a binary signed before copying is still validly signed afterwards — verified: the installed copy satisfies its designated requirement with the correct authority, hardened runtime and entitlement. Sign **before** installing to a root-owned path; signing after fails with `internal error in Code Signing subsystem`, which names neither permissions nor the fix. | 2026-08-19 |
| 34 | **`grep -q` under `set -o pipefail` inverts a passing check into a failure.** `grep -q` closes the pipe on first match, the upstream command gets SIGPIPE (exit 141), and `pipefail` propagates that as the pipeline's status — so `if ! cmd \| grep -q ...` fires on a *successful* match. **The obvious remedy is also wrong**: `printf '%s' "$VAR" | grep -q` is still a pipeline and still inverts — measured at 200k lines. It only moves the threshold to the pipe buffer. The genuinely safe forms are `case "$VAR" in *pat*)` (no I/O, cannot be raced) or `grep -q pat <<<"$VAR"`. This bug was recorded as learned, "fixed" with the broken remedy, and left live in `make-signing-cert.sh` where it reported a **present** signing identity as absent — which would mint a second certificate and silently break Calendar access, since the TCC designated requirement names the first certificate's root. | 2026-08-19 |
| 35 | **A security fallback on an unreachable path cannot be tested and must not be trusted.** The forgery fix worked when tested because the kernel symbol was present; the fallback was dead code on this machine and reintroduced the exact bypass. Prefer failing closed over degrading to a weaker check — a mechanism you cannot exercise is a mechanism you cannot verify. | 2026-08-19 |
| 36 | `posix_spawn_file_actions_addinherit_np` (public, `spawn.h`, macOS 10.7+) is the explicit API for exempting a descriptor from `POSIX_SPAWN_CLOEXEC_DEFAULT`; `adddup2(fd, fd)` works but states its intent less clearly. Both fail with **EBADF on a closed descriptor**, which fails the entire spawn — so guard with `fcntl(fd, F_GETFD) != -1`, or anything launched without stdio (launchd, cron, `0<&-`) silently loses the disclaim. | 2026-08-19 |
| 37 | `FileManager.homeDirectoryForCurrentUser` reads the **passwd database**, not `$HOME` — verified: `HOME=/tmp/fake` did not redirect state files. `NSString.expandingTildeInPath` is the one that honours `$HOME`. | 2026-08-19 |
| 38 | **`String.prefix(n)` counts grapheme clusters, not bytes.** One base letter plus 500 combining marks is a *single* `Character` that expands to ~1 kB of UTF-8, so a "64-character" cap produced a filename the filesystem rejected outright. Cap on `utf8.count` when the string becomes a path component. | 2026-08-19 |
| 39 | **XCTest is unavailable with Command Line Tools only** (`Testing.framework` ships, `XCTest.swiftmodule` does not), and `swift test` fails three times over on module and dyld paths. `scripts/test.sh` derives them from `xcode-select -p`. Use swift-testing. | 2026-08-19 |
| 40 | **A test target CAN depend on an executable target** that uses `unsafeFlags` — verified by building and running. `unsafeFlags` only bars the package from being resolved as someone *else's* dependency; it places no restriction on a sibling target. No library extraction needed. | 2026-08-19 |
| 41 | Top-level-code globals in `main.swift` are `@MainActor`-isolated and **SEGV the test host** when read from a test, killing the whole run. **Fixed 2026-08-19** by moving them into `Runtime`. Doctor and SetupFlow are now covered, including SetupFlow's refusal-under-inherited-identity — the guard that stops permission attaching to the launching app. | 2026-08-19 |
| 42 | **`createDirectory` succeeds on an existing directory without touching its attributes**, so passing `posixPermissions` only protects a *fresh* install. Every machine that ran an older build kept 0755 — found by the first test written against the state directory, which Phase 5 fills with event titles, notes and attendee names. Permissions must be enforced explicitly on the existing-directory path. | 2026-08-19 |
| 43 | **A question must not have side effects.** `disclaimMode` originally performed the respawn lazily on first read, so merely *asking* about the identity from a test would `posix_spawn` a copy of the test host with the test host's argv. The respawn is now an explicit startup step (`Runtime.establishPrivacyIdentity()`); the mode is a pure kernel query. | 2026-08-19 |
| 44 | **Claude Desktop already disclaims the MCP servers it spawns.** Verified 2026-08-20: `/Applications/Claude.app/Contents/Helpers/disclaimer` — signed `Developer ID Application: Anthropic PBC` — imports `_responsibility_spawnattrs_setdisclaim`, the same private API this project uses. A server spawned by Desktop is therefore ALREADY its own responsible process, arrives with `fullAccess` under its own identity, and our re-exec correctly does **not** fire (`parent_path` is the helper, not our own binary). Independent convergence on the same solution is strong validation of the architecture. | 2026-08-20 |
| 45 | Consequence of 44: the kernel-based disclaim check earns its keep beyond security. The withdrawn env-marker version would have re-spawned redundantly on Desktop, since the marker would be absent while the process was already disclaimed. Asking the kernel makes the re-exec a no-op exactly where the host has already done the work, and active where it has not (terminals, Claude Code, Codex). | 2026-08-20 |
| 46 | **Swift encodes `Date` as a NUMBER by default** — seconds since the 2001 reference date — so any DTO field typed `Date` silently violates an outputSchema promising a string. The MCP SDK validates `structuredContent` **in memory, before serialization**, using an encoder we do not configure, so there is no `dateEncodingStrategy` to reach for. DTOs must carry pre-formatted RFC 3339 strings. Shipped broken in Phase 4 and found by the user on first real use. | 2026-08-20 |
| 47 | Swift's synthesized `Codable` omits every nil optional, which erases the difference between "null by nature" and "you did not request this". `occurrence_date: null` means the event does not recur; a missing `notes` means notes were not requested — not that there are none. Hand-write `encode(to:)`: `encode` for nullable-by-nature fields, `encodeIfPresent` for opt-in ones. | 2026-08-20 |
| 48 | **All-day events need BOTH representations.** The instant is machine-comparable but renders as the wrong *day* for a reader in another zone (the midnight-crossing bug); the `YYYY-MM-DD` string is correct to display but cannot be ordered against timed events. Emit `start`/`end` as instants always, plus `all_day_start_date`/`all_day_end_date`, and let `is_all_day` select. | 2026-08-20 |
| 49 | **`TimeZone.current` is a snapshot; `TimeZone.autoupdatingCurrent` tracks the OS.** This server is long-running — a client holds it open for a whole session — so `.current` would keep rendering the departure city's offset after a flight, with nothing to signal it. Use `autoupdatingCurrent` everywhere, and travel and DST are handled with no restart. | 2026-08-20 |
| 50 | **`ISO8601DateFormatter` defaults to GMT**, so timestamps rendered as `20:53:20Z` for a 2:53pm Denver meeting — the right instant, unreadable, and an invitation for a reader to convert it by hand and get it wrong. Set `formatter.timeZone` explicitly. | 2026-08-20 |
| 51 | `EKEvent.timeZone` is the event's OWN zone and is often **nil**, which is meaningful rather than missing: nil = the event floats with the machine's zone (9am stays 9am wherever you are); non-nil = pinned to that zone (a call created in `America/New_York` stays at that New York instant). That distinction is what a traveller needs, so never substitute the system zone for nil. | 2026-08-20 |
| 52 | **EventKit stores an all-day event's `end` INCLUSIVELY** — 23:59:59 on the final day, not midnight on the next. Query windows here are half-open `[start, end)`, so two conventions meet in one payload. Reported as EventKit stores it rather than normalised, because rewriting it would misstate the user's actual calendar; documented in the DTO, the schema and the tool description instead. A consumer assuming exclusivity is a day short on multi-day all-day events. | 2026-08-20 |
| 53 | **`saveEvent` returning NO does not mean failure.** The header is explicit: NO with a **nil** error means the event "wasn't dirty and didn't need saving" — a success. "The correct way to detect failure is a result of NO **and** a non-nil error parameter." So `if !saved { throw }` reports a false failure on every unchanged save, and checking only `error != nil` misses real ones. Three outcomes, not two: saved / noChangeNeeded / failed. | 2026-08-20 |
| 54 | **`seekToEnd` + `write` is not an atomic append.** Two concurrent writers interleave and corrupt each other's lines, losing both records. Found by parallel test execution before it shipped — which reproduced exactly the race concurrent tool handlers would cause. Open with `O_APPEND` so the kernel positions each write, serialise within the process, and resume short writes rather than treating them as complete. | 2026-08-20 |

| # | Gotcha | Date |
|---|--------|------|
| | | |

## Open Questions

| # | Question | Why it matters | Gate |
|---|----------|----------------|------|
| ~~1~~ | ~~Does Cowork run locally or remotely?~~ **ANSWERED 2026-08-19: locally.** Cowork runs inside Claude Desktop on this Mac, so the server reaches EventKit; mobile is only the remote control. Confirms the human has no terminal when driving from a phone, which is why undo capability must be model-reachable. | closed |
| ~~2~~ | ~~Bundle identifier~~ **SETTLED: `com.collierhmg.apple-calendar-mcp`**, now baked into the TCC designated requirement, so changing it means re-granting. | closed |
| 3 | Default allowlist empty ⇒ all writes fail closed on a fresh install | Confirm, or name a default writable calendar | Before Phase 5 |
| 4 | Adopt C6 (attendee refusal) formally | Currently recorded as pending human confirmation | Before Phase 6 |
| 5 | Does `calshow:` open Calendar.app at a date? | Would let the C6 refusal hand the user a clickable jump | Optional |

## Verification Sources

The **local EventKit SDK headers** are the source of record for EventKit facts:
`$(xcrun --show-sdk-path)/System/Library/Frameworks/EventKit.framework/Headers`.
Apple's web documentation is JavaScript-rendered and could not be machine-read; five
claims previously recorded as "verified" were wrong and were corrected against the headers
on 2026-08-18. Header-verified facts, externally-sourced facts, and inference are kept
visually separate in the plan (§2). Do not record an EventKit claim as verified without a
header line to point at.
