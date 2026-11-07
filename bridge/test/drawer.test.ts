/**
 * S14 · the drawer (PLAN.md §5 S14). The bridge sends each session's workspace (TaskSummary
 * field 280) for a phone session and for a Web session, and both frames are the golden fixtures
 * that the Swift tests decode too.
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { describe, test } from 'node:test'
import { create, toBinary, toJson } from '@bufbuild/protobuf'
import { DshTasks } from '../src/dsh.ts'
import { FrameSchema } from '../src/gen/frame_pb.ts'
import { HostLog, type LoggedEvent } from '../src/s2/host-log.ts'
import { TaskHub } from '../src/s2/task-hub.ts'
import { SessionDirectory, type SessionReader } from '../src/sessions/directory.ts'
import { FakeDSH } from './fake-dsh.ts'
import { FIXTURES_DIR } from './fixtures.ts'

const AT = 1_793_000_000_000

/** The frame the server forwards for one logged event (server.ts `forward`). */
function frameOf(event: LoggedEvent) {
  return create(FrameSchema, { kind: { case: 'event', value: { hostSeq: event.seq, body: event.body } } })
}

function upserts(log: HostLog, taskId: string) {
  return log.since(log.logId, 0n).events.filter(e => e.taskId === taskId && e.body?.case === 'taskUpserted')
}

function golden(name: string) {
  return new Uint8Array(readFileSync(`${FIXTURES_DIR}/${name}.binpb`))
}

/** One finished Web turn in a DSH journal, listed with the session's `cwd`. */
function webReader(cwd: Record<string, string>): SessionReader {
  const journal = [
    { type: 'turn/start', seq: 0, time: AT, data: { turn: 1 } },
    { type: 'user/message', seq: 1, time: AT + 1000, data: { source: { kind: 'user' }, content: [{ type: 'text', text: '网页第一条' }] } },
    { type: 'assistant/message', seq: 2, time: AT + 2000, data: { message: { content: [{ type: 'text', text: '已收到。' }] } } },
    { type: 'turn/end', seq: 3, time: AT + 3000, data: { turn: 1, reason: { kind: 'completed' } } },
  ]
  return {
    async list() {
      return { items: Object.entries(cwd).map(([sessionId, dir]) => ({ sessionId, cwd: dir, blank: false, running: false, updatedAt: AT })) }
    },
    async events({ address }) {
      const records = address.sessionId === 'web-1' ? journal : []
      return { cursor: records.length ? 3 : 0, hasMore: false, records: records.map(event => ({ event })) }
    },
  }
}

describe('DrawerWorkspaces', () => {
  test('phoneAndWebSessionsCarryTheirWorkspaceAsTheGoldenFixtures', async () => {
    const dsh = new FakeDSH({ reply: ['已收到。'] })
    const hub = new TaskHub(new DshTasks(dsh, '/home/user'), new HostLog(), () => AT)
    // A phone session in a chosen workspace, and one in the host's default.
    await hub.create('修复 CI 挂掉的测试', undefined, undefined, '/work/app')
    await hub.create('Translate: Bonjour.')
    await hub.close()
    const phone = upserts(hub.log, 'session-1')[0]
    assert.equal(phone.body?.case === 'taskUpserted' && phone.body.value.task?.workspace, '/work/app')
    assert.deepEqual(toBinary(FrameSchema, frameOf(phone)), golden('s14_phone_session_upserted_event'),
      JSON.stringify(toJson(FrameSchema, frameOf(phone))))
    assert.equal(hub.list().find(t => t.taskId === 'session-2')?.workspace, '/home/user')

    // A Web session in the same workspace: the bridge reads DSH's `cwd` from the session list.
    const webHub = new TaskHub(new DshTasks(new FakeDSH(), '/home/user'), new HostLog(), () => AT)
    const directory = new SessionDirectory(webReader({ 'web-1': '/work/app' }), webHub, assert.fail)
    await directory.reconcile()
    const web = upserts(webHub.log, 'web-1').at(-1)!
    assert.equal(web.body?.case === 'taskUpserted' && web.body.value.task?.workspace, '/work/app')
    // S27: the same frame with the latest turn's start (`turn_started_at_ms`); S14's golden is the
    // frame from an older bridge, which the app still reads.
    assert.deepEqual(toBinary(FrameSchema, frameOf(web)), golden('s27_web_session_upserted_event'),
      JSON.stringify(toJson(FrameSchema, frameOf(web))))
    directory.close()
    await webHub.close()
  })

  test('dshCwdWinsOverThePhonePathOnceTheSessionIsListed', async () => {
    const dsh = new FakeDSH()
    const hub = new TaskHub(new DshTasks(dsh, '/home/user'), new HostLog(), () => AT)
    await hub.create('Show the repo name', undefined, undefined, '/tmp/app')
    // DSH resolves the directory (for example /tmp → /private/tmp on macOS).
    const directory = new SessionDirectory(webReader({ 'session-1': '/private/tmp/app' }), hub, assert.fail)
    await directory.reconcile()
    assert.equal(hub.list().find(t => t.taskId === 'session-1')?.workspace, '/private/tmp/app')
    // A later listing without a cwd keeps what the bridge knows.
    hub.observeSession('session-1', 99n, 'Show the repo name', hub.list()[0].state, '', BigInt(AT), BigInt(AT))
    assert.equal(hub.list().find(t => t.taskId === 'session-1')?.workspace, '/private/tmp/app')
    directory.close()
    await hub.close()
  })
})
