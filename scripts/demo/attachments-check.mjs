#!/usr/bin/env node
// Checks that a DSH session made since <since> (Unix seconds) has the photo in its first user
// message (ARCHITECTURE D95): the prompt text and an `image` part of <width>x<height> whose
// attachment object is in DSH's store.
//   node scripts/demo/attachments-check.mjs <DSH_HOME> <since> <prompt> <width>x<height>
import { existsSync } from 'node:fs'
import { objectPath, sessionLogs, textOf, userMessages } from './dsh-journal.mjs'

const [home, since, prompt, size] = process.argv.slice(2)
if (!home || !since || !prompt || !/^\d+x\d+$/.test(size ?? '')) {
  console.error('usage: attachments-check.mjs <DSH_HOME> <since> <prompt> <width>x<height>'); process.exit(2)
}
const [width, height] = size.split('x').map(Number)

for (const log of sessionLogs(home, since)) {
  const content = userMessages(log)[0] ?? []
  const text = textOf(content)
  const part = content.find((p) => p.type === 'image')
  const image = part?.attachment
  if (text !== prompt || !image) continue
  const object = objectPath(home, part)
  console.log(`${log}\n  first user message: "${text}" + image ${image.mediaType} ${image.width}x${image.height} ${image.bytes} bytes "${image.name}"`)
  if (image.mediaType !== 'image/jpeg') { console.error(`expected image/jpeg, got ${image.mediaType}`); process.exit(1) }
  if (image.width !== width || image.height !== height) { console.error(`expected ${size}`); process.exit(1) }
  if (!existsSync(object)) { console.error(`no attachment object at ${object}`); process.exit(1) }
  console.log(`  attachment object: ${object}`)
  process.exit(0)
}
console.error(`no session in ${home} since ${since} whose first user message is "${prompt}" with an image`)
process.exit(1)
