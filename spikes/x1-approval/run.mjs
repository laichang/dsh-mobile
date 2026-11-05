#!/usr/bin/env node
/**
 * X1 spike runner (throwaway). Starts real DSH 0.2.2-rc.1 with the X1 plugin and the mock LLM,
 * then runs one scenario per answerer placement. In each, the mock model makes one `bash` tool
 * call that needs approval; the plugin parks it; `release.mjs` (a separate process, standing in
 * for the phone) releases it. Writes results/latest.json and exits non-zero if a check fails.
 *
 *   node spikes/x1-approval/run.mjs            (or spikes/x1-approval/scripts/run)
 *
 * Ports: DSH web 3282, plugin control 47803, mock proxy 47804. DSH_HOME ~/.dshm/home-x1x4.
 */
import { execFileSync } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { controlClient, hasToolResult, sleep, startHost, until, userTexts } from './lib/host.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const PORT = Number(process.env.X1_CONTROL_PORT ?? 47803)
const call = controlClient(PORT)
const results = { startedAt: new Date().toISOString(), dsh: '0.2.2-rc.1 (mock LLM)', scenarios: [] }
const checks = []
const check = (scenario, name, pass, detail) => { checks.push({ scenario, name, pass: !!pass, detail }); console.log(`  ${pass ? 'ok  ' : 'FAIL'} ${name}${detail === undefined ? '' : ` — ${JSON.stringify(detail)}`}`) }

const GATED = JSON.stringify({ command: 'echo X1-GATE tool ran', description: 'X1 gated echo' })
const ESCALATED = JSON.stringify({
  command: 'echo X1-ESCALATED tool ran',
  description: 'X1 escalated echo',
  sandbox_permissions: 'danger-full-access',
  justification: 'X1 spike: prove a real sandbox escalation reaches the plugin answerer',
})

const SUBAGENT = JSON.stringify({ description: 'X1 child gated echo', prompt: 'X1-CHILD: run the gated echo with bash' })

const release = (...args) => execFileSync(process.execPath, [join(HERE, 'release.mjs'), ...args], {
  env: { ...process.env, X1_CONTROL_PORT: String(PORT) }, encoding: 'utf8',
}).trim()

const task = (id) => call('GET', `/task/${id}`)
const eventsOf = async (id, type) => (await task(id)).events.filter((e) => e.type === type)
const turnEnded = async (id) => (await eventsOf(id, 'turn/end')).length > 0
const decided = async (id) => (await eventsOf(id, 'approval/decided')).map((e) => JSON.parse(e.data).outcome)
const toolResults = async (id) => (await task(id)).events.filter((e) => /tool/.test(e.type) && /result/.test(e.type)).map((e) => e.data)

async function scenario(name, { mode, toolArguments, subagent = false }, body) {
  console.log(`\n== ${name} (answerer: ${mode}${subagent ? ', gated call made by a subagent' : ''})`)
  if (!subagent) {
    await host.script({ sequence: ['tool_call_success', 'success'], repeatLast: true, toolName: 'bash', toolArguments, successText: `${name} done` })
  } else {
    // Root agent delegates to a subagent; the subagent makes the gated bash call.
    await host.route({
      parentCall: { sequence: ['tool_call_success'], repeatLast: true, toolName: 'subagent', toolArguments: SUBAGENT },
      childCall: { sequence: ['tool_call_success'], repeatLast: true, toolName: 'bash', toolArguments },
      done: { sequence: ['success'], repeatLast: true, successText: `${name} done` },
    }, (b) => {
      const child = (userTexts(b)[0] ?? '').includes('X1-CHILD')
      if (hasToolResult(b)) return 'done'
      return child ? 'childCall' : 'parentCall'
    })
  }
  const startedAt = Date.now()
  const set = await call('POST', '/mode', { mode, gate: true })
  const before = (await call('GET', '/state')).released.length
  const { sessionId } = await call('POST', '/task', { prompt: `X1 scenario ${name}` })
  // Either our answerer parks it, or (without one in front) something else holds it.
  await until(async () => {
    const s = await call('GET', '/state')
    return s.parked.length > 0 || s.gateway?.pending.length > 0 || (await eventsOf(sessionId, 'approval/decided')).length > 0 || await turnEnded(sessionId)
  }, 30_000, 'approval to be parked or pending')
  await sleep(1500) // let it settle: does anything else answer it meanwhile?
  const s = await call('GET', '/state')
  const sessionState = await call('GET', `/session-state/${sessionId}`)
  const r = {
    name, mode, sessionId, listenerOrder: set.order,
    whileHeld: {
      parkedByPlugin: s.parked.map(({ toolName, callId, reason, agentId, agentShape, sessionId: sid }) => ({ toolName, callId, reason, sameSession: sid === sessionId, agentId, agentShape })),
      gatewayPending: s.gateway?.pending ?? null,
      liveWebClient: s.gateway?.liveClient ?? null,
      webSessionState: { running: sessionState.running, pendingInput: sessionState.pendingInput },
      decidedSoFar: await decided(sessionId),
      turnEnded: await turnEnded(sessionId),
      asked: (await eventsOf(sessionId, 'approval/asked')).map((e) => JSON.parse(e.data)),
    },
  }
  r.startedAt = startedAt
  if (subagent) {
    r.traffic = host.traffic.filter((t) => t.at >= startedAt && t.routed !== 'side').map(({ routed, users, lastToolResult }) => ({ routed, firstUser: users?.[0]?.slice(0, 60), lastToolResult: lastToolResult?.slice(0, 300) }))
    r.rootEvents = (await task(sessionId)).events.map((e) => `${e.type} ${String(e.data).slice(0, 160)}`)
  }
  await body({ r, sessionId, state: s })
  const after = await call('GET', '/state')
  r.after = {
    released: after.released.slice(before),
    gatewayPending: after.gateway?.pending ?? null,
    decided: await decided(sessionId),
    turnEnded: await turnEnded(sessionId),
    toolResults: await toolResults(sessionId),
  }
  results.scenarios.push(r)
  return r
}

const host = await startHost({
  plugins: [join(HERE, 'plugin')],
  ready: async () => (await call('GET', '/state')) !== undefined,
})
try {
  // A. No plugin answerer: what does DSH's own (web) answerer path do with no browser open?
  await scenario('A-no-plugin-answerer', { mode: 'off', toolArguments: GATED }, async ({ r, sessionId }) => {
    check('A', 'nothing answers it within 1.5 s (no immediate unavailable)', r.whileHeld.decidedSoFar.length === 0, r.whileHeld.decidedSoFar)
    check('A', 'it is held as a pending web (Remote) event', r.whileHeld.gatewayPending?.some((p) => p.event === 'approval/request'), r.whileHeld.gatewayPending)
    check('A', 'web state shows input-required (pendingInput approval)', r.whileHeld.webSessionState.pendingInput.includes('approval'), r.whileHeld.webSessionState)
    await call('POST', `/cancel/${sessionId}`)
    await until(() => turnEnded(sessionId), 20_000, 'turn end after cancel')
    check('A', 'cancelling the turn settles it as cancelled', (await decided(sessionId)).includes('cancelled'), await decided(sessionId))
  })

  // B. Plugin answerer appended (plain ctx.on): it sits behind the web forwarder.
  await scenario('B-append', { mode: 'append', toolArguments: GATED }, async ({ r, sessionId }) => {
    check('B', 'listener order: web forwarder first, plugin second', r.listenerOrder.at(-1) === 'x1-spike' && r.listenerOrder.length >= 2, r.listenerOrder)
    check('B', 'plugin never sees the request (web forwarder holds it)', r.whileHeld.parkedByPlugin.length === 0, r.whileHeld.parkedByPlugin)
    check('B', 'held as pending web event instead', r.whileHeld.gatewayPending?.length > 0, r.whileHeld.gatewayPending)
    await call('POST', `/cancel/${sessionId}`)
    await until(() => turnEnded(sessionId), 20_000, 'turn end after cancel')
  })

  // C. Plugin answerer prepended: it owns the request; the web never sees it.
  await scenario('C-prepend-allow', { mode: 'prepend', toolArguments: GATED }, async ({ r, sessionId }) => {
    check('C', 'listener order: plugin first', r.listenerOrder[0] === 'x1-spike', r.listenerOrder)
    check('C', 'plugin parks it with toolName + callId + reason', r.whileHeld.parkedByPlugin.length === 1 && r.whileHeld.parkedByPlugin[0].toolName === 'bash' && !!r.whileHeld.parkedByPlugin[0].callId, r.whileHeld.parkedByPlugin)
    check('C', 'web does NOT see it (no pending Remote event)', r.whileHeld.gatewayPending?.length === 0, r.whileHeld.gatewayPending)
    check('C', 'web state shows no input-required while plugin holds it', r.whileHeld.webSessionState.pendingInput.length === 0, r.whileHeld.webSessionState)
    check('C', 'turn stays open while parked', r.whileHeld.turnEnded === false)
    r.releaseOutput = release('first', 'allow')
    await until(() => turnEnded(sessionId), 20_000, 'turn end after release')
    check('C', 'release script → allowed-once recorded in session audit', (await decided(sessionId)).join() === 'allowed-once', await decided(sessionId))
    check('C', 'the gated tool actually ran', (await toolResults(sessionId)).some((t) => t.includes('X1-GATE tool ran')), await toolResults(sessionId))
  })

  await scenario('D-prepend-reject', { mode: 'prepend', toolArguments: GATED }, async ({ sessionId }) => {
    release('first', 'reject')
    await until(() => turnEnded(sessionId), 20_000, 'turn end after reject')
    check('D', 'release script → rejected recorded', (await decided(sessionId)).join() === 'rejected', await decided(sessionId))
    check('D', 'model sees a rejection, tool did not run', (await toolResults(sessionId)).some((t) => t.includes('rejected')) && !(await toolResults(sessionId)).some((t) => t.includes('X1-GATE tool ran')), await toolResults(sessionId))
  })

  // E. Real DSH path: a bash sandbox escalation (no spike gate involved).
  await scenario('E-real-sandbox-escalation', { mode: 'prepend', toolArguments: ESCALATED }, async ({ r, sessionId }) => {
    check('E', 'sandbox escalation reaches the plugin answerer', r.whileHeld.parkedByPlugin.length === 1 && r.whileHeld.parkedByPlugin[0].toolName === 'bash', r.whileHeld.parkedByPlugin)
    release('first', 'allow')
    await until(() => turnEnded(sessionId), 20_000, 'turn end after release')
    check('E', 'escalated command ran after release', (await toolResults(sessionId)).some((t) => t.includes('X1-ESCALATED tool ran')), await toolResults(sessionId))
  })

  // F. Fan-out: plugin first, re-dispatches a copy to the rest of the chain (web) and races it.
  await scenario('F-fanout-phone-wins', { mode: 'fanout', toolArguments: GATED }, async ({ r, sessionId }) => {
    check('F', 'plugin parks it', r.whileHeld.parkedByPlugin.length === 1, r.whileHeld.parkedByPlugin)
    check('F', 'web sees it too (pending Remote event)', r.whileHeld.gatewayPending?.some((p) => p.event === 'approval/request'), r.whileHeld.gatewayPending)
    check('F', 'web state shows input-required', r.whileHeld.webSessionState.pendingInput.includes('approval'), r.whileHeld.webSessionState)
    release('first', 'allow')
    await until(() => turnEnded(sessionId), 20_000, 'turn end after release')
    const s = await call('GET', '/state')
    check('F', 'phone answer withdraws the web copy (no pending Remote event left)', s.gateway?.pending.length === 0, s.gateway?.pending)
    check('F', 'one audit pair, allowed-once', (await decided(sessionId)).join() === 'allowed-once', await decided(sessionId))
  })

  // G. Turn cancelled while parked.
  await scenario('G-cancel-while-parked', { mode: 'prepend', toolArguments: GATED }, async ({ sessionId }) => {
    await call('POST', `/cancel/${sessionId}`)
    await until(() => turnEnded(sessionId), 20_000, 'turn end after cancel')
    const s = await call('GET', '/state')
    check('G', 'parked entry is dropped', s.parked.length === 0, s.parked)
    check('G', 'outcome cancelled via the request signal', s.released.at(-1)?.outcome === 'cancelled' && s.released.at(-1)?.answeredBy === 'request-signal', s.released.at(-1))
  })

  // H. A subagent's approval. DSH pins delegated children to approval policy `never`
  // (dsh-subagent: "operations that require approval are rejected automatically"), so the
  // request is rejected inside the approval service before any answerer is dispatched.
  await scenario('H-subagent', { mode: 'prepend', toolArguments: GATED, subagent: true }, async ({ r, sessionId }) => {
    await until(() => host.traffic.some((t) => t.at >= r.startedAt && t.routed === 'done' && (t.users?.[0] ?? '').includes('X1-CHILD')), 30_000, 'child to finish its gated step')
    await sleep(500)
    const s = await call('GET', '/state')
    const child = host.traffic.filter((t) => t.at >= r.startedAt && t.routed === 'done' && (t.users?.[0] ?? '').includes('X1-CHILD')).at(-1)
    r.childToolResult = child?.lastToolResult
    r.hits = s.hits.filter((h) => h.at >= r.startedAt)
    check('H', 'plugin answerer is never entered for the subagent request', r.hits.length === 0 && s.parked.length === 0, r.hits)
    check('H', 'web never sees it either (no pending Remote event)', (s.gateway?.pending ?? []).length === 0, s.gateway?.pending)
    check('H', 'subagent gets a plain rejection', /rejected/.test(child?.lastToolResult ?? ''), child?.lastToolResult)
    await call('POST', `/cancel/${sessionId}`).catch(() => {})
  })

  // J. No plugin answerer; a browser tab opens only AFTER the request was held.
  await scenario('J-web-opens-late', { mode: 'off', toolArguments: GATED }, async ({ r, sessionId }) => {
    check('J', 'held with no live web client', r.whileHeld.liveWebClient === false && r.whileHeld.gatewayPending?.length === 1, r.whileHeld)
    const opened = await call('POST', '/fake-web/open')
    check('J', 'late browser tab receives the held request on connect', opened.frames.some((f) => f.type === 'waterfall' && f.event === 'approval/request' && f.toolName === 'bash'), opened.frames)
    await call('POST', '/fake-web/answer', { outcome: 'allowed-once' })
    await until(() => turnEnded(sessionId), 20_000, 'turn end after web answer')
    check('J', 'web answer → allowed-once, tool ran', (await decided(sessionId)).join() === 'allowed-once' && (await toolResults(sessionId)).some((t) => t.includes('X1-GATE tool ran')), await decided(sessionId))
  })

  // K. Fan-out with a browser tab open; the WEB answers first.
  await scenario('K-fanout-web-wins', { mode: 'fanout', toolArguments: GATED }, async ({ r, sessionId }) => {
    check('K', 'plugin parks it and the open tab got it too', r.whileHeld.parkedByPlugin.length === 1 && r.whileHeld.gatewayPending?.length === 1, r.whileHeld)
    await call('POST', '/fake-web/answer', { outcome: 'rejected' })
    await until(() => turnEnded(sessionId), 20_000, 'turn end after web answer')
    const s = await call('GET', '/state')
    check('K', 'phone copy is withdrawn (nothing parked), answeredBy downstream', s.parked.length === 0 && s.released.at(-1)?.answeredBy === 'downstream' && s.released.at(-1)?.outcome === 'rejected', s.released.at(-1))
    check('K', 'one audit pair, rejected', (await decided(sessionId)).join() === 'rejected', await decided(sessionId))
  })

  // L. Fan-out with the tab open; the PHONE answers first: the tab gets a cancel frame.
  await scenario('L-fanout-phone-wins-tab-open', { mode: 'fanout', toolArguments: GATED }, async ({ sessionId }) => {
    release('first', 'allow')
    await until(() => turnEnded(sessionId), 20_000, 'turn end after release')
    const s = await call('GET', '/state')
    const frames = s.fakeWeb.frames
    const last = frames.filter((f) => f.type === 'waterfall').at(-1)
    check('L', 'open tab receives a cancel for its copy', frames.some((f) => f.type === 'cancel' && f.eventId === last?.eventId), frames.slice(-3))
    check('L', 'one audit pair, allowed-once', (await decided(sessionId)).join() === 'allowed-once', await decided(sessionId))
    await call('POST', '/fake-web/close')
  })
} catch (error) {
  checks.push({ scenario: '-', name: 'runner', pass: false, detail: String(error?.stack ?? error) })
  console.error(error)
} finally {
  await host.stop()
}

results.checks = checks
results.passed = checks.every((c) => c.pass)
mkdirSync(join(HERE, 'results'), { recursive: true })
writeFileSync(join(HERE, 'results/latest.json'), `${JSON.stringify(results, null, 2)}\n`)
console.log(`\n${checks.filter((c) => c.pass).length}/${checks.length} checks passed → spikes/x1-approval/results/latest.json`)
process.exit(results.passed ? 0 : 1)
