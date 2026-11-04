import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { describe, test } from 'node:test'
import { fromBinary, fromJson, toBinary, toJson } from '@bufbuild/protobuf'
import { FrameSchema } from '../src/gen/frame_pb.ts'
import { FIXTURES_DIR, loadFixtures } from './fixtures.ts'

describe('GoldenFixtures', () => {
  const fixtures = loadFixtures()

  test('fixturesRoundTrip', () => {
    assert.ok(fixtures.length >= 9)
    for (const f of fixtures) {
      const bytes = new Uint8Array(readFileSync(`${FIXTURES_DIR}/${f.name}.binpb`))
      const decoded = fromBinary(FrameSchema, bytes)
      assert.deepEqual(toJson(FrameSchema, decoded), f.frame, `${f.name}: decoded JSON`)
      assert.deepEqual(toBinary(FrameSchema, decoded), bytes, `${f.name}: re-encoded bytes`)
      assert.deepEqual(toBinary(FrameSchema, fromJson(FrameSchema, f.frame)), bytes, `${f.name}: JSON → bytes`)
    }
  })
})
