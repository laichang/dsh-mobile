/**
 * Model failures (ARCHITECTURE D104, D110), against FakeDSH replaying what real DSH 0.2.2-rc.1
 * emitted for each failure (`test/fixtures/model-failures/<case>.json`: every follow frame, recorded
 * with a fake DeepSeek provider in front of DSH's mock LLM). A model failure ends the task as
 * FAILED with DSH's text and failure class, nothing keeps it running, and a new message into the
 * same session continues it.
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { after, describe, test } from 'node:test'
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocket } from 'ws'
import { PlaintextChannel } from '../src/channel.ts'
import { SUPPORTED_DSH } from '../src/compatibility.ts'
import { DshTasks, type FollowFrame } from '../src/dsh.ts'
import { MessageMode } from '../src/gen/conversation_pb.ts'
import { FrameSchema, TaskStatus, type Event, type Frame, type Response } from '../src/gen/frame_pb.ts'
import { MilestoneKind } from '../src/gen/milestones_pb.ts'
import { TaskState } from '../src/gen/s2_pb.ts'
import { failureOf } from '../src/milestones/mapper.ts'
import { CONVERSATION_CAPABILITY, PLAINTEXT_PATH, startBridgeServer, type BridgeServer } from '../src/server.ts'
import { FakeDSH, type FakeDSHOptions } from './fake-dsh.ts'

type RequestBody = NonNullable<MessageInitShape<typeof FrameSchema>['kind']> extends infer K
  ? K extends { case: 'request'; value: infer V } ? V extends { body?: infer B } ? B : never : never : never

interface Fixture {
  case: string
  selection?: { provider: string; model: string }
  selected?: { error: string; code: string }
  followUp?: { value: { accepted: boolean } }
  frames: { atMs: number; frame: FollowFrame }[]
}

/** lib/test/… or test/… → bridge/test/fixtures/model-failures. */
const FIXTURES = new URL(import.meta.url.includes('/lib/test/')
  ? '../../test/fixtures/model-failures/' : './fixtures/model-failures/', import.meta.url)

function fixture(name: string): Fixture {
  return JSON.parse(readFileSync(new URL(`${name}.json`, FIXTURES), 'utf8'))
}

/** The recorded frames per DSH turn: each turn runs to its `turn/end`; the opening snapshot is left out. */
function turns(f: Fixture): Record<number, FollowFrame[]> {
  const out: Record<number, FollowFrame[]> = {}
  let turn = 1
  for (const { frame } of f.frames) {
    if (frame.type === 'snapshot') continue
    ;(out[turn] ??= []).push(frame)
    if (frame.type === 'event' && frame.event.type === 'turn/end') turn += 1
  }
  return out
}

/** How DSH ended each recorded turn: `reason` of every `turn/end`, in order. */
function ends(f: Fixture) {
  return f.frames.flatMap(({ frame }) => frame.type === 'event' && frame.event.type === 'turn/end'
    ? [(frame.event.data as { reason: { kind: string; error?: { message: string; code: string } } }).reason] : [])
}

async function connect(port: number) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}${PLAINTEXT_PATH}`)
  ws.binaryType = 'nodebuffer'
  const frames: Frame[] = []
  ws.on('message', (data: Buffer) => { frames.push(fromBinary(FrameSchema, new Uint8Array(data))) })
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject) })
  let nextId = 1n
  const client = {
    frames,
    async until(pred: (fs: Frame[]) => boolean, ms = 5000) {
      const deadline = Date.now() + ms
      while (!pred(frames)) {
        if (Date.now() > deadline) throw new Error(`timed out; got ${frames.length} frames`)
        await new Promise((r) => setTimeout(r, 10))
      }
    },
    async call(body: RequestBody): Promise<Response> {
      const id = nextId++
      ws.send(toBinary(FrameSchema, create(FrameSchema, { kind: { case: 'request', value: { id, body } } })))
      const isIt = (f: Frame) => f.kind.case === 'response' && f.kind.value.requestId === id
      await client.until((fs) => fs.some(isIt))
      return frames.find(isIt)!.kind.value as Response
    },
    events(): Event[] { return frames.flatMap((f) => (f.kind.case === 'event' ? [f.kind.value] : [])) },
    close() { ws.close() },
  }
  await client.call({ case: 'hello', value: { protocolVersion: 1, capabilities: [CONVERSATION_CAPABILITY, 'transcript.v1'] } })
  return client
}

const servers: BridgeServer[] = []
after(async () => { await Promise.all(servers.map((s) => s.close())) })

async function bridgeWith(options: FakeDSHOptions) {
  const dsh = new FakeDSH(options)
  const server = await startBridgeServer({
    dshVersion: SUPPORTED_DSH, host: '127.0.0.1', port: 0, channel: new PlaintextChannel(),
    tasks: new DshTasks(dsh, '/tmp/dshm-ws'), hostName: 'test-mac',
  })
  servers.push(server)
  return { dsh, server }
}

const endedCount = (fs: Frame[]) => fs.filter((f) => f.kind.case === 'event' && f.kind.value.body.case === 'taskEnded').length

/** Starts a task on a FakeDSH that replays `name`, and waits for its first TaskEnded. */
async function failedTask(name: string) {
  const recorded = fixture(name)
  const { dsh, server } = await bridgeWith({ recorded: turns(recorded) })
  const client = await connect(server.port)
  const created = await client.call({ case: 'createTask', value: { prompt: `X1 case ${name}: say hello` } })
  assert.equal(created.body.case, 'taskCreated')
  const taskId = created.body.value.taskId
  await client.until((fs) => endedCount(fs) === 1)
  return { recorded, dsh, server, client, taskId }
}

/** Every model failure X1 recorded that ends the turn. */
const TERMINAL = ['model-not-found', 'model-not-exist-400', 'invalid-key', 'no-balance', 'rate-limit',
  'mock-auth-error', 'mock-invalid-request', 'mock-quota-exceeded']

describe('ModelFailuresAgainstFakeDSH', () => {
  for (const name of TERMINAL) {
    test(`eachRecordedFailureEndsTheTaskAsFailedWithTheTextOfDSH (${name})`, async () => {
      const { recorded, server, client, taskId } = await failedTask(name)
      const error = ends(recorded)[0].error!
      assert.equal(ends(recorded)[0].kind, 'error')

      // TaskEnded: FAILED, DSH's message as it is, and DSH's failure class (D104).
      const events = client.events()
      const end = events.flatMap((e) => (e.body.case === 'taskEnded' ? [e.body.value] : []))[0]
      assert.deepEqual([end.taskId, end.status, end.message, end.failureCode], [taskId, TaskStatus.FAILED, error.message, error.code])
      // The summary says the same, and the timeline ends on FAILED with the same text.
      const summaries = events.flatMap((e) => (e.body.case === 'taskUpserted' ? [e.body.value.task!] : []))
      const last = summaries.at(-1)!
      assert.deepEqual([last.state, last.message, last.failureCode], [TaskState.FAILED, error.message, error.code])
      const milestones = events.flatMap((e) => (e.body.case === 'milestoneAdded' ? [e.body.value] : []))
      assert.deepEqual([milestones.at(-1)!.kind, milestones.at(-1)!.text], [MilestoneKind.FAILED, error.message])
      // A rate limit is retried by DSH in the turn (5 times), then the turn ends; the others at once.
      const retries = milestones.filter((m) => m.kind === MilestoneKind.RETRYING).length
      assert.equal(retries, error.code === 'RATE_LIMIT' ? 5 : 0)

      // No retry keeps it running: nothing follows TaskEnded, and the host lists it as FAILED.
      await new Promise((r) => setTimeout(r, 50))
      const tail = client.events().at(-1)!
      assert.equal(tail.body.case, 'taskEnded')
      assert.equal(server.hub.isActive(taskId), false)
      const list = await client.call({ case: 'listTasks', value: {} })
      assert.ok(list.body.case === 'taskList')
      const listed = list.body.value.tasks.find((t) => t.taskId === taskId)!
      assert.deepEqual([listed.state, listed.message, listed.failureCode], [TaskState.FAILED, error.message, error.code])
      client.close()
    })
  }

  for (const name of TERMINAL.filter((n) => fixture(n).followUp?.value.accepted)) {
    test(`aNewMessageAfterEachRecordedFailureContinuesTheSameSession (${name})`, async () => {
      const { recorded, dsh, client, taskId } = await failedTask(name)
      assert.equal(ends(recorded)[1].kind, 'completed')
      const accepted = await client.call({ case: 'sendMessage',
        value: { taskId, mode: MessageMode.STEER, text: `X1 case ${name}: please try again` } })
      assert.equal(accepted.body.case, 'messageAccepted')
      await client.until((fs) => endedCount(fs) === 2)

      // The same DSH session, prompted again after the failure (D110).
      assert.deepEqual(dsh.prompts.map((p) => p.sessionId), [taskId, taskId])
      const events = client.events()
      const taskEnds = events.flatMap((e) => (e.body.case === 'taskEnded' ? [e.body.value] : []))
      assert.deepEqual(taskEnds.map((e) => [e.status, e.failureCode]), [[TaskStatus.FAILED, ends(recorded)[0].error!.code], [TaskStatus.COMPLETED, '']])
      assert.deepEqual(taskEnds[1].message, '')
      const states = events.flatMap((e) => (e.body.case === 'taskUpserted' ? [e.body.value.task!.state] : []))
      assert.deepEqual(states, [TaskState.RUNNING, TaskState.FAILED, TaskState.RUNNING, TaskState.COMPLETED])
      const text = events.flatMap((e) => (e.body.case === 'assistantChunk' ? [e.body.value.text] : [])).join('')
      assert.equal(text, 'X1 recovered: the model answered normally.')
      // The turn that continues adds milestones, so the timeline goes on past the failure.
      const kinds = events.flatMap((e) => (e.body.case === 'milestoneAdded' ? [e.body.value.kind] : []))
      assert.deepEqual(kinds.slice(kinds.lastIndexOf(MilestoneKind.FAILED) + 1), [MilestoneKind.STARTED, MilestoneKind.FINISHED])
      client.close()
    })
  }

  test('aRateLimitThatClearsCompletesTheTask', async () => {
    const recorded = fixture('rate-limit-recovers')
    const { server } = await bridgeWith({ recorded: turns(recorded) })
    const client = await connect(server.port)
    const created = await client.call({ case: 'createTask', value: { prompt: 'X1 case rate-limit-recovers: say hello' } })
    assert.equal(created.body.case, 'taskCreated')
    await client.until((fs) => endedCount(fs) === 1)
    const events = client.events()
    const end = events.flatMap((e) => (e.body.case === 'taskEnded' ? [e.body.value] : []))[0]
    assert.deepEqual([end.status, end.message, end.failureCode], [TaskStatus.COMPLETED, '', ''])
    const kinds = events.flatMap((e) => (e.body.case === 'milestoneAdded' ? [e.body.value.kind] : []))
    assert.equal(kinds.filter((k) => k === MilestoneKind.RETRYING).length, 2)
    assert.equal(kinds.at(-1), MilestoneKind.FINISHED)
    client.close()
  })

  test('aModelTheHostDoesNotListIsRefusedWithTheTextOfDSHAndNothingIsSwapped', async () => {
    const recorded = fixture('model-unlisted')
    const { dsh, server } = await bridgeWith({})
    const client = await connect(server.port)
    const refused = await client.call({ case: 'createTask', value: { prompt: 'X1 case model-unlisted: say hello',
      modelSelection: { provider: recorded.selection!.provider, model: recorded.selection!.model } } })
    assert.ok(refused.body.case === 'error')
    assert.deepEqual([refused.body.value.code, refused.body.value.message], ['task/create-failed', recorded.selected!.error])
    assert.equal(dsh.prompts.length, 0, 'no turn runs on another model')
    assert.equal(client.events().filter((e) => e.body.case === 'taskEnded').length, 0)
    client.close()
  })

  test('aModelFailureKeepsDSHsTextAndCodeAndOtherEndsKeepTheirKind', async () => {
    // The directory reads a session from another client (or after a restart) through the same rule.
    assert.deepEqual(failureOf('error', { message: 'Insufficient Balance', code: 'QUOTA', status: 402 }),
      { message: 'Insufficient Balance', code: 'QUOTA' })
    assert.deepEqual(failureOf('error', { message: 'boom' }), { message: 'boom', code: '' })
    assert.deepEqual(failureOf('aborted', { message: 'shutdown' }), { message: 'aborted: shutdown', code: '' })
    assert.deepEqual(failureOf('unknown', undefined), { message: 'unknown', code: '' })
  })
})
