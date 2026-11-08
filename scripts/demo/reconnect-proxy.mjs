#!/usr/bin/env node
// An address of the host that goes away after one connection (scripts/demo/reconnect.sh).
// It forwards its first TCP connection to the bridge and stops listening at once, so every later
// connection to it is refused, like a LAN address after the phone left that network.
//
//   node scripts/demo/reconnect-proxy.mjs <listen port> <bridge port>
import net from 'node:net'

const [listenPort, bridgePort] = process.argv.slice(2).map(Number)
if (!listenPort || !bridgePort) {
  console.error('usage: reconnect-proxy.mjs <listen port> <bridge port>')
  process.exit(2)
}

const server = net.createServer((client) => {
  server.close()
  console.log(`reconnect-proxy: forwarded one connection; ${listenPort} is now dead`)
  const bridge = net.connect(bridgePort, '127.0.0.1')
  client.pipe(bridge)
  bridge.pipe(client)
  const end = () => {
    client.destroy()
    bridge.destroy()
  }
  for (const s of [client, bridge]) {
    s.on('error', end)
    s.on('close', end)
  }
})
server.listen(listenPort, '127.0.0.1', () => console.log(`reconnect-proxy: ready on ${listenPort} -> ${bridgePort}`))
