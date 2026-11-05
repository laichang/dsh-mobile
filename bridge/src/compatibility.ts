// DSH's launcher reads the version of its own app-boot package. Resolve it from
// the running launcher, not from the separately installed bridge package.
import { realpathSync } from 'node:fs'
import { createRequire } from 'node:module'

export const SUPPORTED_DSH = '0.2.2-rc.1'

export function runtimeDshVersion(entry = process.argv[1]): string {
  try {
    const manifest = createRequire(realpathSync(entry))('@deepseek-ai/dsh-app-boot/package.json')
    return typeof manifest.version === 'string' ? manifest.version : 'unknown'
  } catch {
    return 'unknown'
  }
}

export function supportsDsh(version: string): boolean {
  return version.split('+')[0] === SUPPORTED_DSH
}
