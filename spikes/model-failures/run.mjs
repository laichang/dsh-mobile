#!/usr/bin/env node
/**
 * X1 (M2) spike runner (throwaway): model failures in DSH 0.2.2-rc.1.
 *
 * Starts real DSH (`dsh web`) with the spike plugin (plugin/) and a fake DeepSeek provider
 * (fake-provider.mjs). For each case, the provider answers like DeepSeek does for that failure;
 * the plugin starts one task the way the bridge does and records every `sessionController.follow`
 * frame. After a terminal failure the provider is healed and one more message goes into the same
 * session, to see how a new turn behaves. Each recording is written to fixtures/<case>.json, and a
 * summary to results/latest.json.
 *
 *   spikes/model-failures/run.sh [case ...] [--keep]
 *
 * --keep leaves DSH running at the end and prints the DSH web URL (to look at the web UI).
 * Env: DSHM_HOME (~/.dshm/home-x1), DSHM_WEB_PORT (3284), MF_PROVIDER_PORT (47811),
 *      MF_CONTROL_PORT (47841), DSHM_RUNTIME (~/.dshm/runtime).
 */
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { startFakeProvider } from './fake-provider.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const RUNTIME = process.env.DSHM_RUNTIME ?? join(homedir(), '.dshm/runtime')
const DSH_HOME = process.env.DSHM_HOME ?? join(homedir(), '.dshm/home-x1')
const WEB_PORT = Number(process.env.DSHM_WEB_PORT ?? 3284)
const PROVIDER_PORT = Number(process.env.MF_PROVIDER_PORT ?? 47811)
const CONTROL_PORT = Number(process.env.MF_CONTROL_PORT ?? 47841)
const DSH = join(RUNTIME, 'node_modules/.bin/dsh')
const OK_TEXT = 'X1 recovered: the model answered normally.'

// DeepSeek error bodies (OpenAI-style envelope, as in DeepSeek's "Error Codes" page). DSH's
// adapter reads error.{message,type,code} and the HTTP status; the exact provider wording is
// only shown when DSH has no localized copy for the code.
const deepseekError = (message, type, code = 'invalid_request_error') => ({ error: { message, type, param: null, code } })
const CASES = {
  'model-not-found': {
    title: 'Model not found: HTTP 404, Anthropic-style not_found_error (agent-loop requests only)',
    provider: { status: 404, scope: 'agent', body: { type: 'error', error: { type: 'not_found_error', message: 'Model Not Exist' } } },
    followUp: true,
  },
  'model-not-exist-400': {
    title: 'Model not found as DeepSeek words it on its OpenAI endpoint: HTTP 400 "Model Not Exist"',
    provider: { status: 400, scope: 'agent', body: deepseekError('Model Not Exist', 'invalid_request_error') },
    followUp: true,
  },
  'model-unlisted': {
    title: 'Model the host does not list: selectModel with an unknown model id (no provider error)',
    provider: null,
    selection: { provider: 'deepseek-official', model: 'deepseek-x1-does-not-exist' },
    followUp: true,
  },
  'invalid-key': {
    title: 'API key not valid: HTTP 401 authentication_error',
    provider: { status: 401, body: deepseekError('Authentication Fails, Your api key: ****-key is invalid', 'authentication_error') },
    followUp: true,
  },
  'no-balance': {
    title: 'No balance: HTTP 402 "Insufficient Balance"',
    provider: { status: 402, body: deepseekError('Insufficient Balance', 'unknown_error') },
    followUp: true,
  },
  'rate-limit': {
    title: 'Rate limited on every request: HTTP 429, no Retry-After',
    provider: { status: 429, body: deepseekError('Rate Limit Reached', 'rate_limit_error') },
    followUp: true,
    timeoutMs: 90_000,
  },
  'rate-limit-recovers': {
    title: 'Rate limited twice with Retry-After: 2, then the request succeeds',
    provider: { status: 429, times: 2, scope: 'agent', headers: { 'retry-after': '2' }, body: deepseekError('Rate Limit Reached', 'rate_limit_error') },
    followUp: false,
  },
  // The same failures from DSH's own mock LLM server, without the fake provider's DeepSeek wording.
  'mock-auth-error': {
    title: 'dsh-llm-mock-server auth_error (401 invalid_api_key)',
    provider: { mock: ['auth_error'] },
    followUp: false,
  },
  'mock-quota-exceeded': {
    title: 'dsh-llm-mock-server quota_exceeded (429 insufficient_quota)',
    provider: { mock: ['quota_exceeded'] },
    followUp: false,
  },
  'mock-invalid-request': {
    title: 'dsh-llm-mock-server invalid_request (400), the closest it has to "model not found"',
    provider: { mock: ['invalid_request'] },
    followUp: false,
  },
}

const args = process.argv.slice(2)
const keep = args.includes('--keep')
const only = args.filter((a) => !a.startsWith('--'))
const selected = only.length ? only : Object.keys(CASES)
for (const name of selected) if (!CASES[name]) { console.error(`unknown case ${name}; cases: ${Object.keys(CASES).join(', ')}`); process.exit(2) }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function until(probe, ms, what) {
  const end = Date.now() + ms
  for (;;) {
    const v = await probe().catch(() => undefined)
    if (v) return v
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`)
    await sleep(200)
  }
}
async function call(method, path, body) {
  const res = await fetch(`http://127.0.0.1:${CONTROL_PORT}${path}`, {
    method, headers: { 'content-type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await res.text()
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${text}`)
  return text ? JSON.parse(text) : undefined
}

if (!existsSync(DSH)) { console.error(`no DSH at ${DSH}`); process.exit(1) }
const env = { ...process.env, DSH_HOME, MF_CONTROL_PORT: String(CONTROL_PORT) }
const add = spawnSync(DSH, ['plugin', '--profile', 'web', 'add', join(HERE, 'plugin')], { env, encoding: 'utf8' })
if (add.status !== 0) { console.error(`dsh plugin add failed:\n${add.stdout}${add.stderr}`); process.exit(1) }

const provider = await startFakeProvider({ port: PROVIDER_PORT, successText: OK_TEXT })
const child = spawn(DSH, ['web', '--no-open', '--port', String(WEB_PORT)], {
  env: { ...env, DEEPSEEK_BASE_URL: provider.baseURL, DEEPSEEK_API_KEY: 'mock-key' },
  stdio: ['ignore', 'pipe', 'pipe'],
})
const output = []
let webURL
const keepLine = (b) => {
  const s = String(b)
  output.push(s.replace(/token=\S+/g, 'token=<redacted>'))
  webURL ??= s.match(/https?:\/\/127\.0\.0\.1:\d+\/\S*token=\S+/)?.[0]
}
child.stdout.on('data', keepLine)
child.stderr.on('data', keepLine)
let exited = false
child.on('exit', () => { exited = true })
const stop = async () => {
  if (!exited) { child.kill('SIGTERM'); await new Promise((r) => (exited ? r() : child.once('exit', r))) }
  await provider.close()
}

// Fixtures keep every frame and its shape, but not the prompt-building bulk (system prompt, tool
// schemas, local skills, paths of this Mac): those carry nothing S3 needs and change per host.
const BULK = new Set(['system/message', 'request/header', 'session/title-llm-request'])
const HOME = homedir()
function scrub(value) {
  if (typeof value === 'string') {
    const s = value.replaceAll(HOME, '~').replace(/\/(private\/)?var\/folders\/[^"\s]+?\/T\//g, '$TMPDIR/')
    return s.length > 240 ? `${s.slice(0, 200)}…[${s.length - 200} chars elided]` : s
  }
  if (Array.isArray(value)) return value.map(scrub)
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, scrub(v)]))
  return value
}
function scrubFrame(frame) {
  if (frame.type === 'event' && BULK.has(frame.event.type)) {
    const { data, ...rest } = frame.event
    return { type: 'event', event: { ...rest, data: { elided: 'prompt-building bulk', keys: Object.keys(data ?? {}) } } }
  }
  return scrub(frame)
}

const turnEnds = (frames) => frames.filter((f) => f.frame.type === 'event' && f.frame.event.type === 'turn/end')
const events = (frames, type) => frames.filter((f) => f.frame.type === 'event' && f.frame.event.type === type).map((f) => f.frame.event)

function summarize(name, rec, t0) {
  const frames = rec.frames
  const ends = events(frames, 'turn/end')
  const retries = events(frames, 'llm/retry')
  const first = ends[0]
  return {
    case: name,
    turnEnds: ends.map((e) => ({ turn: e.data.turn, step: e.data.step, reason: e.data.reason, atMs: e.time - t0 })),
    retries: retries.map((e) => ({ retry: e.data.retry, maxRetries: e.data.maxRetries, mode: e.data.mode, delayMs: e.data.delayMs, failure: e.data.failure, atMs: e.time - t0 })),
    firstTurnEndMs: first ? first.time - t0 : undefined,
    eventTypes: [...new Set(frames.filter((f) => f.frame.type === 'event').map((f) => f.frame.event.type))],
    assistantText: rec.text,
  }
}

const summary = { recordedAt: new Date().toISOString(), dsh: '0.2.2-rc.1', cases: [] }
try {
  await until(async () => (await call('GET', '/ping'))?.ok, 90_000, 'DSH and the spike plugin')
  const catalog = await call('GET', '/catalog')
  summary.catalogDefault = catalog?.default
  console.log(`DSH up on :${WEB_PORT}; default model ${JSON.stringify(catalog?.default)}`)
  mkdirSync(join(HERE, 'fixtures'), { recursive: true })

  for (const name of selected) {
    const c = CASES[name]
    console.log(`\n== ${name}: ${c.title}`)
    await provider.set(c.provider)
    const trafficFrom = provider.traffic.length
    const t0 = Date.now()
    const started = await call('POST', '/task', { prompt: `X1 case ${name}: say hello`, selection: c.selection })
    if (started.error) {
      console.log(`  task refused: ${started.error}`)
      summary.cases.push({ case: name, refused: started })
      continue
    }
    const { sessionId } = started
    const rec = await until(async () => {
      const r = await call('GET', `/task/${sessionId}`)
      return turnEnds(r.frames).length >= 1 ? r : undefined
    }, c.timeoutMs ?? 45_000, `${name}: turn 1 to end`)
    let followUp
    if (c.followUp) {
      await provider.set(null)
      await sleep(500)
      followUp = await call('POST', '/prompt', { sessionId, text: `X1 case ${name}: please try again` })
      await until(async () => turnEnds((await call('GET', `/task/${sessionId}`)).frames).length >= 2, 45_000, `${name}: turn 2 to end`)
    }
    await sleep(800) // let trailing events (titles, usage) arrive
    const final = await call('GET', `/task/${sessionId}`)
    const fixture = {
      case: name,
      title: c.title,
      dsh: '0.2.2-rc.1',
      recordedAt: new Date(t0).toISOString(),
      provider: c.provider ?? null,
      selection: c.selection ?? null,
      selected: started.selected ?? null,
      followUp: followUp ?? null,
      providerRequests: provider.traffic.slice(trafficFrom).map(({ at, ...r }) => ({ atMs: at - t0, ...r })),
      // What the bridge reads: every frame of sessionController.follow, unchanged, with its arrival
      // time relative to the prompt. The opening snapshot is reduced to {type: 'snapshot'}, and
      // bulk prompt text is elided (scrubFrame).
      frames: final.frames.map(({ at, frame }) => ({ atMs: at - t0, frame: scrubFrame(frame) })),
    }
    writeFileSync(join(HERE, 'fixtures', `${name}.json`), `${JSON.stringify(fixture, null, 2)}\n`)
    const s = { ...summarize(name, final, t0), sessionId, selected: started.selected, followUp, providerRequests: fixture.providerRequests.map((r) => `${r.atMs}ms ${r.method} ${r.path} ${r.agentLoop ? 'agent' : 'side'} → ${r.status}`) }
    summary.cases.push(s)
    for (const e of s.retries) console.log(`  llm/retry ${e.retry}/${e.maxRetries} delay ${e.delayMs}ms at ${e.atMs}ms: ${e.failure?.code} ${e.failure?.message}`)
    for (const e of s.turnEnds) console.log(`  turn/end turn ${e.turn} at ${e.atMs}ms: ${JSON.stringify(e.reason)}`)
    console.log(`  text: ${JSON.stringify(s.assistantText)}`)
  }
} catch (error) {
  console.error(String(error?.stack ?? error))
  console.error(output.join('').slice(-4000))
  process.exitCode = 1
} finally {
  mkdirSync(join(HERE, 'results'), { recursive: true })
  writeFileSync(join(HERE, 'results', 'latest.json'), `${JSON.stringify(summary, null, 2)}\n`)
  if (keep && !exited) {
    console.log(`\n--keep: DSH web stays up at ${webURL ?? `http://127.0.0.1:${WEB_PORT}`}; Ctrl-C to stop`)
    process.on('SIGINT', async () => { await stop(); process.exit(0) })
    process.on('SIGTERM', async () => { await stop(); process.exit(0) })
  } else {
    await stop()
  }
}
