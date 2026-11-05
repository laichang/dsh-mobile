import assert from 'node:assert/strict'
import { after, describe, test } from 'node:test'
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocket } from 'ws'
import { PlaintextChannel, isLoopbackAddress } from '../src/channel.ts'
import { DshTasks } from '../src/dsh.ts'
import { FrameSchema, TaskStatus, type Frame } from '../src/gen/frame_pb.ts'
import { PLAINTEXT_PATH, startBridgeServer, type BridgeServer } from '../src/server.ts'
import { FakeDSH, type FakeDSHOptions } from './fake-dsh.ts'

/** A minimal test client: send Requests, collect every Frame received. */
async function connect(port: number) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}${PLAINTEXT_PATH}`)
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
  test('hostCatalogPreservesGroupsNamesEffortsAndDefault', async () => {
    const { dsh, client } = await bridgeWith()
    client.send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
    client.send({ kind: { case: 'request', value: { id: 2n, body: { case: 'getModelCatalog', value: {} } } } })
    await client.until(fs => fs.length === 2)
    client.close()
    const reply = client.frames[1].kind
    assert.ok(reply.case === 'response' && reply.value.body.case === 'modelCatalog')
    const catalog = reply.value.body.value
    assert.equal(catalog.groups[0].name, dsh.catalog.groups[0].name)
    const model = catalog.groups[0].models[0]
    assert.equal(model.name, dsh.catalog.groups[0].models[0].name)
    assert.equal(model.defaultEffort, 'low')
    assert.deepEqual(model.efforts.map(e => [e.id, e.name]), [['low', 'Low'], ['high', 'High']])
    assert.equal(catalog.defaultSelection?.provider, dsh.catalog.default.provider)
    assert.equal(catalog.defaultSelection?.model, dsh.catalog.default.model)
    assert.equal(catalog.defaultSelection?.reasoningEffort, dsh.catalog.default.reasoningEffort)
  })

  test('unavailableModelDoesNotPromptOrSubstitute', async () => {
    const { dsh, client } = await bridgeWith()
    client.send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
    client.send({ kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: {
      prompt: 'hi', modelSelection: { provider: 'provider', model: 'gone' },
    } } } } })
    await client.until(fs => fs.length === 2)
    client.close()
    const reply = client.frames[1].kind
    assert.ok(reply.case === 'response' && reply.value.body.case === 'error')
    assert.match(reply.value.body.value.message, /available model/)
    assert.deepEqual(dsh.prompts, [])
  })

  test('modelSwitchReplaysInOrderAndRejectedSelectionDoesNotChangeTask', async () => {
    const { client } = await bridgeWith({ reply: ['done'], chunkDelayMs: 300 })
    const selection = { provider: 'provider', model: 'model', reasoningEffort: 'low' }
    client.send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
    client.send({ kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: {
      prompt: 'hi', modelSelection: selection,
    } } } } })
    await client.until(fs => fs.some(f => f.kind.case === 'event' && f.kind.value.body.case === 'modelSelected'))
    const created = client.frames[1].kind
    assert.ok(created.case === 'response' && created.value.body.case === 'taskCreated')
    const taskId = created.value.body.value.taskId
    const select = (id: bigint, model: string) => client.send({ kind: { case: 'request', value: { id, body: {
      case: 'selectModel', value: { taskId, selection: { ...selection, model, reasoningEffort: 'high' } },
    } } } })
    select(3n, 'gone')
    await client.until(fs => fs.some(f => f.kind.case === 'response' && f.kind.value.requestId === 3n))
    const rejected = client.frames.find(f => f.kind.case === 'response' && f.kind.value.requestId === 3n)!.kind
    assert.ok(rejected.case === 'response' && rejected.value.body.case === 'error')
    assert.equal(rejected.value.body.value.code, 'model/unavailable')
    select(4n, 'model')
    await client.until(ended)
    const beforeReplay = client.frames.length
    client.send({ kind: { case: 'request', value: { id: 5n, body: { case: 'resume', value: {} } } } })
    await client.until(fs => fs.some(f => f.kind.case === 'response' && f.kind.value.requestId === 5n))
    client.close()
    const changes = (frames: Frame[]) => frames.flatMap(f => f.kind.case === 'event' && f.kind.value.body.case === 'modelSelected'
      ? [[f.kind.value.hostSeq, f.kind.value.body.value.selection?.reasoningEffort]] : [])
    const live = changes(client.frames.slice(0, beforeReplay))
    assert.deepEqual(live.map(change => change[1]), ['low', 'high'])
    assert.deepEqual(changes(client.frames.slice(beforeReplay)), live)
  })

  test('createTaskStreamsChunksThenTaskEnded', async () => {
    const { dsh, client } = await bridgeWith({ reply: ['你好', '，', 'world'] })
    client.send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
    client.send({ kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: { prompt: 'hi' } } } } })
    await client.until(ended)
    client.close()

    const [hello, created, ...events] = client.frames
    assert.equal(hello.kind.case, 'response')
    assert.equal(hello.kind.value?.body.case, 'hello')
    assert.deepEqual(hello.kind.case === 'response' && hello.kind.value.body.case === 'hello' && hello.kind.value.body.value.capabilities, ['tasks.v1', 'milestones.v1', 'resume.v1', 'models.v1'])

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
