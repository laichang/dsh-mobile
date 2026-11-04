/** Writes protocol/fixtures/<name>.binpb for entries in fixtures.json that don't have one yet. */
import { existsSync, writeFileSync } from 'node:fs'
import { fromJson, toBinary } from '@bufbuild/protobuf'
import { FrameSchema } from '../src/gen/frame_pb.ts'
import { FIXTURES_DIR, loadFixtures } from '../test/fixtures.ts'

for (const f of loadFixtures()) {
  const path = `${FIXTURES_DIR}/${f.name}.binpb`
  if (existsSync(path)) continue
  writeFileSync(path, toBinary(FrameSchema, fromJson(FrameSchema, f.frame)))
  console.log(`wrote ${path}`)
}

