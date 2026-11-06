/**
 * S2: tasks belong to the host, not to the connection that created them (STORY principle 4:
 * nothing is lost across disconnects). The hub starts each task, follows its output for as
 * long as the bridge runs, keeps a summary per task for `ListTasks`, and writes every event
 * into the `HostLog` that `Resume` replays from.
 */
import type { Selection } from '../models/catalog.ts'
import type { Pending, Resolved } from '../approvals/holder.ts'
import { TaskStatus } from '../gen/frame_pb.ts'
import { TaskState, type TaskSummary } from '../gen/s2_pb.ts'
import type { DshTasks, StartedTask, TaskOutput } from '../dsh.ts'
import { HostLog } from './host-log.ts'
import { milestoneAdded } from '../milestones/wire.ts'
import { sessionWorkspace } from '../drawer/workspace.ts'

export interface TaskStarter {
  interrupt(taskId: string): void
  listWorkspaces?: DshTasks['listWorkspaces']
  modelCatalog?: DshTasks['modelCatalog']
  selectModel?: DshTasks['selectModel']
  start(prompt: string, signal: AbortSignal, selection?: Selection, workspace?: string): Promise<StartedTask>
}

type Summary = Omit<TaskSummary, '$typeName' | '$unknown' | 'pendingApprovals' | 'modelSelection'>
  & { pendingApprovals: Pending[]; modelSelection?: Selection }

export class TaskHub {
  private readonly summaries = new Map<string, Summary>()
  private readonly pending = new Map<string, Pending>()
  private readonly abort = new AbortController()
  private readonly running = new Set<Promise<void>>()

  constructor(
    private readonly starter: TaskStarter,
    readonly log: HostLog = new HostLog(),
    private readonly now: () => number = Date.now,
  ) {}

  /**
   * Starts a task. `onCreated` runs synchronously once the task id is known and before any of
   * the task's events are logged, so the caller can answer `CreateTask` first.
   */
  async create(prompt: string, onCreated: (taskId: string) => void = () => {}, selection?: Selection, workspace?: string): Promise<string> {
    const task = await this.starter.start(prompt, this.abort.signal, selection, workspace)
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

  private approvalsFor(taskId: string) {
    return [...this.pending.values()].filter(request => request.taskId === taskId)
  }

  sessionRevision(taskId: string): number | undefined {
    const revision = this.summaries.get(taskId)?.sessionRevision
    return revision === undefined ? undefined : Number(revision)
  }

  /** The DSH session ID is also CreateTask's ID, even if the journal arrives before its response. */
  observeSession(taskId: string, revision: bigint, title: string, state: TaskState, message: string,
    updatedAt: bigint, createdAt: bigint, latestReply?: string, renamedTitle?: string, workspace?: string) {
    const old = this.summaries.get(taskId)
    if (old?.sessionRevision !== undefined && old.sessionRevision >= revision) return
    const pending = this.approvalsFor(taskId)
    const summary: Summary = old ?? { taskId, title, createdAtMs: createdAt, updatedAtMs: updatedAt,
      state, message, externalSession: true, approvalOnly: false, pendingApprovals: pending }
    if (summary.approvalOnly) summary.externalSession = true
    summary.approvalOnly = false
    if (renamedTitle) summary.title = renamedTitle
    else if (!summary.title || summary.title === taskId) summary.title = title
    summary.latestReply = latestReply
    summary.workspace = sessionWorkspace(workspace, summary.workspace)
    summary.sessionRevision = revision
    summary.updatedAtMs = summary.updatedAtMs > updatedAt ? summary.updatedAtMs : updatedAt
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

  private async pump(task: StartedTask, summary: Summary): Promise<void> {
    let seq = 0n
    let milestoneSeq = 0n
    let ended = false
    try {
      for await (const out of task.output) {
        if (out.kind === 'text') {
          this.log.append(task.taskId, { case: 'assistantChunk', value: { taskId: task.taskId, seq: ++seq, text: out.text } })
        } else if (out.kind === 'model') {
          summary.modelSelection = out.selection
          summary.updatedAtMs = BigInt(this.now())
          this.log.append(task.taskId, { case: 'modelSelected', value: { taskId: task.taskId, selection: out.selection } })
        } else if (out.kind === 'milestone') {
          // S3: milestones are logged like any other event, so Resume replays them (S2 × S3 seam).
          this.log.append(task.taskId, { case: 'milestoneAdded', value: milestoneAdded(task.taskId, ++milestoneSeq, out.milestone) })
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
