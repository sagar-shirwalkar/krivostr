/**
 * NIP-49 encrypted private keys: the `ncryptsec1` bech32 payload.
 *
 * A transport encoding, NOT encryption at rest. The payload carries the
 * password-derived key's cost parameters in the clear, so anyone holding the
 * `ncryptsec1` string can attack the password offline; keep the decrypted
 * secret in a store that protects it, and use this to move it between
 * machines.
 *
 * Scheme: `scrypt` then XChaCha20-Poly1305, bech32 payload byte for byte:
 * `version(1) = 0x02 || log_n(1) || salt(16) || nonce(24) ||
 *  key_security_byte(1) || ciphertext(32) || tag(16)` — 91 bytes before
 * bech32.
 *
 * Salt and nonce are injected rather than generated, keeping the module pure
 * and the spec's published vector reproducible; the caller draws both from
 * the OS CSPRNG. Every failure is an `Err`.
 *
 * One deliberate difference from the Haskell core: the spec asks for NFKC
 * normalisation of the password before UTF-8 encoding, which `text` cannot
 * do without a new dependency, so the Haskell caller must normalise. JS has
 * `String.normalize('NFKC')` built in, so this module normalises itself.
 *
 * Mirrors `Krivostr.Nip.Nip49` on the Haskell side.
 */

import { scrypt } from '@noble/hashes/scrypt';
import { xchacha20poly1305 } from '@noble/ciphers/chacha';
import { encode, decode } from './bech32';
import { Result, Ok, Err } from '../fp/result';

/** The version byte every NIP-49 payload leads with. Only 0x02 exists. */
const ncryptsecVersion = 0x02;

/** Fixed sizes from the spec. */
const saltLength = 16;
const nonceLength = 24;
const privateKeyLength = 32;
/** version + log_n + salt + nonce + security byte + ciphertext + tag. */
const payloadLength = 91;
/** Longest text decoded at all: a resource guard before bech32 runs. */
const maxNcryptsecChars = 1024;

/** Smallest accepted `n = 2^log_n`. */
const minLogN = 1;
/** Largest accepted `log_n`: 2^22 is the top of the spec's own table. */
const maxLogN = 22;
/** Hard ceiling on scrypt memory: 2^32, the cost of the largest `log_n`. */
const maxScryptMemoryBytes = 4294967296;

/** `log_n = 16`, `p = 1`: 64 MiB, ~100ms. The spec default and the vector. */
export const defaultLogN = 16;

/** Whether the caller believes the secret was ever handled in the clear. */
export type KeySecurity = 'insecure' | 'secure' | 'untracked';

const keySecurityByte = (s: KeySecurity): number =>
  s === 'insecure' ? 0x00 : s === 'secure' ? 0x01 : 0x02;

const keySecurityFromByte = (b: number): Result<string, KeySecurity> => {
  if (b === 0x00) return Ok('insecure');
  if (b === 0x01) return Ok('secure');
  if (b === 0x02) return Ok('untracked');
  return Err(`undefined NIP-49 key security byte ${b}`);
};

/** A decrypted `ncryptsec` payload. `logN` rides along with the result. */
export interface Ncryptsec {
  seckeyHex: string;
  logN: number;
  keySecurity: KeySecurity;
}

/** Draw fresh salt (16) and nonce (24) bytes from the CSPRNG. The IO edge. */
export const randomSaltNonce = (): { salt: Uint8Array; nonce: Uint8Array } => ({
  salt: crypto.getRandomValues(new Uint8Array(saltLength)),
  nonce: crypto.getRandomValues(new Uint8Array(nonceLength)),
});

/**
 * Derive the 32-byte symmetric key. `logN` is validated before scrypt runs:
 * it arrives inside an attacker-supplied payload on decrypt, and an
 * unchecked `log_n = 30` would ask for a terabyte of allocation.
 */
const symmetricKey = (password: string, salt: Uint8Array, logN: number): Result<string, Uint8Array> => {
  if (!Number.isInteger(logN) || logN < minLogN || logN > maxLogN) {
    return Err('NIP-49 payload claims an out-of-range scrypt log_n');
  }
  const n = 2 ** logN;
  if (128 * n * 8 + 256 * 8 * 1 > maxScryptMemoryBytes) {
    return Err('scrypt parameters exceed the accepted memory budget');
  }
  if (salt.length !== saltLength) return Err('NIP-49 salt must be 16 bytes');
  try {
    // NFKC first: the same password typed on two machines must derive the
    // same key. Only visible for compatibility characters.
    return Ok(scrypt(password.normalize('NFKC'), salt, { N: n, r: 8, p: 1, dkLen: 32 }));
  } catch {
    return Err('scrypt key derivation failed');
  }
};

/**
 * Encrypt a 32-byte secret under `password` into an `ncryptsec1` string.
 * Salt and nonce must be fresh random bytes, never reused for another
 * encryption: a repeated (key, nonce) pair leaks the keystream.
 */
export const encryptNcryptsec = (
  seckeyHex: string,
  password: string,
  logN: number,
  keySecurity: KeySecurity,
  salt: Uint8Array,
  nonce: Uint8Array,
): Result<string, string> => {
  if (!/^[0-9a-f]{64}$/.test(seckeyHex)) return Err('secret key must be 64 hex characters');
  if (nonce.length !== nonceLength) return Err('NIP-49 nonce must be 24 bytes');
  const key = symmetricKey(password, salt, logN);
  if (key._tag === 'Err') return key;
  const secByte = keySecurityByte(keySecurity);
  const seckey = Uint8Array.from(
    seckeyHex.match(/../g)!.map((h) => parseInt(h, 16)),
  );
  const sealed = xchacha20poly1305(key.value, nonce, Uint8Array.of(secByte)).encrypt(seckey);
  const payload = new Uint8Array(payloadLength);
  payload[0] = ncryptsecVersion;
  payload[1] = logN;
  payload.set(salt, 2);
  payload.set(nonce, 2 + saltLength);
  payload.set([secByte], 2 + saltLength + nonceLength);
  payload.set(sealed, 2 + saltLength + nonceLength + 1);
  return Ok(encode('ncryptsec', payload));
};

/**
 * Decrypt an `ncryptsec1` payload with `password`.
 *
 * Length, hrp, version, the `log_n` claim and every field width settle before
 * a byte of key material is derived, so a malformed payload cannot make us
 * spend scrypt's memory or time.
 */
export const decryptNcryptsec = (payload: string, password: string): Result<string, Ncryptsec> => {
  if (payload.length > maxNcryptsecChars) return Err('NIP-49 payload exceeds the accepted size');
  let decoded: { hrp: string; bytes: Uint8Array };
  try {
    decoded = decode(payload);
  } catch {
    return Err('invalid bech32 payload');
  }
  if (decoded.hrp !== 'ncryptsec') return Err('wrong hrp');
  if (decoded.bytes.length !== payloadLength) {
    return Err(`NIP-49 payload must be ${payloadLength} bytes`);
  }
  const bytes = decoded.bytes;
  if (bytes[0] !== ncryptsecVersion) return Err('unsupported NIP-49 payload version');
  const logN = bytes[1];
  const salt = bytes.subarray(2, 2 + saltLength);
  const nonce = bytes.subarray(2 + saltLength, 2 + saltLength + nonceLength);
  const secByte = bytes[2 + saltLength + nonceLength];
  const sealed = bytes.subarray(2 + saltLength + nonceLength + 1);
  const security = keySecurityFromByte(secByte);
  if (security._tag === 'Err') return security;
  // Bound the attacker's own cost claim before deriving anything from it.
  const key = symmetricKey(password, salt, logN);
  if (key._tag === 'Err') return key;
  try {
    const plaintext = xchacha20poly1305(key.value, nonce, Uint8Array.of(secByte)).decrypt(sealed);
    if (plaintext.length !== privateKeyLength) return Err('decrypted NIP-49 key must be 32 bytes');
    return Ok({
      seckeyHex: [...plaintext].map((b) => b.toString(16).padStart(2, '0')).join(''),
      logN,
      keySecurity: security.value,
    });
  } catch {
    return Err('NIP-49 authentication tag mismatch');
  }
};
