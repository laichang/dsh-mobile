// Loads .claude/workflows/run-plan.js as the Workflow tool runs it, with a fake agent().
//  - Graph tests: a scripted agent (no shell); each node has a list of round results.
//  - Round-trip tests: the shell steps (brief, verify, merge) run for real in a temporary clone;
//    the build agent is a script.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, mkdtempSync, readFileSync, rmSync, readdirSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const SRC = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim()
const INTO = 'main'
const NODE_BRANCH = 'claude/s99-fake-node'
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
const LAST_LINE = /^return await runPlan\(args, \{ agent, phase, log \}\)\s*$/m

function git(cwd, ...a) {
  return execFileSync('git', a, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
}

// The workflow file as the Workflow tool gets it: meta, then a body with agent/phase/log/args.
function workflowText() {
  const text = readFileSync(join(SRC, '.claude/workflows/run-plan.js'), 'utf8')
  assert.match(text, /^export const meta = \{/)
  assert.match(text, LAST_LINE)
  return text.replace(/^export const meta/, 'const meta')
}

function loadWorkflow() {
  return new AsyncFunction('agent', 'phase', 'log', 'args', workflowText())
}

// The same body, but it gives back its functions and constants instead of running.
function internals() {
  const body = workflowText().replace(LAST_LINE, 'return { RETURN_SCHEMA, BUILD_SCHEMA, MAX_PARALLEL, MAX_ROUNDS }')
  return new AsyncFunction('agent', 'phase', 'log', 'args', body)(null, () => {}, () => {}, null)
}

// ------------------------------------------------------------------- graph tests (no shell)

const tick = (ms) => new Promise((r) => setTimeout(r, ms))

function graph(nodes) {
  return { nodes: nodes.map(([id, needs]) => ({ id, kind: 'slice', title: id, needs, branch: null })), order: nodes.map(([id]) => id) }
}

function baseArgs(nodes, extra = {}) {
  return { graph: graph(nodes), scope: {}, into: 'main', repo: '/tmp/repo', done: [], fixes: [], started: [], rounds: {}, ...extra }
}

// rounds: {ID: ['pass' | 'fail:<evidence>' | 'outside' | 'review']} (the last one repeats);
// ms: {ID: build time}. It records each call, each start and end, and the number of nodes in a
// round at the same time.
function scripted({ rounds = {}, ms = {} } = {}) {
  const rec = { calls: [], events: [], active: new Set(), peak: 0 }
  const agent = async (prompt, opts = {}) => {
    const [step, id, r] = opts.label.split(' ')
    const round = Number(r.slice(1))
    rec.calls.push({ prompt, opts, step, id, round })
    const plan = rounds[id] || ['pass']
    const what = plan[Math.min(round, plan.length) - 1]
    if (step === 'brief') {
      rec.active.add(id)
      rec.peak = Math.max(rec.peak, rec.active.size)
      if (round === 1) rec.events.push(`start ${id}`)
      return { exit: 0, stdout: '' }
    }
    if (step === 'build') {
      await tick(ms[id] ?? 5)
      return { outside_slice: what === 'outside', note: what === 'outside' ? 'the bridge of S9 is broken' : 'done' }
    }
    if (step === 'verify') {
      const ok = !what.startsWith('fail:')
      const items = ok ? [] : [{ item: 0, tier: 'auto', passed: false, runs: [{ cmd: `scripts/check ${what.slice(5)}`, exit: 1 }] }]
      if (!ok) rec.active.delete(id)
      return { exit: 0, stdout: JSON.stringify({ head: 'h', passed: ok, items }) }
    }
    if (step === 'record') return { exit: 0, stdout: '' }
    if (step === 'merge') {
      rec.active.delete(id)
      if (what === 'review') return { exit: 1, stdout: 'run-plan: refused: evidence changed by the slice\nchanged: scripts/check\n' }
      rec.events.push(`end ${id}`)
      return { exit: 0, stdout: JSON.stringify({ merged: true, passed: true, merge: `a${id.slice(1)}000000000000000`, items: [] }) }
    }
    throw new Error(`unknown step ${step}`)
  }
  agent.rec = rec
  return agent
}

async function runScripted(args, script) {
  const agent = scripted(script)
  const logs = []
  const result = await loadWorkflow()(agent, () => {}, (m) => logs.push(m), args)
  return { result, rec: agent.rec, logs }
}

test('a node starts when its needs are merged, and 3 nodes or fewer run at the same time', async () => {
  const nodes = [['T0', []], ['S1', ['T0']], ['S2', ['T0']], ['S3', ['T0']], ['S4', ['T0']], ['S5', ['T0']], ['S6', ['S1', 'S2']], ['S7', ['S6']]]
  const { result, rec } = await runScripted(baseArgs(nodes), { ms: { S1: 5, S2: 40, S3: 60, S4: 80, S5: 5, S6: 5 } })
  assert.deepEqual(result.merged.map((m) => m.id).sort(), nodes.map(([id]) => id).sort())
  assert.equal(rec.peak, 3, 'it runs 3 nodes at the same time when 3 are ready, never more')
  const at = (e) => rec.events.indexOf(e)
  for (const [id, needs] of nodes) for (const n of needs) assert.ok(at(`start ${id}`) > at(`end ${n}`), `${id} after ${n}`)
  // When a node ends, the next ready node starts before any other node ends.
  const firstEnd = rec.events.findIndex((e, i) => i > at('end T0') && e.startsWith('end '))
  assert.equal(rec.events[firstEnd], 'end S1')
  assert.equal(rec.events[firstEnd + 1], 'start S4')
  // S6 waits for S2 (slow); S5 (no shared need) went before it.
  assert.ok(at('start S5') < at('start S6'))
})

test('the prompt of a node has only its ID, round and brief path; a changed graph gives the same prompts', async () => {
  const g1 = [['T0', []], ['S1', ['T0']], ['S2', ['T0']], ['S3', ['S1']]]
  const g2 = [['T0', []], ['S2', []], ['S1', ['T0', 'S2']], ['S4', []], ['S3', ['S1', 'S4']]]
  const prompts = async (nodes) => {
    const { rec } = await runScripted(baseArgs(nodes), { rounds: { S2: ['fail:x', 'pass'] } })
    const by = {}
    for (const c of rec.calls) (by[c.id] ||= []).push(c.prompt)
    return { by, rec }
  }
  const a = await prompts(g1)
  const b = await prompts(g2)
  for (const c of a.rec.calls.filter((c) => c.step === 'build')) {
    assert.equal(c.prompt, `Slice ${c.id}, round ${c.round}. Brief: /tmp/dshm-brief/${c.id}-r${c.round}.md`)
  }
  assert.deepEqual(a.rec.calls.filter((c) => c.id === 'S2' && c.step === 'build').map((c) => c.prompt),
    ['Slice S2, round 1. Brief: /tmp/dshm-brief/S2-r1.md', 'Slice S2, round 2. Brief: /tmp/dshm-brief/S2-r2.md'])
  for (const id of ['T0', 'S1', 'S2', 'S3']) {
    assert.deepEqual(b.by[id], a.by[id], `${id}: the same prompts in both graphs`)
    const others = ['T0', 'S1', 'S2', 'S3', 'S4'].filter((x) => x !== id)
    for (const p of a.by[id]) for (const o of others) assert.ok(!p.includes(o), `a prompt of ${id} names ${o}: ${p}`)
  }
  // The options of a call do not depend on the graph either.
  const opts = (r, id) => r.calls.filter((c) => c.id === id).map((c) => JSON.stringify(c.opts))
  assert.deepEqual(opts(b.rec, 'S1'), opts(a.rec, 'S1'))
})

test('rework: blocked after 3 rounds, after 2 rounds with the same evidence, after an out-of-scope report', async () => {
  const nodes = [['S1', []], ['S2', []], ['S3', []], ['S4', []], ['S5', ['S2']]]
  const { result, rec } = await runScripted(baseArgs(nodes), {
    rounds: { S1: ['fail:a', 'fail:b', 'fail:c', 'pass'], S2: ['fail:a', 'fail:a', 'pass'], S3: ['outside'], S4: ['fail:a', 'pass'] },
  })
  const blocked = Object.fromEntries(result.blocked.map((b) => [b.id, b]))
  assert.equal(blocked.S1.round, 3)
  assert.match(blocked.S1.why, /^3 rounds: verify 0:scripts\/check c=1$/)
  assert.equal(blocked.S2.round, 2)
  assert.match(blocked.S2.why, /^same evidence in 2 rounds: verify 0:scripts\/check a=1$/)
  assert.equal(blocked.S3.round, 1)
  assert.match(blocked.S3.why, /^outside the slice: the bridge of S9 is broken$/)
  assert.deepEqual(result.merged, [{ id: 'S4', rounds: 2, merge: 'a40000000000' }])
  assert.deepEqual(result.waiting, [{ id: 'S5', on: ['S2'] }])
  // Each round is a new agent with a new prompt (a fresh context); no verify after an out-of-scope report.
  assert.deepEqual(rec.calls.filter((c) => c.id === 'S1' && c.step === 'build').map((c) => c.round), [1, 2, 3])
  assert.deepEqual(rec.calls.filter((c) => c.id === 'S3').map((c) => c.step), ['brief', 'build'])
})

test('a fix blocks only the nodes that have not started and share files or screens with it', async () => {
  const nodes = [['T0', []], ['S1', ['T0']], ['S2', ['T0']], ['S3', ['T0']], ['S4', ['T0']], ['S5', ['T0']]]
  const scope = {
    S1: { files: ['ios/A.swift'], screens: ['home'] },
    S2: { files: ['ios/A.swift'], screens: [] },   // shares a file with the fix: waits
    S3: { files: [], screens: ['home'] },           // shares a screen, but started before the stop
    S4: { files: ['bridge/x.ts'], screens: [] },    // shares nothing: runs at once
    S5: { files: [], screens: ['home'] },           // shares a screen: waits
  }
  const fixes = [{ node: 'S1', item: 2, files: ['ios/A.swift'], screens: ['home'] }]
  const args = baseArgs(nodes, { scope, fixes, done: ['T0', 'S1'], started: ['S3'] })
  const { result, rec } = await runScripted(args, { ms: { S1: 50 } })
  const at = (e) => rec.events.indexOf(e)
  assert.ok(!rec.events.includes('start T0'), 'a done node does not run')
  assert.ok(at('start S1') >= 0, 'the fix node runs again, also when it is in done')
  assert.ok(at('start S3') < at('end S1') && at('start S4') < at('end S1'), 'S3 and S4 are not held')
  assert.ok(at('start S2') > at('end S1') && at('start S5') > at('end S1'), 'S2 and S5 wait for the fix')
  assert.equal(result.merged.length, 5)

  // A fix node that does not merge holds them: they wait and say why.
  const r2 = await runScripted(args, { rounds: { S1: ['outside'] } })
  assert.deepEqual(r2.result.waiting, [{ id: 'S2', on: ['S1'] }, { id: 'S5', on: ['S1'] }])
  assert.deepEqual(r2.result.merged.map((m) => m.id), ['S3', 'S4'])
})

// A small validator for the parts of JSON Schema that RETURN_SCHEMA uses.
function check(v, s, at = '$') {
  const types = [].concat(s.type || [])
  const typeOf = (x) => (x === null ? 'null' : Array.isArray(x) ? 'array' : Number.isInteger(x) ? 'integer' : typeof x)
  if (types.length && !types.includes(typeOf(v))) return [`${at}: ${typeOf(v)} is not ${types}`]
  const errs = []
  if (typeOf(v) === 'object') {
    for (const k of s.required || []) if (!(k in v)) errs.push(`${at}: no ${k}`)
    if (s.additionalProperties === false) for (const k of Object.keys(v)) if (!(k in (s.properties || {}))) errs.push(`${at}: extra ${k}`)
    for (const [k, ps] of Object.entries(s.properties || {})) if (k in v) errs.push(...check(v[k], ps, `${at}.${k}`))
  }
  if (typeOf(v) === 'array') {
    if (s.maxItems !== undefined && v.length > s.maxItems) errs.push(`${at}: more than ${s.maxItems}`)
    v.forEach((x, i) => errs.push(...check(x, s.items || {}, `${at}[${i}]`)))
  }
  if (typeof v === 'string' && s.maxLength !== undefined && v.length > s.maxLength) errs.push(`${at}: longer than ${s.maxLength}`)
  return errs
}

// The estimate of scripts/check-docs: one token for each 3.7 ASCII characters.
const tokens = (s) => Math.round([...s].filter((c) => c.charCodeAt(0) < 128).length / 3.7) + [...s].filter((c) => c.charCodeAt(0) >= 128).length

test('the return fits the schema and is about 300 tokens or fewer; /run-plan calls the Workflow', async () => {
  const { RETURN_SCHEMA } = await internals()
  const nodes = [['T0', []], ['T1', ['T0']], ['S1', []], ['S2', ['T1']], ['S3', ['T1']], ['S4', ['S2']], ['S5', ['S4']], ['S6', []], ['S7', ['S1', 'S2', 'S3', 'S4', 'S5', 'S6']]]
  const long = 'x'.repeat(400)
  const { result } = await runScripted(baseArgs(nodes, { done: ['T0', 'T1'] }), {
    rounds: { S2: [`fail:${long}a`, `fail:${long}b`, `fail:${long}c`], S3: ['review'], S1: ['fail:a', 'pass'] },
  })
  assert.deepEqual(check(result, RETURN_SCHEMA), [])
  assert.deepEqual(result.blocked.map((b) => b.id), ['S2'])
  assert.deepEqual(result.review, [{ id: 'S3', round: 1, files: ['scripts/check'] }])
  assert.deepEqual(result.waiting.map((w) => w.id), ['S4', 'S5', 'S7'])
  const text = JSON.stringify(result)
  assert.ok(tokens(text) <= 300, `${tokens(text)} tokens: ${text}`)

  const skill = readFileSync(join(SRC, '.agents/skills/run-plan/SKILL.md'), 'utf8')
  assert.match(skill, /Workflow/)
  assert.match(skill, /\.claude\/workflows\/run-plan\.js/)
  assert.match(skill, /scripts\/run-plan-args/)
  assert.match(skill, /resumeFromRunId/)
})

test('bad args stop the Workflow before any agent runs', async () => {
  const agent = scripted()
  const run = (args) => loadWorkflow()(agent, () => {}, () => {}, args)
  await assert.rejects(run({ graph: graph([['S1', []]]), into: 'main', repo: 'relative' }), /args.repo/)
  await assert.rejects(run({ graph: graph([['S1', ['bad']]]), into: 'main', repo: '/r' }), /needs/)
  await assert.rejects(run(baseArgs([['S1', []]], { fixes: [{ node: 'S9' }] })), /args.fixes/)
  assert.equal(agent.rec.calls.length, 0)
})

// ----------------------------------------------------------- round-trip tests (real shell)

// A temporary clone: main holds the tools under test (the working copy) and the fake plan; the
// node branch starts at main. Only git notes and refs of the clone change.
function makeRepo(nodes) {
  const t = mkdtempSync(join(tmpdir(), 'dshm-run-plan-test-'))
  const repo = join(t, 'repo')
  git(t, 'clone', '-q', SRC, repo)
  git(repo, 'checkout', '-q', '-B', INTO, 'HEAD')
  git(repo, 'config', 'user.name', 'test'); git(repo, 'config', 'user.email', 'test@example.com')
  for (const f of ['scripts/plan', 'scripts/slice-env', 'scripts/brief', 'scripts/run-plan-args', 'scripts/lib', 'scripts/fixtures', '.claude/workflows']) {
    rmSync(join(repo, f), { recursive: true, force: true })
    cpSync(join(SRC, f), join(repo, f), { recursive: true })
  }
  rmSync(join(repo, 'plan'), { recursive: true, force: true })
  mkdirSync(join(repo, 'plan'))
  for (const f of ['plan.json', 'S99.json']) cpSync(join(repo, 'scripts/fixtures/fake-plan', f), join(repo, 'plan', f))
  if (nodes) {
    mkdirSync(join(repo, 'fake-node'))
    writeFileSync(join(repo, 'fake-node/hello.txt'), 'hello\n')
    git(repo, 'add', 'fake-node')
    const fixture = JSON.parse(readFileSync(join(repo, 'plan/S99.json')))
    rmSync(join(repo, 'plan/S99.json'))
    writeFileSync(join(repo, 'plan/plan.json'), JSON.stringify({ title: 'Simulator allocation', nodes }))
    for (const { id } of nodes) {
      const item = { ...fixture.items[0], tier: 'ui' }
      writeFileSync(join(repo, `plan/${id}.json`), JSON.stringify({ id, items: [item] }))
    }
  }
  git(repo, 'add', '-A', 'scripts', 'plan', '.claude/workflows')
  git(repo, 'commit', '-q', '-m', 'tools under test and the fake plan')
  process.env.PATH = join(SRC, 'scripts/fixtures/simctl') + ':' + process.env.PATH
  process.env.DSHM_TEST_DEVICES = join(t, 'devices')
  process.env.DSHM_TMP_ROOT = join(t, 'tmp')
  process.env.DSHM_OWNERS = join(t, 'owners')
  // Fix the baseline after assignment so refused merges still leave the target at base.
  if (!nodes) execFileSync(join(repo, 'scripts/plan'), ['assign', 'S99', '--schedule', '--commit'], { cwd: repo })
  process.env.DSHM_VERIFY_LOGS = join(t, 'verify-logs')
  return { t, repo }
}

// The fake agent. A shell step runs its one command for real (as the real agent is told to).
// The build step is a script: `honest` makes the item true; `editCheck` changes the evidence
// script; otherwise it does nothing. It always reports that all is done. `lyingVerifier`
// reports a pass whatever the command says.
function fakeAgent({ t, repo, honest, editCheck = false, lyingVerifier = false, calls }) {
  return async (prompt, opts = {}) => {
    calls.push({ prompt, opts })
    const sh = prompt.match(/```sh\n([\s\S]*?)\n```/)
    if (sh) {
      const r = spawnSync('bash', ['-c', sh[1]], { encoding: 'utf8', env: { ...process.env, HOME: t } })
      if (lyingVerifier && opts.phase === 'Verify') return { exit: 0, stdout: JSON.stringify({ head: 'x', passed: true }) }
      return { exit: r.status, stdout: r.stdout }
    }
    const m = prompt.match(/^Slice (\S+), round (\d+)\. Brief: (\S+)$/)
    assert.ok(m, `the build prompt is only the ID, the round and the brief path: ${prompt}`)
    const brief = readFileSync(m[3], 'utf8')
    const branch = brief.match(/Branch: `([^`]+)`/)[1]
    const wt = join(t, `wt-${m[1]}`)
    if (!existsSync(wt)) git(repo, 'worktree', 'add', '-q', wt, branch)
    mkdirSync(join(wt, 'fake-node'), { recursive: true })
    writeFileSync(join(wt, 'fake-node/hello.txt'), honest ? 'hello\n' : `not yet ${m[2]}\n`)
    writeFileSync(join(wt, 'fake-node', m[1]), 'built\n')
    if (editCheck) writeFileSync(join(wt, 'scripts/fixtures/fake-plan/check'), '#!/bin/sh\nexit 0\n', { mode: 0o755 })
    git(wt, 'add', '-A'); git(wt, 'commit', '-q', '-m', `fake node round ${m[2]}`)
    return { outside_slice: false, note: 'Done. All items pass; I verified everything myself. RESULT: PASS.' }
  }
}

async function run(opts) {
  const { t, repo } = makeRepo()
  const calls = []
  const logs = []
  const base = git(repo, 'rev-parse', INTO)
  const args = JSON.parse(execFileSync(join(repo, 'scripts/run-plan-args'), ['--into', INTO, '--repo', repo], { cwd: repo, encoding: 'utf8' }))
  const result = await loadWorkflow()(fakeAgent({ t, repo, calls, ...opts }), () => {}, (m) => logs.push(m), args)
  return { t, repo, calls, logs, base, result }
}

test('one node goes from brief to merge; the merge step checks the merge commit again', async () => {
  const { t, repo, calls, base, result } = await run({ honest: true })
  try {
    assert.equal(result.merged.length, 1, JSON.stringify(result, null, 2))
    assert.deepEqual(calls.map((c) => c.opts.phase), ['Brief', 'Build', 'Verify', 'Merge', 'Merge'])
    assert.equal(calls[1].prompt, `Slice S99, round 1. Brief: /tmp/dshm-brief/S99-r1.md`)
    const brief = readFileSync('/tmp/dshm-brief/S99-r1.md', 'utf8')
    assert.match(brief, /The file fake-node\/hello\.txt holds one line: hello/)
    const tip = git(repo, 'rev-parse', `${INTO}^1`)
    const head = git(repo, 'rev-parse', `${tip}^2`)
    assert.equal(git(repo, 'rev-parse', `${tip}^1^1`), base)
    assert.equal(git(repo, 'rev-parse', `${tip}^2`), head)
    assert.deepEqual(result, { into: INTO, tip: tip.slice(0, 12), merged: [{ id: 'S99', rounds: 1, merge: tip.slice(0, 12) }], blocked: [], review: [], waiting: [] })
    const note = JSON.parse(git(repo, 'notes', '--ref=refs/notes/dshm-verify', 'show', tip)).S99
    assert.deepEqual(note.items[0].runs.map((r) => [r.cmd, r.exit]), [['scripts/fixtures/fake-plan/check', 0]])
    for (const c of calls.slice(2)) assert.ok(!c.prompt.includes('RESULT: PASS') && !c.prompt.includes('Done.'))
    // scripts/run-plan-args now finds S99 merged; a fix item (passed: false) makes it run again.
    const s99 = JSON.parse(readFileSync(join(repo, 'plan/S99.json'), 'utf8'))
    s99.items.push({ tier: 'auto', text: 'Fix: hello.txt ends with a newline', files: ['fake-node/hello.txt'], screens: [], passed: false })
    writeFileSync(join(repo, 'plan/S99.json'), JSON.stringify(s99, null, 2) + '\n')
    git(repo, 'commit', '-q', '-am', 'fix item')
    const args = (...x) => JSON.parse(execFileSync(join(repo, 'scripts/run-plan-args'), ['--into', INTO, ...x], { cwd: repo, encoding: 'utf8' }))
    assert.deepEqual(args().done, ['S99'])
    const a = args('--fix', 'S99:1')
    assert.deepEqual(a.fixes, [{ node: 'S99', item: 1, files: ['fake-node/hello.txt'], screens: [] }])
    assert.deepEqual(a.scope.S99, { files: ['fake-node/hello.txt'], screens: [] })
  } finally {
    rmSync(t, { recursive: true, force: true })
  }
})

test('a build agent that reports done without the work, and a verifier that reports a pass: no merge, blocked', async () => {
  const { t, repo, calls, base, result } = await run({ honest: false, lyingVerifier: true })
  try {
    assert.deepEqual(result.merged, [])
    assert.equal(result.blocked[0].round, 2, JSON.stringify(result))
    assert.match(result.blocked[0].why, /^same evidence in 2 rounds: merge 0:scripts\/fixtures\/fake-plan\/check=1$/)
    assert.deepEqual(calls.map((c) => c.opts.phase), ['Brief', 'Build', 'Verify', 'Merge', 'Brief', 'Build', 'Verify', 'Merge'])
    assert.equal(git(repo, 'rev-list', '--merges', `${base}..${INTO}`), '', 'no slice was merged')
  } finally {
    rmSync(t, { recursive: true, force: true })
  }
})

test('an honest verifier stops a node that is not done before the merge step', async () => {
  const { t, repo, calls, base, result } = await run({ honest: false })
  try {
    assert.match(result.blocked[0].why, /^same evidence in 2 rounds: verify 0:/)
    assert.ok(!calls.some((c) => c.opts.phase === 'Merge'))
    assert.equal(git(repo, 'rev-list', '--merges', `${base}..${INTO}`), '')
  } finally {
    rmSync(t, { recursive: true, force: true })
  }
})

test('a merge refused for changed evidence: needs review, and the Workflow never allows it itself', async () => {
  const { t, repo, calls, base, result } = await run({ honest: true, editCheck: true })
  try {
    assert.deepEqual(result.review, [{ id: 'S99', round: 1, files: ['scripts/fixtures/fake-plan/check'] }], JSON.stringify(result))
    assert.deepEqual(result.blocked, [])
    assert.ok(!calls.some((c) => c.prompt.includes('--allow-changed-evidence')))
    assert.equal(git(repo, 'rev-list', '--merges', `${base}..${INTO}`), '')
  } finally {
    rmSync(t, { recursive: true, force: true })
  }
})

test('ready UI nodes get separate simulators and a successor reuses the released slot', async () => {
  const nodes = graph([['S96', []], ['S97', []], ['S98', ['S96']]]).nodes
  const { t, repo } = makeRepo(nodes)
  try {
    const calls = []
    const build = fakeAgent({ t, repo, honest: true, calls })
    const assigned = {}
    let scheduledSecond
    const second = new Promise((resolve) => { scheduledSecond = resolve })
    const agent = async (prompt, opts) => {
      if (opts.phase === 'Build') {
        const id = opts.label.split(' ')[1]
        const row = readFileSync(join(repo, 'scripts/resources.tsv'), 'utf8').split('\n')
          .findLast((line) => line.startsWith(id + '\t')).split('\t')
        assigned[id] = { slot: row[2], sim: row[7] }
        const devices = readdirSync(join(t, 'devices')).map((f) => readFileSync(join(t, 'devices', f), 'utf8'))
        assert.ok(devices.includes(row[7]))
        if (id === 'S96') await second
        if (id === 'S97') scheduledSecond()
      }
      return build(prompt, opts)
    }
    const args = JSON.parse(execFileSync(join(repo, 'scripts/run-plan-args'), ['--into', INTO], { cwd: repo }))
    const result = await loadWorkflow()(agent, () => {}, () => {}, args)
    assert.deepEqual(result.merged.map((m) => m.id).sort(), nodes.map((n) => n.id), JSON.stringify(result))
    assert.notEqual(assigned.S96.sim, assigned.S97.sim)
    assert.notEqual(assigned.S96.slot, assigned.S97.slot)
    assert.equal(assigned.S98.slot, assigned.S96.slot)
    assert.deepEqual(readdirSync(join(t, 'devices')), [])
  } finally {
    rmSync(t, { recursive: true, force: true })
  }
})

test('fresh runs share the committed three-round budget for each node', async () => {
  const nodes = graph([['S96', []], ['S97', []]]).nodes
  const { t, repo } = makeRepo(nodes)
  const args = (...extra) => JSON.parse(execFileSync(join(repo, 'scripts/run-plan-args'),
    ['--into', INTO, ...extra], { cwd: repo }))
  try {
    const builds = []
    for (let round = 1; round <= 3; round++) {
      const build = fakeAgent({ t, repo, honest: false, calls: [] })
      let failed = false
      const interrupted = async (prompt, opts) => {
        if (opts.phase === 'Brief' && failed) throw new Error('workflow interrupted before next round')
        if (opts.phase === 'Build') builds.push(prompt)
        const result = await build(prompt, opts)
        if (opts.phase === 'Verify') failed = !JSON.parse(result.stdout).passed
        return result
      }
      const result = await loadWorkflow()(interrupted, () => {}, () => {}, args('--done', 'S97', '--round', 'S96=1'))
      assert.ok(failed)
      assert.deepEqual(result.merged, [])
      assert.equal(args().rounds.S96, round + 1)
      assert.equal(args().rounds.S97, undefined)
    }
    const idle = scripted()
    const final = await loadWorkflow()(idle, () => {}, () => {}, args('--done', 'S97'))
    assert.equal(idle.rec.calls.length, 0)
    assert.match(final.blocked[0].why, /3 build rounds already used/)
    assert.deepEqual(builds.map((s) => Number(s.match(/round (\d+)/)[1])), [1, 2, 3])
  } finally {
    rmSync(t, { recursive: true, force: true })
  }
})
