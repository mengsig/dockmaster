#!/usr/bin/env node

const assert = require('assert')
const fs = require('fs')
const path = require('path')

const ROOT = path.join(__dirname, '..')
const SOURCE = fs.readFileSync(path.join(ROOT, 'workflows/pr-pipeline.js'), 'utf8')
  .replace('export const meta =', 'const meta =')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

function defaultResponse(label) {
  if (label.startsWith('review:')) return { findings: [] }
  if (label.startsWith('tests:') || label === 'verify') return { passed: true, summary: 'passed' }
  if (label === 'security') return { surface: false, findings: [], summary: 'no surface' }
  if (label === 'pr') return { url: 'https://github.com/o/r/pull/12' }
  if (label === 'fix:head-status') return { head: 'a'.repeat(40), dirty: false }
  if (label === 'verify-findings') return { refuted: false, rationale: 'real' }
  return {}
}

async function run(overrides, scripted, parallelImpl) {
  const calls = []; const logs = []; const queues = {}
  for (const key of Object.keys(scripted || {})) {
    queues[key] = Array.isArray(scripted[key]) ? scripted[key].slice() : scripted[key]
  }
  const agent = async (prompt, options) => {
    const label = options.label
    calls.push(label)
    let response = queues[label]
    if (Array.isArray(response)) response = response.shift()
    if (typeof response === 'function') response = response({ prompt, options, calls })
    if (response instanceof Error) throw response
    return response === undefined ? defaultResponse(label) : response
  }
  const parallel = parallelImpl || (async (thunks) => {
    assert(thunks.every((thunk) => typeof thunk === 'function'), 'parallel requires thunks')
    return Promise.all(thunks.map((thunk) => thunk()))
  })
  const args = Object.assign({
    taskId: 'runner-test', repo: 'demo', worktree: '/tmp/worktree', branch: 'fix/test',
    binDir: '/tmp/bin', base: 'main', testCmd: 'true',
  }, overrides || {})
  const result = await new AsyncFunction('args', 'agent', 'parallel', 'log', SOURCE)(
    args, agent, parallel, (message) => logs.push(message))
  return { result, calls, logs }
}

async function checkTierOrder() {
  const cases = [
    ['fast', ['review:coldstart', 'tests:gate', 'pr']],
    ['default', ['review:coldstart', 'tests:gate', 'review:merge-gate', 'tests:gate', 'security', 'pr']],
    ['rigorous', [
      'review:coldstart:correctness', 'review:coldstart:security', 'review:coldstart:concurrency',
      'review:coldstart:portability', 'review:coldstart:tests', 'tests:gate', 'verify', 'security', 'pr',
    ]],
  ]
  for (const [tier, expected] of cases) {
    const actual = await run({ tier }, {})
    assert.equal(actual.result.ok, true, `${tier} should complete`)
    assert.deepEqual(actual.calls, expected, `${tier} gate call order`)
  }
}

async function checkFixLoop() {
  const finding = { severity: 'high', file: 'x.js', summary: 'wrong result' }
  const fixed = await run({ gates: [
    { gate: 'review', pass: 'coldstart' }, { gate: 'fix', max_rounds: 1 }, { gate: 'tests' },
  ] }, {
    'review:coldstart': [{ findings: [finding] }, { findings: [] }],
    'fix:head-status': [{ head: 'a'.repeat(40), dirty: false }, { head: 'b'.repeat(40), dirty: false }],
  })
  assert.equal(fixed.result.ok, true)
  assert.deepEqual(fixed.calls, ['review:coldstart', 'fix:head-status', 'fix', 'fix:head-status', 'review:coldstart', 'tests:gate'])

  const dirty = await run({ gates: [
    { gate: 'review' }, { gate: 'fix', max_rounds: 1 },
  ] }, {
    'review:review': { findings: [finding] },
    'fix:head-status': [{ head: 'a'.repeat(40), dirty: false }, { head: 'a'.repeat(40), dirty: true }],
  })
  assert.equal(dirty.result.stage, 'fix')
  assert.match(dirty.result.detail, /no commit/)
}

async function checkFindingVotes() {
  const finding = { severity: 'medium', file: 'x.js', summary: 'possibly wrong' }
  for (const test of [
    { votes: [{ refuted: true }, { refuted: true }, { refuted: false }], expected: '0/1' },
    { votes: [{ refuted: true }, { refuted: false }, { refuted: false }], expected: '1/1' },
  ]) {
    const checked = await run({ gates: [
      { gate: 'review' }, { gate: 'verify-findings', voters: 3 },
    ] }, {
      'review:review': { findings: [finding] },
      'verify-findings': test.votes.map((vote) => Object.assign({ rationale: 'checked' }, vote)),
    })
    assert(checked.logs.some((line) => line.includes(test.expected)), `vote result ${test.expected}`)
  }
}

async function checkFailures() {
  const finding = { severity: 'high', file: 'auth.js', summary: 'auth bypass' }
  const cases = [
    [{ gates: [{ gate: 'tests' }] }, { 'tests:gate': { passed: false, summary: 'red' } }, 'tests'],
    [{ gates: [{ gate: 'verify' }] }, { verify: { passed: false, summary: 'broken' } }, 'verify'],
    [{ gates: [{ gate: 'security' }] }, { security: { surface: true, findings: [finding], summary: 'unsafe' } }, 'security'],
    [{ gates: [{ gate: 'pr' }] }, { pr: { url: 'not-a-pr' } }, 'pr'],
    [{ gates: [{ gate: 'unknown' }] }, {}, 'config'],
  ]
  for (const [args, scripted, stage] of cases) {
    const failed = await run(args, scripted)
    assert.equal(failed.result.ok, false)
    assert.equal(failed.result.stage, stage)
  }

  for (const label of ['review:review', 'tests:gate', 'verify', 'security', 'pr']) {
    const gate = label.startsWith('review:') ? 'review' : label.replace(':gate', '')
    await assert.rejects(run({ gates: [{ gate }] }, { [label]: new Error(`${label} unavailable`) }), /unavailable/)
  }
}

async function checkParallelFailure() {
  await assert.rejects(run({ tier: 'rigorous' }, {}, async () => {
    throw new Error('parallel host unavailable')
  }), /parallel host unavailable/)
}

async function checkCompatibilityEdges() {
  const deferred = await run({ gates: [{ gate: 'await-checks' }, { gate: 'pr' }] }, {})
  assert.deepEqual(deferred.calls, ['pr'])
  assert(deferred.logs.some((line) => line.includes('deferred')))

  const softSkip = await run({ gates: [{ gate: 'tests' }], testCmd: '' }, {})
  assert.deepEqual(softSkip.result, { ok: true, stage: 'complete' })
  assert.deepEqual(softSkip.calls, [])

  const verifySkip = await run({ gates: [{ gate: 'verify', optional: true }], noRuntimeSurface: true }, {})
  assert.deepEqual(verifySkip.calls, [])

  const finding = { severity: 'low', file: 'x.js', summary: 'still present' }
  const unresolved = await run({ gates: [{ gate: 'review' }, { gate: 'fix', max_rounds: 1 }] }, {
    'review:review': [{ findings: [finding] }, { findings: [finding] }],
    'fix:head-status': [{ head: 'a'.repeat(40), dirty: false }, { head: 'b'.repeat(40), dirty: false }],
  })
  assert.equal(unresolved.result.stage, 'fix')
  assert.match(unresolved.result.detail, /unresolved/)

  await assert.rejects(run({ worktree: '' }, {}), /requires args\.taskId/)
  await assert.rejects(run({ base: '', defaultBranch: '' }, {}), /requires args\.base/)
}

async function main() {
  await checkTierOrder()
  await checkFixLoop()
  await checkFindingVotes()
  await checkFailures()
  await checkParallelFailure()
  await checkCompatibilityEdges()
  console.log('ok   compatible runner gate order, fan-out, voting, fix, failure, security, and PR paths')
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
