/**
 * Agent questions (ARCHITECTURE D18, D92). DSH's `ask_user_question` tool dispatches the
 * `user-questions/request` waterfall. The bridge answers first (`prepend`), holds the request for a
 * paired phone, and fans a copy out to the rest of the chain (the DSH Web/desktop forwarder), as
 * the approval holder does (D17). The first answer wins; the other copy is withdrawn. The holder
 * never answers by itself: the task waits until a person answers or the turn ends.
 */
import { randomUUID } from 'node:crypto'
import { QuestionOutcome, type QuestionPending, type QuestionResolved } from '../gen/questions_pb.ts'

export type Pending = Omit<QuestionPending, '$typeName' | '$unknown' | 'questions'> & {
  questions: { id: string; text: string; header: string; detail: string; multiSelect: boolean;
    options: { label: string; description: string }[] }[]
}
export type Answer = { questionId: string; selected: string[] }
export type Resolved = Omit<QuestionResolved, '$typeName' | '$unknown' | 'answers'> & { answers: Answer[] }

/** Subset of DSH's `AskUserQuestionItem` (`@deepseek-ai/dsh-user-questions/types`). */
export interface AskItem {
  id: string
  question: string
  header?: string
  detail?: string
  options?: { label: string; description?: string }[]
  multiSelect?: boolean
}
/** DSH's `AskUserQuestionAnswer`: the model gets it verbatim as the tool result. */
export interface AskAnswer { answers: { id: string; selected: string[]; custom?: string }[] }
export interface QuestionRequest {
  questions: readonly AskItem[]
  agent?: { session: { id: string } }
  signal?: AbortSignal
}
export interface QuestionContext {
  on(name: 'user-questions/request', handler: (this: unknown, req: QuestionRequest, next: () => Promise<AskAnswer>) => Promise<AskAnswer>,
    options: { prepend: true }): () => void
  waterfall(scope: unknown, name: 'user-questions/request', req: QuestionRequest, next: () => Promise<AskAnswer>): Promise<AskAnswer>
}

class QuestionCancelled extends Error {
  readonly code = 'ASK_ABORTED'
  constructor() { super('the question was cancelled before an answer') }
}

function pending(taskId: string, items: readonly AskItem[]): Pending {
  return { id: randomUUID(), taskId, questions: items.map(q => ({
    id: q.id, text: q.question, header: q.header ?? '', detail: q.detail ?? '', multiSelect: q.multiSelect === true,
    options: (q.options ?? []).map(o => ({ label: o.label, description: o.description ?? '' })),
  })) }
}

export class QuestionHolder {
  private readonly pending = new Map<string, { request: Pending; finish: (outcome: QuestionOutcome, answers: Answer[]) => Resolved }>()
  private readonly copies = new WeakSet<QuestionRequest>()

  constructor(private readonly change: (event: Pending | Resolved) => void) {}

  register(ctx: QuestionContext) {
    const holder = this
    return ctx.on('user-questions/request', function (req, next) {
      // A question with no session (a tool outside an agent) has no task to show it on.
      if (holder.copies.has(req) || !req.agent) return next()
      return holder.hold(req, copy => ctx.waterfall(this, 'user-questions/request', copy, () =>
        Promise.reject(new Error('no other user-questions answerer'))))
    }, { prepend: true })
  }

  hold(req: QuestionRequest, downstream: (copy: QuestionRequest) => Promise<AskAnswer>): Promise<AskAnswer> {
    const request = pending(req.agent?.session.id ?? '', req.questions)
    const fanout = new AbortController()
    return new Promise((resolve, reject) => {
      const finish = (outcome: QuestionOutcome, answers: Answer[]): Resolved => {
        const resolved: Resolved = { id: request.id, taskId: request.taskId, outcome, answers }
        if (!this.pending.delete(request.id)) return resolved
        req.signal?.removeEventListener('abort', cancel)
        fanout.abort()
        this.change(resolved)
        if (outcome === QuestionOutcome.CANCELLED) reject(new QuestionCancelled())
        else resolve({ answers: answers.map(a => ({ id: a.questionId, selected: a.selected })) })
        return resolved
      }
      const cancel = () => finish(QuestionOutcome.CANCELLED, [])
      this.pending.set(request.id, { request, finish })
      this.change(request)
      if (req.signal?.aborted) { cancel(); return }
      req.signal?.addEventListener('abort', cancel, { once: true })
      const copy = { ...req, signal: fanout.signal }
      this.copies.add(copy)
      // No other answerer, or one that went away, leaves the question held for a paired phone.
      Promise.resolve().then(() => fanout.signal.aborted ? undefined : downstream(copy)).then(answer => {
        if (answer && !fanout.signal.aborted) {
          finish(QuestionOutcome.ANSWERED_ELSEWHERE, answer.answers.map(a => ({ questionId: a.id,
            selected: a.custom ? [...a.selected, a.custom] : a.selected })))
        }
      }).catch(() => {})
    })
  }

  /** A phone's answer: one choice of the offered options for each question. */
  answer(id: string, answers: Answer[]): Resolved {
    const held = this.pending.get(id)
    if (!held) throw new Error('This question has already closed.')
    const questions = held.request.questions
    if (answers.length !== questions.length) throw new Error('Answer every question.')
    for (const q of questions) {
      const a = answers.find(x => x.questionId === q.id)
      if (!a || a.selected.length === 0) throw new Error('Answer every question.')
      if (!q.multiSelect && a.selected.length !== 1) throw new Error('Choose one option.')
      if (a.selected.some(label => !q.options.some(o => o.label === label))) throw new Error('Choose one of the offered options.')
    }
    return held.finish(QuestionOutcome.ANSWERED, questions.map(q => answers.find(a => a.questionId === q.id)!))
  }

  cancelTask(taskId: string) {
    for (const item of this.pending.values()) {
      if (item.request.taskId === taskId) item.finish(QuestionOutcome.CANCELLED, [])
    }
  }

  close() {
    for (const item of this.pending.values()) item.finish(QuestionOutcome.CANCELLED, [])
  }
}
