<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Learning Log

**Memory Type:** Episodic (experiences)
**Lifecycle:** Graduate to methods when pattern emerges per §7.0.4

> **Entry rules:** Each entry ≤5 lines. State what happened, then the actionable rule.
> Record conclusions, not evidence. If it wouldn't change future behavior, it doesn't belong here.
> Route other content: decisions → PROJECT-MEMORY, architecture → ARCHITECTURE.md

---

## Active Lessons

**2026-09-13 — Ordinary completion tests accidentally measured scheduler speed.** Two gate
tests assumed work would beat 80–100 ms fixture deadlines under parallel load. **Rule:**
observe completion and timer cancellation directly, bound the failure wait, and keep
separate tests for real timeout behavior.

**2026-09-13 — Session history became an unintended client dependency.** I made a Cowork
status report the next gate although the server is client-neutral and work had moved to
Codex. **Rule:** verify in the current client, separate server guarantees from client
integration evidence, and never turn the originating host into a product requirement.

**2026-09-13 — Cancellation ends a caller, not a blocking dependency.** A read caller can
stop waiting while EventKit still occupies its executor. Freeing the admission slot at that
point would queue more work behind it. **Rule:** retain the operation slot/deadline until
actual completion, and keep deadline handling outside the blocked executor.

**2026-09-13 — A journal append is not acknowledged just because it returned an ID.** The
old writer swallowed storage failures, and its reader confused missing history with failed
I/O. **Rule:** make persistence acknowledgements explicit, distinguish unavailable history
from empty history, and test recovery across rotation boundaries.

**2026-08-27 — Safe handling is sink-specific.** #24a JSON-encoded client metadata safely but
also interpolated the same client-supplied strings raw into stderr, where controls can forge
diagnostic lines. **Rule:** when adding external data, audit every output sink independently;
encoding for one sink proves nothing about another. Prefer omitting diagnostic decoration that
the feature does not need.

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
and does not prevent injection; a guard that refetches the event consults stronger evidence
than a model-supplied summary. Whether the resulting policy is confirmation or refusal is a
separate human decision. **Rule:** rank controls by *what they consult* — ground truth beats
model-supplied arguments — not by how much machinery they involve.

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

**2026-08-20 — I verified the protocol and never verified a payload.** Phase 4 shipped with
every event tool returning numbers where its own schema promised strings. `tools/list`
passed, the handshake passed, 73 tests passed, and every real query failed at the client.
The gap: nothing ever encoded a result and compared it against the schema the server
advertises — which needs **no calendar access and no permission**, only synthetic objects.
I skipped it because the dev binary had no grant, and treated that as a reason to test less
rather than a reason to test differently. **Rule:** for any contract you publish, assert your
own output against it with synthetic data; the absence of a live dependency is never the
reason not to.

**2026-08-20 — A bug report from real use beat four review agents.** Contrarian, validator,
coherence and security reviews all read this code and none caught it, because it is invisible
in source: `let start: Date` looks right, and only the encoder's default behaviour makes it
wrong. **Rule:** reviews catch reasoning errors; running the thing catches runtime ones.
Neither substitutes for the other.

**2026-08-20 — I filed a checkable fact as an "open question" and designed around it for a
whole phase.** The premise justifying a write tool — "nobody has verified whether Claude
Desktop prompts" — was answered in the app's own bundle, and by an already-installed MCP
server with delete tools that had been traversing that path for months. Open questions get
designed around; assumptions get checked. **Rule:** before building anything to answer a
question, spend ten minutes trying to answer it for free — read the binary, check what is
already installed, grep the config.

**2026-08-20 — Calling something "an experiment" made it survive scrutiny it should not
have.** Three write designs were refuted for resting on unmeasured premises. The fourth rested
on one too, but the word "measurement" made it read as the cure rather than the disease.
**Rule:** an experiment that also ships the capability it is measuring is not an experiment.
If the measurement can be taken without the capability, it must be.

**2026-08-20 — I treated a stated requirement as a specification instead of a symptom.** The
human asked for "full ability to revert". I took that as *restore the original object*, and
spent three refuted designs on identifier stability, invitation state and series membership —
all genuinely unsolvable. Asked directly, the actual need was "put things back the way they
were, and it can be a new event with the same info." Every blocker vanished. **Rule:** when a
requirement leads somewhere impossible, re-examine the requirement before the design. Ask what
outcome it protects, not what mechanism it names.

**2026-08-20 — SUPERSEDED 2026-08-25: two constraints initially appeared to stop at the same
line.** C6 once refused attendee events, and attendees are the one field EventKit cannot
restore. The human later accepted confirmed removal plus a narrow C7 exception and social
recovery. **Rule:** when controls appear to share a boundary, record whether that identity is
an invariant or merely a policy choice; amending one may invalidate the other.

**2026-08-20 — Withdrawing a decision is a code change, not a memory edit.** C1 was dropped in
conversation and the natural next move was to write it into PROJECT-MEMORY and move on. Grepping
the repo first found the allowlist live in shipped code, silently reporting every one of the
user's calendars as non-writable. **Rule:** when a decision is reversed, grep for its
implementation before recording the reversal — a control written for a future phase may already
be load-bearing in a shipped one.

**2026-08-20 — `private` on a pure function is where untested logic hides.** `writableReason`
took two booleans, returned four strings, needed no calendar and no permission — and was
untestable purely because of an access modifier chosen by reflex. **Rule:** if a function is
pure and its output is user-facing, make it internal and test it; "it's an implementation
detail" is not a reason when the implementation detail is a sentence the user reads.

**2026-08-20 — A sibling project's bug report found a defect here that no review had.** `apple-mail`'s
`delete_draft` hung for 60s, twice. The same class of gap exists in this server and is worse — no EventKit
call has a timeout, and because the store is a serial actor on one dedicated thread, one hang wedges every
later calendar operation rather than just its own caller. Four security reviews and 99 tests never raised
it. **Rule:** read bug reports from adjacent systems as findings against your own; shared authorship and
shared architecture mean shared defects, and the sibling's failure is free evidence you did not have to
cause yourself.

**2026-08-20 — "Not found" degrading into "hang" is worse than either.** The `apple-mail` failure was an id
FORM mismatch between two tools in one server: create returned an RFC Message-ID, delete expected an
internal numeric id, and the lookup scanned instead of erroring. The caller could not distinguish
not-found from still-working from deadlocked, and could not safely retry. **Rule:** every lookup must fail
fast and structured on an unresolvable key, and every operation needs a bound well under the client's
ceiling. An unbounded operation has no honest error to report.

**2026-08-22 — The drift had one structural cause, and it was not carelessness.** Phase status,
test counts and plan revision numbers were restated in six files, and the canonical plan lived
outside the repo as a private file the repo held a *copy* of. Every restatement is a thing that
can go stale independently, and the count reached four different values (63/95/99/119) across
four documents. **Rule: a volatile fact belongs in exactly one place, and preferably in a
command rather than in prose. If a document must mention it, it points at the command.**

**2026-08-22 — The schema conformance suite could not see the field that was lying.** It walked
the *declared* properties of each `outputSchema`, so `limits_applied` — emitted on every
response and declared in none — was skipped entirely while it reported the hard ceiling as the
limit in force. **Rule: a conformance check must test in both directions. Declared-but-absent
AND emitted-but-undeclared. Whatever the schema does not name, nothing is checking.**

**2026-08-22 — A field that echoes an argument can be false without being malformed.**
`effective_time_zone` reported the caller's requested zone while timestamps rendered in the
machine's. Every timestamp carried a valid RFC 3339 offset, so nothing downstream could detect
it. **Rule: a field that describes the payload must be derived from the payload. Echoing the
request back as though it were a fact about the response is how a well-formed answer lies.**

**2026-08-22 — Truncating before filtering turns a count bug into an absence bug.** The search
fetched 500 events and filtered those, so a match at position 501 came back as "no matching
events". A wrong count is a nuisance; a wrong absence is what makes an assistant book over
something. **Rule: filter the whole bounded set first, cap second — and bound the set by the
query window, not by the page size.**

**2026-08-22 — "Untestable" was a missing prerequisite, not a property.** Orphan behaviour sat
as an unmet exit criterion for three phases because every subprocess test invoked `--version`,
which exits in milliseconds. Once a long-running command existed the test took one file and
found a real fact in passing (there is no `serve` subcommand). **Rule: when a gate is deferred
as untestable, record what would make it testable — otherwise "not yet" quietly becomes
"never".**

**2026-08-22 — The fresh-context audit found four dangerous claims I had just finished
"reconciling".** I audited the read surface against its contract and fixed eight defects, then
a subagent with no context found four more of exactly the class I had been hunting: controls
marked *Live* with no code path to gate, `--doctor` printing "read and write" on a build with
no write tool, a computed-and-discarded value whose comment promised it was reported, and a
README recovery claim in the present tense. **Rule: the author who just corrected a document
is the reader least able to see what is still wrong in it. Budget for the fresh pass as part
of the work, not as a formality after it.**

**2026-08-22 — Test coverage proves a function works, not that anything calls it.**
`CalendarScope.unmatchedIds` was computed, documented as "reported rather than swallowed", and
unit-tested three ways — and no caller ever read it, so a stale calendar id produced an empty
result indistinguishable from an empty week. Green tests around a dead value look exactly like
green tests around a live one. **Rule: when a value exists to be surfaced, assert it at the
boundary it is surfaced through, not only at the function that computes it.**

**2026-08-22 — "Live" conflated a decision being in force with a mechanism being in force.**
Four containment controls were tabulated as Live while the server had no mutation path for any
of them to gate, and ARCHITECTURE republished it publicly. **Rule: a control has two states —
adopted and enforced — and any table with one column will merge them. Say which.**

**2026-08-22 — I bounded a query in the wrong dimension and called it safe.** Uncapping the
search fetch, I reasoned "the window is capped at 31 days, so it is bounded in time". An
independent review pointed out that `eventsMatchingPredicate` returns an ARRAY — EventKit had
always materialised every matching event, and my change added a DTO per event on top. Days
bound nothing about count. The fix was not a smaller window or a scan ceiling but an ordering
change: match on the `EKEvent` before converting, so only returned matches become objects.
**Rule: when you justify removing a limit, name the dimension the remaining limit constrains,
and check it is the dimension that grows.**

**2026-08-22 — Removing a redaction pass was the proof the fix was right.** Once the adapter
matched against the event itself, the search no longer needed to fetch notes and location just
to search them, so `redact()` — which stripped them back out afterwards — became dead. A
control that exists to undo an earlier decision is a sign the earlier decision was wrong.
**Rule: when a fix deletes a compensating step rather than adding one, that is evidence it
addressed the cause.**

**2026-08-22 — A generic function is how a tested rule and the executed rule stay the same
rule.** The filter-then-count-then-cap ordering was tested over DTOs while the adapter had its
own hand-inlined copy over `EKEvent`s. Two implementations of one guarantee is one that can
drift silently. Making it generic over the element means the test exercises the code that
runs. **Rule: if a rule matters enough to test, the code under test must be the code in the
call path — not a faithful-looking twin.**

**2026-08-22 — The control the whole design rested on had never been switched on, and two
"measurements" were taken on top of it.** Memory recorded `toolPolicy: {"*": "ask"}` as
configured in Claude Desktop. It appears in no server entry, no backup, and no settings file —
it was never applied. So the measurement "reads do not prompt even with toolPolicy set" and the
later "a write executed with no prompt" both measured the same thing: the default with no
policy at all. **This is the third time here: the C1 allowlist decided a shipped tool's output
while unconfigured, four containment controls were tabulated "Live" with no code path to gate,
and now this.** The shape is always the same — the control is recorded when it is *decided*,
and nothing re-checks that it was *applied*. **Rule: verify a control by observing the artifact
that would carry it — the config file, the binary, the call path — never by remembering that
you set it up. And before trusting any measurement, confirm the thing being measured is
switched on.**

**2026-08-22 — A negative result is only evidence if the mechanism was present to fail.**
"No prompt appeared" reads like an answer and was nearly recorded as one. With the policy
absent, the only thing it established was that the default does not gate writes — useful, but
the opposite of what the experiment was for. **Rule: before accepting a null result, state what
would have had to be true for a positive one, and check that it was.**

**2026-08-22 — I asked a sibling project to confirm my hypothesis and it refuted it usefully.**
I suspected the unprompted write was explained by missing annotations. It was not: their write
tools declare `readOnlyHint: false` and their deletes declare `destructiveHint: true`. What
they supplied instead was a third confound I had not considered — the two tools tested never
request confirmation server-side at all — making the silence overdetermined three ways. **Rule:
ask a peer for the facts that would DISCONFIRM your hypothesis, not for the ones that would
confirm it; and when a null result has several sufficient causes, it is evidence about none of
them.**

**2026-08-22 — Server-initiated elicitation was available in our binary, but owning the
request is not the same as owning the guard.** The pinned SDK supports elicitation, while its
capability validator is inert under our effective default configuration. **Rule: a project-
owned approval control requires an explicit, tested capability check and refusal path; a
control you ship is verifiable only when its effective guard is also yours.**

**2026-08-22 — I told the human a control "fails closed" and it does not.** The SDK's
`validateClientCapability` reads exactly like a fail-closed guard, and its whole body sits
inside `if configuration.strict` — with `strict: false` as the default our server takes. I had
already read the function and quoted it before noticing the enclosing condition. **Rule: when
citing a guard as a safety property, read the enclosing scope and the default configuration,
not just the guard. A conditional guard is a comment until you can name the condition and show
it holds** — this is the third instance here of a control that was real in source and inert in
the running configuration.

**2026-08-24 — A protocol standard is not evidence that a framework call triggers that
protocol action.** iTIP defines `CANCEL` and `REPLY`; it does not prove EventKit's
`removeEvent` emits either. **Rule: keep protocol semantics, exposed platform capability, and
observed adapter behavior as separate evidence levels; verify each claim at its own layer.**

**2026-08-24 — A persistence component without an injectable root turned unit tests into live
state writes.** Journal tests accumulated in the user's state directory and one fixture wrote
outside the journal's synchronization. **Rule: every persistent subsystem needs a temporary
test root, and tests must assert that their resolved path is outside the live state directory.**

**2026-08-26 — A green disposable CI runner proved independence from local prerequisites, not
storage hermeticity.** The suite passed without a Calendar grant, signing certificate, or
pre-existing state, while `JournalTests` still wrote into the runner user's normal state path.
**Rule:** call tests hermetic only when state roots are injected and asserted outside production
paths; an ephemeral machine merely makes contamination disposable.

**2026-08-24 — I cited a standard as proof that an implementation obeys it.** RFC 5546 defines
what organizer `CANCEL` and attendee `REPLY` mean; I wrote that this "verifies" EventKit sends
them on delete, and recorded it as no-longer-inference. It does nothing of the kind — the
causal step from `removeEvent` to a message on the wire is exactly the part no specification
can supply. Caught by a fresh reviewer, in a session I had spent removing claims of this shape.
**Rule: a spec defining semantics, a header naming a concept, and an implementation performing
an action are three different evidence layers. Name which one you have.**

**2026-08-24 — I misquoted a warning that my own tool output had attributed correctly.** The
fetched Google page said the caveat about emails being sent anyway belongs to the deprecated
boolean `sendNotifications`; I attached it to `sendUpdates`, which is string-valued and cannot
be set to `false`. The error was introduced between reading and summarising. **Rule: when a
source distinguishes two parameters, carry the distinction into the summary — a caveat is
attached to the thing it was written about, and generalising it invents evidence.**

**2026-08-24 — The test written to prove corruption-tolerance was the corruption.**
`corruptLineIsSkipped` opened the live journal, seeked to the end and wrote outside both the
write queue and O_APPEND — the exact non-atomic append gotcha 54 exists to warn about,
reproduced inside the suite. Running in parallel it could destroy the entry another test was
asserting on, which is what made the suite intermittently red, and it left 36 malformed lines
in the user's real state directory. I had diagnosed it vaguely as "parallel tests sharing a
file"; a reviewer found the actual line. **Rule: a test that fabricates a failure condition
must fabricate it in a fixture it owns. If it reaches into production storage to do so, it is
not simulating the bug — it is committing it.**

**2026-08-24 — I proposed a permission matrix that quietly reversed four settled decisions.**
It ungated inert creates (the human had asked for approval on create, change and delete),
treated restorability as authorization, downgraded a rejection to an approval, and
re-introduced the `source_type` guard the human had deliberately withdrawn — all while
presenting itself as adopting best practice. **Rule: when a new model touches an area with
existing decisions, diff it against those decisions explicitly before proposing it. A design
that reads as coherent can still be a silent reversal, and "industry practice" is not
authority over a decision the human already made.**

**2026-08-26 — My isolation fix guarded the call that was already correct.** I gave `Journal`
a `root:` parameter with a production default and wrote a test asserting the temp root
resolved outside the user's home. That checks a call that passed one. The failure that
mattered — a test simply omitting `root:` and silently getting the live directory — was
invisible to it, and was the mode reachable by forgetting rather than by deciding. Removing
the default made omission a compile error. **Rule: when writing a guard, ask which failure it
can actually see. A runtime check inspects the arguments it is handed and is blind to the call
that omitted one; prefer a guarantee the compiler enforces.**

**2026-08-26 — A linter that lives in the file it lints always finds its own text.** The
assertion that no journal test passes the live root matched the line holding the search
strings. `test-shell.sh` had already met this and solved it by excluding itself; here scanner
and subject are the same file by design, so the needles are built from fragments. **Rule: a
source-text check must be written so that it is not an instance of what it forbids.**

**2026-08-27 — I committed a peer's factual claim without running the one command that checked
it.** A review reported the installed binary as `notDetermined` with an invalid entitlement
blob; I reviewed the diff, agreed it read sensibly, and pushed it. Measuring before the
reinstall showed `fullAccess` and a perfectly valid entitlement. The claim was about a
machine's live state, checkable in seconds, and I treated it as a documentation edit because it
arrived as one. **Rule: a review's *reasoning* can be assessed by reading; a review's *facts*
have to be measured, and a claim about live state that arrives inside a documentation diff is
still a claim about live state.**

---

## Graduated Patterns

| Pattern | Graduated To | Date |
|---------|-------------|------|
| | | |
