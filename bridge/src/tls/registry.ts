import { createHash, randomBytes, randomUUID } from 'node:crypto'
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { ListenerInfo } from '../pairing/announce.ts'
import type { PairingOffer } from '../pairing/offer.ts'

interface Device { id: string; digest: string; pairedAt: number; lastSeenAt: number }
interface Audit { id: string; atMs: number; actor: string; device: string; action: string; detail: string }
const digest = (value: string) => createHash('sha256').update(value).digest('hex')

/** The listener is the sole writer. Outstanding offers expire on restart. */
export class TLSRegistry {
  private readonly offers = new Map<string, { hash: string; expires: number }>()
  private readonly file: string
  private data: { devices: Device[]; history: Audit[] }
  constructor(readonly dir: string, readonly now = Date.now) {
    this.file = join(dir, 'tls', 'devices.json')
    this.data = existsSync(this.file) ? JSON.parse(readFileSync(this.file, 'utf8')) : { devices: [], history: [] }
  }

  issue(listener: ListenerInfo, pin: Buffer, ttl: number): PairingOffer {
    if (!Number.isFinite(ttl) || ttl <= 0 || ttl > 3600_000) throw new Error('offer lifetime must be at most one hour')
    const now = this.now()
    for (const [id, offer] of this.offers) if (offer.expires <= now) this.offers.delete(id)
    const offerId = randomBytes(16), secret = randomBytes(32)
    this.offers.set(offerId.toString('base64url'), { hash: digest(secret.toString('base64url')), expires: now + ttl })
    return { ...listener, version: 2, hostKey: pin, offerId, secret, expiresAt: now + ttl }
  }

  redeem(id: string, secret: string) {
    const offer = this.offers.get(id), now = this.now()
    if (!offer || offer.expires <= now || offer.hash !== digest(secret)) return
    this.offers.delete(id)
    const bearer = randomBytes(32).toString('base64url')
    const device = { id: randomUUID(), digest: digest(bearer), pairedAt: now, lastSeenAt: now }
    this.write([...this.data.devices, device], { id: 'pair:' + id, atMs: now, actor: 'owner', device: device.id,
      action: 'Device paired', detail: device.id })
    return { id: device.id, bearer }
  }

  authenticate(header: string | undefined) {
    if (!header || !/^Bearer [A-Za-z0-9_-]{43}$/.test(header)) return
    const hash = digest(header.slice(7))
    return this.data.devices.find(d => d.digest === hash)?.id
  }

  has(id: string) { return this.data.devices.some(d => d.id === id) }
  devices() { return this.data.devices }
  pairingHistory(): Audit[] {
    const path = join(this.dir, 'devices.json')
    if (!existsSync(path)) return this.data.history
    const legacy = JSON.parse(readFileSync(path, 'utf8')) as { id: string; offerId: string; pairedAt: number }[] | { history: Audit[] }
    const rows = Array.isArray(legacy) ? legacy.map(d => ({
      id: 'pair:' + d.offerId, atMs: d.pairedAt, actor: 'owner', device: d.id, action: 'Device paired', detail: d.id,
    })) : legacy.history
    return [...this.data.history, ...rows.map(row => ({ ...row, id: 'legacy:' + row.id }))]
  }

  seen(id: string) {
    this.write(this.data.devices.map(d => d.id === id ? { ...d, lastSeenAt: this.now() } : d))
  }

  revoke(id: string, actor: string) {
    if (!this.has(id)) throw new Error('Device is no longer paired.')
    this.write(this.data.devices.filter(d => d.id !== id), { id: 'revoke:' + randomUUID(), atMs: this.now(),
      actor: 'owner', device: actor, action: 'Device revoked', detail: id })
  }

  private write(devices: Device[], entry?: Audit) {
    const data = { devices, history: entry ? [...this.data.history, entry] : this.data.history }
    writeFileSync(this.file + '.new', JSON.stringify(data), { mode: 0o600 })
    renameSync(this.file + '.new', this.file)
    this.data = data
  }
}
