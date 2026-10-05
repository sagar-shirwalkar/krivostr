/**
 * NIP-44 v2 encrypted payloads.
 *
 * Deliberately not an AEAD: raw ChaCha20 for confidentiality plus
 * HMAC-SHA256 for integrity, with the aad supplied as a concatenation rather
 * than through a cipher mode. That is why this module reaches for
 * `@noble/ciphers/chacha` (the raw stream) instead of `chacha20poly1305` — an
 * AEAD here would put a Poly1305 tag on the wire where the spec expects an
 * HMAC, and every other implementation would reject the payload.
 *
 * Wire format, standard base64 with padding:
 * `version(1) = 0x02 || nonce(32) || ciphertext || mac(32)`
 *
 * The nonce is injected rather than generated so the module stays pure and
 * the published test vectors stay reproducible; the caller draws it from
 * `crypto.getRandomValues` (see `randomNonce`).
 *
 * New runtime dependency, and why: `@noble/ciphers` is noble's audited home
 * for ChaCha20/XChaCha20-Poly1305. `@noble/hashes` (already carried) has no
 * stream cipher, and WebCrypto has neither raw ChaCha20 nor XChaCha20, so
 * NIP-44 and NIP-49 cannot be built without it.
 *
 * Mirrors `Krivostr.Nip.Nip44` on the Haskell side, including its two guards
 * over the reference spec: the short-ciphertext length check and the
 * pre-decode payload-size bound.
 */

import { secp256k1 } from '@noble/curves/secp256k1';
import { hmac } from '@noble/hashes/hmac';
import { extract, expand } from '@noble/hashes/hkdf';
import { sha256 } from '@noble/hashes/sha256';
import { concatBytes, hexToBytes, utf8ToBytes } from '@noble/hashes/utils';
import { chacha20 } from '@noble/ciphers/chacha';
import { Result, Ok, Err } from '../fp/result';

/** The version byte leading every v2 payload. 0x00/0x01 are never accepted. */
export const payloadVersion = 0x02;

/** HKDF-Extract is salted with the literal UTF-8 bytes of this string. */
const conversationKeySalt = utf8ToBytes('nip44-v2');

/** Largest base64 payload accepted, in bytes of base64 text. A resource guard. */
export const maxPayloadBytes = 1024 * 1024;

/** Shortest payload holding version + nonce + mac. */
const minPayloadBytes = 132;

/** Smallest padded plaintext, and the floor `calcPaddedLen` returns. */
const minPaddedLength = 32;

/** Largest plaintext: the extended length prefix is a u32. */
export const maxPlaintextLength = 4294967295;

/** Draw 32 fresh nonce bytes from the platform CSPRNG. The IO boundary. */
export const randomNonce = (): Uint8Array => crypto.getRandomValues(new Uint8Array(32));

const bytesToBase64 = (bytes: Uint8Array): string => {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
};

const base64ToBytes = (s: string): Result<string, Uint8Array> => {
  try {
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return Ok(out);
  } catch {
    return Err('invalid base64 payload');
  }
};

/** Constant-time compare: no early exit, so a forgery leaks nothing. */
const constEq = (a: Uint8Array, b: Uint8Array): boolean => {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
};

/**
 * The 32-byte conversation key from our secret and a peer's x-only pubkey.
 * Symmetric: both sides reach the same bytes because ECDH is, using only the
 * x coordinate of the shared point.
 */
export const conversationKey = (skHex: string, peerHex: string): Result<string, Uint8Array> => {
  try {
    const sk = hexToBytes(skHex);
    const peer = hexToBytes(peerHex);
    if (peer.length !== 32) return Err('peer pubkey must be 32 bytes');
    // Lift the x-only key to a compressed point; prefix parity is irrelevant
    // because only the shared x coordinate is used.
    const shared = secp256k1.getSharedSecret(sk, concatBytes(new Uint8Array([2]), peer));
    const sharedX = shared.subarray(1, 33);
    return Ok(extract(sha256, sharedX, conversationKeySalt));
  } catch {
    return Err('peer public key is not a valid curve point');
  }
};

/** The three keys one message derives from the conversation key and nonce. */
export interface MessageKeys {
  chachaKey: Uint8Array;
  chachaNonce: Uint8Array;
  hmacKey: Uint8Array;
}

/**
 * Expand the conversation key into the 76 bytes NIP-44 slices into
 * chacha_key[0:32], chacha_nonce[32:44], hmac_key[44:76].
 *
 * The nonce doubles as HKDF info and HMAC aad, binding a ciphertext to the
 * message it was produced under: a payload encrypted under one nonce cannot
 * be replayed as if it belonged to another.
 */
export const messageKeys = (convKey: Uint8Array, nonce: Uint8Array): Result<string, MessageKeys> => {
  if (convKey.length !== 32) return Err('conversation key must be 32 bytes');
  if (nonce.length !== 32) return Err('nonce must be 32 bytes');
  const okm = expand(sha256, convKey, nonce, 76);
  return Ok({
    chachaKey: okm.subarray(0, 32),
    chachaNonce: okm.subarray(32, 44),
    hmacKey: okm.subarray(44, 76),
  });
};

const floorLog2 = (n: number): number => {
  let acc = 0;
  let m = n;
  while (m > 1) {
    acc += 1;
    m = Math.floor(m / 2);
  }
  return acc;
};

/**
 * `calc_padded_len` from the spec: chunks of 32 up to 256 bytes of plaintext,
 * powers of two divided by 8 beyond. Padding hides the plaintext length; the
 * schedule leaks only "same chunk", not "same length".
 */
export const calcPaddedLen = (unpaddedLen: number): number => {
  if (unpaddedLen <= minPaddedLength) return minPaddedLength;
  const nextPower = 2 ** (floorLog2(unpaddedLen - 1) + 1);
  const chunk = nextPower <= 256 ? 32 : nextPower / 8;
  return chunk * (Math.floor((unpaddedLen - 1) / chunk) + 1);
};

/** Prepend the big-endian length prefix, then zero-fill to `calcPaddedLen`. */
export const pad = (msg: Uint8Array): Result<string, Uint8Array> => {
  const len = msg.length;
  if (len < 1) return Err('plaintext must not be empty');
  if (len > maxPlaintextLength) return Err('plaintext exceeds the NIP-44 maximum');
  const paddedLen = calcPaddedLen(len);
  const prefix =
    len < 65536
      ? Uint8Array.of(len >>> 8, len & 0xff)
      : Uint8Array.of(0, 0, (len >>> 24) & 0xff, (len >>> 16) & 0xff, (len >>> 8) & 0xff, len & 0xff);
  const out = new Uint8Array(prefix.length + paddedLen);
  out.set(prefix, 0);
  out.set(msg, prefix.length);
  return Ok(out);
};

/** Strip prefix and padding, rejecting anything whose bytes disagree. */
export const unpad = (padded: Uint8Array): Result<string, Uint8Array> => {
  if (padded.length < 2) return Err('padded plaintext is shorter than its length prefix');
  const short = padded[0] * 256 + padded[1];
  let prefixLen: number;
  let declared: number;
  if (short !== 0) {
    prefixLen = 2;
    declared = short;
  } else {
    if (padded.length < 6) return Err('payload is too short to hold a length prefix');
    prefixLen = 6;
    declared = padded[2] * 2 ** 24 + padded[3] * 2 ** 16 + padded[4] * 256 + padded[5];
  }
  if (declared < 1) return Err('plaintext length prefix is zero');
  if (declared > maxPlaintextLength) return Err('plaintext exceeds the NIP-44 maximum');
  if (prefixLen + 1 > padded.length) return Err('padded plaintext is shorter than its length prefix');
  if (declared > padded.length - prefixLen) return Err('declared plaintext is longer than the payload');
  if (padded.length !== prefixLen + calcPaddedLen(declared)) {
    return Err('padded length does not match calc_padded_len');
  }
  const body = padded.subarray(prefixLen, prefixLen + declared);
  const padding = padded.subarray(prefixLen + declared);
  if (!padding.every((b) => b === 0)) return Err('padding is not all zero bytes');
  return Ok(body.slice());
};

const hmacAead = (key: Uint8Array, aad: Uint8Array, message: Uint8Array): Uint8Array =>
  hmac(sha256, key, concatBytes(aad, message));

/**
 * Encrypt `plaintext` to the peer and return the base64 payload.
 *
 * The nonce must be 32 fresh random bytes never before used with this
 * conversation key — reuse exposes the keystream and forges the HMAC — so
 * this function will not generate one. Draw with `randomNonce`.
 */
export const encryptWithNonce = (
  skHex: string,
  peerHex: string,
  nonce: Uint8Array,
  plaintext: Uint8Array,
): Result<string, string> => {
  const ck = conversationKey(skHex, peerHex);
  if (ck._tag === 'Err') return ck;
  const padded = pad(plaintext);
  if (padded._tag === 'Err') return padded;
  const keys = messageKeys(ck.value, nonce);
  if (keys._tag === 'Err') return keys;
  const ciphertext = chacha20(keys.value.chachaKey, keys.value.chachaNonce, padded.value);
  const mac = hmacAead(keys.value.hmacKey, nonce, ciphertext);
  return Ok(bytesToBase64(concatBytes(Uint8Array.of(payloadVersion), nonce, ciphertext, mac)));
};

/**
 * Decrypt a base64 payload `skHex` should be able to read, given the hex
 * pubkey of the sender.
 *
 * Order is deliberate: size bound before base64 runs, minimum length and
 * version before key derivation, constant-time MAC before ChaCha20.
 */
export const decrypt = (skHex: string, peerHex: string, payload: string): Result<string, Uint8Array> => {
  if (utf8ToBytes(payload).length > maxPayloadBytes) {
    return Err('NIP-44 payload exceeds the accepted size');
  }
  if (payload.startsWith('#')) return Err('unsupported NIP-44 payload version');
  // Short-ciphertext guard: the bound is on the base64 text, before the
  // decoder runs — decoding allocates before anything is authenticated.
  if (utf8ToBytes(payload).length < minPayloadBytes) {
    return Err('NIP-44 payload is too short to hold a version, nonce and mac');
  }
  const raw = base64ToBytes(payload);
  if (raw._tag === 'Err') return raw;
  if (raw.value[0] !== payloadVersion) return Err('unsupported NIP-44 payload version');
  const nonce = raw.value.subarray(1, 33);
  const rest = raw.value.subarray(33);
  const ciphertext = rest.subarray(0, rest.length - 32);
  const macPart = rest.subarray(rest.length - 32);
  if (ciphertext.length < minPaddedLength) return Err('NIP-44 ciphertext is too short');
  const ck = conversationKey(skHex, peerHex);
  if (ck._tag === 'Err') return ck;
  const keys = messageKeys(ck.value, nonce);
  if (keys._tag === 'Err') return keys;
  const mac = hmacAead(keys.value.hmacKey, nonce, ciphertext);
  if (!constEq(mac, macPart)) return Err('NIP-44 mac mismatch');
  return unpad(chacha20(keys.value.chachaKey, keys.value.chachaNonce, ciphertext));
};

/** Convenience: encrypt a UTF-8 string. */
export const encryptString = (
  skHex: string,
  peerHex: string,
  nonce: Uint8Array,
  plaintext: string,
): Result<string, string> => encryptWithNonce(skHex, peerHex, nonce, utf8ToBytes(plaintext));
