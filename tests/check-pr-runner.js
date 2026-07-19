#!/usr/bin/env node

const assert = require('assert')
const fs = require('fs')
const path = require('path')

const ROOT = path.join(__dirname, '..')
const SOURCE = fs.readFileSync(path.join(ROOT, 'workflows/pr-pipeline.js'), 'utf8')
  .replace('export const meta =', 'const meta =')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

function runner(agent) {
  return new AsyncFunction('args', 'agent', 'parallel', 'log', SOURCE)(
    {
      taskId: 'security-test', repo: 'demo', worktree: '/tmp/worktree',
      binDir: '/tmp/bin', base: 'main', gates: [{ gate: 'security', method: 'auto' }],
    },
    agent,
    async (thunks) => Promise.all(thunks.map((thunk) => thunk())),
    () => {},
  )
}

async function main() {
  const finding = { severity: 'high', file: 'src/auth.js', summary: 'auth bypass' }
  const failed = await runner(async () => ({ surface: true, findings: [finding], summary: 'one finding' }))
  assert.equal(failed.ok, false)
  assert.equal(failed.stage, 'security')
  assert.deepEqual(failed.findings, [finding])

  const skipped = await runner(async () => ({ surface: false, findings: [], summary: 'no surface' }))
  assert.deepEqual(skipped, { ok: true, stage: 'complete' })

  await assert.rejects(runner(async () => { throw new Error('review capability missing') }), /capability missing/)
  console.log('ok   compatible-host security gate consumes results and fails closed')
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
