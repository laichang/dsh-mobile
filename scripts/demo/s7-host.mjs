#!/usr/bin/env node
// Real DSH reads the same relative file in two workspaces. Only the model is scripted.
import { createServer, connect } from 'node:net'
import { fileURLToPath } from 'node:url'

const port = createServer()
await new Promise((ok, fail) => port.once('error', fail).listen(0, '127.0.0.1', ok))
process.env.DSHM_MOCK_PORT = String(port.address().port)
await new Promise(ok => port.close(ok))
const { startHost, lastToolResult } = await import('../../spikes/x1-approval/lib/host.mjs')
const bridge = fileURLToPath(new URL('../../bridge', import.meta.url))
const host = await startHost({
  plugins: [bridge],
  ready: () => new Promise(ok => {
    const socket = connect(Number(process.env.DSHM_BRIDGE_PORT), '127.0.0.1')
    socket.once('connect', () => { socket.end(); ok(true) })
    socket.once('error', () => ok(false))
  }),
  log: s => process.stdout.write(s),
})
try {
  const once = { repeatLast: true }
  await host.route({
    read: { ...once, sequence: ['tool_call_success'], toolName: 'read', toolArguments: JSON.stringify({ file_path: 'project-label.txt' }) },
    first: { ...once, sequence: ['success'], successText: 'Amber repository' },
    second: { ...once, sequence: ['success'], successText: 'Violet repository' },
    error: { ...once, sequence: ['success'], successText: 'Unexpected file contents.' },
  }, body => {
    const result = lastToolResult(body)
    if (result === undefined) return 'read'
    if (result.includes('AMBER-MARKER')) return 'first'
    if (result.includes('VIOLET-MARKER')) return 'second'
    return 'error'
  })
  console.log('s7-host: ready')
  await new Promise(ok => { process.once('SIGTERM', ok); process.once('SIGINT', ok) })
} finally {
  await host.stop()
}
