# <p align="center">krivostr</p>

<p align="center"><strong>The local-first Nostr engine.</strong></p>

<div align="center">

[![Haskell](https://img.shields.io/badge/Haskell-5D4F85?style=for-the-badge&logo=haskell&logoColor=white)](https://haskell.org)
[![Lit](https://img.shields.io/badge/lit-324FFF?style=for-the-badge&logo=lit&logoColor=white)](https://lit.dev)
[![License](https://img.shields.io/badge/AGPL--3.0-red?style=for-the-badge)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/sagar-shirwalkar/krivostr?display_name=release&style=for-the-badge&labelColor=black&color=%23fbb22b)](https://github.com/sagar-shirwalkar/krivostr/actions/workflows/release.yml)
[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/sagar-shirwalkar/krivostr/ci.yml?branch=main&style=for-the-badge&labelColor=%23404040&color=%232d9e37)](https://github.com/sagar-shirwalkar/krivostr/actions/workflows/ci.yml)

</div>

<div align="center">

<img width="2900" height="3328" alt="krivostr-ui-landing" src="https://github.com/user-attachments/assets/2757af11-6abc-41bb-9e46-b9916a375b50" />

</div>

<br>

<p align="center">See the client in action at https://krivostr-ui.pages.dev/</p>

With krivostr, everything you read lands in a SQLite file you own, indexed for full-text search, and
reachable from the command line. Relays forget; your store does not. The name is a
portmanteau of **Nostr** and **Krivine**, the call-by-name abstract machine that evaluates
lambda terms through a stack of closures.

- **An offline-capable archive** — events in SQLite with a 30-day retention
  window, indexed on `pubkey`, `created_at`, and `kind`, plus an FTS5 index for search.
  Read your timeline on a flight; your follows, mutes, and DMs persist.
- **A multiplexing bridge** — the browser speaks ordinary Nostr to `krivostr
  serve`, which answers from the local store and fans out to upstream relays.
- **A headless CLI & TUI** — twenty-two subcommands over the same store: `serve`, `feed`,
  `search`, `dm`, `reply`, `react`, `repost`, `verify`, `publish`, `delete`, `resolve`,
  `comment`, `list`, `count`, `wallet`, `relay`, `export`, `watch`, `api`, `reindex`,
  `keygen`, `tui`. SQLite and FTS5 are linked in; no runtime to install.
- **Signers at the boundary** — NIP-07 browser extension or NIP-46 remote bunker for
  real identities (the picker nudges you there); pasted local `nsec` is gated behind
  an explicit risk acknowledgment and meant for testing and burner keys.
- **A pure core** — canonical serialization, signing, verification, and filter matching
  are pure Haskell with no IO in `krivostr-core`; SQLite, WebSockets, and HTTP live in
  `krivostr-client`.

---

## Contents

- [Quick start](#quick-start)
- [Installation](#installation)
- [Commands](#commands)
- [Configuration](#configuration)
- [Architecture](#architecture)
- [Protocol support](#protocol-support)
- [Testing and coverage](#testing-and-coverage)
- [Development](#development)
- [Design decisions](#design-decisions)
- [Known limitations](#known-limitations)
- [Roadmap](#roadmap)
- [License](#license)

---

## Quick start

### Download and run (no build)

Each [release](https://github.com/sagar-shirwalkar/krivostr/releases) ships the
binary **and** the built UI in one tarball — no clone, no toolchain, no Cloudflare
account. Extract and run; the archive mirrors the repo layout (`ui/dist`), so
`serve` finds the UI with zero flags:

```bash
mkdir krivostr && tar -xzf krivostr-0.7.4-linux-amd64.tar.gz -C krivostr
cd krivostr
./krivostr serve
```

Open <http://localhost:8081>. The bridge serves the UI, keeps your SQLite vault
(`.krivostr/events.db`), and works fully offline once relays have fed it.

Every release archive ships SLSA build provenance plus a keyless Sigstore
bundle — see [docs/security/supply-chain.md](docs/security/supply-chain.md#release-provenance)
for how to verify a download before running it.

### Build from source

**Prerequisites:** GHC 9.10.3 (pinned by Stack through `lts-24.61`), Stack, Node 22+,
pnpm 9+. Docker is optional.

```bash
git clone https://github.com/sagar-shirwalkar/krivostr
cd krivostr
make build
```

`make build` compiles the Haskell executable and the UI. Then start the bridge, which
also serves the built UI from `./ui/dist`:

```bash
stack exec krivostr serve
```

```
info  store: opened .krivostr/events.db
info  bridge: 3 upstream relays
info  bridge: listening on http://127.0.0.1:8081
info  connected: wss://relay.damus.io
info  connected: wss://nos.lol
info  connected: wss://relay.primal.net
```

Open <http://localhost:8081>. The landing page explains the model; open the client,
choose a signer, and post.

For UI development with hot reload, run Vite alongside the bridge. Vite does not proxy
`/ws`, so point the UI at the bridge explicitly:

```bash
stack exec krivostr serve &                        # bridge on :8081
cd ui && VITE_BRIDGE_URL=ws://localhost:8081/ws pnpm dev   # Vite on :5173
```

### Fill the store, then search it

This is the part that makes the store worth having. Stream from a relay into SQLite,
then query it:

```bash
krivostr feed --follow --ingest --relay wss://nos.lol -n 3
```

```
now    #7368   4579cf15…4579cf152e756a938e169761baca157dd6cf9df983b4aedafa2a3537
now    #20000  9bddfd32…9bddfd3281e8685684f0ff6dddca8b7b220cc34d10cb5cd6232c7542  {"messageId":"","fromPeerId":"10f8563a…
```

```bash
krivostr search peerId -n 2
```

```
2 match(es) for peerId
now    #22668  00442745…004427456813179dfcfa8e14460977878a0af57e7f4daf520e804fdd  {"peerId":"u4Cp55I9uwnnXAw3ssRS"}
now    #22870  a8a5efbd…a8a5efbdcb5e5d262523c8e9feac4c2915b56f27e33d9118c2b02d3f  {"peerId":"ICTHnCqgP7JUc8J1zdZ7"}
```

The first command talks to a relay and writes to SQLite; the second never touches the
network. That is the whole idea.

---

## Installation

### Backend

```bash
stack build --fast
stack exec krivostr serve
```

### UI

The UI is a static bundle. `krivostr serve` serves `./ui/dist` when it exists, so a
built UI and the bridge are one process on one port.

```bash
cd ui
corepack enable
corepack prepare pnpm@9 --activate
pnpm install --frozen-lockfile
pnpm build              # output: ui/dist
pnpm dev                # dev server with hot reload on :5173
```

### Docker

```bash
make docker
docker compose -f docker/docker-compose.yml up
```

The image is `debian:bookworm-slim` with `libgmp10`, `zlib1g`, `libtinfo6`, and
`ca-certificates`, and it runs under `tini` so the bridge gets correct signal handling. The container serves the
static UI and the bridge together, publishes `:8081`, and keeps the database at
`/data/events.db` on the `krivostr-data` volume. Note the compose file publishes
`8081:8081` on all interfaces — see the deployment note in
[docs/security/overview.md](docs/security/overview.md#deployment-footgun) before
exposing it past loopback.

The published Linux binary is built by `docker/Dockerfile.linux` and checked for a glibc
floor of 2.34. It is **not** a fully static build: it links against glibc, `libgmp`,
`libz`, and `libtinfo` (ncurses), so it runs on any Linux with glibc 2.34 or newer.

---

## Commands (CLI)

Global flags come before the subcommand:

| Flag | Environment | Default | Meaning |
|---|---|---|---|
| `--db PATH` | `KRIVOSTR_DB` | `.krivostr/events.db` | SQLite database |
| `--log-level LEVEL` | `KRIVOSTR_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `--color` / `--no-color` | `NO_COLOR` | auto | Force or suppress ANSI colour (`NO_COLOR` set suppresses unless `--color` is given) |
| `--version` | — | — | Print the version and exit |

| Command | What it does |
|---|---|
| `serve` | Run the bridge: WebSocket plus static UI |
| `feed` | Read the store; `--follow` streams live |
| `search` | Full-text search over the local store |
| `dm` | Send a DM (NIP-04 today, NIP-17 planned), or `--inbox` to read yours |
| `reply` | Reply to a note (NIP-10, marked `e` tags) |
| `react` | React to an event (NIP-25 kind 7, `--emoji`, default `+`) |
| `repost` | Repost (kind 6/16) or quote with `--quote` (NIP-18) |
| `verify` | Check a NIP-05 identifier against its domain |
| `publish` | Publish a Markdown file as a long-form article (NIP-23) |
| `delete` | Request deletion of your events (NIP-09), removes locally |
| `resolve` | Resolve a `nostr:` reference, bech32, or hex (NIP-27; `nevent` and `naddr` both resolve from the store) |
| `comment` | Comment on a non-note event by id or address (NIP-22) |
| `list` | Show or edit a NIP-51 list: `mute`, `pin`, `bookmark` |
| `count` | Count stored events matching a filter (NIP-45; ignores `--limit`) |
| `wallet` | Talk to a lightning wallet: `balance`, `info`, `pay`, `invoice` (NIP-47) |
| `relay` | List, add, or remove bridge upstream relays |
| `export` | Bulk export as `nostr` (ndjson), `array`, or `csv` |
| `watch` | Notify on new events |
| `api` | Run the JSON HTTP API on its own port |
| `reindex` | Rebuild the full-text search index |
| `keygen` | Generate an `nsec` / `npub` pair |
| `tui` | Interactive terminal UI over the local store |

### Setup from scratch

Fresh tarball, empty directory, no history. Five steps to a working client:

```bash
# 1. A keypair. The secret never leaves your shell history file's reach —
#    export it per session, or prefix it per command.
krivostr keygen
export KRIVOSTR_NSEC=nsec1…

# 2. Relays. The table starts empty, so `list` shows the compiled-in
#    defaults; add your own and they take effect (a running bridge picks
#    them up within ~30 seconds, no restart).
krivostr relay list
krivostr relay add wss://my-relay.example

# 3. The bridge. Serves the UI on :8081 and connects the effective set
#    (flags ∪ table, else defaults). Leave it running.
krivostr serve

# 4. Fill the store. Nothing is in SQLite until something arrives: stream
#    for a while, then read locally — the second command touches no network.
krivostr feed --follow --ingest --relay wss://nos.lol -n 50
krivostr feed -k note -n 20

# 5. Say something. Your sends are stored locally on acceptance, so `feed`
#    and `delete` can find them afterwards.
printf '# Hello\n\nFirst post.\n' > hello.md
krivostr publish hello.md --title "Hello"
```

Two things that bite newcomers: `KRIVOSTR_DB` defaults to `.krivostr/events.db`
*relative to your shell's directory* — `serve` in one directory and `feed` in
another read different stores, so pick a directory (or export the variable) and
stay there. And the UI publishes through whichever transport it is on: the
local UI talks to your bridge (everything above applies), the hosted demo
talks to public relays directly (your store stays empty until something
ingests into it).

### `feed`

```bash
krivostr feed                                  # recent events from the store
krivostr feed -k note -n 20                    # kind 1 only
krivostr feed -a npub1… -t e=<event-id>        # by author, or by tag
krivostr feed --since 2h --json                # time window, one JSON event per line
krivostr feed --follow --ingest                # stream from relays and store what arrives
```

Filter flags shared by `feed`, `search`, `export`, `watch`, and `count`: `-k/--kind`
(`note`, `dm`, `like`, `repost`, `delete`, `metadata`, `follow`, `relays`,
`giftwrap`, or a number 0–65535), `-a/--author` (`npub` or hex), `-t/--tag NAME=VALUE`
(also accepts `#e=<v>`), `--since`, `--until` (unix timestamp, `YYYY-MM-DD`, or
relative `90s|15m|2h|7d|3w|6mo|1y`), `-n/--limit` (default 100), `-s/--search`
(NIP-50 full text — FTS5 locally, forwarded to relays).

Two sharp edges: `--follow` drops `--limit` (a limit means nothing to a live
subscription), and `--ingest` only stores what verifies — forged events are rejected
with `cli: rejected event … (invalid signature)` while the display keeps showing
what arrived.

### `search`

```bash
krivostr search "gm" --any -n 20               # any word, not all
krivostr search nostr -k note --since 7d
```

`search` takes a `QUERY` positional and the shared filter flags (including `-s/--search`
as a second query source). `--any` matches any word instead of requiring all of them.

### `dm`

Needs a secret key in `KRIVOSTR_NSEC`; `krivostr keygen` prints a fresh pair.

```bash
export KRIVOSTR_NSEC=nsec1…
krivostr dm npub1… "the message"
krivostr dm --inbox                           # decrypt kind 4 events addressed to you
```

DMs are NIP-04 (AES-256-CBC under an ECDH shared secret). NIP-04 is deprecated in favour
of NIP-44; see [Known limitations](#known-limitations). The NIP-17 stack — kind 14
rumor, NIP-44 seal, gift wrap — is implemented and tested in Haskell and
TypeScript, but `dm` still sends kind 4.

`--inbox` reads from the local store only (default 50, `-n` to change) — nothing is
fetched from relays. Sends wait up to `--timeout` seconds (default 15) per relay and
are stored locally once at least one relay accepts; the process exits non-zero when
every relay refuses, so scripts can test the outcome.

### Sends: `reply`, `react`, `repost`, `publish`, `comment`, `delete`

All of these need `KRIVOSTR_NSEC`, take repeatable `--relay` (else the stored kind-10002
read hints, else the defaults), and wait `--timeout` seconds (default 15) per relay:

```bash
krivostr reply <event-id> "well said"          # NIP-10, marked e tags, root resolved from the store
krivostr react <event-id> --emoji "🤙"          # NIP-25 kind 7, default +
krivostr repost <event-id>                     # kind 6 for notes, kind 16 + k tag otherwise
krivostr repost <event-id> --quote "read this" # kind 1 + q tag, deliberately no e tag (stays out of the thread)
krivostr publish hello.md --title "Hello" --slug hello --summary "…" --image https://…
krivostr comment <event-id> "great article"    # kind 1111; refuses kind 1 (use reply, not comment)
krivostr comment kind:pubkey:slug "…"          # …or an address for versioned content
krivostr delete <event-id>…                    # kind 5; refuses other people's events, then removes yours locally
```

`publish` takes a Markdown file (required) and a `--title` (required); `--slug`
defaults to the slugified title, and the printed `30023:pubkey:slug` address replaces
on re-publish per slug. Like `dm`, every send here is stored locally on acceptance so
`feed` and `delete` can find it afterwards.

### Lookup, lists, counting, wallet

```bash
krivostr verify alice@example.com --pubkey npub1…   # NIP-05 over HTTPS; --pubkey defaults to your own key
krivostr resolve nostr:npub1…                       # authors, relays, stored events (nevent and naddr: yes)
krivostr list mute --add npub1… --del npub1…        # mute | pin | bookmark; no --add/--del prints the list
krivostr count -k note --since 7d                   # NIP-45; --limit is ignored, everything matching counts
krivostr wallet balance                             # needs KRIVOSTR_NWC=nostr+walletconnect://…
krivostr wallet pay lnbc1…                          # fixed 30s timeout; first relay in the NWC URI answers
krivostr wallet invoice 21000 --description "tip"
```

`list` values are authors for `mute`, event ids for `pin`, and either (addresses as
`a`, ids as `e`) for `bookmark`; edits publish the new list event and store it.
`wallet` does `balance`, `info`, `pay`, and `invoice` as single-flight NIP-47 calls —
no wallet service ships here, only the client side.

### `relay`, upstreams, and the bridge control channel

Upstream relays resolve in three layers: `--upstream` flags first, then the
`relay_config` table, then the compiled-in defaults. Flags and the table union
rather than override, so a flag adds a relay for one run without disturbing the
saved set:

```bash
krivostr relay list                        # what serve will connect to
krivostr relay add wss://my-relay.example  # remembered in SQLite
krivostr relay remove wss://relay.damus.io # forgotten (needs a bridge restart, or DELETE below, to drop live)
krivostr serve                             # flags ∪ table, else defaults
```

This is the bridge's own upstream set — where *your daemon* connects — not your
published NIP-65 read/write hints, which is what other clients read. The two
overlap in practice and differ on purpose.

The running bridge exposes the same control over HTTP on its own port
(same origin as the UI, so no extra service and no CORS):

```bash
curl localhost:8081/relays                                          # {connected, configured}
curl -X POST localhost:8081/relays -d '{"url":"wss://x.example"}'   # connect + remember
curl -X DELETE localhost:8081/relays -d '{"url":"wss://x.example"}' # disconnect + forget
```

Two honest details: `POST` only persists the URL when the dial actually connects —
a dead relay stays ephemeral (retried for ~6 minutes, then dropped with a warning)
so dead URLs cannot accumulate on disk. And `relay remove` only forgets; a connection
already in use stays until it drops or the bridge restarts — `DELETE /relays` is the
live disconnect.

A newly connected relay immediately receives every live client subscription,
so it joins the feed instead of sitting silent. In the UI, the relay form
under the status dots drives this endpoint on a local bridge; on the hosted
demo (direct relays) the same form opens session-only connections instead.

### `export`, `watch`, `api`, `reindex`, `keygen`

```bash
krivostr export -k note --since 30d --format csv --out notes.csv
krivostr watch -a npub1… --exec 'notify-send "{content}"'   # {json} {content} {author} {kind}
krivostr watch --bell --interval 5 --existing               # ring, poll cadence, include history
krivostr watch --print-unit > ~/.config/systemd/user/krivostr-watch.service
krivostr api --port 8090                      # GET /api/health /api/stats /api/events /api/events/:id /api/search
krivostr reindex                              # rebuild FTS5 after an import
krivostr keygen
```

`export --format` is `nostr` (ndjson, the default), `array`, or `csv` — case-insensitive,
with `ndjson` accepted as an alias; CSV tags render as `name=v1|v2` with RFC-4180
quoting. `watch --exec` substitutes exactly `{json} {content} {author} {kind}` through
`sh -c` (quoting is the caller's problem); note the generated systemd unit only carries
`--kind/--author/--tag/--bell` and silently drops `--exec`, `--interval`, `--limit`,
`--search`, and `--existing`, so re-add what the unit needs. The `api` answers
permissive CORS (`Access-Control-Allow-Origin: *`); `/api/search` requires `?q=` and answers
503 with a `run: krivostr reindex` hint when the store has no search index.

---

## TUI

```bash
krivostr tui                                    # start the TUI
krivostr tui --relay wss://nos.lol              # override upstream relays
krivostr tui --no-ingest                        # disable live follow ingest
krivostr tui --no-color                         # disable ANSI colours
```

The TUI is a brick-based terminal interface over the same SQLite store and relay
pool. It shares the store with `serve` and the CLI (WAL mode with
`busy_timeout = 5000` allows concurrent access).

### Screens and global keys

| Screen | Purpose | Enter via |
| --- | --- | --- |
| Feed | Timeline, newest first | default |
| Thread | Note + replies | `Enter` on a note |
| Search | FTS5 query | `/` |
| Lists | Mute / pin / bookmark tabs | `Tab` cycle or `:lists` |
| Help | Key table + command list | `Tab` cycle or `:help` |
| Compose | Reply / react / quote / comment | `r` `A` `Q` `c` |
| DM | *placeholder* — `:dm` shows "arrives in M3" | `Tab` cycle or `:dm` |
| Relays | *placeholder* — `:relays` shows "arrives in M3" | `Tab` cycle or `:relays` |
| Outbox | *placeholder* — depth is in the status bar | `Tab` cycle or `:outbox` |

Global keys work on the feed-like screens: `?` shows the help screen, `q` quits,
`:` opens the command bar, `/` enters search, `~` toggles the log pane, `Esc`
cancels an overlay (or pops a sub-screen), `Tab` / `Shift-Tab` cycle screens
(Feed → Relays → Lists → DM → Outbox → Help → Feed). The Search screen owns every
key while it is open, so the globals are inert there until `Esc`.

### Feed keys (Feed, Search, Thread screens):

| Key | Action |
| --- | --- |
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
| `f` | Toggle live follow mode (cosmetic — see the note below) |
| `n` | List mentions in the focused event (Thread screen only) |
| `o` | Fetch missing thread relatives from the store (Thread screen only) |
| `1`–`3` | Switch Lists tab (mute / pin / bookmark) when on Lists screen |

### Compose keys (multiline editor)

| Key | Action |
| --- | --- |
| `Ctrl-G` | Sign and send |
| `Esc` | Cancel, return to previous screen |
| `E` | Promote to `$EDITOR` (only on empty editor) |

### Command bar (opened with `:`) 

The parser is total — anything it does not recognize is logged as `unknown command` rather than failing. Only these are
wired:

| Command | Effect |
| --- | --- |
| `:q` / `:quit` | Leave the TUI |
| `:search <text>` | Open the search view on `<text>` |
| `:count [kind]` | Log the number of stored events (optionally of one kind) |
| `:limit <n>` | Set the feed query limit and reload the feed |
| `:resolve <ref>` | Resolve `npub`/`note`/`naddr`/hex/`nostr:` refs, logging the result |
| `:verify <name> [pubkey]` | Fetch a NIP-05 document and check the optional key |
| `:publish <file> [title]` | Publish a NIP-23 article from a file (needs `KRIVOSTR_NSEC`) |
| `:ingest [on\|off]` | Start/stop the live ingest subscription (default toggles) |
| `:relays` | Show the (placeholder) relays view |
| `:lists` | Show the mute/pin/bookmark lists view |
| `:outbox` | Show the (placeholder) outbox view |
| `:dm` | Show the (placeholder) DM view |
| `:help` | Show the help view |

The wider CLI parity the TUI is aiming at — `:export`, `:wallet`, `:reindex`,
`:keygen`, `:bell`, `:exec` — is **not implemented yet**; each currently logs
`unknown command`. Use the CLI subcommand of the same name meanwhile.

### Security notes

- Muted authors are filtered from the feed (same as CLI `feed` and web UI).
- Sensitive content (NIP-36 `content-warning` tag) renders as `[hidden — content-warning]` until `v` is pressed; reveals are session-only, never persisted.
- The log pane (`~`) captures all publish verdicts, async results, and yanks — nothing is printed to stderr (would shred the screen).
- `KRIVOSTR_NSEC` enables sending; without it the TUI is read-only (same as CLI).

**One known TUI quirk.** `f` toggles an `asFollowing` flag that only feeds
the status bar — it does *not* pause the live ingest subscription. Use `:ingest off` for
that; the `f` toggle is cosmetic until the key is wired to the same seam.

---

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `KRIVOSTR_DB` | `.krivostr/events.db` | SQLite path (serve and CLI must agree — it is relative to your shell's directory) |
| `KRIVOSTR_LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |
| `KRIVOSTR_PORT` | `8081` | Bridge port (`serve`) |
| `KRIVOSTR_STATIC_DIR` | `./ui/dist` | Static asset directory |
| `KRIVOSTR_API_HOST` | `127.0.0.1` | Interface for `api` |
| `KRIVOSTR_NSEC` | — | Secret key for `dm` and every send command |
| `KRIVOSTR_NWC` | — | Wallet connection URI for `wallet` (NIP-47) |

Two `--help` texts name environment variables the runners ignore: `serve --host`
cites `KRIVOSTR_BRIDGE_HOST`, but the parser's own default shadows it, so only the
`--host` flag (default `127.0.0.1`) takes effect; `api --host` cites
`KRIVOSTR_API_HOST` in help yet the dispatch passes the flag straight through, so again
pass `--host` explicitly. See [Known limitations](#known-limitations).

UI variables are read by Vite at build time, so they must be set before `pnpm build`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `VITE_BRIDGE_URL` | same origin | Where the browser opens its WebSocket, e.g. `ws://localhost:8081` |
| `VITE_KRIVOSTR_TRANSPORT` | `relay` | `bridge` or `relay` |

`?transport=bridge` in the URL sets the same choice at runtime. When neither is
set, a page on `localhost` / loopback defaults to the bridge (the tarball case),
and anywhere else defaults to direct relays (the hosted demo). Dropped sockets
redial with backoff (six attempts, doubling); the bridge warning offers a manual
retry. The transport switch is
honoured by the relay-status element, which owns the browser's Nostr socket; the rest of
the UI reads from that element.

---

## Architecture

<!-- Architecture diagram as plain HTML. GitHub's sanitizer strips inline `style`
     and `bgcolor`, so this uses only tags and attributes it keeps (`<table>`,
     `<font color>`, `align`, `colspan`) plus the client's design-token accents.
     Palette legend: relay/external = mute #767a82, client = amber-dim #a87f3f,
     core = sage-dim #5a8e87, browser = indigo #6b7de0. See
     .agents/skills/krivostr-client-visual-design/references/design-tokens.md. -->

<table width="100%" cellpadding="8" cellspacing="0" border="0">
  <tr>
    <td align="center" valign="top" width="20%">
      <font color="#767a82"><b>Nostr relays</b></font><br>
      <sub>external · untrusted</sub><br><br>
      <code>REQ · EVENT · EOSE</code>
    </td>
    <td align="center" valign="middle" width="8%">⇄<br><sub>wss://</sub></td>
    <td align="center" valign="top" width="36%">
      <font color="#a87f3f"><b>krivostr-client</b></font><br>
      <sub>effectful Haskell</sub><br><br>
      <code>Pool</code> — one drain thread per relay<br>
      <code>Store</code> — SQLite + FTS5, 30-day retention<br>
      <code>Bridge</code> — WebSocket + static UI<br>
      <code>Cli</code> — 22 subcommands · <code>Cli.Api</code> — JSON on :8090
    </td>
    <td align="center" valign="middle" width="8%">↔<br><sub>pure</sub></td>
    <td align="center" valign="top" width="28%">
      <font color="#5a8e87"><b>krivostr-core</b></font><br>
      <sub>pure Haskell · no IO</sub><br><br>
      <code>Wire</code> — NIP-01 encode / decode<br>
      <code>Event</code> — event ADT, accessors<br>
      <code>Filter</code> — matches predicate<br>
      <code>Nip01 · Schnorr · Key</code>
    </td>
  </tr>
</table>

<table width="100%" cellpadding="8" cellspacing="0" border="0">
  <tr>
    <td align="center" valign="top" width="20%">
      <font color="#6b7de0"><b>Browser — Lit 3 UI</b></font><br>
      <sub>the client's other half</sub><br><br>
      <code>app-shell</code><br>
      <code>nostr-relay-status</code> — owns the socket<br>
      <code>signer</code> — local nsec · NIP-07 · NIP-46
    </td>
    <td align="center" valign="middle" width="8%">⇄<br><sub>wss://host/ws</sub></td>
    <td align="center" valign="top" width="36%">
      <b>Bridge, relay-shaped</b><br>
      <sub>answers from SQLite first, then fans out upstream</sub><br><br>
      A browser speaks ordinary Nostr to <code>krivostr serve</code>; the bridge
      replays matching history, sends <code>EOSE</code>, then broadcasts the
      <code>REQ</code> to the effective upstream set.
    </td>
    <td align="center" valign="middle" width="8%">⇄</td>
    <td align="center" valign="top" width="28%">
      <b>IndexedDB cache</b><br>
      <sub>30-day retention, verified on put</sub><br><br>
      <code>ui/src/nostr/cache.ts</code> — module present but not wired into a
      component; the bridge's SQLite is the durable store in practice.
    </td>
  </tr>
</table>

The Haskell and TypeScript sides deliberately mirror each other: fallible operations are
`Result`s, effects are `IO`s, and optionality is `Maybe`. Same shape on both sides,
no cross-language FFI. (Filter *matching* is a hand-rolled predicate on both sides rather
than the `Rule` algebra — see [docs/architecture.md](docs/architecture.md).)

- **`core/`** — pure Haskell: NIP-01 serialization/signing/verification, NIP-05
  identifiers, NIP-09 deletion, NIP-10 replies, NIP-13 proof of work, NIP-17
  private DMs, NIP-18 reposts, NIP-19 entities, NIP-21 URIs, NIP-22 comments,
  NIP-23 articles, NIP-25 reactions, NIP-27 references, NIP-36 content warnings,
  NIP-40 expiration, NIP-42 AUTH, NIP-44 v2 encryption, NIP-46 nostr-connect,
  NIP-47 wallet connect, NIP-49 `ncryptsec`, NIP-50 search filter, NIP-51 lists,
  NIP-57 zaps, NIP-59 gift wrap, NIP-11 relay info, NIP-65 relay hints,
  filter predicates, wire ADTs, `Writer`-based logging.
- **`client/`** — effectful Haskell: relay pool, SQLite store (FTS5),
  WebSocket bridge, HTTP API, CLI (22 subcommands).
- **`ui/`** — browser: Lit 3, hand-rolled `Maybe` / `Result` / `IO` / `Rule`, IndexedDB
  cache, signer picker (NIP-07 modal, NIP-46 bunker, risk-gated local `nsec`).

See [docs/architecture.md](docs/architecture.md) for more detail.

---

## Protocol support

| NIP | Title | Status |
| --- | --- | --- |
| 01 | Basic protocol | ✅ full — variadic `REQ` filters, `EVENT`, `EOSE`, `OK`, `NOTICE`, `CLOSED` |
| 02 | Follow list | ❌ not implemented |
| 04 | Encrypted direct messages | ◐ CLI can send; UI cannot read (NIP-04 only) |
| 05 | DNS identifiers | ✅ parse + HTTPS verify (`krivostr verify`, UI logic) |
| 07 | `window.nostr` | ✅ full |
| 09 | Event deletion | ✅ kind 5, `krivostr delete`, local removal + UI hide |
| 10 | Reply conventions | ✅ marked + positional `e` tags, `krivostr reply`, UI threads |
| 11 | Relay info | ◐ parses `RelayInfo` (`supportsNip`); nothing fetches it on connect |
| 13 | Proof of work | ✅ `nonce` tag, leading-zero-bit difficulty, committed target |
| 18 | Reposts | ✅ kind 6/16 + `q` quotes, `krivostr repost`, UI rendering |
| 19 | bech32 entities | ✅ keys + `nevent`/`naddr` TLV pointers, both sides |
| 21 | `nostr:` URIs | ✅ single-reference parse; UI mentions open in-client |
| 22 | Comments | ✅ kind 1111 root/parent scopes, `krivostr comment`, UI threads |
| 23 | Long-form content | ✅ kind 30023 articles, `krivostr publish`, UI rendering |
| 25 | Reactions | ✅ kind 7 `e`/`p`/`k`, `krivostr react`, UI counts |
| 27 | Text note references | ✅ `nostr:` scanning, `krivostr resolve`, UI mentions |
| 36 | Sensitive content | ✅ `content-warning`, CLI gate, UI blur-to-reveal |
| 40 | Expiration timestamp | ✅ `expiration` tag helpers; purge is retention-based |
| 42 | Authentication | ✅ kind 22242 challenge/response, wired into the relay pool |
| 44 | Versioned encryption | ✅ NIP-44 v2 — ChaCha20 + HMAC, official vectors |
| 45 | Counting results | ✅ wire `COUNT`, bridge SQLite answer, `krivostr count` |
| 46 | Remote signer | ✅ bunker over NIP-44, wired into the signer picker |
| 47 | Wallet connect | ✅ NIP-44 requests/responses, `krivostr wallet`, UI zap payment path |
| 49 | Private-key encryption | ✅ `ncryptsec` — scrypt + XChaCha20-Poly1305 |
| 50 | Search | ✅ wire `search` filter; bridge FTS5, CLI `--search`, UI search box |
| 51 | Lists | ✅ mute/pin/bookmark, `krivostr list`, UI mute filtering |
| 57 | Lightning zaps | ✅ kind 9734 + 9735 receipts, LNURL flow, UI zap dialog |
| 59 | Gift wrap | ✅ rumor → seal (kind 13) → wrap (kind 1059), official vectors |
| 17 | Private direct messages | ✅ kind 14 rumor → seal → wrap, ±2 day jitter |
| 65 | Relay list metadata | ◐ kind 10002 drives CLI read relays; `writeRelays` unused |

---

## Testing and coverage

```bash
make test          # backend (stack test) + UI unit + UI browser
make test-backend  # 1093 hspec examples (647 core + 446 client)
make test-ui       # 310 unit tests (jsdom) + 29 browser tests (real Chromium)
```

Browser tests run through `@vitest/browser` and Playwright against real Chromium. They
exercise the Lit elements end to end: rendering, event emission, attribute reflection,
and lifecycle. On a fresh clone, `make test-ui` installs the Playwright browser first;
without that step the browser project fails with `Executable doesn't exist at …`.

Coverage:

```bash
make coverage          # backend and UI
cd ui && pnpm coverage # v8, thresholds 80/80/80/80
```

Backend coverage is reported by `scripts/hpc-coverage.py`, which reads the HTML index
that `stack test --coverage` writes. The cryptography and the NIP modules are well
covered; the IO layers — the relay pool, the bridge, the CLI, and the HTTP API — dominate
the total and are mostly untested. `.hpc-threshold` pins the measured total as a ratchet
(currently `min: 70`): coverage may rise, and `make coverage` fails if it drops. If your
change raises the measured number, raise the pin in the same change; never lower it.

UI coverage is a different story, because the vitest config measures the pure logic
(`src/fp` and `src/nostr`, excluding the bridge transport) with thresholds of 80 across
statements, branches, functions, and lines.

The printed percentages are deliberately not copied here, so they cannot drift out of
date. To surface the number as a badge instead, either:

- **Static** — a `shields.io` badge whose value you bump by hand when the ratchet moves:
  `https://img.shields.io/badge/coverage-<pct>%25-<color>`. Update it in the same change
  that edits `.hpc-threshold`.
- **Dynamic** — have CI write a shields.io endpoint document
  (`{"schemaVersion":1,"label":"coverage","message":"<pct>%","color":"<color>"}`) and point
  the badge at `https://img.shields.io/endpoint?url=<raw-url>`. Nothing to keep in sync by
  hand; the workflow owns the file.

`shields.io` badges render instantly with no third-party account. Codecov is the heavier
option if you later want history and PR annotations.

---

## Development

```bash
make build             # backend + UI
make build-backend     # stack build --fast
make build-ui          # pnpm install + pnpm build
make test              # backend + UI unit + UI browser
make test-backend      # stack test
make test-ui           # unit + browser
make test-ui-browser   # browser tests only
make coverage          # backend + UI coverage reports
make docker            # build the runtime image
make clean             # remove build artifacts
```

`stack.yaml` resolves everything from `lts-24.61` with no extra dependencies, so
`stack build` is reproducible from that file alone. See
[docs/development.md](docs/development.md) for the longer version.

---

## Design decisions

- **The core is pure.** Signing, hashing, filter matching, and wire encoding are pure
  functions. Everything that performs IO lives in `client`.
- **The bridge is a personal relay.** Same wire protocol as a relay, backed by SQLite,
  single-user, on your machine.
- **Retention is a policy, not a default.** Ordinary events expire after 30 days;
  persistent kinds — DMs, follows, metadata, and relay lists — never do. The policy
  lives in `Store.hs` and `cache.ts` and is applied identically on both sides.
- **Ingest is idempotent and verified.** Events are inserted with `INSERT OR IGNORE`
  on the event id, so re-streaming the same relay changes nothing — and every insert
  first verifies the Schnorr signature, answering `Inserted` / `Duplicate` /
  `InvalidSignature`, so forgeries never reach the store.
- **The UI re-expresses the algebra.** Fallible operations are `Result`s and effects are
  `IO`s. The `Rule`/`Predicate` combinators in `fp/algebra.ts` exist but nothing in the
  app uses them yet; only the algebra's own test imports that module.

---

## Known limitations

Worth stating plainly, because the rest of this README is otherwise optimistic.

- **Ingest trusts nothing.** `Store.insertEvent` verifies every signature and answers
  `Inserted` / `Duplicate` / `InvalidSignature`; the browser cache refuses forgeries too.
- **Backend test coverage is gated by a ratchet** (`.hpc-threshold`): the build fails
  when coverage drops below the pinned floor. The NIP modules are well covered; the relay
  pool, bridge, CLI, and HTTP API are not. Run `make coverage` for the current number.
- **The local signer keeps the secret in memory for the session only.** There is no
  at-rest encryption and nothing is written to disk, but there is also no keyring
  integration.
- **The Linux binary is not static.** It needs glibc 2.34+, `libgmp`, `libz`, and `libtinfo` (ncurses).
- **Upstream `search` depends on the relay.** The bridge answers from FTS5; remote
  relays without NIP-50 ignore the `search` key and return unfiltered matches.
- **`_headers` applies to Cloudflare Pages only.** `krivostr serve` serves the same files
  without the CSP.
- **`dm @alice` is not accepted**; pass an `npub` or hex key.
- **Two `--help` texts name environment variables the runners ignore.**
  `KRIVOSTR_BRIDGE_HOST` is shadowed by the parser default and `KRIVOSTR_API_HOST` is
  never read by the `api` dispatch — pass `--host` explicitly until those are wired up.
- **`resolve` answers from the local store.** `nevent` and `naddr` pointers are decoded
  and the referenced event is looked up locally; it is never fetched from a relay, so an
  event you have not ingested resolves to "not in the local store".

---

## Roadmap

### Near-term

- Tests for the IO layers, to move backend coverage off the floor.
- **NIP-02** — parse and honour kind 3 follow lists.
- **NIP-13** — inbound filter with configurable difficulty threshold.

### Medium-term

- **NIP-17** — switch `dm` from NIP-04 to gift-wrapped kind 14.
- **NIP-49** — encrypt the local signer's key at rest with `ncryptsec`.

---

## License

[GNU Affero General Public License v3.0](LICENSE) — SPDX `AGPL-3.0-only`.

The AGPL covers the Haskell backend and the TypeScript UI together; both are
released under these terms.

Section 13 asks that users interacting with the software over a network be
offered its source. `krivostr serve` is exactly such a service, so this
repository is that offer: <https://github.com/sagar-shirwalkar/krivostr>
