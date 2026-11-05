/**
 * Throwaway spike host (X1 + X4): real DSH 0.2.2-rc.1 from ~/.dshm/runtime, the spike plugin(s)
 * added to the `web` profile of a private DSH_HOME, and DSH's mock LLM server behind a small
 * proxy so each scenario can swap in a freshly scripted mock without restarting DSH.
 *
 * Routing: requests that carry `tools` (the agent loop) go to the scenario's scripted mock;
 * everything else (session titles and other side calls) goes to a fixed "success" mock, so side
 * calls never consume the scenario's script.
 *
 * Env: DSHM_RUNTIME (~/.dshm/runtime), DSHM_HOME (~/.dshm/home-x1x4), DSHM_WEB_PORT (3282),
 * DSHM_MOCK_PORT (47804, the proxy DSH talks to).
 */
import { spawn, spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { request as httpRequest, createServer } from 'node:http'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const RUNTIME = process.env.DSHM_RUNTIME ?? join(homedir(), '.dshm/runtime')
const DSH_HOME = process.env.DSHM_HOME ?? join(homedir(), '.dshm/home-x1x4')
const WEB_PORT = Number(process.env.DSHM_WEB_PORT ?? 3282)
const MOCK_PORT = Number(process.env.DSHM_MOCK_PORT ?? 47804)
const DSH = join(RUNTIME, 'node_modules/.bin/dsh')

const { startMockLlmServer } = await import(
  pathToFileURL(join(RUNTIME, 'node_modules/@deepseek-ai/dsh-llm-mock-server/lib/index.js')).href)

/** Start DSH with `plugins` (absolute dirs) enabled; resolves once `ready()` says so. */
export async function startHost({ plugins, ready, log = () => {} }) {
  if (!existsSync(DSH)) throw new Error(`no DSH at ${DSH}`)
  const env = { ...process.env, DSH_HOME }
  for (const dir of plugins) {
    const add = spawnSync(DSH, ['plugin', '--profile', 'web', 'add', dir], { env, encoding: 'utf8' })
    if (add.status !== 0) throw new Error(`dsh plugin add ${dir} failed:\n${add.stdout}${add.stderr}`)
  }

  const side = await startMockLlmServer({ sequence: ['success'], repeatLast: true, successText: 'side call' })
  // Agent-loop requests go to one of several scripted mocks, chosen per request by `pick(body)`.
  let mocks = { main: await startMockLlmServer({ sequence: ['success'], repeatLast: true }) }
  let pick = () => 'main'
  const traffic = [] // { at, routed: <mock key>|'side', path, users: [user texts] }

  const proxy = createServer((req, res) => {
    const chunks = []
    req.on('data', (c) => chunks.push(c))
    req.on('end', () => {
      const body = Buffer.concat(chunks)
      let parsed
      try { parsed = JSON.parse(String(body)) } catch { parsed = undefined }
      const agentLoop = Array.isArray(parsed?.tools) && parsed.tools.length > 0
      let key = 'side'
      if (agentLoop) { try { key = pick(parsed) } catch { key = 'main' } if (!mocks[key]) key = 'main' }
      const target = new URL(agentLoop ? mocks[key].baseURL : side.baseURL)
      traffic.push({ at: Date.now(), routed: key, path: req.url, users: agentLoop ? userTexts(parsed) : undefined, lastToolResult: agentLoop ? lastToolResult(parsed) : undefined, userBlocks: agentLoop ? newUserBlocks(parsed) : undefined })
      const out = httpRequest({
        host: target.hostname, port: target.port, method: req.method, path: req.url,
        headers: { ...req.headers, host: target.host },
      }, (up) => {
        res.writeHead(up.statusCode ?? 502, up.headers)
        up.pipe(res)
      })
      out.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end() })
      out.end(body)
    })
  })
  await new Promise((resolve, reject) => { proxy.once('error', reject); proxy.listen(MOCK_PORT, '127.0.0.1', resolve) })

  const child = spawn(DSH, ['web', '--no-open', '--port', String(WEB_PORT)], {
    env: { ...env, DEEPSEEK_BASE_URL: `http://127.0.0.1:${MOCK_PORT}/v1`, DEEPSEEK_API_KEY: 'mock-key' },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const output = []
  const keep = (b) => { const s = String(b).replace(/token=\S+/g, 'token=<redacted>'); output.push(s); log(s) }
  child.stdout.on('data', keep)
  child.stderr.on('data', keep)
  let exited = false
  child.on('exit', () => { exited = true })

  const stop = async () => {
    if (!exited) {
      child.kill('SIGTERM')
      await new Promise((r) => (exited ? r() : child.once('exit', r)))
    }
    proxy.close()
    await Promise.all([side.close(), ...Object.values(mocks).map((m) => m.close())])
  }

  const deadline = Date.now() + 90_000
  try {
    while (!(await ready().catch(() => false))) {
      if (exited) throw new Error(`DSH exited early:\n${output.join('')}`)
      if (Date.now() > deadline) throw new Error(`DSH not ready after 90 s:\n${output.join('')}`)
      await sleep(500)
    }
  } catch (error) {
    await stop()
    throw error
  }

  return {
    output,
    traffic,
    /** Swap in one scripted mock for every agent-loop request. Returns the new mock handle. */
    async script(options) {
      return (await this.route({ main: options }, () => 'main')).main
    },
    /** Swap in several scripted mocks; `choose(body)` names the one each agent-loop request goes to. */
    async route(optionsByKey, choose) {
      const old = mocks
      const next = {}
      for (const [k, o] of Object.entries(optionsByKey)) next[k] = await startMockLlmServer(o)
      mocks = next
      pick = choose
      await Promise.all(Object.values(old).map((m) => m.close()))
      return next
    },
    stop,
  }
}

/** Text of every user-role message in a Messages request, in order (tool results excluded). */
export function userTexts(body) {
  const out = []
  for (const m of body?.messages ?? []) {
    if (m.role !== 'user') continue
    if (typeof m.content === 'string') { out.push(m.content); continue }
    const text = (m.content ?? []).filter((c) => c.type === 'text').map((c) => c.text).join('')
    if (text) out.push(text)
  }
  return out
}

/** Text of the last tool_result block in a Messages request, if any. */
export function lastToolResult(body) {
  let out
  for (const m of body?.messages ?? []) for (const c of Array.isArray(m.content) ? m.content : []) {
    if (c.type !== 'tool_result') continue
    out = typeof c.content === 'string' ? c.content : (c.content ?? []).map((x) => x.text ?? '').join('')
  }
  return out
}

/** User-side blocks after the last assistant message (what is new for this step), summarized. */
export function newUserBlocks(body) {
  const msgs = body?.messages ?? []
  let i = msgs.length
  while (i > 0 && msgs[i - 1].role !== 'assistant') i--
  const out = []
  for (const m of msgs.slice(i)) {
    const blocks = typeof m.content === 'string' ? [{ type: 'text', text: m.content }] : m.content ?? []
    for (const b of blocks) {
      if (b.type === 'text') out.push({ type: 'text', text: b.text.slice(0, 400) })
      else if (b.type === 'image') out.push({ type: 'image', mediaType: b.source?.media_type, sourceType: b.source?.type })
      else if (b.type === 'tool_result') out.push({ type: 'tool_result' })
      else out.push({ type: b.type })
    }
  }
  return out
}

/** Whether a Messages request already carries a tool result (i.e. it is not the agent's first step). */
export const hasToolResult = (body) => (body?.messages ?? []).some((m) => Array.isArray(m.content) && m.content.some((c) => c.type === 'tool_result'))

/** Tiny JSON-over-HTTP client for a spike plugin's loopback control port. */
export function controlClient(port) {
  return async function call(method, path, body) {
    const res = await fetch(`http://127.0.0.1:${port}${path}`, {
      method,
      headers: { 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    const text = await res.text()
    if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${text}`)
    return text ? JSON.parse(text) : undefined
  }
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** Poll `probe()` until it returns a truthy value or `ms` passes. */
export async function until(probe, ms = 20_000, what = 'condition') {
  const end = Date.now() + ms
  for (;;) {
    const v = await probe()
    if (v) return v
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`)
    await sleep(150)
  }
}
