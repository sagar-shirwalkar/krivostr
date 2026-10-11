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
| Search | FTS5 query | `/` or `:search` |
| DM | Inbox + send | `Tab` cycle or `:dm` |
| Relays | Connected + configured + outbox depth | `Tab` cycle or `:relays` |
| Lists | Mute / pin / bookmark tabs | `Tab` cycle or `:lists` |
| Outbox | Queued events, retry/drop | `Tab` cycle or `:outbox` |
| Help | Key table + command list | `Tab` cycle or `:help` |
| Compose | Reply / react / quote / article / DM | `r` `A` `Q` `c` `E` |

Global keys work everywhere:
- `?` — help overlay
- `q` — quit (or pop back from a sub-screen)
- `:` — command bar
- `/` — enter search
- `~` — toggle log pane
- `Esc` — cancel any overlay
- `Tab` — cycle screens (Feed→Relays→Lists→DM→Outbox→Help→Feed)
- `Shift-Tab` — reverse cycle

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
| `f` | Toggle live follow mode |
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
| `:relays` | Show relays view |
| `:lists` | Show mute/pin/bookmark lists view |
| `:outbox` | Show outbox view |
| `:dm` | Show DM view |
| `:help` | Show help view |
| `:search <query>` | Run FTS search |
| `:verify <id> [--pubkey …]` | Async NIP-05 check |
| `:publish <file.md>` | Article flow (prompts title/slug) |
| `:resolve <ref>` | Open thread/author for `nostr:`/bech32/hex |
| `:export [--format …] [--out …]` | Export current filter |
| `:wallet …` | NIP-47 via `KRIVOSTR_NWC` |
| `:reindex` | Rebuild FTS5 index |
| `:keygen` | Generate keypair (reveals `nsec` on `v`) |
| `:count` | Exact NIP-45 count for current filter |
| `:bell on/off` | Terminal bell on matching events |
| `:exec <cmd>` | Run shell command on match (substitution) |
| `:limit N` | Cap feed display (default 500) |
| `:ingest on/off` | Toggle live follow ingest |

## Security notes

- **Muting**: Muted authors are filtered from the feed at ingest time and retroactively when a mute event is processed (same as CLI `feed` and web UI).
- **NIP-36 content warnings**: Sensitive content (NIP-36 `content-warning` tag) renders as `[hidden — content-warning]` until `v` is pressed; reveals are session-only, never persisted.
- **Log pane** (`~`): Captures all publish verdicts, async results, and yanks — nothing is printed to stderr (would shred the screen).
- **Read-only mode**: Without `KRIVOSTR_NSEC` the TUI is read-only (same as CLI).

## Coexistence with `serve`

The TUI and `serve` can run concurrently on the same database:
- SQLite WAL mode with `PRAGMA busy_timeout = 5000` prevents lock contention
- Both processes deduplicate via `insertEvent` (id PK, verify choke point) — double ingest is harmless
- Follow-mode ingest in the TUI is ON by default (`:ingest off` to disable)
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
| `:wallet`, `:publish`, `:export` | ⬜ M3 |
| Mention links (`n` key) | ✅ (lists mentions, resolution via `:resolve`) |
| Unread counter | ✅ |
| Theme attrs (kind colours) | ✅ |
| NIP-36 content warning | ✅ |
| Muting filter | ✅ |

## Known limitations

- DM/Relays/Outbox views are M3 stubs (show placeholder text)
- Mention resolution via `Enter` on a mention not yet wired (use `:resolve` for now)
- Article composer (`:publish`) not yet implemented
- NIP-17 DMs not yet wired (CLI `dm` uses NIP-04)

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