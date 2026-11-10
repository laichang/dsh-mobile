/**
 * Terminal-first pairing UI: pick the addresses a phone can reach, make an
 * offer, and print it as a QR code plus the `dshm://pair?…` link.
 */
import { hostname, networkInterfaces } from 'node:os'
import { renderUnicodeCompact } from 'uqr'
import { isLoopbackAddress } from '../channel.ts'
import { joinAddress, offerURL, type PairingOffer } from './offer.ts'
import { DEFAULT_OFFER_TTL_MS, type ListenerInfo, type PairingStore } from './store.ts'

/**
 * Where a phone can reach a listener bound to `host`. A wildcard bind lists every external
 * IPv4 address (Wi-Fi, Ethernet, Tailscale's 100.x), so the QR works on the LAN and over a VPN.
 */
export function reachableAddresses(host: string, port: number): string[] {
  if (host !== '0.0.0.0' && host !== '::') return [joinAddress(host, port)]
  const out: string[] = []
  for (const list of Object.values(networkInterfaces())) {
    for (const a of list ?? []) {
      if (a.family === 'IPv4' && !a.internal && !a.address.startsWith('169.254.')) out.push(joinAddress(a.address, port))
    }
  }
  return out.length > 0 ? out : [joinAddress('127.0.0.1', port)]
}

export function listenerInfo(host: string, port: number): ListenerInfo {
  return { hostName: hostname().replace(/\.local$/, ''), addresses: reachableAddresses(host, port) }
}

/** Creates a fresh single-use offer for the listener the store last recorded. */
export function makeOffer(store: PairingStore, ttlMs = DEFAULT_OFFER_TTL_MS, listener = store.listener()): PairingOffer {
  if (!listener) throw new Error(`no listener recorded in ${store.dir}; start the bridge first`)
  const offer = store.createOffer(ttlMs)
  return {
    hostName: listener.hostName,
    addresses: listener.addresses,
    hostKey: store.hostKey().publicKey,
    offerId: offer.id,
    secret: offer.secret,
    expiresAt: offer.expiresAt,
  }
}

export function renderOffer(offer: PairingOffer): string {
  const url = offerURL(offer)
  const minutes = Math.round((offer.expiresAt - Date.now()) / 60000)
  const loopbackOnly = offer.addresses.every((a) => isLoopbackAddress(a.replace(/:\d+$/, '')))
  return [
    'Scan with dsh-mobile to pair this host (single use, expires in ' + `${minutes} min):`,
    renderUnicodeCompact(url, { ecc: 'L', border: 2 }),
    `Addresses: ${offer.addresses.join(', ')}${loopbackOnly ? ' (loopback only: Simulator on this Mac)' : ''}`,
    `Link: ${url}`,
  ].join('\n')
}
