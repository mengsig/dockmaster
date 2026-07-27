// live.js - fills the console document from the real fleet.
//
// It reads state EXACTLY ONE WAY: by running a dm-* script and parsing the JSON
// that script chose to emit. Nothing here opens state/repos.json,
// state/tasks/*.meta, state/backlog.json, or any other on-disk format, and
// nothing re-derives one. Those scripts own their formats; a second parser here
// would be a second thing to keep in sync, and it would drift.
//
// Two honesty rules shape the whole file:
//
//   1. A source that FAILS is never an empty panel. `repos` and `work` are
//      load-bearing, so losing either fails the whole collection - a console
//      that renders a confident, wrong fleet is worse than one that says it
//      could not read the fleet. Every other source degrades into `degraded[]`
//      carrying the PANEL that lost it, so the failure is stated where the
//      operator is looking rather than on a screen they are not on.
//   2. Nothing is inferred past its evidence. A pipeline stage the work has not
//      reached is `ahead` (not "0% done"), and a stage whose state cannot be
//      determined is `unknown` - never quietly rendered as not-started.
//
// Nothing that crosses to the page is free text from a script. A failure
// crosses as a SOURCE TOKEN; the script name, its argv and its stderr go to
// this process's log, which is where they are actually diagnosed.

'use strict';

const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

// Async, never execFileSync: reconciling 90 tasks and sweeping every open PR
// takes seconds to minutes, and a synchronous child would freeze the chat
// long-poll and every other request for exactly that long.
const execFileAsync = promisify(execFile);

// A local script; the PR sweep is a network walk over every open PR and needs
// its own budget.
const SCRIPT_TIMEOUT_MS = 30000;
const SWEEP_TIMEOUT_MS = 180000;
const MAX_OUTPUT_BYTES = 32 * 1024 * 1024;
// Recalled memory can run to hundreds of lines; the panel shows a head and says
// how much it is not showing, rather than silently truncating.
const MEMORY_LINES = 14;
// Matches dm-status.sh's long-runner threshold: past this with no new signal,
// in-progress work is reported as quiet rather than moving.
const QUIET_AFTER_HOURS = 4;

// Every kind of cleanup request the page can send. The page owns the REQUEST
// sentence for each one, the way it owns every other word the operator reads;
// tests/check-console.js pins that none of them is missing a sentence. The
// first two are rows this collector emits under `state.health.cleanup`, keyed
// positionally below; `landed_backlog` is issued straight from
// `state.backlog.done.length` in the view instead, but its sentence needs the
// same coverage, so it is listed here too.
const CLEANUP_KINDS = ['finished_copies', 'orphan_copies', 'landed_backlog'];

// The task states that still have a live track worth drawing.
const OPEN_STATES = [
  'in_progress', 'ready_for_review', 'queued', 'blocked', 'needs_decision', 'paused', 'failed', 'unknown',
];
const STATE_WORDS = {
  working: 'in_progress',
  'awaiting-review': 'ready_for_review',
  pending: 'queued',
  blocked: 'blocked',
  'needs-decision': 'needs_decision',
  paused: 'paused',
  failed: 'failed',
  done: 'done',
  discarded: 'dropped',
};

// --- running the toolbelt ----------------------------------------------------

async function run(bin, script, args, timeoutMs) {
  try {
    const { stdout } = await execFileAsync(`${bin}/${script}`, args, {
      encoding: 'utf8',
      timeout: timeoutMs || SCRIPT_TIMEOUT_MS,
      maxBuffer: MAX_OUTPUT_BYTES,
    });
    return stdout;
  } catch (err) {
    // The script's own stderr is the useful half of the message - it is written
    // to say precisely what refused. Keep it, bounded.
    const detail = String(err.stderr || err.message || '').trim().split('\n').slice(-3).join(' · ');
    const code = err.code === undefined ? 'no exit code' : `exit ${err.code}`;
    const wrapped = new Error(`${script} ${args.join(' ')} failed (${code}): ${detail || 'no output'}`);
    // Some scripts exit NONZERO to report their answer, and print that answer on
    // STDOUT (dm-doctor's verdict, dm-worktree's tangle report). Discarding it
    // here left those callers reconstructing it from the message text, which
    // never contained it - so the panel went blank in exactly the case it
    // existed to describe. Carried explicitly; only a caller that knows the
    // script's contract may use it.
    wrapped.stdout = typeof err.stdout === 'string' ? err.stdout : '';
    throw wrapped;
  }
}

async function runJson(bin, script, args, timeoutMs) {
  const out = await run(bin, script, args, timeoutMs);
  try {
    return JSON.parse(out);
  } catch (err) {
    throw new Error(`${script} ${args.join(' ')} did not emit JSON: ${err.message}`);
  }
}

// Every source the console can lose, and the PANEL that depends on it. The page
// words both from these tokens, so a panel whose source failed says so itself
// instead of rendering as empty with the explanation on another screen.
const SOURCES = {
  repos: 'repos',
  work: 'flight',
  gate_track: 'flight',
  pull_requests: 'prs',
  decisions: 'decisions',
  backlog: 'backlog',
  review_pages: 'reviews',
  clone_branch: 'repos',
  memory: 'repos',
  local_copies: 'health',
  health: 'health',
};

// The real reason - the script, its argv, its stderr - goes to this process's
// log and nowhere else. Only the token crosses to the page.
//
// Logged BEFORE the token is validated: an unknown token is a bug here, and
// throwing first would throw away the failure that was actually being reported.
function logLost(source, err, subject) {
  process.stderr.write(`console: ${source}${subject ? ` (${subject})` : ''}: ${err.message}\n`);
  if (!(source in SOURCES)) throw new RangeError(`console: '${source}' is not a known source`);
}

// attempt(...) -> the value, or null with the source recorded. For sources the
// console can survive without; the page names every one it lost. `subject` is a
// repo name where a source is read per repo - a repo name is the operator's own
// vocabulary and is the only free text that crosses here.
async function attempt(degraded, source, fn, subject) {
  try {
    return await fn();
  } catch (err) {
    logLost(source, err, subject);
    degraded.push({ source, panel: SOURCES[source], subject: subject || '' });
    return null;
  }
}

// A source the whole document is built on. Losing it fails the collection
// rather than rendering a fleet with a silent hole in it.
async function mustRead(source, fn) {
  try {
    return await fn();
  } catch (err) {
    logLost(source, err);
    const wrapped = new Error(`the console could not read ${source}`);
    wrapped.source = source;
    throw wrapped;
  }
}

// --- the pipeline track ------------------------------------------------------

function trackKeys(kind, mode) {
  if (kind === 'scout') return ['dispatched', 'investigating', 'report'];
  if (mode === 'local-only') return ['dispatched', 'building', 'review', 'landed'];
  if (mode === 'direct-pr') return ['dispatched', 'building', 'review', 'pr', 'merged'];
  return ['dispatched', 'building', 'review', 'gates', 'pr', 'merged'];
}

// What each stage is allowed to claim, given only what was actually recorded.
// `unproven` is the caller's verdict for "no evidence": `ahead` normally, but
// `unknown` once the task's own state could not be reconciled - at that point
// "not started yet" is a claim we cannot make either.
function stageState(key, task, unproven) {
  const merged = task.pr_state === 'MERGED' || task.state === 'done';
  const hasPr = Boolean(task.pr);
  const gateEvidence = Boolean(task.tests || task.verify);
  switch (key) {
    case 'dispatched':
      return task.state === 'queued' ? 'active' : 'done';
    case 'building':
    case 'investigating':
      if (merged || hasPr || task.has_review_artifact) return 'done';
      if (task.state === 'queued') return unproven;
      return 'active';
    case 'review':
      if (merged || hasPr) return 'done';
      if (task.state === 'ready_for_review') return 'active';
      return unproven;
    case 'gates':
      // An open PR is the last gate, so reaching it proves the track was walked.
      if (merged || hasPr) return 'done';
      if (gateEvidence) return 'active';
      return unproven;
    case 'pr':
      if (merged) return 'done';
      if (hasPr) return 'active';
      return unproven;
    case 'merged':
    case 'landed':
    case 'report':
      return merged ? 'done' : unproven;
    default:
      return 'unknown';
  }
}

// The one detail a stage is entitled to state, drawn from a recorded field.
// Machine tokens only - the page owns every word the operator reads.
function stageEvidence(key, task) {
  if (key === 'gates' && task.tests) return { kind: 'tests', value: task.tests, detail: task.tests_cmd || '' };
  if (key === 'pr' && task.checks) return { kind: 'checks', value: task.checks, detail: '' };
  if (key === 'review' && task.has_review_artifact) return { kind: 'artifact', value: 'ready', detail: '' };
  return null;
}

function buildTrack(task, gates) {
  // dm-task.sh says so itself when its reconcile could not settle the question;
  // past that point every unproven stage is unknown, not "not yet reached".
  const undeterminable = /could not determine/i.test(task.state_detail || '') || task.state === 'unknown';
  const unproven = undeterminable ? 'unknown' : 'ahead';
  const keys = trackKeys(task.kind, task.mode);
  const stages = keys.map((key) => ({
    key,
    state: stageState(key, task, unproven),
    evidence: stageEvidence(key, task),
  }));
  // The declared gate list is what this change must still CLEAR - a plan, never
  // a progress claim. Only `tests` leaves a record, so every other gate stays
  // explicitly unrecorded rather than being drawn as passed or failed.
  const inGates = stages.some((s) => s.key === 'gates' && s.state === 'active');
  return {
    mode: task.kind === 'scout' ? 'scout' : task.mode,
    stages,
    // `note` is the sentence the pipeline config already writes for each gate
    // ("fresh independent read of the diff against base"). The gate/pass TOKENS
    // do not cross: they put `review (coldstart)` and `review (merge-gate)` on
    // the operator's screen, which is the crew's vocabulary for its own machine.
    gates: inGates && gates ? gates.map((g) => ({
      note: g.note || '',
      optional: Boolean(g.optional),
      state: g.gate === 'tests' && task.tests ? task.tests : 'unrecorded',
    })) : [],
  };
}

// --- sources -----------------------------------------------------------------

// The memory store is plain markdown BY DESIGN - "no bespoke database: memory is
// markdown you can read, diff and edit by hand" - so taking its note bullets is
// DISPLAYING that store, not re-implementing an owned state format. The section
// banners, git-excluded file paths and HTML comments between them are framing
// for whoever edits the file; none of it is for this page.
const NOTE_LINE = /^-\s+(?:\*\*\[([a-z-]+)\]\*\*\s*)?(.*?)\s*(?:_\((\d{4}-\d{2}-\d{2})[^)]*\)_)?\s*$/;

function memoryNotes(text) {
  const notes = [];
  for (const line of String(text || '').split('\n')) {
    if (line.slice(0, 2) !== '- ') continue;
    const match = line.match(NOTE_LINE);
    if (!match || !match[2]) continue;
    notes.push({ kind: match[1] || '', text: match[2], at: match[3] || '' });
  }
  return notes;
}

async function collectRepos(bin, degraded) {
  const repos = await mustRead('repos', async () => {
    const rows = await runJson(bin, 'dm-repo.sh', ['list', '--json']);
    if (!Array.isArray(rows)) throw new TypeError('dm-repo.sh list --json did not emit an array');
    return rows;
  });
  return Promise.all(repos.map(async (repo) => {
    // Both are per-repo shell-outs over a handful of repos, and both are the
    // owning script's answer - never a re-read of the clone from here.
    // --json, because the human form EXITS 1 to report a tangle: read through
    // run() that is indistinguishable from the script failing, so a clone on a
    // side branch degraded instead of being reported, and the panel then said
    // "On main". The prose it prints also names a path and a git command.
    const tangle = await attempt(degraded, 'clone_branch', async () => {
      const doc = await runJson(bin, 'dm-worktree.sh', ['tangle', repo.name, '--json']);
      if (!doc || typeof doc.on !== 'string' || typeof doc.tangled !== 'boolean') {
        throw new TypeError('dm-worktree.sh tangle --json did not report a branch');
      }
      return doc;
    }, repo.name);
    // --crew: the same view a worker is given. The dockmaster-only store is
    // deliberately left out - it exists to be excluded from anything relayed,
    // and this page is served over a socket the operator is not the only thing
    // that can reach. The repos panel says so on screen.
    const memory = await attempt(degraded, 'memory',
      () => run(bin, 'dm-memory.sh', ['recall', repo.name, '--crew']), repo.name);
    const lines = memoryNotes(memory);
    return {
      name: repo.name,
      authority: repo.authority,
      mode: repo.mode,
      branch: repo.branch,
      remote: repo.remote,
      test_cmd: repo.test_cmd,
      // Three states, not two: on its branch, on another one, or NOT READ. The
      // third may not render as either of the first two.
      branch_read: tangle !== null,
      tangled: Boolean(tangle && tangle.tangled),
      on_branch: tangle ? tangle.on : '',
      notes: lines.slice(0, MEMORY_LINES),
      notes_hidden: Math.max(0, lines.length - MEMORY_LINES),
    };
  }));
}

async function collectTasks(bin) {
  return mustRead('work', async () => {
    const tasks = await runJson(bin, 'dm-task.sh', ['list', '--json']);
    if (!Array.isArray(tasks)) throw new TypeError('dm-task.sh list --json did not emit an array');
    return tasks.map((task) => Object.assign({}, task, { state: STATE_WORDS[task.state] || 'unknown' }));
  });
}

function withArtifacts(tasks, rendered) {
  const byId = new Map((rendered || []).map((r) => [r.id, r]));
  return tasks.map((task) => Object.assign({}, task, {
    has_review_artifact: byId.has(task.id),
    review_at: byId.has(task.id) ? byId.get(task.id).rendered_at : '',
  }));
}

// dm-doctor.sh exits NONZERO when a required tool is missing - that is its
// REPORT, not a failure to read it, and it prints the whole verdict on STDOUT
// with nothing on stderr. So the recovery has to read stdout: matching the
// error TEXT for a JSON body could never work, and the health panel went blank
// in precisely the case it exists to describe.
async function collectHealth(bin) {
  let raw;
  try {
    raw = await run(bin, 'dm-doctor.sh', ['check', '--json']);
  } catch (err) {
    if (!err.stdout || err.stdout.trim() === '') throw err;
    raw = err.stdout;
  }
  const doc = JSON.parse(raw);
  // The one collector that used to skip the shape check its siblings all make:
  // null, [] and {} each yielded an empty Tools table and no degraded row.
  if (doc === null || typeof doc !== 'object' || Array.isArray(doc)
    || typeof doc.verdict !== 'string' || !Array.isArray(doc.checks)) {
    throw new TypeError('dm-doctor.sh check --json did not emit a verdict and a checks array');
  }
  return doc;
}

async function collectPipelines(bin, repoNames, degraded) {
  const entries = await Promise.all(repoNames.map(async (name) => {
    const doc = await attempt(degraded, 'gate_track', async () => {
      const found = await runJson(bin, 'dm-pr.sh', ['pipeline', name, '--json']);
      if (!found || !Array.isArray(found.gates)) {
        throw new TypeError('dm-pr.sh pipeline --json did not emit a gates array');
      }
      return found;
    }, name);
    return doc ? [name, doc.gates] : null;
  }));
  return new Map(entries.filter(Boolean));
}

// --- assembling the panels ---------------------------------------------------

// The reconcile detail dm-task.sh prints is written FOR the dockmaster: it names
// status lines, local copies and review artifacts. So it never reaches the page
// as prose. It becomes a TOKEN the page words itself, and free text crosses only
// where the crewmate was required to name a concrete blocker - the one case that
// is genuinely for the operator to read and act on.
const REPORTED_STATES = ['blocked', 'needs_decision', 'failed', 'paused'];

function progressNote(task) {
  const detail = String(task.state_detail || '');
  if (REPORTED_STATES.includes(task.state)) {
    // The status line is "<verb>: <note>"; the note is the operator-facing half.
    const split = detail.indexOf(': ');
    return { kind: 'reported', text: (split >= 0 ? detail.slice(split + 2) : detail).trim() };
  }
  if (/could not determine/i.test(detail)) return { kind: 'undeterminable', text: '' };
  if (/not yet dispatched/i.test(detail)) return { kind: 'not_started', text: '' };
  if (/not yet landed/i.test(detail)) return { kind: 'unlanded', text: '' };
  return { kind: '', text: '' };
}

function toWork(tasks, pipelines) {
  return tasks.map((task) => {
    const note = progressNote(task);
    return {
      title: task.title || '(untitled)',
      repo: task.repo,
      kind: task.kind,
      state: task.state,
      since: task.created,
      last_signal_at: task.last_event_at || task.created,
      quiet_after_hours: QUIET_AFTER_HOURS,
      note_kind: note.kind,
      note: note.text,
      review_href: task.has_review_artifact ? `/review/${encodeURIComponent(task.id)}/` : '',
      track: OPEN_STATES.includes(task.state)
        ? buildTrack(task, pipelines.get(task.repo))
        : null,
    };
  });
}

function toPullRequests(rows, repos) {
  const authorityOf = new Map(repos.map((r) => [r.name, r.authority]));
  return rows.map((row) => ({
    title: row.title || '',
    repo: row.repo,
    url: row.url,
    checks: row.checks || 'unknown',
    review: row.review || 'unknown',
    state: row.state || 'unknown',
    // `never` means the dockmaster is refused at the toolbelt, so the PR is the
    // operator's to land - the single most load-bearing fact on that panel.
    authority: row.authority || authorityOf.get(row.repo) || 'invalid',
    opened_at: row.created_at || '',
    cached: Boolean(row.offline),
    // A token from dm-pr.sh, worded by the page: a swept PR that could not be
    // read stays in the list, because one that drops out reads as a fleet with
    // fewer problems than it has.
    unreadable: row.unreadable || '',
  }));
}

function toDecisions(rows) {
  if (!Array.isArray(rows)) throw new TypeError('dm-backlog.sh decisions --json did not emit an array');
  const open = [];
  const resolved = [];
  for (const row of rows) {
    const options = String(row.options || '').split('|').map((s) => s.trim()).filter(Boolean);
    // dm-backlog.sh writes one stamp, `ts`, on both hold and resolve - there is
    // no separate resolved-at. Do not invent the distinction here.
    const entry = {
      question: row.question,
      options,
      answer: row.answer || '',
      at: row.ts || '',
    };
    if (row.status === 'open') open.push(entry);
    else resolved.push(entry);
  }
  return { open, resolved };
}

function toBacklog(doc) {
  // Every sibling collector asserts its shape; without this one a backlog
  // document with no `items` yields three empty buckets and no degraded row -
  // an empty backlog and an unread one would look identical.
  if (!doc || !Array.isArray(doc.items)) {
    throw new TypeError('dm-backlog.sh list --json did not emit an items array');
  }
  const bucket = (status) => doc.items
    .filter((item) => item.status === status)
    .map((item) => ({
      title: item.title,
      repo: item.repo || '',
      blocked_by: (item.blocked_by || []).join(', '),
      note: item.note || '',
    }));
  return { in_flight: bucket('inflight'), queued: bucket('queued'), done: bucket('done') };
}

function toReviews(rendered, tasks) {
  const awaiting = new Set(tasks.filter((t) => t.state === 'ready_for_review').map((t) => t.id));
  const titleOf = new Map(tasks.map((t) => [t.id, t.title]));
  const repoOf = new Map(tasks.map((t) => [t.id, t.repo]));
  return rendered.map((item) => ({
    // A review page outlives the record behind it. When that record is gone the
    // title is EMPTY and the page says so - falling back to the id would print
    // the one thing this seam exists to keep off the screen.
    title: titleOf.get(item.id) || '',
    repo: repoOf.get(item.id) || '',
    state: awaiting.has(item.id) ? 'awaiting' : 'archived',
    at: item.rendered_at || '',
    href: `/review/${encodeURIComponent(item.id)}/`,
    // A real link, not a fetch: the tab this opens must come from the click's
    // own user activation, so the server 302s it straight to the session (or
    // to `href` above, when there is none) rather than the page choosing
    // between them after an async round trip.
    open_href: `/api/review-open?id=${encodeURIComponent(item.id)}&redirect=1`,
  }));
}

function toHealth(doctor, tasks, worktrees) {
  const closed = new Set(tasks.filter((t) => t.state === 'done' || t.state === 'dropped').map((t) => t.id));
  const known = new Set(tasks.map((t) => t.id));
  // `kind` is the token the page keys its cleanup REQUEST off - the sentence the
  // operator sends is written on the page, not here, like every other word they
  // read. The label and note stay free text: they are already written for them.
  const cleanup = [
    {
      kind: CLEANUP_KINDS[0],
      label: 'Local copies of finished work',
      count: (worktrees || []).filter((w) => closed.has(w.id)).length,
      note: 'Safe to clear.',
    },
    {
      kind: CLEANUP_KINDS[1],
      label: 'Local copies with no work behind them',
      count: (worktrees || []).filter((w) => !known.has(w.id) || !w.exists).length,
      note: 'Left over; nothing depends on them.',
    },
  ];
  if (!doctor) return { verdict: 'Not known', checks: [], cleanup };
  return {
    verdict: doctor.verdict || 'Not known',
    checks: (doctor.checks || []).map((c) => ({
      name: c.name,
      tier: c.tier,
      status: c.status,
      note: c.note,
    })),
    cleanup,
  };
}

// --- what needs the operator -------------------------------------------------
//
// The one panel that must never be wrong in the reassuring direction. Each entry
// is a thing that is STOPPED until the operator acts; anything merely in
// progress belongs on another panel.
function toNeedsYou(work, prs, decisions) {
  const items = [];
  const waiting = work.filter((w) => w.state === 'ready_for_review');
  if (waiting.length > 0) {
    // Aggregated on purpose: thirteen identical rows crowd out the four
    // genuinely different things below them.
    items.push({
      lamp: 'brass',
      kind: 'review',
      count: waiting.length,
      repos: Array.from(new Set(waiting.map((w) => w.repo))),
      // Points at the panel holding exactly THESE items. The review archive
      // counts rendered pages, which is a different (smaller) number - two
      // counts side by side that disagree read as a bug.
      href: waiting.length === 1 ? waiting[0].review_href : '#flight',
      at: waiting.map((w) => w.last_signal_at).sort()[0] || '',
    });
  }
  for (const decision of decisions.open) {
    items.push({ lamp: 'brass', kind: 'decision', question: decision.question, options: decision.options, at: decision.at });
  }
  for (const pr of prs) {
    if (pr.state !== 'OPEN') continue;
    if (pr.checks === 'failing') {
      items.push({ lamp: 'port', kind: 'pr_red', title: pr.title, repo: pr.repo, href: pr.url, at: pr.opened_at });
    } else if (pr.review === 'changes-requested') {
      items.push({ lamp: 'brass', kind: 'pr_changes', title: pr.title, repo: pr.repo, href: pr.url, at: pr.opened_at });
    } else if (pr.checks === 'passing' && pr.authority === 'never') {
      items.push({ lamp: 'starboard', kind: 'pr_yours', title: pr.title, repo: pr.repo, href: pr.url, at: pr.opened_at });
    }
  }
  for (const item of work) {
    if (item.state !== 'blocked' && item.state !== 'needs_decision' && item.state !== 'failed') continue;
    items.push({
      lamp: item.state === 'failed' ? 'port' : 'brass',
      kind: item.state,
      title: item.title,
      repo: item.repo,
      detail: item.note,
      at: item.last_signal_at,
    });
  }
  return items;
}

// --- entry points ------------------------------------------------------------

// The cheap half: local files and git only, no network. Safe to re-collect often.
// Independent sources run concurrently - the task reconcile alone walks every
// task, so doing it beside the others rather than after them is most of the wait.
async function collectLocal(bin) {
  const degraded = [];
  const [rendered, repos, rawTasks, backlog, decisions, worktrees, doctor] = await Promise.all([
    attempt(degraded, 'review_pages', async () => {
      const rows = await runJson(bin, 'dm-lavish.sh', ['list', '--json']);
      if (!Array.isArray(rows)) throw new TypeError('dm-lavish.sh list --json did not emit an array');
      return rows;
    }),
    collectRepos(bin, degraded),
    collectTasks(bin),
    // Each shape check sits INSIDE its attempt, so a malformed answer degrades
    // exactly like an unreadable one instead of throwing past the collector.
    attempt(degraded, 'backlog', async () => toBacklog(await runJson(bin, 'dm-backlog.sh', ['list', '--json']))),
    attempt(degraded, 'decisions', async () => toDecisions(await runJson(bin, 'dm-backlog.sh', ['decisions', '--json']))),
    attempt(degraded, 'local_copies', async () => {
      const rows = await runJson(bin, 'dm-worktree.sh', ['list', '--json']);
      if (!Array.isArray(rows)) throw new TypeError('dm-worktree.sh list --json did not emit an array');
      return rows;
    }),
    attempt(degraded, 'health', () => collectHealth(bin)),
  ]);

  const tasks = withArtifacts(rawTasks, rendered);
  const openRepos = Array.from(new Set(
    tasks.filter((t) => OPEN_STATES.includes(t.state)).map((t) => t.repo).filter(Boolean),
  ));
  const pipelines = await collectPipelines(bin, openRepos, degraded);

  return {
    // When this collection FINISHED, not when a later request formatted it. The
    // page says "as of 12:43" off this, and a cached collection can be up to a
    // TTL old - stamping at request time made every read claim to be current.
    at: new Date().toISOString(),
    degraded,
    repos,
    work: toWork(tasks, pipelines),
    backlog: backlog || { in_flight: [], queued: [], done: [] },
    decisions: decisions || { open: [], resolved: [] },
    reviews: toReviews(rendered || [], tasks),
    health: toHealth(doctor, tasks, worktrees),
  };
}

// The expensive half: one GitHub round trip per open PR. Its own cache tier, and
// it REJECTS rather than resolving empty - a resolved failure would be cached
// for the whole TTL and read as "no open pull requests" for that long.
async function collectPullRequests(bin) {
  const rows = await runJson(bin, 'dm-pr.sh', ['sweep', '--json'], SWEEP_TIMEOUT_MS);
  if (!Array.isArray(rows)) throw new TypeError('dm-pr.sh sweep --json did not emit an array');
  return { rows, at: new Date().toISOString() };
}

// buildDocument(local, sweep) - `sweep.rows === null` means the sweep could not
// be read. That is a DEGRADATION named on the pull-request and needs-you
// panels, never an empty list: "nothing is waiting to land" is exactly the
// reassuring lie this console must not tell.
function buildDocument(local, sweep) {
  // `null` and an array are the only two things this may be told. Anything else
  // - an absent field, an undefined - would quietly become an empty PR list,
  // which is the exact failure the null signal exists to prevent.
  if (!sweep || (sweep.rows !== null && !Array.isArray(sweep.rows))) {
    throw new TypeError('console: the sweep must report an array of pull requests, or null for unreadable');
  }
  const degraded = local.degraded.slice();
  if (sweep.rows === null) degraded.push({ source: 'pull_requests', panel: SOURCES.pull_requests, subject: '' });
  const prs = toPullRequests(sweep.rows || [], local.repos);
  const decisions = local.decisions;
  const needs = toNeedsYou(local.work, prs, decisions);
  const inFlight = local.work.filter((w) => OPEN_STATES.includes(w.state) && w.state !== 'queued').length;
  return {
    // Both halves carry their OWN age, because they are cached separately: the
    // sweep can be two and a half minutes older than everything else, and the
    // page must not present one time for both.
    generated_at: local.at,
    prs_read_at: sweep.at || '',
    source: 'live',
    degraded,
    fleet: {
      repos: local.repos.length,
      in_flight: inFlight,
      open_prs: prs.filter((p) => p.state === 'OPEN').length,
      needs_you: needs.length,
    },
    needs_you: needs,
    work: local.work,
    prs,
    repos: local.repos,
    backlog: local.backlog,
    decisions,
    reviews: local.reviews,
    health: local.health,
  };
}

// reviewDir(bin, id) -> the directory holding that task's review page, or null.
// The path is whatever dm-lavish.sh REPORTS for an id it already lists; the URL
// only ever selects a row by equality, so it cannot compose a path of its own.
async function reviewDir(bin, id) {
  const rows = await runJson(bin, 'dm-lavish.sh', ['list', '--json']);
  if (!Array.isArray(rows)) throw new TypeError('dm-lavish.sh list --json did not emit an array');
  const row = rows.find((r) => r.id === id);
  if (!row || typeof row.path !== 'string' || row.path.length === 0) return null;
  return { dir: row.path.replace(/\/[^/]*$/, ''), file: row.path };
}

// The line `dm-lavish.sh open <id>` prints when it actually opened a session:
//   session:
//     file: /path/to/change.html
//     url: "http://127.0.0.1:4387/session/<token>"
//     status: opened
const SESSION_URL = /url:\s*"(https?:\/\/[^"]+)"/;

// openReviewSession(bin, id) -> { url } for the annotatable lavish session, or
// { url: null } when lavish-axi is not installed, the id has no artifact, or
// the command failed for any other reason. Every one of those looks the same
// from here: this is a courtesy on top of the raw review page, so nothing it
// can fail at is treated as fatal - the caller falls back to the plain archive.
//
// --no-open: this call is SERVER-SIDE. The operator's own browser is the one
// that must show the session, via the tab the console opens; a second tab
// launched here, in whatever display the server process happens to have, is
// not that - it is a stray window nobody asked for on this machine.
async function openReviewSession(bin, id) {
  let stdout;
  try {
    stdout = await run(bin, 'dm-lavish.sh', ['open', id, '--no-open']);
  } catch (err) {
    return { url: null };
  }
  const match = SESSION_URL.exec(stdout);
  return { url: match ? match[1] : null };
}

module.exports = {
  collectLocal,
  collectPullRequests,
  buildDocument,
  buildTrack,
  stageState,
  trackKeys,
  progressNote,
  memoryNotes,
  reviewDir,
  openReviewSession,
  SOURCES,
  STATE_WORDS,
  QUIET_AFTER_HOURS,
  CLEANUP_KINDS,
};
