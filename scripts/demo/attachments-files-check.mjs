#!/usr/bin/env node
// Checks the DSH sessions of AttachmentsUITests' file tests (ARCHITECTURE D107), made since
// <since> (Unix seconds):
//   - "Read these files.": the first user message has the photo, then report.pdf as a file part,
//     in that order, and not notes.txt (removed on the phone);
//   - "Say hello.": the same session has a later user message "What is in this file?" with
//     notes.txt as a file part.
// Each part's bytes are in DSH's attachment store, and a file's size is the demo file's.
//   node scripts/demo/attachments-files-check.mjs <DSH_HOME> <since> <files dir>
import { existsSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { objectPath, sessionLogs, textOf, userMessages } from './dsh-journal.mjs'

const [home, since, dir] = process.argv.slice(2)
if (!home || !since || !dir) { console.error('usage: attachments-files-check.mjs <DSH_HOME> <since> <files dir>'); process.exit(2) }

const describe = (content) => content.map((p) => p.type === 'text' ? `"${p.text}"` : `${p.type}:${p.attachment?.name}`).join(' + ')
function fail(message) { console.error(message); process.exit(1) }
function checkParts(content, names) {
  const parts = content.filter((p) => p.type !== 'text')
  const got = parts.map((p) => `${p.type}:${p.attachment?.name}`)
  if (got.join(',') !== names.join(',')) fail(`expected ${names.join(', ')}; got ${got.join(', ') || 'no attachments'}`)
  for (const part of parts) {
    const object = objectPath(home, part)
    if (!existsSync(object)) fail(`no attachment object at ${object}`)
    if (part.type === 'file' && part.attachment.bytes !== statSync(join(dir, part.attachment.name)).size) {
      fail(`${part.attachment.name}: ${part.attachment.bytes} bytes in DSH, not the demo file's size`)
    }
    console.log(`  ${part.type}:${part.attachment.name} → ${object}`)
  }
}

const logs = sessionLogs(home, since).map((log) => ({ log, messages: userMessages(log) }))

const first = logs.find(({ messages }) => textOf(messages[0] ?? []) === 'Read these files.')
if (!first) fail(`no session in ${home} since ${since} whose first user message is "Read these files."`)
console.log(`${first.log}\n  first user message: ${describe(first.messages[0])}`)
checkParts(first.messages[0], ['image:photo.jpg', 'file:report.pdf'])

const followed = logs.find(({ messages }) => textOf(messages[0] ?? []) === 'Say hello.'
  && messages.slice(1).some((m) => textOf(m) === 'What is in this file?'))
if (!followed) fail(`no session in ${home} since ${since} that starts "Say hello." and has the follow-up "What is in this file?"`)
const followUp = followed.messages.slice(1).find((m) => textOf(m) === 'What is in this file?')
console.log(`${followed.log}\n  follow-up in the same session: ${describe(followUp)}`)
checkParts(followUp, ['file:notes.txt'])
console.log('the DSH sessions have the files')
