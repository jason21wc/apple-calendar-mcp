<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Operations

**Memory Type:** Prospective (recurring commitments)
**Lifecycle:** Items persist indefinitely and are retired only with a documented reason — recurrence is the point, so these are never "done."

> This file tracks **recurring commitments** — the things that are never "done" because recurrence is the point. Deferred work that finishes lives in `BACKLOG.md`; both are prospective memory, split by lifecycle.

## Cadences

| Cadence | What | Last run |
|---|---|---|
| Before every push | Re-run the sanitisation sweep across tracked files: the author's macOS username and absolute home paths, personal email addresses, the host terminal app's bundle identifier, other apps observed in the TCC database, and this machine's code-signing fingerprint. None belong in a public repo, and `_ai-context/` ships with it. Keep the search terms out of this file — a checklist that names what it scrubs leaks it |
| Every phase exit | Re-read the phase's exit criteria in `docs/IMPLEMENTATION-PLAN.md` §15 and confirm each is objectively met before moving on | — |
| Every EventKit claim | Verify against the local SDK headers and cite `file:line`. Never against Apple's web docs — they are JavaScript-rendered and unreadable to tooling | 2026-08-18 |
| Every containment-control change | Run `evaluate_governance`, then write the amendment back to `PROJECT-MEMORY.md` **in the same turn**. Three controls once drifted because this was left for "later" | 2026-08-18 |
| Before any plan/spec approval | Run a fresh-context review pass. Author review does not catch author contradictions, and this document reversed direction three times | 2026-08-18 |
| On SDK bump | The MCP Swift SDK is pre-1.0 — read the changelog before moving the exact pin, and re-run contract tests | — |

## Tripwires

| Condition | What to do when it fires |
|---|---|
| A containment control (C1-C6) would be weakened, amended, or dropped | Stop. Run `evaluate_governance`, then write the amendment into `PROJECT-MEMORY.md` in the same turn |
| A probe or `--doctor` reports `inherited-*` rather than `disclaimed-child` | The self-disclaiming re-exec is not running — either the private symbol vanished on a macOS update or the spawn failed. Calendar access is then the host's, not ours. Do not ship a release in this state without saying so in the README |
| Calendar access stops working after moving or reinstalling the binary | Expected: the TCC grant is keyed to the absolute path. Re-run `--setup` at the new path |
| A Calendar call returns denied while `--doctor` reports green | Suspect the macOS 26.5 silent-denial trap: hardened runtime present, entitlement missing or cdhash drifted |
| Any code is copied (not merely patterned) from `che-ical-mcp` or `orchard-mcp` | Flag to the human before it lands; add `NOTICE` + a provenance header |
| Writes start failing after an iCloud resync | Allowlist resolution is failing closed on identifier drift — expected; re-run `--doctor` and re-add the calendar |
| The MCP Swift SDK reaches 1.0, or adds spec revision `2026-07-28` | Re-evaluate the exact pin and the one-revision-behind decision |

## Standing Authorizations

| Granted | Limits | When |
|---|---|---|
| Write capability (create, update, delete, undo) on the user's real calendar | Only under containment controls C1-C6; any weakening needs fresh governance | 2026-08-17 |
| Licence is Apache-2.0 | — | 2026-08-17 |
| Run fresh-context review agents at plan approval and after substantial phases without asking each time | Small edits do not warrant it | 2026-08-18 |
| Undo stays model-callable rather than CLI-only | Behind guards 5-9; premise (Cowork has no terminal) still unverified | 2026-08-18 |

## Metrics

| Metric | Definition | Baseline |
|---|---|---|
| Claims recorded as verified without a `file:line` | Count across plan + memory | 0 (was 5 on 2026-08-17 — all wrong) |
| Internal contradictions found by fresh-context review | Per approval pass | 4 at rev. 2; target 0 |
| Mutating code paths outside `commit()` | Should be structurally impossible | 0 |
| Tool surface size | Total MCP tools | 14 (6 read, 4 propose, 4 commit) |

---

*Convention: items are retired with a documented reason, never silently deleted — an entry that vanished and one that was never there look identical later.*

## Standing Commitments

- **stdout is protocol-only, forever.** Any stray write corrupts the MCP stream. All
  diagnostics go to stderr, control-character-escaped — including calendar and source
  names, which are attacker-influenceable.
- **Never log** event titles, notes, attendees, locations or URLs by default, and never
  return raw framework errors across the MCP boundary.
- **Any borrowing of *expression* from the MIT reference repos gets flagged to the human
  before it lands**, with attribution and license implications. Ideas and approaches carry
  no obligation; code, comments, string literals and test fixtures do.
- **Integration tests never run against real personal calendar data.** Disposable calendars
  only, opt-in and env-gated.
- **No writes to a calendar not named in the allowlist**, and the allowlist is read once at
  startup, never reloaded.
