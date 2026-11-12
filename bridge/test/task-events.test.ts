import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { create, toBinary } from '@bufbuild/protobuf'
import { FrameSchema } from '../src/gen/frame_pb.ts'
import type { TaskEvent } from '../src/tasks/events.ts'
import { HostLog } from '../src/tasks/host-log.ts'
import { FIXTURES_DIR } from './fixtures.ts'

test('host log maps each business event to its shipped frame bytes', () => {
  const taskId = 'session-1'
  const time = 1793000000000n
  const question = { id: '6f1c2c1e-3f5a-4d0b-9c33-1d2e3f4a5b6c', taskId }
  const approval = { id: 'approval-1', taskId: 'session-2' }
  const cases: [string, bigint, TaskEvent][] = [
    ['attachments_user_message_with_files_event', 15n, { case: 'userMessage', value: {
      taskId, messageId: 'message-2', text: '再看看这两个。', timeMs: time + 15000n, attachments: [
        { kind: 'file', name: '笔记.txt', size: 24n, mediaType: 'text/plain' },
        { kind: 'image', name: 'photo.jpg', size: 48213n, mediaType: 'image/jpeg' },
      ],
    } }],
    ['conversation_queued_message_event', 15n, { case: 'queuedMessage', value: {
      taskId, messageId: 'message-2', text: '顺便更新 README。', timeMs: time + 15000n, placement: 'QUEUED',
    } }],
    ['approvals_approval_pending_event', 45n, { case: 'approvalPending', value: {
      ...approval, callId: '', tool: 'bash', reason: '', argumentsJson: '{"command":"rm /tmp/x"}',
    } }],
    ['approvals_approval_resolved_event', 46n, { case: 'approvalResolved', value: { ...approval, outcome: 'TIMEOUT' } }],
    ['questions_pending_event', 12n, { case: 'questionPending', value: { ...question, questions: [
      { id: 'q1', text: '桌面上有两个周报模板，用哪个？', header: '模板', detail: '', multiSelect: false,
        options: [{ label: '公司模板.pptx', description: 'the company one' }, { label: '简洁版.pptx', description: '' }] },
    ] } }],
    ['questions_resolved_event', 13n, { case: 'questionResolved', value: { ...question, outcome: 'ANSWERED_ELSEWHERE',
      answers: [{ questionId: 'q1', selected: ['公司模板.pptx'] }] } }],
    ['durable_list_task_upserted_event', 42n, { case: 'taskUpserted', value: { task: {
      taskId: 'session-2', title: '整理本周的会议记录', state: 'COMPLETED', createdAtMs: time, updatedAtMs: time + 4000n,
      message: '', failureCode: '', approvalOnly: false, externalSession: false, pendingQuestions: [], pendingApprovals: [],
    } } }],
    ['model_failures_task_ended_quota_event', 18n, { case: 'taskEnded', value: { taskId: 'session-6f1c2a',
      status: 'FAILED', message: 'Insufficient Balance', failureCode: 'QUOTA' } }],
    ['models_model_selected_event', 9n, { case: 'modelSelected', value: { taskId,
      selection: { provider: 'provider', model: 'model', reasoningEffort: 'low' } } }],
    ['core_assistant_chunk_event', 0n, { case: 'assistantChunk', value: { taskId: 'session-6f1c2a',
      seq: 1n, text: "你好，I'm a DSH agent 👋" } }],
    ['milestones_milestone_failed_event', 0n, { case: 'milestoneAdded', value: { taskId: 'session-6f1c2a', seq: 4n,
      milestone: { kind: 'failed', text: 'error: rate limited', timeMs: Number(time) + 4000, todos: [] } } }],
    ['transcript_thinking_block_event', 7n, { case: 'transcriptBlock', value: { taskId, block: {
      blockId: 'thinking-attempt-1-0', state: 'done', timeMs: Number(time),
      thinking: { durationMs: 8000, text: '先看测试为什么失败。', truncated: false },
    } } }],
  ]
  const log = new HostLog()
  for (const [fixture, hostSeq, event] of cases) {
    const recorded = log.append(taskId, event)
    const frame = create(FrameSchema, { kind: { case: 'event', value: { hostSeq, body: recorded.body } } })
    assert.deepEqual(Buffer.from(toBinary(FrameSchema, frame)), readFileSync(`${FIXTURES_DIR}/${fixture}.binpb`), fixture)
  }
})
