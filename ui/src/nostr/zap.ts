/**
 * NIP-57 lightning zaps.
 *
 * Two events with opposite visibility: a zap *request* (kind 9734) is
 * signed by the sender and sent to the recipient's LNURL callback, never
 * published; a zap *receipt* (kind 9735) is published by the recipient's
 * wallet after payment. The receipt names the recipient in `p`, the sender
 * in `P` when public, the invoice in `bolt11`, and the original request as
 * JSON in `description`.
 *
 * Fetching LNURL endpoints and paying invoices is async at the edge; parsing
 * and amount math are pure. A receipt is not proof of payment — trusting it
 * means trusting its author — so validation here is structural, and the UI
 * shows receipts as claims, not settlements.
 *
 * Mirrors `Krivostr.Nip.Nip57` on the Haskell side.
 */

import { NostrEvent, parseEvent } from './event';
import { decode as bech32Decode } from './bech32';
import { bytesToUtf8 } from '@noble/hashes/utils';
import { Result, Ok, Err } from '../fp/result';

/** Kind 9734: signed by the sender, sent to the LNURL callback. */
export const zapRequestKind = 9734;
/** Kind 9735: published by the recipient's wallet after payment. */
export const zapReceiptKind = 9735;

/** A parsed zap request. */
export interface ZapRequest {
  recipient: string;
  amountMsats: number | undefined;
  relays: string[];
  lnurl: string | undefined;
  event: string | undefined;
  address: string | undefined;
  comment: string;
}

const tag = (e: Pick<NostrEvent, 'tags'>, name: string): string | undefined => {
  const t = e.tags.find((x) => x[0] === name && x.length > 1);
  return t?.[1];
};

/** Parse a kind-9734 event. The recipient `p` tag is mandatory. */
export const zapRequestOf = (e: NostrEvent): ZapRequest | undefined => {
  if (e.kind !== zapRequestKind) return undefined;
  const recipient = tag(e, 'p');
  if (recipient === undefined) return undefined;
  const amountRaw = tag(e, 'amount');
  if (amountRaw !== undefined && !/^\d+$/.test(amountRaw)) return undefined;
  const relays = e.tags.find((x) => x[0] === 'relays')?.slice(1) ?? [];
  return {
    recipient,
    amountMsats: amountRaw !== undefined ? parseInt(amountRaw, 10) : undefined,
    relays,
    lnurl: tag(e, 'lnurl'),
    event: tag(e, 'e'),
    address: tag(e, 'a'),
    comment: e.content,
  };
};

/**
 * Tags for a zap request: relays, amount in millisats, recipient, and the
 * zapped event or address. The comment rides in the content.
 */
export const buildZapRequestTags = (
  recipient: string,
  msats: number,
  relays: string[],
  lnurl?: string,
  eventId?: string,
  address?: string,
): string[][] => {
  const tags: string[][] = [['relays', ...relays], ['amount', String(msats)], ['p', recipient]];
  if (lnurl !== undefined) tags.push(['lnurl', lnurl]);
  if (eventId !== undefined) tags.push(['e', eventId]);
  if (address !== undefined) tags.push(['a', address]);
  return tags;
};

/** A parsed zap receipt. */
export interface ZapReceipt {
  recipient: string;
  sender: string | undefined;
  event: string | undefined;
  address: string | undefined;
  bolt11: string;
  request: ZapRequest | undefined;
  preimage: string | undefined;
}

/** Parse a kind-9735 event. `p`, `bolt11`, and `description` are mandatory. */
export const zapReceiptOf = (e: NostrEvent): ZapReceipt | undefined => {
  if (e.kind !== zapReceiptKind) return undefined;
  const recipient = tag(e, 'p');
  const bolt11 = tag(e, 'bolt11');
  const desc = tag(e, 'description');
  if (recipient === undefined || bolt11 === undefined || desc === undefined) return undefined;
  let request: ZapRequest | undefined;
  try {
    const r = parseEvent(JSON.parse(desc) as unknown);
    request = r._tag === 'Ok' ? zapRequestOf(r.value) : undefined;
  } catch {
    request = undefined;
  }
  return {
    recipient,
    sender: tag(e, 'P'),
    event: tag(e, 'e'),
    address: tag(e, 'a'),
    bolt11,
    request,
    preimage: tag(e, 'preimage'),
  };
};

export const isZapReceipt = (e: NostrEvent): boolean => zapReceiptOf(e) !== undefined;

/**
 * Millisats encoded in a bolt11 invoice, if it encodes any. Invoices
 * without an amount are valid — any amount may be paid. See the Haskell
 * side for the divisibility rule; this mirrors it exactly.
 */
export const invoiceAmountMsats = (invoice: string): number | undefined => {
  if (!invoice.startsWith('ln')) return undefined;
  const rest = invoice.slice(2).replace(/^[a-z]+/, '');
  const digits = rest.match(/^\d+/)?.[0] ?? '';
  if (digits === '') return undefined;
  const base = parseInt(digits, 10) * 1e11;
  const mult = rest.slice(digits.length, digits.length + 1);
  if (mult === '' || !'munp'.includes(mult)) return base;
  if (mult === 'm') return base / 1e3;
  if (mult === 'u') return base / 1e6;
  if (mult === 'n') return base / 1e9;
  return base % 1e12 === 0 ? base / 1e12 : undefined;
};

/** Whole sats in an invoice, if it encodes a whole number of them. */
export const invoiceAmountSats = (invoice: string): number | undefined => {
  const msats = invoiceAmountMsats(invoice);
  if (msats === undefined || msats % 1000 !== 0) return undefined;
  return msats / 1000;
};

// ── LNURL flow ───────────────────────────────────────────────

/** LNURL-pay params fetched from the recipient's endpoint. */
export interface LnurlPayParams {
  callback: string;
  minSendable: number;
  maxSendable: number;
  metadata: string;
  nostrPubkey?: string;
  allowsNostr?: boolean;
}

/**
 * Resolve a lightning address (`name@domain`) or `lnurl…` bech32 to its
 * LNURL-pay HTTPS endpoint. `lud06` decodes to the URL; `lud16` maps to the
 * well-known path. Anything else is a usage error, not a fetch.
 */
export const lnurlPayUrl = (lud: string): Result<string, string> => {
  if (lud.startsWith('lnurl')) {
    try {
      const { bytes } = bech32Decode(lud);
      const url = bytesToUtf8(bytes);
      if (!url.startsWith('https://')) return Err('lnurl does not decode to an https URL');
      return Ok(url);
    } catch {
      return Err('invalid lnurl bech32');
    }
  }
  const parts = lud.split('@');
  if (parts.length === 2 && parts[0] !== '' && parts[1] !== '') {
    return Ok(`https://${parts[1]}/.well-known/lnurlp/${encodeURIComponent(parts[0])}`);
  }
  return Err('expected a lightning address (name@domain) or lnurl bech32');
};

/** Fetch and validate LNURL-pay params. Amounts arrive as millisats. */
export const fetchPayParams = async (url: string): Promise<Result<string, LnurlPayParams>> => {
  try {
    const res = await fetch(url, { headers: { Accept: 'application/json' } });
    if (!res.ok) return Err(`lnurl endpoint answered ${res.status}`);
    const doc = (await res.json()) as Record<string, unknown>;
    if (typeof doc.callback !== 'string') return Err('lnurl endpoint has no callback');
    if (typeof doc.minSendable !== 'number' || typeof doc.maxSendable !== 'number') {
      return Err('lnurl endpoint has no sendable range');
    }
    return Ok({
      callback: doc.callback,
      minSendable: doc.minSendable,
      maxSendable: doc.maxSendable,
      metadata: typeof doc.metadata === 'string' ? doc.metadata : '',
      nostrPubkey: typeof doc.nostrPubkey === 'string' ? doc.nostrPubkey : undefined,
      allowsNostr: doc.allowsNostr === true ? true : undefined,
    });
  } catch (e) {
    return Err(`lnurl fetch failed: ${String(e)}`);
  }
};

/**
 * Ask the callback for an invoice. `msats` and the signed zap request ride
 * as query params; the answer carries the bolt11 `pr`. Follows NIP-57
 * exactly: the request is sent, never published.
 */
export const requestInvoice = async (
  callback: string,
  msats: number,
  zapRequestJson: string,
): Promise<Result<string, string>> => {
  try {
    const url = `${callback}${callback.includes('?') ? '&' : '?'}amount=${msats}&nostr=${encodeURIComponent(zapRequestJson)}`;
    const res = await fetch(url, { headers: { Accept: 'application/json' } });
    if (!res.ok) return Err(`lnurl callback answered ${res.status}`);
    const doc = (await res.json()) as Record<string, unknown>;
    if (typeof doc.pr !== 'string') {
      return Err(typeof doc.reason === 'string' ? `lnurl refused: ${doc.reason}` : 'lnurl callback returned no invoice');
    }
    return Ok(doc.pr);
  } catch (e) {
    return Err(`invoice request failed: ${String(e)}`);
  }
};

/** Lightning addresses from a kind-0 profile JSON. `lud16` wins on ties. */
export const profileLud = (profileJson: string): string | undefined => {
  try {
    const p = JSON.parse(profileJson) as Record<string, unknown>;
    if (typeof p.lud16 === 'string' && p.lud16 !== '') return p.lud16;
    if (typeof p.lud06 === 'string' && p.lud06 !== '') return p.lud06;
    return undefined;
  } catch {
    return undefined;
  }
};
