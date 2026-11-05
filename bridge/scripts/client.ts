/**
 * Command-line stand-in for the app: Hello, CreateTask, print the streamed reply.
 *   node lib/scripts/client.js [--port 47801] "prompt"
 * Milestones (S3) go to stderr as `client: milestone <seq> <KIND> [<todos as P/I/C>] <text>`.
 * Exit 0 when the task ends COMPLETED, 1 otherwise.
 */
import { create, fromBinary, toBinary } from '@bufbuild/protobuf'
import { WebSocket } from 'ws'
import { FrameSchema, TaskStatus } from '../src/gen/frame_pb.ts'
import { MilestoneKind, TodoStatus } from '../src/gen/milestones_pb.ts'

const args = process.argv.slice(2)
const portAt = args.indexOf('--port')
const port = portAt >= 0 ? Number(args.splice(portAt, 2)[1]) : 47801
const prompt = args.join(' ') || 'Say hello in one sentence.'

const ws = new WebSocket(`ws://127.0.0.1:${port}`)
ws.binaryType = 'nodebuffer'
const timer = setTimeout(() => { console.error('\nclient: timed out'); process.exit(1) }, 120_000)
ws.on('error', (e) => { console.error(`client: ${e.message}`); process.exit(1) })
ws.on('open', () => {
  const send = (init: Parameters<typeof create<typeof FrameSchema>>[1]) => ws.send(toBinary(FrameSchema, create(FrameSchema, init)))
  send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
  send({ kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: { prompt } } } } })
})
ws.on('message', (data: Buffer) => {
  const f = fromBinary(FrameSchema, new Uint8Array(data))
  if (f.kind.case === 'response') {
    const b = f.kind.value.body
    if (b.case === 'hello') console.error(`client: bridge protocol ${b.value.protocolVersion} [${b.value.capabilities.join(', ')}]`)
    if (b.case === 'taskCreated') console.error(`client: task ${b.value.taskId}`)
    if (b.case === 'error') { console.error(`client: error ${b.value.code}: ${b.value.message}`); process.exit(1) }
  } else if (f.kind.case === 'event') {
    const b = f.kind.value.body
    if (b.case === 'assistantChunk') process.stdout.write(b.value.text)
    if (b.case === 'milestoneAdded') {
      const m = b.value
      const todos = m.todos.map((t) => ({ [TodoStatus.PENDING]: 'P', [TodoStatus.IN_PROGRESS]: 'I', [TodoStatus.COMPLETED]: 'C' } as Record<number, string>)[t.status] ?? '?').join('')
      console.error(`client: milestone ${m.seq} ${MilestoneKind[m.kind]} [${todos}] ${m.text}`)
    }
    if (b.case === 'taskEnded') {
      clearTimeout(timer)
      const ok = b.value.status === TaskStatus.COMPLETED
      console.error(`\nclient: task ended ${TaskStatus[b.value.status]}${b.value.message ? `: ${b.value.message}` : ''}`)
      ws.close()
      process.exit(ok ? 0 : 1)
    }
  }
})
