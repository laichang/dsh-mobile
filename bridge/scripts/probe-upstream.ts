// Against the real web gateway: observe the same approval on both clients, deny from
// either side, and verify the other copy is withdrawn without executing the tool.
import assert from 'node:assert/strict'
import { on, once } from 'node:events'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocket } from 'ws'
import { issue, redeem } from '../test/tls-client.ts'
import { FrameSchema, type RequestSchema } from '../src/gen/frame_pb.ts'
import { ApprovalDecision, ApprovalOutcome } from '../src/gen/approvals_pb.ts'
import { SUPPORTED_DSH } from '../src/compatibility.ts'

const controlURL = 'http://127.0.0.1:' + process.argv[2]
async function control(path: string, body?: object) {
  const response = await fetch(controlURL + path, { method: body ? 'POST' : 'GET',
    body: body && JSON.stringify(body), signal: AbortSignal.timeout(5000) })
  assert.equal(response.status, 200)
  const result = await response.json()
  assert.ok(!result.error, result.error)
  return result
}

const dir = join(process.env.DSHM_HOME!, 'dsh-mobile-bridge')
const offer = await issue(dir)
const peer = await redeem(dir, offer)
const socket = new WebSocket('wss://' + offer.searchParams.get('a')!.split(',')[0], {
  ca: readFileSync(join(dir, 'tls/host-cert.pem')), headers: { authorization: 'Bearer ' + peer.bearer },
})
const messages = on(socket, 'message', { signal: AbortSignal.timeout(90_000) })
let id = 0n
function send(body: MessageInitShape<typeof RequestSchema>['body']) {
  socket.send(toBinary(FrameSchema, create(FrameSchema, { kind: { case: 'request', value: { id: ++id, body } } })))
}
async function next() {
  const item = await messages.next()
  assert.ok(!item.done)
  const frame = fromBinary(FrameSchema, item.value[0]).kind
  if (frame.case === 'response' && frame.value.body.case === 'error') assert.fail(frame.value.body.value.message)
  return frame
}

try {
  await once(socket, 'open')
  send({ case: 'hello', value: { protocolVersion: 1, capabilities: ['approvals.v1'] } })
  const hello = await next()
  assert.ok(hello.case === 'response' && hello.value.body.case === 'hello')
  assert.equal(hello.value.body.value.dshVersion, process.env.DSHM_PROBE_VERSION)
  assert.equal(hello.value.body.value.supportedDshRange, SUPPORTED_DSH)
  assert.equal(hello.value.body.value.requiresBridgeUpdate, false,
    'The upstream checkout changed DSH version; review compatibility before extending the pin.')
  await control('/fake-web/open', {})
  for (const winner of ['phone', 'web']) {
    send({ case: 'createTask', value: { prompt: 'Test the approval holder.' } })
    let settled = 0
    let pendingId: string | undefined
    for (;;) {
      const frame = await next()
      if (frame.case !== 'event') continue
      const body = frame.value.body
      if (body.case === 'approvalPending') {
        assert.equal(pendingId, undefined)
        pendingId = body.value.id
        const deadline = Date.now() + 5000
        while (!(await control('/state')).gateway?.pending?.length) {
          assert.ok(Date.now() < deadline, 'the web gateway never received the held approval')
          await new Promise(resolve => setTimeout(resolve, 50))
        }
        if (winner === 'phone') send({ case: 'answerApproval', value: { id: pendingId, decision: ApprovalDecision.DENY } })
        else await control('/fake-web/answer', { outcome: 'rejected' })
      }
      if (body.case === 'approvalResolved') {
        assert.equal(body.value.id, pendingId)
        assert.equal(body.value.outcome, ApprovalOutcome.DENIED)
        settled++
      }
      if (body.case === 'taskEnded') break
    }
    assert.equal(settled, 1)
    assert.equal((await control('/state')).gateway.pending.length, 0)
    const audit = readFileSync(join(process.env.DSHM_HOME!, 'dsh-mobile-bridge', 'approvals.jsonl'), 'utf8')
      .trim().split('\n').map(line => JSON.parse(line)).filter(entry => entry.id === pendingId)
    assert.equal(audit.length, 1)
    assert.equal(audit[0].device, winner === 'phone' ? peer.id : 'DSH client')
    console.log('One approval on both clients; ' + winner + ' answered first')
  }
} finally {
  await messages.return?.()
  socket.close()
}
