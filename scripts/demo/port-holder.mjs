#!/usr/bin/env node
/**
 * Another program on the bridge's port (scripts/demo/bridge-errors.sh): a small HTTP server, as
 * a web app in development would be. It answers every request with 404 and takes no WebSocket.
 *
 *   node scripts/demo/port-holder.mjs <port> [host]   prints "port-holder: ready" once it listens
 */
import { createServer } from 'node:http'

const port = Number(process.argv[2])
const host = process.argv[3] ?? '127.0.0.1'
if (!Number.isInteger(port) || port <= 0) {
  console.error('usage: port-holder.mjs <port> [host]')
  process.exit(2)
}
const server = createServer((req, res) => {
  console.log(`port-holder: ${req.method} ${req.url}`)
  res.writeHead(404, { 'content-type': 'text/plain' })
  res.end('not a DSH bridge\n')
})
// A WebSocket handshake gets the same answer: this program does not upgrade.
server.on('upgrade', (req, socket) => {
  console.log(`port-holder: ${req.method} ${req.url} (upgrade: ${req.headers.upgrade})`)
  socket.end('HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 17\r\nConnection: close\r\n\r\nnot a DSH bridge\n')
})
server.on('error', (error) => { console.error(`port-holder: ${error.message}`); process.exit(1) })
server.listen(port, host, () => console.log(`port-holder: ready on ${host}:${port}`))
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)))
