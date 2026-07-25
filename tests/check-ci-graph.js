#!/usr/bin/env node
// tests/check-ci-graph.js - pins the SHAPE of .github/workflows/ci.yml.
//
// The workflow gates itself, so a PR that weakens the gate verifies itself
// green. This catches that class the way check-gate-drift.js catches gate-list
// drift: add a job and forget `ci-gate.needs`, flip predicate-quantifier back
// to the `some` default, grow the path-filter exclusion list, or drop a heavy
// leg's `if:` guard, and this fails.
//
// Deliberately a line parser, not a YAML library: this repo ships no
// dependencies and the checks must also run under Node 14.
//
// Run: node tests/check-ci-graph.js   (exit 0 = no drift)

const fs = require('fs')
const path = require('path')

const ROOT = process.env.DM_CHECK_ROOT || path.join(__dirname, '..')
const WORKFLOW = path.join(ROOT, '.github', 'workflows', 'ci.yml')

// The heavy legs, and the `changes` output that decides whether each runs.
// ci-gate must read the SAME output rather than trusting the job's own result.
const GATED_LEGS = {
  'smoke-linux': 'code',
  'smoke-bash32': 'code',
  macos: 'code',
  'macos-full': 'macos_full',
}
// Jobs that must run on every event, which is what lets ci-gate hard-require
// them. A `needs:` or `if:` on either would make a skip legitimate.
const UNCONDITIONAL_JOBS = ['fast', 'node14-compat']
// Pinned so a widened exclusion list is a deliberate, reviewed edit. Growing it
// is how a path filter silently stops running a needed test.
const EXPECTED_FILTERS = [
  '**',
  '!docs/**',
  '!.dm-knowledge/**',
  '!assets/**',
  '!CHANGELOG.md',
  '!CONTRIBUTING.md',
  '!SECURITY.md',
  '!LICENSE',
]

// Splits the `jobs:` mapping into { jobName: rawText }. Job keys sit at exactly
// two spaces; everything more-indented (plus blanks and comments) belongs to the
// job above it.
function parseJobs(source) {
  const lines = source.split('\n')
  const start = lines.indexOf('jobs:')
  if (start === -1) throw new Error(`no top-level "jobs:" key in ${WORKFLOW}`)
  const jobs = {}
  let current = null
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i]
    const jobKey = /^ {2}([A-Za-z0-9_-]+):\s*$/.exec(line)
    if (jobKey) {
      current = jobKey[1]
      jobs[current] = []
      continue
    }
    if (/^\S/.test(line)) break // a new top-level key ends the jobs mapping
    if (current) jobs[current].push(line)
  }
  const names = Object.keys(jobs)
  if (names.length < 2) throw new Error(`parsed only ${names.length} job(s) from ${WORKFLOW}`)
  const out = {}
  for (const name of names) out[name] = jobs[name].join('\n')
  return out
}

// `needs: [a, b, c]` or `needs: a`. Returns [] when the key is absent.
function parseNeeds(jobText) {
  const inline = /^ {4}needs:\s*\[([^\]]*)\]\s*$/m.exec(jobText)
  if (inline) return inline[1].split(',').map((s) => s.trim()).filter(Boolean)
  const single = /^ {4}needs:\s*([A-Za-z0-9_-]+)\s*$/m.exec(jobText)
  return single ? [single[1]] : []
}

function checkGateCoversEveryJob(jobs, fail) {
  const expected = Object.keys(jobs).filter((n) => n !== 'ci-gate').sort()
  const actual = parseNeeds(jobs['ci-gate']).slice().sort()
  const same = expected.length === actual.length && expected.every((n, i) => n === actual[i])
  if (!same) {
    fail(`ci-gate.needs must list every other job.\n     expected: [${expected.join(', ')}]\n     actual:   [${actual.join(', ')}]`)
    return
  }
  if (!/^ {4}if: always\(\)\s*$/m.test(jobs['ci-gate'])) {
    fail('ci-gate must carry `if: always()`, or a skipped leg leaves it pending forever')
  }
  for (const name of expected) {
    if (jobs['ci-gate'].indexOf(`needs.${name}.result`) === -1) {
      fail(`ci-gate does not read needs.${name}.result, so ${name}'s outcome cannot affect it`)
    }
  }
}

function checkPathFilter(changesText, fail) {
  if (!/predicate-quantifier:\s*'every'/.test(changesText)) {
    fail("changes must set predicate-quantifier: 'every' -- the `some` default ORs the `!` patterns into `**` and the filter stops excluding anything")
  }
  const block = /filters:\s*\|\s*\n([\s\S]*?)\n\s{4}\S/.exec(changesText + '\n    x')
  if (!block) { fail('could not locate the `filters: |` block in the changes job'); return }
  const patterns = []
  const re = /^\s+- '(.*)'\s*$/gm
  let m
  while ((m = re.exec(block[1])) !== null) patterns.push(m[1])
  const same = patterns.length === EXPECTED_FILTERS.length
    && patterns.every((p, i) => p === EXPECTED_FILTERS[i])
  if (!same) {
    fail(`path-filter list changed. Every entry here is a promise that nothing under test reads it -- re-verify before updating this test.\n     expected: [${EXPECTED_FILTERS.join(', ')}]\n     actual:   [${patterns.join(', ')}]`)
  }
  for (const output of ['code', 'macos_full']) {
    if (!new RegExp(`^ {6}${output}:`, 'm').test(changesText)) {
      fail(`changes must declare the \`${output}\` output; ci-gate reads it`)
    }
  }
}

function checkLegGuards(jobs, gateText, fail) {
  for (const leg of Object.keys(GATED_LEGS)) {
    const output = GATED_LEGS[leg]
    if (!jobs[leg]) { fail(`job ${leg} is gone; ci-gate's structural check assumes it exists`); continue }
    const guard = `needs.changes.outputs.${output} == 'true'`
    if (jobs[leg].indexOf(guard) === -1) {
      fail(`${leg} must be guarded by \`${guard}\` -- ci-gate requires success on exactly that condition, so a different spelling lets the two drift apart`)
    }
  }
  // The gate must actually consult those outputs, not just receive them.
  for (const varName of ['CODE', 'MACOS_FULL_EXPECTED']) {
    if (gateText.indexOf(`$${varName}`) === -1) {
      fail(`ci-gate no longer reads $${varName}, so it is back to trusting a leg's own \`skipped\``)
    }
  }
}

function checkUnconditionalJobs(jobs, fail) {
  for (const name of UNCONDITIONAL_JOBS) {
    if (!jobs[name]) { fail(`job ${name} is gone; ci-gate hard-requires it`); continue }
    if (/^ {4}if:/m.test(jobs[name]) || parseNeeds(jobs[name]).length > 0) {
      fail(`${name} must have no \`if:\` and no \`needs:\` -- ci-gate treats a skip there as a bug, not a filter decision`)
    }
  }
}

function main() {
  const source = fs.readFileSync(WORKFLOW, 'utf8')
  const jobs = parseJobs(source)
  let failed = false
  const fail = (msg) => { failed = true; console.error(`FAIL ${msg}`) }

  for (const name of Object.keys(jobs)) {
    if (!/^ {4}timeout-minutes: \d+\s*$/m.test(jobs[name])) {
      fail(`job ${name} has no timeout-minutes; a hung job would burn the full 6h default`)
    }
  }
  if (!jobs.changes) throw new Error('no `changes` job: the whole path-filter contract is gone')
  if (!jobs['ci-gate']) throw new Error('no `ci-gate` job: nothing aggregates the legs')

  checkGateCoversEveryJob(jobs, fail)
  checkPathFilter(jobs.changes, fail)
  checkLegGuards(jobs, jobs['ci-gate'], fail)
  checkUnconditionalJobs(jobs, fail)

  if (failed) {
    console.error('\nCI graph drift: see .dm-knowledge/ci.md for why each of these holds.')
    process.exit(1)
  }
  console.log(`ok   CI graph intact: ${Object.keys(jobs).length} jobs, all gated by ci-gate`)
}

main()
