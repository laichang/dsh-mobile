import { randomUUID } from 'node:crypto'
import type { ApprovalAuditRecord } from './audit.ts'

export interface Pending { id: string; taskId: string; callId: string; tool: string; argumentsJson: string; reason: string }
export interface Resolved { id: string; taskId: string; outcome: 'ALLOWED' | 'DENIED' | 'CANCELLED' | 'TIMEOUT' }
type Outcome = 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'
interface Block { type: string; id?: string; name?: string; arguments?: string }
export interface ApprovalRequest {
  agent: { session: { id: string; deriveMessages(): { role: string; content: Block[] }[] } }
  callId?: string
  toolName: string
  reason?: string
  signal?: AbortSignal
}
export interface ApprovalContext {
  on(name: 'approval/request', handler: (this: unknown, req: ApprovalRequest, next: () => Promise<Outcome>) => Promise<Outcome>,
    options: { prepend: true }): () => void
  waterfall(scope: unknown, name: 'approval/request', req: ApprovalRequest, next: () => Promise<Outcome>): Promise<Outcome>
}

function details(req: ApprovalRequest): Pending {
  let args = ''
  // The committed assistant message is the source of the tool call that DSH is now executing.
  if (req.callId) {
    for (const msg of req.agent.session.deriveMessages().reverse()) {
      if (msg.role !== 'assistant') continue
      const call = msg.content.find(b => b.type === 'tool-call' && b.id === req.callId && b.name === req.toolName)
      if (call) { args = call.arguments ?? ''; break }
    }
  }
  return { id: randomUUID(), taskId: req.agent.session.id, callId: req.callId ?? '', tool: req.toolName,
    argumentsJson: args, reason: req.reason ?? '' }
}

export class ApprovalHolder {
  private readonly pending = new Map<string, { request: Pending; finish: (outcome: Resolved['outcome'], by: string, device: string) => Resolved }>()
  private readonly copies = new WeakSet<ApprovalRequest>()

  constructor(private readonly appendAudit: (record: ApprovalAuditRecord) => void, private readonly change: (event: Pending | Resolved) => void,
    private readonly timeoutMs = 86_400_000) {
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 2_147_483_647) throw new Error('invalid approval timeout')
  }

  register(ctx: ApprovalContext) {
    const holder = this
    return ctx.on('approval/request', function (req, next) {
      if (holder.copies.has(req)) return next()
      return holder.hold(req, copy => ctx.waterfall(this, 'approval/request', copy, async () => 'unavailable'))
    }, { prepend: true })
  }

  hold(req: ApprovalRequest, downstream: (copy: ApprovalRequest) => Promise<Outcome>): Promise<Outcome> {
    const request = details(req)
    const fanout = new AbortController()
    return new Promise(resolve => {
      const finish = (outcome: Resolved['outcome'], by: string, device: string): Resolved => {
        const resolved = { id: request.id, taskId: request.taskId, outcome }
        if (!this.pending.delete(request.id)) return resolved
        clearTimeout(timer)
        req.signal?.removeEventListener('abort', cancel)
        fanout.abort()
        // Persist before releasing the tool. A failed audit write can never grant permission.
        try {
          this.appendAudit({ when: new Date().toISOString(), by, device, ...request,
            outcome })
        } catch (error) {
          console.error('dsh-mobile: approval audit write failed', error)
          resolved.outcome = 'CANCELLED'
        }
        this.change(resolved)
        resolve(resolved.outcome === 'ALLOWED' ? 'allowed-once' :
          resolved.outcome === 'CANCELLED' ? 'cancelled' : 'rejected')
        return resolved
      }
      const cancel = () => finish('CANCELLED', 'host', 'DSH')
      const timer = setTimeout(() => finish('TIMEOUT', 'timeout', 'bridge'), this.timeoutMs)
      this.pending.set(request.id, { request, finish })
      this.change(request)
      if (req.signal?.aborted) { cancel(); return }
      req.signal?.addEventListener('abort', cancel, { once: true })
      const copy = { ...req, signal: fanout.signal }
      this.copies.add(copy)
      // An unavailable or disconnected downstream leaves the request held for a paired phone.
      Promise.resolve().then(() => fanout.signal.aborted ? 'cancelled' : downstream(copy)).then(answer => {
        if (answer === 'allowed-once') finish('ALLOWED', 'owner', 'DSH client')
        if (answer === 'rejected') finish('DENIED', 'owner', 'DSH client')
      }).catch(() => {})
    })
  }

  answer(id: string, allow: boolean, device: string): Resolved {
    const pending = this.pending.get(id)
    if (!pending) throw new Error('This approval has already closed.')
    if (allow && !pending.request.argumentsJson) throw new Error('Operation details are unavailable.')
    return pending.finish(allow ? 'ALLOWED' : 'DENIED', 'owner', device)
  }

  cancelTask(taskId: string, device: string) {
    for (const item of this.pending.values()) {
      if (item.request.taskId === taskId) item.finish('CANCELLED', 'interrupt', device)
    }
  }

  close() {
    for (const item of this.pending.values()) item.finish('CANCELLED', 'shutdown', 'bridge')
  }
}
