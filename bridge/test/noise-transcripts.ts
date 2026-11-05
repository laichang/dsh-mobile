/**
 * Golden Noise transcripts for the bridge's wire (ARCHITECTURE D6, D18): fixed keys in, exact
 * bytes out. `pnpm noise-fixtures` writes protocol/fixtures/noise/transcripts.json; the TS test
 * (test/pairing.test.ts) regenerates and compares it, and the Swift test
 * (ios/DSHKit/Tests/DSHKitTests/NoiseChannelTests.swift) replays the phone side against it, so the
 * two implementations can't drift apart on the header, prologue, patterns or framing.
 */
import { create, toBinary } from '@bufbuild/protobuf'
import { FrameSchema } from '../src/gen/frame_pb.ts'
import { HandshakeState, hex, keyPairFromSecret } from '../src/pairing/noise.ts'
import { Mode, PAIR_PROTOCOL, RECONNECT_PROTOCOL, encodeFirstMessage, header, prologue } from '../src/pairing/wire.ts'

export interface Transcript {
  name: string
  protocol: string
  mode: number
  hostStatic: string
  hostEphemeral: string
  phoneStatic: string
  phoneEphemeral: string
  offerId?: string
  secret?: string
  /** The phone's first WebSocket message: header ‖ Noise message 1. */
  first: string
  /** The bridge's reply: Noise message 2. */
  reply: string
  handshakeHash: string
  /** Transport messages after the handshake, in order. */
  transport: { from: 'phone' | 'host'; plaintext: string; ciphertext: string }[]
}

const fill = (byte: number, n = 32) => new Uint8Array(n).fill(byte)

const helloRequest = toBinary(FrameSchema, create(FrameSchema, {
  kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } },
}))
const helloResponse = toBinary(FrameSchema, create(FrameSchema, {
  kind: { case: 'response', value: { requestId: 1n, body: { case: 'hello', value: { protocolVersion: 1, capabilities: ['tasks.v1'] } } } },
}))

function transcript(name: string, mode: Mode): Transcript {
  const host = keyPairFromSecret(fill(0x11))
  const hostE = keyPairFromSecret(fill(0x22))
  const phone = keyPairFromSecret(fill(0x33))
  const phoneE = keyPairFromSecret(fill(0x44))
  const offerId = mode === Mode.Pair ? fill(0x55, 16) : undefined
  const secret = mode === Mode.Pair ? fill(0x66) : undefined
  const protocolName = mode === Mode.Pair ? PAIR_PROTOCOL : RECONNECT_PROTOCOL
  const pro = prologue(header(mode, offerId))
  const psks = secret ? [secret] : []
  const ini = new HandshakeState({ protocolName, initiator: true, prologue: pro, s: phone, e: phoneE, rs: host.publicKey, psks })
  const res = new HandshakeState({ protocolName, initiator: false, prologue: pro, s: host, e: hostE, psks })
  const m1 = ini.writeMessage()
  res.readMessage(m1)
  const m2 = res.writeMessage()
  ini.readMessage(m2)
  const p = ini.transport!
  const h = res.transport!
  const transport: Transcript['transport'] = [
    { from: 'phone', plaintext: hex(helloRequest), ciphertext: hex(p.send.encrypt(helloRequest)) },
    { from: 'host', plaintext: hex(helloResponse), ciphertext: hex(h.send.encrypt(helloResponse)) },
    { from: 'phone', plaintext: hex(helloRequest), ciphertext: hex(p.send.encrypt(helloRequest)) },
  ]
  return {
    name, protocol: protocolName, mode,
    hostStatic: hex(host.secretKey), hostEphemeral: hex(hostE.secretKey),
    phoneStatic: hex(phone.secretKey), phoneEphemeral: hex(phoneE.secretKey),
    ...(offerId ? { offerId: hex(offerId), secret: hex(secret!) } : {}),
    first: hex(encodeFirstMessage(mode, m1, offerId)),
    reply: hex(m2),
    handshakeHash: hex(ini.handshakeHash),
    transport,
  }
}

export function makeTranscripts(): { transcripts: Transcript[] } {
  return { transcripts: [transcript('pair', Mode.Pair), transcript('reconnect', Mode.Reconnect)] }
}

