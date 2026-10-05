/**
 * NIP-46 nostr-connect: the remote-signer protocol codec.
 *
 * This module is the protocol layer and nothing else — no socket, no relay
 * pool, no timer. What lives here is the JSON-RPC-ish payload: the method
 * table, request/response codecs, and the kind-24133 addressing rules. The
 * `p` tag names a different peer per direction: a request `p`-tags the
 * remote signer, a response `p`-tags the client. `requestPeer` and
 * `responsePeer` exist so that distinction cannot be got wrong at a call
 * site.
 *
 * Two notes carried over from the spec, because older descriptions still
 * widely copied contradict them: there is no `["NOSTR","NIP42",...]`
 * envelope — requests and responses are both kind 24133 events whose content
 * is a NIP-44 v2 payload wrapping a JSON object; and `sign_message`,
 * `get_relays`, and `close` are NOT methods — anything outside `allMethods`
 * is answered with an error (see `rejectPayload`).
 *
 * Mirrors `Krivostr.Nip.Nip46` on the Haskell side.
 */

import { NostrEvent } from './event';
import { encryptWithNonce, decrypt, randomNonce } from './nip44';
import { Result, Ok, Err } from '../fp/result';

/** Kind 24133 carries both requests and responses. */
export const requestEventKind = 24133;

/** The methods the current NIP-46 defines. `sign_event`, never `sign_message`. */
export type Method =
  | 'connect'
  | 'sign_event'
  | 'ping'
  | 'get_public_key'
  | 'nip04_encrypt'
  | 'nip04_decrypt'
  | 'nip44_encrypt'
  | 'nip44_decrypt'
  | 'switch_relays'
  | 'logout';

/** Every method, in the order the spec table lists them. */
export const allMethods: Method[] = [
  'connect',
  'sign_event',
  'ping',
  'get_public_key',
  'nip04_encrypt',
  'nip04_decrypt',
  'nip44_encrypt',
  'nip44_decrypt',
  'switch_relays',
  'logout',
];

/** Map a wire string onto a method, rejecting anything unrecognised. */
export const methodFromText = (t: string): Result<string, Method> =>
  (allMethods as string[]).includes(t) ? Ok(t as Method) : Err(`unknown NIP-46 method: ${t}`);

/**
 * A request as it travels: an id, a method, and the positional string array
 * exactly as it arrived. Keeping the raw list means a wrong arity is a
 * decode failure with a position in it, not a silently absent value.
 */
export interface ConnectRequest {
  id: string;
  method: Method;
  params: string[];
}

/** Decode a JSON value as a request. */
export const parseRequest = (v: unknown): Result<string, ConnectRequest> => {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return Err('request is not an object');
  const o = v as Record<string, unknown>;
  if (typeof o.id !== 'string') return Err('request id must be a string');
  if (typeof o.method !== 'string') return Err('request method must be a string');
  const method = methodFromText(o.method);
  if (method._tag === 'Err') return method;
  if (!Array.isArray(o.params) || !o.params.every((p) => typeof p === 'string')) {
    return Err('request params must be an array of strings');
  }
  return Ok({ id: o.id, method: method.value, params: o.params as string[] });
};

/** Encode a request to its JSON text, before NIP-44. */
export const encodeRequest = (r: ConnectRequest): string =>
  JSON.stringify({ id: r.id, method: r.method, params: r.params });

/** A response: an id with either a result or an error. */
export interface ConnectResponse {
  id: string;
  result?: string;
  error?: string;
}

/** Decode a JSON value as a response. */
export const parseResponse = (v: unknown): Result<string, ConnectResponse> => {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return Err('response is not an object');
  const o = v as Record<string, unknown>;
  if (typeof o.id !== 'string') return Err('response id must be a string');
  if (o.result !== undefined && typeof o.result !== 'string') return Err('response result must be a string');
  if (o.error !== undefined && typeof o.error !== 'string') return Err('response error must be a string');
  return Ok({ id: o.id, result: o.result as string | undefined, error: o.error as string | undefined });
};

/** Encode a response to its JSON text, before NIP-44. */
export const encodeResponse = (r: ConnectResponse): string =>
  JSON.stringify({ id: r.id, ...(r.result !== undefined ? { result: r.result } : {}), ...(r.error !== undefined ? { error: r.error } : {}) });

/**
 * The `auth_url` challenge: when the result is `auth_url` and an error is
 * present, the error carries the URL the user must visit.
 */
export const authChallengeUrl = (r: ConnectResponse): string | undefined =>
  r.result === 'auth_url' && r.error !== undefined ? r.error : undefined;

/** The error response the spec requires for an unparseable payload. */
export const rejectPayload = (id: string, reason: string): string =>
  encodeResponse({ id, error: reason });

/** The request's peer: its `p` tag, which names the remote signer. */
export const requestPeer = (e: Pick<NostrEvent, 'tags'>): string | undefined => {
  const p = e.tags.find((t) => t[0] === 'p' && t.length > 1 && t[1] !== '');
  return p?.[1];
};

/** The response's peer: its author, which names the client. */
export const responsePeer = (e: Pick<NostrEvent, 'pubkey'>): string => e.pubkey;

/**
 * NIP-44 transport for `nip46Signer`: encrypt to / decrypt from the remote
 * peer with a fresh random nonce per message. This is what the vast majority
 * of bunkers currently speak NIP-04 for — passing this adapter instead of a
 * NIP-04 pair switches the signer to the spec-current transport at the
 * existing `encryptFor`/`decryptFrom` boundary, with no change to the signer.
 */
export const nip44Transport = (
  localSecret: string,
  remotePubkey: string,
): {
  encrypt: (sk: string, pk: string, plain: string) => Promise<string>;
  decrypt: (sk: string, pk: string, cipher: string) => Promise<string>;
} => ({
  encrypt: async (_sk, _pk, plain) => {
    const r = encryptWithNonce(localSecret, remotePubkey, randomNonce(), new TextEncoder().encode(plain));
    if (r._tag === 'Err') throw new Error(r.error);
    return r.value;
  },
  decrypt: async (_sk, _pk, cipher) => {
    const r = decrypt(localSecret, remotePubkey, cipher);
    if (r._tag === 'Err') throw new Error(r.error);
    return new TextDecoder().decode(r.value);
  },
});
