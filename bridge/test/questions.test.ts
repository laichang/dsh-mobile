import assert from 'node:assert/strict'
import { after, describe, test } from 'node:test'
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocket } from 'ws'
import { PlaintextChannel } from '../src/channel.ts'
import { SUPPORTED_DSH } from '../src/compatibility.ts'
import { DshTasks } from '../src/dsh.ts'
import { FrameSchema, type Frame, type RequestSchema } from '../src/gen/frame_pb.ts'
import { QuestionOutcome } from '../src/gen/questions_pb.ts'
import { QuestionHolder, type AskAnswer, type AskItem } from '../src/questions/holder.ts'
import { HostLog } from '../src/s2/host-log.ts'
import { TaskHub } from '../src/s2/task-hub.ts'
import { TaskState } from '../src/gen/s2_pb.ts'
import { PLAINTEXT_PATH, QUESTIONS_CAPABILITY, startBridgeServer, type BridgeServer } from '../src/server.ts'
import { FakeDSH } from './fake-dsh.ts'

const TEMPLATES: AskItem[] = [{
  id: 'q1', question: '桌面上有两个周报模板，用哪个？', header: '模板',
  options: [{ label: '公司模板.pptx', description: 'the company one' }, { label: '简洁版.pptx' }],
}]

async function connect(port: number) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}${PLAINTEXT_PATH}`)
  ws.binaryType = 'nodebuffer'
  const frames: Frame[] = []
  ws.on('message', (data: Buffer) => { frames.push(fromBinary(FrameSchema, new Uint8Array(data))) })
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject) })
  let id = 0n
  return {
    frames,
    request(body: MessageInitShape<typeof RequestSchema>['body']) {
      ws.send(toBinary(FrameSchema, create(FrameSchema, { kind: { case: 'request', value: { id: ++id, body } } })))
      return id
    },
    async until<T>(pick: (fs: Frame[]) => T | undefined, ms = 3000): Promise<T> {
      const deadline = Date.now() + ms
      for (;;) {
        const found = pick(frames)
        if (found !== undefined) return found
        if (Date.now() > deadline) throw new Error(`timed out; got ${frames.map(f => f.kind.value?.body.case).join(', ')}`)
        await new Promise(r => setTimeout(r, 10))
      }
    },
    close() { ws.close() },
  }
}

type Body = Extract<Frame['kind'], { case: 'event' }>['value']['body']
const event = <K extends NonNullable<Body['case']>>(fs: Frame[], kind: K) =>
  fs.flatMap(f => f.kind.case === 'event' && f.kind.value.body.case === kind ? [f.kind.value.body.value as Extract<Body, { case: K }>['value']] : [])
const response = (fs: Frame[], id: bigint) => fs.flatMap(f => f.kind.case === 'response' && f.kind.value.requestId === id ? [f.kind.value.body] : [])[0]
const text = (fs: Frame[]) => fs.map(f => f.kind.case === 'event' && f.kind.value.body.case === 'assistantChunk' ? f.kind.value.body.value.text : '').join('')

const servers: BridgeServer[] = []
after(async () => { await Promise.all(servers.map(s => s.close())) })

/** Two questions in one request: one choice, and one or more choices. */
const REPORT: AskItem[] = [TEMPLATES[0], {
  id: 'q2', question: '周报里放哪些部分？', multiSelect: true,
  options: [{ label: '进展' }, { label: '风险' }, { label: '下周计划' }],
}]

/** Real bridge + FakeDSH whose turn asks TEMPLATES; `web` stands for the DSH Web forwarder after the bridge. */
async function setup(web?: (req: Parameters<FakeDSH['waterfall']>[2]) => Promise<AskAnswer>,
  { ask = TEMPLATES, log }: { ask?: AskItem[]; log?: HostLog } = {}) {
  const dsh = new FakeDSH({ ask })
  const tasks = new DshTasks(dsh, '/tmp/dshm-ws')
  const hub = new TaskHub(tasks, log)
  const questions = new QuestionHolder(e => hub.questionChanged(e))
  questions.register(dsh)
  if (web) dsh.on('user-questions/request', req => web(req))
  const server = await startBridgeServer({ dshVersion: SUPPORTED_DSH, host: '127.0.0.1', port: 0,
    channel: new PlaintextChannel(), tasks, hub, questions })
  servers.push(server)
  const client = await connect(server.port)
  const hello = client.request({ case: 'hello', value: { protocolVersion: 1, capabilities: [QUESTIONS_CAPABILITY] } })
  const caps = await client.until(fs => { const r = response(fs, hello); return r?.case === 'hello' ? r.value.capabilities : undefined })
  assert.ok(caps.includes(QUESTIONS_CAPABILITY))
  client.request({ case: 'createTask', value: { prompt: '用本周的笔记写一份周报' } })
  return { dsh, client, hub, server }
}

describe('Questions', () => {
  test('bridgeHoldsQuestionSendsPendingAndAnswersDshWithTheChosenOption', async () => {
    let webSignal: AbortSignal | undefined
    const { dsh, client } = await setup(req => { webSignal = req.signal; return new Promise(() => {}) })
    const pending = await client.until(fs => event(fs, 'questionPending')[0])
    assert.equal(pending.questions[0].text, TEMPLATES[0].question)
    assert.deepEqual(pending.questions[0].options.map(o => [o.label, o.description]),
      [['公司模板.pptx', 'the company one'], ['简洁版.pptx', '']])
    assert.equal(pending.questions[0].multiSelect, false)
    // The web copy is held as well, and the task waits: no answer by itself.
    assert.ok(webSignal && !webSignal.aborted)
    await new Promise(r => setTimeout(r, 50))
    assert.equal(dsh.answers.length, 0)

    const refused = client.request({ case: 'answerQuestion', value: { id: pending.id, answers: [{ questionId: 'q1', selected: ['其他.pptx'] }] } })
    const error = await client.until(fs => response(fs, refused))
    assert.equal(error.case, 'error')

    const id = client.request({ case: 'answerQuestion', value: { id: pending.id, answers: [{ questionId: 'q1', selected: ['简洁版.pptx'] }] } })
    const answered = await client.until(fs => response(fs, id))
    assert.ok(answered.case === 'questionResolved')
    assert.equal(answered.value.outcome, QuestionOutcome.ANSWERED)
    assert.deepEqual(dsh.answers, [{ answers: [{ id: 'q1', selected: ['简洁版.pptx'] }] }])
    assert.ok(webSignal.aborted, 'the web copy is withdrawn')
    const resolved = await client.until(fs => event(fs, 'questionResolved')[0])
    assert.deepEqual(resolved.answers.map(a => a.selected), [['简洁版.pptx']])
    await client.until(fs => event(fs, 'taskEnded')[0])
    assert.equal(text(client.frames), 'Using 简洁版.pptx.')
    // The card replaces the tool row.
    assert.equal(event(client.frames, 'transcriptBlock').length, 0)
    const late = client.request({ case: 'answerQuestion', value: { id: pending.id, answers: [{ questionId: 'q1', selected: ['公司模板.pptx'] }] } })
    assert.equal((await client.until(fs => response(fs, late))).case, 'error')
    client.close()
  })

  test('answerFromTheWebWithdrawsTheCard', async () => {
    let answerOnWeb!: (a: AskAnswer) => void
    const { dsh, client } = await setup(() => new Promise(resolve => { answerOnWeb = resolve }))
    const pending = await client.until(fs => event(fs, 'questionPending')[0])
    answerOnWeb({ answers: [{ id: 'q1', selected: ['公司模板.pptx'] }] })
    const resolved = await client.until(fs => event(fs, 'questionResolved')[0])
    assert.equal(resolved.id, pending.id)
    assert.equal(resolved.outcome, QuestionOutcome.ANSWERED_ELSEWHERE)
    assert.deepEqual(resolved.answers.map(a => a.selected), [['公司模板.pptx']])
    await client.until(fs => event(fs, 'taskEnded')[0])
    assert.deepEqual(dsh.answers, [{ answers: [{ id: 'q1', selected: ['公司模板.pptx'] }] }])
    const id = client.request({ case: 'answerQuestion', value: { id: pending.id, answers: [{ questionId: 'q1', selected: ['简洁版.pptx'] }] } })
    assert.equal((await client.until(fs => response(fs, id))).case, 'error')
    client.close()
  })

  test('noOtherAnswererKeepsTheQuestionHeldAndInterruptCancelsIt', async () => {
    const { client } = await setup()
    const pending = await client.until(fs => event(fs, 'questionPending')[0])
    await new Promise(r => setTimeout(r, 50))
    assert.equal(event(client.frames, 'questionResolved').length, 0)
    client.request({ case: 'interrupt', value: { taskId: pending.taskId } })
    const resolved = await client.until(fs => event(fs, 'questionResolved')[0])
    assert.equal(resolved.outcome, QuestionOutcome.CANCELLED)
    client.close()
  })

  test('typedAndMultiSelectAnswersReachDshAsGiven', async () => {
    const { dsh, client } = await setup(undefined, { ask: REPORT })
    const pending = await client.until(fs => event(fs, 'questionPending')[0])
    assert.deepEqual(pending.questions.map(q => q.multiSelect), [false, true])
    const ask = (answers: { questionId: string; selected: string[]; custom?: string }[]) =>
      client.request({ case: 'answerQuestion', value: { id: pending.id, answers } })
    const refused = async (answers: Parameters<typeof ask>[0]) => {
      const id = ask(answers)
      const r = await client.until(fs => response(fs, id))
      assert.equal(r.case, 'error', JSON.stringify(answers))
    }
    // One choice only, unless the question is multi-select; typed text counts as the choice.
    await refused([{ questionId: 'q1', selected: ['公司模板.pptx', '简洁版.pptx'] }, { questionId: 'q2', selected: ['进展'] }])
    await refused([{ questionId: 'q1', selected: ['简洁版.pptx'], custom: '都不要' }, { questionId: 'q2', selected: ['进展'] }])
    await refused([{ questionId: 'q1', selected: [], custom: '   ' }, { questionId: 'q2', selected: ['进展'] }])
    await refused([{ questionId: 'q1', selected: [], custom: '用去年的模板' }, { questionId: 'q2', selected: ['进展', '附录'] }])
    assert.equal(dsh.answers.length, 0)

    const id = ask([{ questionId: 'q1', selected: [], custom: ' 用去年的模板 ' }, { questionId: 'q2', selected: ['进展', '下周计划'] }])
    const answered = await client.until(fs => response(fs, id))
    assert.ok(answered.case === 'questionResolved', answered.case)
    assert.equal(answered.value.outcome, QuestionOutcome.ANSWERED)
    assert.deepEqual(answered.value.answers.map(a => [a.questionId, a.selected, a.custom]),
      [['q1', [], '用去年的模板'], ['q2', ['进展', '下周计划'], '']])
    // DSH gets the typed text as its free-text answer, and every chosen option.
    assert.deepEqual(dsh.answers, [{ answers: [{ id: 'q1', selected: [], custom: '用去年的模板' }, { id: 'q2', selected: ['进展', '下周计划'] }] }])
    await client.until(fs => event(fs, 'taskEnded')[0])
    assert.equal(text(client.frames), 'Using 用去年的模板, 进展, 下周计划.')
    client.close()
  })

  test('pendingQuestionIsInTheSummaryAndTheReplayAndWaitsOnUser', async () => {
    // A short log: the QuestionPending event is trimmed before the second phone resumes.
    const { client, hub, server } = await setup(undefined, { log: new HostLog(3) })
    const pending = await client.until(fs => event(fs, 'questionPending')[0])
    const upserted = await client.until(fs => event(fs, 'taskUpserted').find(e => e.task?.pendingQuestions.length))
    assert.equal(upserted.task?.state, TaskState.WAITING_ON_USER)
    assert.equal(upserted.task?.pendingQuestions[0].id, pending.id)
    assert.equal(upserted.task?.pendingQuestions[0].questions[0].text, TEMPLATES[0].question)
    assert.equal(hub.list()[0].state, TaskState.WAITING_ON_USER)

    // A phone that comes later: the summary still has the question, and its replay too while retained.
    const later = await connect(server.port)
    const hello = later.request({ case: 'hello', value: { protocolVersion: 1, capabilities: [QUESTIONS_CAPABILITY] } })
    await later.until(fs => response(fs, hello))
    const list = later.request({ case: 'listTasks', value: {} })
    const tasks = await later.until(fs => { const r = response(fs, list); return r?.case === 'taskList' ? r.value.tasks : undefined })
    assert.equal(tasks[0].state, TaskState.WAITING_ON_USER)
    assert.deepEqual(tasks[0].pendingQuestions.map(q => q.id), [pending.id])
    later.request({ case: 'resume', value: { logId: 'gone', afterSeq: 1n } })
    await later.until(fs => event(fs, 'logReset')[0])
    const replayed = await later.until(fs => event(fs, 'taskUpserted').at(-1))
    assert.deepEqual(replayed.task?.pendingQuestions.map(q => q.id), [pending.id])

    // An app without questions.v1 cannot answer: for it the task runs, with no question.
    const old = await connect(server.port)
    const oldHello = old.request({ case: 'hello', value: { protocolVersion: 1 } })
    await old.until(fs => response(fs, oldHello))
    const oldList = old.request({ case: 'listTasks', value: {} })
    const oldTasks = await old.until(fs => { const r = response(fs, oldList); return r?.case === 'taskList' ? r.value.tasks : undefined })
    assert.equal(oldTasks[0].state, TaskState.RUNNING)
    assert.equal(oldTasks[0].pendingQuestions.length, 0)

    const id = later.request({ case: 'answerQuestion', value: { id: pending.id, answers: [{ questionId: 'q1', selected: ['简洁版.pptx'] }] } })
    assert.equal((await later.until(fs => response(fs, id))).case, 'questionResolved')
    // The answer withdraws the card on the first phone too, and the task runs again.
    const resolved = await client.until(fs => event(fs, 'questionResolved')[0])
    assert.equal(resolved.outcome, QuestionOutcome.ANSWERED)
    const running = await client.until(fs => {
      const ups = event(fs, 'taskUpserted')
      return ups.slice(ups.findIndex(e => e.task?.pendingQuestions.length) + 1).find(e => e.task?.state === TaskState.RUNNING)
    })
    assert.equal(running.task?.pendingQuestions.length, 0)
    await client.until(fs => event(fs, 'taskEnded')[0])
    assert.equal(hub.list()[0].pendingQuestions.length, 0)
    for (const c of [client, later, old]) c.close()
  })

  test('appWithoutQuestionsCapabilityGetsNoCard', async () => {
    const dsh = new FakeDSH({ ask: TEMPLATES })
    const tasks = new DshTasks(dsh, '/tmp/dshm-ws')
    const hub = new TaskHub(tasks)
    const questions = new QuestionHolder(e => hub.questionChanged(e))
    questions.register(dsh)
    const server = await startBridgeServer({ dshVersion: SUPPORTED_DSH, host: '127.0.0.1', port: 0, channel: new PlaintextChannel(), tasks, hub, questions })
    servers.push(server)
    const client = await connect(server.port)
    client.request({ case: 'hello', value: { protocolVersion: 1 } })
    client.request({ case: 'createTask', value: { prompt: 'old app' } })
    await client.until(fs => hub.list()[0])
    await new Promise(r => setTimeout(r, 50))
    assert.equal(event(client.frames, 'questionPending').length, 0)
    questions.close()
    client.close()
  })
})
