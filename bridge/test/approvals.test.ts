import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test, type TestContext } from 'node:test'
import { approvalAudit } from '../src/approvals/audit.ts'
import { ApprovalHolder, type ApprovalRequest, type Pending, type Resolved } from '../src/approvals/holder.ts'
import { auditPage } from '../src/devices/manage.ts'
import { ApprovalOutcome } from '../src/gen/approvals_pb.ts'
import { HostLog } from '../src/tasks/host-log.ts'
import { TaskHub } from '../src/tasks/task-hub.ts'

const args = '{"command":"rm /tmp/x"}'
const req: ApprovalRequest = { toolName: 'bash', callId: 'c', reason: 'Confirm delete', agent: { session: {
  id: 'session', deriveMessages: () => [{ role: 'assistant', content: [
    { type: 'tool-call', id: 'other', name: 'bash', arguments: '{"command":"wrong"}' },
    { type: 'tool-call', id: 'c', name: 'bash', arguments: args },
  ] }],
} } }

function setup(t: TestContext, timeout = 10_000, changed?: (e: Pending | Resolved) => void) {
  const dir = mkdtempSync(join(tmpdir(), 'dshm-approval-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  const audit = join(dir, 'approvals.jsonl')
  const events: (Pending | Resolved)[] = []
  const holder = new ApprovalHolder(approvalAudit(dir).append, e => { events.push(e); changed?.(e) }, timeout)
  return { dir, audit, holder, events }
}

test('approvalTimeoutRejectsAndEmitsTimeout', async t => {
  const { holder, events, audit } = setup(t, 10)
  const outcome = await holder.hold(req, async () => 'unavailable')
  assert.equal(outcome, 'rejected')
  assert.equal((events[1] as Resolved).outcome, ApprovalOutcome.TIMEOUT)
  assert.equal(JSON.parse(readFileSync(audit, 'utf8')).by, 'timeout')
})

test('firstAnswerAuditsWhatWhenWhoAndDevice', async t => {
  const { holder, events, audit } = setup(t)
  let withdrawn = false
  const outcome = holder.hold(req, async copy => {
    copy.signal!.addEventListener('abort', () => { withdrawn = true })
    return 'unavailable'
  })
  await Promise.resolve()
  const id = events[0].id
  holder.answer(id, false, 'paired-key-id')
  assert.equal(await outcome, 'rejected')
  assert.ok(withdrawn)
  assert.throws(() => holder.answer(id, true, 'other-phone'), /closed/)
  const web = holder.hold(req, async () => 'allowed-once')
  assert.equal(await web, 'allowed-once')
  const lines = readFileSync(audit, 'utf8').trim().split('\n').map(line => JSON.parse(line))
  assert.equal(lines.length, 2)
  assert.equal(lines[0].argumentsJson, args)
  assert.deepEqual(lines[0], { ...events[0], by: 'owner', device: 'paired-key-id', when: lines[0].when, outcome: 'DENIED' })
  assert.ok(Number.isFinite(Date.parse(lines[0].when)))
  assert.equal(lines[1].outcome, 'ALLOWED')
  assert.equal(lines[1].device, 'DSH client')
})

test('trimmedResumeRetainsPendingAndStaleAnswerCannotReleaseNextRequest', async t => {
  const hub = new TaskHub({ interrupt: () => assert.fail('unexpected interrupt'), start: async () => ({ taskId: 'session', output: (async function* () {})() }) }, new HostLog(1))
  const { holder, events } = setup(t, 10_000, event => hub.approvalChanged(event))
  await hub.create('test')
  const first = holder.hold(req, async () => 'unavailable')
  const oldID = events[0].id
  assert.ok(hub.log.since(hub.log.logId, 1n).reset)
  assert.equal(hub.list()[0].pendingApprovals[0].id, oldID)
  holder.answer(oldID, false, 'phone')
  assert.equal(await first, 'rejected')
  const next = holder.hold(req, async () => 'unavailable')
  assert.throws(() => holder.answer(oldID, true, 'phone'), /closed/)
  assert.notEqual(hub.list()[0].pendingApprovals[0].id, oldID)
  holder.close()
  assert.equal(await next, 'cancelled')
  assert.equal(hub.list()[0].pendingApprovals.length, 0)
})

test('upstreamSessionIsVisibleOnlyWhileAnApprovalIsHeld', async t => {
  const hub = new TaskHub({ interrupt: () => assert.fail('unexpected interrupt'), start: async () => { throw new Error('unexpected bridge task') } })
  const { holder, audit } = setup(t, 10_000, event => hub.approvalChanged(event, true))
  let webAnswer!: (answer: 'allowed-once' | 'rejected') => void
  const web = () => new Promise<'allowed-once' | 'rejected'>(resolve => { webAnswer = resolve })
  const first = holder.hold(req, web)
  await Promise.resolve()
  const row = hub.list()[0]
  assert.equal(row.approvalOnly, true)
  const id = row.pendingApprovals[0].id
  holder.answer(id, false, 'paired-device')
  webAnswer('allowed-once')
  assert.equal(await first, 'rejected')
  assert.deepEqual(hub.list(), [])

  const second = holder.hold(req, web)
  await Promise.resolve()
  webAnswer('rejected')
  assert.equal(await second, 'rejected')
  assert.deepEqual(hub.list(), [])
  const lines = readFileSync(audit, 'utf8').trim().split('\n')
  assert.deepEqual(lines.map(line => JSON.parse(line).device), ['paired-device', 'DSH client'])
})

test('appends to a historical journal and preserves mixed audit pagination', async t => {
  const { dir, audit, holder, events } = setup(t)
  const old = Array.from({ length: 49 }, (_, n) => ({
    when: new Date(100 + n).toISOString(), by: 'owner', device: 'old-phone', id: String(n),
    taskId: 'older-session', callId: 'old-call', tool: 'read', argumentsJson: '', reason: 'example', outcome: 'DENIED',
  }))
  const historical = old.map(row => JSON.stringify(row)).join('\n')
  writeFileSync(audit, historical)
  const pair = { id: 'pair:old', atMs: 101, actor: 'owner', device: 'old-phone', action: 'Device paired', detail: 'old-phone' }
  const revoke = { ...pair, id: 'revoke:old', atMs: 99, action: 'Device revoked' }
  const store = { dir, devices: () => [], pairingHistory: () => [pair, revoke] }
  const previous = auditPage(store, '')
  assert.equal(previous.nextBeforeId, 'approval:0')

  const result = holder.hold(req, async () => 'unavailable')
  holder.answer(events[0].id, true, 'new-phone')
  assert.equal(await result, 'allowed-once')
  const contents = readFileSync(audit, 'utf8')
  assert.ok(contents.startsWith(historical + '\n'))
  const appended = JSON.parse(contents.trimEnd().split('\n').at(-1)!)
  assert.deepEqual(appended, { when: appended.when, by: 'owner', device: 'new-phone', ...events[0], outcome: 'ALLOWED' })
  const first = auditPage(store, '')
  const second = auditPage(store, first.nextBeforeId)
  assert.equal(first.entries.length, 50)
  assert.equal(first.nextBeforeId, pair.id)
  assert.equal(second.nextBeforeId, '')
  const expected = old.reverse().map(row => ({ id: 'approval:' + row.id, atMs: BigInt(Date.parse(row.when)),
    actor: 'owner', device: 'old-phone', action: 'Approval denied', detail: 'read example' }))
  assert.deepEqual([...first.entries, ...second.entries], [
    { id: 'approval:' + events[0].id, atMs: BigInt(Date.parse(appended.when)), actor: 'owner',
      device: 'new-phone', action: 'Approval allowed', detail: 'bash ' + args },
    ...expected.slice(0, -1), { ...pair, atMs: 101n }, expected.at(-1), { ...revoke, atMs: 99n },
  ])
  assert.deepEqual(auditPage(store, previous.nextBeforeId).entries, [{ ...revoke, atMs: 99n }])
})

test('a real journal write failure cancels permission; successful release observes the persisted record', async t => {
  let observed: unknown
  const { audit, holder, events } = setup(t, 10_000, event => {
    if ('outcome' in event && event.outcome === ApprovalOutcome.ALLOWED) observed = JSON.parse(readFileSync(audit, 'utf8'))
  })
  const errors = t.mock.method(console, 'error', () => {})
  mkdirSync(audit)
  const denied = holder.hold(req, async () => 'unavailable')
  assert.equal(holder.answer(events[0].id, true, 'phone').outcome, ApprovalOutcome.CANCELLED)
  assert.equal(await denied, 'cancelled')
  assert.equal(errors.mock.calls[0].arguments[1].code, 'EISDIR')

  rmSync(audit, { recursive: true })
  const allowed = holder.hold(req, async () => 'unavailable')
  assert.equal(holder.answer(events[2].id, true, 'phone').outcome, ApprovalOutcome.ALLOWED)
  assert.equal(await allowed, 'allowed-once')
  assert.deepEqual(observed, { when: JSON.parse(readFileSync(audit, 'utf8')).when, by: 'owner', device: 'phone',
    ...events[2], outcome: 'ALLOWED' })
})
