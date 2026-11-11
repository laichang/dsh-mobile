// Stand in for a changed host key, an unrelated responder or a redirect while an enrolled phone reconnects.
import { createServer } from 'node:https'
import { join } from 'node:path'
import { writeFileSync } from 'node:fs'
import { tlsIdentity } from '../src/tls/identity.ts'

const [mode, stateDir, temp, portText] = process.argv.slice(2)
const identity = tlsIdentity(mode === 'wrong-key' ? join(temp, 'other') : join(stateDir, 'tls'), ['127.0.0.1'])
let received = 0, authenticated = 0, forwarded = 0
const save = () => writeFileSync(join(temp, 'counts.json'), JSON.stringify({ received, authenticated, forwarded }))
const destination = createServer(identity.options, (_req, res) => { forwarded++; save(); res.writeHead(403).end() })
await new Promise<void>(r => destination.listen(0, '127.0.0.1', r))
const addr = destination.address()
if (!addr || typeof addr !== 'object') throw new Error('missing destination')
const server = createServer(identity.options, (req, res) => {
  received++
  if (req.headers.authorization?.startsWith('Bearer ')) authenticated++
  save()
  if (mode === 'redirect') res.writeHead(307, { location: 'https://127.0.0.1:' + addr.port + '/device' }).end()
  else res.writeHead(403).end()
})
server.listen(Number(portText), '127.0.0.1', save)
