<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Session State

**Last Updated:** 2026-09-14
**Memory Type:** Working (transient)
**Lifecycle:** Current position only; decisions and history live in the other memory files.

## Where things stand

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
- **Installed remains `0.2.1`; no client configuration or Calendar data changed.**
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
- Installed binary is now `0.2.1`; the current native Codex connection answers diagnostics
  and reads. This establishes read access, not approval for future writes.
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

1. **Install the reviewed candidate once.** Source publication and full CI are complete.
   The signed release candidate is ready for validation on the host. The human installs the
   candidate at `/usr/local/bin/apple-calendar-mcp`, retains `--read-only`, adds
   `--enable-approval-probe` to Codex registration, and fully quits/reopens Codex once.
   Agent `sudo` execution was previously refused (`operation not permitted`); use the
   human's interactive terminal. Never request a new Calendar grant or Settings Restart.
2. Use native `calendar_permission_status` to verify the new connection, then run the harmless
   diagnostic with actual human interaction: accept, decline/cancel and non-response.
   Verify later diagnostics/reads still work; record UI dismissal and late-answer isolation.
   Repeat approval verification per client before enabling writes there. Do not reconfigure
   the working Cowork/Claude Code routes merely for a Codex experiment.
3. Before any mutating caller, connect acknowledged journal storage and define outcome-error
   reconciliation. Do not retry a future write merely because recording its outcome failed.
   Implement the typed snapshot/field matrix and disposable-calendar round trip before delete.
4. When the approval gate is proved: create → delete **with restore in the same change** →
   update. The attendee/invitation exception is unchanged; other unrestorable fields refuse.
5. For future releases, retain the reviewed build/sign/same-path install procedure and
   verify actual-host behavior after loading the replacement. The `0.2.1` install and
   native read verification are complete; no new Calendar grant was requested.

## Current install handoff

Run in the human's interactive terminal, then fully quit/reopen Codex once. The first
command needs the Mac's administrator authorization, which the agent shell cannot supply.
The existing `0.2.1` backup is recorded above. Do not run `--setup` or reset Calendar access.

```bash
sudo /usr/bin/install -o root -g wheel -m 755 /Users/jasoncollier/Developer/apple-calendar/.build/release/apple-calendar-mcp /usr/local/bin/apple-calendar-mcp &&
/usr/bin/codesign --verify --strict /usr/local/bin/apple-calendar-mcp &&
codex mcp add apple-calendar -- /usr/local/bin/apple-calendar-mcp --read-only --enable-approval-probe
```

Return to this task for native verification and the harmless human prompt test. Cowork and
Claude Code retain their existing read configuration; the probe flag is deliberate opt-in.

## Operational observations and limits

- Last installed version observed is `0.2.1` at `/usr/local/bin/apple-calendar-mcp`;
  strict signature verification passed on 2026-09-14. Before the update, on 2026-09-13,
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
