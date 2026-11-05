/**
 * The bridge's own WebSocket listener (ARCHITECTURE §5.1). One binary WebSocket message carries
 * one `Frame` through the connection's channel. T0 serves Hello and CreateTask; S2 adds ListTasks
 * and Resume, and tasks now belong to the host's `TaskHub`, not to the connection (D20).
 *
 * Channels (S1, ARCHITECTURE D6/D21):
 * - Noise on every path except `PLAINTEXT_PATH`: the first message is the handshake
 *   (src/pairing/wire.ts), then each message is one Noise transport message.
 * - Plaintext on `PLAINTEXT_PATH`, only when a PlaintextChannel is configured, which in turn
 *   only listens on loopback (development and T0's demo).
 */
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocketServer, type WebSocket } from 'ws'
import type { ApprovalHolder } from './approvals/holder.ts'
import { ApprovalDecision } from './gen/approvals_pb.ts'
import { deviceId } from './pairing/store.ts'
import { CloseCode } from './pairing/wire.ts'
import { auditPage, deviceList } from './devices/manage.ts'
import { hostname } from 'node:os'
import type { SecureChannel } from './channel.ts'
import { FrameSchema, type Frame, type Request, type ResponseSchema } from './gen/frame_pb.ts'
import { MILESTONES_CAPABILITY } from './milestones/wire.ts'
import { HandshakeRejected, type NoiseResponder } from './pairing/handshake.ts'
import type { LoggedEvent } from './s2/host-log.ts'
import { TaskHub, type TaskStarter } from './s2/task-hub.ts'

export type { TaskStarter } from './s2/task-hub.ts'

type ResponseBody = MessageInitShape<typeof ResponseSchema>['body']

export const PROTOCOL_VERSION = 1
/** `resume.v1`: ListTasks, Resume and `Event.host_seq` (S2). `milestones.v1`: MilestoneAdded (S3). */
export const CAPABILITIES = ['tasks.v1', MILESTONES_CAPABILITY, 'resume.v1', 'interrupt.v1'] as const
/** Where the dev-only plaintext channel is served. */
export const PLAINTEXT_PATH = '/plaintext'

export interface BridgeServerOptions {
  host: string
  /** 0 picks a free port (tests). */
  port: number
  /** Dev-only plaintext on PLAINTEXT_PATH; refuses non-loopback listen addresses. */
  channel?: SecureChannel
  /** Pairing + reconnect over Noise on every other path. */
  noise?: NoiseResponder
  tasks: TaskStarter
  /** The host's name in TaskList / Resumed (default: this machine's hostname). */
  hostName?: string
  /** Inject a hub (tests); by default the server makes one around `tasks`. */
  hub?: TaskHub
  approvals?: ApprovalHolder
  log?: (message: string) => void
}

export interface BridgeServer {
  readonly port: number
  readonly hub: TaskHub
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

  const hub = options.hub ?? new TaskHub(options.tasks)
  const host = { hub, hostName: options.hostName ?? hostname(), authenticated: new Map<WebSocket, string>() }
  wss.on('connection', (socket, req) => serveConnection(socket, req.url ?? '/', options, host, log))

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

/** Seals and opens the frames of one connection. */
interface FrameCodec {
  seal(plaintext: Uint8Array): Uint8Array
  open(ciphertext: Uint8Array): Uint8Array
}

function serveConnection(
  socket: WebSocket, url: string, options: BridgeServerOptions, host: { hub: TaskHub; hostName: string; authenticated: Map<WebSocket, string> },
  log: (m: string) => void,
) {
  const { hub, hostName } = host
  let device = 'dev loopback'
  let helloDone = false
  let clientApprovals = false
  let codec: FrameCodec | undefined

  const path = new URL(url, 'ws://bridge').pathname
  if (path === PLAINTEXT_PATH) {
    if (!options.channel) return socket.close(1008, 'plaintext disabled')
    codec = options.channel
  } else if (!options.noise) {
    return socket.close(1008, `plaintext only, on ${PLAINTEXT_PATH}`)
  }
  // Which logged events this connection receives. Before Resume (a T0-style client): only the
  // events of tasks it created here. After Resume: every event, in host_seq order.
  const ownTasks = new Set<string>()
  let resumed = false
  let unsubscribe: (() => void) | undefined

  const send = (frame: MessageInitShape<typeof FrameSchema>) => {
    if (socket.readyState !== socket.OPEN || !codec) return
    socket.send(codec.seal(toBinary(FrameSchema, create(FrameSchema, frame))))
  }
  const respond = (requestId: bigint, body: ResponseBody) =>
    send({ kind: { case: 'response', value: { requestId, body } } })
  const fail = (requestId: bigint, code: string, message: string) =>
    respond(requestId, { case: 'error', value: { code, message } })
  const forward = (event: LoggedEvent) => {
    // Older apps cannot withdraw temporary upstream approval rows.
    if (!clientApprovals && (event.body?.case === 'approvalPending' || event.body?.case === 'approvalResolved'
      || (event.body?.case === 'taskUpserted' && event.body.value.task?.approvalOnly))) return
    send({ kind: { case: 'event', value: { hostSeq: event.seq, body: event.body } } })
  }
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
        clientApprovals = request.body.value.capabilities.includes('approvals.v1')
        return respond(id, {
          case: 'hello',
          value: { protocolVersion: PROTOCOL_VERSION, capabilities: [
            ...CAPABILITIES,
            ...(options.tasks.modelCatalog && options.tasks.selectModel ? ['models.v1'] : []),
            ...(options.approvals ? ['approvals.v1'] : []),
            ...(host.authenticated.has(socket) ? ['devices.v1'] : []),
          ] },
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
          if (request.body.value.modelSelection && !options.tasks.selectModel) {
            return fail(id, 'model/unavailable', 'This host cannot select the requested model.')
          }
          await hub.create(prompt, (taskId) => {
            ownTasks.add(taskId)
            respond(id, { case: 'taskCreated', value: { taskId } })
          }, request.body.value.modelSelection)
        } catch (error) {
          log(`create task failed: ${String(error)}`)
          return fail(id, 'task/create-failed', error instanceof Error ? error.message : String(error))
        }
        return
      }
      case 'interrupt': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        try {
          const taskId = request.body.value.taskId
          hub.interrupt(taskId)
          options.approvals?.cancelTask(taskId, device)
          return respond(id, { case: 'interruptAccepted', value: {} })
        } catch (error) {
          return fail(id, 'task/interrupt-failed', error instanceof Error ? error.message : String(error))
        }
      }
      case 'getModelCatalog':
      case 'selectModel': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        if (!options.tasks.modelCatalog || !options.tasks.selectModel) {
          return fail(id, 'request/unsupported', 'This host cannot select a model.')
        }
        if (request.body.case === 'getModelCatalog') {
          try {
            return respond(id, { case: 'modelCatalog', value: await options.tasks.modelCatalog() })
          } catch (error) {
            return fail(id, 'model/catalog-failed', error instanceof Error ? error.message : String(error))
          }
        }
        const { taskId, selection } = request.body.value
        if (!selection || !hub.isActive(taskId)) {
          return fail(id, 'model/invalid-task', 'Select a model for a running task on this host.')
        }
        try {
          const accepted = await options.tasks.selectModel(taskId, selection)
          return respond(id, { case: 'modelSelected', value: { taskId, selection: accepted } })
        } catch (error) {
          return fail(id, 'model/unavailable', error instanceof Error ? error.message : String(error))
        }
      }
      case 'listDevices':
      case 'listAudit':
      case 'revokeDevice': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        const actor = host.authenticated.get(socket)
        const store = options.noise?.store
        if (!actor || !store) return fail(id, 'devices/forbidden', 'Pair this device to manage the host.')
        try {
          if (request.body.case === 'listAudit') {
            return respond(id, { case: 'auditPage', value: auditPage(store, request.body.value.beforeId) })
          }
          if (request.body.case === 'listDevices') return respond(id, { case: 'deviceList', value: deviceList(store, actor) })
          const target = request.body.value.deviceId
          store.revoke(target, actor)
          try {
            respond(id, { case: 'deviceList', value: deviceList(store, actor) })
          } finally {
            for (const [client, fingerprint] of host.authenticated) {
              if (fingerprint === target) client.close(CloseCode.DeviceUnknown, 'device revoked')
            }
          }
        } catch (error) {
          return fail(id, 'devices/failed', error instanceof Error ? error.message : String(error))
        }
        return
      }
      case 'answerApproval': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        if (!options.approvals) return fail(id, 'request/unsupported', 'approvals unavailable')
        const answer = request.body.value
        if (answer.decision !== ApprovalDecision.DENY && answer.decision !== ApprovalDecision.ALLOW_ONCE) {
          return fail(id, 'approval/invalid', 'choose allow once or deny')
        }
        try {
          const resolved = options.approvals.answer(answer.id, answer.decision === ApprovalDecision.ALLOW_ONCE, device)
          return respond(id, { case: 'approvalResolved', value: resolved })
        } catch (error) {
          return fail(id, 'approval/refused', error instanceof Error ? error.message : String(error))
        }
      }
      case 'listTasks': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        return respond(id, { case: 'taskList', value: { tasks: hub.list().filter(task => clientApprovals || !task.approvalOnly), logId: hub.log.logId, hostName } })
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
    if (socket.readyState !== socket.OPEN) return
    if (!isBinary) return socket.close(1003, 'binary frames only')
    const bytes = new Uint8Array(Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer))
    if (!codec) {
      // First message on a Noise connection: the handshake.
      try {
        const { reply, session } = options.noise!.accept(bytes)
        socket.send(reply)
        codec = session
        device = deviceId(session.remoteStatic)
        host.authenticated.set(socket, device)
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
  // The connection goes; the host's tasks keep running (STORY principle 4).
  socket.on('close', () => { host.authenticated.delete(socket); unsubscribe?.() })
}
