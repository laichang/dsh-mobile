import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { after, describe, test } from 'node:test'
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocket } from 'ws'
import { PlaintextChannel } from '../src/channel.ts'
import { SUPPORTED_DSH } from '../src/compatibility.ts'
import { DshTasks } from '../src/dsh.ts'
import { FrameSchema, type Frame } from '../src/gen/frame_pb.ts'
import { TranscriptBlockState, type TranscriptBlock } from '../src/gen/transcript_pb.ts'
import { PLAINTEXT_PATH, startBridgeServer, type BridgeServer } from '../src/server.ts'
import { countChanges, toolTarget, TranscriptMapper } from '../src/transcript/mapper.ts'
import { TRANSCRIPT_CAPABILITY } from '../src/transcript/wire.ts'
import { FAKE_DSH_EPOCH_MS, FakeDSH, type FakeDSHOptions } from './fake-dsh.ts'
import { FIXTURES_DIR } from './fixtures.ts'

const servers: BridgeServer[] = []
after(async () => { await Promise.all(servers.map((s) => s.close())) })

/** Runs one task through the real bridge server against FakeDSH; returns every frame received. */
async function runTask(options: FakeDSHOptions, capabilities: string[] = [TRANSCRIPT_CAPABILITY]): Promise<Frame[]> {
  const server = await startBridgeServer({
    dshVersion: SUPPORTED_DSH,
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
  send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1, capabilities } } } } })
  send({ kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: { prompt: 'fix the test' } } } } })
  await done
  ws.close()
  return frames
}

const events = (frames: Frame[]) =>
  frames.flatMap((f) => f.kind.case === 'event' ? [f.kind.value.body] : [])

/** Compact view of the transcript: chunks as their text, blocks as kind|id|state|details. */
const brief = (frames: Frame[]) => events(frames).flatMap((body) => {
  if (body.case === 'assistantChunk') return [`text:${body.value.text}`]
  if (body.case !== 'transcriptBlock') return []
  const b: TranscriptBlock = body.value
  const state = TranscriptBlockState[b.state]
  if (b.kind.case === 'thinking') return [`thinking|${state}|${b.kind.value.durationMs}ms`]
  if (b.kind.case === 'tool') {
    const t = b.kind.value
    return [`tool|${b.blockId}|${state}|${t.tool}|${t.target}|+${t.linesAdded}-${t.linesRemoved}${t.error ? `|${t.error}` : ''}`]
  }
  return ['?']
})

const context = ['import Foundation', '', 'final class TaskListStore {']
const tail = ['}', '', '// end']
const editMeta = {
  diffs: [{
    path: 'TaskListStore.swift',
    oldText: [...context, 'a', 'b', 'c', ...tail].join('\n') + '\n',
    newText: [...context, ...Array.from({ length: 12 }, (_, i) => `line ${i + 1}`), ...tail].join('\n') + '\n',
  }],
}

const codingTask: FakeDSHOptions = {
  reasoning: ['先看', '测试为什么', '失败。', '…', '…', '…', '…', '然后改。'],
  reply: ['Fixed', ' it.'],
  tools: [
    { callId: 'call_read', name: 'read', arguments: JSON.stringify({ file_path: 'Sources/TaskListStore.swift' }) },
    { callId: 'call_edit', name: 'edit', arguments: JSON.stringify({ file_path: 'Sources/TaskListStore.swift', old_string: 'a', new_string: 'b' }), meta: editMeta },
    { callId: 'call_bash', name: 'bash', arguments: JSON.stringify({ command: 'swift test\n--parallel' }), isError: true, reason: 'exit code 1' },
  ],
}

describe('TranscriptMapperAgainstFakeDSH', () => {
  test('mapsThinkingAndToolEventsIntoBlocks', async () => {
    const frames = await runTask(codingTask)
    assert.deepEqual(brief(frames), [
      'thinking|RUNNING|0ms',
      // Eight reasoning chunks one second apart, then the end of the reasoning block: 8 s.
      'thinking|DONE|8000ms',
      'text:Fixed',
      'text: it.',
      'tool|call_read|RUNNING|read|Sources/TaskListStore.swift|+0-0',
      'tool|call_read|DONE|read|Sources/TaskListStore.swift|+0-0',
      'tool|call_edit|RUNNING|edit|Sources/TaskListStore.swift|+0-0',
      'tool|call_edit|DONE|edit|Sources/TaskListStore.swift|+12-3',
      'tool|call_bash|RUNNING|bash|swift test|+0-0',
      'tool|call_bash|FAILED|bash|swift test|+0-0|exit code 1',
    ])
    const blocks = events(frames).flatMap((b) => b.case === 'transcriptBlock' ? [b.value] : [])
    const thinking = blocks.find((b) => b.kind.case === 'thinking' && b.state === TranscriptBlockState.DONE)!
    assert.equal(thinking.timeMs, BigInt(FAKE_DSH_EPOCH_MS))
    assert.equal(thinking.kind.case === 'thinking' && thinking.kind.value.text, codingTask.reasoning!.join(''))
    // Every block has the task's id; a thinking block keeps one id from RUNNING to DONE.
    assert.ok(blocks.every((b) => b.taskId === 'session-1'))
    assert.equal(new Set(blocks.filter((b) => b.kind.case === 'thinking').map((b) => b.blockId)).size, 1)
  })

  test('noModelSummaryOnlyDshData', async () => {
    // The blocks carry nothing but DSH's tool names, arguments, diffs and timestamps.
    const frames = await runTask(codingTask)
    const tools = events(frames).flatMap((b) => b.case === 'transcriptBlock' && b.value.kind.case === 'tool' ? [b.value.kind.value] : [])
    assert.deepEqual([...new Set(tools.map((t) => t.tool))], ['read', 'edit', 'bash'])
    assert.equal(tools.find((t) => t.tool === 'edit')!.arguments, codingTask.tools![1].arguments)
  })

  test('withoutTranscriptCapabilityTheClientGetsNoBlocks', async () => {
    const frames = await runTask(codingTask, [])
    assert.deepEqual(brief(frames), ['text:Fixed', 'text: it.'])
    const hello = frames.find((f) => f.kind.case === 'response' && f.kind.value.body.case === 'hello')!
    assert.ok(hello.kind.case === 'response' && hello.kind.value.body.case === 'hello'
      && hello.kind.value.body.value.capabilities.includes(TRANSCRIPT_CAPABILITY), 'the bridge still advertises transcript.v1')
  })

  test('aTaskWithoutThinkingOrToolsHasNoBlocks', async () => {
    const frames = await runTask({ reply: ['Hi.'] })
    assert.deepEqual(brief(frames), ['text:Hi.'])
  })
})

describe('TranscriptMapper', () => {
  test('countsLinesAddedAndRemovedInHunks', () => {
    assert.deepEqual(countChanges(editMeta.diffs[0].oldText, editMeta.diffs[0].newText), { added: 12, removed: 3 })
    assert.deepEqual(countChanges(null, 'a\nb\n'), { added: 2, removed: 0 })
    assert.deepEqual(countChanges('a\nb\n', 'a\nb\n'), { added: 0, removed: 0 })
  })

  test('targetComesFromTheArguments', () => {
    assert.equal(toolTarget('{"file_path":"/a/b.swift"}'), '/a/b.swift')
    assert.equal(toolTarget('{"command":"ls -la\\npwd"}'), 'ls -la')
    assert.equal(toolTarget('{"pattern":"TODO","path":"src"}'), 'src')
    assert.equal(toolTarget('{"input":"*** Begin Patch\\n*** Update File: a/b.ts\\n@@"}'), 'a/b.ts')
    assert.equal(toolTarget('not json'), '')
    assert.equal(toolTarget('{"x":1}'), '')
  })

  test('thinkingEndsAtTheFirstTextChunkWithoutABlockEnd', () => {
    const m = new TranscriptMapper()
    m.stream({ type: 'start', attemptId: 'a1' })
    const started = m.stream({ type: 'chunk', attemptId: 'a1', time: 1000, chunk: { type: 'reasoning-delta', index: 0, text: 'hm' } })
    assert.equal(started[0].state, 'running')
    m.stream({ type: 'chunk', attemptId: 'a1', time: 2500, chunk: { type: 'reasoning-delta', index: 0, text: '…' } })
    const ended = m.stream({ type: 'chunk', attemptId: 'a1', time: 4000, chunk: { type: 'text-delta', index: 1, text: 'Hi' } })
    assert.deepEqual(ended.map((b) => [b.blockId, b.state, b.thinking?.durationMs]), [['thinking-a1-0', 'done', 3000]])
    assert.deepEqual(m.stream({ type: 'end' }), [])
  })

  test('ignoresMalformedEvents', () => {
    const m = new TranscriptMapper()
    assert.deepEqual(m.event({ type: 'tool/call', data: null }), [])
    assert.deepEqual(m.event({ type: 'tool/result', data: { message: { toolCallId: 'unknown' } } }), [])
    assert.deepEqual(m.stream({ type: 'chunk', chunk: { type: 'reasoning-delta', text: '   ' } }), [])
    assert.deepEqual(m.stream(null), [])
  })
})

describe('S17TranscriptFixtures', () => {
  const decode = (name: string) => {
    const frame = fromBinary(FrameSchema, new Uint8Array(readFileSync(`${FIXTURES_DIR}/${name}.binpb`)))
    assert.ok(frame.kind.case === 'event' && frame.kind.value.body.case === 'transcriptBlock')
    return frame.kind.value.body.value
  }

  test('thinkingAndToolBlocksDecode', () => {
    const thinking = decode('s17_thinking_block_event')
    assert.equal(thinking.state, TranscriptBlockState.DONE)
    assert.ok(thinking.kind.case === 'thinking')
    assert.equal(thinking.kind.value.durationMs, 8000n)
    assert.equal(thinking.kind.value.text, '先看测试为什么失败。')

    const tool = decode('s17_tool_block_event')
    assert.ok(tool.kind.case === 'tool')
    assert.deepEqual([tool.kind.value.tool, tool.kind.value.target, tool.kind.value.linesAdded, tool.kind.value.linesRemoved],
      ['edit', 'ios/DSHKit/Sources/DSHCore/Sync/TaskListStore.swift', 12, 3])

    const failed = decode('s17_failed_tool_block_event')
    assert.equal(failed.state, TranscriptBlockState.FAILED)
    assert.ok(failed.kind.case === 'tool')
    assert.deepEqual([failed.kind.value.error, failed.kind.value.argumentsTruncated], ['exit code 1', true])
  })
})
