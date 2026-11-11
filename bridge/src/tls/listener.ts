import { createServer } from 'node:https'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { WebSocketServer, type WebSocket } from 'ws'
import { listenerInfo } from '../pairing/announce.ts'
import { splitAddress, type PairingOffer } from '../pairing/offer.ts'
import { tlsIdentity } from './identity.ts'
import { serveOffers } from './local-offers.ts'
import { TLSRegistry } from './registry.ts'

export async function listenTLS(host: string, port: number, stateDir: string,
  connected: (ws: WebSocket, id: string, store: TLSRegistry) => void) {
  mkdirSync(stateDir, { recursive: true, mode: 0o700 })
  let issue: ((ttl: number) => PairingOffer) | undefined
  const ipc = await serveOffers(stateDir, ttl => {
    if (!issue) throw new Error('listener starting')
    return issue(ttl)
  })
  try {
    const server = await startListener(host, port, stateDir, connected)
    issue = server.issue
    return { port: server.port, close: async () => {
      issue = undefined
      try { await server.close() } finally { await new Promise<void>(done => ipc.close(() => done())) }
    } }
  } catch (error) { ipc.close(); throw error }
}

async function startListener(host: string, port: number, stateDir: string,
  connected: (ws: WebSocket, id: string, store: TLSRegistry) => void) {
  const identity = tlsIdentity(join(stateDir, 'tls'), listenerInfo(host, port).addresses.map(a => splitAddress(a).host))
  const registry = new TLSRegistry(stateDir)
  const http = createServer(identity.options, (req, res) => {
    res.setHeader('cache-control', 'no-store')
    if (req.method === 'POST' && req.url === '/enroll') {
      const parts = /^Offer ([\w-]{22})\.([\w-]{43})$/.exec(req.headers.authorization ?? '')
      const entry = parts && registry.redeem(parts[1], parts[2])
      if (!entry) { res.writeHead(403).end(); return }
      res.writeHead(201, { 'content-type': 'application/json' }).end(JSON.stringify(entry))
      return
    }
    if (req.method === 'GET' && req.url === '/device') {
      const allowed = registry.authenticate(req.headers.authorization)
      res.writeHead(allowed ? 204 : 403, { 'x-dshm-device': allowed ? 'paired' : 'unknown' }).end()
      return
    }
    res.writeHead(404).end()
  })
  const wss = new WebSocketServer({ noServer: true })
  http.on('upgrade', (req, socket, head) => {
    const id = registry.authenticate(req.headers.authorization)
    if (req.url !== '/' || !id) {
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n')
      return
    }
    wss.handleUpgrade(req, socket, head, ws => {
      if (!registry.has(id)) { ws.close(4003, 'device revoked'); return }
      registry.seen(id)
      connected(ws, id, registry)
    })
  })
  await new Promise<void>((resolve, reject) => http.once('error', reject).listen(port, host, resolve))
  const address = http.address()
  if (!address || typeof address !== 'object') throw new Error('missing listener address')
  return {
    port: address.port,
    issue(ttl: number) {
      const info = listenerInfo(host, address.port)
      const renewed = tlsIdentity(join(stateDir, 'tls'), info.addresses.map(a => splitAddress(a).host))
      http.setSecureContext(renewed.options)
      return registry.issue(info, renewed.spkiSHA256, ttl)
    },
    close: async () => {
      for (const ws of wss.clients) ws.terminate()
      wss.close()
      await new Promise<void>(done => http.close(() => done()))
    },
  }
}
