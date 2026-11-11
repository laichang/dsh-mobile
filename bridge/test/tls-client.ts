// A second enrolled device for integration tests, using the fixture's local certificate as its trusted anchor.
import { execFile } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { request } from 'node:https'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { setTimeout as sleep } from 'node:timers/promises'
import { once } from 'node:events'
import { WebSocket } from 'ws'
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { FrameSchema, type Frame, type RequestSchema } from '../src/gen/frame_pb.ts'

export async function issue(dir: string, ttlMinutes = 10) {
  const { stdout } = await promisify(execFile)(process.execPath, ['lib/scripts/pair.js', '--url-only', '--state-dir', dir,
    '--ttl-minutes', String(ttlMinutes)])
  return new URL(stdout.trim())
}

export async function redeem(dir: string, offer: URL) {
  const address = offer.searchParams.get('a')!.split(',')[0]
  const authorization = 'Offer ' + offer.searchParams.get('i') + '.' + offer.searchParams.get('s')
  return new Promise<{ id: string; bearer: string }>((resolve, reject) => {
    const req = request('https://' + address + '/enroll', { ca: readFileSync(join(dir, 'tls/host-cert.pem')),
      method: 'POST', headers: { authorization } }, res => {
      let data = ''
      res.on('data', b => { data += b })
      res.on('end', () => res.statusCode === 201 ? resolve(JSON.parse(data)) : reject(new Error('enrollment refused')))
    })
    req.on('error', reject)
    req.end()
  })
}

export async function connectDevice(dir: string, address: string, bearer: string, capabilities: string[] = []) {
  const ws = new WebSocket('wss://' + address + '/', { ca: readFileSync(join(dir, 'tls/host-cert.pem')),
    headers: { authorization: 'Bearer ' + bearer } })
  await once(ws, 'open')
  let id = 0n
  const events: Frame[] = []
  ws.on('message', data => {
    const frame = fromBinary(FrameSchema, new Uint8Array(data as Buffer))
    if (frame.kind.case === 'event') events.push(frame)
  })
  async function rpc(body: MessageInitShape<typeof RequestSchema>['body']) {
    const tag = ++id
    const reply = new Promise<Extract<Frame['kind'], { case: 'response' }>['value']['body']>((resolve, reject) => {
      const cleanup = () => { ws.off('message', onMessage); ws.off('close', onClose) }
      const onClose = () => { cleanup(); reject(new Error('socket closed')) }
      const onMessage = (bytes: Buffer) => {
        const frame = fromBinary(FrameSchema, bytes)
        if (frame.kind.case === 'response' && frame.kind.value.requestId === tag) {
          cleanup(); resolve(frame.kind.value.body)
        }
      }
      ws.on('message', onMessage)
      ws.once('close', onClose)
    })
    ws.send(toBinary(FrameSchema, create(FrameSchema, { kind: { case: 'request', value: { id: tag, body } } })))
    return reply
  }
  await rpc({ case: 'hello', value: { protocolVersion: 1, capabilities } })
  return { ws, rpc, events }
}

if (import.meta.main) {
  const dir = process.argv[2], offer = await issue(dir), own = await redeem(dir, offer)
  const peer = await connectDevice(dir, offer.searchParams.get('a')!.split(',')[0], own.bearer)
  if (process.argv[3] === 'seed-task') {
    const task = await peer.rpc({ case: 'createTask', value: { prompt: 'Second enrolled host cache check' } })
    if (task.case !== 'taskCreated') throw new Error('second host could not start task')
    const ended = () => peer.events.some(f => f.kind.case === 'event' && f.kind.value.body.case === 'taskEnded')
    for (let n = 0; !ended() && n < 400; n++) await sleep(100)
    if (!ended()) throw new Error('second host task did not finish')
  } else {
    const list = await peer.rpc({ case: 'listDevices', value: {} })
    if (list.case !== 'deviceList') throw new Error('list devices failed')
    const phones = list.value.devices.filter(d => d.id !== own.id)
    if (phones.length !== 1) throw new Error('expected one enrolled phone before offline revoke')
    const result = await peer.rpc({ case: 'revokeDevice', value: { deviceId: phones[0].id } })
    if (result.case !== 'deviceList') throw new Error('revoke failed')
  }
  peer.ws.close()
}
