// Cross-language handshake: this process runs the TS side in-process and spawns the Swift
// noise-peer (swift/.build/debug/noise-peer, or $SWIFT_PEER) over stdin/stdout pipes.
// Build it first: `swift build --package-path ../swift` (scripts/interop does this).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DecryptError, generateKeyPair, hex, type KeyPair } from '../src/noise.ts';
import { StreamFrameIO, runInterop, type InteropResult } from '../src/interop.ts';

const SWIFT_PEER = process.env.SWIFT_PEER ??
  fileURLToPath(new URL('../../swift/.build/debug/noise-peer', import.meta.url));

interface PeerOutcome<T> { result?: T; error?: unknown; code: number | null; stderr: string }

async function withSwiftPeer<T>(args: Record<string, string>, run: (io: StreamFrameIO) => Promise<T>):
    Promise<PeerOutcome<T>> {
  assert.ok(existsSync(SWIFT_PEER), `missing ${SWIFT_PEER}; run scripts/interop or swift build first`);
  const child = spawn(SWIFT_PEER, Object.entries(args).flatMap(([k, v]) => [`--${k}`, v]),
    { stdio: ['pipe', 'pipe', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', (d) => (stderr += d));
  child.stdin.on('error', () => {}); // the peer may exit before we write
  const exited = new Promise<number | null>((r) => child.on('close', r));
  const io = new StreamFrameIO(child.stdout, child.stdin);
  let result: T | undefined;
  let error: unknown;
  try {
    result = await run(io);
  } catch (e) {
    error = e;
  }
  child.stdin.end();
  const code = await exited;
  return { result, error, code, stderr };
}

const PROTOCOLS = [
  'Noise_IK_25519_ChaChaPoly_SHA256',
  'Noise_IK_25519_AESGCM_SHA256',
  'Noise_IKpsk1_25519_ChaChaPoly_SHA256',
  'Noise_IKpsk2_25519_ChaChaPoly_SHA256',
  'Noise_XX_25519_ChaChaPoly_SHA256',
];

const usesPsk = (p: string) => p.includes('psk');
const knowsHostKey = (p: string) => p.includes('_IK');

function checkSuccess(o: PeerOutcome<InteropResult>, me: KeyPair, peer: KeyPair) {
  assert.equal(o.error, undefined, `${o.error}\nswift stderr: ${o.stderr}`);
  assert.equal(o.code, 0, o.stderr);
  const r = o.result!;
  assert.equal(r.peerImpl, 'swift');
  assert.deepEqual(r.remoteStatic, peer.publicKey);
  assert.match(o.stderr, new RegExp(`^ok h=${hex(r.handshakeHash)} rs=${hex(me.publicKey)}$`, 'm'));
  assert.ok(r.received.includes('pong 2 swift') || r.received.includes('ping 2'));
}

for (const protocolName of PROTOCOLS) {
  test(`InteropTests tsInitiatorSwiftResponder ${protocolName}`, async () => {
    const phone = generateKeyPair(), host = generateKeyPair();
    const psk = generateKeyPair().secretKey;
    const o = await withSwiftPeer({
      role: 'responder', protocol: protocolName, s: hex(host.secretKey), ...(usesPsk(protocolName) && { psk: hex(psk) }),
    }, (io) => runInterop({
      initiator: true, protocolName, s: phone, rs: knowsHostKey(protocolName) ? host.publicKey : undefined,
      psk: usesPsk(protocolName) ? psk : undefined,
    }, io));
    checkSuccess(o, phone, host);
  });

  test(`InteropTests swiftInitiatorTsResponder ${protocolName}`, async () => {
    const phone = generateKeyPair(), host = generateKeyPair();
    const psk = generateKeyPair().secretKey;
    const o = await withSwiftPeer({
      role: 'initiator', protocol: protocolName, s: hex(phone.secretKey),
      ...(knowsHostKey(protocolName) && { rs: hex(host.publicKey) }), ...(usesPsk(protocolName) && { psk: hex(psk) }),
    }, (io) => runInterop({
      initiator: false, protocolName, s: host, psk: usesPsk(protocolName) ? psk : undefined,
    }, io));
    checkSuccess(o, host, phone);
  });
}

test('InteropTests pairingWrongSecretRejected', async () => {
  const protocolName = 'Noise_IKpsk1_25519_ChaChaPoly_SHA256';
  const phone = generateKeyPair(), host = generateKeyPair();
  // Swift phone, TS host: the host's first read fails.
  const a = await withSwiftPeer({
    role: 'initiator', protocol: protocolName, s: hex(phone.secretKey), rs: hex(host.publicKey),
    psk: hex(new Uint8Array(32).fill(1)),
  }, (io) => runInterop({ initiator: false, protocolName, s: host, psk: new Uint8Array(32).fill(2) }, io));
  assert.ok(a.error instanceof DecryptError, String(a.error));
  assert.equal(a.code, 1);
  // TS phone, Swift host: the Swift host rejects message 1 and exits without answering.
  const b = await withSwiftPeer({
    role: 'responder', protocol: protocolName, s: hex(host.secretKey), psk: hex(new Uint8Array(32).fill(2)),
  }, (io) => runInterop({
    initiator: true, protocolName, s: phone, rs: host.publicKey, psk: new Uint8Array(32).fill(1),
  }, io));
  assert.match(String(b.error), /peer closed/);
  assert.equal(b.code, 1);
  assert.match(b.stderr, /decryptFailed/);
});

test('InteropTests wrongHostKeyRejected', async () => {
  const protocolName = 'Noise_IK_25519_ChaChaPoly_SHA256';
  const host = generateKeyPair();
  const o = await withSwiftPeer({ role: 'responder', protocol: protocolName, s: hex(host.secretKey) },
    (io) => runInterop({ initiator: true, protocolName, s: generateKeyPair(), rs: generateKeyPair().publicKey }, io));
  assert.match(String(o.error), /peer closed/);
  assert.match(o.stderr, /decryptFailed/);
});
