/**
 * dsh-mobile bridge: a Cordis plugin installed into the user's DSH profile (ARCHITECTURE §5).
 * Install and enable: see bridge/README.md.
 */
import { homedir } from 'node:os'
import { join } from 'node:path'
import { PlaintextChannel } from './channel.ts'
import { DshTasks, type DshServices } from './dsh.ts'
import { listenerInfo, makeOffer, renderOffer } from './pairing/announce.ts'
import { NoiseResponder } from './pairing/handshake.ts'
import { PairingStore } from './pairing/store.ts'
import { startBridgeServer, type BridgeServer } from './server.ts'

export const name = 'dsh-mobile-bridge'
export const inject = ['sessionController', 'workspaceController']

export interface Config {
  /** Listen address. Default 0.0.0.0: every payload is Noise-encrypted (ARCHITECTURE D21). */
  host?: string
  port?: number
  /** Fixed workspace directory for new tasks (S7 adds a picker). */
  cwd?: string
  /** Host key, pairing offers and device registry. Default `$DSH_HOME/dsh-mobile-bridge`. */
  stateDir?: string
  /**
   * Development only: also serve unencrypted frames on `/plaintext`. Requires a loopback `host`;
   * the bridge refuses to start otherwise. Off by default.
   */
  devPlaintext?: boolean
}

export const DEFAULT_PORT = 47801

/**
 * Config from the profile's cordis.yml, then `DSHM_BRIDGE_*` environment variables (used by
 * scripts/dsh-up.mjs, so each worktree runs its own bridge), then defaults.
 */
export function resolveConfig(config: Config = {}, env: NodeJS.ProcessEnv = process.env) {
  const dshHome = env.DSH_HOME ?? join(homedir(), '.dsh')
  return {
    host: config.host ?? env.DSHM_BRIDGE_HOST ?? '0.0.0.0',
    port: config.port ?? (env.DSHM_BRIDGE_PORT ? Number(env.DSHM_BRIDGE_PORT) : DEFAULT_PORT),
    cwd: config.cwd ?? homedir(),
    stateDir: config.stateDir ?? env.DSHM_BRIDGE_STATE_DIR ?? join(dshHome, 'dsh-mobile-bridge'),
    devPlaintext: config.devPlaintext ?? env.DSHM_BRIDGE_DEV_PLAINTEXT === '1',
  }
}

interface PluginContext extends DshServices {
  effect(setup: () => () => void): void
  logger?(name: string): { info(...args: unknown[]): void; warn(...args: unknown[]): void }
}

export function apply(ctx: PluginContext, config: Config = {}) {
  const logger = ctx.logger?.(name)
  const log = (m: string) => (logger ? logger.info(m) : console.log(`[${name}] ${m}`))
  const c = resolveConfig(config)
  ctx.effect(() => {
    let server: BridgeServer | undefined
    let disposed = false
    const store = new PairingStore(c.stateDir)
    startBridgeServer({
      host: c.host,
      port: c.port,
      noise: new NoiseResponder(store, log),
      channel: c.devPlaintext ? new PlaintextChannel() : undefined,
      tasks: new DshTasks(ctx, c.cwd),
      log,
    }).then(
      (s) => {
        if (disposed) return void s.close()
        server = s
        store.writeListener(listenerInfo(c.host, s.port))
        // Terminal-first pairing: with no device yet, print a QR right away. More offers:
        // `node bridge/lib/scripts/pair.js` (see bridge/README.md).
        if (store.devices().length === 0) log(`\n${renderOffer(makeOffer(store))}`)
      },
      (error) => (logger ? logger.warn(`failed to start: ${String(error)}`) : console.error(error)),
    )
    return () => { disposed = true; void server?.close() }
  })
}
