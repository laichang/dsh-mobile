import { randomUUID } from 'node:crypto'
import { appendFileSync } from 'node:fs'
import { ApprovalOutcome, type ApprovalPending, type ApprovalResolved } from '../gen/approvals_pb.ts'

export type Pending = Omit<ApprovalPending, '$typeName' | '$unknown'>
export type Resolved = Omit<ApprovalResolved, '$typeName' | '$unknown'>
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
  private readonly pending = new Map<string, { request: Pending; finish: (outcome: ApprovalOutcome, by: string, device: string) => Resolved }>()
  private readonly copies = new WeakSet<ApprovalRequest>()

  constructor(private readonly auditFile: string, private readonly change: (event: Pending | Resolved) => void,
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
      const finish = (outcome: ApprovalOutcome, by: string, device: string): Resolved => {
        const resolved = { id: request.id, taskId: request.taskId, outcome }
        if (!this.pending.delete(request.id)) return resolved
        clearTimeout(timer)
        req.signal?.removeEventListener('abort', cancel)
        fanout.abort()
        // Persist before releasing the tool. A failed audit write can never grant permission.
        try {
          appendFileSync(this.auditFile, JSON.stringify({ when: new Date().toISOString(), by, device, ...request,
            outcome: ApprovalOutcome[outcome] }) + '\n', { mode: 0o600 })
        } catch (error) {
          console.error('dsh-mobile: approval audit write failed', error)
          resolved.outcome = ApprovalOutcome.CANCELLED
        }
        this.change(resolved)
        resolve(resolved.outcome === ApprovalOutcome.ALLOWED ? 'allowed-once' :
          resolved.outcome === ApprovalOutcome.CANCELLED ? 'cancelled' : 'rejected')
        return resolved
      }
      const cancel = () => finish(ApprovalOutcome.CANCELLED, 'host', 'DSH')
      const timer = setTimeout(() => finish(ApprovalOutcome.TIMEOUT, 'timeout', 'bridge'), this.timeoutMs)
      this.pending.set(request.id, { request, finish })
      this.change(request)
      if (req.signal?.aborted) { cancel(); return }
      req.signal?.addEventListener('abort', cancel, { once: true })
      const copy = { ...req, signal: fanout.signal }
      this.copies.add(copy)
      // An unavailable or disconnected downstream leaves the request held for a paired phone.
      Promise.resolve().then(() => fanout.signal.aborted ? 'cancelled' : downstream(copy)).then(answer => {
        if (answer === 'allowed-once') finish(ApprovalOutcome.ALLOWED, 'owner', 'DSH client')
        if (answer === 'rejected') finish(ApprovalOutcome.DENIED, 'owner', 'DSH client')
      }).catch(() => {})
    })
  }

  answer(id: string, allow: boolean, device: string): Resolved {
    const pending = this.pending.get(id)
    if (!pending) throw new Error('This approval has already closed.')
    if (allow && !pending.request.argumentsJson) throw new Error('Operation details are unavailable.')
    return pending.finish(allow ? ApprovalOutcome.ALLOWED : ApprovalOutcome.DENIED, 'owner', device)
  }

  cancelTask(taskId: string, device: string) {
    for (const item of this.pending.values()) {
      if (item.request.taskId === taskId) item.finish(ApprovalOutcome.CANCELLED, 'interrupt', device)
    }
  }

  close() {
    for (const item of this.pending.values()) item.finish(ApprovalOutcome.CANCELLED, 'shutdown', 'bridge')
  }
}
