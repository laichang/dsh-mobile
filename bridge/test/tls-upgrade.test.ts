import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { randomBytes, X509Certificate } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { connect } from 'node:tls'
import { test } from 'node:test'
import { auditPage } from '../src/devices/manage.ts'
import { listenerInfo } from '../src/pairing/announce.ts'
import { offerURL, parseOfferURL } from '../src/pairing/offer.ts'
import { listenTLS } from '../src/tls/listener.ts'
import { TLSRegistry } from '../src/tls/registry.ts'
import { connectDevice, issue, redeem } from './tls-client.ts'

for (const format of ['array', 'history']) {
  test('upgrades legacy ' + format + ' registry without granting access', async t => {
    const dir = mkdtempSync(join(tmpdir(), 'dshm-upgrade-'))
    const id = randomBytes(16).toString('base64url'), secret = randomBytes(32).toString('base64url')
    const device = { id: 'previous-phone', publicKey: secret, pairedAt: 100, lastSeenAt: 300, offerId: id }
    const paired = { id: 'pair:' + id, atMs: 100, actor: 'owner', device: device.id, action: 'Device paired', detail: device.id }
    const revoked = { ...paired, id: 'revoke:old', atMs: 200, action: 'Device revoked' }
    const old = JSON.stringify(format === 'array' ? [device] : { devices: [], history: [paired, revoked] })
    writeFileSync(join(dir, 'devices.json'), old)
    writeFileSync(join(dir, 'host-key.json'), JSON.stringify({ publicKey: secret, privateKey: secret }))
    writeFileSync(join(dir, 'offers.json'), JSON.stringify([{ id, secret, expiresAt: Date.now() + 60_000 }]))
    writeFileSync(join(dir, 'approvals.jsonl'), Array.from({ length: 55 }, (_, n) => JSON.stringify({
      id: String(n), when: new Date(1000 + n).toISOString(), by: device.id, device: device.id,
      outcome: 'allowed', tool: 'read', argumentsJson: 'old file',
    })).join('\n'))
    const server = await listenTLS('127.0.0.1', 0, dir, ws => ws.close())
    t.after(async () => { await server.close(); rmSync(dir, { recursive: true, force: true }) })
    const offer = await issue(dir)
    const decoded = parseOfferURL(offer.href)
    assert.deepEqual(parseOfferURL(offerURL(decoded)), decoded)
    assert.throws(() => parseOfferURL(offer.href.replace('v=2', 'v=1')), /unsupported/)
    const legacy = new URL(offer)
    legacy.searchParams.set('i', id)
    legacy.searchParams.set('s', secret)
    await assert.rejects(redeem(dir, legacy), /refused/)
    await assert.rejects(connectDevice(dir, listenerInfo('127.0.0.1', server.port).addresses[0], secret), /403/)
    const fresh = await redeem(dir, offer)
    const store = new TLSRegistry(dir)
    assert.deepEqual(store.devices().map(d => d.id), [fresh.id])
    const first = auditPage(store, ''), next = auditPage(store, first.nextBeforeId)
    const entries = [...first.entries, ...next.entries]
    assert.equal(first.entries.length, 50)
    assert.equal(next.nextBeforeId, '')
    assert.equal(new Set(entries.map(e => e.id)).size, entries.length)
    assert.equal(entries.filter(e => e.action === 'Approval allowed').length, 55)
    assert.equal(entries[0].device, fresh.id)
    assert.equal(entries.at(-1)?.device, device.id)
    assert.equal(entries.at(-1)?.atMs, 100n)
    assert.equal(entries.filter(e => e.action === 'Device revoked').length, format === 'history' ? 1 : 0)
    assert.equal(readFileSync(join(dir, 'devices.json'), 'utf8'), old)
  })
}

test('a running listener refreshes its certificate before expiry without an offer', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] })
  const dir = mkdtempSync(join(tmpdir(), 'dshm-renew-'))
  const host = await listenTLS('127.0.0.1', 0, dir, ws => ws.close())
  t.after(async () => { await host.close(); rmSync(dir, { recursive: true, force: true }) })
  const key = join(dir, 'tls/host-key.pem'), cert = join(dir, 'tls/host-cert.pem')
  const original = new X509Certificate(readFileSync(cert))
  execFileSync('openssl', ['req', '-x509', '-new', '-key', key, '-out', cert, '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=IP:127.0.0.1'])
  const nearExpiry = new X509Certificate(readFileSync(cert))
  t.mock.timers.tick(24 * 3600_000)
  const renewed = new X509Certificate(readFileSync(cert))
  assert.ok(renewed.publicKey.equals(nearExpiry.publicKey))
  assert.ok(renewed.validToDate > nearExpiry.validToDate)
  assert.notEqual(original.fingerprint256, renewed.fingerprint256)
  await new Promise<void>((resolve, reject) => {
    const socket = connect({ host: '127.0.0.1', port: host.port, ca: renewed.toString(), minVersion: 'TLSv1.3' }, () => {
      const served = socket.getPeerX509Certificate()?.fingerprint256
      socket.end()
      if (served === renewed.fingerprint256) resolve()
      else reject(new Error('listener did not serve its renewed certificate'))
    })
    socket.once('error', reject)
  })
})
