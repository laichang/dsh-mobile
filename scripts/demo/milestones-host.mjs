#!/usr/bin/env node
/**
 * Milestones acceptance host: real DSH 0.2.2-rc.1 + the dsh-mobile bridge, driven by DSH's mock LLM
 * server scripted as a multi-step agent that keeps a todo list (ARCHITECTURE.md).
 * No API key. Runs in the foreground until SIGINT/SIGTERM.
 *
 *   node scripts/demo/milestones-host.mjs
 *
 * Env (with defaults):
 *   DSHM_RUNTIME       ~/.dshm/runtime (npm install @deepseek-ai/dsh@0.2.2-rc.1
 *                      @deepseek-ai/dsh-llm-mock-server@0.2.2-rc.1), read-only
 *   DSHM_HOME          ~/.dshm/home-milestones (the DSH_HOME; created on first run)
 *   DSHM_WEB_PORT      3285
 *   DSHM_BRIDGE_PORT   47812
 *   DSHM_STEP_DELAY_MS 1500 (pause before each model step, so todos tick visibly)
 * Needs Node >= 24.9 and a pnpm on PATH (DSH's `dsh plugin` calls it).
 *
 * The model script, per agent turn (one DSH session per task):
 *   step 1..4  `todo_write` tool calls: the plan, then each todo ticking off
 *   step 5     a final text answer
 * The script is chosen by counting `tool_result` blocks in the request, so it is stateless and
 * restarts for every new task. Requests that carry no tools (e.g. title generation) get a short
 * text answer. Each step is served by its own instance of DSH's mock server
 * (`tool_call_success` with that step's arguments); a small proxy in front picks the instance.
 */
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const RUNTIME = process.env.DSHM_RUNTIME ?? join(homedir(), '.dshm/runtime')
const DSH_HOME = process.env.DSHM_HOME ?? join(homedir(), '.dshm/home-milestones')
const WEB_PORT = Number(process.env.DSHM_WEB_PORT ?? 3285)
const BRIDGE_PORT = Number(process.env.DSHM_BRIDGE_PORT ?? 47812)
const STEP_DELAY_MS = Number(process.env.DSHM_STEP_DELAY_MS ?? 1500)
const DSH = join(RUNTIME, 'node_modules/.bin/dsh')

export const TODOS = ['Read the project layout', 'Write the summary', 'Check the summary against the code']
export const FINAL_TEXT = 'All three steps are done: the layout is read, the summary is written and checked.'

const todoArgs = (done, active) => JSON.stringify({
  todos: TODOS.map((content, i) => ({
    content, status: i < done ? 'completed' : i === active ? 'in_progress' : 'pending',
  })),
})
/** One entry per agent step: [behavior, toolArguments?]. */
const STEPS = [
  ['tool_call_success', todoArgs(0, 0)],
  ['tool_call_success', todoArgs(1, 1)],
  ['tool_call_success', todoArgs(2, 2)],
  ['tool_call_success', todoArgs(3, -1)],
  ['slow_success'],
]

const die = (m) => { console.error(`milestones-host: ${m}`); process.exit(1) }
if (!existsSync(DSH)) die(`no DSH at ${DSH}; see the header of this script`)
if (!existsSync(join(ROOT, 'bridge/lib/src/index.js'))) die('build the bridge first: (cd bridge && pnpm build)')

mkdirSync(DSH_HOME, { recursive: true })
const env = { ...process.env, DSH_HOME }
const add = spawnSync(DSH, ['plugin', '--profile', 'web', 'add', join(ROOT, 'bridge')], { env, encoding: 'utf8' })
if (add.status !== 0) die(`dsh plugin add failed:\n${add.stdout}${add.stderr}`)
// The profile's own patch layer: point the bridge at this slice's port (bridge/README.md).
writeFileSync(join(DSH_HOME, 'profiles/web/cordis.patch.yml'),
  `# Written by scripts/demo/milestones-host.mjs\n- id: dsh-mobile-bridge\n  config:\n    port: ${BRIDGE_PORT}\n    # Loopback only, with the dev-only plaintext path (the app's unpaired Debug path).\n    host: 127.0.0.1\n    devPlaintext: true\n`)
console.log(`milestones-host: bridge enabled in ${DSH_HOME}/profiles/web on port ${BRIDGE_PORT}`)

const { startMockLlmServer } = await import(
  pathToFileURL(join(RUNTIME, 'node_modules/@deepseek-ai/dsh-llm-mock-server/lib/index.js')).href)
const common = { repeatLast: true, chunkSize: 6, chunkDelayMs: 40, successText: FINAL_TEXT }
const mocks = []
for (const [behavior, toolArguments] of STEPS) {
  mocks.push(await startMockLlmServer({
    ...common, sequence: [behavior], ...(toolArguments ? { toolName: 'todo_write', toolArguments } : {}),
  }))
}
const plain = await startMockLlmServer({ ...common, sequence: ['success'], successText: 'milestones demo task' })

/** Which step a Messages request is at: tool results since the last user text. */
function stepOf(body) {
  if (!Array.isArray(body?.tools) || body.tools.length === 0) return -1
  let results = 0
  for (const m of body.messages ?? []) {
    const blocks = Array.isArray(m.content) ? m.content : [{ type: 'text' }]
    if (m.role === 'user' && blocks.some((b) => b.type === 'text') && !blocks.some((b) => b.type === 'tool_result')) results = 0
    results += blocks.filter((b) => b.type === 'tool_result').length
  }
  return Math.min(results, STEPS.length - 1)
}

const proxy = createServer(async (req, res) => {
  const chunks = []
  for await (const c of req) chunks.push(c)
  const raw = Buffer.concat(chunks)
  let body
  try { body = JSON.parse(raw.toString('utf8')) } catch { body = undefined }
  const step = stepOf(body)
  const target = step < 0 ? plain : mocks[step]
  if (step >= 0) await new Promise((r) => setTimeout(r, STEP_DELAY_MS))
  const upstream = await fetch(`${target.baseURL}${req.url}`, {
    method: req.method, headers: { 'content-type': 'application/json', 'x-api-key': 'mock-key' },
    body: req.method === 'POST' ? raw : undefined,
  })
  res.writeHead(upstream.status, Object.fromEntries(upstream.headers))
  // The mock always names its tool call `mock-call-1`; give each step its own id.
  let pending = ''
  const decoder = new TextDecoder()
  for await (const c of upstream.body ?? []) {
    pending += decoder.decode(c, { stream: true })
    const cut = pending.lastIndexOf('\n\n')
    if (cut < 0) continue
    res.write(pending.slice(0, cut + 2).replaceAll('"mock-call-1"', `"milestones-step-${step + 1}"`))
    pending = pending.slice(cut + 2)
  }
  res.end(pending)
})
await new Promise((r) => proxy.listen(0, '127.0.0.1', r))
const proxyURL = `http://127.0.0.1:${proxy.address().port}`
console.log(`milestones-host: scripted mock LLM at ${proxyURL} (${STEPS.length} steps)`)

const host = spawn(DSH, ['web', '--no-open', '--port', String(WEB_PORT)], {
  env: { ...env, DEEPSEEK_BASE_URL: `${proxyURL}/v1`, DEEPSEEK_API_KEY: 'mock-key' },
  stdio: ['ignore', 'pipe', 'pipe'],
})
const relay = (stream, out) => stream.on('data', (b) => out.write(String(b).replace(/token=\S+/g, 'token=<redacted>')))
relay(host.stdout, process.stdout)
relay(host.stderr, process.stderr)

const closeAll = async () => { proxy.close(); await Promise.all([...mocks, plain].map((m) => m.close())) }
const stop = async () => { host.kill('SIGTERM'); await closeAll(); process.exit(0) }
process.on('SIGINT', stop)
process.on('SIGTERM', stop)
host.on('exit', async (code) => { await closeAll(); process.exit(code ?? 1) })
