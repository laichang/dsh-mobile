import assert from 'node:assert/strict'
import { after, describe, test } from 'node:test'
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocket } from 'ws'
import { PlaintextChannel, isLoopbackAddress } from '../src/channel.ts'
import { DshTasks } from '../src/dsh.ts'
import { FrameSchema, TaskStatus, type Frame } from '../src/gen/frame_pb.ts'
import { startBridgeServer, type BridgeServer } from '../src/server.ts'
import { FakeDSH, type FakeDSHOptions } from './fake-dsh.ts'

/** A minimal test client: send Requests, collect every Frame received. */
async function connect(port: number) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`)
  ws.binaryType = 'nodebuffer'
  const frames: Frame[] = []
  const waiters: (() => void)[] = []
  ws.on('message', (data: Buffer) => {
    frames.push(fromBinary(FrameSchema, new Uint8Array(data)))
    for (const w of waiters.splice(0)) w()
  })
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject) })
  return {
    frames,
    send(request: MessageInitShape<typeof FrameSchema>) { ws.send(toBinary(FrameSchema, create(FrameSchema, request))) },
    async until(pred: (fs: Frame[]) => boolean, ms = 3000) {
      const deadline = Date.now() + ms
      while (!pred(frames)) {
        if (Date.now() > deadline) throw new Error(`timed out; got ${frames.length} frames`)
        await new Promise<void>((r) => { waiters.push(r); setTimeout(r, 50) })
      }
    },
    close() { ws.close() },
  }
}

const servers: BridgeServer[] = []
after(async () => { await Promise.all(servers.map((s) => s.close())) })

async function bridgeWith(options: FakeDSHOptions = {}) {
  const dsh = new FakeDSH(options)
  const server = await startBridgeServer({
    host: '127.0.0.1', port: 0, channel: new PlaintextChannel(), tasks: new DshTasks(dsh, '/tmp/dshm-ws'),
  })
  servers.push(server)
  return { dsh, client: await connect(server.port) }
}

const ended = (fs: Frame[]) => fs.some((f) => f.kind.case === 'event' && f.kind.value.body.case === 'taskEnded')

describe('BridgeAgainstFakeDSH', () => {
  test('createTaskStreamsChunksThenTaskEnded', async () => {
    const { dsh, client } = await bridgeWith({ reply: ['你好', '，', 'world'] })
    client.send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
    client.send({ kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: { prompt: 'hi' } } } } })
    await client.until(ended)
    client.close()

    const [hello, created, ...events] = client.frames
    assert.equal(hello.kind.case, 'response')
    assert.equal(hello.kind.value?.body.case, 'hello')
    assert.deepEqual(hello.kind.case === 'response' && hello.kind.value.body.case === 'hello' && hello.kind.value.body.value.capabilities, ['tasks.v1', 'milestones.v1'])

    assert.ok(created.kind.case === 'response' && created.kind.value.body.case === 'taskCreated')
    assert.equal(created.kind.value.requestId, 2n)
    const taskId = created.kind.value.body.value.taskId
    assert.equal(taskId, 'session-1')

    const chunks = events.flatMap((f) => f.kind.case === 'event' && f.kind.value.body.case === 'assistantChunk' ? [f.kind.value.body.value] : [])
    assert.deepEqual(chunks.map((c) => c.text), ['你好', '，', 'world'])
    assert.deepEqual(chunks.map((c) => c.seq), [1n, 2n, 3n])
    assert.ok(chunks.every((c) => c.taskId === taskId))

    const last = events.at(-1)!
    assert.ok(last.kind.case === 'event' && last.kind.value.body.case === 'taskEnded')
    assert.equal(last.kind.value.body.value.status, TaskStatus.COMPLETED)

    assert.deepEqual(dsh.workspaces, ['/tmp/dshm-ws'])
    assert.deepEqual(dsh.prompts, [{ sessionId: 'session-1', text: 'hi' }])
  })

  test('failedTurnEndsWithFailedStatus', async () => {
    const { client } = await bridgeWith({ reply: ['partial'], failWith: { kind: 'error', error: { message: 'rate limited' } } })
    client.send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
    client.send({ kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: { prompt: 'hi' } } } } })
    await client.until(ended)
    client.close()
    const last = client.frames.at(-1)!
    assert.ok(last.kind.case === 'event' && last.kind.value.body.case === 'taskEnded')
    assert.equal(last.kind.value.body.value.status, TaskStatus.FAILED)
    assert.equal(last.kind.value.body.value.message, 'error: rate limited')
  })

  test('createTaskBeforeHelloIsRefused', async () => {
    const { client } = await bridgeWith()
    client.send({ kind: { case: 'request', value: { id: 7n, body: { case: 'createTask', value: { prompt: 'hi' } } } } })
    await client.until((fs) => fs.length >= 1)
    client.close()
    const f = client.frames[0]
    assert.ok(f.kind.case === 'response' && f.kind.value.body.case === 'error')
    assert.equal(f.kind.value.requestId, 7n)
    assert.equal(f.kind.value.body.value.code, 'hello/required')
  })

  test('sessionCreateFailureIsReported', async () => {
    const { client } = await bridgeWith({ createError: 'no default model' })
    client.send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
    client.send({ kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: { prompt: 'hi' } } } } })
    await client.until((fs) => fs.length >= 2)
    client.close()
    const f = client.frames[1]
    assert.ok(f.kind.case === 'response' && f.kind.value.body.case === 'error')
    assert.equal(f.kind.value.body.value.code, 'task/create-failed')
    assert.equal(f.kind.value.body.value.message, 'no default model')
  })
})

describe('PlaintextChannelBridge', () => {
  test('refusesNonLoopbackAddress', async () => {
    const channel = new PlaintextChannel()
    for (const host of ['0.0.0.0', '192.168.1.10', '10.0.0.1', '::', 'example.com', 'localhost']) {
      assert.throws(() => channel.assertListenAddress(host), /refuses non-loopback/, host)
      await assert.rejects(
        startBridgeServer({ host, port: 0, channel, tasks: new DshTasks(new FakeDSH(), '/tmp') }),
        /refuses non-loopback/, host)
    }
    for (const host of ['127.0.0.1', '127.1.2.3', '::1', '[::1]']) assert.ok(isLoopbackAddress(host), host)
  })
})
