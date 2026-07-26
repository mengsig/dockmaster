#!/usr/bin/env node

const assert = require('assert')
const fs = require('fs')
const path = require('path')

const ROOT = path.join(__dirname, '..')
const SOURCE = fs.readFileSync(path.join(ROOT, 'workflows/pr-pipeline.js'), 'utf8')
  .replace('export const meta =', 'const meta =')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

function defaultResponse(label) {
  if (label.startsWith('state:')) return { head: 'a'.repeat(40), porcelain: '' }
  if (label.startsWith('review:')) return { findings: [] }
  if (label === 'verify') return { gateDecision: 'required', reportExit: 0, passed: true, summary: 'verified' }
  if (label.startsWith('tests:')) return { passed: true, summary: 'passed' }
  if (label === 'security') return { surface: false, findings: [], summary: 'no surface' }
  if (label === 'pr') return { url: 'https://github.com/o/r/pull/12' }
  if (label === 'verify-findings') return { refuted: false, rationale: 'real' }
  return {}
}

async function run(overrides, scripted, parallelImpl, sourceOverride) {
  const calls = []; const logs = []; const prompts = []; const queues = {}
  for (const key of Object.keys(scripted || {})) {
    queues[key] = Array.isArray(scripted[key]) ? scripted[key].slice() : scripted[key]
  }
  const agent = async (prompt, options) => {
    const label = options.label
    calls.push(label)
    prompts.push({ label, prompt })
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
  const result = await new AsyncFunction('args', 'agent', 'parallel', 'log', sourceOverride || SOURCE)(
    args, agent, parallel, (message) => logs.push(message))
  return { result, calls, logs, prompts }
}

function assertFullStatusPrompt(runResult) {
  const statePrompts = runResult.prompts.filter(({ label }) => label.startsWith('state:'))
  assert(statePrompts.length > 0, 'expected at least one state-check prompt')
  for (const { prompt } of statePrompts) {
    assert(prompt.includes('git -C /tmp/worktree status --porcelain=v1 --untracked-files=all'))
  }
}

async function checkTierOrder() {
  const cases = [
    ['fast', ['state:before-review', 'review:coldstart', 'state:before-tests', 'tests:gate', 'state:before-pr', 'pr']],
    ['default', ['state:before-review', 'review:coldstart', 'state:before-tests', 'tests:gate', 'state:before-review', 'review:merge-gate', 'state:before-tests', 'tests:gate', 'security', 'state:before-pr', 'pr']],
    ['rigorous', [
      'state:before-review', 'review:coldstart:correctness', 'review:coldstart:security',
      'review:coldstart:concurrency', 'review:coldstart:portability', 'review:coldstart:tests',
      'state:before-tests', 'tests:gate', 'verify', 'security', 'state:before-pr', 'pr',
    ]],
  ]
  for (const [tier, expected] of cases) {
    const actual = await run({ tier }, {})
    assert.equal(actual.result.ok, true, `${tier} should complete`)
    assert.deepEqual(actual.calls, expected, `${tier} gate call order`)
    assertFullStatusPrompt(actual)
  }
}

async function checkFixLoop() {
  const finding = { severity: 'high', file: 'x.js', summary: 'wrong result' }
  const fixed = await run({ gates: [
    { gate: 'review', pass: 'coldstart' }, { gate: 'fix', max_rounds: 1 }, { gate: 'tests' },
  ] }, {
    'review:coldstart': [{ findings: [finding] }, { findings: [] }],
    'state:before-fix': { head: 'a'.repeat(40), porcelain: '' },
    'state:after-fix': { head: 'b'.repeat(40), porcelain: '' },
  })
  assert.equal(fixed.result.ok, true)
  assert.deepEqual(fixed.calls, ['state:before-review', 'review:coldstart', 'state:before-fix', 'fix', 'state:after-fix', 'review:coldstart', 'state:before-tests', 'tests:gate'])

  const dirtyBefore = await run({ gates: [
    { gate: 'review' }, { gate: 'fix', max_rounds: 1 },
  ] }, {
    'review:review': { findings: [finding] },
    'state:before-fix': { head: 'a'.repeat(40), porcelain: '?? stale.txt' },
  })
  assert.equal(dirtyBefore.result.stage, 'fix')
  assert.deepEqual(dirtyBefore.calls, ['state:before-review', 'review:review', 'state:before-fix'])

  for (const after of [
    { head: 'a'.repeat(40), porcelain: ' M x.js' },
    { head: 'b'.repeat(40), porcelain: ' M x.js' },
    { head: 'b'.repeat(40), porcelain: '?? generated.txt' },
  ]) {
    const dirty = await run({ gates: [
      { gate: 'review' }, { gate: 'fix', max_rounds: 1 },
    ] }, {
      'review:review': { findings: [finding] },
      'state:before-fix': { head: 'a'.repeat(40), porcelain: '' },
      'state:after-fix': after,
    })
    assert.equal(dirty.result.stage, 'fix')
    assert.match(dirty.result.detail, /not fully clean/)
  }
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
    [{ gates: [{ gate: 'verify' }] }, { verify: { gateDecision: 'required', reportExit: 1, passed: false, summary: 'broken' } }, 'verify'],
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

async function checkBoundedParallel() {
  const serialBatches = []
  await run({ tier: 'rigorous', parallelCapacity: 1 }, {}, async (thunks) => {
    serialBatches.push(thunks.length)
    return Promise.all(thunks.map((thunk) => thunk()))
  })
  assert.deepEqual(serialBatches, [1, 1, 1, 1, 1])

  const batches = []
  const parallel = async (thunks) => {
    batches.push(thunks.length)
    return Promise.all(thunks.map((thunk) => thunk()))
  }
  await run({ tier: 'rigorous', parallelCapacity: 2 }, {}, parallel)
  assert.deepEqual(batches, [2, 2, 1])

  const finding = { severity: 'medium', file: 'x.js', summary: 'check me' }
  const voterBatches = []
  await run({ parallelCapacity: 2, gates: [
    { gate: 'review', dimensions: ['correctness'] }, { gate: 'verify-findings', voters: 3 },
  ] }, {
    'review:review:correctness': { findings: [finding] },
  }, async (thunks) => {
    voterBatches.push(thunks.length)
    return Promise.all(thunks.map((thunk) => thunk()))
  })
  assert.deepEqual(voterBatches, [1, 2, 1])

  const defaultBatches = []
  await run({ tier: 'rigorous', parallelCapacity: 3 }, {}, async (thunks) => {
    defaultBatches.push(thunks.length)
    return Promise.all(thunks.map((thunk) => thunk()))
  })
  assert.deepEqual(defaultBatches, [3, 2])
  for (const value of [0, 4, 1.5]) {
    await assert.rejects(run({ parallelCapacity: value }, {}), /parallelCapacity/)
  }
}

async function checkCompatibilityEdges() {
  const deferred = await run({ gates: [{ gate: 'await-checks' }, { gate: 'pr' }] }, {})
  assert.deepEqual(deferred.calls, ['state:before-pr', 'pr'])
  assert(deferred.logs.some((line) => line.includes('deferred')))

  const softSkip = await run({ gates: [{ gate: 'tests' }], testCmd: '' }, {})
  assert.deepEqual(softSkip.result, { ok: true, stage: 'complete' })
  assert.deepEqual(softSkip.calls, ['state:before-tests'])

  const verifySkip = await run({ gates: [{ gate: 'verify', optional: true }], noRuntimeSurface: true }, {})
  assert.deepEqual(verifySkip.calls, [])
  // A bare `passed: true` is not enough: the agent must report the gate's own
  // decision and report's exit code, or a forged boolean would pass the gate.
  const forged = await run({ gates: [{ gate: 'verify' }] }, {
    verify: { gateDecision: 'required', reportExit: 1, passed: true, summary: 'looked fine' },
  })
  assert.equal(forged.result.ok, false, 'a claimed pass over a red report must fail the gate')
  assert.equal(forged.result.stage, 'verify')
  const unavailable = await run({ gates: [{ gate: 'verify' }] }, {
    verify: { gateDecision: 'unavailable', reportExit: 3, passed: true, summary: 'no app config' },
  })
  assert.equal(unavailable.result.ok, false, 'an unavailable gate must never pass')
  const undetermined = await run({ gates: [{ gate: 'verify' }] }, {
    verify: { gateDecision: 'undetermined', reportExit: 0, passed: true, summary: 'could not decide' },
  })
  assert.equal(undetermined.result.ok, false, 'an undecided gate must never pass')
  // The gate reads a decision STRING now, so anything it does not recognize —
  // a stale "1", a typo, an invented value — must fail closed, not fall through.
  const garbled = await run({ gates: [{ gate: 'verify' }] }, {
    verify: { gateDecision: '1', reportExit: 0, passed: true, summary: 'stale exit-code answer' },
  })
  assert.equal(garbled.result.ok, false, 'an unrecognized gate decision must fail the gate')
  const noSurface = await run({ gates: [{ gate: 'verify' }] }, {
    verify: { gateDecision: 'not-applicable', reportExit: 0, passed: true, summary: 'no runtime surface moved' },
  })
  assert.equal(noSurface.result.ok, true, 'a mechanical no-surface decision passes')

  // The payoff of #196 at the call sites: the runner asks for the machine-readable
  // form and stops narrating exit codes. A prompt that drops --json would put the
  // agent back on the exit code it cannot distinguish from a crash.
  const prompts = noSurface.prompts.find(({ label }) => label === 'verify')
  assert(prompts.prompt.includes('dm-verify.sh gate runner-test --json'), 'verify gate must be asked for --json')
  assert(!/exit code as gateExit/.test(prompts.prompt), 'verify prompt must not narrate gate exit codes')
  const sec = await run({ gates: [{ gate: 'security', method: 'auto' }] }, {})
  const secPrompt = sec.prompts.find(({ label }) => label === 'security')
  assert(secPrompt.prompt.includes('dm-pr.sh security-scan runner-test --json'), 'security scan must be asked for --json')
  assert(!/exits 1/.test(secPrompt.prompt), 'security prompt must not narrate scan exit codes')

  const untrackedPR = await run({ gates: [{ gate: 'pr' }] }, {
    'state:before-pr': { head: 'b'.repeat(40), porcelain: '?? review-output.json' },
  })
  assert.equal(untrackedPR.result.stage, 'pr')
  assert.deepEqual(untrackedPR.calls, ['state:before-pr'])

  const finding = { severity: 'low', file: 'x.js', summary: 'still present' }
  const unresolved = await run({ gates: [{ gate: 'review' }, { gate: 'fix', max_rounds: 1 }] }, {
    'review:review': [{ findings: [finding] }, { findings: [finding] }],
    'state:before-fix': { head: 'a'.repeat(40), porcelain: '' },
    'state:after-fix': { head: 'b'.repeat(40), porcelain: '' },
  })
  assert.equal(unresolved.result.stage, 'fix')
  assert.match(unresolved.result.detail, /unresolved/)

  await assert.rejects(run({ worktree: '' }, {}), /requires args\.taskId/)
  await assert.rejects(run({ base: '', defaultBranch: '' }, {}), /requires args\.base/)
}

async function checkStatePromptMutation() {
  const mutatedSource = SOURCE.replace('--untracked-files=all', '--untracked-files=no')
  const mutated = await run({ gates: [{ gate: 'tests' }] }, {}, undefined, mutatedSource)
  assert.throws(() => assertFullStatusPrompt(mutated))
}

async function main() {
  await checkTierOrder()
  await checkFixLoop()
  await checkFindingVotes()
  await checkFailures()
  await checkParallelFailure()
  await checkBoundedParallel()
  await checkCompatibilityEdges()
  await checkStatePromptMutation()
  console.log('ok   compatible runner gate order, fan-out, voting, fix, failure, security, and PR paths')
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
