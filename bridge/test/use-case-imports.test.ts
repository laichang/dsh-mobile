import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { cpSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

test('protocol adapters accept infrastructure imports and use cases reject type and runtime imports', t => {
  const root = mkdtempSync(join(tmpdir(), 'bridge-imports-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  cpSync('src', root, { recursive: true })
  const check = () => spawnSync(process.execPath, ['scripts/check-use-case-imports.mjs', root], { encoding: 'utf8' })
  writeFileSync(join(root, 'server.ts'), "import type { Request } from './gen/frame_pb.ts'\nimport 'ws'\n")
  assert.equal(check().status, 0)
  for (const specifier of ['../gen/frame_pb.ts', 'ws', 'node:fs/promises']) {
    for (const statement of [`import type { X } from '${specifier}'`, `import '${specifier}'`]) {
      writeFileSync(join(root, 'tasks/task-hub.ts'), statement)
      const result = check()
      assert.equal(result.status, 1)
      assert.ok(result.stderr.includes('tasks/task-hub.ts imports ' + specifier))
    }
  }
})
