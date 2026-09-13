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

## Validation

- `./scripts/test.sh` now explicitly selects native SwiftPM and workspace compiler caches.
  This resolves the local Swift 6.4 default engine's missing TestingMacros problem.
- `./scripts/test.sh --disable-sandbox --skip ServerLifecycleTests` passes locally. The full
  local run reaches the tests but its lifecycle cases cannot inspect child processes because
  this desktop execution sandbox denies `pgrep`. They report that limitation explicitly;
  the tests were not weakened or silently skipped. Failed startup now cleans up its process.
- Shell checks and staged privacy/credential checks pass. Independent reviews covered the
  gate, cancellation, journal locking/durability, diagnostics, and documentation.
- Full macOS CI passed on the implementation commit before publication to `main`.
  No tests were excluded in that run. The local sandbox limitation remains environment-specific.
- No live Calendar query, permission request, journal cleanup, or host-config edit was made.
  Tests use synthetic values and owned temporary storage.

## Next actions, in order

1. **Verify the actual Cowork client.** Reconnect and read `calendar_permission_status`, then
   report `client.elicitation_form_supported`. Requested from the human in this task; not yet
   received. A declaration only establishes whether a form-elicitation test is worth trying.
2. **BACKLOG #24b:** design the approval request's timeout and abandoned-request cleanup,
   then demonstrate accept, decline, cancellation, absent support, error, and non-response.
   The read gate is NOT an elicitation implementation and must not be reused for it.
   `toolPolicy` (#23) remains the other unverified candidate; no configuration was changed.
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
  and the old reinstall guidance. That does not establish the grant state in Cowork and is
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

## Resuming

Read `PROJECT-MEMORY.md`, `LEARNING-LOG.md`, `OPERATIONS.md`, then canonical
`docs/IMPLEMENTATION-PLAN.md`. Completed #19/#26/#27 work is recorded in project memory;
active work is in `BACKLOG.md`. Governance: `gov-4a43b04d5a39` (implementation) and
`gov-2ade001e7ce0` (verification/publication); `meta-quality-verification-validation` governs
separating local test limitations, CI evidence, and installed-host state.
