import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test, type TestContext } from 'node:test'
import { ApprovalHolder, type ApprovalRequest, type Pending, type Resolved } from '../src/approvals/holder.ts'
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
  const holder = new ApprovalHolder(audit, e => { events.push(e); changed?.(e) }, timeout)
  return { audit, holder, events }
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
