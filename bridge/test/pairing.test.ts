/**
 * S1 · Pair + encrypt, bridge side: Noise vectors, golden transcripts, the pairing offer, and the
 * Noise listener end to end against FakeDSH (pairing, reconnect, and every refusal).
 */
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { after, describe, test } from 'node:test'
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocket } from 'ws'
import { PlaintextChannel } from '../src/channel.ts'
import { DshTasks } from '../src/dsh.ts'
import { FrameSchema, TaskStatus, type Frame } from '../src/gen/frame_pb.ts'
import { resolveConfig } from '../src/index.ts'
import { listenerInfo, makeOffer } from '../src/pairing/announce.ts'
import { NoiseInitiator, NoiseResponder, type NoiseSession } from '../src/pairing/handshake.ts'
import {
  DecryptError, HandshakeState, generateKeyPair, hex, keyPairFromSecret, unhex, type KeyPair, type Transport,
} from '../src/pairing/noise.ts'
import { offerURL, parseOfferURL } from '../src/pairing/offer.ts'
import { PairingStore } from '../src/pairing/store.ts'
import { CloseCode } from '../src/pairing/wire.ts'
import { PLAINTEXT_PATH, startBridgeServer, type BridgeServer } from '../src/server.ts'
import { FakeDSH } from './fake-dsh.ts'
import { FIXTURES_DIR } from './fixtures.ts'
import { makeTranscripts } from './noise-transcripts.ts'

// MARK: - Noise itself

interface Vector {
  source: string
  protocol_name: string
  init_prologue: string
  init_psks?: string[]
  init_static?: string
  init_ephemeral: string
  init_remote_static?: string
  resp_prologue: string
  resp_psks?: string[]
  resp_static?: string
  resp_ephemeral?: string
  handshake_hash?: string
  messages: { payload: string; ciphertext: string }[]
}

const vectors: Vector[] = JSON.parse(readFileSync(resolve(FIXTURES_DIR, 'noise/official-vectors.json'), 'utf8')).vectors
const kp = (s?: string) => (s ? keyPairFromSecret(unhex(s)) : undefined)

describe('NoiseVectorsBridge', () => {
  test('vectorSetIsComplete', () => {
    const names = new Set(vectors.map((v) => v.protocol_name))
    for (const p of ['IK', 'IKpsk1']) {
      for (const c of ['ChaChaPoly', 'AESGCM']) assert.ok(names.has(`Noise_${p}_25519_${c}_SHA256`), `${p} ${c}`)
    }
  })

  // Every handshake and transport ciphertext must match byte for byte.
  test('officialVectors', () => {
    for (const v of vectors) {
      const ini = new HandshakeState({
        protocolName: v.protocol_name, initiator: true, prologue: unhex(v.init_prologue),
        s: kp(v.init_static), e: kp(v.init_ephemeral),
        rs: v.init_remote_static ? unhex(v.init_remote_static) : undefined, psks: (v.init_psks ?? []).map(unhex),
      })
      const res = new HandshakeState({
        protocolName: v.protocol_name, initiator: false, prologue: unhex(v.resp_prologue),
        s: kp(v.resp_static), e: kp(v.resp_ephemeral), psks: (v.resp_psks ?? []).map(unhex),
      })
      let tIni: Transport | undefined
      let tRes: Transport | undefined
      v.messages.forEach((m, i) => {
        const fromInitiator = i % 2 === 0
        let ct: Uint8Array
        let pt: Uint8Array
        if (!tIni) {
          const [w, r] = fromInitiator ? [ini, res] : [res, ini]
          ct = w.writeMessage(unhex(m.payload))
          pt = r.readMessage(ct)
          if (ini.isComplete) {
            tIni = ini.transport
            tRes = res.transport
            if (v.handshake_hash) assert.equal(hex(ini.handshakeHash), v.handshake_hash)
          }
        } else {
          const [w, r] = fromInitiator ? [tIni, tRes!] : [tRes!, tIni]
          ct = w.send.encrypt(unhex(m.payload))
          pt = r.receive.decrypt(ct)
        }
        assert.equal(hex(ct), m.ciphertext, `${v.protocol_name} [${v.source}] message ${i}`)
        assert.equal(hex(pt), m.payload)
      })
      assert.ok(tIni)
    }
  })

  test('ikpsk1WrongSecretFailsFirstMessage', () => {
    const host = generateKeyPair()
    const protocolName = 'Noise_IKpsk1_25519_ChaChaPoly_SHA256'
    const i = new HandshakeState({ protocolName, initiator: true, s: generateKeyPair(), rs: host.publicKey, psks: [new Uint8Array(32).fill(1)] })
    const r = new HandshakeState({ protocolName, initiator: false, s: host, psks: [new Uint8Array(32).fill(2)] })
    assert.throws(() => r.readMessage(i.writeMessage()), DecryptError)
  })
})

describe('NoiseGoldenTranscripts', () => {
  // Swift replays the phone side of the same file (NoiseChannelTests/goldenTranscripts).
  test('transcriptsMatchFixture', () => {
    const onDisk = JSON.parse(readFileSync(resolve(FIXTURES_DIR, 'noise/transcripts.json'), 'utf8'))
    assert.deepEqual(onDisk, makeTranscripts(), 'run `pnpm noise-fixtures` and review the diff')
  })
})

// MARK: - Offer and store

const dirs: string[] = []
const servers: BridgeServer[] = []
after(async () => {
  await Promise.all(servers.map((s) => s.close()))
  for (const d of dirs) rmSync(d, { recursive: true, force: true })
})
function tempStore(now: () => number = Date.now) {
  const dir = mkdtempSync(join(tmpdir(), 'dshm-s1-'))
  dirs.push(dir)
  const store = new PairingStore(dir, now)
  store.writeListener({ hostName: 'test-mac', addresses: ['127.0.0.1:1'] })
  return store
}

describe('PairingOffer', () => {
  test('offerURLRoundTrips', () => {
    const store = tempStore()
    const offer = makeOffer(store, 60_000, { hostName: 'Mac mini', addresses: ['192.168.1.5:47801', '[fd7a::1]:47801'] })
    const url = offerURL(offer)
    assert.match(url, /^dshm:\/\/pair\?v=1&/)
    const back = parseOfferURL(url)
    assert.equal(back.hostName, 'Mac mini')
    assert.deepEqual(back.addresses, ['192.168.1.5:47801', '[fd7a::1]:47801'])
    assert.deepEqual(back.hostKey, store.hostKey().publicKey)
    assert.deepEqual(back.offerId, offer.offerId)
    assert.deepEqual(back.secret, offer.secret)
    assert.equal(back.expiresAt, Math.floor(offer.expiresAt / 1000) * 1000)
    assert.throws(() => parseOfferURL(url.replace('v=1', 'v=2')), /version/)
    assert.throws(() => parseOfferURL(url.replace(/&s=[^&]+/, '&s=AAAA')), /field s/)
  })

  test('stateIsPrivateAndHostKeyIsStable', () => {
    const store = tempStore()
    const key = store.hostKey().publicKey
    assert.deepEqual(new PairingStore(store.dir).hostKey().publicKey, key)
    assert.equal(statSync(store.dir).mode & 0o777, 0o700)
    assert.equal(statSync(join(store.dir, 'host-key.json')).mode & 0o777, 0o600)
  })

  test('wildcardListenerListsExternalAddresses', () => {
    assert.deepEqual(listenerInfo('127.0.0.1', 47810).addresses, ['127.0.0.1:47810'])
    for (const a of listenerInfo('0.0.0.0', 47810).addresses) assert.match(a, /:47810$/)
  })

  test('configDefaultsToNoiseOnAllInterfaces', () => {
    const c = resolveConfig({}, { DSH_HOME: '/tmp/h' })
    assert.equal(c.host, '0.0.0.0')
    assert.equal(c.devPlaintext, false)
    assert.equal(c.stateDir, '/tmp/h/dsh-mobile-bridge')
    const e = resolveConfig({}, { DSHM_BRIDGE_PORT: '47810', DSHM_BRIDGE_HOST: '127.0.0.1', DSHM_BRIDGE_DEV_PLAINTEXT: '1' })
    assert.equal(e.port, 47810)
    assert.equal(e.devPlaintext, true)
  })
})

// MARK: - The Noise listener end to end

interface Client {
  frames: Frame[]
  closed: Promise<{ code: number; reason: string }>
  session?: NoiseSession
  send(f: MessageInitShape<typeof FrameSchema>): void
  until(pred: (fs: Frame[]) => boolean, ms?: number): Promise<void>
  close(): void
}

/** Opens a WebSocket, runs the initiator's handshake, then speaks Noise-sealed frames. */
async function noiseClient(port: number, initiator: NoiseInitiator, path = '/'): Promise<Client> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`)
  ws.binaryType = 'nodebuffer'
  const frames: Frame[] = []
  const waiters: (() => void)[] = []
  let session: NoiseSession | undefined
  let handshake: { resolve: () => void; reject: (e: Error) => void }
  const ready = new Promise<void>((resolve, reject) => { handshake = { resolve, reject } })
  const closed = new Promise<{ code: number; reason: string }>((r) => ws.on('close', (code, reason) => {
    handshake.reject(new Error(`closed ${code} ${reason.toString()}`))
    r({ code, reason: reason.toString() })
  }))
  ws.on('message', (data: Buffer) => {
    const bytes = new Uint8Array(data)
    if (!session) {
      try { session = initiator.finish(bytes); handshake.resolve() } catch (e) { handshake.reject(e as Error) }
      return
    }
    frames.push(fromBinary(FrameSchema, session.open(bytes)))
    for (const w of waiters.splice(0)) w()
  })
  ws.on('open', () => ws.send(initiator.first))
  ws.on('error', () => {})
  const client: Client = {
    frames, closed,
    send(f) { ws.send(session!.seal(toBinary(FrameSchema, create(FrameSchema, f)))) },
    async until(pred, ms = 3000) {
      const deadline = Date.now() + ms
      while (!pred(frames)) {
        if (Date.now() > deadline) throw new Error(`timed out; got ${frames.length} frames`)
        await new Promise<void>((r) => { waiters.push(r); setTimeout(r, 50) })
      }
    },
    close() { ws.close() },
  }
  try { await ready } catch { return client }
  client.session = session
  return client
}

/** Sends one raw binary message and reports how the bridge closes the connection. */
function sendRaw(port: number, bytes: Uint8Array): Promise<{ code: number; reason: string }> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/`)
  ws.on('open', () => ws.send(bytes))
  ws.on('error', () => {})
  return new Promise((r) => ws.on('close', (code, reason) => r({ code, reason: reason.toString() })))
}

async function noiseBridge(store: PairingStore, plaintext = false) {
  const server = await startBridgeServer({
    host: '127.0.0.1', port: 0, noise: new NoiseResponder(store),
    channel: plaintext ? new PlaintextChannel() : undefined,
    tasks: new DshTasks(new FakeDSH({ reply: ['secret', ' ', 'reply'] }), '/tmp/dshm-ws'),
  })
  servers.push(server)
  return server
}

const hello: MessageInitShape<typeof FrameSchema> = { kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } }
const createTask: MessageInitShape<typeof FrameSchema> = { kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: { prompt: 'hi' } } } } }
const ended = (fs: Frame[]) => fs.some((f) => f.kind.case === 'event' && f.kind.value.body.case === 'taskEnded')

async function runTask(c: Client) {
  c.send(hello)
  c.send(createTask)
  await c.until(ended)
  const text = c.frames.flatMap((f) => f.kind.case === 'event' && f.kind.value.body.case === 'assistantChunk' ? [f.kind.value.body.value.text] : []).join('')
  const last = c.frames.at(-1)!
  assert.ok(last.kind.case === 'event' && last.kind.value.body.case === 'taskEnded')
  assert.equal(last.kind.value.body.value.status, TaskStatus.COMPLETED)
  return text
}

function pairWith(store: PairingStore, phone: KeyPair, offer = makeOffer(store)) {
  return NoiseInitiator.pair({ s: phone, hostKey: offer.hostKey, offerId: offer.offerId, secret: offer.secret })
}

describe('PairingBridge', () => {
  test('pairsThenRunsTaskThenReconnects', async () => {
    const store = tempStore()
    const server = await noiseBridge(store)
    const phone = generateKeyPair()

    const paired = await noiseClient(server.port, pairWith(store, phone))
    assert.ok(paired.session, 'pairing handshake completes')
    assert.equal(await runTask(paired), 'secret reply')
    paired.close()
    const devices = store.devices()
    assert.equal(devices.length, 1)
    assert.deepEqual(devices[0].publicKey, phone.publicKey)

    // Reconnect: IK with the stored host key, no secret.
    const again = await noiseClient(server.port, NoiseInitiator.reconnect({ s: phone, hostKey: store.hostKey().publicKey }))
    assert.ok(again.session, 'reconnect handshake completes')
    assert.equal(await runTask(again), 'secret reply')
    again.close()
  })

  test('reusedSecretIsRejected', async () => {
    const store = tempStore()
    const server = await noiseBridge(store)
    const offer = makeOffer(store)
    const firstInitiator = pairWith(store, generateKeyPair(), offer)
    const first = await noiseClient(server.port, firstInitiator)
    assert.ok(first.session)
    await runTask(first)
    first.close()
    // Same offer again, from another phone (or a replay): refused before the host answers.
    const second = await noiseClient(server.port, pairWith(store, generateKeyPair(), offer))
    assert.equal(second.session, undefined)
    assert.deepEqual(await second.closed, { code: CloseCode.PairingRejected, reason: 'pairing secret used' })
    // A byte-for-byte replay of the first phone's message 1 is refused too.
    assert.deepEqual(await sendRaw(server.port, firstInitiator.first), { code: CloseCode.PairingRejected, reason: 'pairing secret used' })
    assert.equal(store.devices().length, 1)
  })

  test('expiredSecretIsRejected', async () => {
    let now = 1_000_000
    const store = tempStore(() => now)
    const server = await noiseBridge(store)
    const offer = makeOffer(store, 10 * 60_000)
    now += 10 * 60_000 + 1
    const c = await noiseClient(server.port, pairWith(store, generateKeyPair(), offer))
    assert.equal(c.session, undefined)
    assert.deepEqual(await c.closed, { code: CloseCode.PairingRejected, reason: 'pairing secret expired' })
    assert.equal(store.devices().length, 0)
  })

  test('wrongSecretIsRejected', async () => {
    const store = tempStore()
    const server = await noiseBridge(store)
    const offer = makeOffer(store)
    const c = await noiseClient(server.port, NoiseInitiator.pair({
      s: generateKeyPair(), hostKey: offer.hostKey, offerId: offer.offerId, secret: new Uint8Array(32).fill(9),
    }))
    assert.deepEqual(await c.closed, { code: CloseCode.PairingRejected, reason: 'pairing secret wrong' })
    assert.equal(store.devices().length, 0)
  })

  test('unknownOfferIsRejected', async () => {
    const store = tempStore()
    const server = await noiseBridge(store)
    const c = await noiseClient(server.port, NoiseInitiator.pair({
      s: generateKeyPair(), hostKey: store.hostKey().publicKey, offerId: new Uint8Array(16).fill(1), secret: new Uint8Array(32),
    }))
    assert.deepEqual(await c.closed, { code: CloseCode.PairingRejected, reason: 'pairing secret unknown' })
  })

  test('unpairedDeviceCannotReconnect', async () => {
    const store = tempStore()
    const server = await noiseBridge(store)
    const c = await noiseClient(server.port, NoiseInitiator.reconnect({ s: generateKeyPair(), hostKey: store.hostKey().publicKey }))
    assert.deepEqual(await c.closed, { code: CloseCode.DeviceUnknown, reason: 'device not paired' })
  })

  test('wrongHostKeyFails', async () => {
    const store = tempStore()
    const server = await noiseBridge(store)
    const phone = generateKeyPair()
    const paired = await noiseClient(server.port, pairWith(store, phone))
    await runTask(paired)
    paired.close()
    const c = await noiseClient(server.port, NoiseInitiator.reconnect({ s: phone, hostKey: generateKeyPair().publicKey }))
    assert.deepEqual(await c.closed, { code: CloseCode.HandshakeFailed, reason: 'handshake failed' })
  })

  test('deviceRegisteredOnlyAfterFirstTransportMessage', async () => {
    const store = tempStore()
    const server = await noiseBridge(store)
    const c = await noiseClient(server.port, pairWith(store, generateKeyPair()))
    assert.ok(c.session)
    assert.equal(store.devices().length, 0, 'not yet: the phone has not proven it finished the handshake')
    c.send(hello)
    await c.until((fs) => fs.length >= 1)
    assert.equal(store.devices().length, 1)
    c.close()
  })

  test('garbageFirstMessageIsRefused', async () => {
    const server = await noiseBridge(tempStore())
    assert.equal((await sendRaw(server.port, Uint8Array.of(9, 9, 9))).code, CloseCode.BadHello)
  })
})

describe('PlaintextChannelDevOnly', () => {
  // The bridge serves plaintext only when configured (devPlaintext), only on PLAINTEXT_PATH, and
  // only on a loopback listener; a Noise-only bridge refuses the plaintext path outright.
  test('plaintextPathRefusedUnlessConfigured', async () => {
    const server = await noiseBridge(tempStore())
    const ws = new WebSocket(`ws://127.0.0.1:${server.port}${PLAINTEXT_PATH}`)
    const closed = new Promise<{ code: number; reason: string }>((r) => ws.on('close', (code, reason) => r({ code, reason: reason.toString() })))
    assert.deepEqual(await closed, { code: 1008, reason: 'plaintext disabled' })
  })

  test('devPlaintextRequiresLoopbackListener', async () => {
    await assert.rejects(startBridgeServer({
      host: '0.0.0.0', port: 0, noise: new NoiseResponder(tempStore()), channel: new PlaintextChannel(),
      tasks: new DshTasks(new FakeDSH(), '/tmp'),
    }), /refuses non-loopback/)
  })

  test('noiseAndDevPlaintextSideBySide', async () => {
    const store = tempStore()
    const server = await noiseBridge(store, true)
    const c = await noiseClient(server.port, pairWith(store, generateKeyPair()))
    assert.equal(await runTask(c), 'secret reply')
    c.close()
  })
})
