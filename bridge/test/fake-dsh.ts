/**
 * FakeDSH: an in-memory stand-in for the DSH 0.2.2-rc.1 services the bridge uses
 * (`workspaceController`, `sessionController`). It replays the frame shapes real DSH emits on
 * `sessionController.follow`: snapshot, `turn/start`, assistant-stream start/chunk(text-delta)/end,
 * `assistant/message`, `turn/end`. No network, no model.
 * S3: `events` adds durable projection events (`todo/write`, `plan/mode`, `llm/retry`, …) to every
 * turn, between `turn/start` and the reply, each with its own `seq` and `time`.
 * S17: `reasoning` streams timed `reasoning-delta` chunks before the reply, and `tools` adds a
 * durable `tool/call` and `tool/result` pair for each call after it.
 * D101: the session's inbox, as real DSH keeps it (measured against DSH 0.2.2-rc.1): a prompt to an
 * idle session starts a turn; while a turn runs, `queue` waits for the next turn (one turn per
 * message, in order) and `steer` for the next step of this turn (after the reply streams). Each
 * message enters the turn as a `user/message` with its `requestId` as `source.rpcId`. `state()`
 * lists what waits; `updateQueue` steers or removes an item. A cancel keeps the inbox, and nothing
 * then runs by itself.
 */
import type { Selection } from '../src/models/catalog.ts'
import type { DshServices, FollowFrame, PromptPart } from '../src/dsh.ts'
import type { AskAnswer, AskItem, QuestionRequest } from '../src/questions/holder.ts'

type QuestionHandler = (this: unknown, req: QuestionRequest, next: () => Promise<AskAnswer>) => Promise<AskAnswer>

export interface FakeDSHOptions {
  /** Text deltas the agent "streams" for every prompt. */
  reply?: string[]
  /** Per turn of a session (1 = the first prompt): the deltas of that turn, instead of `reply`. */
  replies?: Record<number, string[]>
  /** D101: the deltas of a step that steered messages start (default: the turn's reply). */
  stepReply?: string[]
  /** End the turn with this reason instead of `completed`. */
  failWith?: { kind: string; error?: { message: string } }
  /** Make `sessionController.create` reject. */
  createError?: string
  /** Durable events the agent appends during the turn, in order (S3). `turn` is added to `data`. */
  events?: { type: string; data: Record<string, unknown> }[]
  /** Wait this long before each text delta (default 0: the whole turn runs at once). */
  chunkDelayMs?: number
  /** S17: reasoning deltas streamed before the reply; chunk `time`s are `reasoningStepMs` apart (default 1000). */
  reasoning?: string[]
  reasoningStepMs?: number
  /** S17: tool calls after the reply, each a durable `tool/call` then its `tool/result`. */
  tools?: FakeToolCall[]
  /**
   * Agent questions: the turn calls `ask_user_question` with these items first, through the
   * `user-questions/request` waterfall (`on` / `waterfall` below), and waits for the answer. The
   * reply then names the chosen labels: "Using <label>." (or "No answer." when the ask failed).
   */
  ask?: AskItem[]
}

/** S17: one tool call and its result, as dsh-tool-fs and dsh-tool-bash record them. */
export interface FakeToolCall {
  callId: string
  name: string
  arguments: string
  /** The result's `meta`, e.g. `{ diffs: [{ path, oldText, newText }] }`. */
  meta?: unknown
  isError?: boolean
  reason?: string
}

/** D101: one message in a session's inbox. */
interface InboxItem { id: string; rpcId?: string; text: string }

interface FakeSession {
  followers: Channel<FollowFrame>[]
  seq: number
  /** The latest turn that started. */
  turn: number
  abort?: AbortController
  /** D101: a turn runs now. */
  running: boolean
  /** D101: messages for the next step of the running turn, and for the next turns. */
  nextStep: InboxItem[]
  nextTurn: InboxItem[]
  /** Turns a cancel stopped: they emit nothing more. */
  stopped: Set<number>
}

/** A DSH Remote error with its `code`, as `sessionController` throws it. */
function remoteError(code: string, message: string): Error {
  return Object.assign(new Error(message), { code, name: 'RemoteError' })
}

/** `time` of the first event; each later event is one second on. */
export const FAKE_DSH_EPOCH_MS = 1_793_000_000_000

class Channel<T> {
  private items: T[] = []
  private waiters: ((r: IteratorResult<T>) => void)[] = []
  private closed = false
  push(item: T) {
    const w = this.waiters.shift()
    if (w) w({ value: item, done: false }); else this.items.push(item)
  }
  close() {
    this.closed = true
    for (const w of this.waiters.splice(0)) w({ value: undefined, done: true })
  }
  async *[Symbol.asyncIterator](): AsyncGenerator<T> {
    while (true) {
      if (this.items.length) { yield this.items.shift()!; continue }
      if (this.closed) return
      const r = await new Promise<IteratorResult<T>>((resolve) => this.waiters.push(resolve))
      if (r.done) return
      yield r.value
    }
  }
}

export class FakeDSH implements DshServices {
  readonly interrupts: string[] = []
  readonly workspaces: string[] = []
  readonly sessionWorkspaces: string[] = []
  readonly workspaceRegistry = {
    // DSH titles a new Workspace after its final path segment.
    list: () => this.workspaces.map((path, index) => ({ path, title: path.split('/').at(-1), updatedAt: new Date(index).toISOString() })),
  }
  readonly prompts: { sessionId: string; text: string }[] = []
  /** D95: every prompt's content parts, in order (text and staged files). */
  readonly promptParts: { sessionId: string; parts: readonly PromptPart[] }[] = []
  /** D95: images staged through `fileUploads.uploadImageStream`, by receipt. */
  readonly stagedImages: { sessionId: string; receiptId: string; mediaType: string; name?: string; data: Uint8Array }[] = []
  /** D107: other files staged through `fileUploads.uploadStream`, by receipt. */
  readonly stagedFiles: { sessionId: string; receiptId: string; name?: string; data: Uint8Array }[] = []
  /** Every receipt in the order it was staged, images and files. */
  private readonly receipts: { sessionId: string; receiptId: string }[] = []
  /** The `mode` and `requestId` of each prompt, in the order of `prompts`. */
  readonly promptOptions: { mode?: string; requestId?: string }[] = []
  /** D101: every `updateQueue` call, in order. */
  readonly queueEdits: { sessionId: string; itemId: string; action: string }[] = []
  private sessions = new Map<string, FakeSession>()
  private nextItem = 1
  private answerers: QuestionHandler[] = []
  /** Answers each `ask` got, in order. */
  readonly answers: AskAnswer[] = []

  /** The Cordis seam of `user-questions/request`: `prepend` registers ahead of the others. */
  on(name: 'user-questions/request', handler: QuestionHandler, options?: { prepend?: boolean }): () => void {
    if (options?.prepend) this.answerers.unshift(handler); else this.answerers.push(handler)
    return () => { this.answerers = this.answerers.filter(h => h !== handler) }
  }

  waterfall(_scope: unknown, _name: 'user-questions/request', req: QuestionRequest, last: () => Promise<AskAnswer>): Promise<AskAnswer> {
    const chain = [...this.answerers]
    const at = (i: number): Promise<AskAnswer> => i < chain.length ? chain[i].call(this, req, () => at(i + 1)) : last()
    return at(0)
  }
  private nextId = 1

  constructor(private readonly options: FakeDSHOptions = {}) {}

  workspaceController = {
    create: async (request: { path: string }) => {
      this.workspaces.push(request.path)
      return { workspace: { workspaceId: `ws-${this.workspaces.length}` } }
    },
  }

  readonly catalog = {
    groups: [{ id: 'provider', name: 'Provider Name', models: [{
      id: 'model', name: 'Model Name', reasoning: {
        efforts: [{ id: 'low', name: 'Low' }, { id: 'high', name: 'High' }], defaultEffort: 'low',
      },
    }] }],
    default: { provider: 'provider', model: 'model', reasoningEffort: 'low' },
    routableProviders: ['provider'], failures: [],
  }

  fileUploads = {
    uploadImageStream: async (request: { sessionId: string; data: AsyncIterable<Uint8Array>; mediaType: string; name?: string }) => {
      this.session(request.sessionId)
      const parts: Uint8Array[] = []
      for await (const part of request.data) parts.push(part)
      const receiptId = `receipt-${this.receipts.length + 1}`
      this.receipts.push({ sessionId: request.sessionId, receiptId })
      this.stagedImages.push({ sessionId: request.sessionId, receiptId, mediaType: request.mediaType, name: request.name,
        data: new Uint8Array(Buffer.concat(parts)) })
      return { receiptId }
    },
    uploadStream: async (request: { sessionId: string; data: AsyncIterable<Uint8Array>; name?: string }) => {
      this.session(request.sessionId)
      const parts: Uint8Array[] = []
      for await (const part of request.data) parts.push(part)
      const receiptId = `receipt-${this.receipts.length + 1}`
      this.receipts.push({ sessionId: request.sessionId, receiptId })
      this.stagedFiles.push({ sessionId: request.sessionId, receiptId, name: request.name, data: new Uint8Array(Buffer.concat(parts)) })
      return { receiptId }
    },
  }

  sessionController = {
    modelCatalog: async () => this.catalog,
    selectModel: async ({ sessionId, ...selection }: Selection & { sessionId: string }) => {
      this.session(sessionId)
      if (selection.provider !== 'provider' || selection.model !== 'model'
          || (selection.reasoningEffort !== undefined && !['low', 'high'].includes(selection.reasoningEffort))) {
        throw new Error('Select an available model before sending a message.')
      }
      this.emitEvent(sessionId, 'model/selection', selection)
      return { selected: selection }
    },
    create: async (request: { workspaceId: string }) => {
      this.sessionWorkspaces.push(request.workspaceId)
      if (this.options.createError) throw new Error(this.options.createError)
      const sessionId = `session-${this.nextId++}`
      this.sessions.set(sessionId, { followers: [], seq: 0, turn: 0, running: false, nextStep: [], nextTurn: [], stopped: new Set() })
      return { sessionId }
    },

    cancel: (request: { sessionId: string }) => {
      const session = this.session(request.sessionId)
      this.interrupts.push(request.sessionId)
      session.abort?.abort()
      session.stopped.add(session.turn)
      session.running = false
      this.emitEvent(request.sessionId, 'turn/end', { turn: session.turn, reason: { kind: 'aborted', reason: { kind: 'user' } } })
      return { accepted: true as const }
    },

    prompt: async (
      request: { sessionId: string; mode?: string; requestId?: string; content: readonly PromptPart[] },
      _signal: AbortSignal,
    ) => {
      const s = this.session(request.sessionId)
      for (const part of request.content) {
        if (part.type === 'file' && !this.receipts.some((i) => i.receiptId === part.receiptId && i.sessionId === request.sessionId)) {
          throw new Error(`unknown receipt ${part.receiptId}`)
        }
      }
      const text = request.content.map((c) => (c.type === 'text' ? c.text : '')).join('')
      this.prompts.push({ sessionId: request.sessionId, text })
      this.promptParts.push({ sessionId: request.sessionId, parts: request.content })
      this.promptOptions.push({ mode: request.mode, requestId: request.requestId })
      const item: InboxItem = { id: `item-${this.nextItem++}`, rpcId: request.requestId, text }
      if (s.running) {
        // D101: a running turn takes a steer at its next step; a queued message waits for its own turn.
        if (request.mode === 'steer') s.nextStep.push(item); else s.nextTurn.push(item)
      } else {
        this.startTurn(request.sessionId, item)
      }
      return { accepted: true as const }
    },

    state: async (request: { sessionId: string }, _signal: AbortSignal) => {
      const s = this.session(request.sessionId)
      return { running: s.running, queue: [
        ...s.nextStep.map(i => ({ id: i.id, placement: 'steering' as const, rpcId: i.rpcId, content: [{ type: 'text', text: i.text }] })),
        ...s.nextTurn.map(i => ({ id: i.id, placement: 'queued' as const, rpcId: i.rpcId, content: [{ type: 'text', text: i.text }] })),
      ] }
    },

    updateQueue: async (request: { sessionId: string; itemId: string; action: { kind: 'steer' } | { kind: 'remove' } }) => {
      const s = this.session(request.sessionId)
      this.queueEdits.push({ sessionId: request.sessionId, itemId: request.itemId, action: request.action.kind })
      const list = [s.nextTurn, s.nextStep].find(l => l.some(i => i.id === request.itemId))
      if (!list) throw remoteError('session/queue-item-not-found', 'queued item is no longer pending')
      const at = list.findIndex(i => i.id === request.itemId)
      if (request.action.kind === 'steer') {
        if (!s.running) throw remoteError('session/steer-unavailable', 'current turn no longer accepts steering')
        if (list === s.nextStep) return { accepted: true as const }
        s.nextStep.push(...list.splice(at, 1))
      } else {
        list.splice(at, 1)
      }
      return { accepted: true as const }
    },

    follow: (
      request: { address: { kind: 'session'; sessionId: string } },
      signal: AbortSignal,
    ): AsyncIterable<FollowFrame> => {
      const s = this.session(request.address.sessionId)
      const ch = new Channel<FollowFrame>()
      ch.push({ type: 'snapshot' })
      s.followers.push(ch)
      signal.addEventListener('abort', () => ch.close(), { once: true })
      return ch
    },
  }

  private session(id: string) {
    const s = this.sessions.get(id)
    if (!s) throw new Error(`no such session ${id}`)
    return s
  }

  private emitEvent(sessionId: string, type: string, data: unknown) {
    this.emit(sessionId, (seq) => ({ type: 'event', event: { type, seq, time: FAKE_DSH_EPOCH_MS + seq * 1000, data } }))
  }

  private emit(sessionId: string, frame: FollowFrame | ((seq: number) => FollowFrame)) {
    const s = this.session(sessionId)
    const f = typeof frame === 'function' ? frame(++s.seq) : frame
    for (const ch of s.followers) ch.push(f)
  }

  /** D101: an idle session takes `item` as a new turn, asynchronously, like the real agent loop. */
  private startTurn(sessionId: string, item: InboxItem) {
    const s = this.session(sessionId)
    s.running = true
    const turn = ++s.turn
    setImmediate(() => void this.runTurn(sessionId, turn, item))
  }

  private userMessage(sessionId: string, turn: number, item: InboxItem) {
    this.emitEvent(sessionId, 'user/message', { turn, role: 'user', id: item.id, content: [{ type: 'text', text: item.text }],
      source: { kind: 'user', ...(item.rpcId === undefined ? {} : { rpcId: item.rpcId }) } })
  }

  /** Streams one model response of the turn. False once a cancel stopped the turn. */
  private async stream(sessionId: string, turn: number, step: number, reply: string[]): Promise<boolean> {
    const s = this.session(sessionId)
    const delay = this.options.chunkDelayMs ?? 0
    this.emit(sessionId, { type: 'assistant-stream', frame: { type: 'start' } })
    for (const text of reply) {
      if (delay > 0) await new Promise((r) => setTimeout(r, delay))
      if (s.stopped.has(turn)) return false
      this.emit(sessionId, { type: 'assistant-stream', frame: { type: 'chunk', chunk: { type: 'text-delta', index: 0, text } } })
    }
    this.emit(sessionId, { type: 'assistant-stream', frame: { type: 'end' } })
    this.emit(sessionId, (seq) => ({
      type: 'event',
      event: { type: 'assistant/message', seq, data: { turn, step, message: { content: [{ type: 'text', text: reply.join('') }] } } },
    }))
    return true
  }

  private async runTurn(sessionId: string, turn: number, item: InboxItem) {
    const s = this.session(sessionId)
    let reply = this.options.replies?.[turn] ?? this.options.reply ?? ['Hello', ' from', ' FakeDSH.']
    this.emitEvent(sessionId, 'turn/start', { turn })
    this.userMessage(sessionId, turn, item)
    if (this.options.ask) {
      const abort = new AbortController()
      this.session(sessionId).abort = abort
      const callId = `call_ask_${turn}`
      this.emitEvent(sessionId, 'tool/call', { turn, step: 0, callId, name: 'ask_user_question',
        arguments: JSON.stringify({ questions: this.options.ask }) })
      try {
        const answer = await this.waterfall(undefined, 'user-questions/request',
          { questions: this.options.ask, agent: { session: { id: sessionId } }, signal: abort.signal },
          () => Promise.reject(new Error('no user-questions answerer accepted the request')))
        this.answers.push(answer)
        reply = this.options.reply ?? ['Using ', answer.answers.flatMap(a => a.selected).join(', '), '.']
      } catch {
        if (s.stopped.has(turn)) return
        reply = this.options.reply ?? ['No answer.']
      }
      this.emitEvent(sessionId, 'tool/result', { turn, step: 0, message: { role: 'tool', toolCallId: callId, content: [] } })
    }
    for (const e of this.options.events ?? []) this.emitEvent(sessionId, e.type, { turn, ...e.data })
    const delay = this.options.chunkDelayMs ?? 0
    this.emit(sessionId, { type: 'assistant-stream', frame: { type: 'start' } })
    const reasoning = this.options.reasoning ?? []
    const step = this.options.reasoningStepMs ?? 1000
    reasoning.forEach((text, i) => this.emit(sessionId, { type: 'assistant-stream',
      frame: { type: 'chunk', time: FAKE_DSH_EPOCH_MS + i * step, chunk: { type: 'reasoning-delta', index: 0, text } } }))
    if (reasoning.length) {
      this.emit(sessionId, { type: 'assistant-stream', frame: { type: 'chunk', time: FAKE_DSH_EPOCH_MS + reasoning.length * step,
        chunk: { type: 'block-end', index: 0, block: { type: 'reasoning', text: reasoning.join('') } } } })
    }
    for (const text of reply) {
      if (delay > 0) await new Promise((r) => setTimeout(r, delay))
      if (s.stopped.has(turn)) return
      this.emit(sessionId, { type: 'assistant-stream', frame: { type: 'chunk', chunk: { type: 'text-delta', index: 0, text } } })
    }
    this.emit(sessionId, { type: 'assistant-stream', frame: { type: 'end' } })
    this.emit(sessionId, (seq) => ({
      type: 'event',
      event: { type: 'assistant/message', seq, data: { turn, step: 0, message: { content: [{ type: 'text', text: reply.join('') }] } } },
    }))
    // D101: steered messages go in at the next step of this turn, and the agent answers them there.
    for (let next = 1; s.nextStep.length; next++) {
      for (const steered of s.nextStep.splice(0)) this.userMessage(sessionId, turn, steered)
      if (!await this.stream(sessionId, turn, next, this.options.stepReply ?? reply)) return
    }
    for (const call of this.options.tools ?? []) {
      this.emitEvent(sessionId, 'tool/call', { turn, step: 0, callId: call.callId, name: call.name, arguments: call.arguments })
      this.emitEvent(sessionId, 'tool/result', {
        turn, step: 0, message: { role: 'tool', toolCallId: call.callId, content: [], ...(call.isError ? { isError: true } : {}) },
        ...(call.meta === undefined ? {} : { meta: call.meta }),
        ...(call.isError ? { error: { name: 'ToolError', code: 'failed', reason: call.reason ?? '' } } : {}),
      })
    }
    if (s.stopped.has(turn)) return
    const reason = this.options.failWith ?? { kind: 'completed' }
    s.running = false
    this.emitEvent(sessionId, 'turn/end', { turn, reason })
    // D101: the next queued message runs as its own turn.
    const queued = s.nextTurn.shift()
    if (queued && reason.kind === 'completed') this.startTurn(sessionId, queued)
    else if (queued) s.nextTurn.unshift(queued)
  }
}
