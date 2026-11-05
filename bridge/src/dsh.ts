/**
 * The only file that knows DSH internals (ARCHITECTURE D4). It maps a dsh-mobile task onto one
 * DSH session (D13): create a session in a fixed workspace, prompt it, follow its log, and turn
 * the follow stream into plain task output. Types are structural subsets of the DSH 0.2.2-rc.1
 * `sessionController` / `workspaceController` services, so `FakeDSH` can implement them in tests.
 */
import { randomUUID } from 'node:crypto'
import { MilestoneMapper, describeFailure, isUserInterrupt, type Milestone } from './milestones/mapper.ts'

/** Subset of `ctx.workspaceController` (`@deepseek-ai/dsh-api-workspace-controller`). */
export interface WorkspaceControllerLike {
  create(request: { path: string }): Promise<{ workspace: { workspaceId: string } }>
}

/** One frame of `sessionController.follow` that the bridge reads; everything else is ignored. */
export type FollowFrame =
  | { type: 'snapshot' }
  | { type: 'event'; event: { type: string; seq: number; time?: number; data: unknown } }
  | { type: 'assistant-stream'; frame: { type: 'start' | 'end' } | { type: 'chunk'; chunk: unknown } }

/** Subset of `ctx.sessionController` (`@deepseek-ai/dsh-api-session-controller`). */
export interface SessionControllerLike {
  create(request: { workspaceId: string }): Promise<{ sessionId: string }>
  cancel(request: { sessionId: string }): { accepted: true }
  prompt(
    request: { requestId: string; sessionId: string; mode: 'queue'; content: readonly { type: 'text'; text: string }[] },
    signal: AbortSignal,
  ): Promise<unknown>
  follow(
    request: { address: { kind: 'session'; sessionId: string }; assistantStream: true; activate?: boolean },
    signal: AbortSignal,
  ): AsyncIterable<FollowFrame>
}

export interface DshServices {
  sessionController: SessionControllerLike
  workspaceController: WorkspaceControllerLike
}

/** What a running task produces, in order. Exactly one `end`, always last. */
export type TaskOutput =
  | { kind: 'text'; text: string }
  | { kind: 'milestone'; milestone: Milestone }
  | { kind: 'end'; status: 'completed' | 'interrupted' | 'failed'; message?: string }

export interface StartedTask {
  taskId: string
  output: AsyncIterable<TaskOutput>
}

/** Starts tasks on DSH. `cwd` is the fixed workspace directory for T0 (S7 adds a picker). */
export class DshTasks {
  constructor(private readonly dsh: DshServices, private readonly cwd: string) {}

  interrupt(taskId: string): void {
    this.dsh.sessionController.cancel({ sessionId: taskId })
  }

  async start(prompt: string, signal: AbortSignal): Promise<StartedTask> {
    const { workspace } = await this.dsh.workspaceController.create({ path: this.cwd })
    const { sessionId } = await this.dsh.sessionController.create({ workspaceId: workspace.workspaceId })

    // Open the follow before prompting, so the turn's first frames can't be missed.
    const follow = this.dsh.sessionController.follow(
      { address: { kind: 'session', sessionId }, assistantStream: true, activate: true }, signal)
    const iterator = follow[Symbol.asyncIterator]()
    const first = await iterator.next() // the opening snapshot

    await this.dsh.sessionController.prompt(
      { requestId: randomUUID(), sessionId, mode: 'queue', content: [{ type: 'text', text: prompt }] }, signal)

    return { taskId: sessionId, output: mapFollow(first, iterator) }
  }
}

async function* mapFollow(
  first: IteratorResult<FollowFrame>, iterator: AsyncIterator<FollowFrame>,
): AsyncGenerator<TaskOutput> {
  let turn: number | undefined
  const milestones = new MilestoneMapper()
  try {
    for (let next = first; !next.done; next = await iterator.next()) {
      const f = next.value
      if (f.type === 'assistant-stream' && f.frame.type === 'chunk') {
        const chunk = f.frame.chunk as { type?: string; text?: unknown } | null
        if (chunk?.type === 'text-delta' && typeof chunk.text === 'string' && chunk.text) {
          yield { kind: 'text', text: chunk.text }
        }
      } else if (f.type === 'event') {
        for (const milestone of milestones.map(f.event)) yield { kind: 'milestone', milestone }
        const data = f.event.data as { turn?: number; reason?: { kind?: string; error?: unknown; reason?: { kind?: string } } } | null
        if (f.event.type === 'turn/start' && turn === undefined) turn = data?.turn
        if (f.event.type === 'turn/end' && (turn === undefined || data?.turn === turn)) {
          const kind = data?.reason?.kind ?? 'unknown'
          if (kind === 'completed') yield { kind: 'end', status: 'completed' }
          else if (isUserInterrupt(data?.reason)) yield { kind: 'end', status: 'interrupted' }
          else yield { kind: 'end', status: 'failed', message: describeFailure(kind, data?.reason?.error) }
          return
        }
      }
    }
    const message = 'DSH closed the session stream before the turn ended'
    for (const milestone of milestones.abandon(message, Date.now())) yield { kind: 'milestone', milestone }
    yield { kind: 'end', status: 'failed', message }
  } finally {
    await iterator.return?.()
  }
}
