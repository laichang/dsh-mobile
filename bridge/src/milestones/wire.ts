/** S3: a mapped `Milestone` → the `MilestoneAdded` event body (protocol/milestones.proto). */
import type { MessageInitShape } from '@bufbuild/protobuf'
import { MilestoneKind, TodoStatus, type MilestoneAddedSchema } from '../gen/milestones_pb.ts'
import type { Milestone, MilestoneKindName, TodoStatusName } from './mapper.ts'

export const MILESTONES_CAPABILITY = 'milestones.v1'

const KINDS: Record<MilestoneKindName, MilestoneKind> = {
  started: MilestoneKind.STARTED,
  planned: MilestoneKind.PLANNED,
  todoStarted: MilestoneKind.TODO_STARTED,
  todoDone: MilestoneKind.TODO_DONE,
  planModeEntered: MilestoneKind.PLAN_MODE_ENTERED,
  planModeLeft: MilestoneKind.PLAN_MODE_LEFT,
  retrying: MilestoneKind.RETRYING,
  failed: MilestoneKind.FAILED,
  finished: MilestoneKind.FINISHED,
}

const STATUSES: Record<TodoStatusName, TodoStatus> = {
  pending: TodoStatus.PENDING,
  in_progress: TodoStatus.IN_PROGRESS,
  completed: TodoStatus.COMPLETED,
}

export function milestoneAdded(taskId: string, seq: bigint, m: Milestone): MessageInitShape<typeof MilestoneAddedSchema> {
  return {
    taskId,
    seq,
    kind: KINDS[m.kind],
    text: m.text,
    todos: m.todos.map((t) => ({ content: t.content, status: STATUSES[t.status] })),
    timeMs: BigInt(Math.trunc(m.timeMs)),
  }
}
