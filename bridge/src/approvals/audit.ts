import { closeSync, existsSync, fstatSync, openSync, readFileSync, readSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

export interface ApprovalAuditRecord {
  when: string
  by: string
  device: string
  id: string
  taskId: string
  callId: string
  tool: string
  argumentsJson: string
  reason: string
  outcome: string
}

export function approvalAudit(dir: string) {
  const file = join(dir, 'approvals.jsonl')
  return {
    append(record: ApprovalAuditRecord) {
      const fd = openSync(file, 'a+', 0o600)
      try {
        // A readable historical JSONL file can end immediately after its last record.
        const size = fstatSync(fd).size
        const last = Buffer.alloc(1)
        if (size) readSync(fd, last, 0, 1, size - 1)
        const separator = size && last[0] !== 10 ? '\n' : ''
        writeFileSync(fd, separator + JSON.stringify(record) + '\n')
      } finally {
        closeSync(fd)
      }
    },
    read(): ApprovalAuditRecord[] {
      return existsSync(file) ? readFileSync(file, 'utf8').split('\n').filter(Boolean).map(line => JSON.parse(line)) : []
    },
  }
}
