/**
 * NIP-17 private direct messages, composed from NIP-59 primitives.
 *
 * This module is mostly composition: build a kind-14 rumor, seal it, then
 * gift-wrap it to every participant. The parts that are NIP-17's own are the
 * ones that make the scheme private rather than merely encrypted:
 * - The rumor's `p` tags define the room. Adding or removing one starts a
 *   new room with a clean history — the tag set IS the room identity, so
 *   there is no public group identifier to correlate.
 * - Every layer's `created_at` is randomized up to two days into the past.
 *   Grouping messages by timestamp is otherwise a cheap way to link them.
 * - The sender gets their own gift wrap. Without it the sender keeps no copy
 *   and "fully recoverable" would not hold.
 *
 * NIP-17 says the rumor's content MUST be plain text. Enforcing that is a
 * client decision, not a protocol one: the seal encrypts whatever bytes it
 * is given. The caller is trusted to follow it.
 *
 * Mirrors `Krivostr.Nip.Nip17` on the Haskell side.
 */

import { NostrEvent } from './event';
import { Rumor, createRumor, seal, wrap } from './nip59';
import { Result, Ok } from '../fp/result';

/** Kind 14, a chat message. Content is plain text. */
export const chatKind = 14;
/** Kind 15, an encrypted file message. */
export const fileMessageKind = 15;
/** Kind 10050, the user's preferred relays for receiving DMs. */
export const dmRelayListKind = 10050;

/** The jitter window, in seconds. */
export const twoDaysSeconds = 2 * 24 * 60 * 60;

/**
 * Shift a timestamp backwards by a caller-supplied offset, clamped to
 * `[0, twoDaysSeconds]`. A negative offset would date the event in the
 * future, which some relays refuse to serve.
 */
export const pastTimestamp = (now: number, offset: number): number => {
  if (offset < 0) return now;
  if (offset > twoDaysSeconds) return now - twoDaysSeconds;
  return now - offset;
};

/**
 * Build a kind-14 chat rumor. The `p` tags are the room; an optional
 * `subject` tag rides along as an ordinary tag (only the newest one in a
 * room counts as the topic).
 */
export const createChatRumor = (
  skHex: string,
  now: number,
  receivers: string[],
  subject: string,
  content: string,
): Result<string, Rumor> => {
  const pTags = receivers.filter((r) => r !== '').map((r) => ['p', r]);
  const tags = subject !== '' ? [...pTags, ['subject', subject]] : pTags;
  return createRumor(skHex, { pubkey: '', created_at: now, kind: chatKind, tags, content });
};

/**
 * Build a kind-15 file message rumor. The file itself is encrypted by the
 * caller; only the tags carrying no caller data are filled in here, the rest
 * arrive via `extraTags`.
 */
export const createFileRumor = (
  skHex: string,
  now: number,
  receivers: string[],
  fileType: string,
  content: string,
  extraTags: string[][],
): Result<string, Rumor> => {
  const tags = [
    ...receivers.filter((r) => r !== '').map((r) => ['p', r]),
    ...(fileType !== '' ? [['file-type', fileType]] : []),
    ...extraTags,
  ];
  return createRumor(skHex, { pubkey: '', created_at: now, kind: fileMessageKind, tags, content });
};

/** The receivers of a chat rumor: its `p` tags, in order. */
export const chatReceivers = (r: Pick<Rumor, 'tags'>): string[] =>
  r.tags.filter((t) => t[0] === 'p' && t.length > 1 && t[1] !== '').map((t) => t[1]);

/** The rumor's `subject` tag, if any. */
export const chatSubject = (r: Pick<Rumor, 'tags'>): string | undefined => {
  const s = r.tags.find((t) => t[0] === 'subject' && t.length > 1 && t[1] !== '');
  return s?.[1];
};

/** The two layers of a sent message, kept together. */
export interface DmLayers {
  seal: NostrEvent;
  wrap: NostrEvent;
}

/**
 * Seal a rumor for one recipient and gift-wrap the seal to them.
 *
 * The wrap is signed by `wrapperSkHex`, which must be a fresh one-time key
 * unrelated to the author's: the wrap is what a relay sees, and an
 * author-signed wrap would link every message to one identity. Timestamps
 * and nonces are independent per layer for the same reason — reusing either
 * across layers is exactly the correlation the spec warns about.
 */
export const sealAndWrap = (
  authorSkHex: string,
  wrapperSkHex: string,
  recipientHex: string,
  sealCreated: number,
  sealNonce: Uint8Array,
  wrapCreated: number,
  wrapNonce: Uint8Array,
  rumor: Rumor,
): Result<string, DmLayers> => {
  const s = seal(authorSkHex, recipientHex, sealCreated, sealNonce, rumor);
  if (s._tag === 'Err') return s;
  const w = wrap(wrapperSkHex, recipientHex, wrapCreated, wrapNonce, s.value);
  if (w._tag === 'Err') return w;
  return Ok({ seal: s.value, wrap: w.value });
};

/**
 * The `relay` tags for a kind-10050 DM relay list. Clients MUST only publish
 * DMs to the recipient's listed relays: the wrap says who, this says where.
 */
export const dmRelayListTags = (relays: string[]): string[][] =>
  relays.filter((r) => r !== '').map((r) => ['r', r]);
