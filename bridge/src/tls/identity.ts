// The listener is the sole writer of this directory. Keep the key across certificate renewals.
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, X509Certificate } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { isIP } from 'node:net'
import { join } from 'node:path'
import type { ServerOptions } from 'node:https'

export function tlsIdentity(dir: string, hosts: readonly string[]) {
  mkdirSync(dir, { mode: 0o700, recursive: true })
  const keyPath = join(dir, 'host-key.pem')
  const certPath = join(dir, 'host-cert.pem')
  if (!existsSync(keyPath)) {
    const key = generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey
    writeFileSync(keyPath, key.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600, flag: 'wx' })
  }
  const key = readFileSync(keyPath)
  const publicKey = createPublicKey(createPrivateKey(key))
  const spkiSHA256 = createHash('sha256').update(publicKey.export({ type: 'spki', format: 'der' })).digest()
  const names = [...new Set(hosts)].map(h => {
    if (isIP(h)) return 'IP:' + h
    if (!h.length || h.length > 253 || !h.split('.').every(label =>
      /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(label))) throw new Error('invalid TLS DNS name')
    return 'DNS:' + h
  })
  if (!names.length) throw new Error('TLS requires an advertised DNS name or IP address')
  const previous = existsSync(certPath) ? new X509Certificate(readFileSync(certPath)) : undefined
  if (!previous || !previous.publicKey.equals(publicKey) || previous.validToDate.getTime() < Date.now() + 7 * 86400_000 ||
      !hosts.every(h => isIP(h) ? previous.checkIP(h) : previous.checkHost(h, { subject: 'never' }))) {
    const cert = execFileSync('openssl', ['req', '-x509', '-new', '-key', keyPath, '-sha256', '-days', '90',
      '-subj', '/CN=dsh-mobile bridge', '-addext', 'basicConstraints=critical,CA:FALSE',
      '-addext', 'keyUsage=critical,digitalSignature', '-addext', 'extendedKeyUsage=serverAuth',
      '-addext', 'subjectAltName=' + names.join(',')])
    writeFileSync(certPath + '.new', cert, { mode: 0o600 })
    renameSync(certPath + '.new', certPath)
  }
  const options: ServerOptions = { key, cert: readFileSync(certPath), minVersion: 'TLSv1.3', maxVersion: 'TLSv1.3' }
  return { options, spkiSHA256 }
}
