// A fake DeepSeek provider for demos. DSH 0.2.2-rc.1's DeepSeek route
// speaks the Anthropic Messages wire format (`POST {DEEPSEEK_BASE_URL}/messages`). While the
// account has no balance, every Messages request gets DeepSeek's 402 answer; after `topUp()`,
// every request goes to DSH's own mock LLM server, which streams a normal reply.
//
//   const provider = await startFakeDeepSeek({ runtime, successText })
//   env.DEEPSEEK_BASE_URL = provider.baseURL
//   provider.topUp()
import { request as httpRequest, createServer } from 'node:http'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

/** DeepSeek's answer when the account has no balance (HTTP 402). DSH reads it as `QUOTA`. */
export const NO_BALANCE = {
  status: 402,
  body: { error: { message: 'Insufficient Balance', type: 'unknown_error', param: null, code: 'invalid_request_error' } },
}

export async function startFakeDeepSeek({ runtime, successText, port = 0 }) {
  const { startMockLlmServer } = await import(pathToFileURL(join(runtime,
    'node_modules/@deepseek-ai/dsh-llm-mock-server/lib/index.js')).href)
  const mock = await startMockLlmServer({ sequence: ['success'], repeatLast: true, successText })
  let balance = false
  /** Every request: { path, status }, in order. */
  const traffic = []

  const server = createServer((req, res) => {
    const chunks = []
    req.on('data', (chunk) => chunks.push(chunk))
    req.on('end', () => {
      const body = Buffer.concat(chunks)
      const entry = { path: req.url, status: 0 }
      traffic.push(entry)
      if (!balance && req.method === 'POST' && /\/messages$/.test(req.url ?? '')) {
        entry.status = NO_BALANCE.status
        res.writeHead(NO_BALANCE.status, { 'content-type': 'application/json' })
        res.end(JSON.stringify(NO_BALANCE.body))
        return
      }
      const target = new URL(mock.baseURL)
      const out = httpRequest({
        host: target.hostname, port: target.port, method: req.method, path: req.url,
        headers: { ...req.headers, host: target.host },
      }, (up) => {
        entry.status = up.statusCode ?? 502
        res.writeHead(up.statusCode ?? 502, up.headers)
        up.pipe(res)
      })
      out.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end() })
      out.end(body)
    })
  })
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve) })

  return {
    baseURL: `http://127.0.0.1:${server.address().port}/v1`,
    traffic,
    /** The user paid: from now on every request succeeds. */
    topUp() { balance = true },
    async close() {
      const closed = new Promise((resolve) => server.close(resolve))
      server.closeAllConnections()
      await closed
      await mock.close()
    },
  }
}
