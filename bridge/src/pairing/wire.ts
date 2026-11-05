/**
 * How a Noise connection starts on the bridge's WebSocket (ARCHITECTURE D6, D20). Mirrored in
 * ios/DSHKit/Sources/DSHCore/Pairing/PairingWire.swift; the golden transcripts in
 * protocol/fixtures/noise/ keep the two sides in step.
 *
 * The app's first binary message is a short header followed by Noise message 1:
 *
 *   pair:      [WIRE_VERSION, Mode.Pair, offerId (16 bytes)] ‖ IKpsk1 message 1
 *   reconnect: [WIRE_VERSION, Mode.Reconnect]                ‖ IK message 1
 *
 * The header is bound into the Noise prologue ("dshm/1" ‖ header), so tampering with the mode
 * or the offer id just fails the handshake. The bridge answers with Noise message 2 (no header).
 * Handshake payloads are empty; after that every binary message is one Noise transport message
 * carrying one protobuf `Frame`, and `Hello` is the first one.
 */

export const WIRE_VERSION = 1
export const PROLOGUE_LABEL = 'dshm/1'
export const PAIR_PROTOCOL = 'Noise_IKpsk1_25519_ChaChaPoly_SHA256'
export const RECONNECT_PROTOCOL = 'Noise_IK_25519_ChaChaPoly_SHA256'
export const OFFER_ID_LENGTH = 16
export const SECRET_LENGTH = 32
export const KEY_LENGTH = 32

export const Mode = { Pair: 1, Reconnect: 2 } as const
export type Mode = (typeof Mode)[keyof typeof Mode]

/** WebSocket close codes the bridge uses to say why a Noise connection was refused. */
export const CloseCode = {
  /** The first message is not a well-formed header + Noise message 1. */
  BadHello: 4000,
  /** Pairing: the offer is unknown, expired, already used, or the secret is wrong. */
  PairingRejected: 4001,
  /** The Noise handshake failed (wrong host key, tampering, bad payload). */
  HandshakeFailed: 4002,
  /** Reconnect: the device's static key isn't in the registry (never paired, or revoked). */
  DeviceUnknown: 4003,
} as const

export interface FirstMessage {
  mode: Mode
  offerId?: Uint8Array
  /** The header bytes, as they go into the prologue. */
  header: Uint8Array
  noise: Uint8Array
}

export function encodeFirstMessage(mode: Mode, noise: Uint8Array, offerId?: Uint8Array): Uint8Array {
  return concat(header(mode, offerId), noise)
}

export function header(mode: Mode, offerId?: Uint8Array): Uint8Array {
  if (mode === Mode.Pair) {
    if (offerId?.length !== OFFER_ID_LENGTH) throw new Error('pairing needs a 16-byte offer id')
    return concat(Uint8Array.of(WIRE_VERSION, mode), offerId)
  }
  return Uint8Array.of(WIRE_VERSION, mode)
}

/** Returns undefined if the bytes can't be a first message. */
export function decodeFirstMessage(bytes: Uint8Array): FirstMessage | undefined {
  if (bytes.length < 2 || bytes[0] !== WIRE_VERSION) return undefined
  const mode = bytes[1]
  if (mode === Mode.Pair) {
    const end = 2 + OFFER_ID_LENGTH
    if (bytes.length <= end) return undefined
    return { mode, offerId: bytes.slice(2, end), header: bytes.slice(0, end), noise: bytes.slice(end) }
  }
  if (mode === Mode.Reconnect) {
    if (bytes.length <= 2) return undefined
    return { mode, header: bytes.slice(0, 2), noise: bytes.slice(2) }
  }
  return undefined
}

export function prologue(headerBytes: Uint8Array): Uint8Array {
  return concat(new TextEncoder().encode(PROLOGUE_LABEL), headerBytes)
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let o = 0
  for (const p of parts) { out.set(p, o); o += p.length }
  return out
}

export const b64url = (b: Uint8Array): string => Buffer.from(b).toString('base64url')
export const unb64url = (s: string): Uint8Array => new Uint8Array(Buffer.from(s, 'base64url'))
