/* views.mjs - one function per panel. Each takes the console document and returns
 * a fragment; none of them fetches, caches, or knows about the server.
 *
 * Every word here comes from dom.mjs's vocabulary maps. A machine token that
 * reached the screen would be a bug.
 */
'use strict';

import {
  el, add, lamp, stateCell, meta, link, table, cell, section, head, empty,
  foldable, segmented, askControl,
  plural, lookup, word, ago, clockTime, hoursSince,
  WORK_STATE, CHECKS, REVIEW_VERDICT, AUTHORITY, KIND, CHECK_STATUS, MODE,
  STAGE_LABEL, STAGE_STATE, SOURCE_WORD, PR_UNREADABLE, TESTS_RESULT,
  CLEANUP_REQUEST, TRASH_REQUEST, APPROVE_REQUEST, REVISION_REQUEST, ANSWER_MESSAGE,
} from './dom.mjs';

// What a fold is remembered under. One owner for the format: the Tidy panel
// names the same groups from outside, and a key it spelled itself would fold
// nothing the day a label changed.
const foldKey = (view, label) => `${view}:${label}`;

// A group of finished work folds itself away: the count stays on screen, the rows
// stop crowding the page. `ctx.fold` remembers what the operator opened.
function foldedSection(ctx, view, label, count, openByDefault) {
  const key = foldKey(view, label);
  const { node, body } = foldable(label, count, ctx.fold(key, openByDefault),
    (open) => ctx.setFold(key, open));
  node.classList.add('section');
  return { node, body };
}

// The labels of the groups that hold work which is over. Each is named here
// rather than at its call site because "fold the finished groups away" on the
// Tidy panel has to address the very same group - see FINISHED_GROUPS below.
const LANDED = 'Landed';
const ANSWERED = 'Answered';
const REVIEWED = 'Reviewed';

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

function gateList(gates) {
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
  return list;
}

// The declared gates this change must still clear. A PLAN, not progress: only
// the tests gate records anything, so every other one says so plainly rather
// than being drawn as passed.
//
// The unreported ones are the majority and every one makes the SAME claim, so
// they are counted in the open and read on request. Folded, never dropped -
// "nothing has reported on this" is a claim the page has to keep making, and
// the summary states how many there are before it is opened.
function gateStrip(gates) {
  if (!gates || gates.length === 0) return null;
  const recorded = gates.filter((g) => g.state !== 'unrecorded');
  const silent = gates.filter((g) => g.state === 'unrecorded');
  const wrap = el('div', 'gates');
  add(wrap, el('span', 'eyebrow', 'Still to clear'));
  if (recorded.length) add(wrap, gateList(recorded));
  if (silent.length) {
    const fold = el('details', 'gate-fold');
    add(fold, el('summary', 'gate-summary',
      `${plural(silent.length, 'step has', 'steps have')} nothing reported yet`));
    add(fold, gateList(silent));
    add(wrap, fold);
  }
  return wrap;
}

// The document carries a token for where a piece of work stands; the sentence is
// chosen here. Free text crosses only as `reported` - a worker's own words,
// written for the operator to read. Exported so a test can prove every kind the
// collector emits actually has a word here, instead of a second hand-copied list
// silently drifting out of sync with this one.
export const NOTE = {
  reported: (text) => text,
  undeterminable: () => 'Could not tell how far this got — its repo could not be read.',
  not_started: () => 'Not started yet.',
  unlanded: () => 'Committed, but not landed yet.',
  unreadable: () => 'Something was reported, but its note could not be read.',
  silent: () => 'Nothing has been reported yet.',
};

function noteText(item) {
  const word = NOTE[item.note_kind];
  return word ? word(item.note) : '';
}

// "Quiet" is not a judgement, it is a threshold: the document carries the same
// number dm-status.sh uses for a long runner, and every surface that says "quiet"
// says the number too. An unreadable stamp is NOT quiet - it is unknown, and
// counting it as quiet would invent a claim.
function isQuiet(item) {
  if (typeof item.quiet_after_hours !== 'number') return false;
  const quiet = hoursSince(item.last_signal_at);
  return quiet !== null && quiet > item.quiet_after_hours;
}

// "Is it moving?" answered from the only honest signal there is: how long since
// this piece of work last reported anything.
function movement(item) {
  if (item.state !== 'in_progress') return null;
  if (hoursSince(item.last_signal_at) === null) return null;
  if (!isQuiet(item)) {
    return add(el('span', 'moving'), lamp('starboard'), el('span', null, 'moving'));
  }
  return add(el('span', 'moving is-quiet'), lamp('neutral'),
    el('span', null, `quiet ${ago(item.last_signal_at).replace(' ago', '')}`));
}

// Work that is over cannot be trashed, and there is nothing to ask for.
const TRASHABLE = ['in_progress', 'ready_for_review', 'queued', 'blocked', 'needs_decision', 'paused', 'failed'];

// The written state on its own, without the lamp: the request text needs the word
// but not the colour.
const WORK_STATE_LABEL = Object.keys(WORK_STATE).reduce((map, key) => {
  map[key] = WORK_STATE[key][1];
  return map;
}, {});

// Open a review INSIDE the console (#219). A button, not a link: the review is
// not somewhere the browser navigates to any more, and while it is on screen the
// console holds a listener open for it - which is the shell's job (ctx.openReview),
// so a panel only ever names which review.
//
// A failure gets said next to the control that was clicked. The alternative was
// a click that does nothing, on the one control that leads to a decision.
function reviewOpener(ctx, href, label) {
  const box = el('span', 'review-open-control');
  // Not `row-action`: that class writes an arrow after the label, and an arrow
  // says the click leaves. This one opens the review right here.
  const button = el('button', 'btn btn-quiet review-open-button');
  button.type = 'button';
  add(button, el('span', null, label));
  const failed = el('span', 'review-open-failed');
  button.addEventListener('click', () => {
    failed.textContent = '';
    button.disabled = true;
    const done = () => { button.disabled = false; };
    // Called straight out of the click, not from a later microtask: the open
    // reads the operator's gesture, and a deferred call is how a control ends up
    // looking dead for a frame.
    try {
      ctx.openReview(href).then(done, (err) => { failed.textContent = err.message; done(); });
    } catch (err) {
      failed.textContent = err.message;
      done();
    }
  });
  return add(box, button, failed);
}

// The trash affordance. It ENQUEUES a request - naming the work the way the
// operator sees it, since a task id is the one thing this seam keeps off the page
// - and the dockmaster carries it out under the usual gates. Two steps, and it is
// coloured as the destructive request it is.
function trashControl(item, ctx) {
  if (!TRASHABLE.includes(item.state)) return null;
  return askControl({
    kind: 'trash',
    label: 'Trash this work',
    confirm: 'Ask the dockmaster to drop this work and stop paying it any more attention.',
    request: TRASH_REQUEST(item.title, item.repo, word(WORK_STATE_LABEL, item.state)),
    ask: ctx.ask,
  });
}

// The two awaiting-review affordances. Same enqueue-only pattern as the trash
// control above: each one only ever puts an ordinary message on the queue, and
// the dockmaster is the one that reads it and acts. Neither shows outside
// `ready_for_review`, and neither shows without a rendered artifact behind
// `review_href` - the artifact IS the approval gate, so approving or asking for
// changes with nothing to review is not a request this page can even word.
function approveControl(item, ctx) {
  if (item.state !== 'ready_for_review' || !item.review_href) return null;
  return askControl({
    kind: 'approve',
    label: 'Approve',
    confirm: "Ask the dockmaster to approve this change. Landing still follows the repo's own merge authority.",
    request: APPROVE_REQUEST(item.title, item.repo),
    ask: ctx.ask,
  });
}

function changesControl(item, ctx) {
  if (item.state !== 'ready_for_review' || !item.review_href) return null;
  return askControl({
    kind: 'changes',
    label: 'Request changes',
    confirm: 'Send the dockmaster your notes on what needs to change.',
    notes: true,
    placeholder: 'What needs to change?',
    buildRequest: (notes) => REVISION_REQUEST(item.title, item.repo, notes),
    ask: ctx.ask,
  });
}

// Where this work stands, as one string. It is what the shell diffs between
// renders to decide whether anything actually moved - so it holds only stable
// facts, never an age, which would "change" every minute on its own.
function voyageSignature(item) {
  const active = item.track ? (item.track.stages.find((s) => s.state === 'active') || {}).key : '';
  return `${item.state}|${active || ''}`;
}

function voyage(item, ctx) {
  const [lampKind, stateWord] = lookup(WORK_STATE, item.state);
  const card = el('article', `voyage is-${item.state}`);
  card.dataset.key = `work:${item.repo}:${item.title}`;
  card.dataset.sig = voyageSignature(item);
  const header = el('div', 'voyage-head');
  const left = el('div');
  // Title above its metadata, for the same reason the queue rows read that way.
  add(left,
    el('h3', 'voyage-title', item.title),
    meta(item.repo, word(KIND, item.kind), `started ${ago(item.since)}`));
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
  const foot = el('div', 'voyage-foot');
  if (item.review_href) add(foot, reviewOpener(ctx, item.review_href, 'Open the review'));
  add(foot, approveControl(item, ctx));
  add(foot, changesControl(item, ctx));
  add(foot, trashControl(item, ctx));
  add(card, foot);
  return card;
}

// --- in flight ---------------------------------------------------------------

const CARD_GROUPS = [
  ['In progress', ['in_progress']],
  ['Ready for your review', ['ready_for_review']],
  ['Stopped', ['blocked', 'needs_decision', 'failed']],
  ['Paused', ['paused']],
];
// The optional 4th/5th slots carry a group's own sort and its own time column,
// so a label rename can never silently drop either: both travel WITH the group
// they belong to, never keyed off its label at the call site.
const LEDGER_GROUPS = [
  ['Not started', ['queued'], true],
  ['Recently finished', ['done'], false, byFinishedNewestFirst,
    { header: 'Finished', value: (w) => w.last_signal_at }],
  ['Dropped', ['dropped'], false],
];

// "Recently finished" reads newest-completed first. `last_signal_at` is the
// last recorded event - the landing append when the dockmaster landed it
// (dm-pr.sh / dm-merge.sh write that append right there), but the PR-open
// stamp when the operator merged on GitHub themselves (a `never`-authority
// repo's dm-pr.sh check records pr_state=MERGED with no append of its own) -
// so for those it is a lower bound on completion, not the completion time
// itself. It already falls back to the task's created time when no event ever
// landed, so no extra field is needed. Title breaks ties so the order never
// depends on object insertion order. A row missing the field sorts last
// rather than throwing, since an unreadable stamp is unknown, not a crash.
export function byFinishedNewestFirst(rows) {
  return [...rows].sort((a, b) => (
    String(b.last_signal_at || '').localeCompare(String(a.last_signal_at || ''))
    || a.title.localeCompare(b.title)
  ));
}

// Every group that holds work which is over - what "fold the finished groups
// away" on the Tidy panel acts on. DERIVED, not restated: a group holds
// finished work exactly when it folds itself away by default, so the in-flight
// ones come straight off LEDGER_GROUPS and the rest off the labels their own
// call sites use. A hand-written key here would go on folding the group that
// used to have that name.
export const FINISHED_GROUPS = [
  ...LEDGER_GROUPS.filter(([, , openByDefault]) => !openByDefault)
    .map(([label]) => foldKey('flight', label)),
  foldKey('backlog', LANDED),
  foldKey('decisions', ANSWERED),
  foldKey('reviews', REVIEWED),
];

// The raw states dm-status.sh reports are finer than the operator wants to pick
// through: "idle" covers everything that is not running, not yet reviewed, and
// not over - paused voluntarily, stopped on a blocker or a question, or a task
// that failed and needs new work. Grouped here, once, rather than at each call
// site, so the filter and the label it shows can never drift apart.
const IDLE_STATES = ['queued', 'paused', 'blocked', 'needs_decision', 'failed'];

// The filters. Each one is a predicate over the SAME list - nothing is fetched,
// nothing is re-derived - and every one is answerable from the document's own
// `state`, the real status the dm-* scripts report, never a label invented here.
//
// Only `all` shows everything, and it is the default. The rest NARROW, so the
// panel states how many rows a filter is holding back rather than letting a
// choice made yesterday read as a fleet with less in it.
const FLIGHT_FILTERS = [
  { id: 'all', label: 'Everything', match: () => true },
  { id: 'running', label: 'Running', match: (w) => w.state === 'in_progress' },
  { id: 'review', label: 'Ready for review', match: (w) => w.state === 'ready_for_review' },
  { id: 'idle', label: 'Idle', match: (w) => IDLE_STATES.includes(w.state) },
  { id: 'done', label: 'Done', match: (w) => w.state === 'done' || w.state === 'dropped' },
];

const flightFilter = (id) => FLIGHT_FILTERS.find((f) => f.id === id) || FLIGHT_FILTERS[0];

// What each filter actually means, named on screen beside the control that uses
// it - a filter called "idle" that will not say what it covers is the operator
// having to take the page's word for it.
const FILTER_NOTE = {
  all: 'Every piece of work, whatever it is doing.',
  running: 'Under way right now.',
  review: 'Done and waiting on your review.',
  idle: 'Not moving right now — paused, stopped on a blocker or a question you have not answered yet, not started, or failed and waiting on new work.',
  done: 'Over — landed or dropped.',
};

function filterBar(state, ctx) {
  const wrap = el('div', 'filters');
  const current = flightFilter(ctx.filter).id;
  const options = FLIGHT_FILTERS.map((f) => ({
    id: f.id,
    label: f.label,
    count: state.work.filter(f.match).length,
  }));
  add(wrap, segmented('Filter the work', options, current, (id) => ctx.setFilter(id)));
  add(wrap, el('p', 'filters-note', FILTER_NOTE[current]));
  return wrap;
}

export function viewInFlight(state, ctx) {
  const frag = document.createDocumentFragment();
  add(frag, head('In flight',
    'Where each piece of work has actually got to. A hollow mark is a stage it has not reached, '
    + 'a dashed line is what nothing has reported on yet — neither is a claim that it is failing.'));
  add(frag, lostHere(state, 'flight'));
  add(frag, filterBar(state, ctx));

  const active = flightFilter(ctx.filter);
  const shown = state.work.filter(active.match);
  // A filter hiding work must SAY it is hiding work. Otherwise "nothing is under
  // way" is a claim about the fleet made by a control the operator set earlier.
  if (active.id !== 'all') {
    add(frag, el('p', 'filters-count',
      `Showing ${shown.length} of ${state.work.length}. ${state.work.length - shown.length} hidden by this filter.`));
  }
  if (shown.length === 0) {
    add(frag, active.id === 'all'
      ? empty('Nothing is under way.', 'The crew has no open work right now.')
      : empty('Nothing matches this filter.',
        `${plural(state.work.length, 'piece of work is', 'pieces of work are')} here — none of them ${active.label.toLowerCase()}.`));
    return frag;
  }

  const matches = (keys) => shown.filter((w) => keys.includes(w.state));
  for (const [label, keys] of CARD_GROUPS) {
    const rows = matches(keys);
    if (rows.length === 0) continue;
    const node = section(`${label} · ${rows.length}`);
    const list = el('div', 'voyages');
    rows.forEach((row) => add(list, voyage(row, ctx)));
    add(frag, add(node, list));
  }
  for (const [label, keys, openByDefault, sortRows, timeColumn] of LEDGER_GROUPS) {
    const matched = matches(keys);
    if (matched.length === 0) continue;
    const rows = sortRows ? sortRows(matched) : matched;
    const { node, body } = foldedSection(ctx, 'flight', label, rows.length, openByDefault);
    const timeHeader = timeColumn ? timeColumn.header : 'Started';
    const timeValue = timeColumn ? timeColumn.value : (w) => w.since;
    add(body, table(['What', 'Repo', timeHeader, 'Waiting on'], rows, (w) => add(el('tr'),
      cell('cell-title', el('span', null, w.title)),
      cell('mono nowrap', el('span', null, w.repo)),
      cell('mono nowrap', el('span', null, ago(timeValue(w)))),
      cell(null, el('span', noteText(w) ? '' : 'mono mono-mute', noteText(w) || '—')))));
    add(frag, node);
  }
  return frag;
}

// --- needs you ---------------------------------------------------------------

// One renderer per kind. The document carries a token and the data; the sentence
// the operator reads is chosen here.
//
// `state` is the row's standing printed beside its lamp. Chosen per KIND rather
// than per lamp because one lamp serves several: `port` is both a pull request
// whose checks are failing and a piece of work that failed outright, and
// "Failing" is only true of one of them.
const NEEDS = {
  review: (item) => ({
    head: `${plural(item.count, 'change is', 'changes are')} waiting for your review`,
    detail: `In ${item.repos.join(', ')}.`,
    state: 'Waiting for review',
    action: item.count === 1 ? 'Open the review page' : 'See what is waiting',
  }),
  decision: (item) => ({
    head: item.question,
    detail: item.options && item.options.length
      ? 'Only you can answer this. One click sends the answer, or write your own.'
      : 'Only you can answer this. Write the answer in the conversation.',
    state: 'Waiting on you',
  }),
  pr_red: (item) => ({
    head: item.title, detail: 'Checks are failing on this pull request.',
    state: 'Checks failing', action: 'Open on GitHub',
  }),
  pr_changes: (item) => ({
    head: item.title, detail: 'A review asked for changes.',
    state: 'Changes requested', action: 'Open on GitHub',
  }),
  pr_yours: (item) => ({
    head: item.title,
    detail: 'Green and ready. This repo is yours to merge — the dockmaster never merges it.',
    state: 'Ready to merge',
    action: 'Merge on GitHub',
  }),
  blocked: (item) => ({ head: item.title, detail: item.detail || 'Stopped, waiting on you.', state: 'Stopped' }),
  needs_decision: (item) => ({
    head: item.title, detail: item.detail || 'Waiting on a choice only you can make.',
    state: 'Waiting on you',
  }),
  failed: (item) => ({ head: item.title, detail: item.detail || 'This did not complete.', state: 'Failed' }),
};

// The queue arrives in the order it was ASSEMBLED - every review, then every
// decision, then the pull requests - so a failing pull request routinely sits
// below two questions that can wait. Ranked on the severity the server already
// assigned each row, which is exactly what `lamp` is for: no fleet fact is
// derived in the browser, the existing one is only read in a better order.
const LAMP_RANK = { port: 0, brass: 1, starboard: 2, neutral: 4 };
const KNOWN_LAMPS = new Set(Object.keys(LAMP_RANK));

// A lamp this page has never seen is a DIFFERENT claim from `neutral` - not the
// server marking a row deliberately calm, but a gap in this page's vocabulary.
// Adding a lamp server-side is the obvious way to add a severity, so a gap must
// not read as calm: it floats above `neutral` rather than folding into it, so a
// client predating a new severity still surfaces it instead of burying it.
const UNCLASSIFIED_RANK = 3;
const rankOf = (item) => (KNOWN_LAMPS.has(item.lamp) ? LAMP_RANK[item.lamp] : UNCLASSIFIED_RANK);

function byUrgency(a, b) {
  if (rankOf(a) !== rankOf(b)) return rankOf(a) - rankOf(b);
  // Same severity: the one waiting longest is the one to answer. An unreadable
  // stamp sorts to the end of its group - comparing it equal to everything is
  // not transitive, and would let it invert two dated rows depending only on
  // which pair the sort happened to compare first.
  const at = Date.parse(a.at || '');
  const bt = Date.parse(b.at || '');
  if (Number.isNaN(at) && Number.isNaN(bt)) return 0;
  if (Number.isNaN(at)) return 1;
  if (Number.isNaN(bt)) return -1;
  return at - bt;
}

// The fallback standing, for a kind NEEDS has no entry for. A colour carrying
// rank has to say what rank it is: red and green are the two an operator is most
// likely to be unable to tell apart, and 8px of it is below the size at which
// colour works as a channel at all.
const URGENCY = {
  port: 'Failing',
  brass: 'Waiting on you',
  starboard: 'Ready',
  neutral: 'Waiting on you',
};

// Identity across renders, so the shell can tell a genuinely new row from the
// same row redrawn. Deliberately free of anything that ages on its own.
const berthKey = (item) => `need:${item.kind}:${item.title || item.question || ''}:${item.repo || ''}`;

// The fallback never prints `kind`: an unrecognised kind is a gap in NEEDS, and
// its token is exactly the sort of word that must not reach the screen. Exported
// because the beacon above every panel says the same thing in one line, and two
// places wording it independently would drift.
export function needsWords(item) {
  const words = NEEDS[item.kind];
  if (words) return words(item);
  return { head: item.title || 'Something is waiting on you', detail: item.detail || '' };
}

// Which arrivals on the conversation change what a PANEL says, so the shell
// knows when a redraw is owed. Two of them, and no third:
//   - the Updates panel IS the conversation read as a feed, so any message does;
//   - an OPERATOR message may be the answer to a question a row is still
//     offering buttons for - sent from this tab or from a second one. Without
//     this, a tab that had not sent the answer itself went on offering live
//     buttons until the 30-second refresh, and a click there queued a second,
//     contradictory answer.
// Everything else deliberately leaves the panel alone: rebuilding it on every
// dockmaster status line would drop whatever the operator had half-typed into a
// revision note.
export function panelNeedsRedraw(messages, view) {
  if (messages.length === 0) return false;
  return view === 'updates' || messages.some((m) => m.from === 'operator');
}

// One row per task behind an aggregated "N changes are waiting for your
// review" beacon - the headline stays aggregated, but each task underneath it
// is still a single piece of work the operator can act on without leaving this
// panel for In-flight. Built from `approveControl`/`changesControl` so the
// wording and the enqueue-only contract are the same ones the In-flight card
// uses, never a second copy of either.
function reviewRow(sub, ctx) {
  const row = el('div', 'review-item');
  add(row, el('p', 'review-item-what', `${sub.title} — ${sub.repo}`));
  const actions = el('div', 'review-item-actions');
  if (sub.review_href) add(actions, reviewOpener(ctx, sub.review_href, 'Open the review'));
  // `state` is synthesized, always 'ready_for_review' - approveControl's/
  // changesControl's own gate on it is vacuous here. The real guarantee is
  // upstream: live.js only ever maps a task actually awaiting review into
  // this items[] array in the first place. `review_href` crosses through
  // unchanged, so the artifact-rendered gate still applies to this row too.
  const stand = { state: 'ready_for_review', title: sub.title, repo: sub.repo, review_href: sub.review_href };
  add(actions, approveControl(stand, ctx));
  add(actions, changesControl(stand, ctx));
  add(row, actions);
  return row;
}

// Answering a question the dockmaster asked, in ONE click.
//
// No confirm strip, unlike the cleanup and trash controls: those enqueue a
// REQUEST that changes the fleet, and an answer is a message. It still leaves
// this page the only way anything does - as an ordinary operator message on the
// same queue as a typed sentence.
//
// A DECIDED question does not offer the buttons again. The hold stays open until
// the dockmaster picks the answer up and resolves it, so the row outlives the
// answer by minutes, and this panel is rebuilt from scratch every 30 seconds -
// which used to put live buttons back with no sign anything had been sent. A
// second click would then queue a second, possibly contradictory answer behind
// the first, and nothing anywhere says which of the two wins. `ctx.answered`
// reads the transcript, the one place the answer is durably recorded, so the
// acknowledgement survives the rebuild, a reload and a restart of the console.
//
// It says only what it knows. The transcript arrives on its own request, so
// until that has landed there is no answer to be found and NOT FINDING one is
// not evidence: a button offered in that window is how an already-answered
// question gets a second, contradictory answer. So the row waits instead, and
// the read redraws it (see panelNeedsRedraw).
function choices(item, ctx) {
  if (!ctx.transcriptRead()) {
    return add(el('div'), el('p', 'choice-status',
      'Reading the conversation to see whether this was already answered.'));
  }
  const already = ctx.answered(item.question);
  if (already !== null) {
    // What happens to it next is the dockmaster's, and this row cannot see the
    // pick-up queue - only that the answer is in the conversation.
    return add(el('div'), el('p', 'choice-status choice-answered',
      `Answered: ${already} — it is in the conversation. This stays here until the `
      + 'dockmaster closes it; say so in the conversation if you need to change it.'));
  }
  const box = el('div', 'choices');
  const status = el('p', 'choice-status');
  status.hidden = true;
  const buttons = item.options.map((option) => {
    const button = el('button', 'btn choice', option);
    button.type = 'button';
    return button;
  });
  const setDisabled = (disabled) => buttons.forEach((b) => { b.disabled = disabled; });
  buttons.forEach((button, i) => {
    button.addEventListener('click', () => {
      setDisabled(true);
      status.hidden = false;
      status.textContent = 'Sending…';
      ctx.sendAnswer(item.question, item.options[i]).then(() => {
        status.textContent = 'Answered. It is in the conversation.';
      }, (err) => {
        // The answer was NOT sent, so the buttons come back: a row that looks
        // answered when nothing left the page is the one failure that matters.
        setDisabled(false);
        status.textContent = `Not sent: ${err.message}`;
      });
    });
    add(box, button);
  });
  // Anything that is not one of the options: the question is drafted into the
  // composer for the operator to finish, which is what "or write your own"
  // means. It sends nothing.
  const own = el('button', 'btn btn-quiet choice', 'Write my own');
  own.type = 'button';
  own.addEventListener('click', () => ctx.compose(ANSWER_MESSAGE(item.question, '')));
  add(box, own);
  return add(el('div'), box, status);
}

function berth(item, ctx) {
  const words = needsWords(item);
  // `item.lamp` is a token from the server, not a class name: an unvalidated
  // lamp interpolated straight into className lets a stray value attach classes
  // this row was never meant to carry. It always falls back to `neutral`, and
  // the written standing below says plainly when that fallback fired.
  const known = KNOWN_LAMPS.has(item.lamp);
  const rank = known ? item.lamp : 'neutral';
  const row = el('div', `row row-${rank}`);
  row.dataset.key = berthKey(item);
  row.dataset.sig = `${item.lamp || ''}|${item.count || ''}|${words.detail || ''}`;
  // The headline goes FIRST. A monospace repo line above it delayed the answer
  // by one line on every row, so the eye landed on metadata before the news.
  add(row, el('p', 'row-head', words.head), el('p', 'row-detail', words.detail));
  if (item.kind === 'review' && item.items && item.items.length) {
    const list = el('div', 'review-items');
    item.items.forEach((sub) => add(list, reviewRow(sub, ctx)));
    add(row, list);
  }
  if (item.options && item.options.length) add(row, choices(item, ctx));
  // A single awaiting review already got its own "Open the review page" link
  // in the row above - repeating it here would be the same link twice. Several
  // still get the jump to In-flight, which the per-task rows do not replace.
  const oneReviewAlready = item.kind === 'review' && item.items && item.items.length === 1;
  if (item.href && words.action && !oneReviewAlready) {
    add(row, link(item.href, words.action, 'row-action'));
  }
  // The standing, its lamp, and the where/when - reference, so it sits last.
  const where = item.repo || (item.repos || []).join(', ');
  const when = item.at ? ago(item.at) : '';
  const foot = el('p', 'row-meta');
  add(foot, stateCell(rank, known ? (words.state || word(URGENCY, rank)) : 'Not known'));
  [where, when].filter(Boolean).forEach((part) => {
    add(foot, el('span', 'mono mono-mute', '·'), el('span', 'mono', part));
  });
  return add(row, foot);
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
  const hero = el('div', 'hero is-urgent');
  add(hero,
    add(el('span', 'hero-figure'), el('span', null, state.needs_you.length)),
    add(el('span', 'hero-side'),
      el('span', 'hero-label', state.needs_you.length === 1 ? 'thing is waiting on you' : 'things are waiting on you'),
      el('span', 'hero-sub', 'Each one is stopped until you act.')));
  add(frag, hero);
  const rows = el('div', 'rows');
  // Most urgent first, then longest-waiting. The hero above already says how
  // many; this decides which one the eye reaches first.
  state.needs_you.slice().sort(byUrgency).forEach((item) => add(rows, berth(item, ctx)));
  return add(frag, rows);
}

// --- pull requests -----------------------------------------------------------

// owner/repo#number, the way the operator says it out loud. Anything that is
// not a pull-request address is shown whole rather than guessed at.
const PR_URL = /^https?:\/\/[^/]+\/([^/]+)\/([^/]+)\/pull\/(\d+)/;
function shortRef(url) {
  const parts = PR_URL.exec(url || '');
  return parts ? `${parts[1]}/${parts[2]}#${parts[3]}` : (url || '');
}

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
    const anchor = link(pr.url, pr.title || 'Title not read');
    // The address is the link and its tooltip. Printed in full under every row
    // it pushed the Repo column off the deck at the ordinary window size, and
    // Repo is the column the operator came for.
    anchor.title = pr.url;
    const ref = el('span', 'cell-sub link-url', shortRef(pr.url));
    ref.title = pr.url;
    add(title, anchor, ref);
    if (pr.unreadable) add(title, el('span', 'cell-sub cell-warn', word(PR_UNREADABLE, pr.unreadable)));
    else if (pr.cached) add(title, el('span', 'cell-sub', 'Last known — not re-read just now'));
    else if (pr.opened_at) add(title, el('span', 'cell-sub', `Opened ${ago(pr.opened_at)}`));
    const row = el('tr');
    row.dataset.key = `pr:${pr.url}`;
    // Checks flipping is the change this panel exists to show, so it is the
    // signature: the shell marks exactly that row when it moves.
    row.dataset.sig = `${pr.checks}|${pr.review}`;
    return add(row,
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

  if (state.decisions.resolved.length === 0) {
    const done = section(`${ANSWERED} · 0`);
    add(done, el('p', 'empty-note', 'Nothing answered yet.'));
    return add(frag, done);
  }
  const { node, body } = foldedSection(ctx, 'decisions', ANSWERED, state.decisions.resolved.length, false);
  add(body, table(['Question', 'Your answer', 'When'], state.decisions.resolved, (d) => add(el('tr'),
    cell('cell-title', el('span', null, d.question)),
    cell(null, el('span', null, d.answer || '—')),
    cell('mono nowrap', el('span', null, ago(d.at))))));
  return add(frag, node);
}

// --- backlog -----------------------------------------------------------------

export function viewBacklog(state, ctx) {
  const frag = document.createDocumentFragment();
  add(frag, head('Backlog', 'What the crew is on, what is next, and what has landed.'));
  add(frag, lostHere(state, 'backlog'));
  const groups = [
    ['Under way', state.backlog.in_flight, true],
    ['Queued', state.backlog.queued, true],
    [LANDED, state.backlog.done, false],
  ];
  const rowsOf = (rows) => table(['What', 'Repo', 'Waiting on'], rows, (item) => add(el('tr'),
    cell('cell-title', el('span', null, item.title)),
    cell('mono nowrap', el('span', null, item.repo || '—')),
    cell(null, el('span', item.blocked_by ? '' : 'mono mono-mute', item.blocked_by || '—'))));
  for (const [label, rows, openByDefault] of groups) {
    if (rows.length === 0) {
      const node = section(`${label} · 0`);
      add(node, el('p', 'empty-note', 'Nothing here.'));
      add(frag, node);
      continue;
    }
    const { node, body } = foldedSection(ctx, 'backlog', label, rows.length, openByDefault);
    add(body, rowsOf(rows));
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

export function viewReviews(state, ctx) {
  const frag = document.createDocumentFragment();
  add(frag, head('Reviews', 'Every review page the crew has produced. They stay openable after the work lands. '
    + 'Open shows the page the console keeps; the original is the annotatable session it was rendered in, '
    + 'which is not always still open.'));
  const lost = lostHere(state, 'reviews');
  add(frag, lost);
  if (state.reviews.length === 0) {
    if (!lost) add(frag, empty('No review pages yet.', 'One appears here each time a change is ready for you.'));
    return frag;
  }
  const rowsOf = (rows) => table(['What', 'Repo', 'State', 'Rendered', ''], rows, (r) => {
    const awaiting = r.state === 'awaiting';
    // Which reviews the console is holding a listener open for. One lamp on the
    // row that has one; nothing at all on the rows that do not.
    const listening = ctx.reviewIsLive(r.href)
      ? add(el('span', 'review-listening'), lamp('starboard'), el('span', null, 'Listening'))
      : null;
    return add(el('tr'),
      // A review page outlives the record that named it; when that is gone the
      // page says the title is not recorded rather than printing an internal id.
      cell('cell-title', el('span', r.title ? null : 'mono mono-mute', r.title || 'Title not recorded')),
      cell('mono nowrap', el('span', null, r.repo || '—')),
      cell('nowrap', stateCell(awaiting ? 'brass' : 'neutral', awaiting ? 'Waiting for you' : 'Reviewed')),
      cell('mono nowrap', add(el('span', null, ago(r.at)), listening)),
      // The console's own page first, and it opens HERE - the review is part of
      // the console, not a tab beside it. The annotatable lavish session stays a
      // real link: it is a different origin on a different server, so it is not
      // embedded, and the tab has to come from the click's own gesture.
      cell('nowrap', add(el('div', 'review-open'),
        reviewOpener(ctx, r.href, 'Open'),
        el('span', 'review-or', '·'),
        link(r.session_href, 'the original', 'row-action'))));
  });
  // Waiting and reviewed are two different jobs: one is a queue, the other an
  // archive. The archive folds away; the queue never does.
  const waiting = state.reviews.filter((r) => r.state === 'awaiting');
  const archived = state.reviews.filter((r) => r.state !== 'awaiting');
  if (waiting.length > 0) {
    const node = section(`Waiting for you · ${waiting.length}`);
    add(node, rowsOf(waiting));
    add(frag, node);
  }
  if (archived.length > 0) {
    const { node, body } = foldedSection(ctx, 'reviews', REVIEWED, archived.length, false);
    add(body, rowsOf(archived));
    add(frag, node);
  }
  return frag;
}

// --- health ------------------------------------------------------------------

export function viewHealth(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('Health', 'Whether the dockmaster can do its job, and what it would like to tidy up.'));

  // A verdict is a WORD, not a figure, so it does not get the figure's type.
  const hero = el('div', 'hero is-verdict');
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
  add(tidy, link('#tidy', 'Ask the dockmaster to clear these', 'row-action'));
  return add(frag, tidy);
}

// --- tidy up -----------------------------------------------------------------

// The operator asked for a way to clean things up. There are two kinds, and the
// difference is the whole point of this panel: one only changes what this page
// SHOWS, and happens on the spot. The other removes real work, so this page never
// does it - it asks, and the dockmaster carries it out under the usual gates.
export function viewTidy(state, ctx) {
  const frag = document.createDocumentFragment();
  add(frag, head('Tidy up',
    'Two kinds of tidying, kept apart on purpose. Folding a group away only changes what this '
    + 'page shows. Anything that removes real work is a request — this page sends it, the '
    + 'dockmaster carries it out.'));

  const view = section('On this page only');
  add(view, el('p', 'view-note', 'Nothing here leaves the browser. Fold the groups holding finished '
    + 'work away, or open them all back up.'));
  const controls = el('div', 'tidy-actions');
  const foldAll = el('button', 'btn', 'Fold the finished groups away');
  foldAll.type = 'button';
  foldAll.addEventListener('click', () => ctx.setFolds(FINISHED_GROUPS, false));
  const openAll = el('button', 'btn btn-quiet', 'Open everything back up');
  openAll.type = 'button';
  openAll.addEventListener('click', () => ctx.setFolds(FINISHED_GROUPS, true));
  add(controls, foldAll, openAll);
  add(view, controls);
  add(frag, view);

  const ask = section('Ask the dockmaster');
  add(ask, el('p', 'view-note', 'Each of these writes one request into the conversation. You confirm '
    + 'it first, and you can see exactly what will be sent.'));
  // Both sources this section counts from: the cleanup rows come from health,
  // the landed-rows request from the backlog. If either failed to read, "Nothing
  // to clear." below is a guess, so the failure is named here rather than
  // letting the page imply there is nothing left behind.
  add(ask, lostHere(state, 'health', 'backlog'));

  const requests = [];
  for (const row of state.health.cleanup) {
    if (!row.count) continue;
    // A kind with a count but no sentence in CLEANUP_REQUEST is a gap in THIS
    // file, not something to drop: dropping it silently would read as "nothing
    // to clear" when the health panel just said otherwise.
    if (!CLEANUP_REQUEST[row.kind]) {
      requests.push(add(el('div', 'ask'),
        el('p', 'ask-what', `${row.label} — ${row.count}. No request written for this yet.`)));
      continue;
    }
    requests.push(askControl({
      kind: 'tidy',
      label: `${row.label} — ${row.count}`,
      confirm: `${row.label}: ${row.count}. ${row.note}`,
      request: CLEANUP_REQUEST[row.kind](row.count),
      ask: ctx.ask,
    }));
  }
  const landed = state.backlog.done.length;
  if (landed > 0) {
    requests.push(askControl({
      kind: 'tidy',
      label: `Landed rows in the backlog — ${landed}`,
      confirm: `${landed} rows in the backlog have landed and are only taking up room.`,
      request: CLEANUP_REQUEST.landed_backlog(landed),
      ask: ctx.ask,
    }));
  }
  if (requests.length === 0) {
    add(ask, empty('Nothing to clear.', 'No finished work is leaving anything behind right now.'));
  } else {
    add(ask, add(el('div', 'asks'), ...requests));
  }
  add(frag, ask);

  const never = section('What this page will never do');
  add(never, el('p', 'view-note', 'No control here merges, lands, or deletes anything. Every one of '
    + 'them sends a message; the dockmaster does the work under the same gates as always.'));
  return add(frag, never);
}

// --- updates -----------------------------------------------------------------

// The conversation read as a feed: only what the dockmaster has said, newest
// first, so a glance answers "what has happened" without scrolling a transcript.
// One source - the same messages the conversation renders - read two ways.
export function viewUpdates(state, ctx) {
  const frag = document.createDocumentFragment();
  add(frag, head('Updates',
    'Everything the dockmaster has posted, newest first. The same conversation, read as a log.'));
  if (ctx.updates.length === 0) {
    add(frag, empty('No updates yet.',
      'The dockmaster posts here as work moves. Ask it something in the conversation to start one.'));
    return frag;
  }
  const feed = el('div', 'feed');
  const recent = ctx.updates.slice(0, FEED_HEAD);
  recent.forEach((message) => add(feed, feedLine(message)));
  add(frag, feed);
  const older = ctx.updates.slice(FEED_HEAD);
  if (older.length > 0) {
    const { node, body } = foldedSection(ctx, 'updates', 'Earlier', older.length, false);
    const rest = el('div', 'feed');
    older.forEach((message) => add(rest, feedLine(message)));
    add(body, rest);
    add(frag, node);
  }
  return frag;
}

// How many updates stay open before the rest folds away. A day of status lines is
// a wall; the newest handful is what is actually being read.
const FEED_HEAD = 20;

function feedLine(message) {
  const row = el('div', 'feed-line');
  add(row,
    el('span', 'feed-at', clockTime(message.at)),
    el('span', 'feed-ago', ago(message.at)),
    el('p', 'feed-text', message.text));
  return row;
}

// --- the registry ------------------------------------------------------------

const LIVE_STATES = ['in_progress', 'ready_for_review', 'blocked', 'needs_decision', 'paused', 'failed'];

// A count over a source that could not be read is not a count. `null` drops the
// badge entirely, so the rail never shows a confident 0 for a panel that in
// fact knows nothing - the operator reads that 0 as "none", not "not read".
const counted = (panel, fn) => (s) => (lostAny(s, panel) ? null : fn(s));

// The rail's groups are NAMED, because the grouping is a claim about the content:
// one panel is the queue, three are live work, three are reference, two are the
// console's own housekeeping. An unlabelled divider left the reader to guess.
export const VIEWS = [
  {
    id: 'needs', label: 'Needs you', group: 'Waiting on you', urgent: true, render: viewNeedsYou,
    count: (s) => s.needs_you.length,
  },
  { id: 'updates', label: 'Updates', group: 'Waiting on you', render: viewUpdates, count: () => null },
  {
    id: 'flight', label: 'In flight', group: 'The work', render: viewInFlight,
    count: (s) => s.work.filter((w) => LIVE_STATES.includes(w.state)).length,
  },
  {
    id: 'prs', label: 'Pull requests', group: 'The work', render: viewPullRequests,
    count: counted('prs', (s) => s.prs.length),
  },
  {
    id: 'decisions', label: 'Decisions', group: 'The work', render: viewDecisions,
    count: counted('decisions', (s) => s.decisions.open.length),
  },
  {
    id: 'backlog', label: 'Backlog', group: 'Reference', render: viewBacklog,
    count: counted('backlog', (s) => s.backlog.in_flight.length + s.backlog.queued.length),
  },
  { id: 'repos', label: 'Repos', group: 'Reference', render: viewRepos, count: (s) => s.repos.length },
  {
    id: 'reviews', label: 'Reviews', group: 'Reference', render: viewReviews,
    count: counted('reviews', (s) => s.reviews.filter((r) => r.state === 'awaiting').length),
  },
  { id: 'tidy', label: 'Tidy up', group: 'The console', render: viewTidy, count: () => null },
  { id: 'health', label: 'Health', group: 'The console', render: viewHealth, count: () => null },
];
