/**
 * Signer plug-in. The publish boundary only ever sees a `Signer`.
 * Three implementations:
 *   - LocalSigner  — private key held in memory, decrypted from IndexedDB.
 *   - Nip07Signer  — delegates to window.nostr (browser extension).
 *   - Nip46Signer  — remote bunker over NIP-04-encrypted DMs.
 *
 * None of these touch the core event algebra except through `UnsignedEvent`
 * and the `Result` type.
 */

import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils';
import { NostrEvent, UnsignedEvent, computeId, canonicalBytes } from './event';
import { Result, Ok, Err } from '../fp/result';
import { RelayHandle, connect } from './relay';

export type SignerType = 'local' | 'nip07' | 'nip46';

export interface Signer {
  readonly type: SignerType;
  readonly pubkey: () => Promise<Result<string, string>>;
  readonly signEvent: (e: UnsignedEvent) => Promise<Result<string, NostrEvent>>;
}

// ── Local signer ───────────────────────────────────────────────

export const localSigner = (seckeyHex: string): Signer => {
  const sk = hexToBytes(seckeyHex);
  const pk = schnorr.getPublicKey(sk);
  const pkHex = bytesToHex(pk);

  return {
    type: 'local',
    pubkey: async () => Ok(pkHex),
    signEvent: async (u: UnsignedEvent): Promise<Result<string, NostrEvent>> => {
      try {
        const id = await computeId(u);
        const msgHash = sha256(canonicalBytes(u));
        const sig = schnorr.sign(msgHash, sk);
        return Ok({ ...u, id, sig: bytesToHex(sig) });
      } catch (e) {
        return Err(String(e));
      }
    },
  };
};

// ── NIP-07 signer ──────────────────────────────────────────────

interface Nip07Provider {
  getPublicKey(): Promise<string>;
  signEvent(e: UnsignedEvent): Promise<NostrEvent>;
}

declare global {
  interface Window {
    nostr?: Nip07Provider;
  }
}

export const nip07Signer = (): Signer => ({
  type: 'nip07',
  pubkey: async () => {
    if (!window.nostr) return Err('NIP-07 provider not found');
    try {
      return Ok(await window.nostr.getPublicKey());
    } catch (e) {
      return Err(String(e));
    }
  },
  signEvent: async (u) => {
    if (!window.nostr) return Err('NIP-07 provider not found');
    try {
      return Ok(await window.nostr.signEvent(u));
    } catch (e) {
      return Err(String(e));
    }
  },
});

export const isNip07Available = (): boolean =>
  typeof window !== 'undefined' && typeof window.nostr !== 'undefined';

// ── NIP-46 signer ──────────────────────────────────────────────

export interface BunkerConfig {
  remotePubkey: string;
  relay: string;
  secret?: string;
}

export const parseBunkerUrl = (raw: string): Result<string, BunkerConfig> => {
  if (!raw.startsWith('bunker://')) return Err('must start with bunker://');
  try {
    const u = new URL(raw);
    const remotePubkey = u.hostname;
    const relay = u.searchParams.get('relay');
    const secret = u.searchParams.get('secret') ?? undefined;
    if (!remotePubkey) return Err('missing remote pubkey');
    if (!relay) return Err('missing relay');
    return Ok({ remotePubkey, relay, secret });
  } catch (e) {
    return Err(String(e));
  }
};

/**
 * NIP-46 signer. Sends encrypted requests over the signer's relay and
 * awaits responses. Request ids are random 32-byte hex strings.
 *
 * This implementation uses NIP-04 encryption for the transport, which is
 * what the vast majority of bunkers currently speak. NIP-44 support is a
 * drop-in at the `encryptFor`/`decryptFrom` boundary.
 */
export const nip46Signer = async (
  cfg: BunkerConfig,
  localSecret: string,
  nip04: {
    encrypt: (sk: string, pk: string, plain: string) => Promise<string>;
    decrypt: (sk: string, pk: string, cipher: string) => Promise<string>;
  },
): Promise<Signer> => {
  // Establish the relay connection and a subscription to responses.
  const pending = new Map<string, (r: Result<string, string>) => void>();

  const onEvent = async (e: NostrEvent) => {
    if (e.kind !== 24133 || e.pubkey !== cfg.remotePubkey) return;
    try {
      const plain = await nip04.decrypt(localSecret, cfg.remotePubkey, e.content);
      const msg = JSON.parse(plain) as {
        id: string;
        result?: string;
        error?: string;
      };
      const cb = pending.get(msg.id);
      if (!cb) return;
      pending.delete(msg.id);
      if (msg.error) cb(Err(msg.error));
      else cb(Ok(msg.result ?? ''));
    } catch {
      /* ignore */
    }
  };

  const handle: RelayHandle = connect(cfg.relay, {
    onEvent: (e) => void onEvent(e),
    onState: () => undefined,
  });
  handle.subscribe('nip46', {
    kinds: [24133],
    authors: [cfg.remotePubkey],
  });

  const pubkeyP = schnorr.getPublicKey(hexToBytes(localSecret));
  const localPubkey = bytesToHex(pubkeyP);

  const send = async (method: string, params: unknown[]): Promise<Result<string, string>> => {
    const id = bytesToHex(crypto.getRandomValues(new Uint8Array(16)));
    const req = JSON.stringify({ id, method, params });
    const cipher = await nip04.encrypt(localSecret, cfg.remotePubkey, req);
    const ev: NostrEvent = {
      id: '',
      pubkey: localPubkey,
      created_at: Math.floor(Date.now() / 1000),
      kind: 24133,
      tags: [['p', cfg.remotePubkey]],
      content: cipher,
      sig: '',
    };
    // Sign with our local key so the bunker can authenticate us.
    const signed = await localSigner(localSecret).signEvent(ev);
    if (signed._tag === 'Err') return Err(signed.error);
    handle.publish(signed.value);

    return new Promise<Result<string, string>>((resolve) => {
      pending.set(id, resolve);
      setTimeout(() => {
        if (pending.has(id)) {
          pending.delete(id);
          resolve(Err('nip46 timeout'));
        }
      }, 30_000);
    });
  };

  return {
    type: 'nip46',
    pubkey: async () => {
      const r = await send('get_public_key', []);
      return r;
    },
    signEvent: async (u) => {
      const r = await send('sign_event', [JSON.stringify(u)]);
      if (r._tag === 'Err') return r;
      try {
        return Ok(JSON.parse(r.value) as NostrEvent);
      } catch (e) {
        return Err(String(e));
      }
    },
  };
};

// ── Publish ────────────────────────────────────────────────────

/**
 * The publish boundary: takes an unsigned event, a signer, and a relay
 * handle. Returns the signed event on success.
 */
export const publish = async (
  signer: Signer,
  relay: RelayHandle,
  u: UnsignedEvent,
): Promise<Result<string, NostrEvent>> => {
  const signed = await signer.signEvent(u);
  if (signed._tag === 'Err') return signed;
  relay.publish(signed.value);
  return signed;
};
