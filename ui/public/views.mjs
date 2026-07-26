/* views.mjs - one function per panel. Each takes the console document and returns
 * a fragment; none of them fetches, caches, or knows about the server.
 *
 * Every word here comes from dom.mjs's vocabulary maps. A machine token that
 * reached the screen would be a bug.
 */
'use strict';

import {
  el, add, lamp, stateCell, meta, link, table, cell, section, head, empty,
  plural, lookup, word, ago, hoursSince,
  WORK_STATE, CHECKS, REVIEW_VERDICT, AUTHORITY, KIND, CHECK_STATUS, MODE,
  STAGE_LABEL, STAGE_STATE, SOURCE_WORD, PR_UNREADABLE, TESTS_RESULT,
} from './dom.mjs';

// --- what this panel could not read ------------------------------------------

// A panel whose source failed says so IN THAT PANEL. Putting the explanation on
// the Health screen and leaving this one blank is how "all clear" gets rendered
// over a failed pull-request sweep.
//
// Called with no panels it reports everything lost, which is what Health shows.
function lostHere(state, ...panels) {
  const rows = panels.length === 0
    ? state.degraded
    : state.degraded.filter((d) => panels.includes(d.panel));
  if (rows.length === 0) return null;
  const box = el('div', 'failure');
  add(box, el('p', 'failure-head', rows.length === 1
    ? 'One thing here could not be read.'
    : `${rows.length} things here could not be read.`));
  for (const row of rows) {
    const what = word(SOURCE_WORD, row.source);
    add(box, el('p', 'failure-body', row.subject
      ? `Could not read ${what} — ${row.subject}.`
      : `Could not read ${what}.`));
  }
  add(box, el('p', 'failure-body',
    'What is shown is incomplete. Ask the dockmaster to look into it.'));
  return box;
}

const lostAny = (state, ...panels) => state.degraded.some((d) => panels.includes(d.panel));

// --- the track ---------------------------------------------------------------

// The stepper. The connecting line is drawn SOLID only as far as there is
// evidence and dashed beyond it, so the picture stops exactly where knowledge
// does - it never fills a bar toward a stage nothing has reported on.
function trackStrip(track) {
  const list = el('ol', 'track');
  for (const stage of track.stages) {
    const label = word(STAGE_LABEL, stage.key);
    const claim = word(STAGE_STATE, stage.state);
    const item = el('li', `step is-${stage.state}`);
    item.title = `${label} — ${claim}`;
    add(item,
      el('span', 'step-mark'),
      el('span', 'step-label', label),
      el('span', 'sr-only', `: ${claim}`));
    add(list, item);
  }
  return list;
}

function evidenceChip(stage) {
  const e = stage.evidence;
  if (!e) return null;
  if (e.kind === 'tests') {
    const chip = el('span', `chip${e.value === 'fail' ? ' chip-port' : ''}`, word(TESTS_RESULT, e.value));
    if (e.detail) chip.title = e.detail;
    return chip;
  }
  if (e.kind === 'checks') return el('span', 'chip', `Checks: ${lookup(CHECKS, e.value)[1]}`);
  if (e.kind === 'artifact') return el('span', 'chip', 'Review page rendered');
  return null;
}

// The declared gates this change must still clear. A PLAN, not progress: only
// the tests gate records anything, so every other one says so plainly rather
// than being drawn as passed.
function gateStrip(gates) {
  if (!gates || gates.length === 0) return null;
  const wrap = el('div', 'gates');
  add(wrap, el('span', 'eyebrow', 'Still to clear'));
  const list = el('ul', 'gate-list');
  for (const gate of gates) {
    // The sentence the pipeline writes for the gate, never its token. A gate
    // with nothing written for it says only what is true: it is not reported on.
    const known = gate.state !== 'unrecorded';
    const item = el('li', known ? 'gate-step' : 'gate-step is-unrecorded');
    add(item, el('span', 'gate-mark'));
    add(item, el('span', 'gate-note', gate.note || 'A step with nothing recorded about it.'));
    if (known) add(item, el('span', 'chip', word(TESTS_RESULT, gate.state)));
    if (gate.optional) add(item, el('span', 'chip chip-faint', 'only if needed'));
    add(list, item);
  }
  return add(wrap, list);
}

// The document carries a token for where a piece of work stands; the sentence is
// chosen here. Free text crosses only as `reported` - a blocker a worker was
// asked to name, which is written for the operator to act on.
const NOTE = {
  reported: (text) => text,
  undeterminable: () => 'Could not tell how far this got — its repo could not be read.',
  not_started: () => 'Not started yet.',
  unlanded: () => 'Committed, but not landed yet.',
};

function noteText(item) {
  const word = NOTE[item.note_kind];
  return word ? word(item.note) : '';
}

// "Is it moving?" answered from the only honest signal there is: how long since
// this piece of work last reported anything.
function movement(item) {
  if (item.state !== 'in_progress') return null;
  const quiet = hoursSince(item.last_signal_at);
  if (quiet === null) return null;
  if (quiet <= item.quiet_after_hours) {
    return add(el('span', 'moving'), lamp('starboard'), el('span', null, 'moving'));
  }
  return add(el('span', 'moving is-quiet'), lamp('neutral'),
    el('span', null, `quiet ${ago(item.last_signal_at).replace(' ago', '')}`));
}

function voyage(item) {
  const [lampKind, stateWord] = lookup(WORK_STATE, item.state);
  const card = el('article', 'voyage');
  const header = el('div', 'voyage-head');
  const left = el('div');
  add(left,
    meta(item.repo, word(KIND, item.kind), `started ${ago(item.since)}`),
    el('h3', 'voyage-title', item.title));
  add(header, left, add(el('div', 'voyage-state'), stateCell(lampKind, stateWord), movement(item)));
  add(card, header);

  if (item.track) {
    // The track has a floor width; a narrow deck scrolls it here rather than
    // letting the page scroll sideways.
    add(card, add(el('div', 'scroll scroll-track'), trackStrip(item.track)));
    const chips = item.track.stages.map(evidenceChip).filter(Boolean);
    if (chips.length) add(card, add(el('div', 'chips'), ...chips));
    add(card, gateStrip(item.track.gates));
  }
  const note = noteText(item);
  if (note) add(card, el('p', 'voyage-note', note));
  if (item.review_href) add(card, link(item.review_href, 'Open the review page', 'row-action'));
  return card;
}

// --- in flight ---------------------------------------------------------------

const CARD_GROUPS = [
  ['In progress', ['in_progress']],
  ['Ready for your review', ['ready_for_review']],
  ['Stopped', ['blocked', 'needs_decision', 'failed']],
  ['Paused', ['paused']],
];
const LEDGER_GROUPS = [
  ['Not started', ['queued']],
  ['Recently finished', ['done']],
  ['Dropped', ['dropped']],
];

export function viewInFlight(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('In flight',
    'Where each piece of work has actually got to. A hollow mark is a stage it has not reached, '
    + 'a dashed line is what nothing has reported on yet — neither is a claim that it is failing.'));
  add(frag, lostHere(state, 'flight'));

  const open = state.work.filter((w) => CARD_GROUPS.some(([, keys]) => keys.includes(w.state)));
  if (open.length === 0) {
    add(frag, empty('Nothing is under way.', 'The crew has no open work right now.'));
  }
  for (const [label, keys] of CARD_GROUPS) {
    const rows = state.work.filter((w) => keys.includes(w.state));
    if (rows.length === 0) continue;
    const node = section(`${label} · ${rows.length}`);
    const list = el('div', 'voyages');
    rows.forEach((row) => add(list, voyage(row)));
    add(frag, add(node, list));
  }
  for (const [label, keys] of LEDGER_GROUPS) {
    const rows = state.work.filter((w) => keys.includes(w.state));
    if (rows.length === 0) continue;
    const node = section(`${label} · ${rows.length}`);
    add(node, table(['What', 'Repo', 'Started', 'Waiting on'], rows, (w) => add(el('tr'),
      cell('cell-title', el('span', null, w.title)),
      cell('mono nowrap', el('span', null, w.repo)),
      cell('mono nowrap', el('span', null, ago(w.since))),
      cell(null, el('span', noteText(w) ? '' : 'mono mono-mute', noteText(w) || '—')))));
    add(frag, node);
  }
  return frag;
}

// --- needs you ---------------------------------------------------------------

// One renderer per kind. The document carries a token and the data; the sentence
// the operator reads is chosen here.
const NEEDS = {
  review: (item) => ({
    head: `${plural(item.count, 'change is', 'changes are')} waiting for your review`,
    detail: `In ${item.repos.join(', ')}.`,
    action: item.count === 1 ? 'Open the review page' : 'See what is waiting',
  }),
  decision: (item) => ({ head: item.question, detail: 'Only you can answer this.' }),
  pr_red: (item) => ({ head: item.title, detail: 'Checks are failing on this pull request.', action: 'Open on GitHub' }),
  pr_changes: (item) => ({ head: item.title, detail: 'A review asked for changes.', action: 'Open on GitHub' }),
  pr_yours: (item) => ({
    head: item.title,
    detail: 'Green and ready. This repo is yours to merge — the dockmaster never merges it.',
    action: 'Merge on GitHub',
  }),
  blocked: (item) => ({ head: item.title, detail: item.detail || 'Stopped, waiting on you.' }),
  needs_decision: (item) => ({ head: item.title, detail: item.detail || 'Waiting on a choice only you can make.' }),
  failed: (item) => ({ head: item.title, detail: item.detail || 'This did not complete.' }),
};

function berth(item, ctx) {
  // The fallback never prints `kind`: an unrecognised kind is a gap in NEEDS,
  // and its token is exactly the sort of word that must not reach the screen.
  const words = (NEEDS[item.kind]
    || ((i) => ({ head: i.title || 'Something is waiting on you', detail: i.detail || '' })))(item);
  const row = el('div', 'row');
  const body = el('div');
  const where = item.repo || (item.repos || []).join(', ');
  const when = item.at ? ago(item.at) : '';
  if (where || when) add(body, meta(where, when));
  add(body, el('p', 'row-head', words.head), el('p', 'row-detail', words.detail));
  if (item.options && item.options.length) {
    const choices = el('div', 'choices');
    // The answer goes into the composer rather than straight out: the operator
    // confirms or edits it, and the reply is an ordinary message.
    for (const option of item.options) {
      const button = el('button', 'btn choice', option);
      button.type = 'button';
      button.addEventListener('click', () => ctx.compose(`${item.question} — ${option}`));
      add(choices, button);
    }
    add(body, choices);
  }
  if (item.href && words.action) add(body, link(item.href, words.action, 'row-action'));
  return add(row, lamp(item.lamp), body);
}

// This queue is assembled from the work, the pull-request sweep and the open
// decisions. Losing either of the last two makes it INCOMPLETE, and an
// incomplete queue may never render as "All clear" - a red pull request and a
// merge-ready one both disappear into the same reassuring sentence.
export function viewNeedsYou(state, ctx) {
  const frag = document.createDocumentFragment();
  add(frag, head('Needs you', 'Everything below is stopped until you act. Nothing else is listed here.'));
  const lost = lostHere(state, 'prs', 'decisions');
  add(frag, lost);

  if (state.needs_you.length === 0) {
    add(frag, lost
      ? empty('Nothing else is waiting.', 'What could be read is clear — but this list is incomplete.')
      : empty('All clear.',
        `Nothing needs you right now. ${plural(state.fleet.in_flight, 'change is', 'changes are')} under way.`));
    return frag;
  }
  const hero = el('div', 'hero');
  add(hero, el('span', 'hero-figure', state.needs_you.length), el('span', 'hero-label', 'waiting on you'));
  add(frag, hero);
  const rows = el('div', 'rows');
  state.needs_you.forEach((item) => add(rows, berth(item, ctx)));
  return add(frag, rows);
}

// --- pull requests -----------------------------------------------------------

export function viewPullRequests(state) {
  const frag = document.createDocumentFragment();
  // This panel is read from GitHub on a much slower cycle than the rest of the
  // page, so it carries its own age rather than borrowing the header's.
  add(frag, head('Pull requests',
    'Every pull request the crew has open, and who is allowed to merge it.'
    + (state.prs_read_at ? ` Read from GitHub ${ago(state.prs_read_at)}.` : '')));
  const lost = lostHere(state, 'prs');
  add(frag, lost);
  if (state.prs.length === 0) {
    // "Nothing is waiting to land" is a claim about GitHub. It may only be made
    // when GitHub was actually read.
    if (!lost) add(frag, empty('No open pull requests.', 'Nothing is waiting to land.'));
    return frag;
  }
  // Merging sits second on purpose: who may land this is the column the
  // operator came for, so it must survive a narrow window.
  add(frag, table(['What', 'Merging', 'Checks', 'Review', 'Repo'], state.prs, (pr) => {
    const [checkLamp, checkLabel] = lookup(CHECKS, pr.checks);
    const yours = pr.authority === 'never';
    const title = cell('cell-title col-what');
    add(title, link(pr.url, pr.title || 'Title not read'), el('span', 'cell-sub link-url', pr.url));
    if (pr.unreadable) add(title, el('span', 'cell-sub cell-warn', word(PR_UNREADABLE, pr.unreadable)));
    else if (pr.cached) add(title, el('span', 'cell-sub', 'Last known — not re-read just now'));
    else if (pr.opened_at) add(title, el('span', 'cell-sub', `Opened ${ago(pr.opened_at)}`));
    return add(el('tr'),
      title,
      cell('nowrap', stateCell(yours ? 'brass' : 'neutral', word(AUTHORITY, pr.authority))),
      cell('nowrap', stateCell(checkLamp, checkLabel)),
      cell('nowrap', el('span', null, word(REVIEW_VERDICT, pr.review))),
      cell('mono nowrap', el('span', null, pr.repo)));
  }));
  return frag;
}

// --- decisions ---------------------------------------------------------------

export function viewDecisions(state, ctx) {
  const frag = document.createDocumentFragment();
  add(frag, head('Decisions', 'Questions only you can answer. They stay open until you do.'));
  const lost = lostHere(state, 'decisions');
  add(frag, lost);

  const open = section(`Open · ${state.decisions.open.length}`);
  if (state.decisions.open.length === 0) {
    if (!lost) add(open, empty('Nothing is waiting on you.', 'Every question the crew raised has an answer.'));
  } else {
    const rows = el('div', 'rows');
    for (const decision of state.decisions.open) {
      add(rows, berth({
        lamp: 'brass', kind: 'decision', question: decision.question,
        options: decision.options, at: decision.at,
      }, ctx));
    }
    add(open, rows);
  }
  add(frag, open);

  const done = section(`Answered · ${state.decisions.resolved.length}`);
  if (state.decisions.resolved.length === 0) {
    add(done, el('p', 'empty-note', 'Nothing answered yet.'));
  } else {
    add(done, table(['Question', 'Your answer', 'When'], state.decisions.resolved, (d) => add(el('tr'),
      cell('cell-title', el('span', null, d.question)),
      cell(null, el('span', null, d.answer || '—')),
      cell('mono nowrap', el('span', null, ago(d.at))))));
  }
  return add(frag, done);
}

// --- backlog -----------------------------------------------------------------

export function viewBacklog(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('Backlog', 'What the crew is on, what is next, and what has landed.'));
  add(frag, lostHere(state, 'backlog'));
  const groups = [
    ['Under way', state.backlog.in_flight],
    ['Queued', state.backlog.queued],
    ['Landed', state.backlog.done],
  ];
  for (const [label, rows] of groups) {
    const node = section(`${label} · ${rows.length}`);
    if (rows.length === 0) {
      add(node, el('p', 'empty-note', 'Nothing here.'));
    } else {
      add(node, table(['What', 'Repo', 'Waiting on'], rows, (item) => add(el('tr'),
        cell('cell-title', el('span', null, item.title)),
        cell('mono nowrap', el('span', null, item.repo || '—')),
        cell(null, el('span', item.blocked_by ? '' : 'mono mono-mute', item.blocked_by || '—')))));
    }
    add(frag, node);
  }
  return frag;
}

// --- repos -------------------------------------------------------------------

// One repo is one entity, not a one-row table: a key/value block reads calmer
// and does not repeat a header per repo.
function repoBlock(repo) {
  const node = el('section', 'repo');
  const header = el('div', 'repo-head');
  // Not read is its own answer. Rendering it as "On main" was a claim about a
  // clone nothing had looked at.
  let branch = stateCell('neutral', 'Branch not read');
  if (repo.branch_read) {
    branch = repo.tangled
      ? stateCell('brass', `Left on ${repo.on_branch}, not ${repo.branch}`)
      : stateCell('starboard', `On ${repo.on_branch || repo.branch}`);
  }
  add(header, el('span', 'repo-name', repo.name), branch);
  add(node, header);

  const facts = el('dl', 'facts');
  [
    ['Merging', word(AUTHORITY, repo.authority), false],
    ['How work lands', word(MODE, repo.mode), false],
    ['Tests', repo.test_cmd || 'none registered', true],
    ['Remote', repo.remote, true],
  ].forEach(([term, value, isMono]) => {
    add(facts, el('dt', 'eyebrow', term), el('dd', isMono ? 'mono' : null, value));
  });
  add(node, facts);

  if (repo.notes && repo.notes.length) {
    add(node, el('span', 'eyebrow', 'What the dockmaster remembers'));
    const box = el('div', 'notes');
    for (const note of repo.notes) {
      const line = el('p', 'note-line');
      if (note.kind) add(line, el('span', 'note-kind', note.kind));
      add(line, el('span', null, note.text));
      if (note.at) add(line, el('span', 'note-at', note.at));
      add(box, line);
    }
    add(node, box);
    if (repo.notes_hidden > 0) {
      add(node, el('p', 'empty-note', `${repo.notes_hidden} more not shown.`));
    }
  }
  return node;
}

export function viewRepos(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('Repos',
    'What the dockmaster manages, how work lands, and what it has learned about each one. '
    + 'Notes here are the ones it shares with the crew; anything it keeps to itself stays off this page.'));
  add(frag, lostHere(state, 'repos'));
  state.repos.forEach((repo) => add(frag, repoBlock(repo)));
  return frag;
}

// --- reviews -----------------------------------------------------------------

export function viewReviews(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('Reviews', 'Every review page the crew has produced. They stay openable after the work lands.'));
  const lost = lostHere(state, 'reviews');
  add(frag, lost);
  if (state.reviews.length === 0) {
    if (!lost) add(frag, empty('No review pages yet.', 'One appears here each time a change is ready for you.'));
    return frag;
  }
  add(frag, table(['What', 'Repo', 'State', 'Rendered', ''], state.reviews, (r) => {
    const awaiting = r.state === 'awaiting';
    return add(el('tr'),
      // A review page outlives the record that named it; when that is gone the
      // page says the title is not recorded rather than printing an internal id.
      cell('cell-title', el('span', r.title ? null : 'mono mono-mute', r.title || 'Title not recorded')),
      cell('mono nowrap', el('span', null, r.repo || '—')),
      cell('nowrap', stateCell(awaiting ? 'brass' : 'neutral', awaiting ? 'Waiting for you' : 'Reviewed')),
      cell('mono nowrap', el('span', null, ago(r.at))),
      cell('nowrap', link(r.href, 'Open')));
  }));
  return frag;
}

// --- health ------------------------------------------------------------------

export function viewHealth(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('Health', 'Whether the dockmaster can do its job, and what it would like to tidy up.'));

  const hero = el('div', 'hero');
  add(hero, el('span', 'hero-figure', state.health.verdict), el('span', 'hero-label', 'to take on work'));
  add(frag, hero);

  // Health is the one panel that lists everything lost, wherever it belongs.
  add(frag, lostHere(state));

  // The one place a script's free text is shown deliberately: dm-doctor writes
  // each check's note AS help text ("GitHub auth for the whole PR flow"), for
  // whoever is diagnosing this. A vocabulary map here would drift the moment a
  // check is added, and would say less.
  const tools = section('Tools');
  add(tools, table(['Tool', 'State', 'What it is for'], state.health.checks, (c) => {
    const [kind, label] = lookup(CHECK_STATUS, c.status);
    return add(el('tr'),
      cell('cell-title', el('span', null, c.name)),
      cell('nowrap', stateCell(kind, label)),
      cell(null, el('span', null, c.note)));
  }));
  add(frag, tools);

  const tidy = section('Worth tidying');
  add(tidy, table(['What', 'How many', 'Detail'], state.health.cleanup, (c) => add(el('tr'),
    cell('cell-title', el('span', null, c.label)),
    cell('mono num nowrap', el('span', null, c.count)),
    cell(null, el('span', null, c.note)))));
  return add(frag, tidy);
}

// --- the registry ------------------------------------------------------------

const LIVE_STATES = ['in_progress', 'ready_for_review', 'blocked', 'needs_decision', 'paused', 'failed'];

// A count over a source that could not be read is not a count. `null` drops the
// badge entirely, so the rail never shows a confident 0 for a panel that in
// fact knows nothing - the operator reads that 0 as "none", not "not read".
const counted = (panel, fn) => (s) => (lostAny(s, panel) ? null : fn(s));

export const VIEWS = [
  {
    id: 'needs', label: 'Needs you', group: 0, urgent: true, render: viewNeedsYou,
    count: (s) => s.needs_you.length,
  },
  {
    id: 'flight', label: 'In flight', group: 1, render: viewInFlight,
    count: (s) => s.work.filter((w) => LIVE_STATES.includes(w.state)).length,
  },
  {
    id: 'prs', label: 'Pull requests', group: 1, render: viewPullRequests,
    count: counted('prs', (s) => s.prs.length),
  },
  {
    id: 'decisions', label: 'Decisions', group: 1, render: viewDecisions,
    count: counted('decisions', (s) => s.decisions.open.length),
  },
  {
    id: 'backlog', label: 'Backlog', group: 2, render: viewBacklog,
    count: counted('backlog', (s) => s.backlog.in_flight.length + s.backlog.queued.length),
  },
  { id: 'repos', label: 'Repos', group: 2, render: viewRepos, count: (s) => s.repos.length },
  {
    id: 'reviews', label: 'Reviews', group: 2, render: viewReviews,
    count: counted('reviews', (s) => s.reviews.filter((r) => r.state === 'awaiting').length),
  },
  { id: 'health', label: 'Health', group: 2, render: viewHealth, count: () => null },
];
