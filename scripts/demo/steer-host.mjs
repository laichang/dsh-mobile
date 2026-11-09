#!/usr/bin/env node
// "立即发送" into a long step, against real DSH (ARCHITECTURE D101): DSH Web with the bridge plugin and
// DSH's mock model, scripted so that the agent's first step is a slow tool call (`bash`, a sleep of
// DSHM_STEER_SLEEP seconds, default 30), as a real agent that waits for its subagents. A message
// sent now during that step goes in only when the step ends. The next step answers with
// STEER_REPLY. It writes `bridge-port` into DSHM_FOLLOWUP_SIGNALS and waits until the UI test
// writes `steer-done` (or SIGTERM).
// Env: DSHM_HOME, DSHM_WEB_PORT, DSHM_BRIDGE_PORT (scripts/slice-env), DSHM_FOLLOWUP_SIGNALS.
import { existsSync, writeFileSync } from 'node:fs'
import { connect, createServer } from 'node:net'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

async function freePort() {
  const server = createServer()
  await new Promise((ok, fail) => server.once('error', fail).listen(0, '127.0.0.1', ok))
  const port = server.address().port
  await new Promise(ok => server.close(ok))
  return String(port)
}
process.env.DSHM_MOCK_PORT = await freePort()
process.env.DSHM_BRIDGE_HOST = '127.0.0.1'
process.env.DSHM_BRIDGE_DEV_PLAINTEXT = '1'
const bridgePort = Number(process.env.DSHM_BRIDGE_PORT ?? 47801)
const signals = process.env.DSHM_FOLLOWUP_SIGNALS
if (!signals) throw new Error('set DSHM_FOLLOWUP_SIGNALS')
const sleep = Number(process.env.DSHM_STEER_SLEEP ?? 30)
export const STEER_REPLY = '好的，停在这里。'

const root = fileURLToPath(new URL('../../', import.meta.url))
const { startHost, lastToolResult } = await import('../../spikes/x1-approval/lib/host.mjs')
const listening = () => new Promise(ok => {
  const socket = connect(bridgePort, '127.0.0.1')
  socket.once('connect', () => { socket.destroy(); ok(true) }).once('error', () => ok(false))
})
const host = await startHost({ plugins: [resolve(root, 'bridge')], ready: listening, log: s => process.stdout.write(s) })
let stopped = false
process.once('SIGTERM', () => { stopped = true })
process.once('SIGINT', () => { stopped = true })
try {
  await host.route({
    wait: { sequence: ['tool_call_success'], repeatLast: true, toolName: 'bash',
      toolArguments: JSON.stringify({ command: `sleep ${sleep}; echo parts done`, description: 'Wait for the parts' }) },
    reply: { sequence: ['success'], repeatLast: true, successText: STEER_REPLY },
  }, body => lastToolResult(body) === undefined ? 'wait' : 'reply')
  writeFileSync(join(signals, 'bridge-port'), String(bridgePort))
  console.log(`steer-host: ready (bridge ${bridgePort}, a ${sleep} s tool step)`)
  while (!stopped && !existsSync(join(signals, 'steer-done'))) await new Promise(ok => setTimeout(ok, 300))
} finally {
  await host.stop()
}
