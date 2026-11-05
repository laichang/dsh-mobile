/**
 * X4 spike plugin (throwaway). Sends follow-up messages (and attachments) into a DSH session that
 * is still running, the way the bridge would, and parks agent questions (`ask_user_question` →
 * the `user-questions/request` waterfall) so a script can see how they surface (ARCHITECTURE §8.6).
 *
 * Control port: X4_CONTROL_PORT (default 47805), loopback only, JSON:
 *   POST /task {prompt}                 new workspace session + prompt; → {sessionId}
 *   GET  /task/<sessionId>              recorded follow events (type, seq, data) + assistant text
 *   POST /prompt {sessionId, mode, text, file?, image?}
 *                                       sessionController.prompt with mode queue | steer;
 *                                       file: {name, text} is staged via ctx.fileUploads first;
 *                                       image: {mediaType, data(base64)} goes inline
 *   POST /questions/mode {on}           prepend a `user-questions/request` answerer that parks
 *   GET  /state                         parked + answered questions, gateway pending events
 *   GET  /session-state/<id>            sessionController.state (web's "input required")
 *   POST /questions/<id> {answer}       answer a parked question with {answers:[...]}
 *   POST /cancel/<sessionId>
 */
import { randomUUID } from 'node:crypto'
import { mkdirSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

export const name = 'dshm-spike-x4'
export const inject = ['sessionController', 'workspaceController', 'fileUploads']

const trim = (v, n = 600) => { const s = typeof v === 'string' ? v : JSON.stringify(v); return s && s.length > n ? `${s.slice(0, n)}…` : s }

export function apply(ctx) {
  const port = Number(process.env.X4_CONTROL_PORT ?? 47805)
  const cwd = join(tmpdir(), 'dshm-x4-workspace')
  mkdirSync(cwd, { recursive: true })

  const tasks = new Map() // sessionId → { events, text }
  const parked = new Map() // question id → entry (with resolve)
  const answered = []
  let disposeQuestions

  function questionAnswerer(request, next) {
    const id = randomUUID()
    const agent = request.agent
    const entry = {
      id,
      sessionId: agent?.session?.id,
      requestKeys: Object.keys(request),
      callId: request.callId ?? null,
      questions: request.questions,
      wait: request.wait ?? null,
      parkedAt: new Date().toISOString(),
    }
    return new Promise((resolve, reject) => {
      let settled = false
      const finish = (fn, value, by) => {
        if (settled) return
        settled = true
        parked.delete(id)
        answered.push({ ...entry, answer: value, answeredBy: by, answeredAt: new Date().toISOString() })
        fn(value)
      }
      parked.set(id, { ...entry, resolve: (answer) => finish(resolve, answer, 'script') })
      request.signal?.addEventListener('abort', () => finish(reject, request.signal.reason ?? new Error('aborted'), 'request-signal'), { once: true })
    })
  }

  async function startTask(prompt) {
    const { workspace } = await ctx.workspaceController.create({ path: cwd })
    const { sessionId } = await ctx.sessionController.create({ workspaceId: workspace.workspaceId })
    const record = { events: [], text: '', ended: false }
    tasks.set(sessionId, record)
    const ac = new AbortController()
    const follow = ctx.sessionController.follow({ address: { kind: 'session', sessionId }, assistantStream: true, activate: true }, ac.signal)
    const it = follow[Symbol.asyncIterator]()
    await it.next()
    ;(async () => {
      try {
        for (let n = await it.next(); !n.done; n = await it.next()) {
          const f = n.value
          if (f.type === 'event') record.events.push({ at: Date.now(), seq: f.event.seq, type: f.event.type, data: trim(f.event.data) })
          if (f.type === 'assistant-stream' && f.frame.type === 'chunk' && f.frame.chunk?.type === 'text-delta') record.text += f.frame.chunk.text
        }
      } catch (error) { record.followError = String(error) }
      record.ended = true
    })()
    await prompt_({ sessionId, mode: 'queue', text: prompt })
    return sessionId
  }

  async function prompt_({ sessionId, mode, text, file, image }) {
    const content = []
    if (text) content.push({ type: 'text', text })
    if (file) {
      const data = (async function* () { yield new TextEncoder().encode(file.text) })()
      const staged = await ctx.fileUploads.uploadStream({ sessionId, data, name: file.name })
      content.push({ type: 'file', receiptId: staged.receiptId })
    }
    if (image) content.push({ type: 'image', mediaType: image.mediaType, data: image.data, name: image.name })
    const at = Date.now()
    const value = await ctx.sessionController.prompt({ requestId: randomUUID(), sessionId, mode, content }, AbortSignal.timeout(15_000))
    return { at, value }
  }

  const routes = async (method, path, body) => {
    if (method === 'POST' && path === '/task') return { sessionId: await startTask(body.prompt) }
    if (method === 'GET' && path.startsWith('/task/')) return tasks.get(path.slice(6)) ?? null
    if (method === 'POST' && path === '/prompt') {
      try { return await prompt_(body) } catch (error) { return { error: String(error?.message ?? error), code: error?.code } }
    }
    if (method === 'POST' && path.startsWith('/cancel/')) return ctx.sessionController.cancel({ sessionId: path.slice(8) })
    if (method === 'GET' && path.startsWith('/session-state/')) return ctx.sessionController.state({ sessionId: path.slice(15) }, AbortSignal.timeout(5000))
    if (method === 'POST' && path === '/questions/mode') {
      disposeQuestions?.(); disposeQuestions = undefined
      if (body.on) disposeQuestions = ctx.on('user-questions/request', questionAnswerer, { prepend: true })
      return { on: !!disposeQuestions }
    }
    if (method === 'GET' && path === '/state') {
      const gateway = ctx.get?.('typertGateway')
      return {
        parked: [...parked.values()].map(({ resolve, ...rest }) => rest),
        answered,
        gateway: gateway ? { pending: gateway.getPendingRemoteEvents(), liveClient: gateway.hasLiveClient() } : null,
      }
    }
    if (method === 'POST' && path.startsWith('/questions/')) {
      const entry = parked.get(path.slice(11))
      if (!entry) return { error: 'not parked' }
      entry.resolve(body.answer)
      return { ok: true }
    }
    return undefined
  }

  ctx.effect(() => {
    const server = createServer((req, res) => {
      const chunks = []
      req.on('data', (c) => chunks.push(c))
      req.on('end', async () => {
        try {
          const body = chunks.length ? JSON.parse(String(Buffer.concat(chunks))) : {}
          const out = await routes(req.method, req.url, body)
          if (out === undefined) { res.writeHead(404); res.end(); return }
          res.writeHead(200, { 'content-type': 'application/json' })
          res.end(JSON.stringify(out ?? null))
        } catch (error) {
          res.writeHead(500, { 'content-type': 'application/json' })
          res.end(JSON.stringify({ error: String(error?.stack ?? error) }))
        }
      })
    })
    server.listen(port, '127.0.0.1')
    return () => { server.close(); disposeQuestions?.() }
  }, 'dshm-spike-x4: control server')
}
