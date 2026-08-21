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
> **The safeguards do not defend against a compromised machine — and the consequence is
> worse than "they bypass the server".** The journal and its snapshots are
> ordinary files owned by your user account. Anything running as you — including the coding
> agent this server talks to — can edit or delete them without going through this server.
>
> More seriously, anything running as you can **become** this server. Setup installs a
> code-signing certificate that signs without a password prompt, and macOS checks the
> calendar grant against *identity plus path*, both of which are attacker-supplied. A
> same-uid process can therefore compile its own binary, sign it silently with your
> certificate, write it to the granted path, and hold Calendar access under this tool's
> name — with no prompt, no journal entry, and nothing unusual in System Settings.
>
> **Install the binary somewhere only root can write** (`/usr/local/bin` is root-owned on
> Apple Silicon; on Intel Macs with Homebrew it is often user-owned, which removes this
> protection entirely — check with `ls -ld`). Never grant access to a binary inside
> `.build`, which every `swift build` rewrites.
>
> Same-uid containment is not achievable without a privilege boundary this project does not
> have.

## Status

**Read-only and usable.** Five read tools work against your real calendar from Claude Code,
Codex and Claude Desktop: permission status, list calendars, list events, search events, and
busy intervals. 95 tests pass.

**No write tools exist yet.** Create, update and delete are designed but unbuilt — see
`docs/IMPLEMENTATION-PLAN.md` §6. Nothing this server currently exposes can change your
calendar.

## How it protects you

These apply to the write tools, which are **not built yet**. They are listed so the design is
public before the capability is.

| Control | What it does |
|---|---|
| Host approval on every write | Write tools are configured `"ask"` in your MCP client, which prompts per call and offers no "always allow". This is the only control here that the AI model cannot reach — it is enforced in the client, not in this server |
| Attendee refusal | Events with other people on them cannot be modified at all — deleting one sends a decline or cancellation to real people, and nothing can take that back. The refusal returns the date, time and calendar so you can find and decline it yourself |
| Restorable by construction | Every change is snapshotted first, and anything this server can delete it can put back. **Restore recreates an equivalent event with the same information — it is not the original object, and its identifier will differ.** That is sufficient precisely because the one field a snapshot cannot reproduce is the attendee list, and events with attendees are refused outright |
| Mutation journal | Every change is recorded with a full pre-state snapshot, and a restore is recorded as a new entry referencing the original rather than erasing it |
| No bulk operations | One event per call |

**Writable means whatever macOS says is writable**, including calendars shared with you. If
you can write to it in Calendar.app, this server can too.

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
./scripts/sign.sh                                        # sign FIRST, while you still own the file
sudo cp .build/release/apple-calendar-mcp /usr/local/bin/ # cp preserves the signature
/usr/local/bin/apple-calendar-mcp --setup                 # grant at the final path
```

Sign before copying, not after. `cp` carries the embedded signature across, and once the
binary is owned by root, `codesign` cannot rewrite it in place — it fails with `internal
error in Code Signing subsystem`, which does not hint at permissions. Confirm the installed
copy with `codesign --verify --strict /usr/local/bin/apple-calendar-mcp`.

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
