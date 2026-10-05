/**
 * BIP-173 Bech32, hand-rolled. Encodes/decodes npub, nsec, note, nprofile,
 * nevent, naddr. No external dependencies.
 *
 * References:
 *   https://github.com/bitcoin/bips/blob/master/bip-0173.mediawiki
 */

const CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const CHARSET_MAP = new Map<string, number>(
  [...CHARSET].map((c, i) => [c, i]),
);
const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];

export type Bech32Hrp = 'npub' | 'nsec' | 'note' | 'nprofile' | 'nevent' | 'naddr';

export interface Bech32Decoded {
  hrp: string;
  bytes: Uint8Array;
}

const polymod = (values: number[]): number => {
  let chk = 1;
  for (const v of values) {
    const top = chk >>> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (let i = 0; i < 5; i++) if ((top >> i) & 1) chk ^= GEN[i];
  }
  return chk >>> 0;
};

const hrpExpand = (hrp: string): number[] => {
  const out: number[] = [];
  for (const c of hrp) out.push(c.charCodeAt(0) >> 5);
  out.push(0);
  for (const c of hrp) out.push(c.charCodeAt(0) & 31);
  return out;
};

const createChecksum = (hrp: string, data: number[]): number[] => {
  const values = [...hrpExpand(hrp), ...data, 0, 0, 0, 0, 0, 0];
  const mod = polymod(values) ^ 1;
  return [0, 1, 2, 3, 4, 5].map((i) => (mod >> (5 * (5 - i))) & 31);
};

const verifyChecksum = (hrp: string, data: number[]): boolean =>
  polymod([...hrpExpand(hrp), ...data]) === 1;

const convertBits = (
  data: number[],
  from: number,
  to: number,
  pad: boolean,
): number[] => {
  let acc = 0;
  let bits = 0;
  const ret: number[] = [];
  const maxv = (1 << to) - 1;
  for (const value of data) {
    if (value < 0 || value >> from !== 0) throw new Error('invalid data value');
    acc = (acc << from) | value;
    bits += from;
    while (bits >= to) {
      bits -= to;
      ret.push((acc >> bits) & maxv);
    }
  }
  if (pad) {
    if (bits > 0) ret.push((acc << (to - bits)) & maxv);
  } else if (bits >= from || ((acc << (to - bits)) & maxv)) {
    throw new Error('invalid padding');
  }
  return ret;
};

export const encode = (hrp: string, bytes: Uint8Array): string => {
  const data = convertBits(Array.from(bytes), 8, 5, true);
  const checksum = createChecksum(hrp, data);
  return hrp + '1' + [...data, ...checksum].map((d) => CHARSET[d]).join('');
};

export const decode = (s: string): Bech32Decoded => {
  // BIP-173 caps a bech32 string at 90 characters, but NIP-19 deliberately does
  // not: an nprofile carrying a pubkey plus a relay hint is routinely longer
  // than that, so enforcing the cap made valid nostr: URIs undecodable. Only a
  // lower bound is meaningful here.
  if (s.length < 8) throw new Error('invalid length');
  const lower = s.toLowerCase();
  if (s !== lower && s !== s.toUpperCase()) throw new Error('mixed case');
  const s2 = lower;
  const pos = s2.lastIndexOf('1');
  if (pos < 1 || pos + 7 > s2.length) throw new Error('separator not found');
  const hrp = s2.slice(0, pos);
  const dataPart = s2.slice(pos + 1);
  const data: number[] = [];
  for (const c of dataPart) {
    const v = CHARSET_MAP.get(c);
    if (v === undefined) throw new Error('invalid character');
    data.push(v);
  }
  if (!verifyChecksum(hrp, data)) throw new Error('bad checksum');
  const payload = data.slice(0, -6);
  return { hrp, bytes: new Uint8Array(convertBits(payload, 5, 8, false)) };
};

// ── Nostr-specific helpers ──────────────────────────────────────

const hex = (b: Uint8Array): string =>
  [...b].map((x) => x.toString(16).padStart(2, '0')).join('');

const unhex = (h: string): Uint8Array => {
  if (h.length % 2 !== 0) throw new Error('odd hex length');
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return out;
};

export const npubEncode = (pubkeyHex: string): string =>
  encode('npub', unhex(pubkeyHex));

export const npubDecode = (npub: string): string => {
  const { hrp, bytes } = decode(npub);
  if (hrp !== 'npub') throw new Error(`expected npub, got ${hrp}`);
  return hex(bytes);
};

export const nsecEncode = (seckeyHex: string): string =>
  encode('nsec', unhex(seckeyHex));

export const nsecDecode = (nsec: string): string => {
  const { hrp, bytes } = decode(nsec);
  if (hrp !== 'nsec') throw new Error(`expected nsec, got ${hrp}`);
  return hex(bytes);
};

export const noteEncode = (eventIdHex: string): string =>
  encode('note', unhex(eventIdHex));

export const noteDecode = (note: string): string => {
  const { hrp, bytes } = decode(note);
  if (hrp !== 'note') throw new Error(`expected note, got ${hrp}`);
  return hex(bytes);
};

// ── TLV for nprofile / nevent / naddr ───────────────────────────

const writeTlv = (type: number, value: Uint8Array): Uint8Array => {
  const out = new Uint8Array(2 + value.length);
  out[0] = type;
  out[1] = value.length;
  out.set(value, 2);
  return out;
};

export interface ProfilePointer {
  pubkey: string;
  relays?: string[];
}

export const nprofileEncode = (p: ProfilePointer): string => {
  const parts: Uint8Array[] = [writeTlv(0, unhex(p.pubkey))];
  for (const r of p.relays ?? []) parts.push(writeTlv(1, new TextEncoder().encode(r)));
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return encode('nprofile', out);
};

export const nprofileDecode = (s: string): ProfilePointer => {
  const { hrp, bytes } = decode(s);
  if (hrp !== 'nprofile') throw new Error(`expected nprofile, got ${hrp}`);
  const out: ProfilePointer = { pubkey: '' };
  let i = 0;
  while (i < bytes.length) {
    const t = bytes[i];
    const l = bytes[i + 1];
    const v = bytes.slice(i + 2, i + 2 + l);
    if (t === 0) out.pubkey = hex(v);
    else if (t === 1) {
      out.relays = out.relays ?? [];
      out.relays.push(new TextDecoder().decode(v));
    }
    i += 2 + l;
  }
  return out;
};

// ── TLV entities: nevent / naddr ────────────────────────────────

/**
 * Read a TLV stream into entries. A truncated tail fails the decode rather
 * than silently dropping the relay hint or author it carried.
 */
const readTlv = (bytes: Uint8Array): Array<[number, Uint8Array]> => {
  const out: Array<[number, Uint8Array]> = [];
  let i = 0;
  while (i < bytes.length) {
    if (i + 2 > bytes.length) throw new Error('truncated NIP-19 TLV entry');
    const t = bytes[i];
    const l = bytes[i + 1];
    if (i + 2 + l > bytes.length) throw new Error('truncated NIP-19 TLV value');
    out.push([t, bytes.slice(i + 2, i + 2 + l)]);
    i += 2 + l;
  }
  return out;
};

const uint32BE = (n: number): Uint8Array => {
  if (!Number.isInteger(n) || n < 0 || n > 4294967295) throw new Error('kind does not fit in a uint32');
  return Uint8Array.of((n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff);
};

/** A pointer to one event. */
export interface EventPointer {
  id: string;
  relays?: string[];
  author?: string;
  kind?: number;
}

export const neventEncode = (p: EventPointer): string => {
  const parts: Uint8Array[] = [writeTlv(0, unhex(p.id))];
  for (const r of p.relays ?? []) parts.push(writeTlv(1, new TextEncoder().encode(r)));
  if (p.author !== undefined) parts.push(writeTlv(2, unhex(p.author)));
  if (p.kind !== undefined) parts.push(writeTlv(3, uint32BE(p.kind)));
  return encode('nevent', concat(parts));
};

/** Decode an `nevent`. Rejects the wrong hrp and a missing id. */
export const neventDecode = (s: string): EventPointer => {
  const { hrp, bytes } = decode(s);
  if (hrp !== 'nevent') throw new Error(`expected nevent, got ${hrp}`);
  const entries = readTlv(bytes);
  const id = entries.find(([t, v]) => t === 0 && v.length === 32);
  if (!id) throw new Error('nevent has no 32-byte id');
  const author = entries.find(([t, v]) => t === 2 && v.length === 32);
  const kind = entries.find(([t]) => t === 3);
  return {
    id: hex(id[1]),
    relays: entries.filter(([t]) => t === 1).map(([, v]) => new TextDecoder().decode(v)),
    author: author ? hex(author[1]) : undefined,
    kind: kind && kind[1].length === 4 ? new DataView(kind[1].buffer).getUint32(0) : undefined,
  };
};

/** A pointer to a parameterized address. */
export interface AddrPointer {
  identifier: string;
  relays?: string[];
  author: string;
  kind: number;
}

export const naddrEncode = (p: AddrPointer): string => {
  if (p.identifier === '') throw new Error('naddr identifier must not be empty');
  const parts: Uint8Array[] = [
    writeTlv(0, new TextEncoder().encode(p.identifier)),
    writeTlv(2, unhex(p.author)),
    writeTlv(3, uint32BE(p.kind)),
  ];
  for (const r of p.relays ?? []) parts.splice(1, 0, writeTlv(1, new TextEncoder().encode(r)));
  return encode('naddr', concat(parts));
};

/** Decode an `naddr`. Identifier, author, and kind are all mandatory. */
export const naddrDecode = (s: string): AddrPointer => {
  const { hrp, bytes } = decode(s);
  if (hrp !== 'naddr') throw new Error(`expected naddr, got ${hrp}`);
  const entries = readTlv(bytes);
  const ident = entries.find(([t, v]) => t === 0 && v.length > 0);
  const author = entries.find(([t, v]) => t === 2 && v.length === 32);
  const kind = entries.find(([t]) => t === 3);
  if (!ident) throw new Error('naddr has no identifier');
  if (!author) throw new Error('naddr has no 32-byte author');
  if (!kind || kind[1].length !== 4) throw new Error('naddr kind is not a uint32');
  return {
    identifier: new TextDecoder().decode(ident[1]),
    relays: entries.filter(([t]) => t === 1).map(([, v]) => new TextDecoder().decode(v)),
    author: hex(author[1]),
    kind: new DataView(kind[1].buffer).getUint32(0),
  };
};

/** The `kind:pubkey:d` coordinate an address pointer names. */
export const naddrAddress = (p: AddrPointer): string => `${p.kind}:${p.author}:${p.identifier}`;

const concat = (parts: Uint8Array[]): Uint8Array => {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
};
