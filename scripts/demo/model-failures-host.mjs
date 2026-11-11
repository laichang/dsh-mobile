// Model failures demo host: real DSH Web with the bridge plugin, and
// DeepSeek replaced by a fake provider whose account has no balance (scripts/demo/fake-deepseek.mjs).
// The phone's task fails with DSH's QUOTA. When the UI test has seen the red failure card, the
// provider is "topped up"; the phone then sends a new message into the same session, and the task
// continues. At the end this script reads DSH's own record through the Web API: one session holds
// both messages and one reply, after the second; its first turn ended with QUOTA. Exits 0 when so.
//
// Env: DSHM_RUNTIME (~/.dshm/runtime), DSHM_HOME, DSHM_WEB_PORT, DSHM_BRIDGE_PORT,
// DSHM_FAILURE_SIGNALS (a directory: this script writes `bridge-port` and `topped-up`; the UI test
// writes `failed` and then `messages`).
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { connect } from 'node:net'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { setTimeout as delay } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'
import { startFakeDeepSeek } from './fake-deepseek.mjs'

const runtime = process.env.DSHM_RUNTIME ?? join(homedir(), '.dshm/runtime')
const home = process.env.DSHM_HOME
const signals = process.env.DSHM_FAILURE_SIGNALS
const port = process.env.DSHM_WEB_PORT
const bridgePort = Number(process.env.DSHM_BRIDGE_PORT)
assert.ok(home && signals && port && bridgePort, 'set DSHM_HOME, DSHM_FAILURE_SIGNALS, DSHM_WEB_PORT, DSHM_BRIDGE_PORT')
const dsh = join(runtime, 'node_modules/.bin/dsh')
const env = { ...process.env, DSH_HOME: home, DSHM_BRIDGE_HOST: '127.0.0.1', DSHM_BRIDGE_TLS: '1' }
const bridge = fileURLToPath(new URL('../../bridge', import.meta.url))
const add = spawnSync(dsh, ['plugin', '--profile', 'web', 'add', bridge], { env, encoding: 'utf8' })
assert.equal(add.status, 0, add.stderr || add.stdout)

const REPLY = 'Topped up: the model answered again in the same session.'
const provider = await startFakeDeepSeek({ runtime, successText: REPLY })
const host = spawn(dsh, ['web', '--no-open', '--port', port], {
  env: { ...env, DEEPSEEK_API_KEY: 'mock-key', DEEPSEEK_BASE_URL: provider.baseURL },
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
const listening = () => new Promise(resolve => {
  const socket = connect(bridgePort, '127.0.0.1', () => { socket.destroy(); resolve(true) })
  socket.once('error', () => resolve(false))
})

/** The user and assistant messages of one DSH session (text only), and how each turn ended. */
function record(records) {
  const messages = []
  const ends = []
  for (const { event } of records) {
    const data = event.data ?? {}
    if (event.type === 'user/message' && data.source?.kind === 'user') {
      messages.push({ fromUser: true, text: (data.content ?? []).filter(b => b.type === 'text').map(b => b.text).join('') })
    } else if (event.type === 'assistant/message') {
      messages.push({ fromUser: false, text: (data.message?.content ?? []).filter(b => b.type === 'text').map(b => b.text).join('') })
    } else if (event.type === 'turn/end') {
      ends.push(data.reason?.kind === 'error' ? 'error ' + data.reason.error?.code : data.reason?.kind)
    }
  }
  return { messages: messages.filter(m => m.text), ends }
}

try {
  await until(() => loginURL, 'Web launch URL', 90_000)
  await until(listening, 'the bridge listens on ' + bridgePort, 90_000)
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
  writeFileSync(join(signals, 'bridge-port'), String(bridgePort))
  console.log('DSH Web on ' + port + ', bridge on ' + bridgePort + ', DeepSeek has no balance')

  await until(() => existsSync(join(signals, 'failed')), 'the phone shows the failed task', 900_000)
  assert.ok(provider.traffic.some(r => r.status === 402), 'DSH asked the provider and got 402')
  provider.topUp()
  writeFileSync(join(signals, 'topped-up'), '1')
  console.log('topped up')

  await until(() => existsSync(join(signals, 'messages')), 'the phone continues the task', 900_000)
  const [prompt, followUp] = readFileSync(join(signals, 'messages'), 'utf8').split('\n')

  // DSH's own record: one session, the two messages, one reply after the second.
  const { items } = await rpc('session/list', { _request: {} })
  const sessions = []
  for (const item of items) {
    const { records } = await rpc('session/events', { request: { address: { kind: 'session', sessionId: item.sessionId }, maxMessages: 32 } })
    sessions.push({ id: item.sessionId, ...record(records) })
  }
  const session = sessions.find(s => s.messages.some(m => m.fromUser && m.text === prompt))
  assert.ok(session, 'no DSH session has the prompt: ' + JSON.stringify(sessions))
  assert.deepEqual(session.messages.map(m => m.fromUser ? 'user: ' + m.text : 'agent: ' + m.text),
    ['user: ' + prompt, 'user: ' + followUp, 'agent: ' + REPLY], JSON.stringify(session.messages))
  assert.deepEqual(session.ends, ['error QUOTA', 'completed'])
  console.log('DSH session ' + session.id + ': turns ' + session.ends.join(', ') + '; ' +
    session.messages.map(m => (m.fromUser ? 'user' : 'agent') + ' ' + JSON.stringify(m.text)).join(' | '))
  console.log('model-failures host: the task failed with QUOTA and continued in the same DSH session')
} finally {
  host.kill('SIGTERM')
  await exited
  await provider.close()
}
