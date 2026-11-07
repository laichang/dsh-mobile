import assert from 'node:assert/strict'
import test from 'node:test'
import { SessionDirectory, type SessionReader } from '../src/sessions/directory.ts'
import { TaskHub } from '../src/s2/task-hub.ts'
import { TaskState } from '../src/gen/s2_pb.ts'

test('webSessionsBeforeAndAfterPairingAndPhoneTaskHaveOneHostRowEach', async () => {
  const hub = new TaskHub({ interrupt() {}, async start() { return { taskId: 'phone', output: (async function* () {})() } } })
  type JournalEvent = { type: string; seq: number; time: number; data: unknown }
  const journals = new Map<string, JournalEvent[]>()
  function turn(id: string, text: string) {
    const events = journals.get(id) ?? []
    journals.set(id, events)
    function emit(type: string, data: unknown) { events.push({ type, data, seq: events.length, time: events.length + 1 }) }
    emit('turn/start', {})
    emit('user/message', { source: { kind: 'user' }, content: [{ type: 'text', text }] })
    emit('user/message', { source: { kind: 'runtime' }, content: [{ type: 'text', text: 'private instructions' }] })
    emit('assistant/message', { message: { content: [{ type: 'text', text: 'reply ' + text }] } })
    emit('turn/end', { reason: { kind: 'completed' } })
  }
  const reader: SessionReader = {
    async list() { return { items: [...journals.keys()].map(sessionId => ({ sessionId, blank: false, running: false, updatedAt: 1 })) } },
    async events({ address, beforeSeq, throughSeq }) {
      const journal = journals.get(address.sessionId)!
      const cursor = throughSeq ?? journal.length - 1
      const start = Math.max(0, (beforeSeq ?? cursor + 1) - 6)
      return { cursor, hasMore: start > 0, records: journal.slice(start, beforeSeq ?? cursor + 1).map(event => ({ event })) }
    },
  }
  const directory = new SessionDirectory(reader, hub, assert.fail)
  turn('web-before', 'first')
  await directory.reconcile()
  assert.deepEqual(hub.list().map(row => row.title), ['first'])
  hub.observeSession('web-after', 0n, 'web-after', TaskState.RUNNING, '', 0n, 0n) // turn/start precedes human text
  turn('web-after', 'after')
  directory.changed('web-after', journals.get('web-after')!.at(-1)!)
  turn('phone', 'phone prompt')
  await directory.reconcile() // journal wins the race with CreateTask
  await hub.create('phone prompt')
  await directory.reconcile()
  assert.deepEqual(hub.list().map(row => row.taskId).sort(), ['phone', 'web-after', 'web-before'])
  assert.equal(hub.list().find(row => row.taskId === 'web-after')?.title, 'after')
  assert.equal(hub.list().find(row => row.taskId === 'phone')?.externalSession, false)
  await assert.rejects(directory.read('unlisted'), /Unknown DSH session/)
  turn('web-before', 'second')
  await directory.reconcile()
  const latest = await directory.read('web-before')
  turn('web-before', 'after cut')
  const older = await directory.read('web-before', latest.nextBeforeSeq, latest.throughSeq)
  assert.deepEqual([...older.messages, ...latest.messages].map(m => m.text), ['first', 'reply first', 'second', 'reply second'])
  assert.equal(hub.list().find(row => row.taskId === 'web-before')?.state, TaskState.COMPLETED)
  assert.equal(hub.list().find(row => row.taskId === 'web-before')?.latestReply, 'reply second')
  const events = journals.get('web-before')!
  events.push({ type: 'session/title', seq: events.length, time: 44, data: { source: { kind: 'user' }, title: 'Release notes' } })
  await directory.reconcile()
  assert.equal(hub.list().find(row => row.taskId === 'web-before')?.title, 'Release notes')
  // Real-iPhone finding (2026-11-07): DSH titles a session after its first turn, and Web shows that
  // title; the phone showed the prompt. DSH's generated title now replaces the prompt, also for a phone task.
  const phone = journals.get('phone')!
  phone.push({ type: 'session/title', seq: phone.length, time: 45, data: { source: { kind: 'generated' }, title: 'AI身份询问' } })
  directory.changed('phone', phone.at(-1)!)
  await directory.reconcile()
  assert.equal(hub.list().find(row => row.taskId === 'phone')?.title, 'AI身份询问')
  directory.close()
  await hub.close()
})
