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
import { TaskState, type TaskSummary } from '../gen/s2_pb.ts'
import { randomUUID } from 'node:crypto'
import type { DshTasks, PromptMode, StartedTask, TaskOutput } from '../dsh.ts'
import { HostLog } from './host-log.ts'
import type { StagedImage } from '../attachments/staging.ts'
import { milestoneAdded } from '../milestones/wire.ts'
import { sessionWorkspace } from '../drawer/workspace.ts'
import { transcriptBlock } from '../transcript/wire.ts'
import type { Failure } from '../milestones/mapper.ts'

export interface TaskStarter {
  interrupt(taskId: string): void
  listWorkspaces?: DshTasks['listWorkspaces']
  /** D89: more messages into a task's DSH session (`conversation.v1`). */
  followUp?: DshTasks['followUp']
  modelCatalog?: DshTasks['modelCatalog']
  selectModel?: DshTasks['selectModel']
  start(prompt: string, signal: AbortSignal, selection?: Selection, workspace?: string, images?: readonly StagedImage[]): Promise<StartedTask>
  /** Attachments (D95): the starter takes `images`. */
  readonly attachments?: boolean
}

type Summary = Omit<TaskSummary, '$typeName' | '$unknown' | 'pendingApprovals' | 'modelSelection'>
  & { pendingApprovals: Pending[]; modelSelection?: Selection }

export class TaskHub {
  private readonly summaries = new Map<string, Summary>()
  private readonly pending = new Map<string, Pending>()
  private readonly abort = new AbortController()
  private readonly running = new Set<Promise<void>>()
  /** Per task: the last chunk and milestone seq, and the latest DSH turn. A later turn continues them. */
  private readonly cursors = new Map<string, { chunk: bigint; milestone: bigint; turn?: number; turns: number }>()
  /** D89: tasks whose follow-up DSH has not accepted yet; a second send waits for the first. */
  private readonly sending = new Set<string>()

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
    const task = images?.length
      ? await this.starter.start(prompt, this.abort.signal, selection, workspace, images)
      : await this.starter.start(prompt, this.abort.signal, selection, workspace)
    const at = BigInt(this.now())
    const summary: Summary = {
      taskId: task.taskId, title: prompt, state: TaskState.RUNNING,
      createdAtMs: at, updatedAtMs: at, message: '', failureCode: '', approvalOnly: false, externalSession: false,
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
   * D89: sends one more message into the DSH session of a finished task. The new turn streams
   * under the same task ID: the chunk seq goes on, the task is RUNNING again, and TaskEnded ends
   * the turn. `onAccepted` runs once DSH accepted the message, before the task's new events.
   * D110: a failed task takes one too (a model failure leaves the session usable), and that turn
   * adds milestones, so the timeline goes on with the work instead of ending on the failure.
   */
  async sendMessage(taskId: string, text: string, mode: PromptMode,
    onAccepted: (messageId: string) => void = () => {}): Promise<string> {
    const summary = this.summaries.get(taskId)
    if (!this.starter.followUp) throw new Error('This host cannot take follow-up messages.')
    if (!summary || summary.approvalOnly || summary.externalSession) throw new Error('Unknown bridge task')
    // A follow-up after the task completed (D89) or failed (D110). Not while it runs.
    const afterFailure = summary.state === TaskState.FAILED
    if ((summary.state !== TaskState.COMPLETED && !afterFailure) || this.sending.has(taskId)) {
      throw new Error('Send a follow-up when the task is done.')
    }
    const cursor = this.cursor(taskId)
    const messageId = randomUUID()
    this.sending.add(taskId)
    let output: AsyncIterable<TaskOutput>
    try {
      output = await this.starter.followUp(taskId, text,
        { messageId, mode, afterTurn: cursor.turn, blockPrefix: `turn-${cursor.turns + 1}-`, milestones: afterFailure },
        this.abort.signal)
    } finally {
      this.sending.delete(taskId)
    }
    cursor.turns += 1
    const at = this.now()
    onAccepted(messageId)
    this.log.append(taskId, { case: 'userMessage', value: { taskId, messageId, text, timeMs: BigInt(at) } })
    summary.state = summary.pendingApprovals.length ? TaskState.WAITING_ON_USER : TaskState.RUNNING
    summary.message = ''
    summary.failureCode = ''
    summary.latestReply = undefined
    summary.updatedAtMs = BigInt(at)
    summary.turnStartedAtMs = BigInt(at) // S27: 用时 counts the latest turn only.
    this.upserted(summary)
    const pump = this.pump({ taskId, output }, summary).finally(() => this.running.delete(pump))
    this.running.add(pump)
    return messageId
  }

  private cursor(taskId: string) {
    let cursor = this.cursors.get(taskId)
    if (!cursor) this.cursors.set(taskId, cursor = { chunk: 0n, milestone: 0n, turns: 0 })
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
        updatedAtMs: at, message: '', failureCode: '', approvalOnly: true, externalSession: false, pendingApprovals: [] }
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
  observeSession(taskId: string, revision: bigint, title: string, state: TaskState, failure: Failure,
    updatedAt: bigint, createdAt: bigint, latestReply?: string, hostTitle?: string, workspace?: string,
    turnStartedAt?: bigint) {
    const old = this.summaries.get(taskId)
    if (old?.sessionRevision !== undefined && old.sessionRevision >= revision) return
    const pending = this.approvalsFor(taskId)
    const summary: Summary = old ?? { taskId, title, createdAtMs: createdAt, updatedAtMs: updatedAt,
      state, message: failure.message, failureCode: failure.code, externalSession: true, approvalOnly: false,
      pendingApprovals: pending }
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
    summary.message = failure.message
    summary.failureCode = failure.code
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
    try {
      for await (const out of task.output) {
        if (out.kind === 'turn') {
          cursor.turn = out.turn
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
    }
  }

  private end(summary: Summary, end: Extract<TaskOutput, { kind: 'end' }>) {
    const states = {
      completed: [TaskState.COMPLETED, TaskStatus.COMPLETED],
      failed: [TaskState.FAILED, TaskStatus.FAILED],
      interrupted: [TaskState.INTERRUPTED, TaskStatus.INTERRUPTED],
    } as const
    const [state, status] = states[end.status]
    summary.state = state
    summary.message = end.message ?? ''
    summary.failureCode = end.code ?? ''
    summary.updatedAtMs = BigInt(this.now())
    // State first, then TaskEnded: TaskEnded stays the task's last event (T0's contract).
    this.upserted(summary)
    this.log.append(summary.taskId, {
      case: 'taskEnded',
      value: { taskId: summary.taskId, status, message: summary.message, failureCode: summary.failureCode },
    })
  }

  private upserted(summary: Summary) {
    this.log.append(summary.taskId, { case: 'taskUpserted', value: { task: { ...summary } } })
  }
}
