export const meta = {
  name: 'run-plan',
  description: 'Take one plan node from its brief to a merge: build, verify, and a merge step that checks again itself',
  whenToUse: 'Run one node of plan/ through brief, a fresh build agent, the verifier, and the merge step. args: {slice, round, into, repo}',
  phases: [
    { title: 'Brief', detail: 'scripts/brief writes the brief from the plan data of the target' },
    { title: 'Build', detail: 'a fresh agent; its prompt is the slice ID, the round and the brief path' },
    { title: 'Verify', detail: 'scripts/plan verify in another context (advisory)' },
    { title: 'Merge', detail: 'scripts/plan merge checks the merge commit again itself; no report is read' },
  ],
}

// The logic is plain functions below, and the last line runs them. scripts/run-plan-test loads
// this file with a fake agent() (it runs the shell steps for real) and checks the round trip.
// args: {slice: "S99", round: 1, into: "<target branch>", repo: "<a checkout of the target>"}

const SHELL_SCHEMA = {
  type: 'object',
  properties: {
    exit: { type: 'integer', description: 'the exit code of the command' },
    stdout: { type: 'string', description: 'the standard output of the command, verbatim (not stderr)' },
  },
  required: ['exit', 'stdout'],
}

function checkArgs(a) {
  if (!a || typeof a !== 'object') throw new Error('args: {slice, round, into, repo}')
  if (!/^(T|X|S)[0-9]+$/.test(String(a.slice))) throw new Error(`args.slice: not a slice ID: ${a.slice}`)
  if (!Number.isInteger(a.round) || a.round < 1) throw new Error('args.round: an integer, 1 or more')
  if (!/^[A-Za-z0-9._/-]+$/.test(String(a.into))) throw new Error(`args.into: not a branch name: ${a.into}`)
  if (!/^\/[A-Za-z0-9._/ -]+$/.test(String(a.repo))) throw new Error(`args.repo: not an absolute path: ${a.repo}`)
  return a
}

function briefPath(a) {
  return `/tmp/dshm-brief/${a.slice}-r${a.round}.md`
}

// The prompt of the build agent: the slice ID, the round and the brief path. Nothing else.
function buildPrompt(a) {
  return `Slice ${a.slice}, round ${a.round}. Brief: ${briefPath(a)}`
}

function q(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`
}

// A step that only runs one command: the agent runs it and gives back the exit code and stdout.
function shellPrompt(a, cmd) {
  return [
    'Run this one shell command exactly as written, and nothing else. Do not change, repair or retry it.',
    '',
    '```sh',
    `cd ${q(a.repo)} && ${cmd}`,
    '```',
    '',
    'Give back its exit code and its standard output, verbatim.',
  ].join('\n')
}

function commands(a) {
  const id = a.slice
  return {
    brief: `scripts/brief ${id} --round ${a.round} --base ${q(a.into)} --out ${q(briefPath(a))}`,
    verify: `scripts/plan verify ${id} --base ${q(a.into)} 1>&2 && scripts/plan passed ${id} --base ${q(a.into)} --json`,
    merge: `scripts/plan merge ${id} --into ${q(a.into)}`,
  }
}

function parseJson(text) {
  try {
    return JSON.parse(text)
  } catch (e) {
    return null
  }
}

// One node, one round: brief -> build -> verify -> merge. The build agent's report is kept for
// the log and is never read by a later step. The merge step gets only the ID and the target.
async function runNode(rawArgs, { agent, phase, log }) {
  const a = checkArgs(rawArgs)
  const cmd = commands(a)
  const id = a.slice
  const out = { slice: id, round: a.round, into: a.into, brief: briefPath(a), status: null }

  phase('Brief')
  const brief = await agent(shellPrompt(a, cmd.brief), { label: `brief ${id}`, phase: 'Brief', schema: SHELL_SCHEMA, effort: 'low' })
  if (!brief || brief.exit !== 0) return { ...out, status: 'blocked', step: 'brief', result: brief }

  phase('Build')
  const report = await agent(buildPrompt(a), { label: `build ${id} r${a.round}`, phase: 'Build' })
  out.report = typeof report === 'string' ? report.slice(0, 2000) : null // for the log only

  phase('Verify')
  const v = await agent(shellPrompt(a, cmd.verify), { label: `verify ${id}`, phase: 'Verify', schema: SHELL_SCHEMA, effort: 'low' })
  const derived = v && v.exit === 0 ? parseJson(v.stdout) : null
  out.verify = derived ? { head: derived.head, passed: derived.passed } : { exit: v ? v.exit : null }
  if (!derived || derived.passed !== true) {
    log(`${id}: the verifier did not pass the head; no merge (the rework loop is not here yet)`)
    return { ...out, status: 'rework' }
  }

  phase('Merge')
  const m = await agent(shellPrompt(a, cmd.merge), { label: `merge ${id}`, phase: 'Merge', schema: SHELL_SCHEMA, effort: 'low' })
  const summary = m ? parseJson(m.stdout) : null
  out.merge = summary ? { base: summary.base, head: summary.head, merge: summary.merge, passed: summary.passed, merged: summary.merged } : { exit: m ? m.exit : null }
  const merged = !!(m && m.exit === 0 && summary && summary.merged === true)
  log(merged ? `${id}: merged into ${a.into} as ${summary.merge}` : `${id}: not merged`)
  return { ...out, status: merged ? 'merged' : 'not merged' }
}

return await runNode(args, { agent, phase, log })
