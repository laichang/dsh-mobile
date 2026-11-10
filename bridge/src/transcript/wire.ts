/** A mapped `BlockOut` → the `TranscriptBlock` event body (protocol/transcript.proto). */
import type { MessageInitShape } from '@bufbuild/protobuf'
import { TranscriptBlockState, type TranscriptBlockSchema } from '../gen/transcript_pb.ts'
import type { BlockOut, BlockStateName } from './mapper.ts'

export const TRANSCRIPT_CAPABILITY = 'transcript.v1'

const STATES: Record<BlockStateName, TranscriptBlockState> = {
  running: TranscriptBlockState.RUNNING,
  done: TranscriptBlockState.DONE,
  failed: TranscriptBlockState.FAILED,
}

export function transcriptBlock(taskId: string, b: BlockOut): MessageInitShape<typeof TranscriptBlockSchema> {
  return {
    taskId,
    blockId: b.blockId,
    state: STATES[b.state],
    timeMs: BigInt(Math.trunc(b.timeMs)),
    kind: b.thinking
      ? { case: 'thinking', value: { durationMs: BigInt(Math.trunc(b.thinking.durationMs)), text: b.thinking.text, truncated: b.thinking.truncated } }
      : b.tool ? { case: 'tool', value: { ...b.tool } } : { case: undefined },
  }
}
