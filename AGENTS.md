<!-- scaffold: code/standard template-v2.65.0 2026-08-17 -->
# apple-calendar-mcp

**Description:** Local stdio MCP server giving Claude Code, Codex and Claude Desktop access to the macOS user's Apple Calendar via native EventKit. **Read access is shipped; write access is designed, governed and not built.** Swift, personal use, Apache-2.0, published.
**Framework:** AI Coding Methods (current version)
**Mode:** Standard

> **Start here.** Phases 1-4 are built, tested, published and in daily use. **Five read-only
> tools are shipped and no write tool exists.** The Phase 5 journal substrate is built but has
> no caller. The next code is `BACKLOG` #19 — bound EventKit calls and fail fast once the
> store wedges — and **all write work is blocked** on confirming that a write tool prompts in
> Claude Desktop.
>
> Read `_ai-context/PROJECT-MEMORY.md` (containment controls C3-C7, and the gotcha table —
> mostly measured platform behaviour that will cost you hours if rediscovered), then
> `docs/IMPLEMENTATION-PLAN.md`, which is the canonical plan and lives in this repo.
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

| Command | What it does |
|---|---|
| `swift build` | Debug build. Run from the package root — the embedded Info.plist is added via `-sectcreate` with a path relative to the invoker's cwd |
| `swift build -c release` | Release build, the one that gets signed and installed |
| `./scripts/test.sh` | **The** test command. Never plain `swift test`: Command Line Tools ship `Testing.framework` but no XCTest, and the module and dyld paths have to be derived from `xcode-select -p`. Takes `swift test` flags, e.g. `--filter ReadContractTests` |
| `./scripts/test-shell.sh` | Shell-script checks, standalone. Also driven by the Swift suite |
| `bash -n scripts/*.sh` | Parse check, what CI runs |
| `./scripts/make-signing-cert.sh` | Once per machine. Creates the stable self-signed certificate the TCC grant's designated requirement names |
| `./scripts/trust-signing-cert.sh` | Once per machine, **interactive**, needs the login password. Puts `codesign` on the key's partition list so signing needs no dialog |
| `./scripts/sign.sh` | Signs the release binary with hardened runtime and the calendars entitlement, and asserts both afterwards |
| `<binary> --setup` | Requests Calendar access. Must run at the **final installed path** — the grant is path-keyed |
| `<binary> --doctor` | Reports authorization, identity (`disclaimed-child` is the only good value) and install state |
| `<binary>` *(no arguments)* | Serves MCP over stdio. There is **no** `serve` subcommand; passing one exits `EX_USAGE` |

Never run the binary's `--setup`, `--probe` or a real calendar query from a test: `--setup`
raises a real TCC prompt, and `--probe` writes into the user's real `~/.local/state`.

## Project Structure

```
Sources/apple-calendar-mcp/
  main.swift          entry point: SIGPIPE ignore -> startup flags -> privacy identity
                      -> command dispatch. Top-level code, so nothing here is testable
  Runtime.swift       process-wide facts: disclaim mode, state directory, --read-only
  Reexec.swift        the self-disclaiming re-exec. Load-bearing: without it the Calendar
                      grant belongs to whatever launched the binary
  CLI.swift           Command enum, help, version, Meta (identity from the embedded plist)
  MCP/                ServerBootstrap (server loop; stdin EOF is unconditional shutdown),
                      ToolRegistry (names, schemas, annotations), ToolHandlers (dispatch,
                      argument handling, ToolError codes)
  Calendar/           Models (DTOs), Limits, TimeSemantics, CalendarScope, EventSearch,
                      Journal (Phase 5 substrate, no caller yet)
  EventKit/           CalendarStore (the ONLY file that touches calendar content),
                      AuthorizationState (five states, not six)
  Diagnostics/        Doctor, SetupFlow, TCCInspector
Tests/AppleCalendarMCPTests/    swift-testing; TestSupport.swift locates the repo and binary
scripts/                        build, sign, trust and test scripts
docs/IMPLEMENTATION-PLAN.md     the canonical plan
_ai-context/                    project memory (see above)
```

The conceptual layers are `MCPLayer → CalendarKit → EventKitAdapter`; the directory names
above do **not** mirror them, and the on-disk layout wins.
