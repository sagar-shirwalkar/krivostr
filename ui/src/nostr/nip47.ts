/**
 * NIP-47 Nostr Wallet Connect: the client side of remote lightning.
 *
 * A `nostr+walletconnect://` URI carries the service's pubkey, its relays,
 * and a per-connection client secret that is both the signing key and half
 * of the NIP-44 conversation. Each call opens the first listed relay,
 * subscribes to the service's kind-23195 responses, publishes the encrypted
 * kind-23194 request, and waits for the first answer. Calls are
 * single-flight by construction, so no request/response correlation beyond
 * "the service answered" is needed.
 *
 * The secret never leaves memory and is never stored: it arrives pasted per
 * session (or per call) and dies with the tab. NIP-04 legacy mode is not
 * implemented — a service speaking only NIP-04 yields undecryptable
 * payloads, not a silent downgrade.
 *
 * Mirrors `Krivostr.Nip.Nip47` on the Haskell side, reusing `nip44.ts` for
 * the conversation so there is exactly one NIP-44 implementation to audit.
 */

import { connect, RelayHandle } from './relay';
import { localSigner } from './signer';
import { encryptWithNonce, decrypt, randomNonce } from './nip44';
import { Result, Ok, Err } from '../fp/result';

/** Kind 23194: client to wallet service. */
export const requestEventKind = 23194;
/** Kind 23195: wallet service to client. */
export const responseEventKind = 23195;
/** Kind 13194: the service's capability advertisement. */
export const infoEventKind = 13194;

/** A wallet connection: service pubkey, its relays, our secret. */
export interface WalletConn {
  walletPubkey: string;
  relays: string[];
  secret: string;
  lud16?: string;
}

/**
 * Parse a `nostr+walletconnect://` URI. Relay repeats; `secret` is
 * mandatory. Percent-encoding is decoded: relay URLs arrive encoded.
 */
export const parseWalletUri = (raw: string): Result<string, WalletConn> => {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return Err('not a nostr+walletconnect URI');
  }
  if (u.protocol !== 'nostr+walletconnect:') return Err('not a nostr+walletconnect URI');
  const pubkey = u.hostname;
  if (!/^[0-9a-f]{64}$/.test(pubkey)) return Err('wallet pubkey must be 64 hex characters');
  const secret = u.searchParams.get('secret') ?? '';
  if (!/^[0-9a-f]{64}$/.test(secret)) return Err('secret must be 64 hex characters');
  return Ok({
    walletPubkey: pubkey,
    relays: u.searchParams.getAll('relay').filter((r) => r !== ''),
    secret,
    lud16: u.searchParams.get('lud16') ?? undefined,
  });
};

/** The core wallet methods. */
export type NwMethod =
  | 'get_info' | 'get_balance' | 'pay_invoice' | 'multi_pay_invoice'
  | 'pay_keysend' | 'make_invoice' | 'lookup_invoice' | 'list_transactions'
  | 'sign_message';

export const allMethods: NwMethod[] = [
  'get_info', 'get_balance', 'pay_invoice', 'multi_pay_invoice', 'pay_keysend',
  'make_invoice', 'lookup_invoice', 'list_transactions', 'sign_message',
];

/** Map a wire string onto a method, rejecting anything unrecognised. */
export const methodFromText = (t: string): Result<string, NwMethod> =>
  (allMethods as string[]).includes(t) ? Ok(t as NwMethod) : Err(`unknown NIP-47 method: ${t}`);

/** The tags of a request event: NIP-44 mode plus the service's pubkey. */
export const buildRequestTags = (walletPubkey: string): string[][] => [
  ['encryption', 'nip44_v2'],
  ['p', walletPubkey],
];

/** A wallet error: machine code plus human message. */
export interface WalletError {
  code: string;
  message: string;
}

/** A response payload: result type plus either a result or an error. */
export interface NwResponse {
  type: NwMethod;
  result?: unknown;
  error?: WalletError;
}

/** Decode a decrypted response payload. */
export const parseResponse = (v: unknown): Result<string, NwResponse> => {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return Err('response is not an object');
  const o = v as Record<string, unknown>;
  if (typeof o.result_type !== 'string') return Err('response has no result_type');
  const method = methodFromText(o.result_type);
  if (method._tag === 'Err') return method;
  let error: WalletError | undefined;
  if (o.error !== undefined && o.error !== null) {
    const e = o.error as Record<string, unknown>;
    if (typeof e.code !== 'string' || typeof e.message !== 'string') return Err('response error is malformed');
    error = { code: e.code, message: e.message };
  }
  return Ok({ type: method.value, result: o.result, error });
};

/** The methods a kind-13194 info event advertises: content split on space. */
export const parseInfoMethods = (content: string): string[] =>
  content.split(/\s+/).filter((w) => w !== '');

/**
 * Run one wallet method and return its response. Opens the first listed
 * relay, subscribes before publishing (the service can answer faster than
 * a slow reader loops), waits up to `timeoutMs`, then hangs up. Wallet-side
 * errors arrive as `Err` naming the code.
 */
export const walletCall = async (
  conn: WalletConn,
  method: NwMethod,
  params: Record<string, unknown>,
  timeoutMs = 30_000,
): Promise<Result<string, NwResponse>> => {
  if (conn.relays.length === 0) return Err('wallet connection names no relay');
  const payload = JSON.stringify({ method, params });
  const encrypted = encryptWithNonce(conn.secret, conn.walletPubkey, randomNonce(), new TextEncoder().encode(payload));
  if (encrypted._tag === 'Err') return Err(`cannot encrypt request: ${encrypted.error}`);
  const signer = localSigner(conn.secret);
  const unsigned = {
    pubkey: '',
    created_at: Math.floor(Date.now() / 1000),
    kind: requestEventKind,
    tags: buildRequestTags(conn.walletPubkey),
    content: encrypted.value,
  };
  const signed = await signer.signEvent(unsigned);
  if (signed._tag === 'Err') return Err(`cannot sign request: ${signed.error}`);

  return new Promise((resolve) => {
    let handle: RelayHandle;
    const timer = setTimeout(() => {
      handle?.close();
      resolve(Err('wallet did not answer in time'));
    }, timeoutMs);
    const finish = (r: Result<string, NwResponse>): void => {
      clearTimeout(timer);
      handle.close();
      resolve(r);
    };
    try {
      handle = connect(conn.relays[0], {
        onEvent: (e) => {
          if (e.kind !== responseEventKind || e.pubkey !== conn.walletPubkey) return;
          const plain = decrypt(conn.secret, conn.walletPubkey, e.content);
          if (plain._tag === 'Err') {
            finish(Err(`cannot decrypt wallet response: ${plain.error}`));
            return;
          }
          let v: unknown;
          try {
            v = JSON.parse(new TextDecoder().decode(plain.value)) as unknown;
          } catch {
            finish(Err('bad wallet response'));
            return;
          }
          const res = parseResponse(v);
          if (res._tag === 'Err') {
            finish(res);
            return;
          }
          if (res.value.error) {
            finish(Err(`wallet refused: ${res.value.error.code}: ${res.value.error.message}`));
            return;
          }
          finish(Ok(res.value));
        },
        onState: () => undefined,
      });
    } catch (e) {
      clearTimeout(timer);
      resolve(Err(`cannot reach wallet relay: ${String(e)}`));
      return;
    }
    // Subscribe before publishing: the service can answer faster than a
    // slow reader loops, and a missed answer is a timeout, not a retry.
    handle.subscribe('nwc', { kinds: [responseEventKind], authors: [conn.walletPubkey] });
    handle.publish(signed.value);
  });
};
