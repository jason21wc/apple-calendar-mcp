<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# Session State

**Last Updated:** 2026-09-13
**Memory Type:** Working (transient)
**Lifecycle:** Current position only; decisions and history live in the other memory files.

## Where things stand

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
- Installed binary was **not replaced** during this work. Source improvements are not yet
  an assertion about the executable a connected host is running.
- Client-neutral documentation and backlog now treat Claude Cowork and ChatGPT/Codex Work
  as peer targets. Trusted-project Codex registration is included; native connection status
  is distinct from the successful direct stdio check recorded below.
- That follow-up is published at `1c52de4`; its full macOS CI passed, including lifecycle
  checks: [verification run](https://github.com/jason21wc/apple-calendar-mcp/actions/runs/34782316171).
- The connection lifecycle is documented in `docs/CLIENT-LIFECYCLE.md`: prefer the host's
  supported refresh over quitting the desktop app. Codex's MCP Restart event path was
  inspected in the installed build; its live result in this task remains unverified.

## Validation

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
- No event-data query, permission request, or journal cleanup was made. Tests use synthetic
  values and owned temporary storage. The later project-level client registration is below.
- The lifecycle documentation and signing-guidance correction passed independent review,
  shell syntax checks, and the local test command with the documented lifecycle exclusion.
  Published at `7096f67`; [full CI passed](https://github.com/jason21wc/apple-calendar-mcp/actions/runs/34783951108).

## Next actions, in order

1. **Verify through the current client; do not wait for Cowork.** The human reaffirmed that
   Claude Cowork and ChatGPT/Codex Work are peer targets. Call `calendar_permission_status`
   through the current host's native MCP connection once available. A declaration only
   establishes whether a form-elicitation test is worth trying; it never proves approval.
   A later turn still exposed no native Calendar tools. **Supersedes the quit/reopen advice:**
   follow `docs/CLIENT-LIFECYCLE.md`. The subsequent screenshot and installed source confirm
   that the current project-origin row has disabled controls; Restart only appears after
   a successful settings-page mutation. User-level Calendar registration is still absent.
   Create and verify it with `codex mcp add`, then remove the matching project override.
   Do not promise that a CLI edit reveals Restart. Verify `/mcp` and a real status call. Installed
   source shows a backend-connection restart, not an Electron app relaunch. The human must
   operate that control because Computer Use blocks Codex; a live outcome is still unverified.
2. **BACKLOG #24b:** design the approval request's timeout and abandoned-request cleanup,
   then demonstrate accept, decline, cancellation, absent support, error, and non-response.
   The read gate is NOT an elicitation implementation and must not be reused for it.
   Client-native tool approval remains another unverified candidate (plan §6); no approval
   policy was changed by the new project registration.
3. Before any mutating caller, connect acknowledged journal storage and define outcome-error
   reconciliation. Do not retry a future write merely because recording its outcome failed.
   Implement the typed snapshot/field matrix and disposable-calendar round trip before delete.
4. When the approval gate is proved: create → delete **with restore in the same change** →
   update. The attendee/invitation exception is unchanged; other unrestorable fields refuse.
5. Build/sign/install a reviewed release at the existing final path when activating these
   source changes. Verify the installed artifact and actual-host behavior; no new Calendar
   grant is implied by a same-path replacement signed by the same certificate.

## Operational observations and limits

- Last installed version observed was `0.2.0` at `/usr/local/bin/apple-calendar-mcp`.
  On 2026-09-13 strict signature verification passed and ownership was root:wheel.
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
- Current task exposed no native Apple Calendar tools, and the inspected Codex user config
  had no Calendar registration. A direct stdio call to the installed `0.2.0` binary succeeded
  on 2026-09-13: `calendar_permission_status` returned `disclaimed-child` / `notDetermined`.
  Its `client` flags were false because the test harness declared no capabilities; this is
  not a measurement of Codex's native elicitation support. No event data or setup was requested.
- Adding the user-level Codex registration was attempted but the filesystem rejected config
  persistence with `Operation not permitted`. The supported project-level alternative is now
  saved in `.codex/config.toml`, pointing to the installed binary with `--read-only`.
  `codex mcp get apple-calendar --json` resolves it as enabled with the expected command/args.
  Native connection and capability measurement remain unverified until the host loads it.
- Native verification attempts on 2026-09-13: installed CLI `0.153.4` still resolves the
  project registration. Its documented app-server API includes MCP reload/status/tool-call
  methods, but `app-server proxy` found no control socket. A temporary backend failed before
  initialization because its state database could not initialize, including with escalation.
  No diagnostic task or native MCP call was created. Computer Use explicitly prohibits
  operating the Codex app, so app-side refresh must be performed by the human. These are
  execution-environment limits, not evidence against Calendar server compatibility or approval.
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
