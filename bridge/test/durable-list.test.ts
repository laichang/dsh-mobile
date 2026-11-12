import { startTestBridge, type TestBridge } from './tls-bridge.ts'
/**
 * Durable list + resume: the host event log, Resume, ListTasks, and tasks
 * that outlive the connection that created them. All against FakeDSH.
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { approvalAudit } from '../src/approvals/audit.ts'
import { ApprovalHolder } from '../src/approvals/holder.ts'
import { ApprovalDecision, ApprovalOutcome } from '../src/gen/approvals_pb.ts'
import { TaskHub } from '../src/tasks/task-hub.ts'
import { after, describe, test } from 'node:test'
import { SUPPORTED_DSH } from '../src/compatibility.ts'
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { DshTasks } from '../src/dsh.ts'
import { FrameSchema, TaskStatus, type Event, type Frame, type Response } from '../src/gen/frame_pb.ts'
import { TaskState } from '../src/gen/durable_list_pb.ts'
import { HostLog } from '../src/tasks/host-log.ts'
import { type BridgeServer } from '../src/server.ts'
import { FakeDSH, type FakeDSHOptions } from './fake-dsh.ts'

type RequestBody = NonNullable<MessageInitShape<typeof FrameSchema>['kind']> extends infer K
  ? K extends { case: 'request'; value: infer V } ? V extends { body?: infer B } ? B : never : never : never

async function connect(server: TestBridge, capabilities: string[] = []) {
  const ws = await server.socket()
  ws.binaryType = 'nodebuffer'
  const frames: Frame[] = []
  const waiters: (() => void)[] = []
  ws.on('message', (data: Buffer) => {
    frames.push(fromBinary(FrameSchema, new Uint8Array(data)))
    for (const w of waiters.splice(0)) w()
  })
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject) })
  let nextId = 1n
  const client = {
    frames,
    /** Sends a request; returns its id. */
    send(body: RequestBody): bigint {
      const id = nextId++
      ws.send(toBinary(FrameSchema, create(FrameSchema, { kind: { case: 'request', value: { id, body } } })))
      return id
    },
    async until(pred: (fs: Frame[]) => boolean, ms = 5000) {
      const deadline = Date.now() + ms
      while (!pred(frames)) {
        if (Date.now() > deadline) throw new Error(`timed out; got ${frames.length} frames`)
        await new Promise<void>((r) => { waiters.push(r); setTimeout(r, 20) })
      }
    },
    /** Sends a request and waits for its response. */
    async call(body: RequestBody): Promise<Response> {
      const id = client.send(body)
      const isIt = (f: Frame) => f.kind.case === 'response' && f.kind.value.requestId === id
      await client.until((fs) => fs.some(isIt))
      return frames.find(isIt)!.kind.value as Response
    },
    events(): Event[] {
      return frames.flatMap((f) => (f.kind.case === 'event' ? [f.kind.value] : []))
    },
    close() { ws.close() },
  }
  await client.call({ case: 'hello', value: { protocolVersion: 1, capabilities } })
  return client
}

const servers: BridgeServer[] = []
after(async () => { await Promise.all(servers.map((s) => s.close())) })

async function bridgeWith(options: FakeDSHOptions = {}) {
  const dsh = new FakeDSH(options)
  const server = await startTestBridge({
    dshVersion: SUPPORTED_DSH,
    host: '127.0.0.1', port: 0, tasks: new DshTasks(dsh, '/tmp/dshm-ws'),
    hostName: 'test-mac',
  })
  servers.push(server)
  return { dsh, server }
}

const endedCount = (fs: Frame[]) =>
  fs.filter((f) => f.kind.case === 'event' && f.kind.value.body.case === 'taskEnded').length

describe('HostLog', () => {
  test('sinceReturnsExactlyTheEventsAfterSeq', () => {
    const log = new HostLog(100, 'log-a')
    for (let i = 0; i < 10; i++) log.append(`t${i % 2}`, { case: 'assistantChunk', value: { taskId: 't', seq: BigInt(i), text: String(i) } })
    for (const after of [0n, 1n, 5n, 9n, 10n]) {
      const r = log.since('log-a', after)
      assert.equal(r.reset, false)
      assert.deepEqual(r.events.map((e) => e.seq), Array.from({ length: Number(10n - after) }, (_, i) => after + 1n + BigInt(i)))
    }
  })

  test('sinceResetsForAnotherLogAFutureSeqOrTrimmedEvents', () => {
    const log = new HostLog(4, 'log-a')
    for (let i = 0; i < 10; i++) log.append('t', { case: 'assistantChunk', value: { taskId: 't', seq: BigInt(i), text: String(i) } })
    assert.equal(log.firstRetained, 7n)
    for (const [logId, after] of [['log-b', 8n], ['', 0n], ['log-a', 11n], ['log-a', 5n]] as const) {
      const r = log.since(logId, after)
      assert.equal(r.reset, true, `${logId} ${after}`)
      assert.deepEqual(r.events.map((e) => e.seq), [7n, 8n, 9n, 10n])
    }
    // Exactly at the trim boundary still continues.
    assert.deepEqual(log.since('log-a', 6n), { reset: false, events: log.since('log-a', 6n).events })
    assert.deepEqual(log.since('log-a', 6n).events.map((e) => e.seq), [7n, 8n, 9n, 10n])
  })
})

describe('ResumeAgainstFakeDSH', () => {
  test('resumeReturnsExactlyTheEventsAfterSeq', async () => {
    const { server } = await bridgeWith({ reply: ['a', 'b', 'c'] })
    const writer = await connect(server)
    await writer.call({ case: 'createTask', value: { prompt: 'one' } })
    await writer.call({ case: 'createTask', value: { prompt: 'two' } })
    await writer.until((fs) => endedCount(fs) === 2)
    const head = server.hub.log.head
    const logged = server.hub.log.since(server.hub.log.logId, 0n).events
    assert.ok(head >= 10n, `head ${head}`)

    for (const afterSeq of [0n, 3n, head - 1n, head]) {
      const reader = await connect(server)
      const resumed = await reader.call({ case: 'resume', value: { logId: server.hub.log.logId, afterSeq } })
      assert.equal(resumed.body.case, 'resumed')
      const r = resumed.body.value
      assert.equal(r.reset, false)
      assert.equal(r.headSeq, head)
      assert.equal(r.hostName, 'test-mac')
      assert.equal(r.replayed, head - afterSeq)
      // Exactly the gap: seqs after_seq+1 … head, in order, with the logged bodies.
      const replayed = reader.events()
      assert.deepEqual(replayed.map((e) => e.hostSeq), logged.filter((e) => e.seq > afterSeq).map((e) => e.seq))
      assert.deepEqual(replayed.map((e) => e.body.case), logged.filter((e) => e.seq > afterSeq).map((e) => e.body?.case))
      reader.close()
    }

    // After the replay the reader is live: a new task's events follow with head+1, head+2, …
    const reader = await connect(server)
    await reader.call({ case: 'resume', value: { logId: server.hub.log.logId, afterSeq: head } })
    await writer.call({ case: 'createTask', value: { prompt: 'three' } })
    await reader.until((fs) => endedCount(fs) === 1)
    const live = reader.events().map((e) => e.hostSeq)
    assert.deepEqual(live, live.map((_, i) => head + 1n + BigInt(i)))
    writer.close()
    reader.close()
  })

  test('resumeFromAnotherLogSendsLogResetThenEverything', async () => {
    const { server } = await bridgeWith()
    const writer = await connect(server)
    await writer.call({ case: 'createTask', value: { prompt: 'one' } })
    await writer.until((fs) => endedCount(fs) === 1)
    writer.close()

    const reader = await connect(server)
    const resumed = await reader.call({ case: 'resume', value: { logId: 'a-log-from-an-older-bridge', afterSeq: 99n } })
    assert.ok(resumed.body.case === 'resumed')
    assert.equal(resumed.body.value.reset, true)
    const [reset, ...rest] = reader.events()
    assert.ok(reset.body.case === 'logReset')
    assert.equal(reset.body.value.logId, server.hub.log.logId)
    assert.equal(reset.hostSeq, 0n)
    assert.deepEqual(rest.map((e) => e.hostSeq), rest.map((_, i) => BigInt(i + 1)))
    reader.close()
  })

  test('taskOutlivesTheConnectionThatCreatedIt', async () => {
    const reply = ['one ', 'two ', 'three ', 'four ', 'five']
    const { server } = await bridgeWith({ reply, chunkDelayMs: 40 })
    const writer = await connect(server)
    const created = await writer.call({ case: 'createTask', value: { prompt: 'count to five' } })
    assert.ok(created.body.case === 'taskCreated')
    const taskId = created.body.value.taskId
    await writer.until((fs) => fs.some((f) => f.kind.case === 'event' && f.kind.value.body.case === 'assistantChunk'))
    const seen = writer.events().at(-1)!.hostSeq
    writer.close() // the app is killed mid-task

    await new Promise((r) => setTimeout(r, 400)) // the task finishes while nobody is connected

    const reader = await connect(server)
    await reader.call({ case: 'resume', value: { logId: server.hub.log.logId, afterSeq: seen } })
    const gap = reader.events()
    const text = gap.flatMap((e) => (e.body.case === 'assistantChunk' ? [e.body.value.text] : []))
    const before = server.hub.log.since(server.hub.log.logId, 0n).events
      .filter((e) => e.seq <= seen && e.body?.case === 'assistantChunk')
      .map((e) => (e.body?.case === 'assistantChunk' ? e.body.value.text ?? '' : ''))
    assert.equal(before.join('') + text.join(''), reply.join(''))
    const last = gap.at(-1)!
    assert.ok(last.body.case === 'taskEnded')
    assert.equal(last.body.value.taskId, taskId)
    assert.equal(last.body.value.status, TaskStatus.COMPLETED)
    reader.close()
  })

  test('listTasksReturnsTheHostsTasksNewestFirst', async () => {
    const { server } = await bridgeWith({ failWith: { kind: 'error', error: { message: 'boom' } } })
    const a = await connect(server)
    await a.call({ case: 'createTask', value: { prompt: 'first' } })
    await a.call({ case: 'createTask', value: { prompt: 'second' } })
    await a.until((fs) => endedCount(fs) === 2)
    a.close()
    const b = await connect(server)
    const list = await b.call({ case: 'listTasks', value: {} })
    assert.ok(list.body.case === 'taskList')
    assert.equal(list.body.value.hostName, 'test-mac')
    assert.equal(list.body.value.logId, server.hub.log.logId)
    assert.deepEqual(list.body.value.tasks.map((t) => t.title), ['second', 'first'])
    assert.ok(list.body.value.tasks.every((t) => t.state === TaskState.FAILED && t.message === 'boom'))
    b.close()
  })

  test('resumeBeforeHelloIsRefused', async () => {
    const { server } = await bridgeWith()
    const ws = await server.socket()
    ws.binaryType = 'nodebuffer'
    await new Promise((resolve) => ws.once('open', resolve))
    const got = new Promise<Frame>((resolve) => ws.once('message', (d: Buffer) => resolve(fromBinary(FrameSchema, new Uint8Array(d)))))
    ws.send(toBinary(FrameSchema, create(FrameSchema, { kind: { case: 'request', value: { id: 3n, body: { case: 'resume', value: {} } } } })))
    const f = await got
    ws.close()
    assert.ok(f.kind.case === 'response' && f.kind.value.body.case === 'error')
    assert.equal(f.kind.value.body.value.code, 'hello/required')
  })
})

/** The durable list with milestones: milestones are host-log events, so Resume replays them. */
describe('ResumeReplaysMilestones', () => {
  test('resumeAfterSeqReplaysTheMissedMilestonesOnce', async () => {
    const steps = (...s: string[]) => ({ todos: s.map((status, i) => ({ content: `Step ${i + 1}`, status })) })
    const { server } = await bridgeWith({
      reply: ['ok'],
      events: [
        { type: 'todo/write', data: steps('in_progress', 'pending') },
        { type: 'todo/write', data: steps('completed', 'in_progress') },
        { type: 'todo/write', data: steps('completed', 'completed') },
      ],
    })
    const writer = await connect(server)
    await writer.call({ case: 'createTask', value: { prompt: 'two steps' } })
    await writer.until((fs) => endedCount(fs) === 1)
    writer.close()
    const logged = writer.events()
    const milestones = logged.filter((e) => e.body.case === 'milestoneAdded')
    assert.ok(milestones.length >= 4, `milestones: ${milestones.length}`)
    assert.ok(milestones.every((e) => e.hostSeq > 0n), 'every milestone is numbered in the host log')
    // Resume from just after the second milestone: exactly the later events, milestones included.
    const cursor = milestones[1].hostSeq
    const reader = await connect(server)
    const listing = await reader.call({ case: 'listTasks', value: {} })
    assert.ok(listing.body.case === 'taskList')
    const resumed = await reader.call({ case: 'resume', value: { logId: listing.body.value.logId, afterSeq: cursor } })
    assert.ok(resumed.body.case === 'resumed' && !resumed.body.value.reset)
    reader.close()
    const replayed = reader.events()
    assert.deepEqual(replayed.map((e) => e.hostSeq), logged.filter((e) => e.hostSeq > cursor).map((e) => e.hostSeq))
    const replayedMilestones = replayed.flatMap((e) => (e.body.case === 'milestoneAdded' ? [e.body.value] : []))
    assert.deepEqual(
      replayedMilestones.map((m) => m.seq),
      milestones.slice(2).map((e) => (e.body.case === 'milestoneAdded' ? e.body.value.seq : -1n)))
    // The latest milestone carries the whole todo list, so it alone is enough for the card.
    assert.equal(replayedMilestones.at(-1)?.todos.length, 2)
  })
})

test('legacyResumeAndListOmitTemporaryUpstreamApprovalRows', async () => {
  const { server } = await bridgeWith()
  server.hub.approvalChanged({ id: 'ask', taskId: 'external', tool: 'bash', argumentsJson: '{}', reason: '', callId: 'call' }, true)
  const client = await connect(server)
  try {
    await client.call({ case: 'resume', value: { logId: '', afterSeq: 0n } })
    assert.deepEqual(client.events().map(event => event.body.case), ['logReset'])
    const list = await client.call({ case: 'listTasks', value: {} })
    assert.equal(list.body.case, 'taskList')
    if (list.body.case === 'taskList') assert.deepEqual(list.body.value.tasks, [])
  } finally {
    client.close()
  }
})

test('waitingTaskSwitchesModelResumesBothFieldsAndInterruptCancelsApproval', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'dshm-waiting-task-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  const dsh = new FakeDSH({ reply: ['slow response'], chunkDelayMs: 2000 })
  const tasks = new DshTasks(dsh, dir)
  const hub = new TaskHub(tasks, new HostLog(1))
  const approvals = new ApprovalHolder(approvalAudit(dir).append, event => hub.approvalChanged(event))
  const server = await startTestBridge({ dshVersion: SUPPORTED_DSH, host: '127.0.0.1', port: 0, tasks, hub, approvals })
  servers.push(server)
  const writer = await connect(server, ['approvals.v1'])
  const created = await writer.call({ case: 'createTask', value: { prompt: 'hold for approval' } })
  assert.ok(created.body.case === 'taskCreated')
  const taskId = created.body.value.taskId
  const held = approvals.hold({
    agent: { session: { id: taskId, deriveMessages: () => [] } }, toolName: 'bash',
  }, async () => 'unavailable')
  const selection = { provider: 'provider', model: 'model', reasoningEffort: 'high' }
  const changed = await writer.call({ case: 'selectModel', value: { taskId, selection } })
  assert.equal(changed.body.case, 'modelSelected')
  await writer.until(() => hub.list()[0].modelSelection?.reasoningEffort === 'high')
  writer.close()

  const reader = await connect(server, ['approvals.v1'])
  try {
    const resumed = await reader.call({ case: 'resume', value: { logId: hub.log.logId, afterSeq: 0n } })
    assert.ok(resumed.body.case === 'resumed' && resumed.body.value.reset)
    const listing = await reader.call({ case: 'listTasks', value: {} })
    assert.ok(listing.body.case === 'taskList')
    const [row] = listing.body.value.tasks
    assert.equal(row.state, TaskState.WAITING_ON_USER)
    assert.equal(row.modelSelection?.reasoningEffort, 'high')
    assert.equal(row.pendingApprovals.length, 1)
    const approvalId = row.pendingApprovals[0].id
    const interrupted = await reader.call({ case: 'interrupt', value: { taskId } })
    assert.equal(interrupted.body.case, 'interruptAccepted')
    assert.equal(await held, 'cancelled')
    const stale = await reader.call({ case: 'answerApproval', value: { id: approvalId, decision: ApprovalDecision.ALLOW_ONCE } })
    assert.ok(stale.body.case === 'error' && stale.body.value.code === 'approval/refused')
    await reader.until(frames => endedCount(frames) === 1)
    assert.ok(reader.events().some(e => e.body.case === 'approvalResolved' && e.body.value.outcome === ApprovalOutcome.CANCELLED))
    assert.equal(hub.list()[0].state, 'INTERRUPTED')
    assert.equal(hub.list()[0].pendingApprovals.length, 0)
  } finally {
    approvals.close()
    reader.close()
  }
})
