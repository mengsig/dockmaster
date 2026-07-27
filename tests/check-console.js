#!/usr/bin/env node
// tests/check-console.js - the console's two promises, pinned.
//
//   1. It never claims more than it knows. A stage with no evidence is `ahead`;
//      one whose task could not be reconciled is `unknown`; a gate that records
//      nothing is `unrecorded`. These are three different statements and the
//      document must keep them apart.
//   2. Nothing internal reaches the screen. Every machine token the collector
//      can emit has a word in the page's vocabulary, and the committed demo
//      fleet carries no real repo, org or user.
//
// Failure paths get the same treatment as the happy ones, because a failed
// source is both where a wrong-but-reassuring panel comes from and where
// internal phrasing actually surfaces.
//
// Pure functions and the committed fixture only - no server, no toolbelt, no
// network, so this runs anywhere the rest of the suite does.

const path = require('path')

const ROOT = process.env.DM_CHECK_ROOT ? path.resolve(process.env.DM_CHECK_ROOT) : path.join(__dirname, '..')
const live = require(path.join(ROOT, 'ui', 'live.js'))
const state = require(path.join(ROOT, 'ui', 'state.js'))

let checks = 0

function ok(condition, message) {
  checks += 1
  if (!condition) throw new Error(message)
}

function equal(actual, expected, message) {
  ok(actual === expected, `${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
}

// A task record as dm-task.sh list --json emits it, with only what a case needs.
function task(fields) {
  return Object.assign({
    id: 'demo', kind: 'ship', repo: 'demo', title: 'A change', mode: 'pipeline',
    created: '2026-01-01T00:00:00Z', state: 'in_progress', state_source: 'status-log',
    state_detail: '', last_event: 'working', last_event_at: '2026-01-01T01:00:00Z',
    pr: '', pr_state: '', checks: '', tests: '', tests_cmd: '', verify: '',
    branch: '', has_worktree: true, has_review_artifact: false,
  }, fields)
}

const stateOf = (track, key) => track.stages.find((s) => s.key === key).state

// --- 1. the track claims exactly what was recorded ---------------------------

function checkTrackShapes() {
  const shapes = [
    [{ kind: 'ship', mode: 'pipeline' }, ['dispatched', 'building', 'review', 'gates', 'pr', 'merged']],
    [{ kind: 'ship', mode: 'direct-pr' }, ['dispatched', 'building', 'review', 'pr', 'merged']],
    [{ kind: 'ship', mode: 'local-only' }, ['dispatched', 'building', 'review', 'landed']],
    [{ kind: 'scout', mode: 'pipeline' }, ['dispatched', 'investigating', 'report']],
  ]
  for (const [{ kind, mode }, expected] of shapes) {
    const keys = live.trackKeys(kind, mode)
    equal(keys.join(','), expected.join(','), `${kind}/${mode} track`)
  }
  console.log('ok   every delivery mode has its own track')
}

function checkNothingIsClaimedWithoutEvidence() {
  // Dispatched but nothing reported: everything past "building" is NOT REACHED,
  // and none of it may read as done.
  const fresh = live.buildTrack(task({ state: 'in_progress' }), null)
  equal(stateOf(fresh, 'dispatched'), 'done', 'a dispatched task has been picked up')
  equal(stateOf(fresh, 'building'), 'active', 'work in progress is building')
  for (const key of ['review', 'gates', 'pr', 'merged']) {
    equal(stateOf(fresh, key), 'ahead', `${key} is not yet reached`)
  }

  // An open PR is the LAST gate, so reaching it proves the track was walked.
  const open = live.buildTrack(task({ pr: 'https://example.test/pull/1', checks: 'passing' }), null)
  for (const key of ['building', 'review', 'gates']) {
    equal(stateOf(open, key), 'done', `${key} is behind an open PR`)
  }
  equal(stateOf(open, 'pr'), 'active', 'the PR is where it sits')
  equal(stateOf(open, 'merged'), 'ahead', 'an open PR has not merged')

  const merged = live.buildTrack(task({ pr: 'https://example.test/pull/1', pr_state: 'MERGED' }), null)
  equal(stateOf(merged, 'merged'), 'done', 'a merged PR finishes the track')

  const queued = live.buildTrack(task({ state: 'queued' }), null)
  equal(stateOf(queued, 'dispatched'), 'active', 'an unstarted task sits at the first stage')
  equal(stateOf(queued, 'building'), 'ahead', 'an unstarted task is not building')
  console.log('ok   a stage is done or active only on recorded evidence')
}

function checkUndeterminableIsNotNotStarted() {
  // The operator's rule: when the state could not be determined, the unproven
  // stages must NOT read as "not yet" - that is a claim we cannot make either.
  const lost = live.buildTrack(task({
    state: 'in_progress',
    state_detail: 'could not determine whether its work landed (repo unresolvable)',
  }), null)
  for (const key of ['review', 'gates', 'pr', 'merged']) {
    equal(stateOf(lost, key), 'unknown', `${key} is unknown, not "not yet"`)
  }
  ok(!lost.stages.some((s) => s.state === 'ahead'), 'an undeterminable task claims no position at all')

  const known = live.buildTrack(task({ state: 'in_progress' }), null)
  ok(known.stages.some((s) => s.state === 'ahead'), '"not yet" is still used when the state IS known')
  ok(!known.stages.some((s) => s.state === 'unknown'), 'a reconciled task has no unknown stages')
  console.log('ok   undeterminable is a different claim from not-yet-reached')
}

function checkGatesAreAPlanNotProgress() {
  const declared = [
    { gate: 'review', pass: 'coldstart', optional: false, note: 'fresh independent read of the diff against base' },
    { gate: 'tests', pass: '', optional: false, note: 'must pass after coldstart fixes' },
    { gate: 'pr', pass: '', optional: false, note: 'open the PR with a short human description' },
  ]
  // The gate list shows only while the work is IN the gates.
  const inGates = live.buildTrack(task({ tests: 'pass', tests_cmd: 'npm test' }), declared)
  equal(stateOf(inGates, 'gates'), 'active', 'a recorded test result puts the work in the gates')
  equal(inGates.gates.length, 3, 'the declared gates are listed')
  equal(inGates.gates[0].state, 'unrecorded', 'a review gate records nothing and must say so')
  equal(inGates.gates[1].state, 'pass', 'the tests gate reports what it recorded')
  equal(inGates.gates.filter((g) => g.state !== 'unrecorded').length, 1,
    'only the one gate that recorded something claims anything')

  // The gate TOKENS must not cross at all: `review (coldstart)` and
  // `review (merge-gate)` are the crew's names for its own machine, and they
  // were being printed on the operator's In-flight panel verbatim.
  for (const gate of inGates.gates) {
    ok(!('gate' in gate) && !('pass' in gate), 'a gate token does not cross to the page')
    ok(typeof gate.note === 'string' && gate.note.length > 0, 'each gate crosses as the sentence written for it')
  }

  const unwritten = live.buildTrack(task({ tests: 'pass' }), [{ gate: 'review', pass: 'merge-gate' }])
  equal(unwritten.gates[0].note, '', 'a gate with no sentence written for it carries none, rather than its token')

  const notInGates = live.buildTrack(task({ state: 'in_progress' }), declared)
  equal(notInGates.gates.length, 0, 'work that has not reached the gates lists none')
  console.log('ok   the gate list is what must still be cleared, in words, never a progress claim')
}

// --- 2. nothing internal reaches the screen ----------------------------------

function checkReconcileProseNeverCrosses() {
  // dm-task.sh's detail names status lines and review artifacts. Only a blocker
  // a worker was asked to name is meant for the operator.
  const internal = [
    'reported ready but not yet landed: done: PR https://example.test/pull/9',
    'lavish artifact ready for the operator: review-ready: rendered',
    'committed work not yet landed',
    'not yet dispatched',
    'discard recorded but local copy still present',
  ]
  for (const detail of internal) {
    const note = live.progressNote(task({ state: 'in_progress', state_detail: detail }))
    equal(note.text, '', `no prose crosses for: ${detail}`)
    ok(note.kind === '' || ['unlanded', 'not_started', 'undeterminable'].includes(note.kind),
      `an internal detail becomes a token, not text: ${detail}`)
  }
  const blocked = live.progressNote(task({
    state: 'blocked',
    state_detail: 'blocked: the runner host needs its build user in the docker group',
  }))
  equal(blocked.kind, 'reported', 'a stopped task reports its blocker')
  equal(blocked.text, 'the runner host needs its build user in the docker group',
    'the verb prefix is stripped, the operator-facing half survives')
  console.log('ok   reconcile prose becomes a token; only a named blocker crosses as text')
}

function checkMemoryFramingIsNotShown() {
  const recall = [
    '== shared knowledge: demo (.dm-knowledge/ + AGENTS.md) ==',
    '(empty)',
    '== private notes: demo (/home/someone/dockmaster/repos/demo/.dm/notes.md) ==',
    '<!-- dockmaster private notes for demo - git-excluded, never committed -->',
    '- **[pitfall]** make install rewrites the lockfile under newer npm  _(2026-01-08T20:14:48Z)_',
    '- a note with no kind and no stamp',
  ].join('\n')
  const notes = live.memoryNotes(recall)
  equal(notes.length, 2, 'only the note bullets survive')
  equal(notes[0].kind, 'pitfall', 'the kind is lifted out of its markup')
  equal(notes[0].text, 'make install rewrites the lockfile under newer npm', 'the markup and stamp are stripped')
  equal(notes[0].at, '2026-01-08', 'the stamp becomes a date')
  equal(notes[1].kind, '', 'a bullet with no kind still shows')
  const rendered = JSON.stringify(notes)
  for (const leak of ['.dm-knowledge', 'notes.md', '<!--', '==', '**']) {
    ok(!rendered.includes(leak), `memory framing '${leak}' does not reach the page`)
  }
  console.log('ok   recalled memory shows its notes, not the file around them')
}

// --- 2b. a source that failed is named on the panel that lost it -------------

function checkAFailedSweepIsNeverAnEmptyFleet() {
  const local = {
    at: '2026-01-01T00:00:00Z',
    degraded: [], repos: [], work: [], reviews: [],
    backlog: { in_flight: [], queued: [], done: [] },
    decisions: { open: [], resolved: [] },
    health: { verdict: 'Ready', checks: [], cleanup: [] },
  }
  // The whole point: sabotaging the sweep used to produce open_prs: 0,
  // needs_you: [] and "Nothing is waiting to land" - a red PR, a
  // changes-requested PR and a merge-ready PR all vanishing into "All clear".
  const lostSweep = live.buildDocument(local, { rows: null, at: '' })
  equal(lostSweep.fleet.open_prs, 0, 'a failed sweep knows of no PRs')
  ok(lostSweep.degraded.some((d) => d.source === 'pull_requests' && d.panel === 'prs'),
    'a failed sweep is recorded against the panel that lost it')

  const emptySweep = live.buildDocument(local, { rows: [], at: '2026-01-01T00:00:00Z' })
  equal(emptySweep.degraded.length, 0, 'a sweep that read zero PRs is not a degradation')
  ok(lostSweep.degraded.length !== emptySweep.degraded.length,
    '"no open PRs" and "could not read the PRs" must not produce the same document')

  // Only those two are representable. Anything else would quietly become an
  // empty pull-request list, which is what the null signal exists to prevent.
  for (const bad of [{}, { rows: undefined }, null, { rows: 'none' }]) {
    let threw = false
    try { live.buildDocument(local, bad) } catch { threw = true }
    ok(threw, `a sweep reported as ${JSON.stringify(bad)} must fail, not read as an empty fleet`)
  }
  console.log('ok   a source that failed is a degradation, never an empty panel')
}

async function checkDegradationCarriesTokensNotProse() {
  const dom = await import(`file://${path.join(ROOT, 'ui', 'public', 'dom.mjs')}`)
  const views = await import(`file://${path.join(ROOT, 'ui', 'public', 'views.mjs')}`)
  const panels = new Set(views.VIEWS.map((v) => v.id))
  for (const [source, panel] of Object.entries(live.SOURCES)) {
    ok(source in dom.SOURCE_WORD, `source '${source}' has no word on the page`)
    ok(panels.has(panel), `source '${source}' points at panel '${panel}', which is not a view`)
  }
  // The needs-you queue is assembled from these two, so both must be able to
  // reach it - that is what makes an incomplete queue visible where it matters.
  for (const source of ['pull_requests', 'decisions']) {
    ok(['prs', 'decisions'].includes(live.SOURCES[source]),
      `'${source}' must land on a panel the needs-you view reads`)
  }
  const doc = live.buildDocument(
    { at: '2026-01-01T00:00:00Z', degraded: [{ source: 'backlog', panel: 'backlog', subject: '' }],
      repos: [], work: [], reviews: [],
      backlog: { in_flight: [], queued: [], done: [] }, decisions: { open: [], resolved: [] },
      health: { verdict: '', checks: [], cleanup: [] } },
    { rows: [], at: '2026-01-01T00:00:00Z' },
  )
  for (const row of doc.degraded) {
    ok(!('error' in row), 'a degradation carries no free text - stderr is not for the operator')
  }
  console.log(`ok   ${Object.keys(live.SOURCES).length} losable sources have a word and a panel`)
}

async function checkEveryTokenHasAWord() {
  const dom = await import(`file://${path.join(ROOT, 'ui', 'public', 'dom.mjs')}`)
  for (const token of Object.values(live.STATE_WORDS).concat(['unknown'])) {
    ok(token in dom.WORK_STATE, `work state '${token}' has no word on the page`)
  }
  const everyStage = new Set()
  for (const kind of ['ship', 'scout']) {
    for (const mode of ['pipeline', 'direct-pr', 'local-only']) {
      live.trackKeys(kind, mode).forEach((key) => everyStage.add(key))
    }
  }
  for (const key of everyStage) ok(key in dom.STAGE_LABEL, `track stage '${key}' has no label`)
  for (const claim of ['done', 'active', 'ahead', 'unknown']) {
    ok(claim in dom.STAGE_STATE, `stage claim '${claim}' has no word`)
  }
  ok(dom.STAGE_STATE.ahead !== dom.STAGE_STATE.unknown,
    '"not reached" and "not known" must not read as the same thing')
  // dm-pr.sh emits these two; a sentence from the sweep would be crew phrasing.
  for (const token of ['repo_missing', 'github_unreadable']) {
    ok(token in dom.PR_UNREADABLE, `unreadable pull request '${token}' has no word`)
  }
  // An unmapped token must NOT print itself - that is the whole seam.
  equal(dom.word(dom.WORK_STATE, 'some_new_state'), 'Not known', 'an unmapped token is not printed raw')
  equal(dom.lookup(dom.CHECKS, 'some_new_rollup')[1], 'Not known', 'an unmapped lamp label is not printed raw')
  console.log(`ok   ${everyStage.size} track stages and every work state have a word`)
}

// --- 2c. what the page asks for, and where a link goes -----------------------

// dom.mjs builds every element through document.createElement, so pinning the
// link rule needs just enough of a document to build one. Worth doing: the rule
// has to be inherited by a future panel, not remembered at each call site.
function withStubDocument(fn) {
  const had = 'document' in global
  const previous = global.document
  global.document = {
    createElement: (tag) => ({ tag, className: '', textContent: '', setAttribute() {}, appendChild() {} }),
  }
  try {
    return fn()
  } finally {
    if (had) global.document = previous
    else delete global.document
  }
}

async function checkEveryOutboundLinkOpensAway() {
  const dom = await import(`file://${path.join(ROOT, 'ui', 'public', 'dom.mjs')}`)
  withStubDocument(() => {
    // A pull request, an archived review page, the console's own origin, and the
    // review archive's Open control - which is a real link precisely so the tab
    // comes from the click itself, and 302s on to the annotatable session. All
    // of them LEAVE the panel the operator was reading, so none of them may take
    // the console's tab with it.
    for (const href of [
      'https://github.com/example-org/demo/pull/1',
      '/review/some-task/',
      'http://127.0.0.1:4877/review/some-task/',
      '/api/review-open?id=some-task&redirect=1',
    ]) {
      const node = dom.link(href, 'Open')
      equal(node.target, '_blank', `${href} opens in its own tab`)
      ok(/\bnoopener\b/.test(node.rel), `${href} carries noopener`)
      ok(/\bnoreferrer\b/.test(node.rel), `${href} carries noreferrer`)
    }
    // An in-page jump is navigation WITHIN the console; a tab per panel jump
    // would be the bug, not the convenience.
    const anchor = dom.link('#flight', 'See what is waiting')
    ok(!anchor.target, 'an in-page jump stays in this tab')
    ok(!anchor.rel, 'and needs no rel')
  })
  console.log('ok   every link that leaves the console opens in its own tab')
}

// A cleanup control ENQUEUES a request as an ordinary operator message, so the
// sentence is the operator's own words and the page owns it. A kind with no
// sentence would render a control that cannot say what it would ask for.
async function checkEveryCleanupKindHasARequest() {
  const dom = await import(`file://${path.join(ROOT, 'ui', 'public', 'dom.mjs')}`)
  for (const kind of live.CLEANUP_KINDS) {
    ok(typeof dom.CLEANUP_REQUEST[kind] === 'function', `cleanup kind '${kind}' has no request sentence`)
    const text = dom.CLEANUP_REQUEST[kind](3)
    ok(text.includes('3'), `the request for '${kind}' says how many`)
    ok(!/worktree|task id|\bmeta\b|dm-[a-z]+\.sh/i.test(text),
      `the request for '${kind}' uses the operator's words, not the crew's: ${text}`)
  }
  // The trash request names the work the way the operator sees it. A task id is
  // the one thing this seam exists to keep off the page, so it cannot be in here
  // either - the request goes into the transcript, which is on screen.
  const trash = dom.TRASH_REQUEST('Fix the login redirect', 'harbourmaster', 'In progress')
  ok(trash.includes('Fix the login redirect') && trash.includes('harbourmaster'),
    'a trash request names the work and its repo')
  ok(/authorize/i.test(trash), 'and carries the operator authorising it')
  console.log(`ok   ${live.CLEANUP_KINDS.length} cleanup kinds and the trash request are worded on the page`)
}

// The document deliberately carries NO task id, which is why the trash request
// names work by title and repo. If an id is ever added here it must be a decision,
// not a field that slipped through into a page the operator reads.
async function checkTheDocumentCarriesNoTaskId() {
  const doc = await state.collect('fixture')
  for (const item of doc.work) {
    ok(!('id' in item), 'a work row carries no task id')
  }
  for (const item of doc.needs_you) {
    ok(!('id' in item), 'a needs-you row carries no task id')
  }
  console.log('ok   no task id crosses to the page')
}

// --- 3. the committed demo fleet is a demo fleet ------------------------------

async function checkFixtureIsNeutral() {
  const doc = await state.collect('fixture')
  equal(doc.source, 'fixture', 'the fixture declares itself')
  ok(doc.needs_you.length > 0 && doc.work.length > 0 && doc.prs.length > 0, 'the demo fleet is populated')

  // The distro's tracked surface must not carry the operator's fleet: every
  // remote and PR url belongs to the demo org, and nothing else.
  const ORG = 'example-org'
  for (const repo of doc.repos) {
    ok(repo.remote.includes(`:${ORG}/`), `repo '${repo.name}' points at a real remote: ${repo.remote}`)
  }
  for (const pr of doc.prs) {
    ok(pr.url.startsWith(`https://github.com/${ORG}/`), `PR url is not the demo org: ${pr.url}`)
  }

  // It has to exercise the states a healthy real fleet does not show, or the
  // design gets worked on without them.
  const stages = doc.work.flatMap((w) => (w.track ? w.track.stages.map((s) => s.state) : []))
  for (const claim of ['done', 'active', 'ahead', 'unknown']) {
    ok(stages.includes(claim), `the demo fleet shows no '${claim}' stage`)
  }
  const workStates = new Set(doc.work.map((w) => w.state))
  for (const s of ['in_progress', 'ready_for_review', 'blocked', 'failed', 'paused', 'queued', 'done']) {
    ok(workStates.has(s), `the demo fleet has no '${s}' work`)
  }
  // A demo fleet may not claim it could not read something: the badge would be
  // the one thing on screen that was invented, and it shows permanently.
  equal(doc.degraded.length, 0, 'the demo fleet must not claim an unreadable source')
  ok(doc.prs.some((p) => p.unreadable === 'github_unreadable'),
    'the demo fleet must include a PR the sweep could not read')
  ok(doc.work.some((w) => w.track && w.track.gates.length > 0), 'the demo fleet must show the gate list')

  // Re-anchored onto now, so design work never happens against a year-old fleet.
  const newest = Math.max(...doc.work.map((w) => Date.parse(w.last_signal_at)))
  ok(Math.abs(Date.now() - newest) < 7 * 24 * 3600 * 1000, 'the demo fleet did not age onto now')
  console.log(`ok   the demo fleet is neutral, complete (${doc.work.length} items) and current`)
}

function checkShapeRefusesAHalfDocument() {
  const good = { source: 'live', generated_at: '2026-01-01T00:00:00Z', prs_read_at: '', fleet: { needs_you: 0 }, needs_you: [], work: [], prs: [], repos: [], reviews: [], degraded: [], backlog: {}, decisions: {}, health: {} }
  const refuses = (doc, why) => {
    let threw = false
    try { state.assertShape(doc, 'test') } catch { threw = true }
    ok(threw, why)
  }
  state.assertShape(good, 'test')
  refuses(Object.assign({}, good, { needs_you: [{}] }),
    'a count that disagrees with its list must fail, not render as "nothing needs you"')
  refuses({ fleet: {} }, 'a document missing panels must fail loudly')
  // The page words the demo banner off `source`; a document that does not
  // declare one would render a demo fleet as the operator's own.
  refuses(Object.assign({}, good, { source: '' }), 'a document with no source must fail')
  refuses(Object.assign({}, good, { source: 'demo' }), 'a document with an unknown source must fail')
  console.log('ok   a half-shaped or unattributed document is refused at the seam')
}

async function main() {
  checkTrackShapes()
  checkNothingIsClaimedWithoutEvidence()
  checkUndeterminableIsNotNotStarted()
  checkGatesAreAPlanNotProgress()
  checkReconcileProseNeverCrosses()
  checkMemoryFramingIsNotShown()
  checkAFailedSweepIsNeverAnEmptyFleet()
  await checkDegradationCarriesTokensNotProse()
  await checkEveryTokenHasAWord()
  await checkEveryOutboundLinkOpensAway()
  await checkEveryCleanupKindHasARequest()
  await checkTheDocumentCarriesNoTaskId()
  await checkFixtureIsNeutral()
  checkShapeRefusesAHalfDocument()
  console.log(`\nconsole checks passed (${checks} assertions)`)
}

main().catch((err) => { console.error(`\nFAIL ${err.message}`); process.exit(1) })
