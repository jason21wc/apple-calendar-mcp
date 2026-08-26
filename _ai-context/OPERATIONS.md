<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Operations

**Memory Type:** Prospective (recurring commitments)
**Lifecycle:** Items persist indefinitely and are retired only with a documented reason — recurrence is the point, so these are never "done."

> This file tracks **recurring commitments** — the things that are never "done" because recurrence is the point. Deferred work that finishes lives in `BACKLOG.md`; both are prospective memory, split by lifecycle.

## Cadences

| Cadence | What | Last run |
|---|---|---|
| Before every push | `./scripts/test.sh` (never plain `swift test`) and `bash -n scripts/*.sh`. Three review rounds each found real defects in hand-verified code; the consistent failure was exercising only the path the author built. **CI now runs the same commands on every push and pull request**, which makes this a backstop rather than the only guard | 2026-08-22 |
| Before every push | Re-run the sanitisation sweep across tracked files: the author's macOS username and absolute home paths, personal email addresses, the host terminal app's bundle identifier, other apps observed in the TCC database, and this machine's code-signing fingerprint. None belong in a public repo, and `_ai-context/` ships with it. Keep the search terms out of this file — a checklist that names what it scrubs leaks it |
| Every phase exit | Re-read the phase's exit criteria in `docs/IMPLEMENTATION-PLAN.md` — per-phase in its own section (Phase 4's are in §5), overall in §12 — and confirm each is objectively met before moving on. **Record the ones that are not met**; Phase 4's orphan criterion sat unmet and unstated for three phases | 2026-08-22 |
| Every EventKit claim | Verify against the local SDK headers and cite `file:line`. Never against Apple's web docs — they are JavaScript-rendered and unreadable to tooling | 2026-08-18 |
| Every containment-control change | Run `evaluate_governance`, then write the amendment back to `PROJECT-MEMORY.md` **in the same turn**. Three controls once drifted because this was left for "later" | 2026-08-18 |
| Before any plan/spec approval | Run a fresh-context review pass. Author review does not catch author contradictions, and this document reversed direction three times | 2026-08-18 |
| On SDK bump | The MCP Swift SDK is pre-1.0 — read the changelog before moving the exact pin, and re-run contract tests | — |

## Tripwires

| Condition | What to do when it fires |
|---|---|
| A containment control (C3-C7) would be weakened, amended, or dropped | Stop. Run `evaluate_governance`, then write the amendment into `PROJECT-MEMORY.md` in the same turn |
| A control is about to be recorded as configured, live, or in force | Observe the artifact that carries it — grep the config, read the binary, find the call path — and cite what you saw. For an SDK/framework guard, also inspect its enclosing condition, effective runtime configuration, and default. Recorded-but-never-applied has happened three times here (C1's allowlist, C3-C6 "Live", `toolPolicy`) |
| A measurement is about to be recorded from a null result | State what would have had to be true for a POSITIVE result, and verify that precondition held. Two write-prompt tests measured absent mechanisms |
| A test touches persistent state | Inject a temporary root and assert the resolved path is not beneath `Runtime.stateDirectory`. Never let a unit test append to live user state |
| A protocol or platform document is used to claim external behavior | Keep the evidence levels separate: a protocol defines semantics, an SDK header proves exposed capability, and only platform documentation or a controlled integration test proves a specific framework call's behavior |
| A document states a test count, a tool count, or a plan revision number | Delete it and point at the command or the file that reports it. Every one of these has drifted at least once |
| A response field would restate a request argument rather than describe the payload | Derive it from the payload. `effective_time_zone` echoed the caller's zone while timestamps used another, and every timestamp still looked valid |
| A payload gains a field | Declare it in the `outputSchema` in the same change, and add it to `required` if it is always emitted. An undeclared field is validated by nobody |
| A probe or `--doctor` reports `inherited-*` rather than `disclaimed-child` | The self-disclaiming re-exec is not running — either the private symbol vanished on a macOS update or the spawn failed. Calendar access is then the host's, not ours. Do not ship a release in this state without saying so in the README |
| Calendar access stops working after moving or reinstalling the binary | Expected: the TCC grant is keyed to the absolute path. Re-run `--setup` at the new path |
| A Calendar call returns denied while `--doctor` reports green | Suspect the macOS 26.5 silent-denial trap: hardened runtime present, entitlement missing or cdhash drifted |
| Any code is copied (not merely patterned) from `che-ical-mcp` or `orchard-mcp` | Flag to the human before it lands; add `NOTICE` + a provenance header |
| Writes start failing after an iCloud resync | `eventIdentifier` drifts on sync; re-find the event by content rather than by stored id |
| The MCP Swift SDK reaches 1.0, or adds spec revision `2026-07-28` | Re-evaluate the exact pin and the one-revision-behind decision |

## Standing Authorizations

| Granted | Limits | When |
|---|---|---|
| Fix a proven contract defect in the shipped read surface without a fresh decision | The promise must be *currently made* by the canonical plan or a tool's own schema, and the defect must be demonstrated in source. Expanding the tool surface is NOT covered | 2026-08-22 |
| Write capability (create, update, delete, restore) on the user's real calendar | Only under containment controls C3-C7, and only once a write tool is confirmed to prompt; any weakening needs fresh governance | 2026-08-20 |
| Licence is Apache-2.0 | — | 2026-08-17 |
| Run fresh-context review agents at plan approval and after substantial phases without asking each time | Small edits do not warrant it | 2026-08-18 |
| Undo stays model-callable rather than CLI-only | Behind the restore guards in `SPECIFICATION.md` ("Planned guards" 4-8) and the gates in plan §6. The earlier "guards 5-9" numbering matched no document, and the authorization routed through C4a, which C7 superseded. Premise (Cowork has no terminal) confirmed 2026-08-19: Cowork runs locally in Claude Desktop | 2026-08-18 |

## Metrics

| Metric | Definition | Baseline |
|---|---|---|
| Claims recorded as verified without a `file:line` | Count across plan + memory | 0 (was 5 on 2026-08-17 — all wrong) |
| Internal contradictions found by fresh-context review | Per approval pass | Historical baseline: 4 at the rev. 2 review, 11 at the rev. 4 audit. **2026-08-22 audit: 4 dangerous, 10 misleading, 7 cosmetic — all accepted and fixed.** Target 0 |
| Mutating code paths outside `commit()` | Should be structurally impossible | 0 |
| Tool surface size | Total MCP tools **shipped** | **5, all read-only.** The 14-tool figure (6 read, 4 propose, 4 commit) is the *planned* surface and was recorded here as though it were the current one. Asserted in the suite (`ToolRegistry.all().count == 5`) rather than tracked by hand |
| Volatile counts duplicated in durable docs | Test counts, tool counts, plan revision numbers restated in prose | 0. The test count reached four different values across four files before this was made a rule |

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
- **No destructive tool ships ahead of its restore path.** Delete and its restore land in the
  same change, tested end to end against a disposable calendar: create → delete → restore →
  diff every persisted field. Shipping the destructive half first leaves a window with no way
  back, and C7 is the primary user-facing control now that the allowlist is withdrawn.
