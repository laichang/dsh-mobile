/**
 * FakeDSH: an in-memory stand-in for the DSH 0.2.2-rc.1 services the bridge uses
 * (`workspaceController`, `sessionController`). It replays the frame shapes real DSH emits on
 * `sessionController.follow`: snapshot, `turn/start`, assistant-stream start/chunk(text-delta)/end,
 * `assistant/message`, `turn/end`. No network, no model.
 * S3: `events` adds durable projection events (`todo/write`, `plan/mode`, `llm/retry`, …) to every
 * turn, between `turn/start` and the reply, each with its own `seq` and `time`.
 * S17: `reasoning` streams timed `reasoning-delta` chunks before the reply, and `tools` adds a
 * durable `tool/call` and `tool/result` pair for each call after it.
 */
import type { Selection } from '../src/models/catalog.ts'
import type { DshServices, FollowFrame } from '../src/dsh.ts'

export interface FakeDSHOptions {
  /** Text deltas the agent "streams" for every prompt. */
  reply?: string[]
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
  private sessions = new Map<string, { followers: Channel<FollowFrame>[]; seq: number; turn: number }>()
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
      this.sessions.set(sessionId, { followers: [], seq: 0, turn: 0 })
      return { sessionId }
    },

    cancel: (request: { sessionId: string }) => {
      const session = this.session(request.sessionId)
      this.interrupts.push(request.sessionId)
      this.emitEvent(request.sessionId, 'turn/end', { turn: session.turn, reason: { kind: 'aborted', reason: { kind: 'user' } } })
      return { accepted: true as const }
    },

    prompt: async (
      request: { sessionId: string; content: readonly { type: 'text'; text: string }[] },
      _signal: AbortSignal,
    ) => {
      const s = this.session(request.sessionId)
      this.prompts.push({ sessionId: request.sessionId, text: request.content.map((c) => c.text).join('') })
      const turn = ++s.turn
      // Run the turn asynchronously, like the real agent loop: prompt() returns on admission.
      setImmediate(() => void this.runTurn(request.sessionId, turn))
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

  private async runTurn(sessionId: string, turn: number) {
    const reply = this.options.reply ?? ['Hello', ' from', ' FakeDSH.']
    this.emitEvent(sessionId, 'turn/start', { turn })
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
      if (this.interrupts.includes(sessionId)) return
      this.emit(sessionId, { type: 'assistant-stream', frame: { type: 'chunk', chunk: { type: 'text-delta', index: 0, text } } })
    }
    this.emit(sessionId, { type: 'assistant-stream', frame: { type: 'end' } })
    this.emit(sessionId, (seq) => ({
      type: 'event',
      event: { type: 'assistant/message', seq, data: { turn, step: 0, message: { content: [{ type: 'text', text: reply.join('') }] } } },
    }))
    for (const call of this.options.tools ?? []) {
      this.emitEvent(sessionId, 'tool/call', { turn, step: 0, callId: call.callId, name: call.name, arguments: call.arguments })
      this.emitEvent(sessionId, 'tool/result', {
        turn, step: 0, message: { role: 'tool', toolCallId: call.callId, content: [], ...(call.isError ? { isError: true } : {}) },
        ...(call.meta === undefined ? {} : { meta: call.meta }),
        ...(call.isError ? { error: { name: 'ToolError', code: 'failed', reason: call.reason ?? '' } } : {}),
      })
    }
    const reason = this.options.failWith ?? { kind: 'completed' }
    this.emitEvent(sessionId, 'turn/end', { turn, reason })
  }
}
