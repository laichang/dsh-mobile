// Real Web gateway peer. The Simulator signals when the detail is open and when the app is offline.
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, realpathSync, writeFileSync } from 'node:fs'
import { createConnection, createServer } from 'node:net'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { setTimeout as delay } from 'node:timers/promises'
import { fileURLToPath, pathToFileURL } from 'node:url'

const runtime = process.env.DSHM_RUNTIME ?? join(homedir(), '.dshm/runtime')
const home = process.env.DSHM_HOME
const signals = process.env.DSHM_VISIBILITY_SIGNALS
const port = process.env.DSHM_WEB_PORT
const dsh = join(runtime, 'node_modules/.bin/dsh')
const env = { ...process.env, DSH_HOME: home }
const bridge = fileURLToPath(new URL('../../bridge', import.meta.url))
const add = spawnSync(dsh, ['plugin', '--profile', 'web', 'add', bridge], { env, encoding: 'utf8' })
assert.equal(add.status, 0, add.stderr || add.stdout)
const documents = join(home, 'Documents')
mkdirSync(documents, { recursive: true })
writeFileSync(join(home, 'profiles/web/cordis.patch.yml'),
  '- id: workspace-controller\n  config:\n    documentsDirectory: ' + JSON.stringify(documents) + '\n')

const { startMockLlmServer } = await import(pathToFileURL(join(runtime,
  'node_modules/@deepseek-ai/dsh-llm-mock-server/lib/index.js')))
const mock = await startMockLlmServer({ sequence: ['success'], repeatLast: true, successText: '已收到。' })
const host = spawn(dsh, ['web', '--no-open', '--port', port], {
  env: { ...env, DEEPSEEK_API_KEY: 'mock-key', DEEPSEEK_BASE_URL: mock.baseURL + '/v1' },
  stdio: ['ignore', 'pipe', 'pipe'],
})
const exited = new Promise(resolve => host.once('exit', resolve))
const lifetime = new AbortController()
process.once('SIGTERM', () => lifetime.abort())
host.once('exit', () => lifetime.abort())
let loginURL
for (const output of [host.stdout, host.stderr]) {
  createInterface({ input: output }).on('line', line => {
    const url = line.match(/https?:\/\/[^\s]+\?token=[\w-]+/)
    if (url) loginURL = new URL(url[0])
    else if (/error|warn/i.test(line)) console.error(line.replace(/token=\S+/g, 'token=<redacted>'))
  })
}
async function until(probe, name, ms) {
  const start = Date.now()
  while (!(await probe())) {
    if (Date.now() - start > ms) throw new Error('Timed out: ' + name)
    await delay(150, undefined, { signal: lifetime.signal })
  }
}
const signal = name => writeFileSync(join(signals, name), '')
const gate = name => until(() => existsSync(join(signals, name)), name, 300_000)
// Closing this relay drops only the phone's link. DSH Web keeps running the same session.
let online = true
const clients = new Set()
const relay = createServer(phone => {
  if (!online) return phone.destroy()
  const bridge = createConnection(Number(process.env.DSHM_BRIDGE_PORT), '127.0.0.1')
  clients.add(phone)
  phone.on('error', () => bridge.destroy())
  bridge.on('error', () => phone.destroy())
  phone.on('close', () => { clients.delete(phone); bridge.destroy() })
  bridge.on('close', () => phone.destroy())
  phone.pipe(bridge).pipe(phone)
})
try {
  await new Promise((ok, fail) => relay.once('error', fail).listen(0, '127.0.0.1', ok))
  writeFileSync(join(signals, 'phone-port'), String(relay.address().port))
  await until(() => loginURL, 'Web launch URL', 90_000)
  assert.equal(loginURL.port, port)
  assert.ok(['localhost', '127.0.0.1'].includes(loginURL.hostname))
  const login = await fetch(loginURL, { redirect: 'manual' })
  assert.equal(login.status, 303)
  const cookie = login.headers.get('set-cookie').split(';')[0]
  async function rpc(method, args) {
    const rpcId = crypto.randomUUID()
    const response = await fetch(new URL('/api/' + method, loginURL), {
      method: 'POST', headers: { cookie, origin: loginURL.origin, 'content-type': 'application/json' },
      body: JSON.stringify({ type: 'client-request', rpcId, method, payload: { args } }),
      signal: AbortSignal.timeout(20_000),
    })
    assert.equal(response.status, 200, method)
    const result = await response.json()
    assert.equal(result.rpcId, rpcId)
    assert.ok(result.result.ok, method + ': ' + JSON.stringify(result.result.error))
    return result.result.value
  }
  const { workspace } = await rpc('workspace/initializeDefault', {})
  assert.ok(workspace.path.startsWith(realpathSync(documents) + '/'), workspace.path)
  const { sessionId } = await rpc('session/create', { request: { workspaceId: workspace.workspaceId } })
  async function send(text, turn) {
    const { accepted } = await rpc('session/prompt', { request: {
      requestId: crypto.randomUUID(), sessionId, mode: 'queue', content: [{ type: 'text', text }],
    } })
    assert.ok(accepted)
    await until(async () => {
      const { records } = await rpc('session/events', { request: {
        address: { kind: 'session', sessionId }, maxMessages: 12,
      } })
      return records.filter(r => r.event.type === 'turn/end').length === turn
    }, 'Web turn ' + turn, 40_000)
    console.log('Web turn ' + turn + ' completed in ' + sessionId)
  }
  await rpc('session/rename', { request: { sessionId, title: '网页会话' } })
  await send('网页第一条', 1)
  signal('first-ready')
  await gate('detail-open')
  await send('网页第二条', 2)
  await gate('disconnect')
  online = false
  assert.ok(clients.size > 0, 'phone must be connected when we drop its socket')
  for (const phone of clients) phone.destroy()
  await send('离线第三条', 3)
  await send('离线第四条', 4)
  signal('offline-complete')
  await gate('reconnect')
  online = true
  await gate('verified')
} finally {
  relay.close()
  for (const phone of clients) phone.destroy()
  host.kill('SIGTERM')
  await exited
  await mock.close()
}
