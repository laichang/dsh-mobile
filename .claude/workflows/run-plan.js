export const meta = {
  name: 'run-plan',
  description: 'Run the nodes of a plan graph: brief, a fresh build agent, the verifier and the merge step for each node, with the rework loop',
  whenToUse: 'Run plan/ to the end, 3 nodes at a time or fewer. args: the output of scripts/run-plan-args (graph, scope, into, repo, done, fixes, started, rounds)',
  phases: [
    { title: 'Brief', detail: 'scripts/brief writes the brief from the plan data of the target' },
    { title: 'Build', detail: 'a fresh agent; its prompt is the slice ID, the round and the brief path' },
    { title: 'Verify', detail: 'scripts/plan verify in another context (advisory)' },
    { title: 'Merge', detail: 'scripts/plan merge checks the merge commit again itself; no report is read' },
  ],
}

// The logic is plain functions below, and the last line runs them. scripts/run-plan-test loads
// this file with a fake agent() and checks scheduling, prompts, the rework loop, fixes and the
// return.
//
// args (from scripts/run-plan-args):
//   graph    the output of `scripts/plan dag --json` (nodes with needs, order)
//   scope    {ID: {files, screens}}: the union of the files and screens of the items of each node
//   into     the target branch; repo: an absolute path of a checkout of the repository
//   done     IDs that are merged already (their needs are met; they do not run)
//   fixes    [{node, files, screens}]: an item that a fix added (passed: false) to a node. The
//            node runs (also when it is in done). Each node that has not started and shares a
//            file or a screen with the fix waits until the fix node is merged.
//   started  IDs that an earlier run had started before it was stopped (a fix does not hold them)
//   rounds   {ID: n}: the first round of a node (default 1)
// The old form {slice, round, into, repo} runs one node.
//
// A graph change: stop the run, then resume it with resumeFromRunId and the new args. The
// prompts of a node have only its ID, its round, the brief path, the target and the checkout,
// never its needs: the same node in a changed graph gets the same prompts, and the cache holds.

const MAX_PARALLEL = 3
const MAX_ROUNDS = 3
const ID_RE = /^(T|X|S)[0-9]+$/

const SHELL_SCHEMA = {
  type: 'object',
  properties: {
    exit: { type: 'integer', description: 'the exit code of the command' },
    stdout: { type: 'string', description: 'the standard output of the command, verbatim (not stderr)' },
  },
  required: ['exit', 'stdout'],
}

// The only part of the build agent's report that a later step reads: whether it says that the
// problem is outside its slice. That can only stop the node, never pass it.
const BUILD_SCHEMA = {
  type: 'object',
  properties: {
    outside_slice: {
      type: 'boolean',
      description: 'true only when the items cannot pass because of a problem outside this slice (files of another slice, a tool, the machine, the plan); false when you did the work',
    },
    note: { type: 'string', description: 'one line: what you did; with outside_slice, what is outside and where' },
  },
  required: ['outside_slice', 'note'],
}

// What the Workflow gives back to the coordinator (about 300 tokens or fewer).
const RETURN_SCHEMA = {
  type: 'object',
  required: ['into', 'tip', 'merged', 'blocked', 'review', 'waiting'],
  additionalProperties: false,
  properties: {
    into: { type: 'string' },
    tip: { type: ['string', 'null'], description: 'the last merge commit (12 characters), or null' },
    merged: { type: 'array', items: { type: 'object', required: ['id', 'rounds', 'merge'], additionalProperties: false,
      properties: { id: { type: 'string' }, rounds: { type: 'integer' }, merge: { type: 'string' } } } },
    blocked: { type: 'array', items: { type: 'object', required: ['id', 'round', 'why'], additionalProperties: false,
      properties: { id: { type: 'string' }, round: { type: 'integer' }, why: { type: 'string', maxLength: 120 } } } },
    review: { type: 'array', items: { type: 'object', required: ['id', 'round', 'files'], additionalProperties: false,
      properties: { id: { type: 'string' }, round: { type: 'integer' }, files: { type: 'array', maxItems: 5, items: { type: 'string' } } } } },
    waiting: { type: 'array', items: { type: 'object', required: ['id', 'on'], additionalProperties: false,
      properties: { id: { type: 'string' }, on: { type: 'array', items: { type: 'string' } } } } },
  },
}

// ------------------------------------------------------------------------------------- args

function checkCommon(a) {
  if (!/^[A-Za-z0-9._/-]+$/.test(String(a.into))) throw new Error(`args.into: not a branch name: ${a.into}`)
  if (!/^\/[A-Za-z0-9._/ -]+$/.test(String(a.repo))) throw new Error(`args.repo: not an absolute path: ${a.repo}`)
}

function ids(list, what) {
  const out = list || []
  if (!Array.isArray(out) || out.some((x) => !ID_RE.test(String(x)))) throw new Error(`args.${what}: a list of IDs`)
  return out
}

// The args as one state: the nodes in topological order and what each one waits for.
function normalize(raw) {
  if (!raw || typeof raw !== 'object') throw new Error('args: the output of scripts/run-plan-args')
  let a = raw
  if (raw.slice !== undefined) {    // the old form: one node
    if (!ID_RE.test(String(raw.slice))) throw new Error(`args.slice: not a slice ID: ${raw.slice}`)
    if (!Number.isInteger(raw.round) || raw.round < 1) throw new Error('args.round: an integer, 1 or more')
    a = { ...raw, graph: { nodes: [{ id: raw.slice, needs: [] }], order: [raw.slice] }, rounds: { [raw.slice]: raw.round } }
  }
  checkCommon(a)
  const g = a.graph
  if (!g || !Array.isArray(g.nodes)) throw new Error('args.graph: the output of scripts/plan dag --json')
  const nodes = {}
  for (const n of g.nodes) {
    if (!ID_RE.test(String(n.id))) throw new Error(`args.graph: not a slice ID: ${n.id}`)
    nodes[n.id] = { id: n.id, needs: ids(n.needs, `graph.${n.id}.needs`) }
  }
  const order = Array.isArray(g.order) ? g.order : g.nodes.map((n) => n.id)
  const fixes = (a.fixes || []).map((f) => {
    if (!f || !nodes[f.node]) throw new Error(`args.fixes: not a node of the graph: ${f && f.node}`)
    return { node: f.node, files: f.files || [], screens: f.screens || [] }
  })
  const fixed = new Set(fixes.map((f) => f.node))
  const done = new Set(ids(a.done, 'done').filter((id) => !fixed.has(id)))
  const rounds = a.rounds || {}
  for (const [id, r] of Object.entries(rounds)) {
    if (!Number.isInteger(r) || r < 1) throw new Error(`args.rounds.${id}: an integer, 1 or more`)
  }
  const status = {}
  for (const id of order) status[id] = done.has(id) ? 'merged' : 'todo'
  return {
    into: a.into, repo: a.repo, nodes, order, fixes, done, rounds, status,
    scope: a.scope || {}, started: new Set(ids(a.started, 'started')), result: {}, tip: null,
  }
}

// ------------------------------------------------------------------------------- scheduling

function shares(a, b) {
  const has = (xs, ys) => (xs || []).some((x) => (ys || []).includes(x))
  return has(a.files, b.files) || has(a.screens, b.screens)
}

// The fix nodes that hold id: a fix that is not merged yet, on another node, that shares a file
// or a screen with id. Only a node that has not started waits for a fix.
function heldBy(st, id) {
  if (st.status[id] !== 'todo' || st.started.has(id)) return []
  const mine = st.scope[id] || { files: [], screens: [] }
  return [...new Set(st.fixes.filter((f) => f.node !== id && st.status[f.node] !== 'merged' && shares(mine, f)).map((f) => f.node))]
}

// What a node that has not started waits for: needs that are not merged, and fix nodes.
function waitsOn(st, id) {
  const needs = st.nodes[id].needs.filter((n) => st.status[n] !== 'merged')
  return [...new Set([...needs, ...heldBy(st, id)])]
}

// The nodes that can start now, in the order of the graph.
function ready(st) {
  return st.order.filter((id) => st.status[id] === 'todo' && waitsOn(st, id).length === 0)
}

// ---------------------------------------------------------------------------------- prompts

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

const REFUSED = 'run-plan: refused: evidence changed by the slice'

function commands(a) {
  const id = a.slice
  const review = `review=$(scripts/brief ${id} --round ${a.round} --base ${q(a.into)} --review-path)`
  const err = '"$review.merge-err"'
  return {
    brief: `scripts/brief ${id} --round ${a.round} --base ${q(a.into)} --out ${q(briefPath(a))}`,
    verify: `${review} || exit 1; scripts/plan verify ${id} --base ${q(a.into)} >"$review" 2>&1 || exit $?; ` +
      `result=$(scripts/plan passed ${id} --base ${q(a.into)} --json 2>>"$review"); e=$?; printf '%s\\n' "$result" | tee -a "$review"; exit $e`,
    // stderr goes to a file; a refusal for changed evidence prints one marker line and the files.
    merge: `${review} || exit 1; result=$(scripts/plan merge ${id} --into ${q(a.into)} 2>${err}); e=$?; ` +
      `cat ${err} >>"$review"; printf '%s\\n' "$result" | tee -a "$review"; ` +
      `if grep -q 'evidence changed by the slice' ${err}; then echo '${REFUSED}'; sed -n 's/^  \\(.*\\)$/changed: \\1/p' ${err}; fi; exit $e`,
  }
}

function parseJson(text) {
  try {
    return JSON.parse(text)
  } catch (e) {
    return null
  }
}

// The failure evidence of a round, as one line: each item that did not pass and its runs.
function evidenceKey(items) {
  const failed = (items || []).filter((it) => it.tier !== 'human' && !it.passed)
  if (!failed.length) return 'no item failed'
  return failed.map((it) => `${it.item}:${(it.runs || []).map((r) => `${r.cmd}=${r.exit}`).join(',') || 'no run'}`).join(' ')
}

function short(s, n = 120) {
  s = String(s).replace(/\s+/g, ' ').trim()
  return s.length > n ? s.slice(0, n - 1) + '…' : s
}

// ------------------------------------------------------------------------------------ a node

// One round of one node: brief -> build -> verify -> merge. The build agent's report is read
// only for outside_slice. The merge step gets only the ID and the target.
// Gives back {end: 'merged' | 'review' | 'outside' | 'error' | 'failed', evidence, ...}.
async function runRound(a, { agent, log, onMain }) {
  const cmd = commands(a)
  const id = a.slice
  const tag = `${id} r${a.round}`

  const brief = await onMain(() => agent(shellPrompt(a, `scripts/plan assign ${id} --schedule --round ${a.round} --commit 1>&2 && ${cmd.brief}`), { label: `brief ${tag}`, phase: 'Brief', schema: SHELL_SCHEMA, effort: 'low' }))
  if (!brief || brief.exit !== 0) return { end: 'error', why: `brief: exit ${brief ? brief.exit : 'none'}` }

  const report = await agent(buildPrompt(a), { label: `build ${tag}`, phase: 'Build', schema: BUILD_SCHEMA })
  if (report && report.outside_slice === true) return { end: 'outside', why: `outside the slice: ${report.note}` }

  const v = await agent(shellPrompt(a, cmd.verify), { label: `verify ${tag}`, phase: 'Verify', schema: SHELL_SCHEMA, effort: 'low' })
  const derived = v && v.exit === 0 ? parseJson(v.stdout) : null
  if (!derived || derived.passed !== true) {
    const evidence = derived ? `verify ${evidenceKey(derived.items)}` : `verify: exit ${v ? v.exit : 'none'}`
    log(`${tag}: the verifier did not pass the head (${short(evidence, 80)})`)
    return { end: 'failed', evidence }
  }

  const m = await onMain(() => agent(shellPrompt(a, cmd.merge), { label: `merge ${tag}`, phase: 'Merge', schema: SHELL_SCHEMA, effort: 'low' }))
  const out = m ? m.stdout || '' : ''
  if (out.includes(REFUSED)) {
    const files = out.split('\n').filter((l) => l.startsWith('changed: ')).map((l) => l.slice(9).trim())
    log(`${tag}: the merge step refused changed evidence (${files.join(', ')}); it needs review`)
    return { end: 'review', files }
  }
  const summary = parseJson(out)
  if (m && m.exit === 0 && summary && summary.merged === true) {
    if (!/^[0-9a-f]{7,40}$/.test(summary.merge)) return { end: 'error', why: 'invalid merge commit' }
    const record = await onMain(() => agent(shellPrompt(a, `scripts/plan merged ${id} ${summary.merge} --commit`),
      { label: `record ${tag}`, phase: 'Merge', schema: SHELL_SCHEMA, effort: 'low' }))
    if (!record || record.exit !== 0) return { end: 'error', why: `record merge ${summary.merge} with scripts/plan merged` }
    log(`${tag}: merged into ${a.into} as ${summary.merge}`)
    return { end: 'merged', merge: summary.merge }
  }
  const evidence = summary ? `merge ${evidenceKey(summary.items)}` : `merge: exit ${m ? m.exit : 'none'}`
  log(`${tag}: not merged (${short(evidence, 80)})`)
  return { end: 'failed', evidence }
}

// The rework loop: a new round (fresh agents) until the merge step merges the node. Blocked
// after MAX_ROUNDS rounds, after 2 rounds in sequence with the same failure evidence, or when the
// build agent reports a problem outside its slice. Needs review when the merge step refuses
// changed evidence: the Workflow never passes --allow-changed-evidence.
async function runNode(st, id, ctx) {
  const first = st.rounds[id] || 1
  if (first > MAX_ROUNDS) return { status: 'blocked', round: MAX_ROUNDS, why: '3 build rounds already used' }
  let prev = null
  for (let round = first, n = 1; ; round++, n++) {
    const r = await runRound({ slice: id, round, into: st.into, repo: st.repo }, ctx)
    if (r.end === 'merged') return { status: 'merged', round, rounds: n, merge: r.merge }
    if (r.end === 'review') return { status: 'review', round, files: r.files }
    if (r.end === 'outside' || r.end === 'error') return { status: 'blocked', round, why: short(r.why) }
    if (prev !== null && r.evidence === prev) return { status: 'blocked', round, why: short(`same evidence in 2 rounds: ${r.evidence}`) }
    if (round >= MAX_ROUNDS) return { status: 'blocked', round, why: short(`${MAX_ROUNDS} rounds: ${r.evidence}`) }
    prev = r.evidence
  }
}

// -------------------------------------------------------------------------------- the graph

// When a node ends, start each node whose needs are met; MAX_PARALLEL at the same time or fewer.
async function runPlan(raw, ctx) {
  const st = normalize(raw)
  const running = new Map()
  // Assignments, merge commits and cleanup all write the same checkout.
  let main = Promise.resolve()
  ctx.onMain = (work) => {
    const result = main.then(work)
    main = result.catch(() => {})
    return result
  }
  for (;;) {
    for (const id of ready(st)) {
      if (running.size >= MAX_PARALLEL) break
      st.status[id] = 'running'
      ctx.log(`${id}: start`)
      running.set(id, runNode(st, id, ctx).then((r) => ({ id, r }), (e) => ({ id, r: { status: 'blocked', round: 0, why: short(`error: ${e && e.message}`) } })))
    }
    if (running.size === 0) break
    const { id, r } = await Promise.race(running.values())
    running.delete(id)
    st.status[id] = r.status
    st.result[id] = r
    if (r.status === 'merged') st.tip = r.merge
    if (r.status !== 'merged') ctx.log(`${id}: ${r.status}${r.why ? ` (${r.why})` : ''}`)
  }
  return summarize(st)
}

function summarize(st) {
  const by = (s) => st.order.filter((id) => st.status[id] === s && st.result[id])
  return {
    into: st.into,
    tip: st.tip ? st.tip.slice(0, 12) : null,
    merged: by('merged').map((id) => ({ id, rounds: st.result[id].rounds, merge: st.result[id].merge.slice(0, 12) })),
    blocked: by('blocked').map((id) => ({ id, round: st.result[id].round, why: st.result[id].why })),
    review: by('review').map((id) => ({ id, round: st.result[id].round, files: st.result[id].files.slice(0, 5) })),
    waiting: st.order.filter((id) => st.status[id] === 'todo').map((id) => ({ id, on: waitsOn(st, id) })),
  }
}

return await runPlan(args, { agent, phase, log })
