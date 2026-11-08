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
import { MilestoneMapper, describeFailure, isUserInterrupt, type Milestone } from './milestones/mapper.ts'
import { TranscriptMapper, type BlockOut } from './transcript/mapper.ts'
import type { StagedFile } from './attachments/staging.ts'

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
}

/** A prompt part: text, or a file staged through `fileUploads` (an image receipt enters as that image, D95; a file receipt as a saved-path note, D107). */
export type PromptPart = { type: 'text'; text: string } | { type: 'file'; receiptId: string }

/** Subset of `ctx.fileUploads` (`@deepseek-ai/dsh-client-file-upload`). */
export interface FileUploadsLike {
  uploadImageStream(request: {
    sessionId: string; data: AsyncIterable<Uint8Array>; mediaType: string; name?: string; signal?: AbortSignal
  }): Promise<{ receiptId: string }>
  uploadStream(request: {
    sessionId: string; data: AsyncIterable<Uint8Array>; name?: string; signal?: AbortSignal
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
  | { kind: 'end'; status: 'completed' | 'interrupted' | 'failed'; message?: string }

/** One more turn of a task's session (D89): its output, and the DSH turn it waits for. */
export interface FollowUpOptions {
  /** The message's ID: also DSH's `requestId`, so a repeated send is accepted once. */
  messageId: string
  mode: PromptMode
  /** The latest DSH turn number the task has seen; the new turn has a larger one. */
  afterTurn?: number
  /** A prefix for the transcript block IDs of this turn, so they stay unique within the task. */
  blockPrefix: string
  /** D107: staged files that go into the message after its text, in order. */
  files?: readonly StagedFile[]
}

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

  /** True when the host can stage files for a prompt (`attachments.v1`). */
  get attachments(): boolean { return !!this.dsh.fileUploads }

  /**
   * The prompt content: the text, then each file staged for `sessionId`, in order. An image goes
   * through `uploadImageStream` and enters as that image (D95); any other file goes through
   * `uploadStream`, and the model gets its name and a saved path (D18, D107).
   */
  private async content(sessionId: string, text: string, files: readonly StagedFile[], signal: AbortSignal): Promise<PromptPart[]> {
    if (files.length && !this.dsh.fileUploads) throw new Error('This host cannot take attachments.')
    const content: PromptPart[] = [{ type: 'text', text }]
    for (const file of files) {
      const { receiptId } = file.kind === 'image'
        ? await this.dsh.fileUploads!.uploadImageStream({
          sessionId, data: once(file.data), mediaType: file.mediaType, name: file.name, signal })
        : await this.dsh.fileUploads!.uploadStream({ sessionId, data: once(file.data), name: file.name, signal })
      content.push({ type: 'file', receiptId })
    }
    return content
  }

  async start(prompt: string, signal: AbortSignal, selection?: Selection, path?: string,
              files: readonly StagedFile[] = []): Promise<StartedTask> {
    if (files.length && !this.dsh.fileUploads) throw new Error('This host cannot take attachments.')
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
    try {
      if (selection) await this.selectModel(sessionId, selection)
      const content = await this.content(sessionId, prompt, files, signal)
      await this.dsh.sessionController.prompt({ requestId: randomUUID(), sessionId, mode: 'queue', content }, signal)
    } catch (error) {
      this.sessions.delete(sessionId)
      await iterator.return?.()
      throw error
    }

    return { taskId: sessionId, output: mapFollow(first, iterator), workspace: path }
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
      const content = await this.content(taskId, text, options.files ?? [], signal)
      await this.dsh.sessionController.prompt(
        { requestId: options.messageId, sessionId: taskId, mode: options.mode, content }, signal)
    } catch (error) {
      await iterator.return?.()
      throw error
    }
    return mapFollow(first, iterator, { afterTurn: options.afterTurn, blockPrefix: options.blockPrefix, milestones: false })
  }
}

interface MapOptions {
  /** Wait for a turn after this one (follow-ups); undefined takes the first turn that starts. */
  afterTurn?: number
  blockPrefix?: string
  /** Milestones map the task's first turn only (S3). */
  milestones?: boolean
}

async function* once(data: Uint8Array): AsyncGenerator<Uint8Array> { yield data }

async function* mapFollow(
  first: IteratorResult<FollowFrame>, iterator: AsyncIterator<FollowFrame>, options: MapOptions = {},
): AsyncGenerator<TaskOutput> {
  let turn: number | undefined
  const mapsMilestones = options.milestones ?? true
  const milestones = new MilestoneMapper()
  const blocks = new TranscriptMapper(options.blockPrefix) // S17
  try {
    for (let next = first; !next.done; next = await iterator.next()) {
      const f = next.value
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
            && (options.afterTurn === undefined || (typeof data?.turn === 'number' && data.turn > options.afterTurn))) {
          turn = data?.turn
          if (typeof turn === 'number') yield { kind: 'turn', turn }
        }
        if (f.event.type === 'turn/end' && (turn === undefined || data?.turn === turn)) {
          for (const block of blocks.finish(f.event.time)) yield { kind: 'block', block }
          const kind = data?.reason?.kind ?? 'unknown'
          if (kind === 'completed') yield { kind: 'end', status: 'completed' }
          else if (isUserInterrupt(data?.reason)) yield { kind: 'end', status: 'interrupted' }
          else yield { kind: 'end', status: 'failed', message: describeFailure(kind, data?.reason?.error) }
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
