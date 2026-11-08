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
import { TaskHub } from '../src/s2/task-hub.ts'
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

/** Real bridge + FakeDSH whose turn asks TEMPLATES; `web` stands for the DSH Web forwarder after the bridge. */
async function setup(web?: (req: Parameters<FakeDSH['waterfall']>[2]) => Promise<AskAnswer>) {
  const dsh = new FakeDSH({ ask: TEMPLATES })
  const tasks = new DshTasks(dsh, '/tmp/dshm-ws')
  const hub = new TaskHub(tasks)
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
  return { dsh, client }
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
