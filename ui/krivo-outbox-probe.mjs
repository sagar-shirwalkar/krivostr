import { schnorr } from '@noble/curves/secp256k1';
import { sha256 } from '@noble/hashes/sha256';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils';

const sk = hexToBytes('0707070707070707070707070707070707070707070707070707070707070707');
const pubkey = bytesToHex(schnorr.getPublicKey(sk));
const stamp = Date.now().toString(36);
const sign = (u) => {
  const canon = JSON.stringify([0, pubkey, u.created_at, u.kind, u.tags, u.content]);
  const id = bytesToHex(sha256(new TextEncoder().encode(canon)));
  return { ...u, pubkey, id, sig: bytesToHex(schnorr.sign(id, sk)) };
};
const ev = sign({
  created_at: Math.floor(Date.now() / 1000),
  kind: 1,
  tags: [],
  content: `krivostr outbox probe ${stamp}`,
});

const mode = process.argv[2];
if (mode === 'publish') {
  const ws = new WebSocket('ws://127.0.0.1:18084/ws');
  ws.onopen = () => ws.send(JSON.stringify(['EVENT', ev]));
  ws.onmessage = (msg) => {
    const d = JSON.parse(msg.data);
    if (d[0] === 'OK') {
      console.log('BRIDGE_OK', JSON.stringify(d.slice(1)));
      console.log('EVENT_ID', ev.id);
      ws.close();
      process.exit(0);
    }
  };
  ws.onerror = (e) => {
    console.log('WS_ERROR', e.message);
    process.exit(2);
  };
  setTimeout(() => {
    console.log('TIMEOUT');
    process.exit(3);
  }, 15000);
} else if (mode === 'fetch') {
  const id = process.argv[3];
  const ws = new WebSocket('wss://relay.damus.io');
  ws.onopen = () => ws.send(JSON.stringify(['REQ', 'probe', { ids: [id] }]));
  ws.onmessage = (msg) => {
    const d = JSON.parse(msg.data);
    if (d[0] === 'EVENT') {
      console.log('DAMUS_HIT', d[2].content);
      ws.close();
      process.exit(0);
    }
    if (d[0] === 'EOSE') {
      console.log('DAMUS_MISS');
      ws.close();
      process.exit(1);
    }
  };
  ws.onerror = (e) => {
    console.log('WS_ERROR', e.message);
    process.exit(2);
  };
  setTimeout(() => {
    console.log('TIMEOUT');
    process.exit(3);
  }, 20000);
}
