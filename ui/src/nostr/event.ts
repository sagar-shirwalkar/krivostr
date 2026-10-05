/**
 * NIP-01 event algebra.
 *
 * The only place that knows how an event is shaped, hashed, and serialized.
 * Everything else in the UI goes through `parseEvent` for untrusted input and
 * `canonicalBytes` for signing, so the canonical form is defined exactly once.
 *
 * Mirrors `Krivostr.Event` and `Krivostr.Nip.Nip01` on the Haskell side.
 */

import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex } from '@noble/hashes/utils';
import { Result, Ok, Err } from '../fp/result';

/** An event before it has an id or a signature. */
export interface UnsignedEvent {
  pubkey: string;
  created_at: number;
  kind: number;
  tags: string[][];
  content: string;
}

/** A complete event. `id` is the SHA-256 of the canonical serialization. */
export interface NostrEvent extends UnsignedEvent {
  id: string;
  sig: string;
}

const HEX64 = /^[0-9a-f]{64}$/;
const HEX128 = /^[0-9a-f]{128}$/;

const isHex = (re: RegExp, v: unknown): v is string =>
  typeof v === 'string' && re.test(v);

/** True when `v` is an array of arrays of strings, i.e. a well-formed tag list. */
const isTagList = (v: unknown): v is string[][] =>
  Array.isArray(v) &&
  v.every(
    (tag) => Array.isArray(tag) && tag.every((part) => typeof part === 'string'),
  );

/**
 * Validate an untrusted value as a 'NostrEvent'.
 *
 * Structural only: it checks presence and types, not that `id` really is the
 * hash of the content or that `sig` verifies. Signature checking belongs at
 * the trust boundary (see `verifyEvent`), not in the decoder, because relays
 * legitimately forward events we have no key for.
 */
export const parseEvent = (v: unknown): Result<string, NostrEvent> => {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) {
    return Err('event is not an object');
  }
  const o = v as Record<string, unknown>;

  if (!isHex(HEX64, o.id)) return Err('id must be 64 lowercase hex characters');
  if (!isHex(HEX64, o.pubkey)) return Err('pubkey must be 64 lowercase hex characters');
  if (!isHex(HEX128, o.sig)) return Err('sig must be 128 lowercase hex characters');
  if (typeof o.created_at !== 'number' || !Number.isInteger(o.created_at)) {
    return Err('created_at must be an integer');
  }
  if (typeof o.kind !== 'number' || !Number.isInteger(o.kind)) {
    return Err('kind must be an integer');
  }
  if (!isTagList(o.tags)) return Err('tags must be an array of string arrays');
  if (typeof o.content !== 'string') return Err('content must be a string');

  return Ok({
    id: o.id,
    pubkey: o.pubkey,
    created_at: o.created_at,
    kind: o.kind,
    tags: o.tags,
    content: o.content,
    sig: o.sig,
  });
};

/**
 * The NIP-01 canonical serialization: the UTF-8 JSON array
 * `[0, pubkey, created_at, kind, tags, content]`.
 *
 * `JSON.stringify` already emits exactly this shape, because the array is built
 * from plain values with no keys and no whitespace. Building the array by hand
 * rather than string-formatting each field is what keeps the escaping correct:
 * `JSON.stringify` handles the control characters in `content` that NIP-01
 * requires be escaped, which naive interpolation would not.
 */
export const canonicalBytes = (u: UnsignedEvent): Uint8Array =>
  new TextEncoder().encode(
    JSON.stringify([0, u.pubkey, u.created_at, u.kind, u.tags, u.content]),
  );

/** The event id: SHA-256 of the canonical serialization, lowercase hex. */
export const computeId = async (u: UnsignedEvent): Promise<string> =>
  bytesToHex(sha256(canonicalBytes(u)));

/** First value of the first tag with this name, if any. */
export const tagValue = (
  e: Pick<NostrEvent, 'tags'>,
  name: string,
): string | undefined => {
  for (const tag of e.tags) {
    if (tag[0] === name && tag.length > 1) return tag[1];
  }
  return undefined;
};

/** Every value of every tag with this name. */
export const tagValues = (
  e: Pick<NostrEvent, 'tags'>,
  name: string,
): string[] =>
  e.tags.filter((tag) => tag[0] === name && tag.length > 1).map((tag) => tag[1]);

/** True when the event replies to something. */
export const isReply = (e: Pick<NostrEvent, 'tags'>): boolean =>
  e.tags.some((tag) => tag[0] === 'e');

/** Seconds between the event's timestamp and `now` (both Unix seconds). */
export const ageSeconds = (
  e: Pick<NostrEvent, 'created_at'>,
  now: number,
): number => now - e.created_at;

/**
 * Confirm `id` really is the hash of the event's content.
 *
 * Cheaper than a signature check and catches the common case of a relay or a
 * cache handing back a mutated event. Does not prove authorship.
 */
export const verifyId = async (e: NostrEvent): Promise<boolean> =>
  (await computeId(e)) === e.id;

/**
 * Confirm the event is whole: the id hashes the content AND the Schnorr
 * signature verifies against the claimed pubkey. This is the ingest gate —
 * the cache refuses events that fail it, so a malicious relay cannot plant
 * events attributed to anyone in local storage.
 */
export const verifyEvent = async (e: NostrEvent): Promise<boolean> => {
  try {
    if ((await computeId(e)) !== e.id) return false;
    return schnorr.verify(e.sig, e.id, e.pubkey);
  } catch {
    return false;
  }
};
