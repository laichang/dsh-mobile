#!/usr/bin/env node
/**
 * X4 spike runner (throwaway). Starts real DSH 0.2.2-rc.1 with the X4 plugin and the mock LLM,
 * sends follow-up messages into a session while it is still running, and records when the agent
 * sees them: in the same turn's next step (injected) or in a new turn (queued). Also tries
 * attachments mid-task and an agent question (`ask_user_question`). Writes results/latest.json
 * and exits non-zero if a check fails.
 *
 *   spikes/x4-midtask/scripts/run
 *
 * Ports: DSH web 3282, mock proxy 47804, X4 control 47805. DSH_HOME ~/.dshm/home-x1x4.
 * Reuses the X1 spike host (spikes/x1-approval/lib/host.mjs).
 */
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { controlClient, hasToolResult, sleep, startHost, until, userTexts } from '../x1-approval/lib/host.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const PORT = Number(process.env.X4_CONTROL_PORT ?? 47805)
const call = controlClient(PORT)
const results = { startedAt: new Date().toISOString(), dsh: '0.2.2-rc.1 (mock LLM)', scenarios: [] }
const checks = []
const check = (scenario, name, pass, detail) => { checks.push({ scenario, name, pass: !!pass, detail }); console.log(`  ${pass ? 'ok  ' : 'FAIL'} ${name}${detail === undefined ? '' : ` — ${JSON.stringify(detail).slice(0, 400)}`}`) }

const SLEEP = JSON.stringify({ command: 'sleep 4; echo X4-SLEPT', description: 'X4 slow tool' })
const QUESTION = JSON.stringify({
  questions: [{
    id: 'q1',
    question: 'X4-QUESTION: which branch should I use?',
    header: 'Branch',
    options: [{ label: 'main (Recommended)', description: 'the default' }, { label: 'dev', description: 'the other one' }],
  }],
})
// 1x1 transparent PNG.
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='

const task = (id) => call('GET', `/task/${id}`)
const events = async (id) => (await task(id)).events
const count = async (id, type) => (await events(id)).filter((e) => e.type === type).length
const marker = /X4-[A-Z-]+\d*/g

/** Agent-loop requests since `t0`, each as {i, step markers seen in user text, last tool result}. */
const requestsSince = (t0) => host.traffic.filter((t) => t.at >= t0 && t.routed !== 'side').map((t, i) => ({
  i, routed: t.routed,
  markers: [...new Set((t.users ?? []).join('\n').match(marker) ?? [])],
}))
/** Turn/step position at which each X4 marker entered the session log as a user message. */
async function placement(id) {
  let turn = 0, step = 0
  const out = []
  for (const e of await events(id)) {
    if (e.type === 'turn/start') { turn = JSON.parse(e.data).turn; step = 0 }
    if (e.type === 'step/start') step = JSON.parse(e.data).step
    if (e.type === 'agent/inbox/spliced') {
      const d = JSON.parse(e.data)
      for (const m of d.inserted ?? []) for (const c of m.content ?? []) for (const x of (c.text ?? '').match(marker) ?? []) out.push({ marker: x, inbox: d.target, atTurn: turn, atStep: step })
    }
    if (e.type === 'user/message') for (const x of (e.data.match(marker) ?? [])) out.push({ marker: x, logged: true, turn, step })
  }
  return out
}

async function newTask(name, routes, choose) {
  console.log(`\n== ${name}`)
  await host.route(routes, choose)
  const t0 = Date.now()
  const { sessionId } = await call('POST', '/task', { prompt: `X4 scenario ${name}` })
  return { t0, sessionId }
}

const host = await startHost({
  plugins: [join(HERE, 'plugin')],
  ready: async () => (await call('GET', '/state')) !== undefined,
})
try {
  // 1. Steer and queue while a tool is executing (turn 1, step 1).
  {
    const { t0, sessionId } = await newTask('1-during-tool', {
      sleepCall: { sequence: ['tool_call_success'], repeatLast: true, toolName: 'bash', toolArguments: SLEEP },
      done: { sequence: ['success'], repeatLast: true, successText: 'X4 done' },
    }, (b) => (hasToolResult(b) ? 'done' : 'sleepCall'))
    await until(async () => (await count(sessionId, 'tool/call')) > 0, 30_000, 'tool call to start')
    const steer = await call('POST', '/prompt', { sessionId, mode: 'steer', text: 'X4-STEER-1 please also note this' })
    const queue = await call('POST', '/prompt', { sessionId, mode: 'queue', text: 'X4-QUEUE-1 do this next' })
    const stateWhile = await call('GET', `/session-state/${sessionId}`)
    await until(async () => (await count(sessionId, 'turn/end')) >= 2, 40_000, 'two turns to end')
    const reqs = requestsSince(t0)
    const place = await placement(sessionId)
    results.scenarios.push({ name: '1-during-tool', sessionId, steer, queue, stateWhile, requests: reqs, placement: place })
    const firstWith = (m) => reqs.find((r) => r.markers.includes(m))
    check('1', 'prompt(steer) and prompt(queue) are accepted while the turn runs', steer.value?.accepted && queue.value?.accepted, { steer, queue })
    check('1', 'steer is injected into the SAME turn: next step after the tool result', place.some((p) => p.marker === 'X4-STEER-1' && p.logged && p.turn === 1 && p.step === 2), place)
    check('1', 'steer reaches the model in turn 1 step 2 (2nd agent-loop request)', firstWith('X4-STEER-1')?.i === 1, reqs)
    check('1', 'queue waits for a NEW turn (turn 2)', place.some((p) => p.marker === 'X4-QUEUE-1' && p.logged && p.turn === 2), place)
    check('1', 'queue is not in turn 1 step 2', !reqs[1]?.markers.includes('X4-QUEUE-1'), reqs[1])

    // 3. Steer into an idle session (no turn running).
    const t1 = Date.now()
    const idle = await call('POST', '/prompt', { sessionId, mode: 'steer', text: 'X4-STEER-IDLE after the fact' })
    await until(async () => (await count(sessionId, 'turn/end')) >= 3, 30_000, 'idle steer to run a turn')
    const place3 = await placement(sessionId)
    results.scenarios.push({ name: '3-steer-idle', sessionId, idle, requests: requestsSince(t1), placement: place3.filter((p) => p.marker === 'X4-STEER-IDLE') })
    check('3', 'steer into an idle session starts a new turn (turn 3)', place3.some((p) => p.marker === 'X4-STEER-IDLE' && p.logged && p.turn === 3), place3)
  }

  // 2. Steer while the model is streaming its answer.
  {
    const { t0, sessionId } = await newTask('2-during-stream', {
      slow: { sequence: ['slow_success'], repeatLast: true, successText: 'X4 streaming a long answer, chunk by chunk, slowly.', chunkSize: 2, chunkDelayMs: 120 },
      done: { sequence: ['success'], repeatLast: true, successText: 'X4 done after steer' },
    }, (b) => (userTexts(b).join('\n').includes('X4-STEER-STREAM') ? 'done' : 'slow'))
    await until(async () => (await task(sessionId)).text.length > 4, 30_000, 'stream to start')
    const steer = await call('POST', '/prompt', { sessionId, mode: 'steer', text: 'X4-STEER-STREAM change of plan' })
    await until(async () => (await count(sessionId, 'turn/end')) >= 1, 30_000, 'turn to end')
    await sleep(1000)
    const evs = await events(sessionId)
    const place = await placement(sessionId)
    const assistant = evs.filter((e) => e.type === 'assistant/message').map((e) => ({ interrupted: e.data.includes('"interrupted":true'), text: (e.data.match(/"text":"([^"]*)"/) ?? [])[1] }))
    results.scenarios.push({ name: '2-during-stream', sessionId, steer, requests: requestsSince(t0), placement: place, assistant, turnEnds: evs.filter((e) => e.type === 'turn/end').map((e) => e.data) })
    check('2', 'streaming step is not cut off by a steer (first answer completes)', assistant[0] && !assistant[0].interrupted && assistant[0].text?.includes('slowly'), assistant)
    check('2', 'steer runs as a further step of the same turn', place.some((p) => p.marker === 'X4-STEER-STREAM' && p.logged && p.turn === 1 && p.step === 2), place)
  }

  // 4. Attachments mid-task: a staged text file and an inline image, both steered.
  {
    const { t0, sessionId } = await newTask('4-attachments', {
      sleepCall: { sequence: ['tool_call_success'], repeatLast: true, toolName: 'bash', toolArguments: SLEEP },
      done: { sequence: ['success'], repeatLast: true, successText: 'X4 done' },
    }, (b) => (hasToolResult(b) ? 'done' : 'sleepCall'))
    await until(async () => (await count(sessionId, 'tool/call')) > 0, 30_000, 'tool call to start')
    const file = await call('POST', '/prompt', { sessionId, mode: 'steer', text: 'X4-STEER-FILE see attached', file: { name: 'x4-notes.txt', text: 'X4-FILE-BODY line one\nline two\n' } })
    const image = await call('POST', '/prompt', { sessionId, mode: 'steer', text: 'X4-STEER-IMAGE see image', image: { mediaType: 'image/png', data: PNG, name: 'x4.png' } })
    await until(async () => (await count(sessionId, 'turn/end')) >= 1, 30_000, 'turn to end')
    await sleep(500)
    const reqs = host.traffic.filter((t) => t.at >= t0 && t.routed !== 'side')
    const step2 = reqs[1]
    const userBlocks = step2?.userBlocks ?? []
    const place = await placement(sessionId)
    results.scenarios.push({ name: '4-attachments', sessionId, file, image, step2UserBlocks: userBlocks, placement: place })
    check('4', 'a staged file is accepted in a steer', file.value?.accepted, file)
    check('4', 'the file reaches the model in the same turn (reference or contents in step 2)', userBlocks.some((b) => /x4-notes\.txt|X4-FILE-BODY/.test(b.text ?? '')), userBlocks)
    results.scenarios.at(-1).imageAccepted = !!image.value?.accepted
    check('4', 'an inline image steer gets a definite answer (accepted, or a typed refusal)', image.value?.accepted || image.error, image)
    if (image.value?.accepted) check('4', 'the image reaches the model in the same turn as an image block plus a saved-path note', userBlocks.some((b) => b.type === 'image') && userBlocks.some((b) => /Image "x4\.png"/.test(b.text ?? '')), userBlocks)
  }

  // 5a. Agent question with no plugin answerer: how does it surface?
  {
    await call('POST', '/questions/mode', { on: false })
    const { sessionId } = await newTask('5a-question-no-plugin', {
      ask: { sequence: ['tool_call_success'], repeatLast: true, toolName: 'ask_user_question', toolArguments: QUESTION },
      done: { sequence: ['success'], repeatLast: true, successText: 'X4 done' },
    }, (b) => (hasToolResult(b) ? 'done' : 'ask'))
    await until(async () => (await call('GET', '/state')).gateway?.pending.length > 0 || (await count(sessionId, 'turn/end')) > 0, 30_000, 'question to be pending')
    await sleep(1500)
    const s = await call('GET', '/state')
    const st = await call('GET', `/session-state/${sessionId}`)
    results.scenarios.push({ name: '5a-question-no-plugin', sessionId, gatewayPending: s.gateway?.pending, sessionState: { running: st.running, pendingInput: st.pendingInput } })
    check('5a', 'question is held as a pending web event `user-questions/request` (not approval/request)', s.gateway?.pending.some((p) => p.event === 'user-questions/request') && !s.gateway?.pending.some((p) => p.event === 'approval/request'), s.gateway?.pending)
    check('5a', 'web state marks input-required as a question, distinct from approval', st.pendingInput?.length > 0 && !st.pendingInput.includes('approval'), st.pendingInput)
    await call('POST', `/cancel/${sessionId}`)
    await until(async () => (await count(sessionId, 'turn/end')) > 0, 20_000, 'turn end after cancel')
  }

  // 5b. Agent question with a prepended plugin answerer; a steer arrives while it waits.
  {
    await call('POST', '/questions/mode', { on: true })
    const { t0, sessionId } = await newTask('5b-question-plugin', {
      ask: { sequence: ['tool_call_success'], repeatLast: true, toolName: 'ask_user_question', toolArguments: QUESTION },
      done: { sequence: ['success'], repeatLast: true, successText: 'X4 done' },
    }, (b) => (hasToolResult(b) ? 'done' : 'ask'))
    await until(async () => (await call('GET', '/state')).parked.length > 0 || (await count(sessionId, 'turn/end')) > 0, 30_000, 'question to be parked')
    const s = await call('GET', '/state')
    const q = s.parked[0]
    const steer = await call('POST', '/prompt', { sessionId, mode: 'steer', text: 'X4-STEER-DURING-QUESTION meanwhile' })
    await sleep(1500)
    const stillParked = (await call('GET', '/state')).parked.length
    await call('POST', `/questions/${q?.id}`, { answer: { answers: [{ id: 'q1', selected: ['main (Recommended)'] }] } })
    await until(async () => (await count(sessionId, 'turn/end')) >= 1, 30_000, 'turn end after answer')
    await sleep(500)
    const reqs = host.traffic.filter((t) => t.at >= t0 && t.routed !== 'side')
    const place = await placement(sessionId)
    results.scenarios.push({ name: '5b-question-plugin', sessionId, parked: q, steer, stillParkedAfterSteer: stillParked, step2: { lastToolResult: reqs[1]?.lastToolResult, markers: [...new Set((reqs[1]?.users ?? []).join('\n').match(marker) ?? [])] }, placement: place, gatewayPendingWhileParked: s.gateway?.pending })
    check('5b', 'plugin parks the question with its questions/options', q?.questions?.[0]?.id === 'q1' && q.questions[0].options.length === 2, q)
    check('5b', 'web does not see it while the plugin holds it', s.gateway?.pending.length === 0, s.gateway?.pending)
    check('5b', 'a steer does not release the question (still parked)', stillParked === 1, stillParked)
    check('5b', 'model gets the answer as the tool result', /main \(Recommended\)/.test(reqs[1]?.lastToolResult ?? ''), reqs[1]?.lastToolResult)
    check('5b', 'steer sent during the question lands in the step after the answer', place.some((p) => p.marker === 'X4-STEER-DURING-QUESTION' && p.logged && p.turn === 1 && p.step === 2), place)
    await call('POST', '/questions/mode', { on: false })
  }
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
console.log(`\n${checks.filter((c) => c.pass).length}/${checks.length} checks passed → spikes/x4-midtask/results/latest.json`)
process.exit(results.passed ? 0 : 1)
