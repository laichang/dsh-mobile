/**
 * The pairing offer the QR carries, as a `dshm://pair?…` URL. The same URL
 * is the Debug-only deep link, so the Simulator can pair without a camera. Parsed by
 * ios/DSHKit/Sources/DSHCore/Pairing/PairingOffer.swift.
 *
 *   dshm://pair?v=1&n=<host name>&a=<host:port>,<host:port>&k=<host key>&i=<offer id>&s=<secret>&x=<expiry>
 *
 * k, i and s are unpadded base64url (32, 16 and 32 bytes); x is Unix seconds.
 */
import { KEY_LENGTH, OFFER_ID_LENGTH, SECRET_LENGTH, b64url, unb64url } from './wire.ts'

export interface PairingOffer {
  version?: 1 | 2
  hostName: string
  /** "host:port", IPv6 hosts in brackets. Tried in order. */
  addresses: string[]
  hostKey: Uint8Array
  offerId: Uint8Array
  secret: Uint8Array
  /** Unix milliseconds. */
  expiresAt: number
}

export function offerURL(o: PairingOffer): string {
  const q = new URLSearchParams({
    v: String(o.version ?? 1),
    n: o.hostName,
    a: o.addresses.join(','),
    k: b64url(o.hostKey),
    i: b64url(o.offerId),
    s: b64url(o.secret),
    x: String(Math.floor(o.expiresAt / 1000)),
  })
  return `dshm://pair?${q.toString()}`
}

export function parseOfferURL(url: string): PairingOffer {
  const u = new URL(url)
  if (u.protocol !== 'dshm:' || u.host !== 'pair') throw new Error('not a dshm://pair link')
  const q = u.searchParams
  if (q.get('v') !== '1' && q.get('v') !== '2') throw new Error(`unsupported pairing link version ${q.get('v')}`)
  const bytes = (key: string, length: number) => {
    const b = unb64url(q.get(key) ?? '')
    if (b.length !== length) throw new Error(`pairing link field ${key} must be ${length} bytes`)
    return b
  }
  const addresses = (q.get('a') ?? '').split(',').filter(Boolean)
  if (addresses.length === 0) throw new Error('pairing link has no address')
  const x = Number(q.get('x'))
  if (!Number.isFinite(x) || x <= 0) throw new Error('pairing link has no expiry')
  return {
    ...(q.get('v') === '2' ? { version: 2 as const } : {}),
    hostName: q.get('n') ?? '',
    addresses,
    hostKey: bytes('k', KEY_LENGTH),
    offerId: bytes('i', OFFER_ID_LENGTH),
    secret: bytes('s', SECRET_LENGTH),
    expiresAt: x * 1000,
  }
}

/** "host:port" → parts; IPv6 in brackets. */
export function splitAddress(address: string): { host: string; port: number } {
  const m = /^\[([^\]]+)\]:(\d+)$/.exec(address) ?? /^([^:]+):(\d+)$/.exec(address)
  if (!m) throw new Error(`bad address ${address}`)
  return { host: m[1], port: Number(m[2]) }
}

export function joinAddress(host: string, port: number): string {
  return host.includes(':') ? `[${host}]:${port}` : `${host}:${port}`
}
