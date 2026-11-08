/**
 * The phone dispatch adapter (ARCHITECTURE D4). It maps a dsh-mobile task onto one
 * DSH session (D13): create a session in its selected workspace, prompt it, follow its log, and turn
 * the follow stream into plain task output. Types are structural subsets of the DSH 0.2.2-rc.1
 * `sessionController` / `workspaceController` services, so `FakeDSH` can implement them in tests.
 */
import { catalogFrame, type HostCatalog, type Selection } from './models/catalog.ts'
import { randomUUID } from 'node:crypto'
import { homedir } from 'node:os'
import { isAbsolute } from 'node:path'
import { MilestoneMapper, failureOf, isUserInterrupt, type Milestone } from './milestones/mapper.ts'
import { TranscriptMapper, type BlockOut } from './transcript/mapper.ts'
import type { StagedImage } from './attachments/staging.ts'

/** Subset of `ctx.workspaceController` (`@deepseek-ai/dsh-api-workspace-controller`). */
export interface WorkspaceControllerLike {
  create(request: { path: string }): Promise<{ workspace: { workspaceId: string } }>
}

/** One frame of `sessionController.follow` that the bridge reads; everything else is ignored. */
export type FollowFrame =
  | { type: 'snapshot' }
  | { type: 'event'; event: { type: string; seq: number; time?: number; data: unknown } }
  | { type: 'assistant-stream'; frame: { type: 'start' | 'end' } | { type: 'chunk'; chunk: unknown; time?: number } }

/** `steer`: the next step of the running turn, or a new turn on an idle session. `queue`: the next turn (D18). */
export type PromptMode = 'steer' | 'queue'

/** Subset of `ctx.sessionController` (`@deepseek-ai/dsh-api-session-controller`). */
export interface SessionControllerLike {
  modelCatalog(): Promise<HostCatalog>
  selectModel(request: Selection & { sessionId: string }): Promise<{ selected: Selection }>
  create(request: { workspaceId: string }): Promise<{ sessionId: string }>
  cancel(request: { sessionId: string }): { accepted: true }
  prompt(
    request: { requestId: string; sessionId: string; mode: PromptMode; content: readonly PromptPart[] },
    signal: AbortSignal,
  ): Promise<unknown>
  follow(
    request: { address: { kind: 'session'; sessionId: string }; assistantStream: true; activate?: boolean },
    signal: AbortSignal,
  ): AsyncIterable<FollowFrame>
  /** D101: the session's inbox: messages that wait for the next step (`steering`) or the next turn (`queued`). */
  state(request: { sessionId: string }, signal: AbortSignal): Promise<{ running: boolean; queue: readonly QueueItem[] | null }>
  /** D101: moves a waiting message into the running turn, or takes it out. `itemId` is DSH's own ID of the item. */
  updateQueue(request: { sessionId: string; itemId: string; action: { kind: 'steer' } | { kind: 'remove' } }): Promise<unknown>
}

/** One waiting message of `sessionController.state().queue`; `rpcId` is the prompt's `requestId`. */
export interface QueueItem {
  id: string
  placement: 'queued' | 'steering' | 'context'
  rpcId?: string
}

/** D101: the message is not in the session's inbox any more (DSH took it, or it was removed). */
export class QueueItemGone extends Error {
  constructor() { super('This message is no longer waiting.') }
}

/** A prompt part: text, or a file staged through `fileUploads` (an image receipt enters as that image). */
export type PromptPart = { type: 'text'; text: string } | { type: 'file'; receiptId: string }

/** Subset of `ctx.fileUploads` (`@deepseek-ai/dsh-client-file-upload`). */
export interface FileUploadsLike {
  uploadImageStream(request: {
    sessionId: string; data: AsyncIterable<Uint8Array>; mediaType: string; name?: string; signal?: AbortSignal
  }): Promise<{ receiptId: string }>
}

export interface DshServices {
  /** Attachments (D95); absent on a host without the service. */
  fileUploads?: FileUploadsLike
  sessionController: SessionControllerLike
  workspaceRegistry: { list(): readonly { path: string; title?: string; updatedAt: string }[] }
  workspaceController: WorkspaceControllerLike
}

/** What a running task produces, in order. Exactly one `end`, always last. */
export type TaskOutput =
  | { kind: 'text'; text: string }
  | { kind: 'model'; selection: Selection }
  | { kind: 'milestone'; milestone: Milestone }
  | { kind: 'block'; block: BlockOut } // S17
  | { kind: 'turn'; turn: number } // D89: the DSH turn number, once the turn starts
  | { kind: 'user'; messageId: string; text: string } // D101: DSH took a user message into the turn (its `requestId`)
  | { kind: 'end'; status: 'completed' | 'interrupted' | 'failed'; message?: string; /** D104: DSH's failure class. */ code?: string }

/** One more turn of a task's session (D89): its output, and the DSH turn it waits for. */
export interface FollowUpOptions {
  /** The message's ID: also DSH's `requestId`, so a repeated send is accepted once. */
  messageId: string
  mode: PromptMode
  /** The latest DSH turn number the task has seen; the new turn has a larger one. */
  afterTurn?: number
  /** D101: asked when a turn completes; true when another turn of the task follows (a queued message). */
  continues?: Continues
  /** D110: map this turn's milestones too (it continues a task whose last turn failed). Default false. */
  milestones?: boolean
}

/** D101: asked when a turn completes; true keeps following the session into its next turn. */
export type Continues = () => Promise<boolean>

export interface StartedTask {
  taskId: string
  output: AsyncIterable<TaskOutput>
  /** S14: the directory the session was created in. */
  workspace?: string
}

/**
 * DSH's own default Workspace: the first-use directory `<Documents>/deepseek-harness/default-workspace`,
 * whose automatic title DSH Web labels 默认工作区 (`DEFAULT_WORKSPACE_DIRECTORY` in
 * `@deepseek-ai/dsh-api-workspace-controller`).
 */
export const DSH_DEFAULT_WORKSPACE_TITLE = 'default-workspace'

/** Starts tasks on DSH. `cwd` is the default when the phone sends no workspace. */
export class DshTasks {
  readonly sessions = new Set<string>()

  /**
   * @param configured - the `cwd` from the plugin config. Without it, the default is DSH's own default
   * Workspace, so the phone's 默认工作区 is the one DSH Web shows; without that, the home directory.
   */
  constructor(private readonly dsh: DshServices, private readonly configured?: string,
              private readonly fallback = homedir()) {}

  get cwd(): string {
    return this.configured
      ?? this.dsh.workspaceRegistry.list().find(w => w.title === DSH_DEFAULT_WORKSPACE_TITLE)?.path
      ?? this.fallback
  }

  listWorkspaces() {
    const cwd = this.cwd
    const recentPaths = this.dsh.workspaceRegistry.list()
      .filter(workspace => workspace.path !== cwd)
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
      .map(workspace => workspace.path)
    return { defaultPath: cwd, recentPaths }
  }

  interrupt(taskId: string): void {
    this.dsh.sessionController.cancel({ sessionId: taskId })
  }

  async modelCatalog() {
    return catalogFrame(await this.dsh.sessionController.modelCatalog())
  }

  async selectModel(taskId: string, selection: Selection): Promise<Selection> {
    const { provider, model, reasoningEffort } = selection
    const { selected } = await this.dsh.sessionController.selectModel({
      sessionId: taskId, provider, model, ...(reasoningEffort === undefined ? {} : { reasoningEffort }),
    })
    return selected
  }

  /** True when the host can stage images for a prompt (`attachments.v1`). */
  get attachments(): boolean { return !!this.dsh.fileUploads }

  async start(prompt: string, signal: AbortSignal, selection?: Selection, path?: string,
              images: readonly StagedImage[] = [], continues?: Continues): Promise<StartedTask> {
    if (images.length && !this.dsh.fileUploads) throw new Error('This host cannot take attachments.')
    path ??= this.cwd
    if (!isAbsolute(path)) throw new Error('Choose an absolute workspace path on this host.')
    const { workspace } = await this.dsh.workspaceController.create({ path })
    const { sessionId } = await this.dsh.sessionController.create({ workspaceId: workspace.workspaceId })

    // Open the follow before prompting, so the turn's first frames can't be missed.
    const follow = this.dsh.sessionController.follow(
      { address: { kind: 'session', sessionId }, assistantStream: true, activate: true }, signal)
    const iterator = follow[Symbol.asyncIterator]()
    const first = await iterator.next() // the opening snapshot

    // An approval can arrive before prompt() returns. Distinguish our tasks from requests made by another client.
    this.sessions.add(sessionId)
    const requestId = randomUUID()
    try {
      if (selection) await this.selectModel(sessionId, selection)
      const content: PromptPart[] = [{ type: 'text', text: prompt }]
      for (const image of images) {
        // D95: stage the checked bytes as a prompt image; its receipt enters the message as that image.
        const { receiptId } = await this.dsh.fileUploads!.uploadImageStream({
          sessionId, data: once(image.data), mediaType: image.mediaType, name: image.name, signal,
        })
        content.push({ type: 'file', receiptId })
      }
      await this.dsh.sessionController.prompt({ requestId, sessionId, mode: 'queue', content }, signal)
    } catch (error) {
      this.sessions.delete(sessionId)
      await iterator.return?.()
      throw error
    }

    return { taskId: sessionId, output: mapFollow(first, iterator, { continues, ownRequest: requestId }), workspace: path }
  }

  /**
   * D89: one more message into the task's DSH session. Opens a follow first, so the new turn's
   * first frames can't be missed, then prompts. Rejects when DSH does not accept the message.
   */
  async followUp(taskId: string, text: string, options: FollowUpOptions, signal: AbortSignal): Promise<AsyncIterable<TaskOutput>> {
    const follow = this.dsh.sessionController.follow(
      { address: { kind: 'session', sessionId: taskId }, assistantStream: true, activate: true }, signal)
    const iterator = follow[Symbol.asyncIterator]()
    const first = await iterator.next()
    try {
      await this.dsh.sessionController.prompt(
        { requestId: options.messageId, sessionId: taskId, mode: options.mode, content: [{ type: 'text', text }] }, signal)
    } catch (error) {
      await iterator.return?.()
      throw error
    }
    return mapFollow(first, iterator,
      { afterTurn: options.afterTurn, prefixTurns: true, milestones: options.milestones ?? false, continues: options.continues })
  }

  /**
   * D101: a message into the session of a running task, with no follow of its own: the task's
   * running follow maps what it brings. `queue` waits for the next turn; `steer` goes in at the next step.
   */
  async prompt(taskId: string, text: string, options: { messageId: string; mode: PromptMode }, signal: AbortSignal): Promise<void> {
    await this.dsh.sessionController.prompt(
      { requestId: options.messageId, sessionId: taskId, mode: options.mode, content: [{ type: 'text', text }] }, signal)
  }

  /**
   * D101: moves a waiting message into the running turn (`steer`), or takes it out (`remove`), with
   * DSH's own queue edit. Finds DSH's item by the message's `requestId`. Returns false when DSH can
   * no longer steer into the turn (the turn is ending; the message then runs as the next turn).
   * Throws `QueueItemGone` when the message does not wait any more.
   */
  async editQueue(taskId: string, messageId: string, action: 'steer' | 'remove'): Promise<boolean> {
    const controller = this.dsh.sessionController
    const { queue } = await controller.state({ sessionId: taskId }, AbortSignal.timeout(10_000))
    const item = queue?.find(i => i.rpcId === messageId)
    if (!item) throw new QueueItemGone()
    try {
      await controller.updateQueue({ sessionId: taskId, itemId: item.id, action: { kind: action } })
      return true
    } catch (error) {
      const code = (error as { code?: unknown } | null)?.code
      if (code === 'session/steer-unavailable') return false
      if (code === 'session/queue-item-not-found') throw new QueueItemGone()
      throw error
    }
  }

  /** D101: whether the session's agent runs, and the `requestId`s of the messages in its inbox. */
  async inbox(taskId: string): Promise<{ running: boolean; waiting: string[] }> {
    const { running, queue } = await this.dsh.sessionController.state({ sessionId: taskId }, AbortSignal.timeout(10_000))
    return { running, waiting: (queue ?? []).flatMap(i => i.placement !== 'context' && i.rpcId ? [i.rpcId] : []) }
  }
}

interface MapOptions {
  /** Wait for a turn after this one (follow-ups); undefined takes the first turn that starts. */
  afterTurn?: number
  /** D89: the first mapped turn's block IDs get a `turn-N-` prefix too (later turns always do). */
  prefixTurns?: boolean
  /** Milestones map the task's first turn (S3), and a turn that continues after a failure (D110). */
  milestones?: boolean
  /** D101: asked when a turn completes; true maps the session's next turn too (a queued message). */
  continues?: Continues
  /** The `requestId` of the task's first prompt: its user message is the task's title, not a follow-up. */
  ownRequest?: string
}

async function* once(data: Uint8Array): AsyncGenerator<Uint8Array> { yield data }

async function* mapFollow(
  first: IteratorResult<FollowFrame>, iterator: AsyncIterator<FollowFrame>, options: MapOptions = {},
): AsyncGenerator<TaskOutput> {
  let turn: number | undefined
  let afterTurn = options.afterTurn
  let prefixTurns = options.prefixTurns ?? false
  let mapsMilestones = options.milestones ?? true
  const milestones = new MilestoneMapper()
  let blocks = new TranscriptMapper() // S17
  try {
    for (let next = first; !next.done; next = await iterator.next()) {
      const f = next.value
      if (f.type === 'event' && f.event.type === 'turn/start' && turn === undefined && prefixTurns) {
        // D89: a later turn's thinking block IDs get its DSH turn number, so they stay unique per task.
        const started = (f.event.data as { turn?: unknown } | null)?.turn
        if (typeof started === 'number' && (afterTurn === undefined || started > afterTurn)) {
          blocks = new TranscriptMapper(`turn-${started}-`)
        }
      }
      if (f.type === 'assistant-stream') for (const block of blocks.stream(f.frame)) yield { kind: 'block', block }
      if (f.type === 'event') for (const block of blocks.event(f.event)) yield { kind: 'block', block }
      if (f.type === 'assistant-stream' && f.frame.type === 'chunk') {
        const chunk = f.frame.chunk as { type?: string; text?: unknown } | null
        if (chunk?.type === 'text-delta' && typeof chunk.text === 'string' && chunk.text) {
          yield { kind: 'text', text: chunk.text }
        }
      } else if (f.type === 'event') {
        if (f.event.type === 'model/selection') {
          const selection = f.event.data as Selection
          yield { kind: 'model', selection }
        }
        if (mapsMilestones) for (const milestone of milestones.map(f.event)) yield { kind: 'milestone', milestone }
        const data = f.event.data as { turn?: number; reason?: { kind?: string; error?: unknown; reason?: { kind?: string } } } | null
        if (f.event.type === 'turn/start' && turn === undefined
            && (afterTurn === undefined || (typeof data?.turn === 'number' && data.turn > afterTurn))) {
          turn = data?.turn
          if (typeof turn === 'number') yield { kind: 'turn', turn }
        }
        // D101: DSH took a user message into the turn (a follow-up, queued or sent now): it sits here.
        const user = f.event.data as { source?: { kind?: string; rpcId?: unknown }; content?: { type?: string; text?: unknown }[] } | null
        if (f.event.type === 'user/message' && turn !== undefined && user?.source?.kind === 'user'
            && typeof user.source.rpcId === 'string' && user.source.rpcId !== options.ownRequest) {
          const text = (user.content ?? []).flatMap(c => c.type === 'text' && typeof c.text === 'string' ? [c.text] : []).join('')
          yield { kind: 'user', messageId: user.source.rpcId, text }
        }
        if (f.event.type === 'turn/end' && (turn === undefined || data?.turn === turn)) {
          for (const block of blocks.finish(f.event.time)) yield { kind: 'block', block }
          const kind = data?.reason?.kind ?? 'unknown'
          if (kind === 'completed' && turn !== undefined && options.continues && await options.continues()) {
            // D101: a queued message runs as the next turn of the same session: follow it too.
            afterTurn = turn
            turn = undefined
            prefixTurns = true
            mapsMilestones = false
            continue
          }
          if (kind === 'completed') yield { kind: 'end', status: 'completed' }
          else if (isUserInterrupt(data?.reason)) yield { kind: 'end', status: 'interrupted' }
          else yield { kind: 'end', status: 'failed', ...failureOf(kind, data?.reason?.error) }
          return
        }
      }
    }
    const message = 'DSH closed the session stream before the turn ended'
    if (mapsMilestones) for (const milestone of milestones.abandon(message, Date.now())) yield { kind: 'milestone', milestone }
    yield { kind: 'end', status: 'failed', message }
  } finally {
    await iterator.return?.()
  }
}
