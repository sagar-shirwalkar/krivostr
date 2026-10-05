/**
 * NIP-27 text note references: `nostr:` URIs inside event text.
 *
 * A mention is `nostr:` plus a NIP-19 bech32 string: `npub` names an author,
 * `note` an event, `nprofile` an author with relay hints. Scanning is
 * deliberately dumb — find `nostr:`, take the bech32 run, decode it — because
 * mentions live in free text.
 *
 * An `nsec` in text is never usable: decoding it would put a secret one
 * copy-paste from publication, so it parses as opaque. `nevent`/`naddr`
 * are opaque until the NIP-19 entity work lands.
 *
 * Mirrors `Krivostr.Nip.Nip27` on the Haskell side.
 */

import { decode, npubDecode, noteDecode, nprofileDecode } from './bech32';

export type MentionKind =
  | { type: 'pubkey'; hex: string }
  | { type: 'event'; hex: string }
  | { type: 'profile'; hex: string; relays: string[] }
  | { type: 'opaque'; hrp: string };

/** One reference: what it means plus the exact source span. */
export interface Mention {
  kind: MentionKind;
  raw: string;
}

const BECH32 = /[a-z0-9]/;

/**
 * Find every `nostr:` reference in free text, in order. Runs that are not
 * valid bech32 are skipped, not errors.
 */
export const findMentions = (text: string): Mention[] => {
  const out: Mention[] = [];
  let i = 0;
  for (;;) {
    const at = text.indexOf('nostr:', i);
    if (at < 0) break;
    let end = at + 6;
    while (end < text.length && BECH32.test(text[end])) end++;
    const run = text.slice(at + 6, end);
    const m = decodeRun(run);
    if (m) out.push(m);
    i = end;
  }
  return out;
};

const decodeRun = (run: string): Mention | undefined => {
  const raw = `nostr:${run}`;
  let hrp: string;
  try {
    hrp = decode(run).hrp;
  } catch {
    return undefined;
  }
  try {
    if (hrp === 'npub') return { kind: { type: 'pubkey', hex: npubDecode(run) }, raw };
    if (hrp === 'note') return { kind: { type: 'event', hex: noteDecode(run) }, raw };
    if (hrp === 'nprofile') {
      const p = nprofileDecode(run);
      return { kind: { type: 'profile', hex: p.pubkey, relays: p.relays ?? [] }, raw };
    }
    return { kind: { type: 'opaque', hrp }, raw };
  } catch {
    return undefined;
  }
};

/** A renderable segment: plain text or a mention. */
export type Segment = { text: string } | { mention: Mention };

/** Split text into plain and mention segments for rendering. */
export const splitSegments = (text: string): Segment[] => {
  const mentions = findMentions(text);
  if (mentions.length === 0) return [{ text }];
  const segs: Segment[] = [];
  let i = 0;
  for (const m of mentions) {
    const at = text.indexOf(m.raw, i);
    if (at > i) segs.push({ text: text.slice(i, at) });
    segs.push({ mention: m });
    i = at + m.raw.length;
  }
  if (i < text.length) segs.push({ text: text.slice(i) });
  return segs;
};

/** Short label for a mention: `@ab12…`, `#ab12…`, or the raw span. */
export const mentionLabel = (m: Mention): string => {
  const short = (hex: string): string => `${hex.slice(0, 4)}…${hex.slice(-4)}`;
  switch (m.kind.type) {
    case 'pubkey':
      return `@${short(m.kind.hex)}`;
    case 'event':
      return `#${short(m.kind.hex)}`;
    case 'profile':
      return `@${short(m.kind.hex)}`;
    case 'opaque':
      return m.raw.length > 20 ? `${m.raw.slice(0, 17)}…` : m.raw;
  }
};
