// S14 demo peer: real DSH Web with the bridge plugin and DSH's mock LLM. It makes one Web session in
// DSH's default workspace, then tells the Simulator that workspace. The phone sends its own task
// there, and the drawer must show both sessions under that one workspace (PLAN.md §5 S14).
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, realpathSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { setTimeout as delay } from 'node:timers/promises'
import { fileURLToPath, pathToFileURL } from 'node:url'

const runtime = process.env.DSHM_RUNTIME ?? join(homedir(), '.dshm/runtime')
const home = process.env.DSHM_HOME
const signals = process.env.DSHM_S14_SIGNALS
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
try {
  await until(() => loginURL, 'Web launch URL', 90_000)
  assert.equal(loginURL.port, port)
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
  const { accepted } = await rpc('session/prompt', { request: {
    requestId: crypto.randomUUID(), sessionId, mode: 'queue', content: [{ type: 'text', text: '网页会话' }],
  } })
  assert.ok(accepted)
  await until(async () => {
    const { records } = await rpc('session/events', { request: { address: { kind: 'session', sessionId }, maxMessages: 12 } })
    return records.some(r => r.event.type === 'turn/end')
  }, 'Web turn', 40_000)
  // Diagnostics only: what DSH lists as each session's directory (the bridge reads the same list).
  const listed = () => rpc('session/list', { request: {} })
    .then(({ items }) => JSON.stringify(items.map(item => ({ id: item.sessionId, cwd: item.cwd }))), String)
  console.log('Web session ' + sessionId + ' in ' + workspace.path + '; DSH sessions: ' + await listed())
  writeFileSync(join(signals, 'bridge-port'), String(process.env.DSHM_BRIDGE_PORT))
  writeFileSync(join(signals, 'workspace'), workspace.path)
  await until(() => existsSync(join(signals, 'verified')), 'the Simulator verifies the drawer', 600_000)
  console.log('DSH sessions after the phone task: ' + await listed())
} finally {
  host.kill('SIGTERM')
  await exited
  await mock.close()
}
