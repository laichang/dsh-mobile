import assert from 'node:assert/strict'
import { after, describe, test } from 'node:test'
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocket } from 'ws'
import { PlaintextChannel } from '../src/channel.ts'
import { DshTasks } from '../src/dsh.ts'
import { FrameSchema, type Frame } from '../src/gen/frame_pb.ts'
import { MilestoneKind, TodoStatus, type MilestoneAdded } from '../src/gen/milestones_pb.ts'
import { MilestoneMapper } from '../src/milestones/mapper.ts'
import { PLAINTEXT_PATH, startBridgeServer, type BridgeServer } from '../src/server.ts'
import { FAKE_DSH_EPOCH_MS, FakeDSH, type FakeDSHOptions } from './fake-dsh.ts'

const servers: BridgeServer[] = []
after(async () => { await Promise.all(servers.map((s) => s.close())) })

/** Runs one task through the real bridge server against FakeDSH; returns every frame received. */
async function runTask(options: FakeDSHOptions): Promise<Frame[]> {
  const server = await startBridgeServer({
    host: '127.0.0.1', port: 0, channel: new PlaintextChannel(), tasks: new DshTasks(new FakeDSH(options), '/tmp/dshm-ws'),
  })
  servers.push(server)
  const ws = new WebSocket(`ws://127.0.0.1:${server.port}${PLAINTEXT_PATH}`)
  ws.binaryType = 'nodebuffer'
  const frames: Frame[] = []
  const done = new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timed out; got ${frames.length} frames`)), 3000)
    ws.on('message', (data: Buffer) => {
      const f = fromBinary(FrameSchema, new Uint8Array(data))
      frames.push(f)
      if (f.kind.case === 'event' && f.kind.value.body.case === 'taskEnded') { clearTimeout(timer); resolve() }
    })
  })
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject) })
  const send = (frame: MessageInitShape<typeof FrameSchema>) => ws.send(toBinary(FrameSchema, create(FrameSchema, frame)))
  send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
  send({ kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: { prompt: 'three steps' } } } } })
  await done
  ws.close()
  return frames
}

const milestonesOf = (frames: Frame[]): MilestoneAdded[] =>
  frames.flatMap((f) => f.kind.case === 'event' && f.kind.value.body.case === 'milestoneAdded' ? [f.kind.value.body.value] : [])

const todos = (...statuses: ('pending' | 'in_progress' | 'completed')[]) =>
  ({ todos: statuses.map((status, i) => ({ content: `Step ${i + 1}`, status })) })

/** Compact view of a milestone for assertions: kind, text, and the todo statuses as P/I/C. */
const brief = (m: MilestoneAdded) => {
  const letter = { [TodoStatus.PENDING]: 'P', [TodoStatus.IN_PROGRESS]: 'I', [TodoStatus.COMPLETED]: 'C' } as Record<number, string>
  return `${MilestoneKind[m.kind]}|${m.text}|${m.todos.map((t) => letter[t.status]).join('')}`
}

describe('MilestoneMapperAgainstFakeDSH', () => {
  test('mapsTodosPlanStateAndErrorsIntoMilestoneAdded', async () => {
    const frames = await runTask({
      reply: ['All', ' done.'],
      events: [
        { type: 'plan/mode', data: { active: true } },
        { type: 'todo/write', data: todos('in_progress', 'pending', 'pending') },
        { type: 'plan/mode', data: { active: false } },
        { type: 'step/start', data: { step: 1 } },
        { type: 'todo/write', data: todos('completed', 'in_progress', 'pending') },
        { type: 'llm/retry', data: { step: 2, retry: 1, failure: { message: 'rate limited', code: 'RATE_LIMIT' } } },
        { type: 'todo/write', data: todos('completed', 'completed', 'in_progress') },
        { type: 'todo/write', data: todos('completed', 'completed', 'in_progress') },
        { type: 'todo/write', data: todos('completed', 'completed', 'completed') },
      ],
    })
    const ms = milestonesOf(frames)
    assert.deepEqual(ms.map(brief), [
      'STARTED||',
      'PLAN_MODE_ENTERED||',
      'PLANNED||IPP',
      'TODO_STARTED|Step 1|IPP',
      'PLAN_MODE_LEFT||IPP',
      'TODO_DONE|Step 1|CIP',
      'TODO_STARTED|Step 2|CIP',
      'RETRYING|rate limited|CIP',
      'TODO_DONE|Step 2|CCI',
      'TODO_STARTED|Step 3|CCI',
      'TODO_DONE|Step 3|CCC',
      'FINISHED||CCC',
    ])
    assert.deepEqual(ms.map((m) => m.seq), ms.map((_, i) => BigInt(i + 1)))
    const taskId = ms[0].taskId
    assert.ok(taskId && ms.every((m) => m.taskId === taskId))
    assert.deepEqual(ms[2].todos.map((t) => t.content), ['Step 1', 'Step 2', 'Step 3'])
    // Every milestone carries the time DSH recorded its event (FakeDSH: epoch + seq seconds).
    assert.ok(ms.every((m) => m.timeMs > BigInt(FAKE_DSH_EPOCH_MS)))
    assert.ok(ms.every((m, i) => i === 0 || m.timeMs >= ms[i - 1].timeMs))
    // The timeline closes before TaskEnded, which stays the last frame.
    const last = frames.at(-1)!
    assert.ok(last.kind.case === 'event' && last.kind.value.body.case === 'taskEnded')
  })

  test('failedTurnBecomesFailedMilestone', async () => {
    const frames = await runTask({
      failWith: { kind: 'error', error: { message: 'model unavailable' } },
      events: [{ type: 'todo/write', data: todos('in_progress', 'pending') }],
    })
    assert.deepEqual(milestonesOf(frames).map(brief), [
      'STARTED||', 'PLANNED||IP', 'TODO_STARTED|Step 1|IP', 'FAILED|error: model unavailable|IP',
    ])
  })

  test('noTodosStillGivesStartedAndFinished', async () => {
    const frames = await runTask({})
    assert.deepEqual(milestonesOf(frames).map(brief), ['STARTED||', 'FINISHED||'])
  })
})

describe('MilestoneMapper', () => {
  const ev = (type: string, data: unknown, seq = 1) => ({ type, seq, time: 1000 + seq, data })

  test('changedItemsReplanAndRemovedListReplans', () => {
    const m = new MilestoneMapper()
    m.map(ev('turn/start', { turn: 1 }))
    m.map(ev('todo/write', todos('in_progress', 'pending')))
    const grown = m.map(ev('todo/write', { todos: [...todos('completed', 'in_progress').todos, { content: 'Step 3', status: 'pending' }] }))
    assert.deepEqual(grown.map((x) => `${x.kind}:${x.text}`), ['planned:', 'todoDone:Step 1', 'todoStarted:Step 2'])
    const cleared = m.map(ev('todo/write', { todos: [] }))
    assert.deepEqual(cleared.map((x) => `${x.kind}:${x.todos.length}`), ['planned:0'])
  })

  test('ignoresMalformedPayloadsLaterTurnsAndEventsAfterTheEnd', () => {
    const m = new MilestoneMapper()
    assert.deepEqual(m.map(ev('turn/start', { turn: 1 })).map((x) => x.kind), ['started'])
    assert.deepEqual(m.map(ev('todo/write', { todos: [{ content: 'x', status: 'blocked' }] })), [])
    assert.deepEqual(m.map(ev('todo/write', null)), [])
    assert.deepEqual(m.map(ev('plan/mode', { active: 'yes' })), [])
    assert.deepEqual(m.map(ev('plan/mode', { active: false })), [], 'already out of plan mode')
    assert.deepEqual(m.map(ev('turn/start', { turn: 2 })), [])
    assert.deepEqual(m.map(ev('turn/end', { turn: 2, reason: { kind: 'completed' } })), [])
    assert.deepEqual(m.map(ev('turn/end', { turn: 1, reason: { kind: 'aborted' } })).map((x) => `${x.kind}:${x.text}`), ['failed:aborted'])
    assert.deepEqual(m.map(ev('todo/write', todos('in_progress'))), [])
    assert.deepEqual(m.abandon('closed', 0), [])
  })

  test('abandonFailsOnceWithTheLastTodos', () => {
    const m = new MilestoneMapper()
    m.map(ev('turn/start', { turn: 1 }))
    m.map(ev('todo/write', todos('in_progress')))
    assert.deepEqual(m.abandon('stream closed', 5).map((x) => [x.kind, x.text, x.todos.length, x.timeMs]), [['failed', 'stream closed', 1, 5]])
    assert.deepEqual(m.abandon('again', 6), [])
  })
})
