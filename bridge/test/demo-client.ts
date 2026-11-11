// An enrolled peer on a disposable demo host. The TLS client trusts that fixture's certificate.
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { setTimeout as sleep } from 'node:timers/promises'
import { TaskStatus } from '../src/gen/frame_pb.ts'
import { MilestoneKind, TodoStatus } from '../src/gen/milestones_pb.ts'
import { issue, redeem, connectDevice } from './tls-client.ts'

const [dir, file, prompt] = process.argv.slice(2)
async function run() {
  let identity: { address: string; id: string; bearer: string }
  if (existsSync(file) && !process.env.DSHM_DEMO_OFFER) {
    identity = JSON.parse(readFileSync(file, 'utf8'))
  } else {
    const offer = process.env.DSHM_DEMO_OFFER ? new URL(process.env.DSHM_DEMO_OFFER) : await issue(dir)
    if (offer.searchParams.get('v') !== '2') throw new Error('demo requires a TLS offer')
    identity = { address: offer.searchParams.get('a')!.split(',')[0], ...await redeem(dir, offer) }
    writeFileSync(file, JSON.stringify(identity), { mode: 0o600 })
  }
  const peer = await connectDevice(dir, identity.address, identity.bearer)
  try {
    const result = await peer.rpc({ case: 'createTask', value: { prompt } })
    if (result.case !== 'taskCreated') throw new Error('create task failed')
    console.error('client: task ' + result.value.taskId)
    const deadline = Date.now() + 120_000
    let index = 0
    while (Date.now() < deadline) {
      while (index < peer.events.length) {
        const { kind } = peer.events[index++]
        if (kind.case !== 'event') continue
        const b = kind.value.body
        if (b.case === 'assistantChunk') process.stdout.write(b.value.text)
        if (b.case === 'milestoneAdded') {
          const m = b.value
          const todos = m.todos.map(t => ({ [TodoStatus.PENDING]: 'P', [TodoStatus.IN_PROGRESS]: 'I', [TodoStatus.COMPLETED]: 'C' } as Record<number, string>)[t.status] ?? '?').join('')
          console.error(`client: milestone ${m.seq} ${MilestoneKind[m.kind]} [${todos}] ${m.text}`)
        }
        if (b.case === 'taskEnded' && b.value.taskId === result.value.taskId) {
          if (b.value.status !== TaskStatus.COMPLETED) throw new Error('task did not complete')
          return
        }
      }
      if (peer.ws.readyState === peer.ws.CLOSED) throw new Error('device disconnected')
      await sleep(25)
    }
    throw new Error('task timed out')
  } finally { peer.ws.close() }
}
run().catch(err => { console.error('client: ' + err.message); process.exitCode = 1 })
