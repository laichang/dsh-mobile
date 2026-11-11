import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { once } from 'node:events'
import { chmodSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { request } from 'node:https'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { setTimeout as delay } from 'node:timers/promises'
import { test } from 'node:test'
import { DshTasks } from '../src/dsh.ts'
import { SUPPORTED_DSH } from '../src/compatibility.ts'
import { QuestionHolder } from '../src/questions/holder.ts'
import { startBridgeServer } from '../src/server.ts'
import { offerSocket } from '../src/tls/local-offers.ts'
import { FakeDSH } from './fake-dsh.ts'
import { connectDevice, issue, redeem } from './tls-client.ts'

test('local offers, enrollment, restart, authenticated dispatch and revocation', { timeout: 30000 }, async t => {
  const dir = mkdtempSync(join(tmpdir(), 'dshm-enrollment-'))
  const dsh = new FakeDSH(), tasks = new DshTasks(dsh, dir)
  const start = async () => {
    const bridge = await startBridgeServer({ host: '127.0.0.1', port: 0, tlsStateDir: dir, tasks,
      questions: new QuestionHolder(() => {}), dshVersion: SUPPORTED_DSH })
    const address = '127.0.0.1:' + bridge.port
    return { bridge, address }
  }
  let { bridge, address } = await start()
  const ipcDir = dirname(offerSocket(dir))
  t.after(async () => { await bridge.close(); rmSync(ipcDir, { recursive: true, force: true }); rmSync(dir, { recursive: true, force: true }) })
  assert.equal(statSync(ipcDir).mode & 0o777, 0o700)
  assert.equal(statSync(offerSocket(dir)).mode & 0o777, 0o600)
  chmodSync(ipcDir, 0o755)
  try { await assert.rejects(issue(dir)) } finally { chmodSync(ipcDir, 0o700) }
  const [first, second, interrupted] = await Promise.all([issue(dir), issue(dir), issue(dir)])
  assert.ok(first.toString() !== second.toString())
  const results = await Promise.allSettled([redeem(dir, first), redeem(dir, first)])
  assert.equal(results.filter(x => x.status === 'fulfilled').length, 1)
  const winner = results.find(x => x.status === 'fulfilled')!
  const a = winner.value, b = await redeem(dir, second)
  assert.ok(a.id !== b.id && a.bearer !== b.bearer)
  const expired = await issue(dir, 0.0001)
  await delay(10)
  await assert.rejects(redeem(dir, expired))
  assert.ok(!readFileSync(join(dir, 'tls/devices.json'), 'utf8').includes(a.bearer))
  const lostReply = await issue(dir)
  const header = 'Offer ' + lostReply.searchParams.get('i') + '.' + lostReply.searchParams.get('s')
  await new Promise<void>((resolve, reject) => {
    const req = request('https://' + address + '/enroll', { method: 'POST', ca: readFileSync(join(dir, 'tls/host-cert.pem')),
      headers: { authorization: header } }, res => {
      if (res.statusCode !== 201) { reject(new Error('expected enrollment')); return }
      res.destroy()
      resolve()
    })
    req.once('error', reject).end()
  })
  await assert.rejects(redeem(dir, lostReply))
  await bridge.close()
  ;({ bridge, address } = await start())
  interrupted.searchParams.set('a', address)
  await assert.rejects(redeem(dir, interrupted))
  await redeem(dir, await issue(dir))
  await assert.rejects(connectDevice(dir, address, 'invalid'))
  const c = await connectDevice(dir, address, a.bearer, ['questions.v1'])
  const d = await connectDevice(dir, address, b.bearer)
  await Promise.all([c, d].map(p => p.rpc({ case: 'resume', value: {} })))
  const emitQuestion = () => bridge.hub.questionChanged({ taskId: 'task', id: 'question', questions: [] })
  emitQuestion()
  await Promise.all([c, d].map(p => p.rpc({ case: 'listTasks', value: {} })))
  const hasQuestion = (p: typeof c) => p.events.some(f => f.kind.case === 'event' && f.kind.value.body.case === 'questionPending')
  assert.ok(hasQuestion(c) && !hasQuestion(d))
  const unsupported = await d.rpc({ case: 'answerQuestion', value: { id: 'question' } })
  assert.ok(unsupported.case === 'error' && unsupported.value.code === 'request/unsupported')
  const newer = await connectDevice(dir, address, b.bearer, ['questions.v1'])
  await newer.rpc({ case: 'resume', value: {} })
  assert.ok(hasQuestion(newer))

  const image = Buffer.from('fixture image bytes')
  async function stage(p: typeof c, id: string, complete: boolean) {
    const begin = await p.rpc({ case: 'uploadBegin', value: { uploadId: id, name: 'photo.png', mediaType: 'image/png',
      size: BigInt(image.length), sha256: createHash('sha256').update(image).digest() } })
    assert.equal(begin.case, 'uploadAck')
    await p.rpc({ case: 'uploadChunk', value: { uploadId: id, data: image } })
    if (complete) assert.equal((await p.rpc({ case: 'uploadEnd', value: { uploadId: id } })).case, 'uploadStaged')
  }
  for (const [id, complete] of [['partial', false], ['staged', true]] as const) await stage(d, id, complete)
  d.ws.close()
  await once(d.ws, 'close')
  for (const id of ['partial', 'staged']) {
    const failed = await newer.rpc({ case: 'createTask', value: { prompt: 'test', uploadIds: [id] } })
    assert.ok(failed.case === 'error' && failed.value.code === 'upload/unknown')
  }
  await stage(newer, 'photo', true)
  const begun = await newer.rpc({ case: 'createTask', value: { prompt: 'describe', uploadIds: ['photo'] } })
  assert.equal(begun.case, 'taskCreated')
  await stage(newer, 'next', true)
  const accepted = await newer.rpc({ case: 'sendMessage', value: { taskId: begun.value.taskId, text: 'more', uploadIds: ['next'] } })
  assert.equal(accepted.case, 'messageAccepted')
  assert.deepEqual(dsh.stagedImages.map(i => [i.name, i.mediaType, Buffer.from(i.data)]),
    Array(2).fill(['photo.png', 'image/png', image]))

  const same = await connectDevice(dir, address, b.bearer)
  const closed = Promise.all([same, newer].map(p => once(p.ws, 'close')))
  const racing = connectDevice(dir, address, b.bearer).then(async p => {
    if (p.ws.readyState !== p.ws.CLOSED) await once(p.ws, 'close')
  }, () => {})
  assert.equal((await c.rpc({ case: 'revokeDevice', value: { deviceId: b.id } })).case, 'deviceList')
  for (const [code] of await closed) assert.equal(code, 4003)
  await racing
  await assert.rejects(connectDevice(dir, address, b.bearer))
  const audit = await c.rpc({ case: 'listAudit', value: {} })
  assert.ok(audit.case === 'auditPage' && audit.value.entries.some(e => e.action === 'Device revoked' && e.device === a.id && e.detail === b.id))
  c.ws.close()
})
