# Protocol

krivostr implements the Nostr wire protocol as defined in [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md).

## Events

An event is a JSON object with:


| Field | Type | Notes |
|---|---|---|
| `id` | 32-byte hex | sha256 of canonical serialization |
| `pubkey` | 32-byte hex | x-only Schnorr public key |
| `created_at` | unix seconds | |
| `kind` | int | see NIP-01 for standard kinds |
| `tags` | `string[][]` | |
| `content` | string | |
| `sig` | 64-byte hex | BIP-340 Schnorr |

Canonical serialization for the id: 

**[0, <pubkey>, <created_at>, <kind>, <tags>, <content>]** . No whitespace, UTF-8, `sha256`.

## Wire messages

Client → relay:

- `["EVENT", <event>]`
- `["REQ", <sub-id>, <filter>...]`
- `["CLOSE", <sub-id>]`

Relay → client:

- `["EVENT", <sub-id>, <event>]`
- `["OK", <event-id>, <bool>, <message>]`
- `["EOSE", <sub-id>]`
- `["NOTICE", <message>]`
- `["CLOSED", <sub-id>, <message>]`

## Filters

A filter is a JSON object with optional keys:

| Key | Type |
|---|---|
| `ids` | `string[]` |
| `authors` | `string[]` |
| `kinds` | `int[]` |
| `since` | `int` |
| `until` | `int` |
| `limit` | `int` |
| `#e`, `#p`, ... | `string[]` |

An event matches iff every present clause matches.

## NIPs implemented

| NIP | Title | Status |
|---|---|---|
| 01 | Basic protocol | ✅ |
| 02 | Follow list | 📋 (parse-only) |
| 07 | `window.nostr` | ✅ |
| 19 | bech32 entities | ✅ |
| 46 | Remote signer | ✅ (NIP-04 transport) |
| 65 | Relay list metadata | ✅ |

## NIPs planned

- 44 — Versioned encryption
- 50 — Search
- 59 — Gift wrap
