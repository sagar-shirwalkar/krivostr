# krivostr TUI

The `tui` subcommand provides an interactive terminal interface over the local SQLite store and relay pool. It shares the store with `serve` and the CLI (WAL mode with `busy_timeout = 5000` allows concurrent access).

## Quick start

```bash
# Start the TUI (uses KRIVOSTR_DB, KRIVOSTR_NSEC, relay config)
krivostr tui

# Override upstream relays
krivostr tui --relay wss://nos.lol

# Disable live follow ingest
krivostr tui --no-ingest

# Disable ANSI colours
krivostr tui --no-color
```

## Screens and global keys

| Screen | Purpose | Enter via |
|--------|---------|-----------|
| Feed | Timeline, newest first | default |
| Thread | Note + replies | `Enter` on a note |
| Search | FTS5 query | `/` |
| DM | Inbox + send | `Tab` cycle or `:dm` |
| Relays | Connected + configured + outbox depth | `Tab` cycle or `:relays` |
| Lists | Mute / pin / bookmark tabs | `Tab` cycle or `:lists` |
| Outbox | Queued events, retry/drop | `Tab` cycle or `:outbox` |
| Help | Key table + command list | `Tab` cycle or `:help` |
| Compose | Reply / react / quote / comment | `r` `A` `Q` `c` |

Global keys work on Feed and Thread screens:
- `?` — help screen
- `q` — quit
- `:` — command bar
- `/` — enter search
- `~` — toggle log pane
- `Esc` — cancel overlay / pop screen
- `Tab` — cycle screens (Feed→Relays→Lists→DM→Outbox→Help→Feed)
- `Shift-Tab` — reverse cycle

> **Note:** In Search screen, `stepSearchKey` owns every key — global keys (Tab, ?, f, q, ~, /, Esc) are inert there.

## Feed keys (Feed, Search, Thread screens)

| Key | Action |
|-----|--------|
| `j` / `k` | Move selection down / up |
| `g` / `G` | Jump to top / bottom |
| `Enter` | Open thread for focused note |
| `r` | Reply compose (NIP-10) |
| `A` | React compose, prefilled with `+` (NIP-25) |
| `Q` | Quote compose (NIP-18) |
| `c` | Comment compose (kind 1111; refuses kind 1) |
| `v` | Reveal sensitive content (session only, NIP-36) |
| `y` | Yank full event id to log pane |
| `a` | Immediate like (`+` reaction) |
| `R` | Immediate repost |
| `d` | Immediate delete (own events only) |
| `m` | Immediate mute author (publishes kind 10000) |
| `f` | Toggle live follow mode (cosmetic — see Known limitations) |
| `n` | List mentions in focused thread event |
| `1`–`3` | Switch Lists tab (mute / pin / bookmark) when on Lists screen |

## Compose keys (multiline editor)

| Key | Action |
|-----|--------|
| `Ctrl-G` | Sign and send |
| `Esc` | Cancel, return to previous screen |
| `E` | Promote to `$EDITOR` (only on empty editor) |

## Command bar (opened with `:`)

| Command | Effect |
|---------|--------|
| `:q` / `:quit` | Leave the TUI |
| `:search <query>` | Open the search view on `<query>` |
| `:count [kind]` | Log the number of stored events, optionally for one kind |
| `:limit N` | Set the feed query limit and reload (default 500) |
| `:resolve <ref>` | Resolve `npub`/`note`/`naddr`/hex/`nostr:` refs, logging the result |
| `:verify <name> [pubkey]` | Fetch a NIP-05 document and check the optional key |
| `:publish <file> [title]` | Publish a NIP-23 article from a file (needs `KRIVOSTR_NSEC`) |
| `:ingest [on\|off]` | Start/stop live follow ingest (no argument toggles) |
| `:relays` | Show relays view |
| `:lists` | Show mute/pin/bookmark lists view |
| `:outbox` | Show outbox view |
| `:dm` | Show DM view |
| `:help` | Show help view |

The parser is total: an unrecognized line is logged as `unknown command`,
never a crash. The wider parity set is **not implemented yet** — each logs
`unknown command`:
- `:export [--format …] [--out …]` — Export current filter
- `:wallet …` — NIP-47 via `KRIVOSTR_NWC`
- `:reindex` — Rebuild FTS5 index
- `:keygen` — Generate keypair (reveals `nsec` on `v`)
- `:bell on/off` — Terminal bell on matching events
- `:exec <cmd>` — Run shell command on match (substitution)

Use the CLI subcommand of the same name until these land.

## Security notes

- **Muting**: Muted authors are filtered from the feed at ingest time and retroactively when a mute event is processed (same as CLI `feed` and web UI).
- **NIP-36 content warnings**: Sensitive content (NIP-36 `content-warning` tag) renders as `[hidden — content-warning]` until `v` is pressed; reveals are session-only, never persisted.
- **Log pane** (`~`): Captures all publish verdicts, async results, and yanks — nothing is printed to stderr (would shred the screen).
- **Read-only mode**: Without `KRIVOSTR_NSEC` the TUI is read-only (same as CLI).

## Coexistence with `serve`

The TUI and `serve` can run concurrently on the same database:
- SQLite WAL mode with `PRAGMA busy_timeout = 5000` prevents lock contention
- Both processes deduplicate via `insertEvent` (id PK, verify choke point) — double ingest is harmless
- Follow-mode ingest in the TUI is ON by default; start with `--no-ingest` to disable it, or toggle it at run time with `:ingest off` / `:ingest on`.
- The bridge serves the UI on `:8081`; the TUI uses the same store directly

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `KRIVOSTR_DB` | `.krivostr/events.db` | SQLite path (relative to shell's directory) |
| `KRIVOSTR_NSEC` | — | Secret key for `dm` and every send command |
| `KRIVOSTR_NWC` | — | Wallet connection URI for `wallet` (NIP-47) |
| `KRIVOSTR_LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |
| `EDITOR` | — | External editor for `E` key in compose |

## Current status (M4)

| Feature | Status |
|---------|--------|
| Feed, Thread, Search | ✅ |
| Compose (reply/react/quote/comment) | ✅ |
| Immediate sends (a/R/d/m) | ✅ |
| Lists (mute/pin/bookmark) | ✅ |
| DM view | ⬜ M3 stub |
| Relays view | ⬜ M3 stub |
| Outbox view | ⬜ M3 stub |
| Help view | ✅ |
| `:search`, `:count`, `:limit`, `:resolve`, `:verify`, `:publish`, `:ingest` | ✅ |
| `:wallet`, `:export`, `:reindex`, `:keygen`, `:bell`, `:exec` | ⬜ M3 |
| Mention links (`n` key) | ✅ (lists mentions; event mentions open their thread) |
| Unread counter | ✅ (shows on all screens) |
| Theme attrs (kind colours) | ✅ |
| NIP-36 content warning | ✅ |
| Muting filter | ✅ |

## Known limitations

- DM/Relays/Outbox views are placeholders (they render `// … arrives in M3`).
- `f` toggles an `asFollowing` flag that only feeds the status bar; it does not pause the live ingest subscription. Use `:ingest off` to actually stop ingest; the `f` toggle stays cosmetic until it is wired to the same seam.
- Mention resolution: `n` lists mentions; `RTEvent` mentions open the referenced event's thread. `RTAuthor` and `RTAddress` mentions have no view yet, so they are logged (`author <hex>`, `address <coord> (open with :resolve)`) rather than silently dropped.
- Article composer and DM compose are not implemented (compose targets are reply / react / quote / comment).
- NIP-17 DMs are not wired (CLI `dm` uses NIP-04).
- The unimplemented `:` commands (`:export`, `:wallet`, `:reindex`, `:keygen`, `:bell`, `:exec`) each log `unknown command` (see the command bar above).

## Debugging

```bash
# Run with debug logging
KRIVOSTR_LOG_LEVEL=debug krivostr tui

# Run against a specific database
KRIVOSTR_DB=/path/to/events.db krivostr tui
```

## Development

```bash
# Run TUI tests
stack test --test-arguments '--match "TUI"'

# Run all tests
make test
```