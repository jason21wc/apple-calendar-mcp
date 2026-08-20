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

**2026-08-19 — I wrote a security comment asserting a property the code did not have.**
`// pid-bound, so it cannot be forged` sat on a check any parent defeats with `VAR=$$`. A
security audit found it; the code review before it did not, because I had pointed that
review at password handling. **Rule:** a comment claiming something *cannot* be done is a
claim requiring proof. Write the bypass and run it before writing the comment.

**2026-08-19 — An environment variable can never authenticate its own setter.** Every
attempt to make one trustworthy (constants, then pid-binding) failed to the same one-line
bypass. The fix was to stop asking the environment and ask the kernel. **Rule:** when state
must be trusted, get it from the subsystem that owns it, not from something the caller
hands you.

**2026-08-19 — A flag that "works" may be working by accident.**
`set-key-partition-list -s "$KEYCHAIN"` looked like `-s <keychain>`; `-s` actually takes no
argument and the keychain was landing on a trailing positional. It worked, so it went
unexamined — while silently rewriting every other signing key on the machine. **Rule:**
read the usage string for any command touching keychains, signing, or permissions, even
when the command already appears to work.

**2026-08-19 — A broken assertion is worse than no assertion.** Converting `sign.sh` from
printing the entitlement to asserting it introduced a check that failed on correctly signed
binaries, because `grep -q` plus `pipefail` turns a match into a non-zero pipeline. Had I
only tested the passing case I would have shipped a build gate that blocks every good
build. **Rule:** test a new guard in BOTH directions — that it passes what should pass and
fires on what should fail — before trusting it.

**2026-08-19 — I tested a security fix on the only path that could not be vulnerable.** The
forgery fix asked the kernel, but fell back to the forgeable check when the symbol was
missing. On this machine the symbol exists, so my test exercised the safe path and passed,
while the vulnerable path was unreachable and unverifiable. A fresh review caught it.
**Rule:** when a fix has a fallback, the fallback is the part that needs testing — and if it
cannot be reached, prefer failing closed to degrading.

**2026-08-19 — Memory ran ahead of the code.** Three gotchas recorded lessons as *learned
and fixed* while the same bug sat in two other files: the `pipefail`/`grep -q` trap was
written up the moment I hit it, then left live in both signing scripts. **Rule:** after
recording a lesson, grep the whole repo for the pattern before writing it down as fixed.

**2026-08-19 — I recorded a fix that was not one, then applied it three times.** Gotcha 34
prescribed "capture to a variable, then match" for the `pipefail`/`grep -q` trap. That is
still a pipeline and still inverts; it only moves the threshold. The real bug meanwhile sat
untouched in another script, where it reported a present signing certificate as absent —
which would have minted a second certificate and silently destroyed Calendar access.
**Rule:** when recording a remedy, verify the remedy, not just the diagnosis.

**2026-08-19 — Mutation testing is the only evidence a test suite works.** 17 deliberate
defects were injected and 17 were caught — and the exercise found a bug in the tests
themselves: subprocess tests referenced `Reexec.depthKey`, so renaming the constant renamed
it in the test too and the guard tests passed against a binary that no longer honoured the
documented variable. **Rule:** tests that assert an external contract must hardcode the
literal, not import the constant, or they only prove the code agrees with itself.

**2026-08-19 — The tests caught me adding unnecessary behaviour.** Fixing the byte cap, I
added an "unnamed" placeholder for labels that sanitise away entirely. Two existing tests
failed, and they were right: the placeholder restored no distinguishability and only added
a magic value. **Rule:** when a test disagrees with a change, establish which is correct
before changing the test — here the test was.

**2026-08-20 — "Verified" meant "I ran it from my own shell."** The Phase 1 gate said *have
Claude Code spawn the binary*; what I did was invoke it from a Bash tool and inspect the
parent process, then carried it as verified for three phases. A real MCP-client spawn told a
richer story immediately — Claude Desktop disclaims servers itself, so our re-exec correctly
idled. **Rule:** when a gate names a specific actor, that actor has to perform the action; a
convenient proxy is a different test with a different result.

**2026-08-20 — I fixed eight things and left the list saying they were owed.** The plan's
cleanup section still listed seven completed items as outstanding. Same drift as the eleven
contradictions that prompted the rewrite, one level up: the work moved, the tracker did not.
**Rule:** verify a checklist by grepping for the defect, never by remembering that you fixed
it.

---

## Graduated Patterns

| Pattern | Graduated To | Date |
|---------|-------------|------|
| | | |
