/**
 * Transport security seam. PlaintextChannel refuses any
 * non-loopback address; the Noise channel sits behind the same interface.
 */
import { isIP } from 'node:net'

export interface SecureChannel {
  readonly name: string
  /** Throws if this channel may not be used to listen on `host`. */
  assertListenAddress(host: string): void
  /** Wraps an outgoing frame for the wire. */
  seal(plaintext: Uint8Array): Uint8Array
  /** Unwraps an incoming wire message. */
  open(ciphertext: Uint8Array): Uint8Array
}

export function isLoopbackAddress(host: string): boolean {
  const h = host.startsWith('[') && host.endsWith(']') ? host.slice(1, -1) : host
  if (isIP(h) === 4) return h.split('.')[0] === '127'
  if (isIP(h) === 6) return h === '::1' || h.toLowerCase() === '0:0:0:0:0:0:0:1'
  return false // names (even "localhost") can resolve anywhere; require a literal address
}

export class PlaintextChannel implements SecureChannel {
  readonly name = 'plaintext'
  assertListenAddress(host: string): void {
    if (!isLoopbackAddress(host)) {
      throw new Error(`PlaintextChannel refuses non-loopback address ${JSON.stringify(host)}`)
    }
  }
  seal(plaintext: Uint8Array): Uint8Array { return plaintext }
  open(ciphertext: Uint8Array): Uint8Array { return ciphertext }
}
