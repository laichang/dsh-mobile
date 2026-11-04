import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { JsonValue } from '@bufbuild/protobuf'

// lib/test/fixtures.js or test/fixtures.ts → repo root is two or three levels up; find it.
function repoRoot(): string {
  let dir = dirname(fileURLToPath(import.meta.url))
  while (!existsDir(resolve(dir, 'protocol/fixtures'))) {
    const parent = dirname(dir)
    if (parent === dir) throw new Error('protocol/fixtures not found')
    dir = parent
  }
  return dir
}
function existsDir(p: string): boolean {
  try { readFileSync(resolve(p, 'fixtures.json')); return true } catch { return false }
}

export const FIXTURES_DIR = resolve(repoRoot(), 'protocol/fixtures')

export interface Fixture { name: string; frame: JsonValue }

export function loadFixtures(): Fixture[] {
  return JSON.parse(readFileSync(resolve(FIXTURES_DIR, 'fixtures.json'), 'utf8')).fixtures
}
