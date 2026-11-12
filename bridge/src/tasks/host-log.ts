/**
 * The bridge's per-host event log. DSH has no server-side resume cursor,
 * so the bridge numbers every event it forwards with a monotonic `host_seq` and keeps the most
 * recent ones, so an app that was away can `Resume { after_seq }` and receive exactly the gap.
 *
 * The log lives in memory for the bridge process; `logId` names this incarnation, so an app
 * holding a cursor from an earlier process (or from trimmed events) gets a reset, not a silent gap.
 */
import { randomUUID } from 'node:crypto'
import type { MessageInitShape } from '@bufbuild/protobuf'
import type { Attachment, TaskEvent, Summary } from './events.ts'
import { TaskState } from '../gen/durable_list_pb.ts'
import { QueuePlacement } from '../gen/conversation_pb.ts'
import { AttachmentKind } from '../gen/attachments_pb.ts'
import { ApprovalOutcome } from '../gen/approvals_pb.ts'
import { QuestionOutcome } from '../gen/questions_pb.ts'
import { milestoneAdded } from '../milestones/wire.ts'
import { transcriptBlock } from '../transcript/wire.ts'
import { TaskStatus, type EventSchema } from '../gen/frame_pb.ts'

export type EventBody = MessageInitShape<typeof EventSchema>['body']

export function wireAttachment(attachment: Attachment) {
  return { ...attachment, kind: attachment.kind === 'image' ? AttachmentKind.IMAGE : AttachmentKind.FILE }
}

export function wireSummary(task: Summary) {
  return { ...task, state: TaskState[task.state] }
}

function eventBody(event: TaskEvent): EventBody {
  switch (event.case) {
    case 'userMessage': return { case: event.case, value: { ...event.value, attachments: event.value.attachments?.map(wireAttachment) } }
    case 'queuedMessage': return { case: event.case, value: { ...event.value, placement: QueuePlacement[event.value.placement] } }
    case 'taskUpserted': return { case: event.case, value: { task: wireSummary(event.value.task) } }
    case 'taskEnded': return { case: event.case, value: { ...event.value, status: TaskStatus[event.value.status] } }
    case 'approvalResolved': return { case: event.case, value: { ...event.value, outcome: ApprovalOutcome[event.value.outcome] } }
    case 'questionResolved': return { case: event.case, value: { ...event.value, outcome: QuestionOutcome[event.value.outcome] } }
    case 'milestoneAdded': return { case: event.case, value: milestoneAdded(event.value.taskId, event.value.seq, event.value.milestone) }
    case 'transcriptBlock': return { case: event.case, value: transcriptBlock(event.value.taskId, event.value.block) }
    default: return event
  }
}

export interface LoggedEvent {
  readonly seq: bigint
  readonly taskId: string
  readonly body: EventBody
}

export interface Replay {
  /** True when the cursor doesn't apply (other log, future seq, or trimmed): `events` is everything retained. */
  reset: boolean
  events: LoggedEvent[]
}

export const DEFAULT_LOG_CAPACITY = 50_000

export class HostLog {
  readonly logId: string
  private readonly events: LoggedEvent[] = []
  private headSeq = 0n
  private readonly listeners = new Set<(event: LoggedEvent) => void>()

  constructor(private readonly capacity = DEFAULT_LOG_CAPACITY, logId: string = randomUUID()) {
    if (capacity < 1) throw new Error('capacity must be at least 1')
    this.logId = logId
  }

  /** The last assigned seq (0 before the first event). */
  get head(): bigint { return this.headSeq }

  /** Oldest retained seq, or head + 1 when empty. */
  get firstRetained(): bigint { return this.events[0]?.seq ?? this.headSeq + 1n }

  /** Numbers, stores and publishes one event. Listeners run synchronously, in order. */
  append(taskId: string, value: TaskEvent): LoggedEvent {
    const event: LoggedEvent = { seq: ++this.headSeq, taskId, body: eventBody(value) }
    this.events.push(event)
    if (this.events.length > this.capacity) this.events.splice(0, this.events.length - this.capacity)
    for (const listener of this.listeners) listener(event)
    return event
  }

  /** The events after `afterSeq` of log `logId`, or a reset with everything retained. */
  since(logId: string, afterSeq: bigint): Replay {
    const continuable = logId === this.logId && afterSeq <= this.headSeq && afterSeq >= this.firstRetained - 1n
    if (!continuable) return { reset: true, events: [...this.events] }
    // seqs are contiguous in `events`, so the gap starts at a known index.
    const start = Number(afterSeq - this.firstRetained + 1n)
    return { reset: false, events: this.events.slice(Math.max(0, start)) }
  }

  subscribe(listener: (event: LoggedEvent) => void): () => void {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }
}
