import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  DecryptError, HandshakeState, generateKeyPair, hex, keyPairFromSecret, unhex, type Transport,
} from '../src/noise.ts';

interface Vector {
  source: string;
  protocol_name: string;
  init_prologue: string;
  init_psks?: string[];
  init_static?: string;
  init_ephemeral: string;
  init_remote_static?: string;
  resp_prologue: string;
  resp_psks?: string[];
  resp_static?: string;
  resp_ephemeral?: string;
  handshake_hash?: string;
  messages: { payload: string; ciphertext: string }[];
}

const vectors: Vector[] = JSON.parse(
  readFileSync(new URL('../../vectors/subset.json', import.meta.url), 'utf8'),
).vectors;
const kp = (s?: string) => (s ? keyPairFromSecret(unhex(s)) : undefined);

test('NoiseVectorTests vectorSetIsComplete', () => {
  const names = new Set(vectors.map((v) => v.protocol_name));
  for (const p of ['IK', 'IKpsk1', 'IKpsk2', 'XX']) {
    for (const c of ['ChaChaPoly', 'AESGCM']) assert.ok(names.has(`Noise_${p}_25519_${c}_SHA256`), `${p} ${c}`);
  }
  assert.equal(new Set(vectors.map((v) => v.source)).size, 2);
});

// Replays each official vector: every handshake and transport ciphertext must match byte
// for byte, and each payload must decrypt back.
for (const v of vectors) {
  test(`NoiseVectorTests officialVector ${v.protocol_name} [${v.source}]`, () => {
    const ini = new HandshakeState({
      protocolName: v.protocol_name, initiator: true, prologue: unhex(v.init_prologue),
      s: kp(v.init_static), e: kp(v.init_ephemeral),
      rs: v.init_remote_static ? unhex(v.init_remote_static) : undefined, psks: (v.init_psks ?? []).map(unhex),
    });
    const res = new HandshakeState({
      protocolName: v.protocol_name, initiator: false, prologue: unhex(v.resp_prologue),
      s: kp(v.resp_static), e: kp(v.resp_ephemeral), psks: (v.resp_psks ?? []).map(unhex),
    });
    let tIni: Transport | undefined;
    let tRes: Transport | undefined;
    v.messages.forEach((m, i) => {
      const fromInitiator = i % 2 === 0;
      let ct: Uint8Array;
      let pt: Uint8Array;
      if (!tIni) {
        const [w, r] = fromInitiator ? [ini, res] : [res, ini];
        ct = w.writeMessage(unhex(m.payload));
        pt = r.readMessage(ct);
        if (ini.isComplete) {
          assert.ok(res.isComplete);
          tIni = ini.transport;
          tRes = res.transport;
          assert.deepEqual(ini.handshakeHash, res.handshakeHash);
          if (v.handshake_hash) assert.equal(hex(ini.handshakeHash), v.handshake_hash);
          assert.deepEqual(res.remoteStatic, ini.s?.publicKey);
        }
      } else {
        const [w, r] = fromInitiator ? [tIni, tRes!] : [tRes!, tIni];
        ct = w.send.encrypt(unhex(m.payload));
        pt = r.receive.decrypt(ct);
      }
      assert.equal(hex(ct), m.ciphertext, `message ${i}`);
      assert.equal(hex(pt), m.payload, `message ${i}`);
    });
    assert.ok(tIni);
  });
}

test('NoiseUnitTests ikpsk1WrongSecretFailsFirstMessage', () => {
  const host = generateKeyPair();
  const protocolName = 'Noise_IKpsk1_25519_ChaChaPoly_SHA256';
  const i = new HandshakeState({ protocolName, initiator: true, s: generateKeyPair(), rs: host.publicKey,
    psks: [new Uint8Array(32).fill(1)] });
  const r = new HandshakeState({ protocolName, initiator: false, s: host, psks: [new Uint8Array(32).fill(2)] });
  assert.throws(() => r.readMessage(i.writeMessage()), DecryptError);
});

test('NoiseUnitTests ikpsk2WrongSecretPassesFirstMessage', () => {
  const host = generateKeyPair();
  const protocolName = 'Noise_IKpsk2_25519_ChaChaPoly_SHA256';
  const i = new HandshakeState({ protocolName, initiator: true, s: generateKeyPair(), rs: host.publicKey,
    psks: [new Uint8Array(32).fill(1)] });
  const r = new HandshakeState({ protocolName, initiator: false, s: host, psks: [new Uint8Array(32).fill(2)] });
  r.readMessage(i.writeMessage());
  const m2 = r.writeMessage();
  assert.ok(r.isComplete);
  assert.throws(() => i.readMessage(m2), DecryptError);
});

test('NoiseUnitTests wrongHostKeyFailsFirstMessage', () => {
  const protocolName = 'Noise_IK_25519_ChaChaPoly_SHA256';
  const i = new HandshakeState({ protocolName, initiator: true, s: generateKeyPair(),
    rs: generateKeyPair().publicKey });
  const r = new HandshakeState({ protocolName, initiator: false, s: generateKeyPair() });
  assert.throws(() => r.readMessage(i.writeMessage()), DecryptError);
});

test('NoiseUnitTests tamperedTransportMessageIsRejected', () => {
  const host = generateKeyPair();
  const protocolName = 'Noise_IK_25519_ChaChaPoly_SHA256';
  const i = new HandshakeState({ protocolName, initiator: true, s: generateKeyPair(), rs: host.publicKey });
  const r = new HandshakeState({ protocolName, initiator: false, s: host });
  r.readMessage(i.writeMessage());
  i.readMessage(r.writeMessage());
  const ct = i.transport!.send.encrypt(new TextEncoder().encode('hello'));
  ct[0] ^= 1;
  assert.throws(() => r.transport!.receive.decrypt(ct), DecryptError);
});
