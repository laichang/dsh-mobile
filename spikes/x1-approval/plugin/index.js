/**
 * X1 spike plugin (throwaway). An `approval/request` answerer that PARKS approvals in-process
 * until a script releases them over a loopback HTTP control port, plus probes for how it orders
 * against DSH's web answerer (ARCHITECTURE §8.1).
 *
 * Control port: X1_CONTROL_PORT (default 47803), loopback only, JSON:
 *   POST /mode {mode, gate}      mode: off | append | prepend | fanout   (see `register` below)
 *   POST /task {prompt}          new workspace session + prompt (like the bridge); → {sessionId}
 *   GET  /task/<sessionId>       recorded follow events + assistant text
 *   GET  /state                  parked + released approvals, listener order, gateway pending
 *   GET  /session-state/<id>     sessionController.state (what web uses for "input required")
 *   POST /approvals/<id> {outcome}   release: allowed-once | rejected
 *   POST /fake-web/open | /fake-web/close | /fake-web/answer {outcome}
 *                                 an in-process stand-in for a browser tab on the gateway's
 *                                 forwarded-event stream (what the web UI answers through)
 *
 * `gate: true` adds a `tools/pre-execute` listener that answers `{kind:'ask'}` for any tool call
 * whose arguments contain "X1-GATE", so the mock LLM can trigger an approval deterministically.
 */
import { randomUUID } from 'node:crypto'
import { mkdirSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

export const name = 'dshm-spike-x1'
export const inject = ['sessionController', 'workspaceController']

// Copies we re-dispatch ourselves (fan-out). A WeakSet, not a symbol key: the gateway's Remote
// forwarder rejects requests with any non-JSON own property.
const redispatched = new WeakSet()
function describeAgent(agent) {
  if (!agent) return null
  const own = Object.keys(agent).slice(0, 40)
  const session = agent.session
  return {
    keys: own,
    sessionKeys: session ? Object.keys(session).slice(0, 40) : [],
    parentId: agent.parent?.id ?? agent.owner?.id ?? session?.parentSessionId ?? session?.parent?.id ?? null,
    depth: agent.depth ?? session?.depth ?? null,
  }
}
const trim = (v, n = 400) => { const s = typeof v === 'string' ? v : JSON.stringify(v); return s && s.length > n ? `${s.slice(0, n)}…` : s }

export function apply(ctx) {
  const port = Number(process.env.X1_CONTROL_PORT ?? 47803)
  const cwd = join(tmpdir(), 'dshm-x1-workspace')
  mkdirSync(cwd, { recursive: true })

  let mode = 'off'
  let disposeAnswerer
  let disposeGate
  const parked = new Map() // id → entry (with resolve)
  const released = []
  const tasks = new Map() // sessionId → { events, text }
  const hits = [] // every time our answerer was entered: { at, phase, toolName }

  const publicEntry = ({ resolve, ...rest }) => rest

  /** The answerer. `this` is the dispatch carrier (scopeTarget(agent, agent)). */
  function answerer(request, next) {
    if (redispatched.has(request)) { hits.push({ at: Date.now(), phase: 'redispatch-pass-through', toolName: request.toolName }); return next() }
    hits.push({ at: Date.now(), phase: 'entered', mode, toolName: request.toolName })
    const id = randomUUID()
    const agent = request.agent
    const entry = {
      id,
      sessionId: agent?.session?.id,
      agentId: agent?.id,
      toolName: request.toolName,
      callId: request.callId,
      reason: request.reason,
      parkedAt: new Date().toISOString(),
      mode,
      // Discovery: what an answerer can learn about the asking agent (root vs subagent).
      agentShape: describeAgent(agent),
    }
    return new Promise((resolve) => {
      let settled = false
      const downstream = new AbortController()
      const finish = (outcome, by) => {
        if (settled) return
        settled = true
        parked.delete(id)
        downstream.abort(new Error(`answered by ${by}`))
        released.push({ ...entry, outcome, answeredBy: by, releasedAt: new Date().toISOString() })
        resolve(outcome)
      }
      parked.set(id, { ...entry, resolve: finish })
      request.signal?.addEventListener('abort', () => finish('cancelled', 'request-signal'), { once: true })

      if (mode === 'fanout') {
        // Re-dispatch a copy to the REST of the chain (the web answerer) with our own abort signal,
        // and race it against the phone. A downstream 'unavailable' (no one there) is ignored: we keep holding.
        const copy = { ...request, signal: downstream.signal }
        redispatched.add(copy)
        Promise.resolve()
          .then(() => ctx.waterfall(this, 'approval/request', copy, () => Promise.resolve('unavailable')))
          .then(
            (outcome) => { entry.downstream = outcome; if (outcome === 'allowed-once' || outcome === 'rejected') finish(outcome, 'downstream') },
            (error) => { entry.downstream = `error: ${String(error?.message ?? error)}` },
          )
      }
    })
  }

  function register(nextMode, gate) {
    disposeAnswerer?.(); disposeAnswerer = undefined
    mode = nextMode
    if (mode === 'append') disposeAnswerer = ctx.on('approval/request', answerer)
    if (mode === 'prepend' || mode === 'fanout') disposeAnswerer = ctx.on('approval/request', answerer, { prepend: true })
    if (gate !== undefined) {
      disposeGate?.(); disposeGate = undefined
      if (gate) {
        disposeGate = ctx.on('tools/pre-execute', (exec, next) =>
          JSON.stringify(exec.arguments ?? '').includes('X1-GATE')
            ? Promise.resolve({ kind: 'ask', reason: 'X1 spike gate: tool arguments contain X1-GATE' })
            : next())
      }
    }
  }

  function listenerOrder(event) {
    const events = ctx.root?.events ?? ctx.events
    const hooks = events?._hooks?.[event] ?? []
    return hooks.map((h) => (h.ctx?.fiber === ctx.fiber ? 'x1-spike' : `other(${h.ctx?.fiber?.name ?? h.ctx?.name ?? '?'})`))
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
          if (f.type === 'event') record.events.push({ seq: f.event.seq, type: f.event.type, data: trim(f.event.data) })
          if (f.type === 'assistant-stream' && f.frame.type === 'chunk' && f.frame.chunk?.type === 'text-delta') record.text += f.frame.chunk.text
        }
      } catch (error) { record.followError = String(error) }
      record.ended = true
    })()
    await ctx.sessionController.prompt({ requestId: randomUUID(), sessionId, mode: 'queue', content: [{ type: 'text', text: prompt }] }, ac.signal)
    return sessionId
  }

  // A stand-in for a browser tab: an in-process owner client on the gateway's forwarded-event
  // stream (the same stream /api/remote.mux serves to the web UI). Pokes gateway internals;
  // spike only.
  let fakeWeb
  async function openFakeWeb() {
    const gateway = ctx.get('typertGateway')
    const ac = new AbortController()
    const peer = { principal: { kind: 'owner' }, signal: ac.signal }
    const frames = []
    const it = gateway.openRemoteEvents({ args: {} }, ac.signal, peer)[Symbol.asyncIterator]()
    const first = await it.next()
    frames.push(first.value)
    const client = gateway.remoteEventClients.get(first.value?.clientId)
    ;(async () => { for (let n = await it.next(); !n.done; n = await it.next()) frames.push(n.value) })().catch(() => {})
    fakeWeb = { ac, frames, client, gateway, answered: new Set() }
    const end = Date.now() + 1000 // let already-held events arrive
    while (frames.length < 2 && Date.now() < end) await new Promise((r) => setTimeout(r, 50))
  }
  const fakeWebState = () => fakeWeb ? {
    frames: fakeWeb.frames.map((f) => ({ type: f?.type, event: f?.event, eventId: f?.eventId, toolName: f?.request?.toolName })),
  } : null

  const routes = async (method, path, body) => {
    if (method === 'POST' && path === '/fake-web/open') { await openFakeWeb(); return fakeWebState() }
    if (method === 'POST' && path === '/fake-web/close') { fakeWeb?.ac.abort(); fakeWeb = undefined; return { ok: true } }
    if (method === 'POST' && path === '/fake-web/answer') {
      const cancelled = new Set(fakeWeb.frames.filter((f) => f?.type === 'cancel').map((f) => f.eventId))
      const frame = fakeWeb.frames.findLast((f) => f?.type === 'waterfall' && f.event === 'approval/request' && !cancelled.has(f.eventId) && !fakeWeb.answered.has(f.eventId))
      if (!frame) return { error: 'no open approval frame' }
      fakeWeb.answered.add(frame.eventId)
      fakeWeb.gateway.receiveRemoteEventResult(fakeWeb.client, { eventId: frame.eventId, outcome: { kind: 'result', value: body.outcome } })
      return { ok: true, eventId: frame.eventId }
    }
    if (method === 'POST' && path === '/mode') { register(body.mode, body.gate); return { mode, order: listenerOrder('approval/request') } }
    if (method === 'POST' && path === '/task') return { sessionId: await startTask(body.prompt) }
    if (method === 'GET' && path.startsWith('/task/')) return tasks.get(path.slice(6)) ?? null
    if (method === 'POST' && path.startsWith('/cancel/')) return ctx.sessionController.cancel({ sessionId: path.slice(8) })
    if (method === 'GET' && path.startsWith('/session-state/')) {
      return ctx.sessionController.state({ sessionId: path.slice(15) }, AbortSignal.timeout(5000))
    }
    if (method === 'GET' && path === '/state') {
      const gateway = ctx.get?.('typertGateway')
      return {
        mode,
        order: listenerOrder('approval/request'),
        parked: [...parked.values()].map(publicEntry),
        released,
        hits,
        gateway: gateway ? { pending: gateway.getPendingRemoteEvents(), liveClient: gateway.hasLiveClient() } : null,
        fakeWeb: fakeWebState(),
      }
    }
    if (method === 'POST' && path.startsWith('/approvals/')) {
      const entry = parked.get(path.slice(11))
      if (!entry) return { error: 'not parked' }
      entry.resolve(body.outcome, 'script')
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
          res.end(JSON.stringify(out))
        } catch (error) {
          res.writeHead(500, { 'content-type': 'application/json' })
          res.end(JSON.stringify({ error: String(error?.stack ?? error) }))
        }
      })
    })
    server.listen(port, '127.0.0.1')
    return () => { server.close(); disposeAnswerer?.(); disposeGate?.() }
  }, 'dshm-spike-x1: control server')
}
