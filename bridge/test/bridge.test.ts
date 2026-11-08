import assert from 'node:assert/strict'
import { after, describe, test } from 'node:test'
import { SUPPORTED_DSH } from '../src/compatibility.ts'
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocket } from 'ws'
import { PlaintextChannel, isLoopbackAddress } from '../src/channel.ts'
import { DshTasks } from '../src/dsh.ts'
import { FrameSchema, TaskStatus, type Frame } from '../src/gen/frame_pb.ts'
import { TaskState } from '../src/gen/s2_pb.ts'
import { MilestoneKind } from '../src/gen/milestones_pb.ts'
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

async function bridgeWith(options: FakeDSHOptions = {}, dshVersion = SUPPORTED_DSH) {
  const dsh = new FakeDSH(options)
  const server = await startBridgeServer({
    dshVersion,
    host: '127.0.0.1', port: 0, channel: new PlaintextChannel(), tasks: new DshTasks(dsh, '/tmp/dshm-ws'),
  })
  servers.push(server)
  return { dsh, client: await connect(server.port) }
}

const ended = (fs: Frame[]) => fs.some((f) => f.kind.case === 'event' && f.kind.value.body.case === 'taskEnded')

describe('BridgeAgainstFakeDSH', () => {
  test('helloReportsSupportedRangeAndBlocksUnsupportedDshBeforeDispatch', async () => {
    for (const version of [SUPPORTED_DSH, '0.2.2-alpha.3', 'unknown']) {
      const { dsh, client } = await bridgeWith({}, version)
      try {
        client.send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
        await client.until(fs => fs.length === 1)
        const response = client.frames[0].kind
        assert.ok(response.case === 'response' && response.value.body.case === 'hello')
        const hello = response.value.body.value
        assert.equal(hello.dshVersion, version)
        assert.equal(hello.supportedDshRange, SUPPORTED_DSH)
        assert.equal(hello.requiresBridgeUpdate, version !== SUPPORTED_DSH)
        if (hello.requiresBridgeUpdate) {
          assert.deepEqual(hello.capabilities, [])
          client.send({ kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: { prompt: 'no dispatch' } } } } })
          await client.until(fs => fs.length === 2)
          const refusal = client.frames[1].kind
          assert.ok(refusal.case === 'response' && refusal.value.body.case === 'error')
          assert.equal(refusal.value.body.value.code, 'host/bridge-update')
          assert.deepEqual(dsh.workspaces, [])
        }
      } finally { client.close() }
    }
  })

  test('chosenWorkspaceBecomesSessionCwdWithModelAndRecentPaths', async () => {
    const { dsh, client } = await bridgeWith()
    try {
      client.send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
      client.send({ kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: {
        prompt: 'hi', workspace: '/tmp/another-repo', modelSelection: { provider: 'provider', model: 'model', reasoningEffort: 'low' },
      } } } } })
      await client.until(ended)
      assert.deepEqual(dsh.workspaces, ['/tmp/another-repo'])
      assert.deepEqual(dsh.sessionWorkspaces, ['ws-1'])
      assert.ok(client.frames.some(f => f.kind.case === 'event' && f.kind.value.body.case === 'modelSelected'))
      client.send({ kind: { case: 'request', value: { id: 3n, body: { case: 'listWorkspaces', value: {} } } } })
      await client.until(fs => fs.some(f => f.kind.case === 'response' && f.kind.value.requestId === 3n))
      const reply = client.frames.at(-1)!.kind
      assert.ok(reply.case === 'response' && reply.value.body.case === 'workspaceList')
      assert.equal(reply.value.body.value.defaultPath, '/tmp/dshm-ws')
      assert.deepEqual(reply.value.body.value.recentPaths, ['/tmp/another-repo'])
    } finally { client.close() }
  })

  test('defaultWorkspaceIsDshDefaultUnlessConfigured', async () => {
    // Real-iPhone finding (2026-11-07): the phone said 默认工作区 but used the home directory, so its
    // session was not in the Workspace that DSH Web labels 默认工作区.
    const dsh = new FakeDSH()
    const tasks = new DshTasks(dsh, undefined, '/home/user')
    assert.equal(tasks.cwd, '/home/user')
    await dsh.workspaceController.create({ path: '/home/user/Documents/deepseek-harness/default-workspace' })
    await dsh.workspaceController.create({ path: '/tmp/another-repo' })
    assert.equal(tasks.cwd, '/home/user/Documents/deepseek-harness/default-workspace')
    assert.deepEqual(tasks.listWorkspaces(), {
      defaultPath: '/home/user/Documents/deepseek-harness/default-workspace', recentPaths: ['/tmp/another-repo'],
    })
    const started = await tasks.start('hi', new AbortController().signal)
    assert.equal(started.workspace, '/home/user/Documents/deepseek-harness/default-workspace')
    for await (const _ of started.output) { /* drain */ }
    assert.equal(new DshTasks(dsh, '/srv/configured', '/home/user').cwd, '/srv/configured')
  })

  test('plaintextCannotReadOrChangeDeviceManagement', async () => {
    const { client } = await bridgeWith()
    client.send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
    client.send({ kind: { case: 'request', value: { id: 2n, body: { case: 'listDevices', value: {} } } } })
    client.send({ kind: { case: 'request', value: { id: 3n, body: { case: 'revokeDevice', value: { deviceId: 'victim' } } } } })
    client.send({ kind: { case: 'request', value: { id: 4n, body: { case: 'listAudit', value: {} } } } })
    await client.until(fs => fs.length === 4)
    assert.ok(client.frames.slice(1).every(f => f.kind.case === 'response'
      && f.kind.value.body.case === 'error' && f.kind.value.body.value.code === 'devices/forbidden'))
    client.close()
  })

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
    assert.deepEqual(hello.kind.case === 'response' && hello.kind.value.body.case === 'hello' && hello.kind.value.body.value.capabilities, ['tasks.v1', 'milestones.v1', 'resume.v1', 'interrupt.v1', 'transcript.v1', 'models.v1', 'workspaces.v1', 'drawer.v1', 'conversation.v1', 'conversation.v2', 'attachments.v1'])

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

  test('interruptCallsDSHAndReportsInterrupted', async () => {
    const { dsh, client } = await bridgeWith({ reply: ['first', 'second'], chunkDelayMs: 250 })
    try {
      client.send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
      client.send({ kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: { prompt: 'work' } } } } })
      await client.until((fs) => fs.some((f) => f.kind.case === 'event' && f.kind.value.body.case === 'assistantChunk'))
      const interrupt = (id: bigint, taskId: string) => client.send({ kind: { case: 'request', value: {
        id, body: { case: 'interrupt', value: { taskId } },
      } } })
      interrupt(3n, 'session-1')
      await client.until(ended)
      const events = client.frames.flatMap(f => f.kind.case === 'event' ? [f.kind.value.body] : [])
      assert.equal(events.filter(e => e.case === 'assistantChunk').length, 1)
      assert.ok(events.some(e => e.case === 'milestoneAdded' && e.value.kind === MilestoneKind.INTERRUPTED))
      assert.ok(events.some(e => e.case === 'taskUpserted' && e.value.task?.state === TaskState.INTERRUPTED))
      assert.ok(events.some(e => e.case === 'taskEnded' && e.value.status === TaskStatus.INTERRUPTED))

      interrupt(4n, 'session-1')
      interrupt(5n, 'other')
      await client.until(fs => fs.some(f => f.kind.case === 'response' && f.kind.value.requestId === 5n))
      for (const id of [3n, 4n]) assert.ok(client.frames.some(f => f.kind.case === 'response'
        && f.kind.value.requestId === id && f.kind.value.body.case === 'interruptAccepted'))
      assert.deepEqual(dsh.interrupts, ['session-1'])
      assert.ok(client.frames.some(f => f.kind.case === 'response' && f.kind.value.requestId === 5n
        && f.kind.value.body.case === 'error'))
    } finally {
      client.close()
    }
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
        startBridgeServer({ dshVersion: SUPPORTED_DSH, host, port: 0, channel, tasks: new DshTasks(new FakeDSH(), '/tmp') }),
        /refuses non-loopback/, host)
    }
    for (const host of ['127.0.0.1', '127.1.2.3', '::1', '[::1]']) assert.ok(isLoopbackAddress(host), host)
  })
})
