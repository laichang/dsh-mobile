/**
 * The bridge's own WebSocket listener (ARCHITECTURE §5.1). One binary WebSocket message carries
 * one `Frame` through the connection's channel. T0 serves Hello and CreateTask.
 *
 * Channels (S1, ARCHITECTURE D6/D18):
 * - Noise on every path except `PLAINTEXT_PATH`: the first message is the handshake
 *   (src/pairing/wire.ts), then each message is one Noise transport message.
 * - Plaintext on `PLAINTEXT_PATH`, only when a PlaintextChannel is configured, which in turn
 *   only listens on loopback (development and T0's demo).
 */
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocketServer, type WebSocket } from 'ws'
import type { SecureChannel } from './channel.ts'
import type { StartedTask } from './dsh.ts'
import { HandshakeRejected, type NoiseResponder } from './pairing/handshake.ts'
import {
  FrameSchema, TaskStatus,
  type EventSchema, type Frame, type Request, type ResponseSchema,
} from './gen/frame_pb.ts'

type ResponseBody = MessageInitShape<typeof ResponseSchema>['body']
type EventBody = MessageInitShape<typeof EventSchema>['body']

export const PROTOCOL_VERSION = 1
export const CAPABILITIES = ['tasks.v1'] as const
/** Where the dev-only plaintext channel is served. */
export const PLAINTEXT_PATH = '/plaintext'

export interface TaskStarter {
  start(prompt: string, signal: AbortSignal): Promise<StartedTask>
}

export interface BridgeServerOptions {
  host: string
  /** 0 picks a free port (tests). */
  port: number
  /** Dev-only plaintext on PLAINTEXT_PATH; refuses non-loopback listen addresses. */
  channel?: SecureChannel
  /** Pairing + reconnect over Noise on every other path. */
  noise?: NoiseResponder
  tasks: TaskStarter
  log?: (message: string) => void
}

export interface BridgeServer {
  readonly port: number
  close(): Promise<void>
}

export async function startBridgeServer(options: BridgeServerOptions): Promise<BridgeServer> {
  if (!options.channel && !options.noise) throw new Error('the bridge needs a channel: noise, plaintext, or both')
  options.channel?.assertListenAddress(options.host)
  const log = options.log ?? (() => {})
  const wss = new WebSocketServer({ host: options.host, port: options.port })
  await new Promise<void>((resolve, reject) => {
    wss.once('listening', resolve)
    wss.once('error', reject)
  })
  const address = wss.address()
  const port = typeof address === 'object' && address ? address.port : options.port
  const channels = [options.noise && 'noise', options.channel && `${options.channel.name} on ${PLAINTEXT_PATH}`]
  log(`listening on ${options.host}:${port} (${channels.filter(Boolean).join(', ')})`)

  wss.on('connection', (socket, req) => serveConnection(socket, req.url ?? '/', options, log))

  return {
    port,
    close: () => new Promise<void>((resolve) => {
      for (const client of wss.clients) client.terminate()
      wss.close(() => resolve())
    }),
  }
}

/** Seals and opens the frames of one connection. */
interface FrameCodec {
  seal(plaintext: Uint8Array): Uint8Array
  open(ciphertext: Uint8Array): Uint8Array
}

function serveConnection(socket: WebSocket, url: string, options: BridgeServerOptions, log: (m: string) => void) {
  const abort = new AbortController()
  let helloDone = false
  let codec: FrameCodec | undefined

  const path = new URL(url, 'ws://bridge').pathname
  if (path === PLAINTEXT_PATH) {
    if (!options.channel) return socket.close(1008, 'plaintext disabled')
    codec = options.channel
  } else if (!options.noise) {
    return socket.close(1008, `plaintext only, on ${PLAINTEXT_PATH}`)
  }

  const send = (frame: MessageInitShape<typeof FrameSchema>) => {
    if (socket.readyState !== socket.OPEN || !codec) return
    socket.send(codec.seal(toBinary(FrameSchema, create(FrameSchema, frame))))
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
    const bytes = new Uint8Array(Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer))
    if (!codec) {
      // First message on a Noise connection: the handshake.
      try {
        const { reply, session } = options.noise!.accept(bytes)
        socket.send(reply)
        codec = session
      } catch (error) {
        if (error instanceof HandshakeRejected) {
          log(`refused a connection: ${error.reason}`)
          return socket.close(error.code, error.reason)
        }
        log(`handshake error: ${String(error)}`)
        return socket.close(1011, 'handshake error')
      }
      return
    }
    let frame: Frame
    try {
      frame = fromBinary(FrameSchema, codec.open(bytes))
    } catch {
      return socket.close(1007, 'undecodable frame')
    }
    if (frame.kind.case !== 'request') return
    handle(frame.kind.value).catch((error) => log(`request failed: ${String(error)}`))
  })
  socket.on('close', () => abort.abort())
}
