/**
 * S17 · structured transcript (PLAN.md §5 S17, ARCHITECTURE D61): a deterministic fold over one
 * DSH session's follow stream into transcript blocks. No model, no invented text (the same rule
 * as D11): a block carries DSH's own data, and the app words each row itself.
 *
 * Inputs are the `sessionController.follow` frames of DSH 0.2.2-rc.1:
 *   assistant-stream chunk `reasoning-delta`  → THINKING, RUNNING, at the first one of a block
 *   the end of that reasoning (its `block-end`, the next text or tool-call chunk, or the end of
 *   the attempt)                              → THINKING, DONE, duration by DSH's chunk `time`s
 *   durable `tool/call`                       → TOOL, RUNNING: name, target from the arguments
 *   durable `tool/result`                     → TOOL, DONE or FAILED: lines added and removed
 *                                               from the result's diff (`meta.diffs`)
 * Everything else is ignored. Payloads without the expected shape are ignored too, so a DSH
 * upgrade degrades to fewer rows rather than a broken task.
 */

export type BlockStateName = 'running' | 'done' | 'failed'

export interface ThinkingOut {
  durationMs: number
  text: string
  truncated: boolean
}

export interface ToolOut {
  tool: string
  target: string
  linesAdded: number
  linesRemoved: number
  arguments: string
  argumentsTruncated: boolean
  error: string
}

export interface BlockOut {
  blockId: string
  state: BlockStateName
  /** When DSH recorded the start of the block, Unix ms. */
  timeMs: number
  thinking?: ThinkingOut
  tool?: ToolOut
}

export const THINKING_TEXT_LIMIT = 8000
export const ARGUMENTS_LIMIT = 4000

/** DSH's agent question tool; its call shows as the question card instead (D92). */
export const QUESTION_TOOL = 'ask_user_question'

/** Argument keys that name what a call acts on, in order of preference. */
const TARGET_KEYS = ['file_path', 'path', 'filePath', 'command', 'pattern', 'url', 'query', 'cwd'] as const

/** The target of one call from its raw arguments JSON; '' when they name none. */
export function toolTarget(rawArguments: string): string {
  let args: unknown
  try { args = JSON.parse(rawArguments) } catch { return '' }
  if (typeof args !== 'object' || args === null || Array.isArray(args)) return ''
  const record = args as Record<string, unknown>
  for (const key of TARGET_KEYS) {
    const value = record[key]
    if (typeof value === 'string' && value.trim()) return firstLine(value)
  }
  // apply_patch: the first file the patch names.
  for (const value of Object.values(record)) {
    if (typeof value !== 'string') continue
    const match = /^\*\*\* (?:Update|Add|Delete) File: (.+)$/m.exec(value)
    if (match) return match[1].trim()
  }
  return ''
}

function firstLine(value: string): string {
  const line = value.trim().split('\n', 1)[0]
  return line.length > 200 ? line.slice(0, 200) : line
}

function lines(text: string): string[] {
  if (text === '') return []
  const out = text.split('\n')
  if (out[out.length - 1] === '') out.pop()
  return out
}

/**
 * Lines added and removed between two texts, by a longest common subsequence of lines. The inputs
 * are DSH's hunks (the change plus three lines of context), so they stay small.
 */
export function countChanges(oldText: string | null, newText: string): { added: number; removed: number } {
  const a = oldText === null ? [] : lines(oldText)
  const b = lines(newText)
  if (a.length * b.length > 4_000_000) return { added: b.length, removed: a.length }
  let prev = new Array<number>(b.length + 1).fill(0)
  for (let i = 1; i <= a.length; i++) {
    const row = new Array<number>(b.length + 1).fill(0)
    for (let j = 1; j <= b.length; j++) {
      row[j] = a[i - 1] === b[j - 1] ? prev[j - 1] + 1 : Math.max(prev[j], row[j - 1])
    }
    prev = row
  }
  const common = prev[b.length]
  return { added: b.length - common, removed: a.length - common }
}

/** Lines added and removed in a `tool/result` meta: `diffs` of `{ oldText, newText }` (dsh-tool-fs). */
export function diffCounts(meta: unknown): { added: number; removed: number } {
  const diffs = (meta as { diffs?: unknown } | null)?.diffs
  const total = { added: 0, removed: 0 }
  if (!Array.isArray(diffs)) return total
  for (const d of diffs) {
    const { oldText, newText } = (d ?? {}) as { oldText?: unknown; newText?: unknown }
    if (typeof newText !== 'string' || (oldText !== null && typeof oldText !== 'string')) continue
    const counts = countChanges(oldText as string | null, newText)
    total.added += counts.added
    total.removed += counts.removed
  }
  return total
}

function cut(text: string, limit: number): [string, boolean] {
  return text.length > limit ? [text.slice(0, limit), true] : [text, false]
}

interface OpenThinking {
  blockId: string
  start: number
  last: number
  text: string
}

export class TranscriptMapper {
  private thinking?: OpenThinking
  private attempt = 0
  private readonly tools = new Map<string, BlockOut>()

  /** One assistant-stream frame: `start`, `chunk` (with DSH's `time`) or `end`. */
  stream(frame: unknown): BlockOut[] {
    const f = frame as { type?: unknown; time?: unknown; chunk?: unknown; attemptId?: unknown } | null
    if (f?.type === 'start') {
      this.attempt += 1
      return this.closeThinking(undefined)
    }
    if (f?.type === 'end') return this.closeThinking(undefined)
    if (f?.type !== 'chunk') return []
    const time = typeof f.time === 'number' ? f.time : undefined
    const chunk = f.chunk as { type?: unknown; index?: unknown; text?: unknown; block?: { type?: unknown } } | null
    if (chunk?.type === 'reasoning-delta' && typeof chunk.text === 'string') {
      if (this.thinking) {
        this.thinking.text += chunk.text
        if (time !== undefined) this.thinking.last = time
        return []
      }
      if (!chunk.text.trim()) return []
      const at = time ?? Date.now()
      const attempt = typeof f.attemptId === 'string' ? f.attemptId : String(this.attempt)
      this.thinking = { blockId: `thinking-${attempt}-${String(chunk.index ?? 0)}`, start: at, last: at, text: chunk.text }
      return [this.thinkingBlock('running', 0)]
    }
    if (chunk?.type === 'block-end' && chunk.block?.type === 'reasoning') return this.closeThinking(time)
    if (chunk?.type === 'text-delta' || chunk?.type === 'tool-call-delta'
      || (chunk?.type === 'block-start' && (chunk as { blockType?: unknown }).blockType !== 'reasoning')) {
      return this.closeThinking(time)
    }
    return []
  }

  /** One durable event (`tool/call`, `tool/result`); others are ignored. */
  event(event: { type: string; time?: number; data: unknown }): BlockOut[] {
    if (event.type === 'tool/call') {
      const { callId, name, arguments: raw } = (event.data ?? {}) as { callId?: unknown; name?: unknown; arguments?: unknown }
      if (typeof callId !== 'string' || typeof name !== 'string') return []
      // The question card stands for this call (questions.v1); a tool row would repeat it.
      if (name === QUESTION_TOOL) return this.closeThinking(event.time)
      const rawArguments = typeof raw === 'string' ? raw : ''
      const [args, truncated] = cut(rawArguments, ARGUMENTS_LIMIT)
      const block: BlockOut = {
        blockId: callId, state: 'running', timeMs: event.time ?? Date.now(),
        tool: { tool: name, target: toolTarget(rawArguments), linesAdded: 0, linesRemoved: 0,
          arguments: args, argumentsTruncated: truncated, error: '' },
      }
      this.tools.set(callId, block)
      return [...this.closeThinking(event.time), structuredClone(block)]
    }
    if (event.type === 'tool/result') {
      const data = (event.data ?? {}) as { message?: { toolCallId?: unknown; isError?: unknown }; meta?: unknown; error?: { reason?: unknown } }
      const callId = data.message?.toolCallId
      if (typeof callId !== 'string') return []
      const block = this.tools.get(callId)
      if (!block?.tool) return []
      const failed = data.message?.isError === true
      const { added, removed } = diffCounts(data.meta)
      block.state = failed ? 'failed' : 'done'
      block.tool.linesAdded = added
      block.tool.linesRemoved = removed
      block.tool.error = failed && typeof data.error?.reason === 'string' ? data.error.reason : ''
      this.tools.delete(callId)
      return [structuredClone(block)]
    }
    return []
  }

  /** The stream ended (turn end, abort): close what is still open. */
  finish(time?: number): BlockOut[] {
    return this.closeThinking(time)
  }

  private closeThinking(time: number | undefined): BlockOut[] {
    if (!this.thinking) return []
    const end = Math.max(time ?? this.thinking.last, this.thinking.last)
    const block = this.thinkingBlock('done', end - this.thinking.start)
    this.thinking = undefined
    return [block]
  }

  private thinkingBlock(state: BlockStateName, durationMs: number): BlockOut {
    const t = this.thinking!
    const [text, truncated] = cut(t.text, THINKING_TEXT_LIMIT)
    return { blockId: t.blockId, state, timeMs: t.start, thinking: { durationMs: Math.max(0, durationMs), text, truncated } }
  }
}
