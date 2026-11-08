// Follow-up demo host: real DSH Web with the bridge plugin and DSH's mock LLM, in the DSH home
// DSHM_HOME. It tells the Simulator the bridge port, waits until the phone has sent a task and a
// follow-up, and then reads DSH's own session list through the Web API: one DSH session must
// hold both messages, each with a reply after it (ARCHITECTURE D89). Exits 0 when it does.
//
// DSHM_FOLLOWUP_MODE=running (ARCHITECTURE D101): a slower mock reply (about 35 s), so a turn runs
// while the phone queues follow-ups. It waits for two UI tests: `messages-queue` (a prompt, a
// queued follow-up, and one sent now) and `messages-interrupt` (a prompt, stopped, and a message
// that continues it). DSH must hold each conversation in one session, in the order the agent
// took the messages: the one sent now in the first turn, the queued one as the next turn.
//
// Env: DSHM_RUNTIME (~/.dshm/runtime), DSHM_HOME, DSHM_WEB_PORT, DSHM_BRIDGE_PORT,
// DSHM_FOLLOWUP_SIGNALS (a directory: this script writes `bridge-port`; the UI tests write `messages*`).
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { connect } from 'node:net'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { setTimeout as delay } from 'node:timers/promises'
import { fileURLToPath, pathToFileURL } from 'node:url'

const runtime = process.env.DSHM_RUNTIME ?? join(homedir(), '.dshm/runtime')
const home = process.env.DSHM_HOME
const signals = process.env.DSHM_FOLLOWUP_SIGNALS
const port = process.env.DSHM_WEB_PORT
const bridgePort = Number(process.env.DSHM_BRIDGE_PORT)
assert.ok(home && signals && port && bridgePort, 'set DSHM_HOME, DSHM_FOLLOWUP_SIGNALS, DSHM_WEB_PORT, DSHM_BRIDGE_PORT')
const dsh = join(runtime, 'node_modules/.bin/dsh')
const env = { ...process.env, DSH_HOME: home, DSHM_BRIDGE_HOST: '127.0.0.1', DSHM_BRIDGE_DEV_PLAINTEXT: '1' }
const bridge = fileURLToPath(new URL('../../bridge', import.meta.url))
const add = spawnSync(dsh, ['plugin', '--profile', 'web', 'add', bridge], { env, encoding: 'utf8' })
assert.equal(add.status, 0, add.stderr || add.stdout)

// The same mock reply as scripts/dsh-up.mjs. Slower (about 9 s a turn), so that the UI test sees
// the follow-up's turn run and stream; at 60 ms a chunk it ends before the test reads the page.
const MOCK_TEXT = '你好！I am a DSH agent on your Mac. This reply is streamed through the dsh-mobile bridge.'
const { startMockLlmServer } = await import(pathToFileURL(join(runtime,
  'node_modules/@deepseek-ai/dsh-llm-mock-server/lib/index.js')))
const running = process.env.DSHM_FOLLOWUP_MODE === 'running'
const mock = await startMockLlmServer({
  sequence: ['slow_success'], repeatLast: true, successText: MOCK_TEXT, chunkSize: 4, chunkDelayMs: running ? 1500 : 400,
})
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
const listening = () => new Promise(resolve => {
  const socket = connect(bridgePort, '127.0.0.1', () => { socket.destroy(); resolve(true) })
  socket.once('error', () => resolve(false))
})

/** The user and assistant messages of one DSH session, as DSH Web lists them (text only). */
function messages(records) {
  return records.flatMap(({ event }) => {
    const data = event.data ?? {}
    if (event.type === 'user/message' && data.source?.kind === 'user') {
      return [{ fromUser: true, text: (data.content ?? []).filter(b => b.type === 'text').map(b => b.text).join('') }]
    }
    if (event.type === 'assistant/message') {
      return [{ fromUser: false, text: (data.message?.content ?? []).filter(b => b.type === 'text').map(b => b.text).join('') }]
    }
    return []
  }).filter(m => m.text)
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
  console.log('DSH Web on ' + port + ', bridge on ' + bridgePort + (running ? ' (follow-ups while a task runs)' : ''))
  const files = running ? ['messages-queue', 'messages-interrupt'] : ['messages']
  await until(() => files.every(f => existsSync(join(signals, f))), 'the phone sends its tasks and follow-ups', 900_000)
  const sent = Object.fromEntries(files.map(f => [f, readFileSync(join(signals, f), 'utf8').split('\n')]))

  // DSH's own record: one session per conversation, the messages in the order the agent took them.
  const { items } = await rpc('session/list', { _request: {} })
  const sessions = []
  for (const item of items) {
    const { records } = await rpc('session/events', { request: { address: { kind: 'session', sessionId: item.sessionId }, maxMessages: 32 } })
    sessions.push({ id: item.sessionId, messages: messages(records) })
  }
  const sessionOf = (prompt) => {
    const session = sessions.find(s => s.messages.some(m => m.fromUser && m.text === prompt))
    assert.ok(session, 'no DSH session has the prompt: ' + JSON.stringify(sessions))
    console.log('DSH session ' + session.id + ': ' + session.messages.map(m => (m.fromUser ? 'user' : 'agent') + ' ' + JSON.stringify(m.text)).join(' | '))
    return session
  }
  const shape = (session) => session.messages.map(m => m.fromUser ? 'user: ' + m.text : 'agent')
  if (!running) {
    const [prompt, followUp] = sent.messages
    const session = sessionOf(prompt)
    assert.deepEqual(shape(session), ['user: ' + prompt, 'agent', 'user: ' + followUp, 'agent'], JSON.stringify(session.messages))
    assert.ok(session.messages.filter(m => !m.fromUser).every(m => m.text === MOCK_TEXT))
    console.log('followup host: the follow-up is in the same DSH session')
  } else {
    // D101: the one sent now went in at the next step of the first turn; the queued one ran next.
    const [prompt, later, now] = sent['messages-queue']
    const queue = sessionOf(prompt)
    assert.deepEqual(shape(queue), ['user: ' + prompt, 'agent', 'user: ' + now, 'agent', 'user: ' + later, 'agent'],
      JSON.stringify(queue.messages))
    assert.ok(queue.messages.filter(m => !m.fromUser).every(m => m.text === MOCK_TEXT))
    // After the stop, the new message went into the same session, and the agent answered it.
    const [story, goOn] = sent['messages-interrupt']
    const stopped = sessionOf(story)
    assert.deepEqual(stopped.messages.filter(m => m.fromUser).map(m => m.text), [story, goOn], JSON.stringify(stopped.messages))
    assert.equal(stopped.messages.at(-1).fromUser, false)
    assert.equal(stopped.messages.at(-1).text, MOCK_TEXT)
    console.log('followup host: queued, sent now and continued, each in its own DSH session')
  }
} finally {
  host.kill('SIGTERM')
  await exited
  await mock.close()
}
