import type * as Approvals from '../approvals/holder.ts'
import type * as Questions from '../questions/holder.ts'
import type { Selection } from '../models/catalog.ts'
import type { Milestone } from '../milestones/mapper.ts'
import type { BlockOut } from '../transcript/mapper.ts'
import type { AttachmentKind } from '../attachments/staging.ts'

export type EndStatus = 'COMPLETED' | 'FAILED' | 'INTERRUPTED'
export type State = EndStatus | 'RUNNING' | 'WAITING_ON_USER'
export type Placement = 'QUEUED' | 'STEERING' | 'REMOVED' | 'RETURNED'

export interface Summary {
  taskId: string
  title: string
  state: State
  createdAtMs: bigint
  updatedAtMs: bigint
  message: string
  failureCode: string
  approvalOnly: boolean
  externalSession: boolean
  sessionRevision?: bigint
  pendingApprovals: Approvals.Pending[]
  pendingQuestions: Questions.Pending[]
  modelSelection?: Selection
  workspace?: string
  turnStartedAtMs?: bigint
  latestReply?: string
}

export interface Attachment { kind: AttachmentKind; name: string; size: bigint; mediaType: string }

interface Events {
  userMessage: { taskId: string; messageId: string; text: string; timeMs: bigint;
    attachments?: Attachment[] }
  queuedMessage: { taskId: string; messageId: string; text: string; timeMs: bigint; placement: Placement }
  assistantChunk: { taskId: string; seq: bigint; text: string }
  modelSelected: { taskId: string; selection: Selection }
  milestoneAdded: { taskId: string; seq: bigint; milestone: Milestone }
  transcriptBlock: { taskId: string; block: BlockOut }
  approvalPending: Approvals.Pending
  approvalResolved: Approvals.Resolved
  questionPending: Questions.Pending
  questionResolved: Questions.Resolved
  taskEnded: { taskId: string; status: EndStatus; message: string; failureCode: string }
  taskUpserted: { task: Summary }
}

export type TaskEvent = { [K in keyof Events]: { case: K; value: Events[K] } }[keyof Events]
export interface TaskEvents {
  append(taskId: string, event: TaskEvent): void
}
