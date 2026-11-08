#!/usr/bin/env node
// Checks that a DSH session made since <since> (Unix seconds) has an image in its first user
// message (ARCHITECTURE D95). Usage: node scripts/demo/attachments-check.mjs <DSH_HOME> <since>
// Session logs are `<DSH_HOME>/sessions/<workspace>/<session>/session.v4.jsonl.zstd`.
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { zstdDecompressSync } from 'node:zlib'

const [home, since = '0'] = process.argv.slice(2)
if (!home) { console.error('usage: attachments-check.mjs <DSH_HOME> <since>'); process.exit(2) }
const logs = []
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name)
    if (statSync(path).isDirectory()) walk(path)
    else if (name.endsWith('.jsonl.zstd') && statSync(path).mtimeMs / 1000 >= Number(since)) logs.push(path)
  }
}
walk(join(home, 'sessions'))
if (!logs.length) { console.error(`no session in ${home} since ${since}`); process.exit(1) }

for (const log of logs) {
  const events = zstdDecompressSync(readFileSync(log)).toString('utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))
  for (const event of events) {
    if (process.env.DEBUG) console.log(JSON.stringify(event).slice(0, 400))
  }
}
