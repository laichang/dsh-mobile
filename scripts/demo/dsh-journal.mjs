// Reads DSH session logs for the demo checks. Session logs are
// `<DSH_HOME>/sessions/<workspace>/<session>/session.v4.jsonl.zstd`: JSON lines in several zstd
// frames (node's zstdDecompressSync reads one frame only, so each is read alone).
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { zstdDecompressSync } from 'node:zlib'

/** The session logs under `home` written at or after `since` (Unix seconds). */
export function sessionLogs(home, since) {
  const logs = []
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name)
      if (statSync(path).isDirectory()) walk(path)
      else if (name.endsWith('.jsonl.zstd') && statSync(path).mtimeMs / 1000 >= Number(since)) logs.push(path)
    }
  }
  walk(join(home, 'sessions'))
  return logs
}

/** The events of one session log, in order. */
export function events(path) {
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

/** The messages the user wrote (not the context DSH adds), in order. */
export function userMessages(path) {
  return events(path).filter((e) => e.type === 'user/message' && e.data?.source?.kind === 'user')
    .map((e) => e.data?.content ?? [])
}

/** The text parts of a message's content, joined. */
export const textOf = (content) => content.filter((p) => p.type === 'text').map((p) => p.text).join('')

/** Where DSH keeps the bytes of an attachment: `objects` for an image, `file-objects` for a file. */
export function objectPath(home, part) {
  const id = String(part.attachment?.attachmentId ?? '').replace(/^sha256:/, '')
  return join(home, 'attachments/v1', part.type === 'image' ? 'objects' : 'file-objects', id.slice(0, 2), id)
}
