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

export function link(href, text, className) {
  const node = el('a', className, text);
  node.href = href;
  // Only an external destination opens away from the console; an in-page
  // anchor that stole a tab would be a bug, not a convenience.
  if (/^https?:/.test(href)) { node.target = '_blank'; node.rel = 'noreferrer'; }
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
export const lookup = (map, key) => map[key] || ['neutral', key];

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
