/**
 * The bridge's own WebSocket listener (ARCHITECTURE §5.1). One binary WebSocket message carries
 * one `Frame` through the SecureChannel. T0 serves Hello and CreateTask.
 */
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocketServer, type WebSocket } from 'ws'
import type { SecureChannel } from './channel.ts'
import type { StartedTask } from './dsh.ts'
import {
  FrameSchema, TaskStatus,
  type EventSchema, type Frame, type Request, type ResponseSchema,
} from './gen/frame_pb.ts'

type ResponseBody = MessageInitShape<typeof ResponseSchema>['body']
type EventBody = MessageInitShape<typeof EventSchema>['body']

export const PROTOCOL_VERSION = 1
export const CAPABILITIES = ['tasks.v1'] as const

export interface TaskStarter {
  start(prompt: string, signal: AbortSignal): Promise<StartedTask>
}

export interface BridgeServerOptions {
  host: string
  /** 0 picks a free port (tests). */
  port: number
  channel: SecureChannel
  tasks: TaskStarter
  log?: (message: string) => void
}

export interface BridgeServer {
  readonly port: number
  close(): Promise<void>
}

export async function startBridgeServer(options: BridgeServerOptions): Promise<BridgeServer> {
  options.channel.assertListenAddress(options.host)
  const log = options.log ?? (() => {})
  const wss = new WebSocketServer({ host: options.host, port: options.port })
  await new Promise<void>((resolve, reject) => {
    wss.once('listening', resolve)
    wss.once('error', reject)
  })
  const address = wss.address()
  const port = typeof address === 'object' && address ? address.port : options.port
  log(`listening on ${options.host}:${port} (${options.channel.name})`)

  wss.on('connection', (socket) => serveConnection(socket, options, log))

  return {
    port,
    close: () => new Promise<void>((resolve) => {
      for (const client of wss.clients) client.terminate()
      wss.close(() => resolve())
    }),
  }
}

function serveConnection(socket: WebSocket, options: BridgeServerOptions, log: (m: string) => void) {
  const abort = new AbortController()
  let helloDone = false

  const send = (frame: MessageInitShape<typeof FrameSchema>) => {
    if (socket.readyState !== socket.OPEN) return
    socket.send(options.channel.seal(toBinary(FrameSchema, create(FrameSchema, frame))))
  }
  const respond = (requestId: bigint, body: ResponseBody) =>
    send({ kind: { case: 'response', value: { requestId, body } } })
  const fail = (requestId: bigint, code: string, message: string) =>
    respond(requestId, { case: 'error', value: { code, message } })
  const emit = (body: EventBody) =>
    send({ kind: { case: 'event', value: { body } } })

  const handle = async (request: Request) => {
    const id = request.id
    switch (request.body.case) {
      case 'hello': {
        const v = request.body.value.protocolVersion
        if (v !== PROTOCOL_VERSION && v !== PROTOCOL_VERSION - 1) {
          return fail(id, 'hello/version-unsupported', `bridge speaks protocol ${PROTOCOL_VERSION}, got ${v}`)
        }
        helloDone = true
        return respond(id, {
          case: 'hello',
          value: { protocolVersion: PROTOCOL_VERSION, capabilities: [...CAPABILITIES] },
        })
      }
      case 'createTask': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        const prompt = request.body.value.prompt
        if (!prompt.trim()) return fail(id, 'task/prompt-empty', 'the prompt is empty')
        let task: StartedTask
        try {
          task = await options.tasks.start(prompt, abort.signal)
        } catch (error) {
          log(`create task failed: ${String(error)}`)
          return fail(id, 'task/create-failed', error instanceof Error ? error.message : String(error))
        }
        respond(id, { case: 'taskCreated', value: { taskId: task.taskId } })
        let seq = 0n
        for await (const out of task.output) {
          if (out.kind === 'text') {
            emit({ case: 'assistantChunk', value: { taskId: task.taskId, seq: ++seq, text: out.text } })
          } else {
            emit({
              case: 'taskEnded',
              value: {
                taskId: task.taskId,
                status: out.status === 'completed' ? TaskStatus.COMPLETED : TaskStatus.FAILED,
                message: out.message ?? '',
              },
            })
          }
        }
        return
      }
      default:
        return fail(id, 'request/unsupported', `unsupported request ${String(request.body.case)}`)
    }
  }

  socket.on('message', (data, isBinary) => {
    if (!isBinary) return socket.close(1003, 'binary frames only')
    let frame: Frame
    try {
      const bytes = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer)
      frame = fromBinary(FrameSchema, options.channel.open(new Uint8Array(bytes)))
    } catch {
      return socket.close(1007, 'undecodable frame')
    }
    if (frame.kind.case !== 'request') return
    handle(frame.kind.value).catch((error) => log(`request failed: ${String(error)}`))
  })
  socket.on('close', () => abort.abort())
}
