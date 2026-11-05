/**
 * Writes protocol/fixtures/noise/transcripts.json from fixed keys (see test/noise-transcripts.ts).
 *   pnpm noise-fixtures
 */
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { FIXTURES_DIR } from '../test/fixtures.ts'
import { makeTranscripts } from '../test/noise-transcripts.ts'

const out = resolve(FIXTURES_DIR, 'noise/transcripts.json')
writeFileSync(out, JSON.stringify(makeTranscripts(), null, 2) + '\n')
console.log(`wrote ${out}`)
