/**
 * S2: tasks belong to the host, not to the connection that created them (STORY principle 4:
 * nothing is lost across disconnects). The hub starts each task, follows its output for as
 * long as the bridge runs, keeps a summary per task for `ListTasks`, and writes every event
 * into the `HostLog` that `Resume` replays from.
 */
import type { Pending, Resolved } from '../approvals/holder.ts'
import { TaskStatus } from '../gen/frame_pb.ts'
import { TaskState, type TaskSummary } from '../gen/s2_pb.ts'
import type { StartedTask } from '../dsh.ts'
import { HostLog } from './host-log.ts'
import { milestoneAdded } from '../milestones/wire.ts'

export interface TaskStarter {
  start(prompt: string, signal: AbortSignal): Promise<StartedTask>
}

type Summary = Omit<TaskSummary, '$typeName' | '$unknown' | 'pendingApprovals'> & { pendingApprovals: Pending[] }

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
  async create(prompt: string, onCreated: (taskId: string) => void = () => {}): Promise<string> {
    const task = await this.starter.start(prompt, this.abort.signal)
    const at = BigInt(this.now())
    const summary: Summary = {
      taskId: task.taskId, title: prompt, state: TaskState.RUNNING,
      createdAtMs: at, updatedAtMs: at, message: '', approvalOnly: false, pendingApprovals: this.approvalsFor(task.taskId),
    }
    if (summary.pendingApprovals.length) summary.state = TaskState.WAITING_ON_USER
    this.summaries.set(task.taskId, summary)
    onCreated(task.taskId)
    this.upserted(summary)
    const pump = this.pump(task, summary).finally(() => this.running.delete(pump))
    this.running.add(pump)
    return task.taskId
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
        updatedAtMs: at, message: '', approvalOnly: true, pendingApprovals: [] }
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
        } else if (out.kind === 'milestone') {
          // S3: milestones are logged like any other event, so Resume replays them (S2 × S3 seam).
          this.log.append(task.taskId, { case: 'milestoneAdded', value: milestoneAdded(task.taskId, ++milestoneSeq, out.milestone) })
        } else {
          ended = true
          this.end(summary, out.status === 'completed', out.message ?? '')
        }
      }
    } catch (error) {
      if (!ended && !this.abort.signal.aborted) {
        ended = true
        this.end(summary, false, error instanceof Error ? error.message : String(error))
      }
    }
  }

  private end(summary: Summary, completed: boolean, message: string) {
    summary.state = completed ? TaskState.COMPLETED : TaskState.FAILED
    summary.message = completed ? '' : message
    summary.updatedAtMs = BigInt(this.now())
    // State first, then TaskEnded: TaskEnded stays the task's last event (T0's contract).
    this.upserted(summary)
    this.log.append(summary.taskId, {
      case: 'taskEnded',
      value: { taskId: summary.taskId, status: completed ? TaskStatus.COMPLETED : TaskStatus.FAILED, message: summary.message },
    })
  }

  private upserted(summary: Summary) {
    this.log.append(summary.taskId, { case: 'taskUpserted', value: { task: { ...summary } } })
  }
}
