// Loopback integration peer for the iOS transport. Tests only transmit a public sentinel.
import { fromBinary, toBinary } from '@bufbuild/protobuf'
import { FrameSchema } from '../src/gen/frame_pb.ts'
import { TLSSocket } from 'node:tls'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, unlinkSync } from 'node:fs'
import { createServer, type ServerOptions } from 'node:https'
import { createServer as createHttpServer } from 'node:http'
import { join } from 'node:path'
import { WebSocketServer } from 'ws'
import { X509Certificate } from 'node:crypto'
import { tlsIdentity } from '../src/tls/identity.ts'

const dir = process.argv[2]
const hosts = ['localhost', '127.0.0.1']
const host = tlsIdentity(dir, hosts)
const certificate = new X509Certificate(host.options.cert as Buffer)
const hello = readFileSync('../protocol/fixtures/core_hello_request.binpb')
const reply = readFileSync('../protocol/fixtures/core_hello_response.binpb')
const sentinel = 'Bearer public-transport-sentinel'
const counts: Record<string, number> = {}
async function listen(label: string, options?: ServerOptions, redirect?: number) {
  const server = options ? createServer(options) : createHttpServer()
  counts[label] = 0
  const websocket = new WebSocketServer({ noServer: true })
  server.on('upgrade', (req, socket, head) => {
    counts[label]++
    writeFileSync(join(dir, 'counts.json'), JSON.stringify(counts))
    if (redirect) {
      socket.end('HTTP/1.1 302 Found\r\nLocation: wss://localhost:' + redirect + '/\r\nContent-Length: 0\r\n\r\n')
      return
    }
    assert.equal(req.headers.authorization, sentinel)
    assert(req.socket instanceof TLSSocket && req.socket.getProtocol() === 'TLSv1.3')
    websocket.handleUpgrade(req, socket, head, ws => ws.on('message', data => {
      assert(Buffer.isBuffer(data))
      if (data.equals(hello)) {
        ws.send(reply)
        if (label === 'ip') server.close()
        return
      }
      const frame = fromBinary(FrameSchema, data)
      assert(frame.kind.case === 'request' && frame.kind.value.body.case === 'hello')
      const response = fromBinary(FrameSchema, reply)
      assert(response.kind.case === 'response')
      response.kind.value.requestId = frame.kind.value.id
      ws.send(toBinary(FrameSchema, response))
    }))
  })
  await new Promise<void>((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve))
  const addr = server.address()
  assert(addr && typeof addr === 'object')
  return addr.port
}

const ports: Record<string, number> = {}
ports.ip = await listen('ip', host.options)
// Renew for an additional address while retaining the enrolled key.
const renewed = tlsIdentity(dir, [...hosts, '127.0.0.2'])
assert.deepEqual(renewed.spkiSHA256, host.spkiSHA256)
assert.notEqual(certificate.serialNumber, new X509Certificate(renewed.options.cert as Buffer).serialNumber)
ports.renewed = await listen('renewed', renewed.options)
ports.wrongKey = await listen('wrongKey', tlsIdentity(join(dir, 'other'), hosts).options)
ports.oldTLS = await listen('oldTLS', { ...host.options, minVersion: 'TLSv1.2', maxVersion: 'TLSv1.2' })
ports.cleartext = await listen('cleartext')
ports.destination = await listen('destination', host.options)
ports.redirect = await listen('redirect', host.options, ports.destination)
// Same key, but DNS-only SAN: a connection by IP must fail.
unlinkSync(join(dir, 'host-cert.pem'))
ports.wrongName = await listen('wrongName', tlsIdentity(dir, ['localhost']).options)
const key = join(dir, 'host-key.pem')
const csr = execFileSync('openssl', ['req', '-new', '-key', key, '-subj', '/CN=localhost'])
for (const [label, days, usage] of [['expired', '0', 'serverAuth'], ['wrongUsage', '1', 'clientAuth']]) {
  const ext = join(dir, 'extensions')
  writeFileSync(ext, 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n' +
    'extendedKeyUsage=' + usage + '\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n')
  const cert = execFileSync('openssl', ['x509', '-req', '-signkey', key, '-days', days, '-extfile', ext], { input: csr })
  ports[label] = await listen(label, { ...host.options, cert })
}
writeFileSync(join(dir, 'client.json'), JSON.stringify({ pin: host.spkiSHA256.toString('base64'),
  hello: hello.toString('base64'), reply: reply.toString('base64'), ports }))
