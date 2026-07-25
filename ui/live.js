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
//   1. A source that FAILS is never an empty panel. `repos` and `tasks` are
//      load-bearing, so losing either fails the whole collection - a console
//      that renders a confident, wrong fleet is worse than one that says it
//      could not read the fleet. Every other source degrades into `degraded[]`,
//      which the page shows.
//   2. Nothing is inferred past its evidence. A pipeline stage the work has not
//      reached is `ahead` (not "0% done"), and a stage whose state cannot be
//      determined is `unknown` - never quietly rendered as not-started.

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
    throw new Error(`${script} ${args.join(' ')} failed (${code}): ${detail || 'no output'}`);
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

// attempt(...) -> the value, or null with the reason recorded. For sources the
// console can survive without; the page names every one it lost.
async function attempt(degraded, source, fn) {
  try {
    return await fn();
  } catch (err) {
    degraded.push({ source, error: err.message });
    return null;
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
    gates: inGates && gates ? gates.map((g) => ({
      gate: g.gate,
      pass: g.pass,
      optional: g.optional,
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
  const repos = await runJson(bin, 'dm-repo.sh', ['list', '--json']);
  if (!Array.isArray(repos)) throw new TypeError('dm-repo.sh list --json did not emit an array');
  return Promise.all(repos.map(async (repo) => {
    // Both are per-repo shell-outs over a handful of repos, and both are the
    // owning script's answer - never a re-read of the clone from here.
    const branch = await attempt(degraded, `clone branch (${repo.name})`,
      async () => (await run(bin, 'dm-worktree.sh', ['tangle', repo.name])).trim());
    const memory = await attempt(degraded, `memory (${repo.name})`,
      () => run(bin, 'dm-memory.sh', ['recall', repo.name]));
    const lines = memoryNotes(memory);
    return {
      name: repo.name,
      authority: repo.authority,
      mode: repo.mode,
      branch: repo.branch,
      remote: repo.remote,
      test_cmd: repo.test_cmd,
      // `tangle` prints nothing when the clone sits on its default branch.
      tangled: Boolean(branch),
      tangle_note: branch || '',
      notes: lines.slice(0, MEMORY_LINES),
      notes_hidden: Math.max(0, lines.length - MEMORY_LINES),
    };
  }));
}

async function collectTasks(bin) {
  const tasks = await runJson(bin, 'dm-task.sh', ['list', '--json']);
  if (!Array.isArray(tasks)) throw new TypeError('dm-task.sh list --json did not emit an array');
  return tasks.map((task) => Object.assign({}, task, { state: STATE_WORDS[task.state] || 'unknown' }));
}

function withArtifacts(tasks, rendered) {
  const byId = new Map((rendered || []).map((r) => [r.id, r]));
  return tasks.map((task) => Object.assign({}, task, {
    has_review_artifact: byId.has(task.id),
    review_at: byId.has(task.id) ? byId.get(task.id).rendered_at : '',
  }));
}

async function collectPipelines(bin, repoNames, degraded) {
  const entries = await Promise.all(repoNames.map(async (name) => {
    const doc = await attempt(degraded, `gate track (${name})`,
      () => runJson(bin, 'dm-pr.sh', ['pipeline', name, '--json']));
    return doc && Array.isArray(doc.gates) ? [name, doc.gates] : null;
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
    title: row.title || '(title not read)',
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
    error: row.error || '',
  }));
}

function toDecisions(rows) {
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
  const bucket = (status) => (doc.items || [])
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
    title: titleOf.get(item.id) || item.id,
    repo: repoOf.get(item.id) || '',
    state: awaiting.has(item.id) ? 'awaiting' : 'archived',
    at: item.rendered_at || '',
    href: `/review/${encodeURIComponent(item.id)}/`,
  }));
}

function toHealth(doctor, tasks, worktrees) {
  const closed = new Set(tasks.filter((t) => t.state === 'done' || t.state === 'dropped').map((t) => t.id));
  const known = new Set(tasks.map((t) => t.id));
  const cleanup = [
    {
      label: 'Local copies of finished work',
      count: (worktrees || []).filter((w) => closed.has(w.id)).length,
      note: 'Safe to clear.',
    },
    {
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
  const [rendered, repos, rawTasks, backlog, decisionRows, worktrees, doctor] = await Promise.all([
    attempt(degraded, 'review pages', () => runJson(bin, 'dm-lavish.sh', ['list', '--json'])),
    collectRepos(bin, degraded),
    collectTasks(bin),
    attempt(degraded, 'backlog', () => runJson(bin, 'dm-backlog.sh', ['list', '--json'])),
    attempt(degraded, 'decisions', () => runJson(bin, 'dm-backlog.sh', ['decisions', '--json'])),
    attempt(degraded, 'local copies', () => runJson(bin, 'dm-worktree.sh', ['list', '--json'])),
    // dm-doctor exits nonzero when a required tool is missing - that is its
    // REPORT, not a failure to read it, so the verdict it printed still shows.
    attempt(degraded, 'health', async () => {
      try {
        return await runJson(bin, 'dm-doctor.sh', ['check', '--json']);
      } catch (err) {
        const body = String(err.message).match(/\{[\s\S]*\}/);
        if (body) return JSON.parse(body[0]);
        throw err;
      }
    }),
  ]);

  const tasks = withArtifacts(rawTasks, rendered);
  const openRepos = Array.from(new Set(
    tasks.filter((t) => OPEN_STATES.includes(t.state)).map((t) => t.repo).filter(Boolean),
  ));
  const pipelines = await collectPipelines(bin, openRepos, degraded);

  return {
    degraded,
    repos,
    work: toWork(tasks, pipelines),
    backlog: backlog ? toBacklog(backlog) : { in_flight: [], queued: [], done: [] },
    decisions: toDecisions(decisionRows || []),
    reviews: toReviews(rendered || [], tasks),
    health: toHealth(doctor, tasks, worktrees),
  };
}

// The expensive half: one GitHub round trip per open PR. Its own cache tier.
async function collectPullRequests(bin) {
  const degraded = [];
  const rows = await attempt(degraded, 'pull requests',
    () => runJson(bin, 'dm-pr.sh', ['sweep', '--json'], SWEEP_TIMEOUT_MS));
  return { rows: rows || [], degraded, reachable: rows !== null };
}

function buildDocument(local, sweep) {
  const prs = toPullRequests(sweep.rows, local.repos);
  const decisions = local.decisions;
  const needs = toNeedsYou(local.work, prs, decisions);
  const inFlight = local.work.filter((w) => OPEN_STATES.includes(w.state) && w.state !== 'queued').length;
  return {
    generated_at: new Date().toISOString(),
    source: 'live',
    degraded: local.degraded.concat(sweep.degraded),
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
  STATE_WORDS,
  QUIET_AFTER_HOURS,
};
