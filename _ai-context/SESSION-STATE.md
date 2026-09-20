<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Session State

**Last Updated:** 2026-09-20
**Memory Type:** Working (transient)
**Lifecycle:** Current position only; decisions and history live in the other memory files.

## Where things stand

- **Systemic review completed; qualified upstream follow-up is ready, not submitted.**
  Existing issue [#40390](https://github.com/openai/codex/issues/40390) remains the closest
  report. The isolated direct-call fixture now reproduces missing frontend resolution
  **and** stale `waitingOnApproval` for ten seconds after acknowledged server cancellation
  and after MCP disconnect. Normal answers and late answers return the thread to idle;
  a late old acceptance did not settle a newer form in the bounded check.
  Source shows split ownership: internal cancellation ends the MCP request, while frontend
  callbacks/approval guards normally finish on a reply or broader turn/thread cleanup.
  Turn transitions can mask the missing per-request path; the direct test runs outside a
  model turn and does not prove an indefinite normal-chat hang. Replay/idle eviction effects
  are source-supported, unmeasured. Current-main source still has the gap at inspected
  `a2de8fedcc3abe3cdde09b43515db820fb6b95b5`. See `docs/CODEX-ELICITATION-ISSUE.md` for
  research, results, limits and the proposed comment. `--extended` runs the new scenarios.
  No production code, installed binary, live configuration or Calendar data changed.
  **Next action:** human decision on submitting the qualified comment to #40390. No further
  identical native probe, restart or deadline change is justified. Gate 1 remains open.

- **Updated-host decline and timeout delivery now pass.** ChatGPT `26.915.31945` bundles
  Codex `0.155.0-alpha.9.2`. At the human's request, attended retry returned `declined` in
  12.5 seconds; desktop response ID 78 logged decline at `2026-09-20T03:32:55.231Z`.
  The following unanswered probe returned `timed_out` in measured 30,040 ms. Native
  diagnostics after each remain `fullAccess` / `disclaimed-child`; no restart was needed.
- **Timeout observation retry:** at the human's “Try again” request, the unanswered probe
  again returned `timed_out` in measured 30,042 ms. Follow-up diagnostics at
  `2026-09-19T22:42:44-06:00` remain `fullAccess` / `disclaimed-child`. No Calendar data
  changed. This is additional delivery evidence, not visual dismissal evidence.
  Governance `gov-69e1df9bba36` (PROCEED); the observation is recorded below.
- **Human confirms expired controls remained editable:** the checkbox and Continue/Skip
  buttons remained visible and editable after timeout. This is not merely completed history.
  The human then reported needing Skip “to get the prompt window”; whether that means the
  normal chat composer has been asked explicitly. Desktop log records a late decline at
  `2026-09-20T04:44:00.975Z` (request ID 8), after timeout delivery; diagnostics afterward
  remain healthy. No new probe was opened. Native UI cleanup is not passing; keep Gate 1 open.
  Exact tagged source shows internal cancellation removes its response route but the separate
  app-server frontend task awaits a human response before emitting `serverRequest/resolved`.
  This fits the observation; no runtime notification trace was captured. The concrete report
  is `docs/CODEX-ELICITATION-ISSUE.md`, prepared but not submitted.
- **Previous unseen response clarified:** the human was elsewhere and did not see the form
  that yielded accept/confirm false and `invalid_response`. It establishes refusal of
  non-affirmative content, not a human action. The cause of that host response is unknown.
  Stay in this conversation for attended tests; the 30-second server deadline keeps running.

- **Earlier host checkpoint: affirmative form verified; Skip returned timeout.**
  The human saw the successful form, then explicitly chose Skip without checking the request.
  Installed UI source maps Skip directly to decline, independent of checkbox state; desktop
  logs confirm decline. The native probe instead returned `timed_out`. No Calendar changed.
- **Installed `0.2.3` and healthy Codex diagnostics are verified.** No server reinstall,
  Calendar grant, or blind restart is needed. Acceptance with `confirm: false` was correctly
  refused; attended `confirm: true` passed and visibility was human-confirmed.
- **Host cancellation defect identified; runtime explanation remains an inference.**
  The earlier desktop `26.908.70816` / backend `0.154.0-alpha.6.2` excludes ordinary forms from
  cancellation handling and waits for pending forms before delivering code-mode results.
  Explicit Skip's transcript spans over 15 minutes despite a reported 30-second duration;
  decline and timeout-result delivery are 1 ms apart. This fits a held timeout result,
  but exact wire/physical-click timing was not captured. Post-dismissal diagnostics prove
  connection health, not unattended cleanup. See `docs/APPROVAL-PROBE-DESIGN.md`.
- **Gate 1 stays open for the remaining UI/approval observations above.** No Calendar
  content changed and no write tool exists. Do not request another updater check or restart.

- Implementation `fd1292b` passed full macOS CI, including lifecycle tests:
  https://github.com/jason21wc/apple-calendar-mcp/actions/runs/35058103638.

## Historical checkpoints (superseded by current position above)

- **Pre-install checkpoint: `0.2.3` signed correction prepared.** The probe's root
  schema title is rejected by Codex's typed parser, whose failure path cancels before UI.
  The original installed wire payload fails the schema exported by bundled backend
  `0.154.0-alpha.6.2`; corrected debug and signed release payloads pass. The regression fails
  before the fix and passes afterward. Local broad suite and independent review pass.
  No host config, approval policy or Calendar grant changed. Native human approval remains
  unproved. Candidate SHA-256 and exact install command are in
  `docs/APPROVAL-PROBE-DESIGN.md#installation-handoff`.

- **Installed `0.2.2` and native Codex connection verified on September 15.** The user
  reports full quit/reopen. Installed version, strict signature and SHA-256 match the signed
  candidate below. Native diagnostics report `fullAccess` / `disclaimed-child` and explicit
  form/URL declarations. `calendar_approval_probe` is exposed by this connection.
- The first native probe returned `canceled` immediately, with `calendar_changed: false`
  and `authorizes_writes: false`. A following native diagnostic succeeded on the same
  connection. **The human subsequently confirmed no form appeared and they did not cancel one.**
  The native cancellation therefore does not demonstrate a human refusal. The user-requested
  bounded event listing then succeeded without truncation; no event details are persisted.
  The investigation found the schema defect above; install the corrected candidate before
  another probe. A restart of the unchanged `0.2.2` binary would not fix the payload.
- Documentation closeout `ea5d505` also passed full CI:
  https://github.com/jason21wc/apple-calendar-mcp/actions/runs/34925673192.

- **#24b candidate is implemented and locally validated.** `0.2.2` adds opt-in
  `calendar_approval_probe` plus a pinned, attributed SDK lifecycle patch in `Vendor/swift-sdk`.
  The probe has no EventKit/journal caller or write token. Default discovery remains five
  tools. Human approval is still unproved; no write tool exists.
- Final source review passed after fixing batch prompt queuing, cancellation of buffered
  batch results, and unbounded outer response sends. The SDK now bounds incoming slots to
  16 and response delivery to 5 seconds; overload or transport failure closes the connection.
  Ordinary unanswered 30-second approval prompts keep a healthy connection available.
- Local broad suite passes with the known `ServerLifecycleTests` sandbox exclusion;
  focused fake-client/owned-pipe cases pass. Deliberately retaining completed SDK send tasks
  makes the settlement checks fail; exact production source was restored and rerun green.
  The signed release binary passed synthetic wire discovery, disabled dispatch, unsupported
  form, argument validation, accept/decline/cancel/invalid response and EOF shutdown.
  Its real 30-second non-response deadline also passed; a late acceptance was ignored
  and subsequent tool discovery succeeded on the same connection. This is synthetic
  protocol evidence, not a measurement of host prompt dismissal or human approval.
- Signed candidate: `.build/release/apple-calendar-mcp`, version `0.2.2`, SHA-256
  `2a3902acede874c5c547ef1fb921f2ee3bd91018b02b6ca049f49aebd9c219af`.
  Strict signature, hardened runtime and Calendar entitlement pass; designated requirement
  matches installed `0.2.1`. Backup: `.build/apple-calendar-mcp-0.2.1.backup`.
  Implementation `ea4c5ea` is published and full macOS CI passed without exclusions:
  https://github.com/jason21wc/apple-calendar-mcp/actions/runs/34925395216.
- The preceding implementation session left `0.2.1` installed; the September 15
  verification above supersedes that installed-state checkpoint. No Calendar data changed.
  Codex native reads are verified. Cowork visibility is user-confirmed; Claude Code
  user-scope registration is confirmed by supplied output, with no native CLI call yet.
  Those observations establish connection/read access, never human write approval.

- A signed `0.2.1` candidate fixes a reproduced SDK initialization incompatibility with
  object-valued experimental capabilities. Local tests and real-process initialization,
  tool discovery, and EOF shutdown pass; its signing requirement matches the prior `0.2.0`.
  Actual Codex logs confirm a handshake/data-format failure, but the exact desktop payload
  was not captured. Full CI passed on `f6c4262`:
  [verification run](https://github.com/jason21wc/apple-calendar-mcp/actions/runs/34857485411).
  Installation was attempted with escalation but the shell refused to execute `sudo`
  (`operation not permitted`). The human then installed the candidate from the interactive
  terminal. On September 14 the agent verified installed version `0.2.1` and a passing
  strict signature check at the final path. Native Codex verification now PASSES after
  full quit/reopen: permission status is `fullAccess` / `disclaimed-child`, form and URL
  declarations are true, and a bounded busy-interval read succeeded without truncation.
  Human approval remains unproven. The rollback copy is
  `.build/apple-calendar-mcp-0.2.0.backup`.
- Phases 1–4 are implemented. **Five read-only tools; no write tool exists.** The Phase 5
  journal has no production caller. Write policy remains C3–C7, as amended 2026-08-25.
- Readiness hardening is committed at `aa21c13`: unsupported availability counts as busy;
  content reads have bounded waits and fail fast after timeout; diagnostic controls are
  escaped; journal failures throw and recovery reads cross month boundaries.
- The plan/specification now agree that unrestorable future-events deletion is refused.
  Snapshot completeness explicitly includes existing alarms and structured locations.
- Full macOS CI passed the implementation commit, including lifecycle checks:
  [verification run](https://github.com/jason21wc/apple-calendar-mcp/actions/runs/34766574299).
  Consult `git status` for the current checkout; the hash above identifies the implementation,
  not subsequent closeout-only commits.
- Installed binary is now `0.2.3`; the refreshed native Codex connection answers diagnostics.
  Bounded content reads passed before this refresh. Neither establishes write approval.
- Client-neutral documentation and backlog now treat Claude Cowork and ChatGPT/Codex Work
  as peer targets. User-level Codex registration is verified and the duplicate project
  override removed; native connection status is distinct from the direct stdio check below.
- That follow-up is published at `1c52de4`; its full macOS CI passed, including lifecycle
  checks: [verification run](https://github.com/jason21wc/apple-calendar-mcp/actions/runs/34782316171).
- Settings Restart twice blanked prompt history and new output according to the human;
  full quit/reopen recovered the UI. Do not prescribe Settings Restart again on this
  installation. Logs show Calendar ready after Settings Restart and before full quit,
  so connection recovery succeeded despite the display failure. Leave the healthy connection
  running; use full quit/reopen only when
  refresh/recovery is needed. `docs/CLIENT-LIFECYCLE.md` records this host-specific limit.

## Validation

- September 20 systemic review: extended synthetic scenarios pass their controls and
  reproduce the cleanup gap described above. Local Swift suite passes with the established
  `ServerLifecycleTests` sandbox exclusion. Independent review of the final diff found no
  blocking correctness or privacy issue; shell syntax, Python parsing and diff checks pass.
  The preceding reproduction checkpoint
  `f591a4b` passed full macOS CI:
  https://github.com/jason21wc/apple-calendar-mcp/actions/runs/35493565346.

- September 20 boundary check and updated Swift suite pass locally, using the established
  `ServerLifecycleTests` desktop sandbox exclusion. Review tightened ID/thread correlation,
  bounded-observation wording, child environment isolation, diagnostics and teardown.
  The journal analysis for checkpoint `ee3befd0e7aa45d6ba70f84ef7429cb1` was consumed:
  accepted the prior CI checkpoint and research lesson; its proposed deferred regression
  is now implemented in this turn. Receipt returned `accepted: false, state_unavailable`;
  memory updates are applied, but hook acknowledgment is not established.

- Documentation checkpoint `fc6f371` passed full macOS CI (build, shell checks, test suite):
  https://github.com/jason21wc/apple-calendar-mcp/actions/runs/35491364654.
  That checkpoint did not establish native cancellation receipt or frontend cleanup.

- September 19 research correction: independent five-file documentation review passed.
  Local `./scripts/test.sh --disable-sandbox --skip ServerLifecycleTests`, shell syntax,
  and whitespace checks passed; the lifecycle exclusion is the established desktop
  sandbox limitation. The separate installed-binary synthetic cancellation check passed
  as described above. No application or server source changed.
  Publication review `gov-6c10f1f78450` (REVIEW, no required modifications) reinforced
  `meta-safety-transparent-limitations`: retain the native-receipt uncertainty explicitly.

- September 19 documentation checkpoint `5c81a39` passed full macOS CI (build, shell checks
  and test suite): https://github.com/jason21wc/apple-calendar-mcp/actions/runs/35484093529.
  This does not establish native refusal delivery or prompt cleanup.

- September 16 Skip investigation changes documentation only. Local suite passes with the
  established `ServerLifecycleTests` sandbox exclusion; shell syntax, diff whitespace and
  public-repository privacy review pass. No executable, host setting or Calendar data changed.

- Latest completed implementation CI passed on `6a4d555`:
  [verification run](https://github.com/jason21wc/apple-calendar-mcp/actions/runs/34920448879).
  That is historical read-surface validation; current candidate checks are recorded above.

- The native-verification documentation push exposed an existing cancellation-test race in
  [CI](https://github.com/jason21wc/apple-calendar-mcp/actions/runs/34920121489): fixed sleep
  returned before timer delivery, so admission was still busy. The test now waits for the
  wedged state with a bounded observation loop while external work remains held. A temporary
  mutation canceling the timer failed the intended assertion; production source was restored.
  This is a test-only correction and needs no binary reinstall or host refresh.

- `./scripts/test.sh` now explicitly selects native SwiftPM and workspace compiler caches.
  This resolves the local Swift 6.4 default engine's missing TestingMacros problem.
- `./scripts/test.sh --disable-sandbox --skip ServerLifecycleTests` passes locally. The full
  local run reaches the tests but its lifecycle cases cannot inspect child processes because
  this desktop execution sandbox denies `pgrep`. They report that limitation explicitly;
  the tests were not weakened or silently skipped. Failed startup now cleans up its process.
- Shell checks and staged privacy/credential checks pass. Independent reviews covered the
  gate, cancellation, journal locking/durability, diagnostics, and documentation.
- The client-neutral follow-up exposed short-deadline flakiness in two ordinary-completion
  gate tests. They now observe actual timer cancellation with bounded failure waits; real
  timeout cases and production code are unchanged. Focused and parallel local suites passed
  after correction, with the same lifecycle sandbox exclusion noted above.
- Full macOS CI passed on the implementation commit before publication to `main`.
  No tests were excluded in that run. The local sandbox limitation remains environment-specific.
- Automated tests use synthetic values and owned temporary storage. Native verification
  on September 14 used a bounded busy-interval read without event details. No permission
  request or journal cleanup was made.
- The lifecycle documentation and signing-guidance correction passed independent review,
  shell syntax checks, and the local test command with the documented lifecycle exclusion.
  Published at `7096f67`; [full CI passed](https://github.com/jason21wc/apple-calendar-mcp/actions/runs/34783951108).

## Next actions, in order

1. **Review the verified follow-up for existing issue #40390; obtain authorization to post.**
   `docs/CODEX-ELICITATION-ISSUE.md` includes the automated reproduction, positive control,
   exact source and remaining evidence limits. Backend cancellation processing is now
   observed in isolation. Do not repeat identical human probes or alter server deadlines.
2. After the cleanup gap is resolved or a relevant host change is verified, retest UI
   cleanup, late-answer isolation and affirmative approval on that version. Submitting a
   report alone is not a reason to repeat a probe. Verify each client before enabling writes.
3. Before any mutating caller, connect acknowledged journal storage and define outcome-error
   reconciliation. Do not retry a future write merely because recording its outcome failed.
   Implement the typed snapshot/field matrix and disposable-calendar round trip before delete.
4. When the approval gate is proved: create → delete **with restore in the same change** →
   update. The attendee/invitation exception is unchanged; other unrestorable fields refuse.
5. For future releases, retain the reviewed build/sign/same-path install procedure and
   verify actual-host behavior after loading the replacement. The `0.2.1` install and
   native read verification are complete; no new Calendar grant was requested.

## Prior installation handoff completed

Installed `0.2.2` matches the signed candidate; the native connection exposes the opt-in
probe after the user's full quit/reopen. Keep the existing Calendar grant and healthy
connection. Backup remains `.build/apple-calendar-mcp-0.2.1.backup`.

## Operational observations and limits

- Last installed version observed is `0.2.3` at `/usr/local/bin/apple-calendar-mcp`;
  strict signature passed on September 15 and the candidate hash was rechecked September 16. Before the update, on 2026-09-13,
  version `0.2.0` passed strict signature verification and ownership was root:wheel.
  `--doctor` from this constrained execution reported `disclaimed-child` + `notDetermined`
  and the old reinstall guidance. That does not establish another host's grant state and is
  not a reason to run `--setup`. The 2026-08-27 `fullAccess` result is historical evidence.
- Host `toolPolicy` was absent in the August inspection. It was not inspected this session;
  do not describe it as configured or claim a current host-wide approval guarantee.
- The live journal contains historical test contamination. Pruning it remains a separate,
  deliberate operation; the new reader reports corruption instead of hiding it.
- Keep the historical deny on the `.build` Calendar grant. **Never grant Calendar access
  to a development binary.** Install only at a root-owned final path; identity and path
  are load-bearing. Do not infer grant ownership from authorization status alone.
- Real populated-calendar concurrency and provider-specific removal/notification semantics
  remain unmeasured. Header evidence is not a live provider measurement.
- Approval policy is decided, approval enforcement is unproven. A capability flag, annotation,
  propose token, or governance assessment is never itself a human approval.
- On September 13 the task exposed no native Apple Calendar tools, and the Codex user config
  had no Calendar registration. A direct stdio call to the installed `0.2.0` binary succeeded
  on 2026-09-13: `calendar_permission_status` returned `disclaimed-child` / `notDetermined`.
  Its `client` flags were false because the test harness declared no capabilities; this is
  not a measurement of Codex's native elicitation support. No event data or setup was requested.
- The agent's September 13 user-level registration attempt failed with `Operation not
  permitted`; a project-level entry temporarily supplied registration. On September 14,
  the human's interactive-terminal command succeeded. The global entry points to the
  installed binary with `--read-only`; its matching project override is now removed.
  Native connection and capability measurement subsequently passed with installed `0.2.1`.
- Native verification attempts on 2026-09-13: installed CLI `0.153.4` still resolves the
  project registration. Its documented app-server API includes MCP reload/status/tool-call
  methods, but `app-server proxy` found no control socket. A temporary backend failed before
  initialization because its state database could not initialize, including with escalation.
  No diagnostic task or native MCP call was created. Computer Use explicitly prohibits
  operating the Codex app, so app-side refresh must be performed by the human. These are
  execution-environment limits, not evidence against Calendar server compatibility or approval.
- On September 14 a standalone Codex handshake fixture with temporary SQLite state also
  failed before initialization with `Operation not permitted`, with and without escalation.
  No client handshake was captured. Published Codex source uses an `extensions` field;
  do not label the experimental-object fixture an exact capture of this desktop's request.
- The journal checkpoint was analyzed and its accepted memory proposals applied. Its receipt
  command returned `accepted: false, reason: state_unavailable`, including with escalation;
  the governance cache has not acknowledged that checkpoint.

## Resuming

Read `PROJECT-MEMORY.md`, `LEARNING-LOG.md`, `OPERATIONS.md`, then canonical
`docs/IMPLEMENTATION-PLAN.md`. Completed #19/#26/#27 work is recorded in project memory;
active work is in `BACKLOG.md`. Governance: `gov-4a43b04d5a39` (implementation) and
`gov-2ade001e7ce0` (verification/publication); `meta-quality-verification-validation` governs
separating local test limitations, CI evidence, and installed-host state.
Client-neutral correction/registration: `gov-a6bea5af4c24`, `gov-905a976a93b6` (PROCEED).
Lifecycle research/correction: `gov-6797056cbe2e` (REVIEW), `gov-23f2ad693912` (PROCEED).
`meta-core-systemic-thinking` and `meta-quality-verification-validation`: fix the host-loading
workflow, retain the server lifecycle, and distinguish implementation evidence from live UI results.
Settings editability correction: `gov-6500cc87631d` (PROCEED); verify control visibility and
enabled preconditions as well as handler behavior (`meta-quality-verification-validation`).
Global registration migration: `gov-1ea4fe07dd03` (REVIEW; retrieved accounting ledger rule
does not apply to this configuration migration). Direct source/configuration verification
and separate native-connection evidence follow `meta-quality-verification-validation`.
SDK compatibility: `gov-2fb6fed27aef` (REVIEW; `coding-quality-modular-service-architecture`:
keep the workaround at the MCP boundary); installation: `gov-93636e49fe31` (PROCEED).

Installation handoff verification: `gov-d857701c5474` (REVIEW); `meta-core-informational-readiness`
and `coding-context-session-state-continuity`: record verified installation separately from pending native connection.

Native read verification and restart correction: `gov-b2d0822f6254` (REVIEW);
`coding-context-session-state-continuity` and `coding-context-context-engineering-discipline`:
replace obsolete refresh advice with measured connection state and the human-reported UI failure.

Cancellation-test correction: `gov-1963a687c0c8` (PROCEED); the existing context pattern
and bounded observation replace scheduler assumptions without changing production behavior.

Cowork/CLI evidence and next-phase design: `gov-63a734e5a214` (REVIEW);
`coding-context-session-state-continuity` and `coding-context-context-engineering-discipline`:
record evidence at its actual strength, preserve working clients, and carry the write gate forward.

Approval-probe implementation: `gov-58493d06fa19` (PROCEED); closeout/sign/publication:
`gov-a07832a0f789` (REVIEW, no required modifications). `meta-core-informational-readiness`
and `coding-process-validation-gates`: distinguish local synthetic verification, full CI,
installed executable and actual human interaction. User authorization covers implementation
and source publication; no approval gate for future calendar writes has been waived.
The phase-start journal audit found no new missing memory; its no-change receipt again
returned `accepted: false, reason: state_unavailable`. Do not retry unchanged.

Post-reopen verification: `gov-9a182972528d` (PROCEED).
`meta-quality-verification-validation`: installation, native protocol outcome, and actual
human UI interaction are separate evidence; the cancellation result does not clear Gate 1.

Journal checkpoint `8a1f43ad7286465d8b4701322220a4eb`: read-only analysis completed;
accepted proposals applied (closeout CI evidence, historical approval-claim corrections,
SDK replacement checklist). Central Reference Library proposal is deferred for user approval.
The main-agent `applied` receipt returned `accepted: false, reason: state_unavailable`.

User UI observation/read check: `gov-6b9a3d0c367f` (PROCEED);
`coding-context-session-state-continuity`: preserve the negative UI observation without
persisting personal calendar content. Observation incorporated in the schema-fix closeout.

Approval schema investigation/correction: `gov-69e34b02900a`, `gov-642d240f6910`,
`gov-0c2e4c2dce52` (PROCEED). `meta-core-informational-readiness` and
`coding-context-session-state-continuity`: preserve the actual consumer rejection and
separate source/schema proof from the pending native human round trip.

Installed-file/native-connection follow-up: `gov-bda9e8c07878` (PROCEED).
Journal checkpoint `c65387a9ea6d4d64965511ad8b2bfc0a` analysis completed; accepted proposals
recorded full-CI evidence and removed stale diagnostic candidate labels. The main-agent
`applied` receipt returned `accepted: false, reason: state_unavailable`; acknowledgement
remains unavailable. The proposed reusable consumer-schema lesson remains local only;
central Reference Library capture requires user approval. That documentation checkpoint is incorporated into the post-restart closeout.

Post-restart measurement: `gov-8062290ad29d` (PROCEED). Preserve the distinction between
client form data, human UI observation and valid affirmative approval. Journal checkpoint
`7598496fca1c44948338d1a49f48ed6c` found no additional gaps; the main-agent `no_change`
receipt returned `accepted: false, reason: state_unavailable`. No central capture was made.

Skip investigation/documentation: `gov-d1a7840d03d6` (REVIEW).
`meta-core-informational-readiness` and `coding-context-context-engineering-discipline`:
record the user's actual controls, distinguish source evidence from runtime inference,
and correct earlier claims of complete timeout cleanup. No server or app configuration changed.

Documentation publication: `gov-4039591994b3` (REVIEW, no required modifications).
`meta-core-single-source-of-truth`: canonical probe evidence owns the investigation;
plan and memory summaries point to it without claiming the host update is available.

Updated-host verification: `gov-d29d206e4859`; documentation checkpoint: `gov-8743b6e2ecdd`
(REVIEW, no required modifications). `coding-process-validation-gates` and
`coding-context-session-state-continuity`: keep source inclusion, native connection health,
and live refusal/cleanup evidence separate. Local suite passes with the established lifecycle
sandbox exclusion; no production code changed. Context index was stale; current files were
read directly for authoritative state. Prior documentation CI passed on `34237de`:
https://github.com/jason21wc/apple-calendar-mcp/actions/runs/35184482219.

Updated-host attended test: `gov-23de0608c39d` (PROCEED); memory/journal closeout:
`gov-01b8c1e97eab` (REVIEW). `coding-context-session-state-continuity`: preserve observed
protocol outcome separately from pending human button observation; no Calendar writes.
Journal checkpoint `1298d79dbc7a48db9890141c648051a5` analysis completed; accepted proposals
record the preceding CI result and the lesson to name the affected application explicitly.
No Reference Library proposal was made.
The main-agent `applied` journal receipt returned `accepted: false, reason: state_unavailable`;
the checkpoint was analyzed and proposals applied, but acknowledgement remains unavailable.

Attended retry: `gov-e29bbd5a7e46`; unanswered test/documentation: `gov-ce39be942a35`
(REVIEW, no required modifications). `meta-core-informational-readiness` and
`meta-quality-verification-validation`: distinguish human observation, response semantics,
actual elapsed delivery and post-test connection health. Previous checkpoint `633ca42`
passed full CI: https://github.com/jason21wc/apple-calendar-mcp/actions/runs/35486423266.

Retained-form observation: `gov-7c328a9b3bff` (REVIEW, no required modifications); retrieved
financial-retention guidance is unrelated and was not applied. Preserve the distinction
between server expiry, visible form retention and control interactivity.
Installed frontend source distinguishes pending forms from completed history: handling
`serverRequest/resolved` removes the pending request and creates `completed: true`,
`action: null` history; its completed renderer shows “Completed request” / “Completed”
without the editable panel. Thus a retained completed card is compatible with cleanup.
That source inspection alone did not establish the observed form's state; the subsequent
human report confirmed that controls remained editable.

Editable-form investigation: `gov-5357021b6488` (PROCEED). The Calendar SDK removes the
pending request before returning timeout and sends standard `notifications/cancelled`.
`MCPRequestLifecycleTests.silenceAndLateResponses` exercises old/duplicate acceptance
against a newer different-ID attempt; that synthetic guarantee does not prove host UI cleanup.
User evidence supersedes the earlier unknown control-state note.

Cleanup-gap report/documentation: `gov-3220758c2378` (REVIEW, no required modifications).
`uiux-interaction-ix4-error-handling-and-recovery`: classify retained editable controls as
a host recovery defect, preserve safe server refusal, and give a concrete upstream repair
target. Issue submission requires explicit user authorization. Previous documentation
checkpoint `0b7bee3` passed full CI: https://github.com/jason21wc/apple-calendar-mcp/actions/runs/35487012696.
