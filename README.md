# apple-calendar-mcp

A local [MCP](https://modelcontextprotocol.io) server that lets Claude Code and Codex work
with your macOS Calendar through native EventKit. Swift, no network, no cloud, no
credentials.

> ## ⚠️ This software can permanently delete calendar events
>
> Read this before installing.
>
> **macOS has no read-only calendar permission.** `requestFullAccessToEvents` is the only
> authorization that permits *reading* events, and it grants read **and write**. There is
> no OS-level setting that makes this tool read-only. Every safety property here is a
> property of the implementation, and nothing else.
>
> **Undo is not undo.** Deleted events can be recreated from a local journal, but the
> recreated event is a *new* event. The original identifier does not come back, and
> invitation state — organizer, attendees, RSVP responses — cannot be restored, because
> EventKit exposes `attendees` as read-only.
>
> **AI assistants can be manipulated by calendar content.** Meeting invitations arrive from
> other people and their titles, notes and locations are attacker-controlled text that
> lands in the model's context. The safeguards below reduce the blast radius of a mistaken
> or manipulated model and make each change reviewable. **They do not prevent it.**
>
> **The safeguards do not defend against a compromised machine.** The allowlist, the
> journal and its snapshots are ordinary files owned by your user account. Anything running
> as you — including the coding agent this server talks to — can edit or delete them
> without going through this server at all. Same-uid containment is not achievable without
> a privilege boundary this project does not have.

## Status

**Early development.** Phase 1 of 7 complete. There is no working MCP server yet — the
current binary is a permission probe. Do not install this expecting a usable tool.

## How it protects you

| Control | What it does |
|---|---|
| Writable-calendar allowlist | Writes only reach calendars you name in config, read once at startup |
| Propose then commit | Every change is previewed and returns a token; a separate call applies it |
| Verified summary | The confirming call must echo a server-generated sentence describing the change, so your approval prompt shows what will happen instead of an opaque id |
| Attendee refusal | Events with other people on them cannot be modified at all — deleting one sends a decline or cancellation to real people, and nothing can take that back |
| Mutation journal | Every change is recorded with a full pre-state snapshot |
| No bulk operations | One event per call |

## Requirements

macOS 14+, Swift 6, and Apple Command Line Tools. Node.js only if you want to run the MCP
Inspector against it.

## Installing

```bash
git clone <this repo> && cd apple-calendar
swift build -c release

./scripts/make-signing-cert.sh     # once per machine
./scripts/trust-signing-cert.sh    # once per machine, interactive, needs your password
```

**Install the binary where it will live permanently, then grant permission there.** macOS
keys the calendar grant to the binary's *absolute path* — granting from `.build` and then
moving the binary silently loses access.

```bash
sudo cp .build/release/apple-calendar-mcp /usr/local/bin/
./scripts/sign.sh /usr/local/bin/apple-calendar-mcp
/usr/local/bin/apple-calendar-mcp --grant
```

### Why the signing dance

A bare executable spawned by another program does **not** get its own macOS privacy
identity — the permission is attributed to whatever launched it, so the grant lands on your
terminal rather than on this tool. Bundling it as an `.app` does not fix that either.

This server therefore re-spawns itself once at startup with the spawn attribute that
disclaims parental responsibility, which gives it a genuine identity of its own. That in
turn requires a stable code-signing certificate: with ad-hoc signing macOS ties the grant to
the exact binary contents and you would lose calendar access on every rebuild.

## Connecting it

Use the same absolute path you granted permission to.

**Claude Code**
```bash
claude mcp add --transport stdio apple-calendar -- /usr/local/bin/apple-calendar-mcp
```

**Codex** — in `~/.codex/config.toml`:
```toml
[mcp_servers.apple-calendar]
command = "/usr/local/bin/apple-calendar-mcp"
args = []
```

## Not in scope

No network listener, telemetry, analytics, or auto-update. No CalDAV, no iCloud
credentials. Reminders are not supported. "Local MCP" means the *server* runs locally — the
AI assistant you connect still receives whatever calendar fields it asks for.

## License

Apache-2.0. See [LICENSE](LICENSE).
