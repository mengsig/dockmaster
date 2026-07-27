/* dom.mjs - element helpers and the console's whole vocabulary.
 *
 * The internal vocabulary stops HERE. Everything the server sends is a machine
 * token (`awaiting-review`, `never`, `ahead`); every word the operator reads is
 * chosen in this file. Nothing downstream prints a task id, a local-copy path,
 * a brief, or a state name.
 *
 * Everything is built with textContent, never assembled HTML: repo names,
 * titles and chat text all arrive from disk and are treated as text.
 */
'use strict';

export function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}

export function add(parent, ...children) {
  for (const child of children) if (child) parent.appendChild(child);
  return parent;
}

export function lamp(kind) {
  const node = el('span', `lamp lamp-${kind}`);
  node.setAttribute('aria-hidden', 'true');
  return node;
}

// A lamp never travels alone: the written state is the accessible carrier and
// the colour is the fast one.
export function stateCell(kind, label) {
  return add(el('span', 'state'), lamp(kind), el('span', null, label));
}

export function meta(...parts) {
  const line = el('p', 'row-meta');
  parts.filter(Boolean).forEach((part, i) => {
    if (i > 0) add(line, el('span', 'mono mono-mute', '·'));
    add(line, el('span', 'mono', part));
  });
  return line;
}

// Every link on the page is built here, so the new-tab rule is INHERITED rather
// than remembered per call site: anything that leaves the console - a pull
// request, a repo, an archived review page - opens in its own tab and never
// navigates the console away from under the operator. An in-page anchor is the
// one thing that stays, because a tab per panel jump would be a bug.
export function link(href, text, className) {
  const node = el('a', className, text);
  node.href = href;
  if (String(href).charAt(0) !== '#') {
    node.target = '_blank';
    // noreferrer implies noopener in current browsers; both are named so the
    // guarantee does not rest on that.
    node.rel = 'noopener noreferrer';
  }
  return node;
}

export function table(columns, rows, buildRow) {
  const wrap = el('div', 'scroll');
  const t = el('table');
  const headRow = el('tr');
  columns.forEach((c) => add(headRow, el('th', null, c)));
  add(t, add(el('thead'), headRow));
  const body = el('tbody');
  rows.forEach((row) => add(body, buildRow(row)));
  return add(wrap, add(t, body));
}

export function cell(className, ...children) {
  return add(el('td', className), ...children);
}

export function section(label) {
  const node = el('section', 'section');
  add(node, el('span', 'eyebrow', label));
  return node;
}

// A group the operator can fold away. Native <details>, so the keyboard and
// screen-reader behaviour comes for free and the count stays readable while it
// is shut - folding is how a finished group stops crowding the page WITHOUT
// hiding that it is there.
export function foldable(label, count, open, onToggle) {
  const node = el('details', 'fold');
  node.open = open;
  const summary = el('summary', 'fold-head');
  add(summary, el('span', 'fold-mark'), el('span', 'eyebrow', label), el('span', 'fold-count', count));
  const body = el('div', 'fold-body');
  add(node, summary, body);
  node.addEventListener('toggle', () => onToggle(node.open));
  return { node, body };
}

// One row of mutually exclusive choices. `aria-pressed` carries the state, so the
// selection is not colour-only.
export function segmented(label, options, current, onPick) {
  const wrap = el('div', 'segmented');
  wrap.setAttribute('role', 'group');
  wrap.setAttribute('aria-label', label);
  for (const option of options) {
    const button = el('button', 'seg');
    button.type = 'button';
    button.setAttribute('aria-pressed', String(option.id === current));
    add(button, el('span', null, option.label));
    if (option.count !== null && option.count !== undefined) {
      add(button, el('span', 'seg-count', option.count));
    }
    button.addEventListener('click', () => onPick(option.id));
    add(wrap, button);
  }
  return wrap;
}

// --- controls that ASK rather than do ----------------------------------------

// The console's contract: no control on this page does anything destructive. A
// cleanup or trash control ENQUEUES a request, which reaches the dockmaster as an
// ordinary operator message and is run there under the usual gates.
//
// Two steps, always. The first click only STATES what will be asked and quotes
// the request verbatim; nothing is sent until the second. Built here so every
// call site inherits the same shape and the same promise.
export function askControl(spec) {
  const box = el('div', `ask${spec.kind === 'trash' ? ' ask-trash' : ''}`);

  const idle = () => {
    box.textContent = '';
    box.classList.remove('is-open');
    const button = el('button', 'btn btn-ask');
    button.type = 'button';
    add(button, el('span', null, spec.label));
    button.addEventListener('click', () => confirm());
    add(box, button);
  };

  const confirm = () => {
    box.textContent = '';
    // The layout around a confirm strip differs from the layout around a button;
    // the class is what lets it say so without the caller knowing.
    box.classList.add('is-open');
    const panel = el('div', 'ask-confirm');
    add(panel,
      el('p', 'ask-what', spec.confirm),
      el('p', 'ask-quote', spec.request),
      el('p', 'ask-promise', 'This page sends the request. It does not carry it out.'));
    const send = el('button', 'btn btn-send', 'Send the request');
    send.type = 'button';
    const cancel = el('button', 'btn btn-quiet', 'Cancel');
    cancel.type = 'button';
    cancel.addEventListener('click', idle);
    send.addEventListener('click', () => {
      send.disabled = true;
      cancel.disabled = true;
      spec.ask(spec.request).then(sent, (err) => {
        send.disabled = false;
        cancel.disabled = false;
        add(panel, el('p', 'ask-failed', `Not sent: ${err.message}`));
      });
    });
    add(panel, add(el('div', 'ask-actions'), send, cancel));
    add(box, panel);
  };

  const sent = () => {
    box.textContent = '';
    box.classList.remove('is-open');
    const done = el('p', 'ask-sent');
    add(done, lamp('brass'), el('span', null, 'Asked. It is in the conversation, waiting to be picked up.'));
    add(box, done);
  };

  idle();
  return box;
}

// A review archive's "Open" action: try the annotatable lavish session the
// crewmate reviewed the change in, falling back to the raw page when that
// surface is not available - `ctx.openReview` never rejects, it always
// resolves to what to do next. Two rests only, no spinner in between: the
// session either opens or it doesn't, and either way this click is answered.
export function reviewOpenControl(href, ctx) {
  const box = el('span', 'review-open');
  const button = el('button', 'link-btn', 'Open');
  button.type = 'button';
  const note = el('span', 'cell-sub cell-warn');
  button.addEventListener('click', () => {
    button.disabled = true;
    note.textContent = '';
    ctx.openReview(href).then((result) => {
      button.disabled = false;
      const url = result && result.url;
      window.open(url || href, '_blank', 'noopener,noreferrer');
      if (!url) note.textContent = 'Annotation unavailable; opened the page instead.';
    });
  });
  add(box, button, note);
  return box;
}

export function head(title, note) {
  const frag = document.createDocumentFragment();
  add(frag, el('h1', 'view-title', title));
  if (note) add(frag, el('p', 'view-note', note));
  add(frag, el('div', 'horizon'));
  return frag;
}

export function empty(headline, note) {
  const node = el('div', 'empty');
  add(node, el('p', 'empty-head', headline), el('p', 'empty-note', note));
  return node;
}

export const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

// A token with no word is a GAP IN THIS FILE, not something to print raw: the
// internal name is exactly what must not reach the screen, and the failure
// paths are where an unmapped token is most likely to turn up.
// tests/check-console.js pins that every token the collector can emit is here.
export const word = (map, token) => map[token] || 'Not known';
export const lookup = (map, key) => map[key] || ['neutral', 'Not known'];

// --- time --------------------------------------------------------------------

// Elapsed time is computed in the page, not baked into the document, so it
// stays true between refreshes instead of ageing into a lie.
export function ago(iso) {
  if (!iso) return '';
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return '';
  const seconds = Math.max(0, (Date.now() - then) / 1000);
  if (seconds < 90) return 'just now';
  const minutes = seconds / 60;
  if (minutes < 60) return `${Math.round(minutes)}m ago`;
  const hours = minutes / 60;
  if (hours < 48) return `${Math.round(hours)}h ago`;
  return `${Math.round(hours / 24)}d ago`;
}

export function hoursSince(iso) {
  const then = Date.parse(iso || '');
  return Number.isNaN(then) ? null : (Date.now() - then) / 3600000;
}

export function clockTime(iso) {
  const at = Date.parse(iso || '');
  if (Number.isNaN(at)) return '';
  return new Date(at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

// --- the operator's words ----------------------------------------------------

export const WORK_STATE = {
  in_progress: ['starboard', 'In progress'],
  ready_for_review: ['brass', 'Ready for your review'],
  queued: ['neutral', 'Not started'],
  blocked: ['brass', 'Stopped'],
  needs_decision: ['brass', 'Waiting on your answer'],
  paused: ['neutral', 'Paused'],
  failed: ['port', 'Failed'],
  done: ['neutral', 'Finished'],
  dropped: ['neutral', 'Dropped'],
  unknown: ['neutral', 'Not known'],
};

export const CHECKS = {
  passing: ['starboard', 'Green'],
  failing: ['port', 'Red'],
  pending: ['neutral', 'Running'],
  none: ['neutral', 'No checks'],
  unknown: ['neutral', 'Not known'],
};

export const REVIEW_VERDICT = {
  clean: 'No objections',
  'changes-requested': 'Changes requested',
  unknown: 'Not known',
};

// `never` is the load-bearing one: the toolbelt refuses to merge those repos at
// all, so the pull request is the operator's to land or nobody's.
export const AUTHORITY = {
  never: 'You merge, always',
  ask: 'Asks you first',
  yolo: 'The dockmaster may merge',
  invalid: 'Not known',
};

export const KIND = { change: 'Change', ship: 'Change', scout: 'Investigation' };

export const MODE = {
  pipeline: 'Through the full review pipeline',
  'direct-pr': 'Straight to a pull request',
  'local-only': 'Landed locally, no pull request',
};

export const CHECK_STATUS = {
  ok: ['starboard', 'Ready'],
  missing: ['brass', 'Missing'],
  fail: ['port', 'Broken'],
};

// What the tests gate recorded. `skip` is a real, registered outcome - the repo
// has no test command - not a failure and not a pass.
export const TESTS_RESULT = {
  pass: 'Tests passed',
  fail: 'Tests failed',
  skip: 'No tests registered',
};

// The pipeline track, in the operator's nouns. A key with no entry here would
// print raw, so every key trackKeys() can emit has one.
export const STAGE_LABEL = {
  dispatched: 'Picked up',
  building: 'Building',
  investigating: 'Digging',
  review: 'Your review',
  gates: 'Checking',
  pr: 'Pull request',
  merged: 'Merged',
  landed: 'Landed',
  report: 'Findings',
};

// What each mark claims. `not yet` and `not known` are DIFFERENT claims and the
// page must never render them alike - one is a position, the other an absence.
export const STAGE_STATE = {
  done: 'done',
  active: 'now',
  ahead: 'not yet',
  unknown: 'not known',
};

// What the console lost, in the operator's nouns. The document names a source
// with a token; the script behind it, its arguments and its stderr never cross,
// because a failure path is exactly where internal phrasing surfaces.
export const SOURCE_WORD = {
  repos: 'the managed repos',
  work: 'what the crew is working on',
  gate_track: 'the checks a change still has to clear',
  pull_requests: 'the pull requests',
  decisions: 'the open decisions',
  backlog: 'the backlog',
  review_pages: 'the review archive',
  clone_branch: 'which branch a repo is sitting on',
  memory: 'what the dockmaster remembers',
  local_copies: 'the local copies',
  health: 'the health check',
};

// --- what the page ASKS FOR --------------------------------------------------
//
// These strings are not labels: each one is ENQUEUED as an operator message and
// the dockmaster acts on it. So they are written as the operator would say it -
// plain, specific, and carrying the condition that makes the request safe.
// Keyed by the token the collector emits for each kind of clutter;
// tests/check-console.js pins that every kind it can emit has a sentence here.
export const CLEANUP_REQUEST = {
  finished_copies: (n) => `Cleanup request: clear the local copies left behind by finished work — ${n} of them. Nothing unlanded may be discarded; stop and tell me if any of them still hold work.`,
  orphan_copies: (n) => `Cleanup request: clear the ${n} leftover local copies that have no work behind them.`,
  landed_backlog: (n) => `Cleanup request: clear the ${n} landed rows out of the backlog.`,
};

// A title reaches here as free text from the work's own record, not something
// this page validated. Quoted verbatim inside the sentence, a stray newline or
// quote mark would break the sentence out of its quotes, and an unbounded title
// would make the transcript unreadable - so it is flattened and capped before
// it goes anywhere near the message.
const TITLE_MAX = 120;
function sanitizeTitle(title) {
  const flat = String(title).replace(/[\r\n"]+/g, ' ').trim();
  return flat.length > TITLE_MAX ? `${flat.slice(0, TITLE_MAX - 1)}…` : flat;
}

// The work is named the way the OPERATOR sees it - title, repo, state - because a
// task id is exactly what this seam keeps off the page. Unambiguous enough for
// the dockmaster to resolve, and readable in the transcript afterwards.
export const TRASH_REQUEST = (title, repo, stateWord) => `Trash request: drop the work "${sanitizeTitle(title)}" in ${repo} (currently ${String(stateWord).toLowerCase()}). It is deprecated — stop it, do not land it, and clear up after it. I authorize discarding it.`;

// A pull request that came back from the sweep unreadable. Kept in the list on
// purpose - one that vanished would read as a fleet with one less problem.
export const PR_UNREADABLE = {
  repo_missing: 'This repo is not set up on this machine, so nothing about it could be read.',
  github_unreadable: 'GitHub could not be read for this one.',
};
