/**
 * Command-line stand-in for the app: Hello, CreateTask, print the streamed reply.
 *   node lib/scripts/client.js [--port 47801] "prompt"                    plaintext (dev, loopback)
 *   node lib/scripts/client.js --identity id.json --pair 'dshm://pair?…' "prompt"   pair over Noise
 *   node lib/scripts/client.js --identity id.json "prompt"                reconnect over Noise
 * The identity file holds this client's Noise static key and the paired host (created by --pair).
 * Milestones (S3) go to stderr as `client: milestone <seq> <KIND> [<todos as P/I/C>] <text>`.
 * Exit 0 when the task ends COMPLETED, 1 otherwise.
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { create, fromBinary, toBinary } from '@bufbuild/protobuf'
import { WebSocket } from 'ws'
import { FrameSchema, TaskStatus } from '../src/gen/frame_pb.ts'
import { MilestoneKind, TodoStatus } from '../src/gen/milestones_pb.ts'
import { NoiseInitiator, type NoiseSession } from '../src/pairing/handshake.ts'
import { generateKeyPair, keyPairFromSecret } from '../src/pairing/noise.ts'
import { parseOfferURL } from '../src/pairing/offer.ts'
import { b64url, unb64url } from '../src/pairing/wire.ts'
import { PLAINTEXT_PATH } from '../src/server.ts'

const args = process.argv.slice(2)
const take = (name: string) => {
  const i = args.indexOf(name)
  return i >= 0 ? args.splice(i, 2)[1] : undefined
}
const port = Number(take('--port') ?? 47801)
const identityPath = take('--identity')
const pairURL = take('--pair')
const prompt = args.join(' ') || 'Say hello in one sentence.'
const die = (m: string): never => { console.error(`client: ${m}`); process.exit(1) }

interface Identity { secretKey: string; hostKey?: string; address?: string }

let url = `ws://127.0.0.1:${port}${PLAINTEXT_PATH}`
let initiator: NoiseInitiator | undefined
let identity: Identity | undefined
if (identityPath) {
  identity = existsSync(identityPath)
    ? JSON.parse(readFileSync(identityPath, 'utf8')) as Identity
    : { secretKey: b64url(generateKeyPair().secretKey) }
  const s = keyPairFromSecret(unb64url(identity.secretKey))
  if (pairURL) {
    const offer = parseOfferURL(pairURL)
    identity.hostKey = b64url(offer.hostKey)
    identity.address = offer.addresses[0]
    initiator = NoiseInitiator.pair({ s, hostKey: offer.hostKey, offerId: offer.offerId, secret: offer.secret })
  } else {
    if (!identity.hostKey || !identity.address) die(`${identityPath} has no paired host; pass --pair first`)
    initiator = NoiseInitiator.reconnect({ s, hostKey: unb64url(identity.hostKey!) })
  }
  url = `ws://${identity.address}/`
}

const ws = new WebSocket(url)
ws.binaryType = 'nodebuffer'
let session: NoiseSession | undefined
const timer = setTimeout(() => die('timed out'), 120_000)
ws.on('error', (e) => die(e.message))
ws.on('close', (code, reason) => { if (code !== 1000 && code !== 1005) die(`closed ${code} ${reason.toString()}`) })

const send = (init: Parameters<typeof create<typeof FrameSchema>>[1]) => {
  const bytes = toBinary(FrameSchema, create(FrameSchema, init))
  ws.send(session ? session.seal(bytes) : bytes)
}
const start = () => {
  send({ kind: { case: 'request', value: { id: 1n, body: { case: 'hello', value: { protocolVersion: 1 } } } } })
  send({ kind: { case: 'request', value: { id: 2n, body: { case: 'createTask', value: { prompt } } } } })
}

ws.on('open', () => {
  if (initiator) ws.send(initiator.first)
  else start()
})
ws.on('message', (data: Buffer) => {
  let bytes: Uint8Array = new Uint8Array(data)
  if (initiator && !session) {
    session = initiator.finish(bytes)
    console.error(`client: noise ${initiator.mode === 1 ? 'pairing (IKpsk1)' : 'reconnect (IK)'} handshake done`)
    if (identityPath && pairURL) writeFileSync(identityPath, JSON.stringify(identity, null, 2) + '\n', { mode: 0o600 })
    return start()
  }
  if (session) bytes = session.open(bytes)
  const f = fromBinary(FrameSchema, bytes)
  if (f.kind.case === 'response') {
    const b = f.kind.value.body
    if (b.case === 'hello') console.error(`client: bridge protocol ${b.value.protocolVersion} [${b.value.capabilities.join(', ')}]`)
    if (b.case === 'taskCreated') console.error(`client: task ${b.value.taskId}`)
    if (b.case === 'error') die(`error ${b.value.code}: ${b.value.message}`)
  } else if (f.kind.case === 'event') {
    const b = f.kind.value.body
    if (b.case === 'assistantChunk') process.stdout.write(b.value.text)
    if (b.case === 'milestoneAdded') {
      const m = b.value
      const todos = m.todos.map((t) => ({ [TodoStatus.PENDING]: 'P', [TodoStatus.IN_PROGRESS]: 'I', [TodoStatus.COMPLETED]: 'C' } as Record<number, string>)[t.status] ?? '?').join('')
      console.error(`client: milestone ${m.seq} ${MilestoneKind[m.kind]} [${todos}] ${m.text}`)
    }
    if (b.case === 'taskEnded') {
      clearTimeout(timer)
      const ok = b.value.status === TaskStatus.COMPLETED
      console.error(`\nclient: task ended ${TaskStatus[b.value.status]}${b.value.message ? `: ${b.value.message}` : ''}`)
      ws.close()
      process.exit(ok ? 0 : 1)
    }
  }
})
