import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import type { AuditEntry } from '../gen/devices_pb.ts'
import type { PairingStore } from '../pairing/store.ts'

type Record = Omit<AuditEntry, '$typeName' | '$unknown'>

export function deviceList(store: PairingStore, currentDeviceId: string) {
  return { currentDeviceId, devices: store.devices().map(d => ({
    id: d.id, pairedAtMs: BigInt(d.pairedAt), lastSeenAtMs: BigInt(d.lastSeenAt),
  })) }
}

export function auditPage(store: PairingStore, beforeId: string) {
  const records: Record[] = store.pairingHistory().map(row => ({ ...row, atMs: BigInt(row.atMs) }))
  // S4 already persists the authenticated answerer and the exact tool arguments before a tool can run.
  const file = join(store.dir, 'approvals.jsonl')
  if (existsSync(file)) {
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      if (!line) continue
      const a = JSON.parse(line)
      records.push({ id: 'approval:' + a.id, atMs: BigInt(Date.parse(a.when)), actor: a.by, device: a.device,
        action: 'Approval ' + a.outcome.toLowerCase(), detail: [a.tool, a.argumentsJson || a.reason].filter(Boolean).join(' ') })
    }
  }
  records.sort((a, b) => b.atMs > a.atMs ? 1 : b.atMs < a.atMs ? -1 : a.id.localeCompare(b.id))
  const start = beforeId ? records.findIndex(r => r.id === beforeId) + 1 : 0
  if (beforeId && start === 0) throw new Error('Audit cursor no longer exists. Refresh the history.')
  const entries = records.slice(start, start + 50)
  return { entries, nextBeforeId: start + entries.length < records.length ? entries.at(-1)!.id : '' }
}
