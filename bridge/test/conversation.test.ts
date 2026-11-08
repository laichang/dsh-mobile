/**
 * Conversation (ARCHITECTURE D18, D89): a follow-up message into the DSH session of a finished
 * task. The new turn streams under the same task ID, and Resume replays the whole conversation.
 * All against FakeDSH.
 */
import assert from 'node:assert/strict'
import { after, describe, test } from 'node:test'
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocket } from 'ws'
import { PlaintextChannel } from '../src/channel.ts'
import { SUPPORTED_DSH } from '../src/compatibility.ts'
import { DshTasks } from '../src/dsh.ts'
import { MessageMode } from '../src/gen/conversation_pb.ts'
import { FrameSchema, TaskStatus, type Event, type Frame, type Response } from '../src/gen/frame_pb.ts'
import { TaskState } from '../src/gen/s2_pb.ts'
import { CONVERSATION_CAPABILITY, PLAINTEXT_PATH, startBridgeServer, type BridgeServer } from '../src/server.ts'
import { FakeDSH, type FakeDSHOptions } from './fake-dsh.ts'

type RequestBody = NonNullable<MessageInitShape<typeof FrameSchema>['kind']> extends infer K
  ? K extends { case: 'request'; value: infer V } ? V extends { body?: infer B } ? B : never : never : never

async function connect(port: number, capabilities: string[]) {
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
  const hello = await client.call({ case: 'hello', value: { protocolVersion: 1, capabilities } })
  return { client, hello }
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

const ended = (fs: Frame[]) => fs.filter((f) => f.kind.case === 'event' && f.kind.value.body.case === 'taskEnded').length
const caps = [CONVERSATION_CAPABILITY, 'transcript.v1']

/** The task's transcript as an app reads it from the events: user messages and reply text, in order. */
function conversation(events: Event[], taskId: string): string[] {
  const out: string[] = []
  for (const e of events) {
    if (e.body.case === 'userMessage' && e.body.value.taskId === taskId) out.push(`user: ${e.body.value.text}`)
    if (e.body.case === 'assistantChunk' && e.body.value.taskId === taskId) {
      if (out.at(-1)?.startsWith('agent: ')) out[out.length - 1] += e.body.value.text
      else out.push(`agent: ${e.body.value.text}`)
    }
  }
  return out
}

describe('FollowUpAgainstFakeDSH', () => {
  test('aFollowUpOnACompletedTaskStreamsTheNextTurnUnderTheSameTaskID', async () => {
    const { dsh, server } = await bridgeWith({ replies: { 1: ['First', ' answer.'], 2: ['Second', ' answer.'] },
      reasoning: ['Think.'] })
    const { client, hello } = await connect(server.port, caps)
    assert.ok(hello.body.case === 'hello' && hello.body.value.capabilities.includes(CONVERSATION_CAPABILITY))
    const created = await client.call({ case: 'createTask', value: { prompt: 'Say hello' } })
    assert.equal(created.body.case, 'taskCreated')
    const taskId = created.body.value.taskId
    await client.until((fs) => ended(fs) === 1)

    const accepted = await client.call({ case: 'sendMessage', value: { taskId, mode: MessageMode.STEER, text: 'And again?' } })
    assert.equal(accepted.body.case, 'messageAccepted')
    assert.equal(accepted.body.value.taskId, taskId)
    await client.until((fs) => ended(fs) === 2)

    // The same DSH session, prompted twice; the follow-up steers into the idle session (D18).
    assert.deepEqual(dsh.prompts.map((p, i) => [p.sessionId, p.text, dsh.promptOptions[i].mode]),
      [[taskId, 'Say hello', 'queue'], [taskId, 'And again?', 'steer']])
    assert.equal(dsh.promptOptions[1].requestId, accepted.body.value.messageId)

    const events = client.events()
    assert.deepEqual(conversation(events, taskId), ['agent: First answer.', 'user: And again?', 'agent: Second answer.'])
    // One task: chunk seqs go on without gaps across the turns.
    const seqs = events.flatMap((e) => (e.body.case === 'assistantChunk' ? [e.body.value.seq] : []))
    assert.deepEqual(seqs, [1n, 2n, 3n, 4n])
    // The task runs again after the follow-up, and the second TaskEnded ends it as completed.
    const states = events.flatMap((e) => (e.body.case === 'taskUpserted' ? [e.body.value.task!.state] : []))
    assert.deepEqual(states, [TaskState.RUNNING, TaskState.COMPLETED, TaskState.RUNNING, TaskState.COMPLETED])
    const ends = events.flatMap((e) => (e.body.case === 'taskEnded' ? [e.body.value] : []))
    assert.deepEqual(ends.map((e) => [e.taskId, e.status]), [[taskId, TaskStatus.COMPLETED], [taskId, TaskStatus.COMPLETED]])
    // Each turn's thinking is its own block.
    const blocks = new Set(events.flatMap((e) => (e.body.case === 'transcriptBlock' ? [e.body.value.blockId] : [])))
    assert.equal(blocks.size, 2)
    // The UserMessage is logged after MessageAccepted and before the turn's output.
    const userAt = client.frames.findIndex((f) => f.kind.case === 'event' && f.kind.value.body.case === 'userMessage')
    const acceptedAt = client.frames.findIndex((f) => f.kind.case === 'response' && f.kind.value.body.case === 'messageAccepted')
    assert.ok(acceptedAt < userAt)
    client.close()
  })

  test('resumeReplaysTheWholeConversationInOrder', async () => {
    const { server } = await bridgeWith({ replies: { 1: ['One.'], 2: ['Two.'], 3: ['Three.'] } })
    const { client } = await connect(server.port, caps)
    const created = await client.call({ case: 'createTask', value: { prompt: 'Count' } })
    assert.equal(created.body.case, 'taskCreated')
    const taskId = created.body.value.taskId
    await client.until((fs) => ended(fs) === 1)
    await client.call({ case: 'sendMessage', value: { taskId, text: 'More' } })
    await client.until((fs) => ended(fs) === 2)
    await client.call({ case: 'sendMessage', value: { taskId, text: 'Last' } })
    await client.until((fs) => ended(fs) === 3)
    const live = conversation(client.events(), taskId)
    client.close()

    const { client: again } = await connect(server.port, caps)
    const resumed = await again.call({ case: 'resume', value: { logId: '', afterSeq: 0n } })
    assert.equal(resumed.body.case, 'resumed')
    const replay = conversation(again.events(), taskId)
    assert.deepEqual(replay, ['agent: One.', 'user: More', 'agent: Two.', 'user: Last', 'agent: Three.'])
    assert.deepEqual(replay, live)
    again.close()
  })

  test('aFollowUpIsRefusedWhileTheTaskRunsAndWhenItIsEmpty', async () => {
    const { server } = await bridgeWith({ reply: ['a', 'b', 'c'], chunkDelayMs: 100 })
    const { client } = await connect(server.port, caps)
    const created = await client.call({ case: 'createTask', value: { prompt: 'Slow' } })
    assert.equal(created.body.case, 'taskCreated')
    const taskId = created.body.value.taskId
    const running = await client.call({ case: 'sendMessage', value: { taskId, text: 'Now?' } })
    assert.equal(running.body.case, 'error')
    assert.equal(running.body.value.code, 'message/refused')
    const empty = await client.call({ case: 'sendMessage', value: { taskId, text: '  ' } })
    assert.ok(empty.body.case === 'error' && empty.body.value.code === 'message/empty')
    const unknown = await client.call({ case: 'sendMessage', value: { taskId: 'nope', text: 'Hi' } })
    assert.ok(unknown.body.case === 'error' && unknown.body.value.code === 'message/refused')
    await client.until((fs) => ended(fs) === 1)
    client.close()
  })

  test('appsWithoutTheCapabilityGetNoUserMessages', async () => {
    const { server } = await bridgeWith({ replies: { 1: ['One.'], 2: ['Two.'] } })
    const { client } = await connect(server.port, caps)
    const created = await client.call({ case: 'createTask', value: { prompt: 'Count' } })
    assert.equal(created.body.case, 'taskCreated')
    await client.until((fs) => ended(fs) === 1)
    await client.call({ case: 'sendMessage', value: { taskId: created.body.value.taskId, text: 'More' } })
    await client.until((fs) => ended(fs) === 2)
    client.close()
    const { client: old } = await connect(server.port, [])
    await old.call({ case: 'resume', value: { logId: '', afterSeq: 0n } })
    assert.equal(old.events().filter((e) => e.body.case === 'userMessage').length, 0)
    old.close()
  })
})
