/**
 * Fake DeepSeek provider (throwaway, X1 of M2). DSH 0.2.2-rc.1's DeepSeek adapter speaks the
 * Anthropic Messages wire format (`POST {DEEPSEEK_BASE_URL}/messages`). This server answers a
 * scripted number of requests with a provider error (status, headers, JSON body), and forwards
 * every other request to DSH's own mock LLM server (`@deepseek-ai/dsh-llm-mock-server`), which
 * streams a normal success.
 *
 *   const p = await startFakeProvider({ port, successText })
 *   await p.set({ status: 402, body: {...}, times: Infinity, scope: 'all' })   // or set(null) = all OK
 *   await p.set({ mock: ['auth_error'] })   // agent-loop requests go to a DSH mock with this sequence
 *
 * `scope`: 'all' fails every Messages request (an account-wide state: bad key, no balance, rate
 * limit); 'agent' fails only agent-loop requests (the ones that carry `tools`), and lets side calls
 * such as session titles succeed (a model-specific failure).
 */
import { request as httpRequest, createServer } from 'node:http'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const RUNTIME = process.env.DSHM_RUNTIME ?? join(homedir(), '.dshm/runtime')
const { startMockLlmServer } = await import(
  pathToFileURL(join(RUNTIME, 'node_modules/@deepseek-ai/dsh-llm-mock-server/lib/index.js')).href)

export async function startFakeProvider({ port, successText }) {
  const ok = await startMockLlmServer({ sequence: ['success'], repeatLast: true, successText })
  let spec = null
  let served = 0
  let scripted = null // a DSH mock with a scripted failure sequence (spec.mock), for agent-loop requests
  const traffic = [] // { at, method, path, model, agentLoop, status }

  const server = createServer((req, res) => {
    const chunks = []
    req.on('data', (c) => chunks.push(c))
    req.on('end', () => {
      const body = Buffer.concat(chunks)
      let parsed
      try { parsed = JSON.parse(String(body)) } catch { parsed = undefined }
      const messages = req.method === 'POST' && /\/messages$/.test(req.url ?? '')
      const agentLoop = Array.isArray(parsed?.tools) && parsed.tools.length > 0
      const entry = { at: Date.now(), method: req.method, path: req.url, model: parsed?.model, agentLoop }
      traffic.push(entry)
      const fail = messages && spec && served < spec.times && (spec.scope === 'all' || agentLoop)
      if (fail) {
        served++
        entry.status = spec.status
        res.writeHead(spec.status, { 'content-type': 'application/json', ...(spec.headers ?? {}) })
        res.end(JSON.stringify(spec.body))
        return
      }
      const target = new URL(scripted && messages && agentLoop ? scripted.baseURL : ok.baseURL)
      const out = httpRequest({
        host: target.hostname, port: target.port, method: req.method, path: req.url,
        headers: { ...req.headers, host: target.host },
      }, (up) => {
        entry.status = up.statusCode
        res.writeHead(up.statusCode ?? 502, up.headers)
        up.pipe(res)
      })
      out.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end() })
      out.end(body)
    })
  })
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve) })

  return {
    baseURL: `http://127.0.0.1:${port}/v1`,
    traffic,
    /** Script the next requests: `null` = every request succeeds. */
    async set(next) {
      await scripted?.close()
      scripted = next?.mock ? await startMockLlmServer({ sequence: next.mock, repeatLast: true, successText }) : null
      spec = next && !next.mock ? { times: Infinity, scope: 'all', ...next } : null
      served = 0
    },
    async close() { server.close(); await Promise.all([ok.close(), scripted?.close()]) },
  }
}
