#!/usr/bin/env node
// tests/check-ci-graph.js - pins the SHAPE of .github/workflows/ci.yml.
//
// The workflow gates itself, so a PR that weakens the gate verifies itself
// green. This catches that class the way check-gate-drift.js catches gate-list
// drift: add a job and forget `ci-gate.needs`, flip predicate-quantifier back
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
const MAX_TIMEOUT_MINUTES = 30

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
// The two expressions the whole design hangs on, pinned VERBATIM. `code:
// ${{ steps.filter.outputs.code == 'true' }}` (dropping the non-PR clause) is a
// plausible simplification that stays green on every PR and surfaces only as a
// red main on the first push; `code: 'false'` is a total silent bypass.
const EXPECTED_OUTPUTS = {
  code: "${{ github.event_name != 'pull_request' || steps.filter.outputs.code == 'true' }}",
  macos_full: "${{ github.event_name != 'pull_request' || (steps.filter.outputs.code == 'true' && contains(github.event.pull_request.labels.*.name, 'ci:macos')) }}",
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

// Pulls the literal block scalar under `filters:` and returns its list entries,
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
  const patterns = []
  for (let i = at + 1; i < lines.length; i++) {
    if (lines[i].trim() === '') continue
    if (/^\s*/.exec(lines[i])[0].length <= baseIndent) break
    const item = /^\s*-\s+(.*?)\s*$/.exec(lines[i])
    if (item) patterns.push(unquote(item[1]))
  }
  return patterns
}

function checkPathFilter(changesText, fail) {
  if (!/predicate-quantifier:\s*'every'/.test(changesText)) {
    fail("changes must set predicate-quantifier: 'every' -- the `some` default ORs the `!` patterns into `**` and the filter stops excluding anything")
  }
  const patterns = parseFilterPatterns(changesText, fail)
  if (patterns) {
    const same = patterns.length === EXPECTED_FILTERS.length
      && patterns.every((p, i) => p === EXPECTED_FILTERS[i])
    if (!same) {
      fail(`path-filter list changed. Every entry is a promise that nothing under test reads it -- re-verify before updating this test.\n     expected: [${EXPECTED_FILTERS.join(', ')}]\n     actual:   [${patterns.join(', ')}]`)
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
// invokes it would otherwise be invisible to every check above.
function checkSelfIsInvoked(jobs, fail) {
  const wanted = '        run: node tests/check-ci-graph.js'
  if (!jobs.fast || !hasLine(jobs.fast, wanted)) {
    fail(`the fast job must invoke this check verbatim:\n     ${wanted.trim()}\n     Otherwise deleting the step silently disables every pin in this file.`)
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
  checkUnconditionalJobs(jobs, fail)
  checkSelfIsInvoked(jobs, fail)

  if (failed) {
    console.error('\nCI graph drift: see .dm-knowledge/ci.md for why each of these holds.')
    process.exit(1)
  }
  console.log(`ok   CI graph intact: ${Object.keys(jobs).length} jobs, all gated by ci-gate`)
}

main()
