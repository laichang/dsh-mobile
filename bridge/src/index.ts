/**
 * dsh-mobile bridge: a Cordis plugin installed into the user's DSH profile (ARCHITECTURE §5).
 * Install and enable: see bridge/README.md.
 */
import { runtimeDshVersion, supportsDsh } from './compatibility.ts'
import { ApprovalHolder, type ApprovalContext } from './approvals/holder.ts'
import { QuestionHolder, type QuestionContext } from './questions/holder.ts'
import { SessionDirectory, type SessionReader } from './sessions/directory.ts'
import { TaskHub } from './tasks/task-hub.ts'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { PlaintextChannel } from './channel.ts'
import { describeListenError, type ListenSetting } from './listen-error.ts'
import { DshTasks, type DshServices } from './dsh.ts'
import { listenerInfo, makeOffer, renderOffer } from './pairing/announce.ts'
import { NoiseResponder } from './pairing/handshake.ts'
import { PairingStore } from './pairing/store.ts'
import { startBridgeServer, type BridgeServer } from './server.ts'

export const name = 'dsh-mobile-bridge'
const dshVersion = runtimeDshVersion()
const supported = supportsDsh(dshVersion)
// `fileUploads` stages attachments; DSH 0.2.2-rc.1 has it in every profile.
export const inject = supported ? ['sessionController', 'workspaceController', 'workspaceRegistry', 'fileUploads'] : []

export interface Config {
  /** Listen address. Default 0.0.0.0: every payload is Noise-encrypted. */
  host?: string
  port?: number
  /** Default workspace directory for tasks without an explicit choice. Default: DSH's default Workspace, else the home directory. */
  cwd?: string
  /** Host key, pairing offers and device registry. Default `$DSH_HOME/dsh-mobile-bridge`. */
  stateDir?: string
  approvalTimeoutMs?: number
  /**
   * Development only: also serve unencrypted frames on `/plaintext`. Requires a loopback `host`;
   * the bridge refuses to start otherwise. Off by default.
   */
  tls?: boolean
  devPlaintext?: boolean
}

export const DEFAULT_PORT = 47801

/**
 * Config from the profile's cordis.yml, then `DSHM_BRIDGE_*` environment variables (used by
 * scripts/dsh-up.mjs, so each worktree runs its own bridge), then defaults.
 */
export function resolveConfig(config: Config = {}, env: NodeJS.ProcessEnv = process.env) {
  const dshHome = env.DSH_HOME ?? join(homedir(), '.dsh')
  const portFrom: ListenSetting['portFrom'] = config.port !== undefined ? 'config' : env.DSHM_BRIDGE_PORT ? 'env' : 'default'
  return {
    host: config.host ?? env.DSHM_BRIDGE_HOST ?? '0.0.0.0',
    port: config.port ?? (env.DSHM_BRIDGE_PORT ? Number(env.DSHM_BRIDGE_PORT) : DEFAULT_PORT),
    /** Where `port` came from, so a listen failure names the setting to change. */
    portFrom,
    cwd: config.cwd,
    stateDir: config.stateDir ?? env.DSHM_BRIDGE_STATE_DIR ?? join(dshHome, 'dsh-mobile-bridge'),
    approvalTimeoutMs: config.approvalTimeoutMs,
    tls: config.tls ?? env.DSHM_BRIDGE_TLS === '1',
    devPlaintext: config.devPlaintext ?? env.DSHM_BRIDGE_DEV_PLAINTEXT === '1',
  }
}

type PluginContext = DshServices & ApprovalContext & QuestionContext & {
  sessionController: SessionReader
  on(name: 'session/event', callback: (session: { id: string }, event: Parameters<SessionDirectory['changed']>[1]) => void): () => void
  effect(setup: () => () => void): void
  logger?(name: string): { info(...args: unknown[]): void; warn(...args: unknown[]): void; error?(...args: unknown[]): void }
}

export function apply(ctx: PluginContext, config: Config = {}) {
  const logger = ctx.logger?.(name)
  const log = (m: string) => (logger ? logger.info(m) : console.log(`[${name}] ${m}`))
  const c = resolveConfig(config)
  ctx.effect(() => {
    let server: BridgeServer | undefined
    let disposed = false
    const store = new PairingStore(c.stateDir)
    const tasks = new DshTasks(ctx, c.cwd)
    const hub = new TaskHub(tasks)
    const sessions = supported ? new SessionDirectory(ctx.sessionController, hub, log) : undefined
    const stopSessions = sessions && ctx.on('session/event', (session, event) => sessions.changed(session.id, event))
    const approvals = new ApprovalHolder(join(c.stateDir, 'approvals.jsonl'), event => hub.approvalChanged(event, !tasks.sessions.has(event.taskId)), c.approvalTimeoutMs)
    const unregister = supported ? approvals.register(ctx) : undefined
    const questions = new QuestionHolder(event => hub.questionChanged(event))
    const unregisterQuestions = supported ? questions.register(ctx) : undefined
    startBridgeServer({
      host: c.host,
      port: c.port,
      noise: c.tls ? undefined : new NoiseResponder(store, log),
      tlsStateDir: c.tls ? c.stateDir : undefined,
      channel: c.devPlaintext ? new PlaintextChannel() : undefined,
      tasks, hub, approvals, questions, sessions, dshVersion,
      log,
    }).then(
      (s) => {
        if (disposed) return void s.close()
        server = s
        store.writeListener({ ...listenerInfo(c.host, s.port), ...(c.tls ? { tls: true } : {}) })
        // Terminal-first pairing: with no device yet, print a QR right away. More offers:
        // `node bridge/lib/scripts/pair.js` (see bridge/README.md).
        if (!c.tls && store.devices().length === 0) log(`\n${renderOffer(makeOffer(store))}`)
      },
      (error) => {
        stopSessions?.(); sessions?.close()
        unregister?.(); unregisterQuestions?.()
        approvals.close(); questions.close()
        // The phone cannot learn why, so this one line names the address, the cause and the
        // setting to change. DSH keeps running without the listener. The terminal gets it on
        // stderr: `dsh web` (0.2.2-rc.1) gives the Cordis logger no console exporter, so a
        // logger line alone reaches only DSH's own exporters (startup diagnostics, inspectors).
        const line = describeListenError(error, c)
        console.error(`[${name}] ${line}`)
        if (logger?.error) logger.error(line)
        else logger?.warn(line)
      },
    )
    return () => { disposed = true; stopSessions?.(); sessions?.close(); unregister?.(); unregisterQuestions?.(); approvals.close(); questions.close(); void server?.close() }
  })
}
