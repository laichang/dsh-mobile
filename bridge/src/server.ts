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
import type { QuestionHolder } from './questions/holder.ts'
import { SUPPORTED_DSH, supportsDsh } from './compatibility.ts'
import { ApprovalDecision } from './gen/approvals_pb.ts'
import { deviceId } from './pairing/store.ts'
import { CloseCode } from './pairing/wire.ts'
import { auditPage, deviceList } from './devices/manage.ts'
import { hostname } from 'node:os'
import type { SecureChannel } from './channel.ts'
import { FrameSchema, type Frame, type Request, type ResponseSchema } from './gen/frame_pb.ts'
import type { SessionDirectory } from './sessions/directory.ts'
import { MILESTONES_CAPABILITY } from './milestones/wire.ts'
import { DRAWER_CAPABILITY } from './drawer/workspace.ts'
import { TRANSCRIPT_CAPABILITY } from './transcript/wire.ts'
import { MessageMode } from './gen/conversation_pb.ts'
import { HandshakeRejected, type NoiseResponder } from './pairing/handshake.ts'
import type { LoggedEvent } from './s2/host-log.ts'
import { TaskHub, type TaskStarter } from './s2/task-hub.ts'

export type { TaskStarter } from './s2/task-hub.ts'

type ResponseBody = MessageInitShape<typeof ResponseSchema>['body']

export const PROTOCOL_VERSION = 1
/** `resume.v1`: ListTasks, Resume and `Event.host_seq` (S2). `milestones.v1`: MilestoneAdded (S3). */
/** Agent questions (protocol/questions.proto, D92). */
export const QUESTIONS_CAPABILITY = 'questions.v1'
export const CAPABILITIES = ['tasks.v1', MILESTONES_CAPABILITY, 'resume.v1', 'interrupt.v1', TRANSCRIPT_CAPABILITY] as const
/** D89: SendMessage, MessageAccepted and UserMessage (protocol/conversation.proto). */
export const CONVERSATION_CAPABILITY = 'conversation.v1'
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
  dshVersion: string
  /** The host's name in TaskList / Resumed (default: this machine's hostname). */
  hostName?: string
  /** Inject a hub (tests); by default the server makes one around `tasks`. */
  hub?: TaskHub
  sessions?: SessionDirectory
  approvals?: ApprovalHolder
  /** Agent questions (`questions.v1`, D92). */
  questions?: QuestionHolder
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
  const supported = supportsDsh(options.dshVersion)
  let device = 'dev loopback'
  let helloDone = false
  let clientSessions = false
  let clientApprovals = false
  let clientTranscript = false
  let clientConversation = false
  let clientQuestions = false
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
    if (!clientSessions && event.body?.case === 'taskUpserted' && event.body.value.task?.externalSession) {
      const task = event.body.value.task
      if (!clientApprovals || !task.pendingApprovals?.length) return
      send({ kind: { case: 'event', value: { hostSeq: event.seq, body: { case: 'taskUpserted', value: {
        task: { ...task, title: '', approvalOnly: true },
      } } } } })
      return
    }
    // S17: only apps that read transcript blocks get them.
    if (!clientTranscript && event.body?.case === 'transcriptBlock') return
    // D89: only apps that send follow-ups read them back.
    if (!clientConversation && event.body?.case === 'userMessage') return
    // Apps without `questions.v1` cannot answer, so they get no card.
    if (!clientQuestions && (event.body?.case === 'questionPending' || event.body?.case === 'questionResolved')) return
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
    if (!supported && request.body.case !== 'hello') {
      return fail(id, 'host/bridge-update', 'The host needs a bridge update.')
    }
    switch (request.body.case) {
      case 'hello': {
        const v = request.body.value.protocolVersion
        if (v !== PROTOCOL_VERSION && v !== PROTOCOL_VERSION - 1) {
          return fail(id, 'hello/version-unsupported', `bridge speaks protocol ${PROTOCOL_VERSION}, got ${v}`)
        }
        helloDone = true
        clientSessions = !!options.sessions && request.body.value.capabilities.includes('sessions.v1')
        clientApprovals = request.body.value.capabilities.includes('approvals.v1')
        clientTranscript = request.body.value.capabilities.includes(TRANSCRIPT_CAPABILITY)
        clientConversation = request.body.value.capabilities.includes(CONVERSATION_CAPABILITY)
        clientQuestions = !!options.questions && request.body.value.capabilities.includes(QUESTIONS_CAPABILITY)
        return respond(id, {
          case: 'hello',
          value: { protocolVersion: PROTOCOL_VERSION, dshVersion: options.dshVersion,
            supportedDshRange: SUPPORTED_DSH, requiresBridgeUpdate: !supported, capabilities: supported ? [
            ...CAPABILITIES,
            ...(options.sessions ? ['sessions.v1'] : []),
            ...(options.tasks.modelCatalog && options.tasks.selectModel ? ['models.v1'] : []),
            ...(options.approvals ? ['approvals.v1'] : []),
            ...(options.questions ? [QUESTIONS_CAPABILITY] : []),
            ...(options.tasks.listWorkspaces ? ['workspaces.v1', DRAWER_CAPABILITY] : []),
            ...(host.authenticated.has(socket) ? ['devices.v1'] : []),
            ...(options.tasks.followUp ? [CONVERSATION_CAPABILITY] : []),
          ] : [] },
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
          if (request.body.value.workspace !== undefined && !options.tasks.listWorkspaces) {
            return fail(id, 'workspace/unavailable', 'This host cannot select a workspace.')
          }
          await hub.create(prompt, (taskId) => {
            ownTasks.add(taskId)
            respond(id, { case: 'taskCreated', value: { taskId } })
          }, request.body.value.modelSelection, request.body.value.workspace)
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
          options.questions?.cancelTask(taskId)
          return respond(id, { case: 'interruptAccepted', value: {} })
        } catch (error) {
          return fail(id, 'task/interrupt-failed', error instanceof Error ? error.message : String(error))
        }
      }
      case 'sendMessage': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        if (!options.tasks.followUp) return fail(id, 'request/unsupported', 'This host cannot take follow-up messages.')
        const { taskId, text, mode } = request.body.value
        if (!text.trim()) return fail(id, 'message/empty', 'the message is empty')
        if (!resumed) { ownTasks.add(taskId); subscribeOwnTasks() }
        try {
          // Answer first, as for CreateTask: then the UserMessage and the turn's events follow.
          await hub.sendMessage(taskId, text, mode === MessageMode.QUEUE ? 'queue' : 'steer',
            (messageId) => respond(id, { case: 'messageAccepted', value: { taskId, messageId } }))
        } catch (error) {
          log(`follow-up failed: ${String(error)}`)
          return fail(id, 'message/refused', error instanceof Error ? error.message : String(error))
        }
        return
      }
      case 'listWorkspaces': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        if (!options.tasks.listWorkspaces) return fail(id, 'request/unsupported', 'This host cannot list workspaces.')
        try {
          return respond(id, { case: 'workspaceList', value: options.tasks.listWorkspaces() })
        } catch (error) {
          return fail(id, 'workspace/list-failed', error instanceof Error ? error.message : String(error))
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
      case 'answerQuestion': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        if (!options.questions) return fail(id, 'request/unsupported', 'questions unavailable')
        const answer = request.body.value
        try {
          const resolved = options.questions.answer(answer.id, answer.answers.map(a => ({ questionId: a.questionId, selected: [...a.selected] })))
          log(`question ${answer.id} answered by ${device}`)
          return respond(id, { case: 'questionResolved', value: resolved })
        } catch (error) {
          return fail(id, 'question/refused', error instanceof Error ? error.message : String(error))
        }
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
      case 'readSession': {
        if (!helloDone || !clientSessions || !options.sessions) return fail(id, 'request/unsupported', 'Session history unavailable.')
        const req = request.body.value
        try {
          return respond(id, { case: 'sessionPage', value: await options.sessions.read(req.taskId, req.beforeSeq, req.throughSeq) })
        } catch (error) { return fail(id, 'session/read-failed', String(error)) }
      }
      case 'listTasks': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        return respond(id, { case: 'taskList', value: { tasks: hub.list().filter(task => clientApprovals || !task.approvalOnly)
          .flatMap(task => !clientSessions && task.externalSession ? (clientApprovals && task.pendingApprovals.length
            ? [{ ...task, title: '', approvalOnly: true }] : []) : [task]), logId: hub.log.logId, hostName } })
      }
      case 'resume': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        if (clientSessions) {
          try { await options.sessions!.reconcile() }
          catch (error) { return fail(id, 'session/list-failed', String(error)) }
        }
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
