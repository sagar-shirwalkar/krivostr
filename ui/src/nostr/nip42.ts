/**
 * NIP-42 authentication of clients to relays.
 *
 * The relay sends `["AUTH", <challenge>]`; the client answers with
 * `["AUTH", <signed event>]` where the event is kind 22242 with
 * `[["relay", <url>], ["challenge", <challenge>]]` tags, signed by the
 * client's key. The event is ephemeral and never stored.
 *
 * The timestamp is a parameter rather than read from the clock so the module
 * stays pure and tests stay deterministic. Signing itself is injected for the
 * same reason: this module builds the unsigned event, the caller signs it
 * with whatever signer is selected.
 *
 * Mirrors `Krivostr.Nip.Nip42` on the Haskell side.
 */

import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex } from '@noble/hashes/utils';
import { NostrEvent, UnsignedEvent, canonicalBytes, tagValue } from './event';
import { Result, Ok, Err } from '../fp/result';

/** Build the unsigned kind-22242 AUTH event for this relay and challenge. */
export const buildAuthUnsigned = (
  relayUrl: string,
  challenge: string,
  createdAt: number,
  pubkey: string,
): UnsignedEvent => ({
  pubkey,
  created_at: createdAt,
  kind: 22242,
  tags: [
    ['relay', relayUrl],
    ['challenge', challenge],
  ],
  content: '',
});

/** The relay URL from the AUTH event's `relay` tag. */
export const authEventRelay = (e: Pick<NostrEvent, 'tags'>): Result<string, string> => {
  const url = tagValue(e, 'relay');
  if (url === undefined) return Err('missing relay tag');
  if (url === '') return Err('empty relay tag');
  return Ok(url);
};

/** The challenge from the AUTH event's `challenge` tag. */
export const authEventChallenge = (e: Pick<NostrEvent, 'tags'>): Result<string, string> => {
  const chal = tagValue(e, 'challenge');
  if (chal === undefined) return Err('missing challenge tag');
  if (chal === '') return Err('empty challenge tag');
  return Ok(chal);
};

/**
 * Validate an AUTH event against the expected relay, challenge, and clock.
 *
 * Checks kind, tags, and freshness (within `maxAgeSeconds`, with 30s of
 * future skew for clock differences), then the id and Schnorr signature.
 * Each failure names itself so a relay's `auth-required:` notice can say why.
 */
export const validateAuthEvent = (
  expectedRelay: string,
  expectedChallenge: string,
  now: number,
  maxAgeSeconds: number,
  e: NostrEvent,
): Result<string, void> => {
  if (e.kind !== 22242) return Err('wrong kind (must be 22242)');
  const relay = authEventRelay(e);
  if (relay._tag === 'Err') return relay;
  const chal = authEventChallenge(e);
  if (chal._tag === 'Err') return chal;
  if (relay.value !== expectedRelay) return Err('relay tag mismatch');
  if (chal.value !== expectedChallenge) return Err('challenge mismatch');
  if (e.created_at > now + 30) return Err('event created in the future');
  if (now - e.created_at > maxAgeSeconds) return Err('event too old');
  try {
    const id = bytesToHex(sha256(canonicalBytes(e)));
    if (id !== e.id) return Err('bad event id');
    const valid = schnorr.verify(e.sig, id, e.pubkey);
    if (!valid) return Err('bad signature');
  } catch {
    return Err('bad signature or invalid id');
  }
  return Ok(undefined);
};

/** The `auth-required: <reason>` notice prefix from NIP-42. */
export const authRequiredNotice = (reason: string): string => `auth-required: ${reason}`;

/** The `restricted: <reason>` notice prefix from NIP-42. */
export const restrictedNotice = (reason: string): string => `restricted: ${reason}`;

/** True when the relay message is an AUTH challenge; the challenge if so. */
export const parseAuthChallenge = (msg: unknown): string | undefined => {
  if (!Array.isArray(msg) || msg[0] !== 'AUTH' || typeof msg[1] !== 'string') return undefined;
  return msg[1];
};
