<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Learning Log

**Memory Type:** Episodic (experiences)
**Lifecycle:** Graduate to methods when pattern emerges per §7.0.4

> **Entry rules:** Each entry ≤5 lines. State what happened, then the actionable rule.
> Record conclusions, not evidence. If it wouldn't change future behavior, it doesn't belong here.
> Route other content: decisions → PROJECT-MEMORY, architecture → ARCHITECTURE.md

---

## Active Lessons

**2026-08-18 — A "verified facts" table with no source pointer per row is where wrong
claims hide.** Five EventKit claims were recorded as verified and five were wrong,
including one (`isImmutable`) that would have shipped a guard rejecting the user's own
writable calendars. **Rule:** never mark a platform-API claim verified without a file:line
to point at, and prefer local SDK headers over web docs — Apple's are JavaScript-rendered
and unreadable to tooling.

**2026-08-18 — Fixing one internal contradiction tends to open another at a different
seam.** Rev. 1 had §6 contradicting §8 on occurrence addressing; rev. 2 fixed it and
introduced `create` as a second ungated write path under a heading that said there was
only one. **Rule:** after any structural revision, re-check the seams the change touched —
consolidation especially, since it moves boundaries rather than code.

**2026-08-18 — A control that reads impressive can be strictly weaker than a one-line
predicate.** The propose/commit token machinery is the most elaborate thing in the design
and does not prevent injection; the attendee refusal is one `if` consulting the event
itself and cannot be argued past. **Rule:** rank controls by *what they consult* — ground
truth beats model-supplied arguments — not by how much machinery they involve.

**2026-08-18 — Author review does not catch author contradictions.** Three fresh-context
reviews found four blocking defects the author had read past repeatedly, two of them
independently. **Rule:** for any document that reversed direction mid-drafting, run a
fresh-context pass before approval; reversals are where stale claims survive.

**2026-08-18 — Approval recorded against controls goes stale the moment the controls are
amended.** Three of five governance-approved controls were superseded during planning while
memory still asserted all five held. **Rule:** amending a control is itself a governed
event — re-evaluate and write memory back in the same turn, never "later".

**2026-08-19 — I put the user's login password in an argument vector.** `security
set-key-partition-list -k "$PASS"` reads correctly and is a real credential leak: argv is
world-readable to every process running as that user. A fresh-context review caught it; I
did not. **Rule:** a secret in argv is a secret published. Use a prompt, a file descriptor,
or stdin — never `-p`, `-k`, or `pass:` with a literal.

**2026-08-19 — A cleanup `trap ... EXIT` does not run on Ctrl-C.** The signing script wrote
an unencrypted private key to a temp dir and would have left it there indefinitely on an
interrupt. **Rule:** `trap ... EXIT INT TERM HUP` whenever the temp dir holds key material.

**2026-08-19 — Two scripts referencing a file neither of them creates.** `make-signing-cert`
never wrote the PEM that `trust-signing-cert` tested for, so its main step silently
no-op'd on any clean machine — invisible to me because I had created that file by hand
mid-session. **Rule:** a handoff file between scripts must be written by one and asserted by
the other; test setup flows on a clean machine, not the one where you improvised.

**2026-08-19 — An inconclusive test is not a passing test.** The SIGTERM orphan check
observed zero children because the probe exits in milliseconds, which demonstrates nothing.
It would have been easy to record it as green. **Rule:** when a test cannot exercise the
condition, say so and carry it forward — a test that cannot fail is not evidence.

---

## Graduated Patterns

| Pattern | Graduated To | Date |
|---------|-------------|------|
| | | |
