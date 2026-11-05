/**
 * The bridge's own WebSocket listener (ARCHITECTURE §5.1). One binary WebSocket message carries
 * one `Frame` through the SecureChannel. T0 serves Hello and CreateTask; S2 adds ListTasks and
 * Resume, and tasks now belong to the host's `TaskHub`, not to the connection (D20).
 */
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocketServer, type WebSocket } from 'ws'
import { hostname } from 'node:os'
import type { SecureChannel } from './channel.ts'
import { FrameSchema, type Frame, type Request, type ResponseSchema } from './gen/frame_pb.ts'
import { MILESTONES_CAPABILITY } from './milestones/wire.ts'
import type { LoggedEvent } from './s2/host-log.ts'
import { TaskHub, type TaskStarter } from './s2/task-hub.ts'

export type { TaskStarter } from './s2/task-hub.ts'

type ResponseBody = MessageInitShape<typeof ResponseSchema>['body']

export const PROTOCOL_VERSION = 1
/** `resume.v1`: ListTasks, Resume and `Event.host_seq` (S2). `milestones.v1`: MilestoneAdded (S3). */
export const CAPABILITIES = ['tasks.v1', MILESTONES_CAPABILITY, 'resume.v1'] as const

export interface BridgeServerOptions {
  host: string
  /** 0 picks a free port (tests). */
  port: number
  channel: SecureChannel
  tasks: TaskStarter
  /** The host's name in TaskList / Resumed (default: this machine's hostname). */
  hostName?: string
  /** Inject a hub (tests); by default the server makes one around `tasks`. */
  hub?: TaskHub
  log?: (message: string) => void
}

export interface BridgeServer {
  readonly port: number
  readonly hub: TaskHub
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

  const hub = options.hub ?? new TaskHub(options.tasks)
  const host = { hub, hostName: options.hostName ?? hostname() }
  wss.on('connection', (socket) => serveConnection(socket, options.channel, host, log))

  return {
    port,
    hub,
    close: async () => {
      await new Promise<void>((resolve) => {
        for (const client of wss.clients) client.terminate()
        wss.close(() => resolve())
      })
      await hub.close()
    },
  }
}

function serveConnection(
  socket: WebSocket, channel: SecureChannel, host: { hub: TaskHub; hostName: string }, log: (m: string) => void,
) {
  const { hub, hostName } = host
  let helloDone = false
  // Which logged events this connection receives. Before Resume (a T0-style client): only the
  // events of tasks it created here. After Resume: every event, in host_seq order.
  const ownTasks = new Set<string>()
  let resumed = false
  let unsubscribe: (() => void) | undefined

  const send = (frame: MessageInitShape<typeof FrameSchema>) => {
    if (socket.readyState !== socket.OPEN) return
    socket.send(channel.seal(toBinary(FrameSchema, create(FrameSchema, frame))))
  }
  const respond = (requestId: bigint, body: ResponseBody) =>
    send({ kind: { case: 'response', value: { requestId, body } } })
  const fail = (requestId: bigint, code: string, message: string) =>
    respond(requestId, { case: 'error', value: { code, message } })
  const forward = (event: LoggedEvent) =>
    send({ kind: { case: 'event', value: { hostSeq: event.seq, body: event.body } } })
  const subscribeOwnTasks = () => {
    unsubscribe ??= hub.log.subscribe((event) => { if (ownTasks.has(event.taskId)) forward(event) })
  }

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
        if (!resumed) subscribeOwnTasks()
        try {
          // The task id is known before any of its events are logged: answer first, then the
          // subscription forwards its events (T0 clients rely on TaskCreated preceding them).
          await hub.create(prompt, (taskId) => {
            ownTasks.add(taskId)
            respond(id, { case: 'taskCreated', value: { taskId } })
          })
        } catch (error) {
          log(`create task failed: ${String(error)}`)
          return fail(id, 'task/create-failed', error instanceof Error ? error.message : String(error))
        }
        return
      }
      case 'listTasks': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        return respond(id, { case: 'taskList', value: { tasks: hub.list(), logId: hub.log.logId, hostName } })
      }
      case 'resume': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        // Replay and subscribe in one synchronous step, so no event falls between them.
        const { logId, afterSeq } = request.body.value
        unsubscribe?.()
        const replay = hub.log.since(logId, afterSeq)
        if (replay.reset) send({ kind: { case: 'event', value: { body: { case: 'logReset', value: { logId: hub.log.logId } } } } })
        for (const event of replay.events) forward(event)
        respond(id, {
          case: 'resumed',
          value: {
            logId: hub.log.logId, headSeq: hub.log.head, hostName,
            reset: replay.reset, replayed: BigInt(replay.events.length),
          },
        })
        resumed = true
        unsubscribe = hub.log.subscribe(forward)
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
      frame = fromBinary(FrameSchema, channel.open(new Uint8Array(bytes)))
    } catch {
      return socket.close(1007, 'undecodable frame')
    }
    if (frame.kind.case !== 'request') return
    handle(frame.kind.value).catch((error) => log(`request failed: ${String(error)}`))
  })
  // The connection goes; the host's tasks keep running (STORY principle 4).
  socket.on('close', () => unsubscribe?.())
}
