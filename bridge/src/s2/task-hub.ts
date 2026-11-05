/**
 * S2: tasks belong to the host, not to the connection that created them (STORY principle 4:
 * nothing is lost across disconnects). The hub starts each task, follows its output for as
 * long as the bridge runs, keeps a summary per task for `ListTasks`, and writes every event
 * into the `HostLog` that `Resume` replays from.
 */
import { TaskStatus } from '../gen/frame_pb.ts'
import { TaskState, type TaskSummary } from '../gen/s2_pb.ts'
import type { StartedTask } from '../dsh.ts'
import { HostLog } from './host-log.ts'
import { milestoneAdded } from '../milestones/wire.ts'

export interface TaskStarter {
  start(prompt: string, signal: AbortSignal): Promise<StartedTask>
}

type Summary = Omit<TaskSummary, '$typeName' | '$unknown'>

export class TaskHub {
  private readonly summaries = new Map<string, Summary>()
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
      createdAtMs: at, updatedAtMs: at, message: '',
    }
    this.summaries.set(task.taskId, summary)
    onCreated(task.taskId)
    this.upserted(summary)
    const pump = this.pump(task, summary).finally(() => this.running.delete(pump))
    this.running.add(pump)
    return task.taskId
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
