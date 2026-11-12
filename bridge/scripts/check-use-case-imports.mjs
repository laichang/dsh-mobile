import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

// The DSH adapter and the plugin's composition root share the same import boundary as the use cases.
const useCases = [
  'tasks/task-hub', 'tasks/events', 'approvals/holder', 'questions/holder', 'sessions/directory',
  'models/catalog', 'milestones/mapper', 'transcript/mapper', 'drawer/workspace', 'dsh', 'index',
]
const root = process.argv[2] ?? fileURLToPath(new URL('../src/', import.meta.url))
for (const name of useCases) {
  const source = readFileSync(join(root, name + '.ts'), 'utf8')
  const imports = /\b(?:from\s*|import\s*(?:\(\s*)?|require\s*\(\s*)['"]([^'"]+)['"]/g
  for (const [, specifier] of source.matchAll(imports)) {
    if (/(^|\/)gen\/|^(?:node:)?fs(?:\/|$)|^ws(?:\/|$)|^@bufbuild\/protobuf(?:\/|$)/.test(specifier)) {
      console.error(name + '.ts imports ' + specifier)
      process.exitCode = 1
    }
  }
}
