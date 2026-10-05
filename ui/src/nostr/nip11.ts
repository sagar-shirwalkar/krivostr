/**
 * NIP-11 relay information document.
 *
 * Relays serve this JSON at their WebSocket root when the HTTP request
 * carries `Accept: application/nostr+json`. Every field is optional — a relay
 * may return any subset — so the type makes optionality explicit with `?`
 * rather than inventing defaults.
 *
 * Mirrors `Krivostr.Nip.Nip11` on the Haskell side.
 */

import { Result, Ok, Err } from '../fp/result';

/** Server limitations a relay may impose on clients. All optional. */
export interface Limitation {
  maxMessageLength?: number;
  maxSubscriptions?: number;
  maxFilters?: number;
  maxLimit?: number;
  maxSubidLength?: number;
  minPrefix?: number;
  maxEventTags?: number;
  maxContentLength?: number;
  minPowDifficulty?: number;
  authRequired?: boolean;
  paymentRequired?: boolean;
  restrictedWrites?: boolean;
  createdAtLowerLimit?: number;
  createdAtUpperLimit?: number;
  defaultLimit?: number;
}

/** Relay information document. All fields optional per the spec. */
export interface RelayInfo {
  name?: string;
  description?: string;
  banner?: string;
  icon?: string;
  pubkey?: string;
  self?: string;
  contact?: string;
  supportedNips?: number[];
  software?: string;
  version?: string;
  termsOfService?: string;
  limitation?: Limitation;
}

const isRecord = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v);

const optString = (o: Record<string, unknown>, k: string): string | undefined =>
  typeof o[k] === 'string' ? (o[k] as string) : undefined;

const optNumber = (o: Record<string, unknown>, k: string): number | undefined =>
  typeof o[k] === 'number' ? (o[k] as number) : undefined;

const optBoolean = (o: Record<string, unknown>, k: string): boolean | undefined =>
  typeof o[k] === 'boolean' ? (o[k] as boolean) : undefined;

/**
 * Validate an untrusted value as a `RelayInfo`.
 *
 * Structural only: unknown fields are ignored, mistyped known fields are
 * dropped rather than failing the whole document, because relays in the wild
 * return arbitrary subsets with occasional vendor extensions.
 */
export const parseRelayInfo = (v: unknown): Result<string, RelayInfo> => {
  if (!isRecord(v)) return Err('relay info is not an object');
  const info: RelayInfo = {};
  const s = (k: string, out: string): void => {
    const val = optString(v, k);
    if (val !== undefined) (info as Record<string, unknown>)[out] = val;
  };
  s('name', 'name');
  s('description', 'description');
  s('banner', 'banner');
  s('icon', 'icon');
  s('pubkey', 'pubkey');
  s('self', 'self');
  s('contact', 'contact');
  s('software', 'software');
  s('version', 'version');
  s('terms_of_service', 'termsOfService');
  if (Array.isArray(v.supported_nips) && v.supported_nips.every((n) => typeof n === 'number')) {
    info.supportedNips = v.supported_nips as number[];
  }
  if (isRecord(v.limitation)) {
    const l = v.limitation;
    const lim: Limitation = {};
    const numKeys: Array<[string, keyof Limitation]> = [
      ['max_message_length', 'maxMessageLength'],
      ['max_subscriptions', 'maxSubscriptions'],
      ['max_filters', 'maxFilters'],
      ['max_limit', 'maxLimit'],
      ['max_subid_length', 'maxSubidLength'],
      ['min_prefix', 'minPrefix'],
      ['max_event_tags', 'maxEventTags'],
      ['max_content_length', 'maxContentLength'],
      ['min_pow_difficulty', 'minPowDifficulty'],
      ['created_at_lower_limit', 'createdAtLowerLimit'],
      ['created_at_upper_limit', 'createdAtUpperLimit'],
      ['default_limit', 'defaultLimit'],
    ];
    for (const [raw, key] of numKeys) {
      const n = optNumber(l, raw);
      if (n !== undefined) (lim as Record<string, unknown>)[key as string] = n;
    }
    const boolKeys: Array<[string, keyof Limitation]> = [
      ['auth_required', 'authRequired'],
      ['payment_required', 'paymentRequired'],
      ['restricted_writes', 'restrictedWrites'],
    ];
    for (const [raw, key] of boolKeys) {
      const b = optBoolean(l, raw);
      if (b !== undefined) (lim as Record<string, unknown>)[key as string] = b;
    }
    info.limitation = lim;
  }
  return Ok(info);
};

/** Parse a relay info document from its JSON text. */
export const decodeRelayInfo = (json: string): Result<string, RelayInfo> => {
  try {
    return parseRelayInfo(JSON.parse(json) as unknown);
  } catch (e) {
    return Err(`invalid relay info JSON: ${String(e)}`);
  }
};

/** True when the relay advertises support for `nip`. Absent list means no. */
export const supportsNip = (nip: number, info: RelayInfo): boolean =>
  info.supportedNips !== undefined && info.supportedNips.includes(nip);
