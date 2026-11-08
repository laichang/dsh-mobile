#!/usr/bin/env node
// Real DSH + the dsh-mobile bridge, with DSH's mock model scripted to ask one agent question.
// The first agent step calls `ask_user_question` (which of two templates); the next step answers
// with the label the model got back in the tool result. Prints `questions-host: ready` when the
// bridge listens. Env: DSHM_HOME, DSHM_WEB_PORT, DSHM_BRIDGE_PORT (scripts/slice-env).
import { connect, createServer } from 'node:net'
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
process.env.DSHM_BRIDGE_HOST = '127.0.0.1'
process.env.DSHM_BRIDGE_DEV_PLAINTEXT = '1'
const bridgePort = Number(process.env.DSHM_BRIDGE_PORT ?? 47801)

export const QUESTION = {
  id: 'template', question: '桌面上有两个周报模板，用哪个？', header: '模板',
  options: [{ label: '公司模板.pptx', description: '带公司页眉' }, { label: '简洁版.pptx', description: '一页纸' }],
}

const root = fileURLToPath(new URL('../../', import.meta.url))
const { startHost, lastToolResult } = await import('../../spikes/x1-approval/lib/host.mjs')
const listening = () => new Promise(ok => {
  const socket = connect(bridgePort, '127.0.0.1')
  socket.once('connect', () => { socket.destroy(); ok(true) }).once('error', () => ok(false))
})
const host = await startHost({ plugins: [resolve(root, 'bridge')], ready: listening, log: s => process.stdout.write(s) })
try {
  await host.route({
    ask: { sequence: ['tool_call_success'], repeatLast: true, toolName: 'ask_user_question',
      toolArguments: JSON.stringify({ questions: [QUESTION] }) },
    company: { sequence: ['success'], repeatLast: true, successText: '好的，用公司模板.pptx 写周报。' },
    simple: { sequence: ['success'], repeatLast: true, successText: '好的，用简洁版.pptx 写周报。' },
    other: { sequence: ['success'], repeatLast: true, successText: 'No answer.' },
  }, body => {
    const result = lastToolResult(body)
    if (result === undefined) return 'ask'
    return result.includes('简洁版.pptx') ? 'simple' : result.includes('公司模板.pptx') ? 'company' : 'other'
  })
  console.log('questions-host: ready')
  await new Promise(ok => { process.once('SIGTERM', ok); process.once('SIGINT', ok) })
} finally {
  await host.stop()
}
