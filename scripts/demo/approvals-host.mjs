#!/usr/bin/env node
// Real DSH + bridge. X1's test plugin only gates this disposable tool call; the production bridge holds it.
import { createServer } from 'node:net'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

async function freePort() {
  const server = createServer()
  await new Promise((ok, fail) => server.once('error', fail).listen(0, '127.0.0.1', ok))
  const port = server.address().port
  await new Promise(ok => server.close(ok))
  return String(port)
}
process.env.DSHM_MOCK_PORT = await freePort()
process.env.X1_CONTROL_PORT = await freePort()
process.env.DSHM_BRIDGE_HOST = '127.0.0.1'
process.env.DSHM_BRIDGE_DEV_PLAINTEXT = '1'

const root = fileURLToPath(new URL('../../', import.meta.url))
const { startHost, controlClient, lastToolResult } = await import('../../spikes/x1-approval/lib/host.mjs')
const control = controlClient(Number(process.env.X1_CONTROL_PORT))
const host = await startHost({
  plugins: [resolve(root, 'bridge'), resolve(root, 'spikes/x1-approval/plugin')],
  ready: async () => Boolean(await control('GET', '/state')),
  log: s => process.stdout.write(s),
})
try {
  await control('POST', '/mode', { mode: 'off', gate: true })
  await host.route({
    tool: { sequence: ['tool_call_success'], repeatLast: true, toolName: 'bash',
      toolArguments: JSON.stringify({ command: process.env.DSHM_APPROVALS_COMMAND, description: 'X1-GATE: remove the demo fixture' }) },
    denied: { sequence: ['success'], repeatLast: true, successText: 'Deletion denied. Task continued.' },
    other: { sequence: ['success'], repeatLast: true, successText: 'Unexpected tool result.' },
  }, body => {
    const result = lastToolResult(body)
    return result === undefined ? 'tool' : /reject/i.test(result) ? 'denied' : 'other'
  })
  console.log(`approvals-host: ready ${process.env.X1_CONTROL_PORT}`)
  await new Promise(ok => { process.once('SIGTERM', ok); process.once('SIGINT', ok) })
} finally {
  await host.stop()
}
