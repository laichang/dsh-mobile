import { AttachmentKind } from '../gen/attachments_pb.ts'
import { TaskState } from '../gen/s2_pb.ts'
import { describeFailure, isUserInterrupt } from '../milestones/mapper.ts'
import type { TaskHub } from '../s2/task-hub.ts'

interface Row {
  sessionId: string
  blank: boolean
  running: boolean
  updatedAt: number
  /** S14: the session's directory on the host. */
  cwd?: string
  projections?: { kind?: 'sequenced' | 'cached'; asOfSeq?: number; values: { title?: string | null } }
}
interface Event { seq: number; type: string; time: number; data: unknown; surfaceOp?: unknown }
interface Page {
  cursor: number
  hasMore: boolean
  records: readonly { event: Event }[]
}
export interface SessionReader {
  list(request: object, signal: AbortSignal): Promise<{ items: readonly Row[] }>
  events(request: { address: { kind: 'session'; sessionId: string }; beforeSeq?: number; throughSeq?: number;
    maxMessages: number }, signal: AbortSignal): Promise<Page>
}

type Block = { type: string; text?: string; attachment?: { name?: string; bytes?: number; mediaType?: string } }

/** D107: a user message's image and file blocks, as chips. The journal has no media type for a file. */
function attachments(content: readonly Block[] | undefined) {
  return (content ?? []).flatMap(b => b.type === 'image' || b.type === 'file' ? [{
    kind: b.type === 'image' ? AttachmentKind.IMAGE : AttachmentKind.FILE,
    name: b.attachment?.name ?? '', size: BigInt(b.attachment?.bytes ?? 0), mediaType: b.attachment?.mediaType ?? '',
  }] : [])
}

function message(event: Event) {
  if (event.surfaceOp !== undefined && event.surfaceOp !== 'append') return
  const data = event.data as { source?: { kind: string }; content?: Block[]; message?: { content: Block[] } } | null
  const fromUser = event.type === 'user/message' && data?.source?.kind === 'user'
  if (!fromUser && event.type !== 'assistant/message') return
  const content = fromUser ? data?.content : data?.message?.content
  const text = content?.filter(b => b.type === 'text').map(b => b.text).join('') ?? ''
  const files = fromUser ? attachments(content) : []
  if (text || files.length) return { seq: BigInt(event.seq), fromUser, text, attachments: files }
}

/** The pinned DSH controller owns visibility, persistence, and message-aligned backwards pages.
 * Its list and events reads do not activate an agent. Only the currently open detail reads older pages. */
export class SessionDirectory {
  private readonly abort = new AbortController()
  private visible = new Set<string>()
  private readonly dirty = new Set<string>()
  private all = false
  private refresh?: Promise<void>

  constructor(private readonly reader: SessionReader, private readonly hub: TaskHub,
    private readonly log: (message: string) => void) {}

  close() { this.abort.abort() }

  changed(id: string, event: Event) {
    if (!['turn/start', 'turn/end', 'assistant/message', 'session/title'].includes(event.type) && !message(event)) return
    this.dirty.add(id)
    void this.sync().catch(error => { if (!this.abort.signal.aborted) this.log('session refresh: ' + error) })
  }

  reconcile() { this.all = true; return this.sync() }

  private sync() {
    this.refresh ??= this.drain().finally(() => { this.refresh = undefined })
    return this.refresh
  }

  private async drain() {
    while (this.all || this.dirty.size) {
      const all = this.all
      const changed = new Set(this.dirty)
      this.dirty.clear()
      this.all = false
      const { items } = await this.reader.list({}, this.abort.signal)
      this.visible = new Set(items.filter(row => !row.blank).map(row => row.sessionId))
      for (const row of items) {
        if (row.blank || (!all && !changed.has(row.sessionId))) continue
        if (!changed.has(row.sessionId) && row.projections?.kind === 'sequenced' && row.projections.asOfSeq !== undefined &&
            row.projections.asOfSeq === this.hub.sessionRevision(row.sessionId)) continue
        try {
          const page = await this.page(row.sessionId)
          const lastTurn = page.records.findLast(({event}) => event.type === 'turn/end' || event.type === 'turn/start')?.event
          const reason = lastTurn?.type === 'turn/end' ? (lastTurn.data as { reason?: {
            kind?: string; error?: unknown; reason?: { kind?: string } } }).reason : undefined
          const state = reason ? (reason.kind === 'completed' ? TaskState.COMPLETED :
            isUserInterrupt(reason) ? TaskState.INTERRUPTED : TaskState.FAILED) :
            row.running || lastTurn?.type === 'turn/start' ? TaskState.RUNNING : TaskState.COMPLETED
          const messages = page.records.flatMap(r => message(r.event) ?? [])
          const prompt = messages.find(m => m.fromUser)?.text
          const latest = messages.at(-1)
          const reply = state === TaskState.COMPLETED && latest && !latest.fromUser && latest.text.length <= 280 ? latest.text : ''
          const rename = page.records.findLast(({event}) => event.type === 'session/title')?.event.data as
            { source?: { kind?: string }; title?: string } | undefined
          // DSH's title wins once it has one: a user rename, or the title DSH generates after the first
          // turn (Web shows it). Until then the first prompt stands in.
          const hostTitle = rename?.title || row.projections?.values.title || undefined
          const title = page.hasMore ? row.projections?.values.title ?? prompt : prompt ?? row.projections?.values.title
          const at = page.records.at(-1)?.event.time ?? row.updatedAt
          // S27: the latest turn's start, so that the phone's 用时 leaves out the idle time between turns.
          const turnStart = page.records.findLast(({event}) => event.type === 'turn/start')?.event.time ??
            page.records.findLast(({event}) => message(event)?.fromUser)?.event.time
          this.hub.observeSession(row.sessionId, BigInt(page.cursor), title ?? row.sessionId,
            state, state === TaskState.FAILED ? describeFailure(reason?.kind ?? 'unknown', reason?.error) : '',
            BigInt(at), BigInt(page.records[0]?.event.time ?? row.updatedAt), reply, hostTitle, row.cwd,
            turnStart === undefined ? undefined : BigInt(turnStart))
        } catch (error) {
          this.abort.signal.throwIfAborted()
          this.log('cannot read session ' + row.sessionId + ': ' + error)
        }
      }
    }
  }

  private page(id: string, beforeSeq?: number, throughSeq?: number) {
    return this.reader.events({ address: { kind: 'session', sessionId: id }, maxMessages: 32,
      ...(beforeSeq === undefined ? {} : { beforeSeq }), ...(throughSeq === undefined ? {} : { throughSeq }) }, this.abort.signal)
  }

  async read(id: string, before?: bigint, through?: bigint) {
    if (!this.visible.has(id)) throw new Error('Unknown DSH session')
    const page = await this.page(id, before === undefined ? undefined : Number(before),
      through === undefined ? undefined : Number(through))
    const first = page.records[0]?.event.seq
    return { messages: page.records.flatMap(({event}) => message(event) ?? []), throughSeq: through ?? BigInt(page.cursor),
      ...(page.hasMore && first !== undefined ? { nextBeforeSeq: BigInt(first) } : {}) }
  }
}
