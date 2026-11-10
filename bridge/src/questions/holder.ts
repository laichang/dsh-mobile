/**
 * Agent questions. DSH's `ask_user_question` tool dispatches the
 * `user-questions/request` waterfall. The bridge answers first (`prepend`), holds the request for a
 * paired phone, and fans a copy out to the rest of the chain (the DSH Web/desktop forwarder), as
 * the approval holder does. The first answer wins; the other copy is withdrawn. The holder
 * never answers by itself: the task waits until a person answers or the turn ends. An answer names
 * offered options, or is typed text (DSH's free-text `custom` answer), or both when multi-select.
 */
import { randomUUID } from 'node:crypto'
import { QuestionOutcome, type QuestionPending, type QuestionResolved } from '../gen/questions_pb.ts'

export type Pending = Omit<QuestionPending, '$typeName' | '$unknown' | 'questions'> & {
  questions: { id: string; text: string; header: string; detail: string; multiSelect: boolean;
    options: { label: string; description: string }[] }[]
}
/** One question's answer: chosen labels, and the text the user typed instead (or as well). */
export type Answer = { questionId: string; selected: string[]; custom?: string }
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
        else resolve({ answers: answers.map(a => ({ id: a.questionId, selected: a.selected, ...(a.custom ? { custom: a.custom } : {}) })) })
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
            selected: a.selected, ...(a.custom ? { custom: a.custom } : {}) })))
        }
      }).catch(() => {})
    })
  }

  /**
   * A phone's answer, one for each question: offered options (one, or one or more when the
   * question is multi-select), or typed text, or options and text when multi-select.
   */
  answer(id: string, answers: Answer[]): Resolved {
    const held = this.pending.get(id)
    if (!held) throw new Error('This question has already closed.')
    const questions = held.request.questions
    if (answers.length !== questions.length) throw new Error('Answer every question.')
    const given: Answer[] = []
    for (const q of questions) {
      const a = answers.find(x => x.questionId === q.id)
      const custom = a?.custom?.trim() ?? ''
      if (!a || (a.selected.length === 0 && !custom)) throw new Error('Answer every question.')
      if (new Set(a.selected).size !== a.selected.length) throw new Error('Choose each option once.')
      if (!q.multiSelect && a.selected.length + (custom ? 1 : 0) !== 1) throw new Error('Choose one option, or type an answer.')
      if (a.selected.some(label => !q.options.some(o => o.label === label))) throw new Error('Choose one of the offered options.')
      given.push({ questionId: q.id, selected: [...a.selected], ...(custom ? { custom } : {}) })
    }
    return held.finish(QuestionOutcome.ANSWERED, given)
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
