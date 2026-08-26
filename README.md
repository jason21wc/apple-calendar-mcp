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
> **Undo will not be undo — and today there is no undo at all.** No write tool exists yet, so
> nothing here deletes anything; but read this before that changes. When the write surface
> ships, a deleted event will be recreated from a local journal, and the recreated event is a
> *new* event: the original identifier does not come back, and invitation state — organizer,
> attendees, RSVP responses — cannot be restored, because EventKit exposes `attendees` as
> read-only. The journal exists in the codebase already; **the restore path that would use it
> does not**, and until it does, nothing reverses anything.
>
> **AI assistants can be manipulated by calendar content.** Meeting invitations arrive from
> other people and their titles, notes and locations are attacker-controlled text that
> lands in the model's context. The safeguards below reduce the blast radius of a mistaken
> or manipulated model and make each change reviewable. **They do not prevent it.**
>
> **The safeguards do not defend against a compromised machine — and the consequence is
> worse than "they bypass the server".** The journal and its snapshots are ordinary files
> owned by your user account. Anything running as you — including the coding agent this
> server talks to — can truncate or delete them without going through this server.
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
busy intervals.

**No write tools exist yet.** Create, update and delete are designed but unbuilt — see
`docs/IMPLEMENTATION-PLAN.md` §6. Nothing this server currently exposes can change your
calendar.

Run `./scripts/test.sh` to see the test suite pass. (A count is not quoted here: it was
quoted in four documents, drifted to four different numbers, and running the suite is the
only way to know it anyway.)

## How it protects you

These apply to the write tools, which are **not built yet**. They are listed so the design is
public before the capability is.

| Control | What it does |
|---|---|
| Human approval on every write | **Mechanism not yet settled — see below.** The intent is that every write requires per-call human confirmation, which would be the only control here the AI model cannot reach. Two candidates are being measured; neither is in place, and no write tool exists yet |
| Events with other people on them | Removing one requires your explicit confirmation, and the prompt says what is actually true: that the event will be removed through EventKit, that this **may notify the other participants**, and that the attendee list **cannot be put back**. macOS gives this server no way to suppress such a notification, and no way to send a proper RSVP either — so it calls the operation *remove*, and does not pretend it is the same as clicking Decline in Calendar.app |
| Restorable by construction, with one exception | Every change is snapshotted first, and anything this server deletes it can put back — **except the attendee list**, which EventKit exposes as read-only and which nothing can reconstruct. **Restore recreates an equivalent event with the same information; it is not the original object, and its identifier will differ.** If you remove a meeting with other people on it, getting back on it means asking to be re-invited |
| Mutation journal | Every change is recorded with a full pre-state snapshot, and a restore is recorded as a new entry referencing the original rather than erasing it |
| No bulk operations | One event per call |

**Writable means whatever macOS says is writable**, including calendars shared with you. If
you can write to it in Calendar.app, this server can too.

## Compatibility

**0.2.0 changes what already-shipped read tools return.** Same events, same instants — but if
you built anything against 0.1.0 output, read this:

| Change | Effect |
|---|---|
| `time_zone` now renders **every** timestamp, not only all-day dates | Same instants, different offsets. Parse RFC 3339; do not compare timestamp strings |
| `occurrence_date` is now **always UTC**, regardless of `time_zone` | It is a key, not a display value, so it no longer shifts with a display preference |
| `limits_applied` reshaped | `limit` is the effective per-call cap and may be `null`; `max_interval_days` may be `null`; new `max_result_limit` |
| New required field `unmatched_calendar_ids` | Calendar ids that matched nothing. Non-empty means those calendars were **not** searched — an empty result may mean "your ids are stale", not "you are free" |
| Errors now lead with a stable code | `INTERVAL_TOO_LARGE: interval is 45 days…`. The code is contractual; the prose is not |
| A search now covers the whole window | `total_matched` counts every match. Previously it counted matches among the first 500 events by start order, so a real match could be reported as none |
| The interval cap counts seconds | A 31.9-day window used to pass a 31-day limit |

## Requirements

macOS 14+, Swift 6, and Apple Command Line Tools. Node.js only if you want to run the MCP
Inspector against it.

## Installing

```bash
git clone https://github.com/jason21wc/apple-calendar-mcp.git
cd apple-calendar-mcp
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

**Claude Desktop** — in `claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "apple-calendar": {
      "command": "/usr/local/bin/apple-calendar-mcp",
      "args": ["--read-only"]
    }
  }
}
```

### Two things you configure, not this server

**`--read-only`** withholds every mutating tool, so they never appear in `tools/list` and
injected calendar text has nothing to name. It ships now, before any write tool exists, so a
client configured today keeps the restriction instead of silently gaining write access later.
It is a real reduction against a mistaken or manipulated model — and it is **not** a boundary:
it comes from argv, and argv comes from config files anything running as you can edit.

**Per-call approval** would be the one control the model cannot reach, because the client
enforces it rather than this server. In Claude Desktop that is `toolPolicy` on the server
entry, where `"ask"` is documented to prompt on every call with no permanent "always allow".

**It is unverified, and stated here as unverified deliberately.** It has not been demonstrated
working on any machine this project has tested, and a measurement previously recorded as
evidence for it turned out to have been taken with the key not set at all. No write tool exists
yet, so nothing depends on it today — but if you are reading this to decide whether writes will
be gated when they arrive, the honest answer is that the mechanism has not been settled. Follow
`docs/IMPLEMENTATION-PLAN.md` §6 rather than assuming this paragraph.

Neither `--read-only` nor per-call approval is configured for you, and this server cannot check
whether you did it. If you want a host that is genuinely write-incapable, install a second copy
built without write support at its own path — the Calendar grant is path-keyed, so it needs its
own `--setup`.

## Not in scope

No network listener, telemetry, analytics, or auto-update. No CalDAV, no iCloud
credentials. Reminders are not supported. "Local MCP" means the *server* runs locally — the
AI assistant you connect still receives whatever calendar fields it asks for.

## License

Apache-2.0. See [LICENSE](LICENSE).
