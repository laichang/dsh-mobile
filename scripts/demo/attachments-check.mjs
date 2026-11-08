#!/usr/bin/env node
// Checks that a DSH session made since <since> (Unix seconds) has the photo in its first user
// message (ARCHITECTURE D95): the prompt text and an `image` part of <width>x<height> whose
// attachment object is in DSH's store.
//   node scripts/demo/attachments-check.mjs <DSH_HOME> <since> <prompt> <width>x<height>
// Session logs are `<DSH_HOME>/sessions/<workspace>/<session>/session.v4.jsonl.zstd`: JSON lines in
// several zstd frames (node's zstdDecompressSync reads one frame only, so each is read alone).
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { zstdDecompressSync } from 'node:zlib'

const [home, since, prompt, size] = process.argv.slice(2)
if (!home || !since || !prompt || !/^\d+x\d+$/.test(size ?? '')) {
  console.error('usage: attachments-check.mjs <DSH_HOME> <since> <prompt> <width>x<height>'); process.exit(2)
}
const [width, height] = size.split('x').map(Number)

const logs = []
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name)
    if (statSync(path).isDirectory()) walk(path)
    else if (name.endsWith('.jsonl.zstd') && statSync(path).mtimeMs / 1000 >= Number(since)) logs.push(path)
  }
}
walk(join(home, 'sessions'))

function events(path) {
  const bytes = readFileSync(path)
  const starts = []
  for (let i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] === 0x28 && bytes[i + 1] === 0xb5 && bytes[i + 2] === 0x2f && bytes[i + 3] === 0xfd) starts.push(i)
  }
  starts.push(bytes.length)
  let text = ''
  for (let k = 0; k + 1 < starts.length; k++) {
    try { text += zstdDecompressSync(bytes.subarray(starts[k], starts[k + 1])).toString('utf8') } catch { /* the magic inside data */ }
  }
  return text.split('\n').filter(Boolean).flatMap((line) => { try { return [JSON.parse(line)] } catch { return [] } })
}

for (const log of logs) {
  const first = events(log).find((e) => e.type === 'user/message' && e.data?.source?.kind === 'user')
  const content = first?.data?.content ?? []
  const text = content.filter((p) => p.type === 'text').map((p) => p.text).join('')
  const image = content.find((p) => p.type === 'image')?.attachment
  if (text !== prompt || !image) continue
  const id = String(image.attachmentId ?? '').replace(/^sha256:/, '')
  const object = join(home, 'attachments/v1/objects', id.slice(0, 2), id)
  console.log(`${log}\n  first user message: "${text}" + image ${image.mediaType} ${image.width}x${image.height} ${image.bytes} bytes "${image.name}"`)
  if (image.mediaType !== 'image/jpeg') { console.error(`expected image/jpeg, got ${image.mediaType}`); process.exit(1) }
  if (image.width !== width || image.height !== height) { console.error(`expected ${size}`); process.exit(1) }
  if (!existsSync(object)) { console.error(`no attachment object at ${object}`); process.exit(1) }
  console.log(`  attachment object: ${object}`)
  process.exit(0)
}
console.error(`no session in ${home} since ${since} whose first user message is "${prompt}" with an image`)
process.exit(1)
