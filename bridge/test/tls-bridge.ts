import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { WebSocket } from 'ws'
import { startBridgeServer, type BridgeServerOptions } from '../src/server.ts'
import { requestOffer } from '../src/tls/local-offers.ts'
import { redeem } from './tls-client.ts'

export type TestBridge = Awaited<ReturnType<typeof startTestBridge>>

export async function startTestBridge(options: BridgeServerOptions) {
  const dir = mkdtempSync(join(tmpdir(), 'dshm-test-host-'))
  try {
    const server = await startBridgeServer({ ...options, tlsStateDir: dir })
    return {
      ...server,
      async socket() {
        const offer = new URL(await requestOffer(dir, 60_000))
        const { bearer } = await redeem(dir, offer)
        return new WebSocket('wss://' + offer.searchParams.get('a')!.split(',')[0] + '/', {
          ca: readFileSync(join(dir, 'tls/host-cert.pem')), headers: { authorization: 'Bearer ' + bearer },
        })
      },
      async close() {
        try { await server.close() } finally { rmSync(dir, { recursive: true, force: true }) }
      },
    }
  } catch (error) {
    rmSync(dir, { recursive: true, force: true })
    throw error
  }
}
