/**
 * Terminal-first pairing UI: pick the addresses a phone can reach, make an
 * offer, and print it as a QR code plus the `dshm://pair?…` link.
 */
import { hostname, networkInterfaces } from 'node:os'
import { renderUnicodeCompact } from 'uqr'
import { isIP } from 'node:net'
import { joinAddress, offerURL, type PairingOffer } from './offer.ts'
export interface ListenerInfo { hostName: string; addresses: string[] }

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

function isLoopbackAddress(host: string): boolean {
  const h = host.startsWith('[') && host.endsWith(']') ? host.slice(1, -1) : host
  if (isIP(h) === 4) return h.split('.')[0] === '127'
  if (isIP(h) === 6) return h === '::1' || h.toLowerCase() === '0:0:0:0:0:0:0:1'
  return false // names (even "localhost") can resolve anywhere; require a literal address
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
