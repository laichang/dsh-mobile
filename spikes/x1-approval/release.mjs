#!/usr/bin/env node
/**
 * X1 release script (throwaway): lists approvals parked by the X1 spike plugin, or releases one.
 * Stands in for the phone's AnswerApproval.
 *
 *   node release.mjs list
 *   node release.mjs <approvalId|first> allow|reject
 *
 * Env: X1_CONTROL_PORT (default 47803).
 */
const port = Number(process.env.X1_CONTROL_PORT ?? 47803)
const base = `http://127.0.0.1:${port}`
const [what = 'list', verdict] = process.argv.slice(2)

const state = await (await fetch(`${base}/state`)).json()
if (what === 'list') {
  console.log(JSON.stringify(state.parked, null, 2))
  process.exit(0)
}
const outcome = { allow: 'allowed-once', reject: 'rejected' }[verdict]
if (!outcome) { console.error('usage: release.mjs <approvalId|first> allow|reject'); process.exit(2) }
const id = what === 'first' ? state.parked[0]?.id : what
if (!id) { console.error('nothing parked'); process.exit(1) }
const res = await fetch(`${base}/approvals/${id}`, {
  method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ outcome }),
})
const body = await res.json()
if (!body.ok) { console.error(`release failed: ${JSON.stringify(body)}`); process.exit(1) }
console.log(`released ${id} → ${outcome}`)
