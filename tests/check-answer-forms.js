#!/usr/bin/env node
// tests/check-answer-forms.js - pins the ANSWER-CARRYING subcommand family (#196).
//
// Some bin/ subcommands exit nonzero to report an ANSWER, not a failure:
// `tangle` exits 1 to say "tangled", `security-scan` exits 1 to say "no signals
// found". Any consumer that treats nonzero as failure — set -e, execFileSync, a
// try/catch around a collector — loses that answer and falls back to a default.
// When the default is the reassuring value the failure is invisible; that is how
// a tangled clone came to render as "On main" in the console.
//
// So every member of the family carries an additive `--json` form that exits 0
// whenever the question could be answered at all, and puts the answer in the
// object. The bare form keeps its exit codes for interactive and shell callers.
//
// This gate is STATIC: it pins the registry, the documented surface, and the
// coupling to tests/smoke.sh, which carries the behavioral proof (each --json
// form actually run against a fixture producing each legitimate answer).
//
// Run: node tests/check-answer-forms.js   (exit 0 = the family holds)

const fs = require('fs')
const path = require('path')

const ROOT = path.join(__dirname, '..')
const BIN = path.join(ROOT, 'bin')
const SMOKE = path.join(ROOT, 'tests', 'smoke.sh')

// The family. `answers` is the full set of legitimate answers the --json form
// must exit 0 for — smoke.sh drives a fixture for each. Adding a subcommand
// whose nonzero exit means "the answer is no" means adding it here.
const FAMILY = [
  { script: 'dm-worktree.sh', sub: 'tangle', field: 'tangled', answers: ['true', 'false'] },
  { script: 'dm-worktree.sh', sub: 'landed', field: 'state', answers: ['landed', 'unlanded', 'undetermined'] },
  { script: 'dm-pr.sh', sub: 'security-scan', field: 'surface', answers: ['true', 'false'] },
  { script: 'dm-verify.sh', sub: 'gate', field: 'decision', answers: ['required', 'not-applicable', 'undetermined', 'unavailable'] },
]

// Subcommands whose header documents an exit code that is NOT an answer: nonzero
// there means the operation failed or the news is genuinely bad, so a caller
// treating it as failure is already correct. Each needs a stated reason, so the
// drift scan below cannot be silenced by adding a bare name.
const NOT_ANSWER_CARRYING = [
  { script: 'dm-backlog.sh', sub: 'validate', why: 'nonzero = the backlog file does not parse, a real failure' },
  { script: 'dm-doctor.sh', sub: null, why: 'nonzero = a required tool is missing; check --json already carries the verdict' },
  { script: 'dm-lavish.sh', sub: null, why: 'prose about a callers exit handling, not a subcommand contract' },
  { script: 'dm-task.sh', sub: 'sizing', why: 'exit 3 = a record disagrees with what its crewmate ran, a refusal to certify' },
  { script: 'dm-test.sh', sub: null, why: 'nonzero = the test suite failed or was misused, genuinely bad news' },
  { script: 'dm-ui.sh', sub: 'poll', why: 'exit 3 = timed out with no operator message; an ABSENT answer, not a negative one' },
  { script: 'dm-verify.sh', sub: 'report', why: 'nonzero = a flow failed or nothing was recorded, never a pass' },
]

// A header line that documents what an exit code MEANS. This is what makes a
// subcommand suspect: it is telling its caller to read $? for content.
const EXIT_DOC = /\bexits?\s+\d|\bexit\s+\d+\s*=/i
// A header entry line: `#   <name>` followed by an argument placeholder or the
// description column. That trailing shape is what distinguishes an entry from a
// prose line, which continues with a single space after its first word.
const ENTRY = /^#\s{2,}([a-z][a-z0-9-]*)(?:\s+[<[]|\s{2,}\S|\s*$)/

function headerLines(file) {
  const lines = fs.readFileSync(file, 'utf8').split('\n')
  const header = []
  for (const line of lines) {
    if (line.startsWith('#!')) continue
    if (!line.startsWith('#')) break
    header.push(line)
  }
  return header
}

// Attribute each exit-documenting header line to the nearest entry above it, or
// to the file itself when the line is free prose.
function exitDocumentedSubs(file) {
  const found = new Map()
  let current = null
  for (const line of headerLines(file)) {
    const entry = ENTRY.exec(line)
    if (entry) current = entry[1]
    // A blank comment line ends an entry's continuation block, so following
    // prose is not misattributed to the last subcommand documented.
    else if (/^#\s*$/.test(line)) current = null
    if (EXIT_DOC.test(line) && !found.has(current)) found.set(current, line.trim())
  }
  return found
}

function fail(problems, message) {
  problems.push(message)
}

// smoke.sh shortens hot paths into a variable (`V="$ROOT/bin/dm-verify.sh"`).
// Expand those back to the script name so the coupling check below sees the
// command a reader sees, not the alias.
function smokeWithScriptAliasesExpanded() {
  let text = fs.readFileSync(SMOKE, 'utf8')
  const alias = /^([A-Za-z_][A-Za-z0-9_]*)="\$ROOT\/bin\/(dm-[a-z-]+\.sh)"$/gm
  const bindings = []
  for (const [, name, script] of text.matchAll(alias)) bindings.push([name, script])
  for (const [name, script] of bindings) {
    text = text.split(`"$${name}"`).join(script)
  }
  return text
}

function checkRegisteredMembers(problems) {
  const smoke = smokeWithScriptAliasesExpanded()
  for (const m of FAMILY) {
    const file = path.join(BIN, m.script)
    if (!fs.existsSync(file)) { fail(problems, `${m.script}: registered in the family but missing from bin/`); continue }
    const source = fs.readFileSync(file, 'utf8')

    // The header must offer the machine-readable form where a reader looks for it.
    const documented = headerLines(file).some((line) => ENTRY.test(line)
      && ENTRY.exec(line)[1] === m.sub && line.includes('[--json]'))
    if (!documented) fail(problems, `${m.script} ${m.sub}: header does not document a [--json] form`)

    // ...and the arg parser must actually offer it. The usage string is written
    // by the same parser that accepts the flag, so it cannot drift from it.
    if (!source.includes(`usage: ${m.script} ${m.sub} `) || !new RegExp(`usage: ${m.script} ${m.sub} [^\\n"]*\\[--json\\]`).test(source)) {
      fail(problems, `${m.script} ${m.sub}: no usage string offering [--json]; the flag is undocumented or unparsed`)
    }

    // smoke.sh holds the behavioral proof: the form actually run, and every
    // legitimate answer observed exiting 0.
    if (!new RegExp(`${m.script}[^\\n]*\\b${m.sub}\\b[^\\n]*--json`).test(smoke)) {
      fail(problems, `${m.script} ${m.sub} --json: tests/smoke.sh never runs it`)
    }
    // Match the ASSERTION, not the check's label: the answer must appear as a
    // quoted literal on a line that also reads the field out of the object, or a
    // prose description alone would satisfy this and pin nothing.
    for (const answer of m.answers) {
      const asserted = new RegExp(`\\.${m.field}"[^\\n]*"${answer.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`)
      if (!asserted.test(smoke)) {
        fail(problems, `${m.script} ${m.sub} --json: tests/smoke.sh does not assert the "${m.field}" answer "${answer}" off the object`)
      }
    }
  }
}

// The drift guard: a NEW subcommand that documents an exit-code meaning must be
// classified — either it joins the family (and gains a --json form) or it is
// recorded as genuinely failure-carrying, with a reason. Neither is automatic.
function checkNoUnclassifiedExitContracts(problems) {
  const known = new Set(
    FAMILY.map((m) => `${m.script} ${m.sub}`)
      .concat(NOT_ANSWER_CARRYING.map((m) => `${m.script} ${m.sub}`)),
  )
  for (const name of fs.readdirSync(BIN).sort()) {
    if (!name.endsWith('.sh')) continue
    for (const [sub, line] of exitDocumentedSubs(path.join(BIN, name))) {
      if (known.has(`${name} ${sub}`)) continue
      fail(problems, `${name} ${sub || '(file header)'}: documents an exit-code meaning but is in neither the answer-carrying family `
        + `nor the failure-carrying allowlist — classify it in tests/check-answer-forms.js.\n      ${line}`)
    }
  }
}

// This file guards nothing while nothing runs it, and it is the only pin on the
// family — deleting its CI step would silently retire the whole contract.
function checkSelfIsInvoked(problems) {
  const workflow = fs.readFileSync(path.join(ROOT, '.github', 'workflows', 'ci.yml'), 'utf8')
  if (!workflow.includes('run: node tests/check-answer-forms.js')) {
    fail(problems, 'CI does not invoke this check; without the step the answer-carrying family is unpinned')
  }
}

function main() {
  for (const m of NOT_ANSWER_CARRYING) {
    if (!m.why) throw new Error(`${m.script} ${m.sub}: an allowlist entry needs a stated reason`)
  }
  const problems = []
  checkRegisteredMembers(problems)
  checkNoUnclassifiedExitContracts(problems)
  checkSelfIsInvoked(problems)
  if (problems.length) {
    console.error('answer-carrying subcommand family FAILED:')
    for (const p of problems) console.error(`  - ${p}`)
    process.exit(1)
  }
  console.log(`ok   ${FAMILY.length} answer-carrying subcommands each offer --json, and no exit contract is unclassified`)
}

main()
