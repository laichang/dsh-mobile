#!/usr/bin/env node
/**
 * Local acceptance host: real DSH 0.2.2-rc.1 + the dsh-mobile bridge, driven by DSH's
 * mock LLM server (no API key). Runs in the foreground until Ctrl-C.
 *
 *   node scripts/dsh-up.mjs            # DSH web on 127.0.0.1:3281, bridge on 127.0.0.1:47801
 *
 * Env: DSHM_RUNTIME (default ~/.dshm/runtime: npm install @deepseek-ai/dsh@0.2.2-rc.1
 * @deepseek-ai/dsh-llm-mock-server@0.2.2-rc.1), DSHM_HOME (default ~/.dshm/home, the DSH_HOME),
 * DSHM_WEB_PORT (3281). Needs Node >= 24.9 and a pnpm on PATH (DSH's `dsh plugin` calls it).
 *
 * Bridge (read by bridge/src/index.ts resolveConfig): DSHM_BRIDGE_PORT (47801), DSHM_BRIDGE_HOST
 * for the local listener. This host uses TLS 1.3. Pair using the local bridge CLI.
 */
import { spawn, spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const RUNTIME = process.env.DSHM_RUNTIME ?? join(homedir(), '.dshm/runtime')
const DSH_HOME = process.env.DSHM_HOME ?? join(homedir(), '.dshm/home')
const WEB_PORT = Number(process.env.DSHM_WEB_PORT ?? 3281)
const DSH = join(RUNTIME, 'node_modules/.bin/dsh')
export const MOCK_TEXT = '你好！I am a DSH agent on your Mac. This reply is streamed through the dsh-mobile bridge.'

const die = (m) => { console.error(`dsh-up: ${m}`); process.exit(1) }
if (!existsSync(DSH)) die(`no DSH at ${DSH}; see the header of this script`)
if (!existsSync(join(ROOT, 'bridge/lib/src/index.js'))) die('build the bridge first: (cd bridge && pnpm build)')

const env = {
  ...process.env,
  DSH_HOME,
  DSHM_BRIDGE_HOST: process.env.DSHM_BRIDGE_HOST ?? '127.0.0.1',
}
const add = spawnSync(DSH, ['plugin', '--profile', 'web', 'add', join(ROOT, 'bridge')], { env, encoding: 'utf8' })
if (add.status !== 0) die(`dsh plugin add failed:\n${add.stdout}${add.stderr}`)
console.log(`dsh-up: bridge enabled in ${DSH_HOME}/profiles/web`)

const { startMockLlmServer } = await import(
  pathToFileURL(join(RUNTIME, 'node_modules/@deepseek-ai/dsh-llm-mock-server/lib/index.js')).href)
const mock = await startMockLlmServer({
  sequence: ['slow_success'], repeatLast: true, successText: MOCK_TEXT, chunkSize: 4, chunkDelayMs: 60,
})
console.log(`dsh-up: mock LLM at ${mock.baseURL}`)

const host = spawn(DSH, ['web', '--no-open', '--port', String(WEB_PORT)], {
  env: { ...env, DEEPSEEK_BASE_URL: `${mock.baseURL}/v1`, DEEPSEEK_API_KEY: 'mock-key' },
  stdio: ['ignore', 'pipe', 'pipe'],
})
const relay = (stream, out) => stream.on('data', (b) => out.write(String(b).replace(/token=\S+/g, 'token=<redacted>')))
relay(host.stdout, process.stdout)
relay(host.stderr, process.stderr)

let stopping = false
const stop = () => {
  stopping = true
  host.kill('SIGTERM')
}
process.on('SIGINT', stop)
process.on('SIGTERM', stop)
host.on('exit', async (code) => { await mock.close(); process.exit(code ?? (stopping ? 0 : 1)) })
