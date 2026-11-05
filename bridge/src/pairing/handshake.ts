/**
 * Both ends of the bridge's Noise handshake (ARCHITECTURE D6, D18).
 * - `NoiseResponder` is the bridge side: pairing (`IKpsk1`, psk = the offer's one-time secret)
 *   and reconnect (`IK`, the phone's static key must be in the device registry).
 * - `NoiseInitiator` is the phone side in TypeScript, for tests and `scripts/client.ts`. The app's
 *   own initiator is ios/DSHKit/Sources/DSHCore/Pairing/NoiseChannel.swift.
 */
import { HandshakeState, NoiseError, type KeyPair, type Transport } from './noise.ts'
import { OfferRejected, type PairingStore } from './store.ts'
import {
  CloseCode, Mode, PAIR_PROTOCOL, RECONNECT_PROTOCOL,
  decodeFirstMessage, encodeFirstMessage, header, prologue,
} from './wire.ts'

/** Why the bridge refused a connection; `code` is the WebSocket close code (`CloseCode`). */
export class HandshakeRejected extends Error {
  constructor(readonly code: number, readonly reason: string) { super(reason) }
}

/** An established Noise session: one transport message per WebSocket message. */
export class NoiseSession {
  private opened = false

  constructor(
    private readonly transport: Transport,
    readonly remoteStatic: Uint8Array,
    readonly mode: Mode,
    private readonly onFirstOpen: () => void = () => {},
  ) {}

  readonly name = 'noise'

  seal(plaintext: Uint8Array): Uint8Array { return this.transport.send.encrypt(plaintext) }

  open(ciphertext: Uint8Array): Uint8Array {
    const plaintext = this.transport.receive.decrypt(ciphertext)
    if (!this.opened) {
      this.opened = true
      this.onFirstOpen()
    }
    return plaintext
  }
}

export interface Accepted {
  /** Noise message 2, to send back as-is. */
  reply: Uint8Array
  session: NoiseSession
}

export class NoiseResponder {
  constructor(private readonly store: PairingStore, private readonly log: (m: string) => void = () => {}) {}

  /** Handles the app's first message. Throws `HandshakeRejected` to refuse the connection. */
  accept(first: Uint8Array): Accepted {
    const msg = decodeFirstMessage(first)
    if (!msg) throw new HandshakeRejected(CloseCode.BadHello, 'bad first message')
    const s = this.store.hostKey()
    const pro = prologue(msg.header)

    if (msg.mode === Mode.Pair) {
      const offerId = msg.offerId!
      let secret: Uint8Array
      try {
        secret = this.store.usableOffer(offerId).secret
      } catch (error) {
        if (error instanceof OfferRejected) {
          throw new HandshakeRejected(CloseCode.PairingRejected, `pairing secret ${error.reason}`)
        }
        throw error
      }
      const hs = new HandshakeState({ protocolName: PAIR_PROTOCOL, initiator: false, prologue: pro, s, psks: [secret] })
      readFirst(hs, msg.noise, CloseCode.PairingRejected, 'pairing secret wrong')
      // Single use from here on: a replayed message 1 can't reuse the secret (X2 risk 3).
      this.store.markOfferUsed(offerId)
      const reply = hs.writeMessage()
      const rs = hs.remoteStatic!
      const session = new NoiseSession(hs.transport!, rs, Mode.Pair, () => {
        // Register only once the phone proves it finished the handshake.
        const d = this.store.registerDevice(rs, offerId)
        this.log(`paired device ${d.id}`)
      })
      return { reply, session }
    }

    const hs = new HandshakeState({ protocolName: RECONNECT_PROTOCOL, initiator: false, prologue: pro, s })
    readFirst(hs, msg.noise, CloseCode.HandshakeFailed, 'handshake failed')
    const rs = hs.remoteStatic!
    if (!this.store.findDevice(rs)) throw new HandshakeRejected(CloseCode.DeviceUnknown, 'device not paired')
    const reply = hs.writeMessage()
    const session = new NoiseSession(hs.transport!, rs, Mode.Reconnect, () => this.store.touchDevice(rs))
    return { reply, session }
  }
}

function readFirst(hs: HandshakeState, noise: Uint8Array, code: number, reason: string): void {
  let payload: Uint8Array
  try {
    payload = hs.readMessage(noise)
  } catch (error) {
    if (error instanceof NoiseError) throw new HandshakeRejected(code, reason)
    throw error
  }
  // Handshake payloads stay empty: message 1 is replayable and not forward-secret (X2 risk 2).
  if (payload.length !== 0) throw new HandshakeRejected(CloseCode.HandshakeFailed, 'non-empty handshake payload')
}

/** The phone side, for tests and the CLI client. */
export class NoiseInitiator {
  private readonly hs: HandshakeState
  readonly first: Uint8Array

  private constructor(protocolName: string, mode: Mode, s: KeyPair, hostKey: Uint8Array, psks: Uint8Array[], offerId?: Uint8Array, e?: KeyPair) {
    const h = header(mode, offerId)
    this.hs = new HandshakeState({ protocolName, initiator: true, prologue: prologue(h), s, rs: hostKey, psks, e })
    this.first = encodeFirstMessage(mode, this.hs.writeMessage(), offerId)
    this.mode = mode
  }

  readonly mode: Mode

  static pair(o: { s: KeyPair; hostKey: Uint8Array; offerId: Uint8Array; secret: Uint8Array; e?: KeyPair }): NoiseInitiator {
    return new NoiseInitiator(PAIR_PROTOCOL, Mode.Pair, o.s, o.hostKey, [o.secret], o.offerId, o.e)
  }

  static reconnect(o: { s: KeyPair; hostKey: Uint8Array; e?: KeyPair }): NoiseInitiator {
    return new NoiseInitiator(RECONNECT_PROTOCOL, Mode.Reconnect, o.s, o.hostKey, [], undefined, o.e)
  }

  /** Reads Noise message 2 and returns the session. */
  finish(reply: Uint8Array): NoiseSession {
    const payload = this.hs.readMessage(reply)
    if (payload.length !== 0) throw new NoiseError('non-empty handshake payload')
    return new NoiseSession(this.hs.transport!, this.hs.remoteStatic!, this.mode)
  }

  get handshakeHash(): Uint8Array { return this.hs.handshakeHash }
}
