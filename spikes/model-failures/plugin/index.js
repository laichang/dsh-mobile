/**
 * Model-failures spike plugin (throwaway). Starts tasks the way the bridge does
 * (workspaceController.create → sessionController.create → follow → prompt) and records every
 * `sessionController.follow` frame unchanged, so a bridge test can replay the recording.
 *
 * Control port: MF_CONTROL_PORT (default 47841), loopback only, JSON:
 *   POST /task {prompt, selection?}    new session (+ selectModel {provider, model}) and prompt → {sessionId}
 *   GET  /catalog                      sessionController.modelCatalog()
 *   POST /prompt {sessionId, text}     one more message in the same session (mode steer, D18)
 *   GET  /task/<sessionId>             {frames: [{at, frame}], text, ended, followError}
 *   GET  /ping
 */
import { randomUUID } from 'node:crypto'
import { mkdirSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

export const name = 'dshm-spike-model-failures'
export const inject = ['sessionController', 'workspaceController']

export function apply(ctx) {
  const port = Number(process.env.MF_CONTROL_PORT ?? 47841)
  const cwd = join(tmpdir(), 'dshm-model-failures-workspace')
  mkdirSync(cwd, { recursive: true })
  const tasks = new Map() // sessionId → { frames, text, ended }

  async function startTask({ prompt, selection }) {
    const { workspace } = await ctx.workspaceController.create({ path: cwd })
    const { sessionId } = await ctx.sessionController.create({ workspaceId: workspace.workspaceId })
    const record = { frames: [], text: '', ended: false }
    tasks.set(sessionId, record)
    const follow = ctx.sessionController.follow(
      { address: { kind: 'session', sessionId }, assistantStream: true, activate: true }, new AbortController().signal)
    const it = follow[Symbol.asyncIterator]()
    const first = await it.next()
    if (!first.done) record.frames.push({ at: Date.now(), frame: first.value.type === 'snapshot' ? { type: 'snapshot' } : first.value })
    ;(async () => {
      try {
        for (let n = await it.next(); !n.done; n = await it.next()) {
          const f = n.value
          record.frames.push({ at: Date.now(), frame: f.type === 'snapshot' ? { type: 'snapshot' } : f })
          if (f.type === 'assistant-stream' && f.frame.type === 'chunk' && f.frame.chunk?.type === 'text-delta') record.text += f.frame.chunk.text
        }
      } catch (error) { record.followError = String(error?.message ?? error) }
      record.ended = true
    })()
    let selected
    if (selection) {
      // Like the bridge's selectModel: DSH may refuse a model it does not list.
      try { selected = (await ctx.sessionController.selectModel({ sessionId, ...selection })).selected }
      catch (error) { selected = { error: String(error?.message ?? error), code: error?.code } }
    }
    const accepted = await prompt_({ sessionId, text: prompt, mode: 'queue' })
    return { sessionId, selected, accepted }
  }

  async function prompt_({ sessionId, text, mode = 'steer' }) {
    const at = Date.now()
    try {
      const value = await ctx.sessionController.prompt(
        { requestId: randomUUID(), sessionId, mode, content: [{ type: 'text', text }] }, AbortSignal.timeout(15_000))
      return { at, value }
    } catch (error) {
      return { at, error: String(error?.message ?? error), code: error?.code }
    }
  }

  const routes = async (method, path, body) => {
    if (method === 'GET' && path === '/ping') return { ok: true }
    if (method === 'GET' && path === '/catalog') return ctx.sessionController.modelCatalog()
    if (method === 'POST' && path === '/task') {
      try { return await startTask(body) } catch (error) { return { error: String(error?.message ?? error), code: error?.code } }
    }
    if (method === 'POST' && path === '/prompt') return prompt_(body)
    if (method === 'GET' && path.startsWith('/task/')) return tasks.get(path.slice(6)) ?? null
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
    return () => server.close()
  })
}
