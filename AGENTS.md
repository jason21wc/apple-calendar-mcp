<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# apple-calendar-mcp

**Description:** Local stdio MCP server giving Claude Code and Codex read+write access to the macOS user's Apple Calendar via native EventKit. Swift, personal use, Apache-2.0, intended for public release.
**Framework:** AI Coding Methods (current version)
**Mode:** Standard

> **Start here.** Phases 1-3 are built, tested and published; **Phase 4 (read surface) is
> next**. Read `_ai-context/PROJECT-MEMORY.md` (containment controls C1-C6, 43 gotchas — most
> of them measured platform behaviour that will cost you hours if rediscovered), then
> `docs/IMPLEMENTATION-PLAN.md` (rev. 5).
>
> Two things to know before touching anything: the Calendar grant is keyed to the binary's
> **absolute path**, and the server only owns that grant because it re-spawns itself with a
> disclaim attribute at startup. Run `./scripts/test.sh`, not `swift test`.

## Memory Files

Project memory lives in `_ai-context/` and is committed to git (shared memory,
not scratch — nothing auto-discovers these files; this loader is the pointer):
- `_ai-context/SESSION-STATE.md` — current position, quick reference, next actions
- `_ai-context/PROJECT-MEMORY.md` — decisions, constraints, gotchas
- `_ai-context/LEARNING-LOG.md` — active lessons
- `_ai-context/BACKLOG.md` — deferred work that finishes (standard kit and above)
- `_ai-context/OPERATIONS.md` — recurring commitments that never finish: cadences, tripwires, standing authorizations, metrics (standard kit and above)

The host tool's own built-in memory is separate — leave it to the host.

## Session Start

1. Read `_ai-context/SESSION-STATE.md` — current position, next actions
2. Read `_ai-context/PROJECT-MEMORY.md` — decisions, constraints, gotchas
3. Read `_ai-context/LEARNING-LOG.md` — active lessons
4. Run existing tests (if applicable) — establish known-good baseline

## Governance

Guidance for any host with the ai-governance MCP server connected (the
*enforcement* mechanism, where one exists, lives in the platform overlay such as
CLAUDE.md — not here):
- `evaluate_governance(planned_action="...")` — before any non-read action
- `query_project(query="...")` — before creating or modifying code/content
- `search_references(query="...")` — before implementing a pattern, to reuse proven precedent from the shared Reference Library
- `capture_reference(...)` — after solving a non-obvious, reusable problem, to bank the lesson in the shared, central Reference Library

## Key Commands

- [Add project commands here — build, test, lint, run]

## Project Structure

[Document key directories and files as the project grows]
