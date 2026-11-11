import { createServer, request } from 'node:http'
import { chmodSync, lstatSync, mkdirSync, realpathSync, rmSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { connect } from 'node:net'
import { join } from 'node:path'
import { offerURL, type PairingOffer } from '../pairing/offer.ts'

export function offerSocket(stateDir: string) {
  if (!process.getuid) throw new Error('TLS enrollment requires Unix domain sockets and owner-only permissions')
  const id = createHash('sha256').update(realpathSync(stateDir)).digest('hex').slice(0, 24)
  const dir = '/tmp/dshm-pair-' + process.getuid() + '-' + id
  mkdirSync(dir, { mode: 0o700, recursive: true })
  const st = lstatSync(dir)
  if (!st.isDirectory() || st.uid !== process.getuid() || (st.mode & 0o077)) throw new Error('unsafe pairing socket directory')
  return join(dir, 'offer.sock')
}

export async function serveOffers(stateDir: string, issue: (ttl: number) => PairingOffer) {
  const socketPath = offerSocket(stateDir)
  const server = createServer((req, res) => {
    if (req.method !== 'POST' || req.url !== '/offer') { res.writeHead(404).end(); return }
    try {
      const link = offerURL(issue(Number(req.headers['x-offer-ttl-ms'])))
      res.writeHead(200, { 'cache-control': 'no-store' }).end(link)
    } catch { res.writeHead(400).end() }
  })
  const listen = () => new Promise<void>((resolve, reject) => {
    server.once('error', reject).listen(socketPath, () => { server.off('error', reject); resolve() })
  })
  try { await listen() } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'EADDRINUSE') throw error
    const old = lstatSync(socketPath)
    const stale = await new Promise<boolean>(resolve => {
      const peer = connect(socketPath, () => { peer.destroy(); resolve(false) })
      peer.once('error', e => resolve((e as NodeJS.ErrnoException).code === 'ECONNREFUSED'))
    })
    if (!stale || !old.isSocket() || lstatSync(socketPath).ino !== old.ino) throw error
    rmSync(socketPath)
    await listen()
  }
  chmodSync(socketPath, 0o600)
  return server
}

export function requestOffer(stateDir: string, ttl: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const req = request({ socketPath: offerSocket(stateDir), method: 'POST', path: '/offer',
      headers: { 'x-offer-ttl-ms': ttl } }, res => {
      let text = ''
      res.on('data', chunk => { text += chunk })
      res.on('end', () => res.statusCode === 200 ? resolve(text) : reject(new Error('offer request refused')))
      res.on('error', reject)
    })
    req.on('error', reject)
    req.end()
  })
}
