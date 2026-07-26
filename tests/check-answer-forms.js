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
// This gate BUILDS ITS OWN FIXTURE and RUNS each form once per legitimate
// answer, asserting exit 0 and the value read off the object. It deliberately
// does not verify by reading tests/smoke.sh: a check that greps another file's
// source text is satisfied by text that never executes — comment the assertions
// out and the grep still matches — which is the vacuous shape this gate exists
// to prevent. smoke.sh keeps its own coverage of these forms inside the full
// lifecycle; this gate does not depend on it.
//
// Needs bash, git and jq on PATH — it runs the real bin/ scripts. A missing tool
// is a hard error, never a skip.
//
// Run: node tests/check-answer-forms.js   (exit 0 = the family holds)

const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawnSync } = require('child_process')

const ROOT = path.join(__dirname, '..')
const BIN = path.join(ROOT, 'bin')

// The family. `answers` is the full set of legitimate answers the --json form
// must exit 0 for; the driver below must observe EVERY one of them, so an answer
// listed here that no fixture produces fails the gate. Adding a subcommand whose
// nonzero exit means "the answer is no" means adding it here.
const FAMILY = [
  { script: 'dm-worktree.sh', sub: 'tangle', field: 'tangled', answers: ['true', 'false'] },
  { script: 'dm-worktree.sh', sub: 'landed', field: 'state', answers: ['landed', 'unlanded', 'undetermined'] },
  { script: 'dm-pr.sh', sub: 'security-scan', field: 'surface', answers: ['true', 'false'] },
  { script: 'dm-verify.sh', sub: 'gate', field: 'decision', answers: ['required', 'not-applicable', 'undetermined', 'unavailable'] },
]

// Subcommands whose header NAMES an exit code that is not an answer: nonzero
// there means the operation failed or the news is genuinely bad, so a caller
// treating it as failure is already correct. Each needs a stated reason, so the
// drift scan below cannot be silenced by adding a bare name.
const NOT_ANSWER_CARRYING = [
  { script: 'dm-backlog.sh', sub: 'validate', why: 'nonzero = the backlog file does not parse, a real failure' },
  { script: 'dm-command-guard.sh', sub: null, why: 'prose about how a PreToolUse hook fails open, not a subcommand contract' },
  { script: 'dm-doctor.sh', sub: null, why: 'nonzero = a required tool is missing; check --json already carries the verdict' },
  { script: 'dm-lavish.sh', sub: null, why: 'prose about a caller degrading, not a subcommand contract' },
  { script: 'dm-sync.sh', sub: null, why: 'prose stating an internal helper always returns 0 and answers on stdout' },
  { script: 'dm-task.sh', sub: 'sizing', why: 'exit 3 = a record disagrees with what its crewmate ran, a refusal to certify' },
  { script: 'dm-test.sh', sub: null, why: 'nonzero = the test suite failed or was misused, genuinely bad news' },
  { script: 'dm-ui.sh', sub: 'poll', why: 'exit 3 = timed out with no operator message; an ABSENT answer, not a negative one' },
  { script: 'dm-verify.sh', sub: 'report', why: 'nonzero = a flow failed or nothing was recorded, never a pass' },
]

// A header line NAMING an exit or return code — the suspect shape, because the
// header is telling a caller to read $? for content. It cannot catch prose that
// describes a code without naming one, so the FAMILY registry above is the
// contract and this scan is the reminder. Said the same way in toolbelt.md.
const EXIT_DOC = /\b(?:exits?|returns?)\s+(?:-?\d|non-?zero)|\bexit\s+\d+\s*=|\bnon-?zero\b/i
// A header entry line: `#   <name>` followed by an argument placeholder or the
// description column. That trailing shape is what distinguishes an entry from a
// prose line, which continues with a single space after its first word.
const ENTRY = /^#\s{2,}([a-z][a-z0-9-]*)(?:\s+[<[]|\s{2,}\S|\s*$)/

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

function fail(problems, message) {
  problems.push(message)
}

function headerLines(file) {
  const header = []
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (line.startsWith('#!')) continue
    if (!line.startsWith('#')) break
    header.push(line)
  }
  return header
}

// The dispatch branch for <sub>: its `  <sub>)` case label through the closing
// `    ;;`. Reading the branch rather than the whole file is what makes "this
// subcommand accepts --json" checkable instead of "the file mentions --json".
function dispatchBranch(source, sub) {
  const lines = source.split('\n')
  const label = new RegExp(`^\\s{2}${escapeRe(sub)}\\)\\s*$`)
  const start = lines.findIndex((line) => label.test(line))
  if (start === -1) return null
  for (let i = start + 1; i < lines.length; i++) {
    if (/^\s{4};;\s*$/.test(lines[i])) return lines.slice(start, i + 1).join('\n')
  }
  return null
}

// --- the declared surface ----------------------------------------------------

function checkDeclaredSurface(problems) {
  for (const m of FAMILY) {
    const file = path.join(BIN, m.script)
    if (!fs.existsSync(file)) { fail(problems, `${m.script}: registered in the family but missing from bin/`); continue }

    // The header must offer the machine-readable form where a reader looks for it.
    const documented = headerLines(file).some((line) => ENTRY.test(line)
      && ENTRY.exec(line)[1] === m.sub && line.includes('[--json]'))
    if (!documented) fail(problems, `${m.script} ${m.sub}: header does not document a [--json] form`)

    const branch = dispatchBranch(fs.readFileSync(file, 'utf8'), m.sub)
    if (!branch) {
      fail(problems, `${m.script} ${m.sub}: no dispatch branch found; the case label or its closing ;; moved`)
      continue
    }
    // The ACCEPT arm, not only the reject arm's usage text. Deleting `--json)`
    // and leaving the usage string intact is otherwise invisible here — the
    // driver below still catches it, but this names the cause directly.
    if (!/--json\)/.test(branch)) {
      fail(problems, `${m.script} ${m.sub}: the dispatch branch has no \`--json)\` arm, so the flag is not accepted`)
    }
    // The reject arm's usage text is what an operator sees on a typo; it must
    // not advertise a flag the accept arm no longer offers, or vice versa.
    if (!new RegExp(`usage: ${escapeRe(m.script)} ${escapeRe(m.sub)} [^\\n"]*\\[--json\\]`).test(branch)) {
      fail(problems, `${m.script} ${m.sub}: the dispatch branch's usage text does not offer [--json]`)
    }
  }
}

// The drift guard: a NEW subcommand whose header names an exit or return code
// must be classified — either it joins the family (and gains a --json form) or
// it is recorded as genuinely failure-carrying, with a reason. Returns how many
// header lines it classified, so the success line can state the scan's real
// reach rather than imply it catches every phrasing.
function checkNoUnclassifiedExitContracts(problems) {
  const known = new Set(
    FAMILY.map((m) => `${m.script} ${m.sub}`)
      .concat(NOT_ANSWER_CARRYING.map((m) => `${m.script} ${m.sub}`)),
  )
  let scanned = 0
  for (const name of fs.readdirSync(BIN).sort()) {
    if (!name.endsWith('.sh')) continue
    let current = null
    for (const line of headerLines(path.join(BIN, name))) {
      const entry = ENTRY.exec(line)
      if (entry) current = entry[1]
      // A blank comment line ends an entry's continuation block, so following
      // prose is not misattributed to the last subcommand documented.
      else if (/^#\s*$/.test(line)) current = null
      if (!EXIT_DOC.test(line)) continue
      scanned++
      if (known.has(`${name} ${current}`)) continue
      fail(problems, `${name} ${current || '(file header)'}: names an exit/return code but is in neither the `
        + `answer-carrying family nor the failure-carrying allowlist — classify it in tests/check-answer-forms.js.`
        + `\n      ${line.trim()}`)
    }
  }
  return scanned
}

// This file guards nothing while nothing runs it, and it is the only pin on the
// family — deleting its CI step would silently retire the whole contract.
function checkSelfIsInvoked(problems) {
  const workflow = fs.readFileSync(path.join(ROOT, '.github', 'workflows', 'ci.yml'), 'utf8')
  if (!workflow.includes('run: node tests/check-answer-forms.js')) {
    fail(problems, 'CI does not invoke this check; without the step the answer-carrying family is unpinned')
  }
}

// --- driving the real thing --------------------------------------------------

function makeRunner(home) {
  const env = Object.assign({}, process.env, {
    DM_HOME: home,
    // Local refs only: the fixture's origin is a path on disk, and `landed`
    // must not depend on a network for a deterministic answer.
    DM_NO_FETCH: '1',
    GIT_AUTHOR_NAME: 'answer forms', GIT_AUTHOR_EMAIL: 'forms@dockmaster.test',
    GIT_COMMITTER_NAME: 'answer forms', GIT_COMMITTER_EMAIL: 'forms@dockmaster.test',
  })
  return function run(cmd, args) {
    const res = spawnSync(cmd, args, { encoding: 'utf8', env })
    if (res.error) throw new Error(`${cmd} ${args.join(' ')}: ${res.error.message}`)
    return { rc: res.status, out: res.stdout || '', err: res.stderr || '' }
  }
}

// Every fixture step must succeed, or the answers driven off it prove nothing.
function must(run, cmd, args) {
  const res = run(cmd, args)
  if (res.rc !== 0) {
    throw new Error(`fixture step failed (rc ${res.rc}): ${cmd} ${args.join(' ')}\n${res.err || res.out}`)
  }
  return res
}

function buildFixture(run, root, home) {
  const origin = path.join(root, 'origin.git')
  const seed = path.join(root, 'seed')
  must(run, 'git', ['init', '-q', '--bare', '-b', 'main', origin])
  must(run, 'git', ['init', '-q', '-b', 'main', seed])
  fs.mkdirSync(path.join(seed, 'src'))
  fs.writeFileSync(path.join(seed, 'src', 'calc.py'), 'def add(a, b):\n    return a + b\n')
  must(run, 'git', ['-C', seed, 'add', '-A'])
  must(run, 'git', ['-C', seed, 'commit', '-qm', 'init'])
  must(run, 'git', ['-C', seed, 'remote', 'add', 'origin', origin])
  must(run, 'git', ['-C', seed, 'push', '-q', 'origin', 'main'])
  must(run, path.join(BIN, 'dm-repo.sh'), ['add', 'demo', origin, '--mode', 'local-only', '--no-memory'])
  return path.join(home, 'repos', 'demo')
}

// A task with its own worktree, optionally carrying files on its own branch.
function newTask(run, id, files, commit) {
  must(run, path.join(BIN, 'dm-task.sh'), ['new', id, '--kind', 'ship', '--repo', 'demo', '--mode', 'local-only'])
  const wt = must(run, path.join(BIN, 'dm-worktree.sh'), ['create', id, 'demo']).out.trim().split('\n').pop()
  if (!files) return wt
  must(run, 'git', ['-C', wt, 'checkout', '-q', '-b', `work/${id}`])
  for (const rel of Object.keys(files)) {
    fs.mkdirSync(path.join(wt, path.dirname(rel)), { recursive: true })
    fs.writeFileSync(path.join(wt, rel), files[rel])
  }
  if (commit) {
    must(run, 'git', ['-C', wt, 'add', '-A'])
    must(run, 'git', ['-C', wt, 'commit', '-qm', `work for ${id}`])
  }
  return wt
}

// One driven answer: the form must exit 0, print one JSON object, and carry the
// expected value in its answer field.
function expectAnswer(problems, observed, run, member, args, want, why) {
  const label = `${member.script} ${member.sub} --json (${why})`
  const res = run(path.join(BIN, member.script), args)
  if (res.rc !== 0) {
    fail(problems, `${label}: exited ${res.rc}; --json must exit 0 whenever the question could be answered`
      + `\n      ${(res.err || res.out).trim().split('\n')[0]}`)
    return
  }
  let doc
  try {
    doc = JSON.parse(res.out)
  } catch (err) {
    fail(problems, `${label}: did not print one JSON object (${err.message})`)
    return
  }
  if (String(doc[member.field]) !== want) {
    fail(problems, `${label}: expected ${member.field}="${want}", got ${JSON.stringify(doc[member.field])}`)
    return
  }
  observed[`${member.script} ${member.sub}`].push(want)
}

// A genuine failure must still exit nonzero in the --json form: the contract is
// "exit 0 when the question could be ANSWERED", not "exit 0 always".
function expectRefusal(problems, run, member, args, why) {
  const res = run(path.join(BIN, member.script), args)
  if (res.rc === 0) {
    fail(problems, `${member.script} ${member.sub} --json (${why}): exited 0 on a genuine failure; `
      + 'nonzero is reserved for exactly this')
  }
}

function requireTool(tool) {
  const probe = spawnSync(tool, ['--version'], { encoding: 'utf8' })
  if (probe.error || probe.status !== 0) {
    throw new Error(`${tool} is required to drive the --json forms; without it this gate proves nothing`)
  }
}

function driveFamily(problems) {
  // Hard requirements, never a skip: a gate that quietly stops driving the forms
  // when a tool is absent is green with no coverage, which is the failure this
  // whole file exists to prevent. bash because it runs the real bin/ scripts.
  requireTool('bash')
  requireTool('git')
  requireTool('jq')
  const root = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'dm-answer-forms-'))
  const home = path.join(root, 'home')
  const observed = {}
  for (const m of FAMILY) observed[`${m.script} ${m.sub}`] = []
  const run = makeRunner(home)
  const [tangle, landed, scan, gate] = FAMILY
  try {
    const clone = buildFixture(run, root, home)

    // tangle: the clone on its default branch, then on a side branch.
    expectAnswer(problems, observed, run, tangle, ['tangle', 'demo', '--json'], 'false', 'clone on its default branch')
    must(run, 'git', ['-C', clone, 'checkout', '-q', '-b', 'sidebranch'])
    expectAnswer(problems, observed, run, tangle, ['tangle', 'demo', '--json'], 'true', 'clone on a side branch')
    must(run, 'git', ['-C', clone, 'checkout', '-q', 'main'])

    // security-scan: an auth diff, then a pure-arithmetic one.
    newTask(run, 'af-auth', { 'src/auth.py': 'def login(password):\n    return authenticate(password)\n' }, true)
    newTask(run, 'af-plain', { 'src/mul.py': 'def mul(a, b):\n    return a * b\n' }, true)
    expectAnswer(problems, observed, run, scan, ['security-scan', 'af-auth', '--json'], 'true', 'auth diff')
    expectAnswer(problems, observed, run, scan, ['security-scan', 'af-plain', '--json'], 'false', 'arithmetic diff')

    // landed: committed work, then a worktree with nothing ahead of the base.
    expectAnswer(problems, observed, run, landed, ['landed', 'af-auth', '--json'], 'unlanded', 'committed, not merged')
    newTask(run, 'af-clean', null, false)
    expectAnswer(problems, observed, run, landed, ['landed', 'af-clean', '--json'], 'landed', 'nothing ahead of the base')

    // gate: docs-only, then a surface with no app config, then with one.
    const gateWt = newTask(run, 'af-gate', { 'docs/notes.md': 'note\n' }, false)
    expectAnswer(problems, observed, run, gate, ['gate', 'af-gate', '--json'], 'not-applicable', 'docs-only diff')
    fs.writeFileSync(path.join(gateWt, 'app.js'), 'console.log(1)\n')
    expectAnswer(problems, observed, run, gate, ['gate', 'af-gate', '--json'], 'unavailable', 'surface moved, no app config')
    must(run, path.join(BIN, 'dm-repo.sh'), ['set', 'demo', 'app_start_cmd', 'true'])
    expectAnswer(problems, observed, run, gate, ['gate', 'af-gate', '--json'], 'required', 'surface moved, app config present')

    // gate: a task with no worktree cannot be read at all.
    must(run, path.join(BIN, 'dm-task.sh'), ['new', 'af-nowt', '--kind', 'ship', '--repo', 'demo', '--mode', 'local-only'])
    expectAnswer(problems, observed, run, gate, ['gate', 'af-nowt', '--json'], 'undetermined', 'no worktree to read')

    // A genuine failure still exits nonzero, in the form that otherwise never does.
    expectRefusal(problems, run, gate, ['gate', 'af-missing', '--json'], 'unknown task')
    expectRefusal(problems, run, landed, ['landed', 'af-missing', '--json'], 'unknown task')
    expectRefusal(problems, run, landed, ['landed', 'af-auth', '--wat', '--json'], 'unknown flag')

    // Last, because it breaks the registry for everything after it: an
    // unresolvable repo is "could not determine", never "not landed".
    const registry = path.join(home, 'state', 'repos.json')
    fs.writeFileSync(registry, must(run, 'jq', ['del(.repos["demo"])', registry]).out)
    expectAnswer(problems, observed, run, landed, ['landed', 'af-auth', '--json'], 'undetermined', 'repo no longer resolves')
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }

  // Every declared answer must have been driven: a registry entry nobody
  // exercises is a claim, not a pin.
  for (const m of FAMILY) {
    const seen = observed[`${m.script} ${m.sub}`]
    for (const answer of m.answers) {
      if (seen.indexOf(answer) === -1) {
        fail(problems, `${m.script} ${m.sub} --json: the answer "${answer}" is declared but no fixture drove it`)
      }
    }
  }
  return FAMILY.reduce((n, m) => n + observed[`${m.script} ${m.sub}`].length, 0)
}

function main() {
  for (const m of NOT_ANSWER_CARRYING) {
    if (!m.why) throw new Error(`${m.script} ${m.sub}: an allowlist entry needs a stated reason`)
  }
  const problems = []
  checkDeclaredSurface(problems)
  const scanned = checkNoUnclassifiedExitContracts(problems)
  checkSelfIsInvoked(problems)
  const driven = driveFamily(problems)
  if (problems.length) {
    console.error('answer-carrying subcommand family FAILED:')
    for (const p of problems) console.error(`  - ${p}`)
    process.exit(1)
  }
  console.log(`ok   ${FAMILY.length} answer-carrying subcommands answered ${driven} driven case(s) at exit 0; `
    + `${scanned} bin/ header line(s) naming an exit/return code are classified`)
}

main()
