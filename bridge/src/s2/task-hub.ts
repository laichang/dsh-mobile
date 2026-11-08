/**
 * S2: tasks belong to the host, not to the connection that created them (STORY principle 4:
 * nothing is lost across disconnects). The hub starts each task, follows its output for as
 * long as the bridge runs, keeps a summary per task for `ListTasks`, and writes every event
 * into the `HostLog` that `Resume` replays from.
 */
import type { Selection } from '../models/catalog.ts'
import type { Pending, Resolved } from '../approvals/holder.ts'
import type * as Questions from '../questions/holder.ts'
import { TaskStatus } from '../gen/frame_pb.ts'
import { QueuePlacement } from '../gen/conversation_pb.ts'
import { TaskState, type TaskSummary } from '../gen/s2_pb.ts'
import { randomUUID } from 'node:crypto'
import type { Continues, DshTasks, PromptMode, StartedTask, TaskOutput } from '../dsh.ts'
import { HostLog } from './host-log.ts'
import type { StagedImage } from '../attachments/staging.ts'
import { milestoneAdded } from '../milestones/wire.ts'
import { sessionWorkspace } from '../drawer/workspace.ts'
import { transcriptBlock } from '../transcript/wire.ts'

export interface TaskStarter {
  interrupt(taskId: string): void
  listWorkspaces?: DshTasks['listWorkspaces']
  /** D89: more messages into a task's DSH session (`conversation.v1`). */
  followUp?: DshTasks['followUp']
  /** D101: the queue while a task runs (`conversation.v2`). */
  prompt?: DshTasks['prompt']
  editQueue?: DshTasks['editQueue']
  inbox?: DshTasks['inbox']
  modelCatalog?: DshTasks['modelCatalog']
  selectModel?: DshTasks['selectModel']
  start(prompt: string, signal: AbortSignal, selection?: Selection, workspace?: string, images?: readonly StagedImage[],
        continues?: Continues): Promise<StartedTask>
  /** Attachments (D95): the starter takes `images`. */
  readonly attachments?: boolean
}

/** D101: a message sent while its task runs, until DSH takes it into a turn. */
interface Waiting {
  taskId: string
  text: string
  timeMs: bigint
  placement: QueuePlacement.QUEUED | QueuePlacement.STEERING
}

type Summary = Omit<TaskSummary, '$typeName' | '$unknown' | 'pendingApprovals' | 'modelSelection'>
  & { pendingApprovals: Pending[]; modelSelection?: Selection }

export class TaskHub {
  private readonly summaries = new Map<string, Summary>()
  private readonly pending = new Map<string, Pending>()
  private readonly abort = new AbortController()
  private readonly running = new Set<Promise<void>>()
  /** Per task: the last chunk and milestone seq, and the latest DSH turn. A later turn continues them. */
  private readonly cursors = new Map<string, { chunk: bigint; milestone: bigint; turn?: number }>()
  /** D89: tasks whose follow-up DSH has not accepted yet; a second send waits for the first. */
  private readonly sending = new Set<string>()
  /** D101: by message ID, the messages that wait in a running task's DSH inbox. */
  private readonly waiting = new Map<string, Waiting>()
  /** D101: per task, a message to the running turn that DSH has not accepted yet. */
  private readonly inflight = new Map<string, Promise<unknown>>()
  /** D101: tasks whose DSH session the hub follows now (a pump runs). */
  private readonly following = new Set<string>()
  /** D89: messages whose UserMessage is logged already (a follow-up to an idle task, on acceptance). */
  private readonly logged = new Set<string>()

  constructor(
    private readonly starter: TaskStarter,
    readonly log: HostLog = new HostLog(),
    private readonly now: () => number = Date.now,
  ) {}

  /**
   * Starts a task. `onCreated` runs synchronously once the task id is known and before any of
   * the task's events are logged, so the caller can answer `CreateTask` first.
   */
  async create(prompt: string, onCreated: (taskId: string) => void = () => {}, selection?: Selection, workspace?: string,
                images?: readonly StagedImage[]): Promise<string> {
    let taskId: string | undefined
    const task = await this.starter.start(prompt, this.abort.signal, selection, workspace, images?.length ? images : undefined,
      () => taskId === undefined ? Promise.resolve(false) : this.continues(taskId))
    taskId = task.taskId
    const at = BigInt(this.now())
    const summary: Summary = {
      taskId: task.taskId, title: prompt, state: TaskState.RUNNING,
      createdAtMs: at, updatedAtMs: at, message: '', approvalOnly: false, externalSession: false,
      sessionRevision: this.summaries.get(task.taskId)?.sessionRevision, pendingApprovals: this.approvalsFor(task.taskId),
      workspace: sessionWorkspace(this.summaries.get(task.taskId)?.workspace, task.workspace ?? workspace),
    }
    if (summary.pendingApprovals.length) summary.state = TaskState.WAITING_ON_USER
    this.summaries.set(task.taskId, summary)
    onCreated(task.taskId)
    this.upserted(summary)
    const pump = this.pump(task, summary).finally(() => this.running.delete(pump))
    this.running.add(pump)
    return task.taskId
  }

  interrupt(taskId: string): void {
    const task = this.summaries.get(taskId)
    if (!task || task.approvalOnly) throw new Error('Unknown bridge task')
    // The terminal event can race a tap or a retry. Keep the outcome DSH already reported.
    if (task.state === TaskState.RUNNING || task.state === TaskState.WAITING_ON_USER) this.starter.interrupt(taskId)
  }

  /**
   * Sends one more message into the DSH session of a task. `onAccepted` runs once DSH accepted
   * the message, before the task's new events.
   *
   * - D89: a task that is done (completed, or stopped by the user) runs again: the new turn streams
   *   under the same task ID, the chunk seq goes on, the task is RUNNING again, and TaskEnded ends it.
   * - D101: while the task runs, the message waits in DSH's inbox: `queue` for the next turn, `steer`
   *   for the next step of this one. A QueuedMessage says so; the UserMessage follows where DSH takes it.
   */
  async sendMessage(taskId: string, text: string, mode: PromptMode,
    onAccepted: (messageId: string) => void = () => {}): Promise<string> {
    const summary = this.summaries.get(taskId)
    if (!this.starter.followUp) throw new Error('This host cannot take follow-up messages.')
    if (!summary || summary.approvalOnly || summary.externalSession) throw new Error('Unknown bridge task')
    if (this.following.has(taskId) && this.isActive(taskId)) return this.sendWhileRunning(taskId, text, mode, onAccepted)
    // Not after a failure (the failed task's own card), and not while an earlier send waits.
    if ((summary.state !== TaskState.COMPLETED && summary.state !== TaskState.INTERRUPTED) || this.sending.has(taskId)) {
      throw new Error('Send a follow-up when the task is done.')
    }
    const cursor = this.cursor(taskId)
    const messageId = randomUUID()
    this.sending.add(taskId)
    let output: AsyncIterable<TaskOutput>
    try {
      output = await this.starter.followUp(taskId, text,
        { messageId, mode, afterTurn: cursor.turn, continues: () => this.continues(taskId) }, this.abort.signal)
    } finally {
      this.sending.delete(taskId)
    }
    const at = this.now()
    onAccepted(messageId)
    this.logged.add(messageId)
    this.log.append(taskId, { case: 'userMessage', value: { taskId, messageId, text, timeMs: BigInt(at) } })
    summary.state = summary.pendingApprovals.length ? TaskState.WAITING_ON_USER : TaskState.RUNNING
    this.turnStarted(summary, at)
    const pump = this.pump({ taskId, output }, summary).finally(() => this.running.delete(pump))
    this.running.add(pump)
    return messageId
  }

  /** D101: the message waits in DSH's inbox of the running task until DSH takes it. */
  private async sendWhileRunning(taskId: string, text: string, mode: PromptMode,
    onAccepted: (messageId: string) => void): Promise<string> {
    if (!this.starter.prompt) throw new Error('This host takes follow-ups only when the task is done.')
    const messageId = randomUUID()
    const accepted = this.starter.prompt(taskId, text, { messageId, mode }, this.abort.signal)
    // A turn that ends meanwhile waits for this answer before it decides whether the task goes on.
    const flight = accepted.catch(() => {})
    this.inflight.set(taskId, flight)
    try {
      await accepted
    } finally {
      if (this.inflight.get(taskId) === flight) this.inflight.delete(taskId)
    }
    const placement = mode === 'queue' ? QueuePlacement.QUEUED : QueuePlacement.STEERING
    const waiting: Waiting = { taskId, text, timeMs: BigInt(this.now()), placement }
    this.waiting.set(messageId, waiting)
    onAccepted(messageId)
    this.queued(messageId, waiting, placement)
    return messageId
  }

  /**
   * D101: moves a waiting message into the running turn (`steer`), or takes it out (`remove`).
   * Returns its place afterwards: STEERING, REMOVED, or QUEUED when DSH could no longer steer
   * into the ending turn (the message then runs as the next turn).
   */
  async editQueue(taskId: string, messageId: string, action: 'steer' | 'remove'): Promise<QueuePlacement> {
    if (!this.starter.editQueue) throw new Error('This host cannot change the queue.')
    const waiting = this.waiting.get(messageId)
    if (!waiting || waiting.taskId !== taskId) throw new Error('This message is no longer waiting.')
    if (action === 'steer' && waiting.placement === QueuePlacement.STEERING) return QueuePlacement.STEERING
    const done = await this.starter.editQueue(taskId, messageId, action)
    // DSH can take the message while the edit runs; then its UserMessage is logged already.
    if (this.waiting.get(messageId) !== waiting) throw new Error('This message is no longer waiting.')
    if (!done) return waiting.placement
    if (action === 'remove') {
      this.waiting.delete(messageId)
      this.queued(messageId, waiting, QueuePlacement.REMOVED)
      return QueuePlacement.REMOVED
    }
    waiting.placement = QueuePlacement.STEERING
    this.queued(messageId, waiting, QueuePlacement.STEERING)
    return QueuePlacement.STEERING
  }

  /**
   * D101: asked when a turn of the task completes. True when a message of this phone still waits
   * in DSH's inbox: DSH runs it as the next turn, and the hub follows that turn too. A message
   * that no longer waits there (another client removed it) is logged as removed.
   */
  private async continues(taskId: string): Promise<boolean> {
    for (;;) {
      const flight = this.inflight.get(taskId)
      if (flight) { await flight; continue }
      const mine = [...this.waiting].filter(([, w]) => w.taskId === taskId)
      if (!mine.length) return false
      if (!this.starter.inbox) return true
      let inbox: { running: boolean; waiting: string[] }
      try {
        inbox = await this.starter.inbox(taskId)
      } catch {
        return true
      }
      if (this.inflight.has(taskId)) continue
      // A running agent has taken (or is about to take) the next message: its turn follows.
      if (inbox.running) return true
      for (const [messageId, waiting] of mine) {
        if (inbox.waiting.includes(messageId) || this.waiting.get(messageId) !== waiting) continue
        this.waiting.delete(messageId)
        this.queued(messageId, waiting, QueuePlacement.REMOVED)
      }
      return [...this.waiting.values()].some(w => w.taskId === taskId)
    }
  }

  private queued(messageId: string, waiting: Waiting, placement: QueuePlacement) {
    const { taskId, text, timeMs } = waiting
    this.log.append(taskId, { case: 'queuedMessage', value: { taskId, messageId, text, timeMs, placement } })
  }

  /** A new turn of the task: RUNNING, with its own start (S27: 用时 counts the latest turn only). */
  private turnStarted(summary: Summary, at: number) {
    summary.message = ''
    summary.latestReply = undefined
    summary.updatedAtMs = BigInt(at)
    summary.turnStartedAtMs = BigInt(at)
    this.upserted(summary)
  }

  private cursor(taskId: string) {
    let cursor = this.cursors.get(taskId)
    if (!cursor) this.cursors.set(taskId, cursor = { chunk: 0n, milestone: 0n })
    return cursor
  }

  /** Includes tasks paused for user input. */
  isActive(taskId: string): boolean {
    const task = this.summaries.get(taskId)
    return !!task && !task.approvalOnly && (task.state === TaskState.RUNNING || task.state === TaskState.WAITING_ON_USER)
  }

  approvalChanged(event: Pending | Resolved, external = false) {
    if ('outcome' in event) {
      this.pending.delete(event.id)
      this.log.append(event.taskId, { case: 'approvalResolved', value: event })
    } else {
      this.pending.set(event.id, event)
      this.log.append(event.taskId, { case: 'approvalPending', value: event })
    }
    let summary = this.summaries.get(event.taskId)
    if (!summary && external && !('outcome' in event)) {
      const at = BigInt(this.now())
      summary = { taskId: event.taskId, title: '', state: TaskState.WAITING_ON_USER, createdAtMs: at,
        updatedAtMs: at, message: '', approvalOnly: true, externalSession: false, pendingApprovals: [] }
      this.summaries.set(event.taskId, summary)
    }
    if (!summary) return // create() snapshots requests that arrived while DSH accepted our prompt.
    summary.pendingApprovals = this.approvalsFor(event.taskId)
    if (summary.approvalOnly && !summary.pendingApprovals.length) {
      this.summaries.delete(event.taskId)
      return
    }
    if (summary.state === TaskState.RUNNING || summary.state === TaskState.WAITING_ON_USER) {
      summary.state = summary.pendingApprovals.length ? TaskState.WAITING_ON_USER : TaskState.RUNNING
    }
    summary.updatedAtMs = BigInt(this.now())
    this.upserted(summary)
  }

  /**
   * Agent questions are logged like any other event, so a phone that resumes gets the card. The
   * task's state stays as DSH reports it.
   */
  questionChanged(event: Questions.Pending | Questions.Resolved) {
    if ('outcome' in event) this.log.append(event.taskId, { case: 'questionResolved', value: event })
    else this.log.append(event.taskId, { case: 'questionPending', value: event })
  }

  private approvalsFor(taskId: string) {
    return [...this.pending.values()].filter(request => request.taskId === taskId)
  }

  sessionRevision(taskId: string): number | undefined {
    const revision = this.summaries.get(taskId)?.sessionRevision
    return revision === undefined ? undefined : Number(revision)
  }

  /** The DSH session ID is also CreateTask's ID, even if the journal arrives before its response. */
  observeSession(taskId: string, revision: bigint, title: string, state: TaskState, message: string,
    updatedAt: bigint, createdAt: bigint, latestReply?: string, hostTitle?: string, workspace?: string,
    turnStartedAt?: bigint) {
    const old = this.summaries.get(taskId)
    if (old?.sessionRevision !== undefined && old.sessionRevision >= revision) return
    const pending = this.approvalsFor(taskId)
    const summary: Summary = old ?? { taskId, title, createdAtMs: createdAt, updatedAtMs: updatedAt,
      state, message, externalSession: true, approvalOnly: false, pendingApprovals: pending }
    if (summary.approvalOnly) summary.externalSession = true
    summary.approvalOnly = false
    if (hostTitle) summary.title = hostTitle
    else if (!summary.title || summary.title === taskId) summary.title = title
    summary.latestReply = latestReply
    summary.workspace = sessionWorkspace(workspace, summary.workspace)
    summary.sessionRevision = revision
    summary.updatedAtMs = summary.updatedAtMs > updatedAt ? summary.updatedAtMs : updatedAt
    if (turnStartedAt !== undefined) summary.turnStartedAtMs = turnStartedAt
    summary.state = pending.length ? TaskState.WAITING_ON_USER : state
    summary.message = message
    this.summaries.set(taskId, summary)
    this.upserted(summary)
  }

  /** Every known task, newest first. */
  list(): Summary[] {
    return [...this.summaries.values()].map((s) => ({ ...s })).reverse()
  }

  /** Stops following DSH (bridge shutdown). DSH's own sessions keep running. */
  async close(): Promise<void> {
    this.abort.abort()
    await Promise.allSettled([...this.running])
  }

  private async pump(task: Pick<StartedTask, 'taskId' | 'output'>, summary: Summary): Promise<void> {
    const cursor = this.cursor(task.taskId)
    let ended = false
    let turns = 0
    this.following.add(task.taskId)
    try {
      for await (const out of task.output) {
        if (out.kind === 'turn') {
          cursor.turn = out.turn
          // D101: a queued message's turn, in the same follow: the task stays RUNNING, with a new 用时.
          if (turns++ > 0) this.turnStarted(summary, this.now())
        } else if (out.kind === 'user') {
          this.userMessage(task.taskId, out)
        } else if (out.kind === 'text') {
          this.log.append(task.taskId, { case: 'assistantChunk', value: { taskId: task.taskId, seq: ++cursor.chunk, text: out.text } })
        } else if (out.kind === 'model') {
          summary.modelSelection = out.selection
          summary.updatedAtMs = BigInt(this.now())
          this.log.append(task.taskId, { case: 'modelSelected', value: { taskId: task.taskId, selection: out.selection } })
        } else if (out.kind === 'milestone') {
          // S3: milestones are logged like any other event, so Resume replays them (S2 × S3 seam).
          this.log.append(task.taskId, { case: 'milestoneAdded', value: milestoneAdded(task.taskId, ++cursor.milestone, out.milestone) })
        } else if (out.kind === 'block') {
          // S17: blocks are logged too, so Resume replays them in their place among the chunks.
          this.log.append(task.taskId, { case: 'transcriptBlock', value: transcriptBlock(task.taskId, out.block) })
        } else {
          ended = true
          this.end(summary, out)
        }
      }
    } catch (error) {
      if (!ended && !this.abort.signal.aborted) {
        ended = true
        this.end(summary, { kind: 'end', status: 'failed', message: error instanceof Error ? error.message : String(error) })
      }
    } finally {
      this.following.delete(task.taskId)
    }
  }

  /**
   * D101: DSH took a user message into the task's turn. A message that waited ends its wait and
   * sits here in the transcript. A follow-up logged on acceptance (D89) is not logged again; a
   * message from another client into this task is logged too.
   */
  private userMessage(taskId: string, out: Extract<TaskOutput, { kind: 'user' }>) {
    if (this.logged.has(out.messageId)) return
    const waiting = this.waiting.get(out.messageId)
    this.waiting.delete(out.messageId)
    this.logged.add(out.messageId)
    this.log.append(taskId, { case: 'userMessage', value: {
      taskId, messageId: out.messageId, text: waiting?.text ?? out.text, timeMs: BigInt(this.now()) } })
  }

  private end(summary: Summary, end: Extract<TaskOutput, { kind: 'end' }>) {
    const states = {
      completed: [TaskState.COMPLETED, TaskStatus.COMPLETED],
      failed: [TaskState.FAILED, TaskStatus.FAILED],
      interrupted: [TaskState.INTERRUPTED, TaskStatus.INTERRUPTED],
    } as const
    const [state, status] = states[end.status]
    // D101: messages that still wait do not run after a stop: out of DSH's inbox, back to the composer.
    for (const [messageId, waiting] of [...this.waiting].filter(([, w]) => w.taskId === summary.taskId)) {
      this.waiting.delete(messageId)
      this.queued(messageId, waiting, QueuePlacement.RETURNED)
      void this.starter.editQueue?.(summary.taskId, messageId, 'remove').catch(() => {})
    }
    summary.state = state
    summary.message = end.message ?? ''
    summary.updatedAtMs = BigInt(this.now())
    // State first, then TaskEnded: TaskEnded stays the task's last event (T0's contract).
    this.upserted(summary)
    this.log.append(summary.taskId, {
      case: 'taskEnded',
      value: { taskId: summary.taskId, status, message: summary.message },
    })
  }

  private upserted(summary: Summary) {
    this.log.append(summary.taskId, { case: 'taskUpserted', value: { task: { ...summary } } })
  }
}
