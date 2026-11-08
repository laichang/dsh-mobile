/**
 * Attachments (ARCHITECTURE D95, D107) against FakeDSH, over the Noise listener: the golden photo
 * (protocol/fixtures/attachments, also read by the Swift tests) goes up in several Noise
 * messages, arrives byte-identical, is staged through `fileUploads`, and enters the first prompt
 * as an image part. Text, PDF and other files enter as file parts with their names, in order, in
 * a first prompt and in a follow-up. A wrong hash, a missing part or a file over the limit is refused.
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, describe, test } from 'node:test'
import { create, fromBinary, toBinary, type MessageInitShape } from '@bufbuild/protobuf'
import { WebSocket } from 'ws'
import { SUPPORTED_DSH } from '../src/compatibility.ts'
import { DshTasks } from '../src/dsh.ts'
import { FrameSchema, RequestSchema, type Frame } from '../src/gen/frame_pb.ts'
import { ATTACHMENTS_CAPABILITY, MAX_UPLOAD_BYTES, MAX_UPLOADS_PER_CONNECTION, PART_SIZE, UploadStaging } from '../src/attachments/staging.ts'
import { AttachmentKind } from '../src/gen/attachments_pb.ts'
import { TaskStatus } from '../src/gen/frame_pb.ts'
import { CONVERSATION_CAPABILITY } from '../src/server.ts'
import { makeOffer } from '../src/pairing/announce.ts'
import { NoiseInitiator, NoiseResponder, type NoiseSession } from '../src/pairing/handshake.ts'
import { generateKeyPair } from '../src/pairing/noise.ts'
import { PairingStore } from '../src/pairing/store.ts'
import { startBridgeServer, type BridgeServer } from '../src/server.ts'
import { FakeDSH } from './fake-dsh.ts'
import { FIXTURES_DIR } from './fixtures.ts'

/** Noise caps one transport message at 65535 bytes, 16 of them the tag (D21). */
const NOISE_MAX_PLAINTEXT = 65535 - 16

interface UploadFixture {
  file: string; name: string; mediaType: string; size: number; sha256: string; partSize: number
  parts: { size: number; sha256: string }[]
}
const fixture: UploadFixture = JSON.parse(readFileSync(join(FIXTURES_DIR, 'attachments/upload.json'), 'utf8'))
const photo = new Uint8Array(readFileSync(join(FIXTURES_DIR, 'attachments', fixture.file)))
const sha256 = (b: Uint8Array) => createHash('sha256').update(b).digest()

function parts(data: Uint8Array, size = PART_SIZE): Uint8Array[] {
  const out: Uint8Array[] = []
  for (let o = 0; o < data.length; o += size) out.push(data.subarray(o, o + size))
  return out
}

const servers: BridgeServer[] = []
const dirs: string[] = []
after(async () => {
  await Promise.all(servers.map((s) => s.close()))
  for (const d of dirs) rmSync(d, { recursive: true, force: true })
})

/** A paired phone on a Noise bridge over FakeDSH; records the size of every sealed message it sends. */
async function phone() {
  const dir = mkdtempSync(join(tmpdir(), 'dshm-attachments-'))
  dirs.push(dir)
  const store = new PairingStore(dir)
  store.writeListener({ hostName: 'test-mac', addresses: ['127.0.0.1:1'] })
  const dsh = new FakeDSH({ reply: ['I see', ' a photo.'] })
  const server = await startBridgeServer({
    dshVersion: SUPPORTED_DSH, host: '127.0.0.1', port: 0, noise: new NoiseResponder(store),
    tasks: new DshTasks(dsh, '/tmp/dshm-ws'),
  })
  servers.push(server)
  const offer = makeOffer(store)
  const initiator = NoiseInitiator.pair({ s: generateKeyPair(), hostKey: offer.hostKey, offerId: offer.offerId, secret: offer.secret })
  const ws = new WebSocket(`ws://127.0.0.1:${server.port}/`)
  ws.binaryType = 'nodebuffer'
  const frames: Frame[] = []
  const sent: number[] = []
  let session: NoiseSession | undefined
  let wake: (() => void) | undefined
  const ready = new Promise<void>((resolve, reject) => {
    ws.on('message', (data: Buffer) => {
      if (!session) { try { session = initiator.finish(new Uint8Array(data)); resolve() } catch (e) { reject(e) } return }
      frames.push(fromBinary(FrameSchema, session.open(new Uint8Array(data))))
      wake?.()
    })
    ws.on('close', (code) => reject(new Error(`closed ${code}`)))
  })
  ws.on('open', () => ws.send(initiator.first))
  await ready
  let nextId = 1n
  const c = {
    dsh, frames, sent,
    /** Sends one request and waits for its response. */
    async request(body: MessageInitShape<typeof RequestSchema>['body']) {
      const id = nextId++
      const plain = toBinary(FrameSchema, create(FrameSchema, { kind: { case: 'request', value: { id, body } } }))
      assert.ok(plain.length <= NOISE_MAX_PLAINTEXT, `frame of ${plain.length} bytes does not fit one Noise message`)
      const sealed = session!.seal(plain)
      sent.push(sealed.length)
      ws.send(sealed)
      const deadline = Date.now() + 3000
      for (;;) {
        const r = frames.find((f) => f.kind.case === 'response' && f.kind.value.requestId === id)
        if (r && r.kind.case === 'response') return r.kind.value.body
        if (Date.now() > deadline) throw new Error(`no response to ${id}`)
        await new Promise<void>((res) => { wake = res; setTimeout(res, 50) })
      }
    },
    close() { ws.close() },
  }
  const hello = await c.request({ case: 'hello', value: { protocolVersion: 1, capabilities: [CONVERSATION_CAPABILITY] } })
  assert.ok(hello.case === 'hello' && hello.value.capabilities.includes(ATTACHMENTS_CAPABILITY))
  return c
}

/** Waits until the frames match. */
async function until(c: { frames: Frame[] }, pred: (fs: Frame[]) => boolean, ms = 3000) {
  const deadline = Date.now() + ms
  while (!pred(c.frames)) {
    if (Date.now() > deadline) throw new Error(`timed out; got ${c.frames.length} frames`)
    await new Promise((r) => setTimeout(r, 10))
  }
}

const ended = (fs: Frame[]) => fs.filter((f) => f.kind.case === 'event' && f.kind.value.body.case === 'taskEnded'
  && f.kind.value.body.value.status === TaskStatus.COMPLETED).length

/** Three files that are not images: text, a PDF of two parts, and a type nobody knows (sent with no media type). */
const files = [
  { name: 'notes.txt', mediaType: 'text/plain', data: new TextEncoder().encode('Buy milk.\n买牛奶。\n') },
  { name: 'report.pdf', mediaType: 'application/pdf', data: new TextEncoder().encode(`%PDF-1.4\n${'x'.repeat(PART_SIZE + 10)}\n%%EOF\n`) },
  { name: 'data.xyz', mediaType: '', data: new Uint8Array([0, 1, 2, 3, 254, 255]) },
]

/** Uploads any file in parts; returns the last response. */
async function uploadFile(c: Phone, uploadId: string, file: { name: string; mediaType: string; data: Uint8Array }) {
  const begin = await c.request({ case: 'uploadBegin', value: {
    uploadId, mediaType: file.mediaType, name: file.name, size: BigInt(file.data.length), sha256: sha256(file.data),
  } })
  if (begin.case === 'error') return begin
  for (const [index, part] of parts(file.data).entries()) {
    const ack = await c.request({ case: 'uploadChunk', value: { uploadId, index, data: part } })
    if (ack.case === 'error') return ack
  }
  return c.request({ case: 'uploadEnd', value: { uploadId } })
}

type Phone = Awaited<ReturnType<typeof phone>>

async function upload(c: Phone, uploadId: string, data: Uint8Array, opts: { hash?: Uint8Array; skip?: number } = {}) {
  const begin = await c.request({ case: 'uploadBegin', value: {
    uploadId, mediaType: fixture.mediaType, name: fixture.name, size: BigInt(data.length), sha256: opts.hash ?? sha256(data),
  } })
  if (begin.case === 'error') return begin
  for (const [index, part] of parts(data).entries()) {
    if (index === opts.skip) continue
    const ack = await c.request({ case: 'uploadChunk', value: { uploadId, index, data: part } })
    if (ack.case === 'error') return ack
  }
  return c.request({ case: 'uploadEnd', value: { uploadId } })
}

describe('Attachments', () => {
  test('goldenPhotoSplitsIntoTheFixtureParts', () => {
    assert.equal(PART_SIZE, fixture.partSize)
    assert.equal(photo.length, fixture.size)
    assert.equal(sha256(photo).toString('hex'), fixture.sha256)
    assert.deepEqual(parts(photo).map((p) => ({ size: p.length, sha256: sha256(p).toString('hex') })), fixture.parts)
    assert.ok(fixture.parts.length >= 3)
  })

  test('photoOfSeveralNoiseMessagesArrivesByteIdenticalAndEntersTheFirstPromptAsAnImage', async () => {
    const c = await phone()
    try {
      const staged = await upload(c, 'upload-1', photo)
      assert.ok(staged.case === 'uploadStaged' && staged.value.uploadId === 'upload-1', JSON.stringify(staged))
      // Hello, Begin, one Noise message per part, End.
      assert.equal(c.sent.length, 1 + 1 + fixture.parts.length + 1)
      assert.ok(c.sent.slice(2, 2 + fixture.parts.length).every((n, i) => n > fixture.parts[i].size && n <= 65535))
      const created = await c.request({ case: 'createTask', value: { prompt: 'What is in this photo?', uploadIds: ['upload-1'] } })
      assert.equal(created.case, 'taskCreated')
      const [image] = c.dsh.stagedImages
      assert.equal(c.dsh.stagedImages.length, 1)
      assert.equal(image.mediaType, 'image/jpeg')
      assert.equal(image.name, 'photo.jpg')
      assert.deepEqual(Buffer.from(image.data), Buffer.from(photo), 'byte-identical')
      const [prompt] = c.dsh.promptParts
      assert.equal(prompt.sessionId, image.sessionId)
      assert.deepEqual(prompt.parts, [{ type: 'text', text: 'What is in this photo?' }, { type: 'file', receiptId: image.receiptId }])
      // The upload is used up: a second task cannot name it.
      const again = await c.request({ case: 'createTask', value: { prompt: 'again', uploadIds: ['upload-1'] } })
      assert.ok(again.case === 'error' && again.value.code === 'upload/unknown')
    } finally { c.close() }
  })

  test('wrongHashIsRefusedAndNothingIsStaged', async () => {
    const c = await phone()
    try {
      const wrong = sha256(photo); wrong[0] ^= 0xff
      const end = await upload(c, 'upload-1', photo, { hash: wrong })
      assert.ok(end.case === 'error' && end.value.code === 'upload/hash-mismatch')
      const create_ = await c.request({ case: 'createTask', value: { prompt: 'x', uploadIds: ['upload-1'] } })
      assert.ok(create_.case === 'error' && create_.value.code === 'upload/unknown')
      assert.deepEqual(c.dsh.stagedImages, [])
      assert.deepEqual(c.dsh.promptParts, [])
    } finally { c.close() }
  })

  test('missingPartIsRefused', async () => {
    const c = await phone()
    try {
      const skipped = await upload(c, 'upload-1', photo, { skip: 1 })
      assert.ok(skipped.case === 'error' && skipped.value.code === 'upload/missing-part', JSON.stringify(skipped))
      // A last part that never comes: End refuses the short file.
      await c.request({ case: 'uploadBegin', value: { uploadId: 'upload-2', mediaType: 'image/jpeg', name: 'p.jpg',
        size: BigInt(photo.length), sha256: sha256(photo) } })
      const [first] = parts(photo)
      await c.request({ case: 'uploadChunk', value: { uploadId: 'upload-2', index: 0, data: first } })
      const end = await c.request({ case: 'uploadEnd', value: { uploadId: 'upload-2' } })
      assert.ok(end.case === 'error' && end.value.code === 'upload/missing-part')
      assert.deepEqual(c.dsh.stagedImages, [])
    } finally { c.close() }
  })

  test('stagingRefusesTooLargeAndTooMany', () => {
    const s = new UploadStaging()
    const hash = sha256(photo)
    assert.throws(() => s.begin({ uploadId: 'a', mediaType: 'image/jpeg', name: '', size: BigInt(MAX_UPLOAD_BYTES + 1), sha256: hash }),
      { code: 'upload/too-large' })
    assert.throws(() => s.begin({ uploadId: 'b', mediaType: 'application/zip', name: '', size: BigInt(MAX_UPLOAD_BYTES + 1), sha256: hash }),
      { code: 'upload/too-large' })
    // D107: any media type is taken; a type DSH does not take as an image goes as a file.
    for (let i = 0; i < MAX_UPLOADS_PER_CONNECTION; i++) {
      s.begin({ uploadId: `ok-${i}`, mediaType: 'image/heic', name: '', size: 10n, sha256: hash })
    }
    assert.throws(() => s.begin({ uploadId: 'one-more', mediaType: 'text/plain', name: '', size: 10n, sha256: hash }),
      { code: 'upload/too-many' })
    assert.throws(() => s.chunk({ uploadId: 'c', index: 0, data: photo }), { code: 'upload/unknown' })
  })

  test('textPdfAndUnknownFilesReachDshAsFilePartsWithTheirNamesInOrder', async () => {
    const c = await phone()
    try {
      for (const [i, file] of files.entries()) {
        const staged = await uploadFile(c, `file-${i}`, file)
        assert.ok(staged.case === 'uploadStaged', JSON.stringify(staged))
      }
      assert.equal((await upload(c, 'photo', photo)).case, 'uploadStaged')
      // The photo between the files: one prompt keeps the order the app chose.
      const order = ['file-0', 'photo', 'file-1', 'file-2']
      const created = await c.request({ case: 'createTask', value: { prompt: 'Read these.', uploadIds: order } })
      assert.equal(created.case, 'taskCreated')
      assert.deepEqual(c.dsh.stagedFiles.map((f) => f.name), ['notes.txt', 'report.pdf', 'data.xyz'])
      for (const [i, file] of files.entries()) assert.deepEqual(Buffer.from(c.dsh.stagedFiles[i].data), Buffer.from(file.data))
      assert.deepEqual(c.dsh.stagedImages.map((i) => i.name), ['photo.jpg'])
      const [prompt] = c.dsh.promptParts
      const byReceipt = new Map([...c.dsh.stagedFiles, ...c.dsh.stagedImages].map((f) => [f.receiptId, f.name]))
      assert.deepEqual(prompt.parts.map((p) => (p.type === 'text' ? `text:${p.text}` : `file:${byReceipt.get(p.receiptId)}`)),
        ['text:Read these.', 'file:notes.txt', 'file:photo.jpg', 'file:report.pdf', 'file:data.xyz'])
      assert.ok([...c.dsh.stagedFiles, ...c.dsh.stagedImages].every((f) => f.sessionId === prompt.sessionId))
    } finally { c.close() }
  })

  test('aFileOverTheLimitIsRefusedBeforeAnyPartAndNothingIsStaged', async () => {
    const c = await phone()
    try {
      const begin = await c.request({ case: 'uploadBegin', value: {
        uploadId: 'big', mediaType: 'application/pdf', name: 'big.pdf', size: BigInt(MAX_UPLOAD_BYTES + 1), sha256: sha256(photo),
      } })
      assert.ok(begin.case === 'error' && begin.value.code === 'upload/too-large', JSON.stringify(begin))
      const part = await c.request({ case: 'uploadChunk', value: { uploadId: 'big', index: 0, data: photo.subarray(0, 10) } })
      assert.ok(part.case === 'error' && part.value.code === 'upload/unknown')
      assert.deepEqual(c.dsh.stagedFiles, [])
      assert.deepEqual(c.dsh.stagedImages, [])
    } finally { c.close() }
  })

  test('aFollowUpTakesFilesIntoTheSameSessionAndItsUserMessageNamesThem', async () => {
    const c = await phone()
    try {
      const created = await c.request({ case: 'createTask', value: { prompt: 'Hello.' } })
      assert.ok(created.case === 'taskCreated')
      const taskId = created.value.taskId
      await until(c, (fs) => ended(fs) === 1)
      assert.equal((await uploadFile(c, 'f-txt', files[0])).case, 'uploadStaged')
      assert.equal((await uploadFile(c, 'f-pdf', files[1])).case, 'uploadStaged')
      const accepted = await c.request({ case: 'sendMessage', value: { taskId, text: 'And these?', uploadIds: ['f-pdf', 'f-txt'] } })
      assert.ok(accepted.case === 'messageAccepted', JSON.stringify(accepted))
      await until(c, (fs) => ended(fs) === 2)
      assert.deepEqual(c.dsh.stagedFiles.map((f) => [f.sessionId, f.name]), [[taskId, 'report.pdf'], [taskId, 'notes.txt']])
      const followUp = c.dsh.promptParts.at(-1)!
      assert.equal(followUp.sessionId, taskId)
      assert.deepEqual(followUp.parts.map((p) => p.type), ['text', 'file', 'file'])
      const messages = c.frames.flatMap((f) =>
        f.kind.case === 'event' && f.kind.value.body.case === 'userMessage' ? [f.kind.value.body.value] : [])
      assert.equal(messages.length, 1)
      assert.deepEqual(messages[0].attachments.map((a) => [a.kind, a.name, Number(a.size), a.mediaType]), [
        [AttachmentKind.FILE, 'report.pdf', files[1].data.length, 'application/pdf'],
        [AttachmentKind.FILE, 'notes.txt', files[0].data.length, 'text/plain'],
      ])
      // The uploads are used up by the message.
      const again = await c.request({ case: 'sendMessage', value: { taskId, text: 'again', uploadIds: ['f-pdf'] } })
      assert.ok(again.case === 'error' && again.value.code === 'upload/unknown')
    } finally { c.close() }
  })
})
