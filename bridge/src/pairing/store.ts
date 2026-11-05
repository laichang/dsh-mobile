/**
 * The bridge's pairing state on disk (ARCHITECTURE D21): the host's Noise static key, open
 * pairing offers, and the device registry. One directory, default `$DSH_HOME/dsh-mobile-bridge`,
 * mode 0700, files 0600. Every call re-reads the files, so `scripts/pair.ts` (a separate
 * process) can add offers while the bridge runs. Writes are atomic (temp file + rename).
 *
 */
import { createHash, randomBytes, randomUUID } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { generateKeyPair, keyPairFromSecret, type KeyPair } from './noise.ts'
import { OFFER_ID_LENGTH, SECRET_LENGTH, b64url, unb64url } from './wire.ts'

export const DEFAULT_OFFER_TTL_MS = 10 * 60 * 1000

export interface Offer {
  id: Uint8Array
  secret: Uint8Array
  createdAt: number
  expiresAt: number
  usedAt?: number
}

export interface Device {
  /** Short, stable id: hex of the first 8 bytes of sha256(publicKey). */
  id: string
  publicKey: Uint8Array
  pairedAt: number
  lastSeenAt: number
  /** Which offer paired it (base64url). */
  offerId: string
}

/** What the listener tells `scripts/pair.ts`, so it can print the right addresses. */
export interface ListenerInfo {
  hostName: string
  addresses: string[]
}

export type OfferRejection = 'unknown' | 'expired' | 'used'

export class OfferRejected extends Error {
  constructor(readonly reason: OfferRejection) { super(`pairing offer ${reason}`) }
}

interface OfferJSON { id: string; secret: string; createdAt: number; expiresAt: number; usedAt?: number }
interface DeviceJSON { id: string; publicKey: string; pairedAt: number; lastSeenAt: number; offerId: string }

interface PairingAudit {
  id: string
  atMs: number
  actor: string
  device: string
  action: string
  detail: string
}
interface Registry { devices: DeviceJSON[]; history: PairingAudit[] }
function paired(d: DeviceJSON): PairingAudit {
  return { id: 'pair:' + d.offerId, atMs: d.pairedAt, actor: 'owner', device: d.id, action: 'Device paired', detail: d.id }
}

export const deviceId = (publicKey: Uint8Array): string =>
  createHash('sha256').update(publicKey).digest('hex').slice(0, 16)

export class PairingStore {
  constructor(readonly dir: string, private readonly now: () => number = Date.now) {
    mkdirSync(dir, { recursive: true, mode: 0o700 })
  }

  // MARK: host key

  /** Loads the host's X25519 static key, creating it on first use. */
  hostKey(): KeyPair {
    const stored = this.read<{ secretKey: string }>('host-key.json')
    if (stored) return keyPairFromSecret(unb64url(stored.secretKey))
    const kp = generateKeyPair()
    this.write('host-key.json', { secretKey: b64url(kp.secretKey) })
    return kp
  }

  // MARK: offers

  createOffer(ttlMs = DEFAULT_OFFER_TTL_MS): Offer {
    const now = this.now()
    const offer: Offer = {
      id: new Uint8Array(randomBytes(OFFER_ID_LENGTH)),
      secret: new Uint8Array(randomBytes(SECRET_LENGTH)),
      createdAt: now,
      expiresAt: now + ttlMs,
    }
    // Drop offers that can no longer be used, keep the rest.
    const kept = this.offersJSON().filter((o) => o.usedAt === undefined && o.expiresAt > now)
    this.write('offers.json', [...kept, toOfferJSON(offer)])
    return offer
  }

  /** The offer with this id, if it can still be used; otherwise throws `OfferRejected`. */
  usableOffer(id: Uint8Array): Offer {
    const key = b64url(id)
    const o = this.offersJSON().find((x) => x.id === key)
    if (!o) throw new OfferRejected('unknown')
    if (o.usedAt !== undefined) throw new OfferRejected('used')
    if (o.expiresAt <= this.now()) throw new OfferRejected('expired')
    return fromOfferJSON(o)
  }

  /** Marks an offer used. Called on the first valid message 1, before the host answers. */
  markOfferUsed(id: Uint8Array): void {
    const key = b64url(id)
    const now = this.now()
    this.write('offers.json', this.offersJSON().map((o) => (o.id === key ? { ...o, usedAt: now } : o)))
  }

  offers(): Offer[] { return this.offersJSON().map(fromOfferJSON) }

  // MARK: devices

  devices(): Device[] { return this.registry().devices.map(fromDeviceJSON) }

  findDevice(publicKey: Uint8Array): Device | undefined {
    const key = b64url(publicKey)
    const d = this.registry().devices.find((x) => x.publicKey === key)
    return d && fromDeviceJSON(d)
  }

  /** Adds (or refreshes) a device. Called after its first valid transport message. */
  registerDevice(publicKey: Uint8Array, offerId: Uint8Array): Device {
    const now = this.now()
    const key = b64url(publicKey)
    const registry = this.registry()
    const others = registry.devices.filter((d) => d.publicKey !== key)
    const device: DeviceJSON = {
      id: deviceId(publicKey), publicKey: key, pairedAt: now, lastSeenAt: now, offerId: b64url(offerId),
    }
    this.write('devices.json', { devices: [...others, device], history: [...registry.history, paired(device)] })
    return fromDeviceJSON(device)
  }

  touchDevice(publicKey: Uint8Array): void {
    const key = b64url(publicKey)
    const now = this.now()
    const registry = this.registry()
    const device = registry.devices.find(d => d.publicKey === key)
    if (!device) throw new Error('device not paired')
    device.lastSeenAt = now
    this.write('devices.json', registry)
  }

  pairingHistory(): PairingAudit[] { return this.registry().history }

  revoke(id: string, actorDevice: string): void {
    const registry = this.registry()
    if (!registry.devices.some(d => d.id === id)) throw new Error('Device is no longer paired.')
    registry.devices = registry.devices.filter(d => d.id !== id)
    registry.history.push({ id: 'revoke:' + randomUUID(), atMs: this.now(), actor: 'owner',
      device: actorDevice, action: 'Device revoked', detail: id })
    // One atomic rename records both the loss of access and who requested it.
    this.write('devices.json', registry)
  }

  // MARK: listener

  writeListener(info: ListenerInfo): void { this.write('listener.json', info) }
  listener(): ListenerInfo | undefined { return this.read<ListenerInfo>('listener.json') }

  // MARK: files

  private offersJSON(): OfferJSON[] { return this.read<OfferJSON[]>('offers.json') ?? [] }
  private registry(): Registry {
    const value = this.read<DeviceJSON[] | Registry>('devices.json')
    // S1 stored an array. Its pairedAt and offer ID provide the original pairing event.
    if (Array.isArray(value)) return { devices: value, history: value.map(paired) }
    return value ?? { devices: [], history: [] }
  }

  private read<T>(name: string): T | undefined {
    const path = join(this.dir, name)
    if (!existsSync(path)) return undefined
    return JSON.parse(readFileSync(path, 'utf8')) as T
  }

  private write(name: string, value: unknown): void {
    const path = join(this.dir, name)
    const tmp = `${path}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`
    writeFileSync(tmp, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 })
    chmodSync(tmp, 0o600)
    renameSync(tmp, path)
  }
}

const toOfferJSON = (o: Offer): OfferJSON => ({
  id: b64url(o.id), secret: b64url(o.secret), createdAt: o.createdAt, expiresAt: o.expiresAt,
  ...(o.usedAt === undefined ? {} : { usedAt: o.usedAt }),
})
const fromOfferJSON = (o: OfferJSON): Offer => ({
  id: unb64url(o.id), secret: unb64url(o.secret), createdAt: o.createdAt, expiresAt: o.expiresAt,
  ...(o.usedAt === undefined ? {} : { usedAt: o.usedAt }),
})
const fromDeviceJSON = (d: DeviceJSON): Device => ({ ...d, publicKey: unb64url(d.publicKey) })
