/**
 * dsh-mobile bridge: a Cordis plugin installed into the user's DSH profile (ARCHITECTURE §5).
 * Install and enable: see bridge/README.md.
 */
import { homedir } from 'node:os'
import { PlaintextChannel } from './channel.ts'
import { DshTasks, type DshServices } from './dsh.ts'
import { startBridgeServer, type BridgeServer } from './server.ts'

export const name = 'dsh-mobile-bridge'
export const inject = ['sessionController', 'workspaceController']

export interface Config {
  /** Listen address. T0's PlaintextChannel accepts loopback literals only. */
  host?: string
  port?: number
  /** Fixed workspace directory for new tasks (S7 adds a picker). */
  cwd?: string
}

export const DEFAULT_PORT = 47801

interface PluginContext extends DshServices {
  effect(setup: () => () => void): void
  logger?(name: string): { info(...args: unknown[]): void; warn(...args: unknown[]): void }
}

export function apply(ctx: PluginContext, config: Config = {}) {
  const logger = ctx.logger?.(name)
  const log = (m: string) => (logger ? logger.info(m) : console.log(`[${name}] ${m}`))
  ctx.effect(() => {
    let server: BridgeServer | undefined
    let disposed = false
    startBridgeServer({
      host: config.host ?? '127.0.0.1',
      port: config.port ?? DEFAULT_PORT,
      channel: new PlaintextChannel(),
      tasks: new DshTasks(ctx, config.cwd ?? homedir()),
      log,
    }).then(
      (s) => { if (disposed) void s.close(); else server = s },
      (error) => (logger ? logger.warn(`failed to start: ${String(error)}`) : console.error(error)),
    )
    return () => { disposed = true; void server?.close() }
  })
}
