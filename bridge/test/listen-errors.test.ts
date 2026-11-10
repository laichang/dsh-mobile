/**
 * A bridge that cannot listen says why in one line of DSH's log: the address,
 * the cause and the setting to change. The plugin's `apply` keeps DSH running: no throw, no
 * unhandled rejection, and a clean dispose.
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { createServer, type Server } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, describe, test } from 'node:test'
import { apply, resolveConfig } from '../src/index.ts'
import { describeListenError } from '../src/listen-error.ts'

/** A program that holds a port, as another app on the user's computer would. */
async function holdPort(host = '127.0.0.1'): Promise<{ server: Server; port: number }> {
  const server = createServer(() => {})
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(0, host, resolve) })
  const address = server.address()
  assert.ok(address && typeof address === 'object')
  return { server, port: address.port }
}

/** The part of the Cordis context `apply` uses when DSH's version is not the supported one. */
function fakeContext() {
  const lines: { level: string; text: string }[] = []
  const disposers: (() => void)[] = []
  const ctx = {
    logger: () => ({
      info: (m: string) => { lines.push({ level: 'info', text: m }) },
      warn: (m: string) => { lines.push({ level: 'warn', text: m }) },
      error: (m: string) => { lines.push({ level: 'error', text: m }) },
    }),
    effect(setup: () => () => void) { disposers.push(setup()) },
    on: () => () => {},
    waterfall: async () => 'unavailable',
  }
  return { ctx, lines, dispose: () => { for (const d of disposers.splice(0)) d() } }
}

async function until(condition: () => boolean, ms = 3000) {
  const deadline = Date.now() + ms
  while (!condition()) {
    if (Date.now() > deadline) throw new Error('timed out')
    await new Promise(r => setTimeout(r, 10))
  }
}

const cleanups: (() => void)[] = []
after(() => { for (const c of cleanups) c() })

describe('ListenErrors', () => {
  test('portTakenLogsOneLineWithPortCauseAndFixAndDshKeepsRunning', async (t) => {
    const terminal = t.mock.method(console, 'error', () => {})
    const { server, port } = await holdPort()
    cleanups.push(() => server.close())
    const stateDir = mkdtempSync(join(tmpdir(), 'dshm-listen-'))
    cleanups.push(() => rmSync(stateDir, { recursive: true, force: true }))
    const rejections: unknown[] = []
    const onRejection = (e: unknown) => { rejections.push(e) }
    process.on('unhandledRejection', onRejection)
    cleanups.push(() => process.off('unhandledRejection', onRejection))

    const { ctx, lines, dispose } = fakeContext()
    // `apply` returns normally: DSH goes on loading its other plugins.
    assert.doesNotThrow(() => apply(ctx as unknown as Parameters<typeof apply>[0], { host: '127.0.0.1', port, stateDir }))
    await until(() => lines.some(l => l.level === 'error'))
    await new Promise(r => setTimeout(r, 100)) // nothing else follows

    const errors = lines.filter(l => l.level === 'error' || l.level === 'warn')
    assert.equal(errors.length, 1, JSON.stringify(lines))
    const line = errors[0].text
    assert.ok(!line.includes('\n'), line)
    assert.match(line, new RegExp(`127\\.0\\.0\\.1:${port}`))
    assert.match(line, /another program uses port/)
    assert.match(line, /EADDRINUSE/)
    assert.match(line, /cordis\.yml/) // the setting to change
    assert.match(line, /`port`/)
    assert.match(line, /DSH keeps running/)
    assert.deepEqual(rejections, [])
    // The same line on the terminal (stderr): `dsh web` gives the logger no console exporter.
    assert.deepEqual(terminal.mock.calls.map(c => c.arguments), [[`[dsh-mobile-bridge] ${line}`]])

    // The plugin can still be stopped (DSH reload or shutdown), and the port holder is untouched.
    assert.doesNotThrow(dispose)
    assert.ok(server.listening)
  })

  test('eachCauseNamesItsFix', () => {
    const at = { host: '0.0.0.0', port: 47801, portFrom: 'default' as const }
    const inUse = describeListenError(Object.assign(new Error('listen EADDRINUSE'), { code: 'EADDRINUSE' }), at)
    assert.match(inUse, /0\.0\.0\.0:47801: another program uses port 47801 \(EADDRINUSE\)/)
    assert.match(inUse, /lsof -nP -iTCP:47801 -sTCP:LISTEN/)
    assert.match(inUse, /pair the phone again/)

    const denied = describeListenError(Object.assign(new Error('listen EACCES'), { code: 'EACCES' }), { ...at, port: 80 })
    assert.match(denied, /may not open port 80 \(EACCES\)/)
    assert.match(denied, /from 1024 to 65535/)

    const env = describeListenError(Object.assign(new Error('x'), { code: 'EADDRINUSE' }), { ...at, portFrom: 'env' })
    assert.match(env, /DSHM_BRIDGE_PORT/)
    assert.doesNotMatch(env, /cordis\.yml/)

    const other = describeListenError(new Error('plaintext needs a loopback host'), at)
    assert.match(other, /cannot listen on 0\.0\.0\.0:47801: plaintext needs a loopback host\. /)
  })

  test('anAddressThatIsNotOnThisComputerIsNamed', async () => {
    // 192.0.2.1 (TEST-NET-1) is never an address of this computer.
    const listen = new Promise<unknown>((resolve) => {
      const s = createServer()
      s.once('error', resolve)
      s.listen(0, '192.0.2.1', () => { s.close(); resolve(undefined) })
    })
    const error = await listen
    assert.ok(error, 'expected EADDRNOTAVAIL')
    const line = describeListenError(error, { host: '192.0.2.1', port: 47801, portFrom: 'config' })
    assert.match(line, /192\.0\.2\.1 is not an address of this computer \(EADDRNOTAVAIL\)/)
    assert.match(line, /set `host`/)
  })

  test('configSaysWhereThePortCameFrom', () => {
    assert.equal(resolveConfig({ port: 47811 }, {}).portFrom, 'config')
    assert.equal(resolveConfig({}, { DSHM_BRIDGE_PORT: '47810' }).portFrom, 'env')
    assert.equal(resolveConfig({}, {}).portFrom, 'default')
  })
})
