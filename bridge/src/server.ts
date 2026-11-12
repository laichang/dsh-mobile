import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import type { WebSocket } from 'ws'
import type { ApprovalHolder } from './approvals/holder.ts'
import type { QuestionHolder } from './questions/holder.ts'
import { SUPPORTED_DSH, supportsDsh } from './compatibility.ts'
import { catalogFrame } from './models/wire.ts'
import { QuestionOutcome } from './gen/questions_pb.ts'
import { ApprovalDecision, ApprovalOutcome } from './gen/approvals_pb.ts'
import { TaskState } from './gen/durable_list_pb.ts'
import { auditPage, deviceList } from './devices/manage.ts'
import { listenTLS } from './tls/listener.ts'
import type { TLSRegistry } from './tls/registry.ts'
import { hostname } from 'node:os'
import { FrameSchema, type Frame, type Request, type ResponseSchema } from './gen/frame_pb.ts'
import type { SessionDirectory } from './sessions/directory.ts'
import { MILESTONES_CAPABILITY } from './milestones/wire.ts'
import { DRAWER_CAPABILITY } from './drawer/workspace.ts'
import { TRANSCRIPT_CAPABILITY } from './transcript/wire.ts'
import { MessageMode, QueueAction, QueuePlacement } from './gen/conversation_pb.ts'
import { HostLog, wireAttachment, wireSummary, type LoggedEvent } from './tasks/host-log.ts'
import { TaskHub, type TaskStarter } from './tasks/task-hub.ts'
import { ATTACHMENTS_CAPABILITY, UploadError, UploadStaging, type StagedFile } from './attachments/staging.ts'

export type { TaskStarter } from './tasks/task-hub.ts'

type ResponseBody = MessageInitShape<typeof ResponseSchema>['body']

export const PROTOCOL_VERSION = 1
/** `resume.v1`: ListTasks, Resume and `Event.host_seq`. `milestones.v1`: MilestoneAdded. */
/** Agent questions (protocol/questions.proto). */
export const QUESTIONS_CAPABILITY = 'questions.v1'
export const CAPABILITIES = ['tasks.v1', MILESTONES_CAPABILITY, 'resume.v1', 'interrupt.v1', TRANSCRIPT_CAPABILITY] as const
/** SendMessage, MessageAccepted and UserMessage (protocol/conversation.proto). */
export const CONVERSATION_CAPABILITY = 'conversation.v1'
/** Follow-ups while the task runs: QueuedMessage, EditQueue and QueueEdited. */
export const QUEUE_CAPABILITY = 'conversation.v2'
/** TaskEnded / TaskSummary carry `failure_code`, and a failed task takes a follow-up. */
export const FAILURES_CAPABILITY = 'failures.v1'
export interface BridgeServerOptions {
  host: string
  /** 0 picks a free port (tests). */
  port: number
  tlsStateDir: string
  tasks: TaskStarter
  dshVersion: string
  /** The host's name in TaskList / Resumed (default: this machine's hostname). */
  hostName?: string
  /** Inject a hub (tests); by default the server makes one around `tasks`. */
  hub?: TaskHub<HostLog>
  sessions?: SessionDirectory
  approvals?: ApprovalHolder
  /** Agent questions (`questions.v1`). */
  questions?: QuestionHolder
  log?: (message: string) => void
}

export interface BridgeServer {
  readonly port: number
  readonly hub: TaskHub<HostLog>
  close(): Promise<void>
}

export async function startBridgeServer(options: BridgeServerOptions): Promise<BridgeServer> {
  const hub = options.hub ?? new TaskHub(options.tasks, new HostLog())
  const host = { hub, hostName: options.hostName ?? hostname(), authenticated: new Map<WebSocket, string>() }
  const server = await listenTLS(options.host, options.port, options.tlsStateDir, (ws, device, registry) => {
    host.authenticated.set(ws, device)
    serveConnection(ws, device, options, host, options.log ?? (() => {}), registry)
  })
  return { port: server.port, hub, close: async () => { await server.close(); await hub.close() } }
}

/**
 * A task as an app without `questions.v1` sees it: it cannot answer, so a task that waits only
 * on a question stays RUNNING for it, as before the question.
 */
function withoutQuestions<T extends { state?: TaskState; pendingApprovals?: readonly unknown[]; pendingQuestions?: readonly unknown[] }>(task: T): T {
  if (!task.pendingQuestions?.length) return task
  const state = task.state === TaskState.WAITING_ON_USER && !task.pendingApprovals?.length ? TaskState.RUNNING : task.state
  return { ...task, state, pendingQuestions: [] }
}

function serveConnection(
  socket: WebSocket, device: string, options: BridgeServerOptions, host: { hub: TaskHub<HostLog>; hostName: string; authenticated: Map<WebSocket, string> },
  log: (m: string) => void, store: TLSRegistry,
) {
  const { hub, hostName } = host
  const supported = supportsDsh(options.dshVersion)
  // The host can queue follow-ups while a task runs, and edit the queue.
  const queues = !!(options.tasks.followUp && options.tasks.prompt && options.tasks.editQueue)
  let helloDone = false
  let clientSessions = false
  let clientApprovals = false
  let clientTranscript = false
  let clientConversation = false
  let clientQueue = false
  let clientQuestions = false
  const uploads = new UploadStaging() // This connection's attachments

  // Which logged events this connection receives. Before Resume (a client without the durable list): only the
  // events of tasks it created here. After Resume: every event, in host_seq order.
  const ownTasks = new Set<string>()
  let resumed = false
  let unsubscribe: (() => void) | undefined

  const send = (frame: MessageInitShape<typeof FrameSchema>) => {
    if (socket.readyState !== socket.OPEN || !store.has(device)) return
    socket.send(toBinary(FrameSchema, create(FrameSchema, frame)))
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
    // Only apps that read transcript blocks get them.
    if (!clientTranscript && event.body?.case === 'transcriptBlock') return
    // Only apps that send follow-ups read them back.
    if (!clientConversation && event.body?.case === 'userMessage') return
    // Only apps that show the queue get its changes.
    if (!clientQueue && event.body?.case === 'queuedMessage') return
    // Apps without `questions.v1` cannot answer, so they get no card.
    if (!clientQuestions && (event.body?.case === 'questionPending' || event.body?.case === 'questionResolved')) return
    if (!clientQuestions && event.body?.case === 'taskUpserted' && event.body.value.task?.pendingQuestions?.length) {
      const task = withoutQuestions(event.body.value.task)
      send({ kind: { case: 'event', value: { hostSeq: event.seq, body: { case: 'taskUpserted', value: { task } } } } })
      return
    }
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
        clientQueue = queues && request.body.value.capabilities.includes(QUEUE_CAPABILITY)
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
            ...(options.tasks.followUp ? [CONVERSATION_CAPABILITY, FAILURES_CAPABILITY] : []),
            ...(queues ? [QUEUE_CAPABILITY] : []),
            ...(options.tasks.attachments ? [ATTACHMENTS_CAPABILITY] : []),
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
          // subscription forwards its events (clients without Resume rely on TaskCreated preceding them).
          if (request.body.value.modelSelection && !options.tasks.selectModel) {
            return fail(id, 'model/unavailable', 'This host cannot select the requested model.')
          }
          if (request.body.value.workspace !== undefined && !options.tasks.listWorkspaces) {
            return fail(id, 'workspace/unavailable', 'This host cannot select a workspace.')
          }
          let files: StagedFile[] | undefined
          if (request.body.value.uploadIds.length) {
            if (!options.tasks.attachments) return fail(id, 'upload/unavailable', 'This host cannot take attachments.')
            files = uploads.take(request.body.value.uploadIds)
          }
          await hub.create(prompt, (taskId) => {
            ownTasks.add(taskId)
            respond(id, { case: 'taskCreated', value: { taskId } })
          }, request.body.value.modelSelection, request.body.value.workspace, files)
        } catch (error) {
          if (error instanceof UploadError) return fail(id, error.code, error.message)
          log(`create task failed: ${String(error)}`)
          return fail(id, 'task/create-failed', error instanceof Error ? error.message : String(error))
        }
        return
      }
      case 'uploadBegin':
      case 'uploadChunk':
      case 'uploadEnd': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        if (!options.tasks.attachments) return fail(id, 'upload/unavailable', 'This host cannot take attachments.')
        const body = request.body
        try {
          if (body.case === 'uploadEnd') {
            uploads.end(body.value.uploadId)
            return respond(id, { case: 'uploadStaged', value: { uploadId: body.value.uploadId } })
          }
          const received = body.case === 'uploadBegin' ? uploads.begin(body.value) : uploads.chunk(body.value)
          return respond(id, { case: 'uploadAck', value: { uploadId: body.value.uploadId, received: BigInt(received) } })
        } catch (error) {
          if (error instanceof UploadError) return fail(id, error.code, error.message)
          throw error
        }
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
        const { taskId, text, mode, uploadIds } = request.body.value
        if (!text.trim()) return fail(id, 'message/empty', 'the message is empty')
        if (uploadIds.length && !options.tasks.attachments) return fail(id, 'upload/unavailable', 'This host cannot take attachments.')
        if (!resumed) { ownTasks.add(taskId); subscribeOwnTasks() }
        let files: StagedFile[] = []
        try {
          // The files are used up by this message, also when DSH refuses it.
          files = uploadIds.length ? uploads.take(uploadIds) : []
        } catch (error) {
          if (error instanceof UploadError) return fail(id, error.code, error.message)
          throw error
        }
        try {
          // Answer first, as for CreateTask: then the UserMessage and the turn's events follow.
          await hub.sendMessage(taskId, text, mode === MessageMode.QUEUE ? 'queue' : 'steer',
            (messageId) => respond(id, { case: 'messageAccepted', value: { taskId, messageId } }), files)
        } catch (error) {
          log(`follow-up failed: ${String(error)}`)
          return fail(id, 'message/refused', error instanceof Error ? error.message : String(error))
        }
        return
      }
      case 'editQueue': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        if (!queues) return fail(id, 'request/unsupported', 'This host cannot change the queue.')
        const { taskId, messageId, action } = request.body.value
        if (action !== QueueAction.STEER && action !== QueueAction.REMOVE) {
          return fail(id, 'queue/action-invalid', 'Steer or remove a queued message.')
        }
        try {
          const placement = await hub.editQueue(taskId, messageId, action === QueueAction.STEER ? 'steer' : 'remove')
          return respond(id, { case: 'queueEdited', value: { taskId, messageId, placement: QueuePlacement[placement] } })
        } catch (error) {
          log(`queue edit failed: ${String(error)}`)
          return fail(id, 'queue/refused', error instanceof Error ? error.message : String(error))
        }
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
            return respond(id, { case: 'modelCatalog', value: catalogFrame(await options.tasks.modelCatalog()) })
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
        if (!actor) return fail(id, 'devices/forbidden', 'Pair this device to manage the host.')
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
              if (fingerprint === target) client.close(4003, 'device revoked')
            }
          }
        } catch (error) {
          return fail(id, 'devices/failed', error instanceof Error ? error.message : String(error))
        }
        return
      }
      case 'answerQuestion': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        if (!options.questions || !clientQuestions) return fail(id, 'request/unsupported', 'questions unavailable')
        const answer = request.body.value
        try {
          const resolved = options.questions.answer(answer.id, answer.answers.map(a => ({ questionId: a.questionId, selected: [...a.selected], custom: a.custom })))
          log(`question ${answer.id} answered by ${device}`)
          return respond(id, { case: 'questionResolved', value: { ...resolved, outcome: QuestionOutcome[resolved.outcome] } })
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
          return respond(id, { case: 'approvalResolved', value: { ...resolved, outcome: ApprovalOutcome[resolved.outcome] } })
        } catch (error) {
          return fail(id, 'approval/refused', error instanceof Error ? error.message : String(error))
        }
      }
      case 'readSession': {
        if (!helloDone || !clientSessions || !options.sessions) return fail(id, 'request/unsupported', 'Session history unavailable.')
        const req = request.body.value
        try {
          const page = await options.sessions.read(req.taskId, req.beforeSeq, req.throughSeq)
          const messages = page.messages.map(m => ({ ...m, attachments: m.attachments.map(wireAttachment) }))
          return respond(id, { case: 'sessionPage', value: { ...page, messages } })
        } catch (error) { return fail(id, 'session/read-failed', String(error)) }
      }
      case 'listTasks': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        return respond(id, { case: 'taskList', value: { tasks: hub.list().map(wireSummary).filter(task => clientApprovals || !task.approvalOnly)
          .map(task => clientQuestions ? task : withoutQuestions(task))
          .flatMap(task => !clientSessions && task.externalSession ? (clientApprovals && task.pendingApprovals.length
            ? [{ ...task, title: '', approvalOnly: true }] : []) : [task]), logId: hub.log.logId, hostName } })
      }
      case 'resume': {
        if (!helloDone) return fail(id, 'hello/required', 'send Hello first')
        if (clientSessions) {
          try { await options.sessions!.reconcile() }
          catch (error) { return fail(id, 'session/list-failed', String(error)) }
        }
        if (socket.readyState !== socket.OPEN || !store.has(device)) return
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
    if (socket.readyState !== socket.OPEN || !store.has(device)) return
    if (!isBinary) return socket.close(1003, 'binary frames only')
    const bytes = new Uint8Array(Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer))
    let frame: Frame
    try {
      frame = fromBinary(FrameSchema, bytes)
    } catch {
      return socket.close(1007, 'undecodable frame')
    }
    if (frame.kind.case !== 'request') return
    handle(frame.kind.value).catch((error) => log(`request failed: ${String(error)}`))
  })
  // The connection goes; the host's tasks keep running (STORY principle 4).
  socket.on('close', () => { host.authenticated.delete(socket); unsubscribe?.() })
}
