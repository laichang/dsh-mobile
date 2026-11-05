#!/usr/bin/env node
/**
 * S2's local acceptance host: real DSH 0.2.2-rc.1 + this worktree's bridge, driven by DSH's mock
 * LLM (no API key), like scripts/dsh-up.mjs but on S2's own resources (PLAN.md §8, 2026-11-05)
 * and with a slow mock, so a task streams for several seconds and the app can be killed mid-task.
 * Runs in the foreground until SIGINT / SIGTERM.
 *
 * Env (defaults are S2's): DSHM_RUNTIME (~/.dshm/runtime, shared, read-only),
 * DSHM_HOME (~/.dshm/home-s2), DSHM_WEB_PORT (3284), DSHM_BRIDGE_PORT (47811),
 * DSHM_MOCK_CHUNK_DELAY_MS (250). Needs Node >= 24.9 and pnpm on PATH, and a built bridge.
 */
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const RUNTIME = process.env.DSHM_RUNTIME ?? join(homedir(), '.dshm/runtime')
const DSH_HOME = process.env.DSHM_HOME ?? join(homedir(), '.dshm/home-s2')
const WEB_PORT = Number(process.env.DSHM_WEB_PORT ?? 3284)
const BRIDGE_PORT = Number(process.env.DSHM_BRIDGE_PORT ?? 47811)
const CHUNK_DELAY_MS = Number(process.env.DSHM_MOCK_CHUNK_DELAY_MS ?? 250)
const DSH = join(RUNTIME, 'node_modules/.bin/dsh')
// Same text as scripts/dsh-up.mjs MOCK_TEXT; the UI tests compare against it.
export const MOCK_TEXT = '你好！I am a DSH agent on your Mac. This reply is streamed through the dsh-mobile bridge.'

const die = (m) => { console.error(`s2-host: ${m}`); process.exit(1) }
if (!existsSync(DSH)) die(`no DSH at ${DSH}; see the header of scripts/dsh-up.mjs`)
if (!existsSync(join(ROOT, 'bridge/lib/src/index.js'))) die('build the bridge first: (cd bridge && pnpm build)')

const env = { ...process.env, DSH_HOME }
const profile = join(DSH_HOME, 'profiles/web')
const add = spawnSync(DSH, ['plugin', '--profile', 'web', 'add', join(ROOT, 'bridge')], { env, encoding: 'utf8' })
if (add.status !== 0) die(`dsh plugin add failed:\n${add.stdout}${add.stderr}`)
mkdirSync(profile, { recursive: true })
writeFileSync(join(profile, 'cordis.patch.yml'),
  `# Written by scripts/demo/s2-host.mjs\n- id: dsh-mobile-bridge\n  config:\n    port: ${BRIDGE_PORT}\n`)
console.log(`s2-host: bridge enabled in ${profile} on port ${BRIDGE_PORT}`)

const { startMockLlmServer } = await import(
  pathToFileURL(join(RUNTIME, 'node_modules/@deepseek-ai/dsh-llm-mock-server/lib/index.js')).href)
const mock = await startMockLlmServer({
  sequence: ['slow_success'], repeatLast: true, successText: MOCK_TEXT, chunkSize: 4, chunkDelayMs: CHUNK_DELAY_MS,
})
console.log(`s2-host: mock LLM at ${mock.baseURL} (${CHUNK_DELAY_MS} ms per chunk)`)

const host = spawn(DSH, ['web', '--no-open', '--port', String(WEB_PORT)], {
  env: { ...env, DEEPSEEK_BASE_URL: `${mock.baseURL}/v1`, DEEPSEEK_API_KEY: 'mock-key' },
  stdio: ['ignore', 'pipe', 'pipe'],
})
const relay = (stream, out) => stream.on('data', (b) => out.write(String(b).replace(/token=\S+/g, 'token=<redacted>')))
relay(host.stdout, process.stdout)
relay(host.stderr, process.stderr)

const stop = async () => { host.kill('SIGTERM'); await mock.close(); process.exit(0) }
process.on('SIGINT', stop)
process.on('SIGTERM', stop)
host.on('exit', async (code) => { await mock.close(); process.exit(code ?? 1) })
