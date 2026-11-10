/**
 * Why the bridge could not open its listener, as one line for DSH's log and the terminal
 *. A bridge that cannot listen cannot tell the phone anything, so this line
 * is the only place the host says why: it names the address, the cause and the fix. DSH keeps
 * running without the bridge's listener.
 */

/** Where the listen address came from, so the fix names the setting to change. */
export interface ListenSetting {
  host: string
  port: number
  /** `config`: the `dsh-mobile-bridge` entry of the profile's cordis.yml; `env`: `DSHM_BRIDGE_PORT`; `default`: neither. */
  portFrom: 'config' | 'env' | 'default'
}

/** The setting a user changes to move the bridge to another port. */
function portSettingName(from: ListenSetting['portFrom']): string {
  return from === 'env'
    ? 'DSHM_BRIDGE_PORT'
    : "`port` in the dsh-mobile-bridge entry of the DSH profile's cordis.yml"
}

/** One line: what failed, why, and what to change. */
export function describeListenError(error: unknown, at: ListenSetting): string {
  const code = typeof error === 'object' && error && 'code' in error ? String((error as { code: unknown }).code) : ''
  const where = `${at.host}:${at.port}`
  const head = `dsh-mobile-bridge cannot listen on ${where}`
  const tail = 'The phone cannot connect until this is fixed; DSH keeps running.'
  const setting = portSettingName(at.portFrom)
  switch (code) {
    case 'EADDRINUSE':
      return `${head}: another program uses port ${at.port} (EADDRINUSE). ${tail} ` +
        `Fix: stop that program (\`lsof -nP -iTCP:${at.port} -sTCP:LISTEN\` shows it), or change ${setting} to a free port, restart DSH and pair the phone again.`
    case 'EACCES':
      return `${head}: this user may not open port ${at.port} (EACCES). ${tail} ` +
        `Fix: change ${setting} to a port from 1024 to 65535, restart DSH and pair the phone again.`
    case 'EADDRNOTAVAIL':
      return `${head}: ${at.host} is not an address of this computer (EADDRNOTAVAIL). ${tail} ` +
        "Fix: set `host` in the dsh-mobile-bridge entry of the DSH profile's cordis.yml (or DSHM_BRIDGE_HOST) to 0.0.0.0, then restart DSH."
    default: {
      const message = error instanceof Error ? error.message : String(error)
      return `${head}: ${message}${code && !message.includes(code) ? ` (${code})` : ''}. ${tail}`
    }
  }
}
