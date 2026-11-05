/**
 * S3 milestone mapper (ARCHITECTURE D11, D19): a deterministic fold over one DSH session's durable
 * events into milestones. No model, no invented text: a milestone carries DSH's own words (a
 * todo's content, a failure message) or none, and the app labels each kind itself.
 *
 * Inputs are the raw `sessionController.follow` event entries of DSH 0.2.2-rc.1:
 *   turn/start   → STARTED (first turn of the task only)
 *   todo/write   → PLANNED (the list's items changed), TODO_DONE / TODO_STARTED per status change
 *   plan/mode    → PLAN_MODE_ENTERED / PLAN_MODE_LEFT (when `active` flips)
 *   llm/retry    → RETRYING (a model request failed; DSH retries it)
 *   turn/end     → FINISHED (completed) or INTERRUPTED (user cancellation) or FAILED
 * Everything else is ignored. Payloads that don't have the expected shape are ignored too, so a
 * DSH upgrade degrades to fewer milestones rather than a broken task.
 */

export type MilestoneKindName =
  | 'started' | 'planned' | 'todoStarted' | 'todoDone'
  | 'planModeEntered' | 'planModeLeft' | 'retrying' | 'failed' | 'finished' | 'interrupted'

export type TodoStatusName = 'pending' | 'in_progress' | 'completed'

export interface TodoItem {
  content: string
  status: TodoStatusName
}

export interface Milestone {
  kind: MilestoneKindName
  /** DSH's words for it, or '' when DSH has none. */
  text: string
  /** The agent's whole todo list right after this milestone. */
  todos: TodoItem[]
  /** When DSH recorded the event, Unix ms. */
  timeMs: number
}

/** One durable event as `sessionController.follow` delivers it (`SessionWireEvent`). */
export interface SessionEventLike {
  type: string
  seq: number
  time?: number
  data: unknown
}

const STATUSES: readonly TodoStatusName[] = ['pending', 'in_progress', 'completed']

function parseTodos(data: unknown): TodoItem[] | undefined {
  const todos = (data as { todos?: unknown } | null)?.todos
  if (!Array.isArray(todos)) return undefined
  const out: TodoItem[] = []
  for (const t of todos) {
    const { content, status } = (t ?? {}) as { content?: unknown; status?: unknown }
    if (typeof content !== 'string' || !STATUSES.includes(status as TodoStatusName)) return undefined
    out.push({ content, status: status as TodoStatusName })
  }
  return out
}

/** `error.message` when there is one, else a string form, prefixed with DSH's reason kind. */
export function describeFailure(kind: string, error: unknown): string {
  if (error && typeof error === 'object' && 'message' in error) return `${kind}: ${String(error.message)}`
  return error === undefined ? kind : `${kind}: ${String(error)}`
}

export function isUserInterrupt(reason: { kind?: unknown; reason?: { kind?: unknown } } | undefined): boolean {
  return reason?.kind === 'aborted' && reason.reason?.kind === 'user'
}

/** Maps the events of one task (one DSH session, D13; the first turn) into milestones. */
export class MilestoneMapper {
  private todos: TodoItem[] = []
  private planMode = false
  private turn: number | undefined
  private ended = false

  /** The milestones `event` adds to the timeline, in order (often none). */
  map(event: SessionEventLike): Milestone[] {
    if (this.ended) return []
    const time = typeof event.time === 'number' ? event.time : 0
    const data = event.data as Record<string, unknown> | null
    const turnOf = () => (typeof data?.turn === 'number' ? data.turn : undefined)
    const at = (kind: MilestoneKindName, text = ''): Milestone =>
      ({ kind, text, todos: this.todos.map((t) => ({ ...t })), timeMs: time })

    switch (event.type) {
      case 'turn/start': {
        if (this.turn !== undefined) return []
        this.turn = turnOf()
        // DSH's `todos` projection clears at turn/start too.
        this.todos = []
        return [at('started')]
      }
      case 'todo/write': {
        const next = parseTodos(data)
        if (!next) return []
        return this.diffTodos(next, at)
      }
      case 'plan/mode': {
        const active = data?.active
        if (typeof active !== 'boolean' || active === this.planMode) return []
        this.planMode = active
        return [at(active ? 'planModeEntered' : 'planModeLeft')]
      }
      case 'llm/retry': {
        if (!this.ours(turnOf())) return []
        const failure = data?.failure as { message?: unknown } | undefined
        return [at('retrying', typeof failure?.message === 'string' ? failure.message : '')]
      }
      case 'turn/end': {
        if (!this.ours(turnOf())) return []
        this.ended = true
        const reason = data?.reason as { kind?: unknown; error?: unknown; reason?: { kind?: unknown } } | undefined
        const kind = typeof reason?.kind === 'string' ? reason.kind : 'unknown'
        if (isUserInterrupt(reason)) return [at('interrupted')]
        return kind === 'completed' ? [at('finished')] : [at('failed', describeFailure(kind, reason?.error))]
      }
      default:
        return []
    }
  }

  /** The task stopped without a `turn/end` (e.g. DSH closed the stream): one FAILED, unless ended. */
  abandon(text: string, timeMs: number): Milestone[] {
    if (this.ended) return []
    this.ended = true
    return [{ kind: 'failed', text, todos: this.todos.map((t) => ({ ...t })), timeMs }]
  }

  private ours(turn: number | undefined): boolean {
    return this.turn === undefined || turn === undefined || turn === this.turn
  }

  private diffTodos(next: TodoItem[], at: (kind: MilestoneKindName, text?: string) => Milestone): Milestone[] {
    const before = this.todos
    const prior = new Map<string, TodoStatusName>()
    for (const t of before) if (!prior.has(t.content)) prior.set(t.content, t.status)
    const itemsChanged = before.length !== next.length || before.some((t, i) => t.content !== next[i].content)

    this.todos = next.map((t) => ({ ...t }))
    const out: Milestone[] = []
    if (itemsChanged && next.length > 0) out.push(at('planned'))
    // Done before started: "ticked A, now on B" reads in that order.
    for (const t of next) {
      if (t.status === 'completed' && prior.get(t.content) !== 'completed' && prior.has(t.content)) {
        out.push(at('todoDone', t.content))
      }
    }
    for (const t of next) {
      if (t.status === 'in_progress' && prior.get(t.content) !== 'in_progress') out.push(at('todoStarted', t.content))
    }
    if (itemsChanged && next.length === 0 && before.length > 0) out.push(at('planned'))
    return out
  }
}
