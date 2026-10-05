/**
 * NIP-59 gift wrap: rumor, seal, and gift wrap.
 *
 * Three layers with separate jobs, and the privacy comes from keeping them
 * separate:
 * - a rumor is an unsigned event. No signature, so a leak is rejected by
 *   relays and clients and cannot be authenticated.
 * - a seal (kind 13) is signed by the real author and encrypts the rumor to
 *   one recipient. No `p` tag, so nothing public names the recipient.
 * - a gift wrap (kind 1059) is signed by a random one-time key and encrypts
 *   the seal. Its `p` tag is the only routing information on the wire.
 *
 * A relay sees only the wrap: the recipient, and nothing else.
 *
 * The rumor serializes WITHOUT a `sig` field. The seal's ciphertext is a
 * function of those exact bytes, so emitting `"sig":""` would produce a
 * payload no other client can open.
 *
 * Ephemeral keys, timestamps, and NIP-44 nonces are parameters — nothing
 * here reads the clock or the CSPRNG — which keeps round trips
 * deterministic and the spec's worked example reproducible.
 *
 * Mirrors `Krivostr.Nip.Nip59` on the Haskell side.
 */

import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, hexToBytes, utf8ToBytes, bytesToUtf8 } from '@noble/hashes/utils';
import { NostrEvent, UnsignedEvent, canonicalBytes, parseEvent } from './event';
import { encryptWithNonce, decrypt } from './nip44';
import { Result, Ok, Err } from '../fp/result';

/** Kind 13. Tags MUST be empty and the inner event MUST be unsigned. */
export const sealKind = 13;
/** Kind 1059. The persistent gift wrap, for asynchronous DMs. */
export const wrapKind = 1059;
/** Kind 21059. Ephemeral: relays MUST NOT store it. For live chat. */
export const ephemeralWrapKind = 21059;

/**
 * An unsigned event with an id. The id is computed, the signature is not —
 * that absence is the deniability: a leaked rumor cannot be attributed.
 */
export interface Rumor {
  id: string;
  pubkey: string;
  created_at: number;
  kind: number;
  tags: string[][];
  content: string;
}

/** Sign an unsigned event with a hex secret. The local signing primitive. */
const signUnsigned = (skHex: string, u: UnsignedEvent): Result<string, NostrEvent> => {
  try {
    const sk = hexToBytes(skHex);
    const pubkey = bytesToHex(schnorr.getPublicKey(sk));
    const withPub: UnsignedEvent = { ...u, pubkey };
    const id = bytesToHex(sha256(canonicalBytes(withPub)));
    const sig = bytesToHex(schnorr.sign(id, sk));
    return Ok({ ...withPub, id, sig });
  } catch (e) {
    return Err(`cannot sign event: ${String(e)}`);
  }
};

const verifyEvent = (e: NostrEvent): boolean => {
  try {
    const id = bytesToHex(sha256(canonicalBytes(e)));
    if (id !== e.id) return false;
    return schnorr.verify(e.sig, id, e.pubkey);
  } catch {
    return false;
  }
};

/**
 * Build a rumor from an unsigned event and the author's hex secret.
 * Pubkey is filled in and the id computed, exactly as signing would do —
 * but no signature. The id is part of the rumor (NIP-17 links replies by
 * it); the signature is what a rumor must not have.
 */
export const createRumor = (skHex: string, u: UnsignedEvent): Result<string, Rumor> => {
  try {
    const pubkey = bytesToHex(schnorr.getPublicKey(hexToBytes(skHex)));
    const withPub: UnsignedEvent = { ...u, pubkey };
    const id = bytesToHex(sha256(canonicalBytes(withPub)));
    return Ok({ id, pubkey, created_at: u.created_at, kind: u.kind, tags: u.tags, content: u.content });
  } catch (e) {
    return Err(`cannot build rumor: ${String(e)}`);
  }
};

/**
 * The exact bytes a seal encrypts. Key order is alphabetical
 * (content, created_at, id, kind, pubkey, tags) to match aeson's encoding on
 * the Haskell side — the ciphertext is a function of these bytes.
 */
export const rumorBytes = (r: Rumor): Uint8Array =>
  utf8ToBytes(
    JSON.stringify({
      content: r.content,
      created_at: r.created_at,
      id: r.id,
      kind: r.kind,
      pubkey: r.pubkey,
      tags: r.tags,
    }),
  );

/** Parse a rumor out of decrypted bytes. */
export const rumorFromJSON = (bytes: Uint8Array): Result<string, Rumor> => {
  try {
    const v = JSON.parse(bytesToUtf8(bytes)) as Record<string, unknown>;
    if (
      typeof v.id !== 'string' ||
      typeof v.pubkey !== 'string' ||
      typeof v.created_at !== 'number' ||
      typeof v.kind !== 'number' ||
      !Array.isArray(v.tags) ||
      typeof v.content !== 'string'
    ) {
      return Err('decrypted rumor has the wrong shape');
    }
    return Ok(v as unknown as Rumor);
  } catch {
    return Err('decrypted rumor is not valid JSON');
  }
};

const eventBytes = (e: NostrEvent): Uint8Array => utf8ToBytes(JSON.stringify(e));

/**
 * Seal a rumor to one recipient. Signed by the real author, so the author is
 * public — but no `p` tag and encrypted content, so neither recipient nor
 * message is. `sealCreated` should differ from the rumor's timestamp:
 * reusing it would correlate the layers for a timing analysis.
 */
export const seal = (
  skHex: string,
  recipientHex: string,
  sealCreated: number,
  nonce: Uint8Array,
  rumor: Rumor,
): Result<string, NostrEvent> => {
  const payload = encryptWithNonce(skHex, recipientHex, nonce, rumorBytes(rumor));
  if (payload._tag === 'Err') return payload;
  return signUnsigned(skHex, {
    pubkey: '',
    created_at: sealCreated,
    kind: sealKind,
    tags: [],
    content: payload.value,
  });
};

/**
 * Open a seal, recovering the rumor. The signature verifies before anything
 * is decrypted, so a forged seal cannot make us derive key material for an
 * attacker-chosen pubkey. Tags must be empty and the seal's pubkey must match
 * the rumor's author — otherwise anyone could impersonate anyone by rewriting
 * the rumor's pubkey.
 */
export const unseal = (skHex: string, e: NostrEvent): Result<string, Rumor> => {
  if (e.kind !== sealKind) return Err('event is not a kind 13 seal');
  if (!verifyEvent(e)) return Err('seal signature is invalid');
  if (e.tags.length !== 0) return Err('a seal must have empty tags');
  const bytes = decrypt(skHex, e.pubkey, e.content);
  if (bytes._tag === 'Err') return bytes;
  const rumor = rumorFromJSON(bytes.value);
  if (rumor._tag === 'Err') return rumor;
  if (rumor.value.pubkey !== e.pubkey) return Err("seal pubkey does not match the rumor's author");
  return rumor;
};

const wrapWith = (
  kind: number,
  skHex: string,
  recipientHex: string,
  wrapCreated: number,
  nonce: Uint8Array,
  inner: NostrEvent,
): Result<string, NostrEvent> => {
  const payload = encryptWithNonce(skHex, recipientHex, nonce, eventBytes(inner));
  if (payload._tag === 'Err') return payload;
  return signUnsigned(skHex, {
    pubkey: '',
    created_at: wrapCreated,
    kind,
    tags: [['p', recipientHex]],
    content: payload.value,
  });
};

/**
 * Wrap a seal for one recipient, signed by a one-time key. The `p` tag is
 * the only routing information on the wire.
 */
export const wrap = (
  skHex: string,
  recipientHex: string,
  wrapCreated: number,
  nonce: Uint8Array,
  inner: NostrEvent,
): Result<string, NostrEvent> => wrapWith(wrapKind, skHex, recipientHex, wrapCreated, nonce, inner);

/** `wrap` at the ephemeral kind, for live chat relays should not store. */
export const wrapEphemeral = (
  skHex: string,
  recipientHex: string,
  wrapCreated: number,
  nonce: Uint8Array,
  inner: NostrEvent,
): Result<string, NostrEvent> => wrapWith(ephemeralWrapKind, skHex, recipientHex, wrapCreated, nonce, inner);

/**
 * Open a gift wrap, recovering the sealed event inside. Only the signature
 * is checked here; confirming the wrap was addressed to the opener is the
 * caller's job (see `wrapRecipient`), because that needs the recipient's
 * identity, not just the key.
 */
export const unwrap = (skHex: string, e: NostrEvent): Result<string, NostrEvent> => {
  if (e.kind !== wrapKind && e.kind !== ephemeralWrapKind) return Err('event is not a gift wrap');
  if (!verifyEvent(e)) return Err('gift wrap signature is invalid');
  const bytes = decrypt(skHex, e.pubkey, e.content);
  if (bytes._tag === 'Err') return bytes;
  try {
    return parseEvent(JSON.parse(bytesToUtf8(bytes.value)) as unknown);
  } catch {
    return Err('gift wrap content is not a valid event');
  }
};

export const isSeal = (e: Pick<NostrEvent, 'kind'>): boolean => e.kind === sealKind;
export const isWrap = (e: Pick<NostrEvent, 'kind'>): boolean => e.kind === wrapKind;
export const isEphemeralWrap = (e: Pick<NostrEvent, 'kind'>): boolean => e.kind === ephemeralWrapKind;

/**
 * The `p`-tagged recipient of a gift wrap, if it has exactly one. No tag is
 * unroutable and several is ambiguous rather than merely unusual, so both
 * are `undefined` and the caller decides.
 */
export const wrapRecipient = (e: Pick<NostrEvent, 'tags'>): string | undefined => {
  const ps = e.tags.filter((t) => t[0] === 'p' && t.length > 1 && t[1] !== '').map((t) => t[1]);
  return ps.length === 1 ? ps[0] : undefined;
};
