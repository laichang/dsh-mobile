/**
 * FakeDSH: an in-memory stand-in for the DSH 0.2.2-rc.1 services the bridge uses
 * (`workspaceController`, `sessionController`). It replays the frame shapes real DSH emits on
 * `sessionController.follow`: snapshot, `turn/start`, assistant-stream start/chunk(text-delta)/end,
 * `assistant/message`, `turn/end`. No network, no model.
 * S3: `events` adds durable projection events (`todo/write`, `plan/mode`, `llm/retry`, …) to every
 * turn, between `turn/start` and the reply, each with its own `seq` and `time`.
 */
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
  readonly workspaces: string[] = []
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

  sessionController = {
    create: async (_request: { workspaceId: string }) => {
      if (this.options.createError) throw new Error(this.options.createError)
      const sessionId = `session-${this.nextId++}`
      this.sessions.set(sessionId, { followers: [], seq: 0, turn: 0 })
      return { sessionId }
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
    for (const text of reply) {
      if (delay > 0) await new Promise((r) => setTimeout(r, delay))
      this.emit(sessionId, { type: 'assistant-stream', frame: { type: 'chunk', chunk: { type: 'text-delta', index: 0, text } } })
    }
    this.emit(sessionId, { type: 'assistant-stream', frame: { type: 'end' } })
    this.emit(sessionId, (seq) => ({
      type: 'event',
      event: { type: 'assistant/message', seq, data: { turn, step: 0, message: { content: [{ type: 'text', text: reply.join('') }] } } },
    }))
    const reason = this.options.failWith ?? { kind: 'completed' }
    this.emitEvent(sessionId, 'turn/end', { turn, reason })
  }
}
