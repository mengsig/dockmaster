#!/usr/bin/env node
// tests/check-ci-graph.js - pins the SHAPE of .github/workflows/ci.yml.
//
// The workflow gates itself, so a PR that weakens the gate verifies itself
// green: add a job and forget `ci-gate.needs`, flip predicate-quantifier back
// to the `some` default, grow the path-filter exclusion list, reword a
// `changes` output expression, or drop a heavy leg's `if:` guard, and this
// fails.
//
// It is a LINE parser, not a YAML parser: this repo ships no dependencies and
// the checks must also run under Node 14. Every probe runs against
// comment-stripped text and pins whole lines rather than substrings, but it
// does NOT model YAML anchors, flow-style job mappings, folded scalars, or
// trailing same-line comments. A drift tripwire, not a proof --
// .dm-knowledge/ci.md names what it cannot see.
//
// Run: node tests/check-ci-graph.js   (exit 0 = no drift)

const fs = require('fs')
const path = require('path')

const ROOT = process.env.DM_CHECK_ROOT || path.join(__dirname, '..')
const WORKFLOW = path.join(ROOT, '.github', 'workflows', 'ci.yml')
const SMOKE = path.join(ROOT, 'tests', 'smoke.sh')
const MAX_TIMEOUT_MINUTES = 30

// The legs that run tests/smoke.sh in slices. The shard count is owned by
// smoke.sh (its `# shard:split` markers), so the matrix and the `--shard k/n`
// argument are both derived from it here rather than pinned to a literal: a
// marker added without touching the workflow would otherwise leave a whole
// group of sections unrun, and no test would notice.
const SHARDED_LEGS = ['smoke-linux', 'smoke-bash32']

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
// Pinned PER FILTER, so a widened `code` exclusion list is a deliberate,
// reviewed edit (growing it is how a path filter silently stops running a
// needed test) and so an inclusion pattern cannot be smuggled into `code`.
// The two inclusion filters hold ONE pattern each on purpose: under
// predicate-quantifier 'every' a file must match every pattern in its filter,
// so a second entry would make the filter match nothing.
const EXPECTED_FILTERS = {
  code: [
    '**',
    '!docs/**',
    '!.dm-knowledge/**',
    '!assets/**',
    '!CHANGELOG.md',
    '!CONTRIBUTING.md',
    '!SECURITY.md',
    '!LICENSE',
  ],
  suite: ['tests/smoke.sh'],
  ci_workflow: ['.github/workflows/ci.yml'],
}
// The two expressions the whole design hangs on, pinned VERBATIM. `code:
// ${{ steps.filter.outputs.code == 'true' }}` (dropping the non-PR clause) is a
// plausible simplification that stays green on every PR and surfaces only as a
// red main on the first push; `code: 'false'` is a total silent bypass.
const EXPECTED_OUTPUTS = {
  code: "${{ github.event_name != 'pull_request' || steps.filter.outputs.code == 'true' }}",
  macos_full: "${{ github.event_name != 'pull_request' || (steps.filter.outputs.code == 'true' && (contains(github.event.pull_request.labels.*.name, 'ci:macos') || steps.filter.outputs.suite == 'true' || steps.filter.outputs.ci_workflow == 'true')) }}",
}
// Load-bearing lines of the ci-gate script. Without these the gate is back to
// reading each leg's own `skipped` as permission to pass.
const GATE_INVARIANTS = [
  '"smoke-linux:$SMOKE_LINUX_RESULT:$CODE"',
  '"smoke-bash32:$SMOKE_BASH32_RESULT:$CODE"',
  '"macos:$MACOS_RESULT:$CODE"',
  '"macos-full:$MACOS_FULL_RESULT:$MACOS_FULL_EXPECTED"',
  'if [ "$required" = "true" ]; then',
  '[ "$result" = "success" ] && continue',
  'true|false) ;;',
]

// Every probe runs against comment-stripped text. Hardcoding a pass while
// leaving the original line in a comment beside it is otherwise invisible to
// every pin below, and a column-0 comment would end the jobs mapping early.
function stripComments(source) {
  return source.split('\n').filter((line) => !/^\s*#/.test(line)).join('\n')
}

function unquote(value) {
  const v = String(value).trim()
  const m = /^(['"])([\s\S]*)\1$/.exec(v)
  return m ? m[2] : v
}

// Splits the `jobs:` mapping into { jobName: rawText }. Job keys sit at exactly
// two spaces; everything more-indented belongs to the job above it.
function parseJobs(source) {
  const lines = source.split('\n')
  const start = lines.indexOf('jobs:')
  if (start === -1) throw new Error(`no top-level "jobs:" key in ${WORKFLOW}`)
  const jobs = {}
  let current = null
  for (let i = start + 1; i < lines.length; i++) {
    const jobKey = /^ {2}("[A-Za-z0-9_-]+"|'[A-Za-z0-9_-]+'|[A-Za-z0-9_-]+):\s*$/.exec(lines[i])
    if (jobKey) {
      current = unquote(jobKey[1])
      jobs[current] = []
      continue
    }
    if (/^\S/.test(lines[i])) break // a new top-level key ends the jobs mapping
    if (current) jobs[current].push(lines[i])
  }
  if (Object.keys(jobs).length < 2) throw new Error(`parsed fewer than 2 jobs from ${WORKFLOW}`)
  const out = {}
  for (const name of Object.keys(jobs)) out[name] = jobs[name].join('\n')
  return out
}

// `needs: [a, b]`, `needs: a`, or a block list. [] when the key is absent.
function parseNeeds(jobText) {
  const inline = /^ {4}needs:\s*\[([^\]]*)\]\s*$/m.exec(jobText)
  if (inline) return inline[1].split(',').map(unquote).filter(Boolean)
  const single = /^ {4}needs:\s*(["']?[A-Za-z0-9_-]+["']?)\s*$/m.exec(jobText)
  if (single) return [unquote(single[1])]
  const block = /^ {4}needs:\s*\n((?: {6}-[^\n]*\n?)+)/m.exec(jobText)
  if (!block) return []
  return block[1].split('\n').map((l) => l.replace(/^\s*-\s*/, '')).map(unquote).filter(Boolean)
}

function hasLine(text, line) {
  return text.split('\n').indexOf(line) !== -1
}

// Every job must reach ci-gate three ways: named in `needs`, bound to an env
// var by an exact `needs.<job>.result` line, and that env var actually READ by
// the gate script. Adding a job therefore needs no edit here -- but forgetting
// any of the three wires does fail.
function checkGateWiring(jobs, fail) {
  const gate = jobs['ci-gate']
  const expected = Object.keys(jobs).filter((n) => n !== 'ci-gate').sort()
  const actual = parseNeeds(gate).slice().sort()
  if (!(expected.length === actual.length && expected.every((n, i) => n === actual[i]))) {
    fail(`ci-gate.needs must list every other job.\n     expected: [${expected.join(', ')}]\n     actual:   [${actual.join(', ')}]`)
    return
  }
  if (!/^ {4}if: always\(\)\s*$/m.test(gate)) {
    fail('ci-gate must carry `if: always()`, or a skipped leg leaves it pending forever')
  }
  const declared = (gate.match(/^ {10}[A-Za-z0-9_]+:/gm) || []).map((l) => l.trim().slice(0, -1))
  const dupes = declared.filter((n, i) => declared.indexOf(n) !== i)
  if (dupes.length) {
    fail(`ci-gate declares ${dupes.join(', ')} more than once -- YAML last-wins would let a hardcoded value shadow the real expression`)
  }
  for (const name of expected) checkOneJobIsWired(gate, name, fail)
}

function checkOneJobIsWired(gate, name, fail) {
  // Whole line, not a substring: `MACOS_FULL_RESULT: success` hardcoded beside
  // a surviving mention of the real expression must not pass.
  const re = new RegExp(`^ {10}([A-Z0-9_]+): \\$\\{\\{ needs\\.${name.replace(/[-]/g, '\\-')}\\.result \\}\\}$`, 'gm')
  const found = []
  let m
  while ((m = re.exec(gate)) !== null) found.push(m[1])
  if (found.length !== 1) {
    fail(`ci-gate must bind exactly one env var to \`\${{ needs.${name}.result }}\` on its own line (found ${found.length})`)
    return
  }
  if (gate.indexOf(`$${found[0]}`) === -1) {
    fail(`ci-gate declares ${found[0]} for ${name} but never reads it, so ${name} failing could not fail the gate`)
  }
}

// Pulls the literal block scalar under `filters:` and returns { filter: [items] },
// accepting single-quoted, double-quoted and bare items alike. A double-quoted
// entry was invisible to the single-quote-only regex this replaces, which let a
// `- "!bin/**"` exclusion ride along under a still-matching pinned list.
function parseFilterPatterns(changesText, fail) {
  const lines = changesText.split('\n')
  let at = -1
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*filters:\s*\S*\s*$/.test(lines[i])) { at = i; break }
  }
  if (at === -1) { fail('could not locate the `filters:` key in the changes job'); return null }
  const scalar = /^\s*filters:\s*(\S*)\s*$/.exec(lines[at])[1]
  if (scalar !== '|') {
    fail(`filters must use a literal block scalar (\`filters: |\`), got \`filters: ${scalar}\` -- a folded scalar rewrites newlines and changes what paths-filter parses`)
    return null
  }
  const baseIndent = /^\s*/.exec(lines[at])[0].length
  const filters = {}
  let current = null
  for (let i = at + 1; i < lines.length; i++) {
    if (lines[i].trim() === '') continue
    if (/^\s*/.exec(lines[i])[0].length <= baseIndent) break
    const named = /^\s*("?[A-Za-z0-9_-]+"?|'[A-Za-z0-9_-]+'):\s*$/.exec(lines[i])
    if (named) { current = unquote(named[1]); filters[current] = []; continue }
    const item = /^\s*-\s+(.*?)\s*$/.exec(lines[i])
    if (!item) continue
    if (!current) { fail('a `filters:` entry appears before any filter name'); return null }
    filters[current].push(unquote(item[1]))
  }
  return filters
}

function checkPathFilter(changesText, fail) {
  if (!/predicate-quantifier:\s*'every'/.test(changesText)) {
    fail("changes must set predicate-quantifier: 'every' -- the `some` default ORs the `!` patterns into `**` and the filter stops excluding anything")
  }
  const filters = parseFilterPatterns(changesText, fail)
  if (filters) {
    const want = Object.keys(EXPECTED_FILTERS).sort()
    const got = Object.keys(filters).sort()
    if (want.join(',') !== got.join(',')) {
      fail(`the set of path filters changed: expected [${want.join(', ')}], got [${got.join(', ')}].\n     Each one feeds a \`changes\` output, so adding or dropping one silently redefines when a leg runs.`)
    }
    for (const name of want) {
      const patterns = filters[name] || []
      const expected = EXPECTED_FILTERS[name]
      const same = patterns.length === expected.length && patterns.every((p, i) => p === expected[i])
      if (!same) {
        fail(`the \`${name}\` path filter changed. In \`code\` every entry is a promise that nothing under test reads it; in an inclusion filter a second entry makes it match NOTHING under predicate-quantifier 'every'. Re-verify before updating this test.\n     expected: [${expected.join(', ')}]\n     actual:   [${patterns.join(', ')}]`)
      }
    }
  }
  for (const name of Object.keys(EXPECTED_OUTPUTS)) {
    const wanted = `      ${name}: ${EXPECTED_OUTPUTS[name]}`
    if (!hasLine(changesText, wanted)) {
      fail(`changes.outputs.${name} must be verbatim:\n     ${wanted.trim()}\n     Every leg's guard and ci-gate's required/not-required split hang on this expression.`)
    }
  }
}

function checkLegGuards(jobs, gateText, fail) {
  for (const leg of Object.keys(GATED_LEGS)) {
    if (!jobs[leg]) { fail(`job ${leg} is gone; ci-gate's structural check assumes it exists`); continue }
    const wanted = `    if: needs.changes.outputs.${GATED_LEGS[leg]} == 'true'`
    if (!hasLine(jobs[leg], wanted)) {
      fail(`${leg} must be guarded verbatim by:\n     ${wanted.trim()}\n     ci-gate requires success on exactly that condition, so any other spelling lets the two drift apart.`)
    }
  }
  for (const invariant of GATE_INVARIANTS) {
    if (gateText.indexOf(invariant) === -1) {
      fail(`ci-gate lost a load-bearing line, so it may be back to trusting a leg's own \`skipped\`:\n     ${invariant}`)
    }
  }
}

// The matrix must cover exactly 1..n of smoke.sh's own shard count, and the
// invocation must pass that same n. smoke.sh refuses a mismatched n at runtime,
// so a drifted denominator is loud -- but a matrix that is merely SHORT (fewer
// legs than shards) runs green while silently dropping sections, which is the
// case this pin exists for.
function checkShardMatrix(jobs, fail) {
  const shards = fs.readFileSync(SMOKE, 'utf8').split('\n')
    .filter((line) => line === '# shard:split').length + 1
  const wantList = Array.from({ length: shards }, (unused, i) => i + 1).join(', ')
  for (const leg of SHARDED_LEGS) {
    if (!jobs[leg]) { fail(`job ${leg} is gone; it is what runs the smoke suite`); continue }
    const matrix = /^ {8}shard: \[([^\]]*)\]\s*$/m.exec(jobs[leg])
    if (!matrix) {
      fail(`${leg} must declare its shards inline as \`shard: [1, 2, ...]\` (tests/smoke.sh has ${shards})`)
    } else if (matrix[1].trim() !== wantList) {
      fail(`${leg}'s matrix is [${matrix[1].trim()}] but tests/smoke.sh has ${shards} shards; expected [${wantList}]`)
    }
    if (!/^ {6}fail-fast: false\s*$/m.test(jobs[leg])) {
      fail(`${leg} must set \`fail-fast: false\`, or one red shard cancels the others and their failures go unreported`)
    }
    const invocations = jobs[leg].match(/--shard \$\{\{ matrix\.shard \}\}\/(\d+)/g) || []
    if (invocations.length !== 1) {
      fail(`${leg} must run the suite exactly once as \`--shard \${{ matrix.shard }}/${shards}\` (found ${invocations.length})`)
    } else if (invocations[0] !== `--shard \${{ matrix.shard }}/${shards}`) {
      fail(`${leg} runs \`${invocations[0]}\` but tests/smoke.sh has ${shards} shards`)
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

function checkTimeouts(jobs, fail) {
  for (const name of Object.keys(jobs)) {
    const m = /^ {4}timeout-minutes: (\d+)\s*$/m.exec(jobs[name])
    if (!m) { fail(`job ${name} has no timeout-minutes; a hung job would burn the full 6h default`); continue }
    if (Number(m[1]) > MAX_TIMEOUT_MINUTES) {
      fail(`job ${name} has timeout-minutes: ${m[1]}, above the ${MAX_TIMEOUT_MINUTES}-minute ceiling -- a cap that cannot bind is not a cap`)
    }
  }
}

// This file guards nothing while nothing runs it. Deleting the step that
// invokes it would otherwise be invisible to every check above. Same for the
// partition check: it is the only thing in CI that proves the shards cover the
// whole suite, and everything above only pins the workflow's side of that.
function checkSelfIsInvoked(jobs, fail) {
  const wanted = [
    '        run: node tests/check-ci-graph.js',
    '        run: bash tests/smoke.sh --shard-plan',
  ]
  for (const line of wanted) {
    if (!jobs.fast || !hasLine(jobs.fast, line)) {
      fail(`the fast job must invoke this step verbatim:\n     ${line.trim()}\n     Otherwise deleting it silently disables the check it runs.`)
    }
  }
}

function main() {
  const source = stripComments(fs.readFileSync(WORKFLOW, 'utf8'))
  const jobs = parseJobs(source)
  let failed = false
  const fail = (msg) => { failed = true; console.error(`FAIL ${msg}`) }

  if (!jobs.changes) throw new Error('no `changes` job: the whole path-filter contract is gone')
  if (!jobs['ci-gate']) throw new Error('no `ci-gate` job: nothing aggregates the legs')

  checkTimeouts(jobs, fail)
  checkGateWiring(jobs, fail)
  checkPathFilter(jobs.changes, fail)
  checkLegGuards(jobs, jobs['ci-gate'], fail)
  checkShardMatrix(jobs, fail)
  checkUnconditionalJobs(jobs, fail)
  checkSelfIsInvoked(jobs, fail)

  if (failed) {
    console.error('\nCI graph drift: see .dm-knowledge/ci.md for why each of these holds.')
    process.exit(1)
  }
  console.log(`ok   CI graph intact: ${Object.keys(jobs).length} jobs, all gated by ci-gate`)
}

main()
