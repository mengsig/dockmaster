/* console.js - renders the console state document and carries the conversation.
 *
 * Everything on screen is built with textContent, never assembled HTML: repo
 * names, titles and chat text all arrive from disk and are treated as text.
 *
 * The internal vocabulary stops at this file. Nothing below prints a task id, a
 * local-copy path, or a machine state name - each one is translated here into
 * the words the operator uses.
 */
'use strict';

// --- tiny DOM helpers --------------------------------------------------------

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}

function add(parent, ...children) {
  for (const child of children) if (child) parent.appendChild(child);
  return parent;
}

function lamp(kind) {
  const node = el('span', `lamp lamp-${kind}`);
  node.setAttribute('aria-hidden', 'true');
  return node;
}

// A lamp never travels alone: the written state is the accessible carrier and
// the colour is the fast one.
function stateCell(kind, label) {
  return add(el('span', 'state'), lamp(kind), el('span', null, label));
}

function meta(...parts) {
  const line = el('p', 'berth-meta');
  parts.filter(Boolean).forEach((part, i) => {
    if (i > 0) add(line, el('span', 'mono mono-mute', '·'));
    add(line, el('span', 'mono', part));
  });
  return line;
}

// --- the operator's vocabulary ----------------------------------------------

const WORK_STATE = {
  in_progress: ['starboard', 'In progress'],
  ready_for_review: ['brass', 'Ready for your review'],
  queued: ['neutral', 'Queued'],
  done: ['neutral', 'Finished'],
  dropped: ['neutral', 'Dropped'],
};
const CHECKS = {
  passing: ['starboard', 'Green'],
  failing: ['port', 'Red'],
  pending: ['neutral', 'Running'],
  unknown: ['neutral', 'Not known'],
};
const MERGE = {
  you: ['brass', 'Yours to merge'],
  dockmaster: ['starboard', 'Dockmaster merges'],
  blocked: ['neutral', 'Not ready'],
};
const AUTHORITY = {
  never: 'You merge, always',
  ask: 'Asks you first',
  yolo: 'The dockmaster may merge',
};
const SYNC = {
  current: ['starboard', 'Up to date'],
  behind: ['brass', 'Behind origin'],
  stuck: ['port', 'Stuck'],
};
const KIND = { change: 'Change', investigation: 'Investigation' };
const CHECK_STATUS = { ok: ['starboard', 'Ready'], warn: ['brass', 'Missing'], fail: ['port', 'Broken'] };

const pluralise = (n, one, many) => `${n} ${n === 1 ? one : many}`;
const lookup = (table, key) => table[key] || ['neutral', key];

// --- view scaffolding --------------------------------------------------------

function head(title, note) {
  const frag = document.createDocumentFragment();
  add(frag, el('h1', 'view-title', title));
  if (note) add(frag, el('p', 'view-note', note));
  add(frag, el('div', 'horizon'));
  return frag;
}

function section(label) {
  const node = el('section', 'section');
  add(node, el('span', 'eyebrow', label));
  return node;
}

function empty(headline, note) {
  const node = el('div', 'empty');
  add(node, el('p', 'empty-head', headline), el('p', 'empty-note', note));
  return node;
}

function table(columns, rows, buildRow) {
  const wrap = el('div', 'scroll');
  const t = el('table');
  const headRow = el('tr');
  columns.forEach((c) => add(headRow, el('th', null, c)));
  add(t, add(el('thead'), headRow));
  const body = el('tbody');
  rows.forEach((row) => add(body, buildRow(row)));
  return add(wrap, add(t, body));
}

function cell(className, ...children) {
  return add(el('td', className), ...children);
}

// --- views -------------------------------------------------------------------

function berth(item) {
  const row = el('div', 'berth');
  const body = el('div');
  add(body,
    meta(item.state, item.repo, item.age),
    el('p', 'berth-head', item.headline),
    el('p', 'berth-detail', item.detail));
  if (item.action) {
    const link = el('a', 'berth-action', item.action.label);
    link.href = item.action.href;
    if (!item.action.href.startsWith('#')) { link.target = '_blank'; link.rel = 'noreferrer'; }
    add(body, link);
  }
  return add(row, lamp(item.lamp), body);
}

function viewNeedsYou(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('Needs you', 'Everything below is stopped until you act. Nothing else is listed here.'));

  if (state.needs_you.length === 0) {
    add(frag, empty('All clear.',
      `Nothing needs you right now. ${pluralise(state.fleet.in_flight, 'change is', 'changes are')} in progress.`));
    return frag;
  }
  const hero = el('div', 'hero');
  add(hero, el('span', 'hero-figure', state.needs_you.length), el('span', 'hero-label', 'waiting on you'));
  add(frag, hero);
  const berths = el('div', 'berths');
  state.needs_you.forEach((item) => add(berths, berth(item)));
  add(frag, berths);
  return frag;
}

function viewWork(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('Work', 'Every change and investigation the crew has open, and what each one is waiting for.'));

  const groups = [
    ['In progress', 'in_progress'],
    ['Ready for your review', 'ready_for_review'],
    ['Queued', 'queued'],
    ['Recently finished', 'done'],
    ['Dropped', 'dropped'],
  ];
  for (const [label, key] of groups) {
    const rows = state.work.filter((w) => w.state === key);
    if (rows.length === 0) continue;
    const node = section(`${label} · ${rows.length}`);
    // Kind is not a column: almost every row is a change, so it earns its space
    // only on the exceptions.
    add(node, table(['What', 'Repo', 'Started', 'Waiting on'], rows, (w) => {
      const what = cell('cell-title', el('span', null, w.title));
      if (w.kind !== 'change') add(what, el('span', 'cell-sub', KIND[w.kind] || w.kind));
      return add(el('tr'),
        what,
        cell('mono nowrap', el('span', null, w.repo)),
        cell('mono nowrap', el('span', null, w.since)),
        cell(null, el('span', w.blocker ? '' : 'mono mono-mute', w.blocker || '—')));
    }));
    add(frag, node);
  }
  return frag;
}

function viewPullRequests(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('Pull requests',
    'Every pull request the crew has open, with who is allowed to merge it.'));
  if (state.prs.length === 0) {
    add(frag, empty('No open pull requests.', 'Nothing is waiting to land.'));
    return frag;
  }
  // Merging sits second on purpose: who is allowed to land this is the column
  // the operator came for, so it must survive a narrow window.
  add(frag, table(['What', 'Merging', 'Checks', 'Review', 'Repo'], state.prs, (pr) => {
    const [checkLamp, checkLabel] = lookup(CHECKS, pr.checks);
    const [mergeLamp, mergeLabel] = lookup(MERGE, pr.merge);
    const title = cell('cell-title col-what');
    const link = el('a', null, pr.title);
    link.href = pr.url; link.target = '_blank'; link.rel = 'noreferrer';
    add(title, link, el('span', 'cell-sub link-url', pr.url));
    add(title, el('span', 'cell-sub', pr.blocker ? `${pr.blocker} · open ${pr.age}` : `Open ${pr.age}`));
    return add(el('tr'),
      title,
      cell('nowrap', stateCell(mergeLamp, mergeLabel)),
      cell('nowrap', stateCell(checkLamp, checkLabel), el('span', 'cell-sub mono', pr.checks_detail)),
      cell('nowrap', el('span', null, pr.reviews)),
      cell('mono nowrap', el('span', null, pr.repo)));
  }));
  return frag;
}

function viewDecisions(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('Decisions', 'Questions only you can answer. They stay open until you do.'));

  const open = section(`Open · ${state.decisions.open.length}`);
  if (state.decisions.open.length === 0) {
    add(open, empty('Nothing is waiting on you.', 'Every question the crew raised has an answer.'));
  } else {
    const berths = el('div', 'berths');
    state.decisions.open.forEach((d) => {
      const body = el('div');
      add(body,
        meta(d.repo, `open ${d.age}`),
        el('p', 'berth-head', d.question),
        el('p', 'berth-detail', d.detail));
      if (d.options) {
        const choices = el('div', 'choices');
        // The answer goes into the composer rather than straight out: the
        // operator confirms or edits it, and the reply is an ordinary message.
        d.options.forEach((option) => {
          const button = el('button', 'btn choice', option);
          button.type = 'button';
          button.addEventListener('click', () => compose(`${d.question} — ${option}`));
          add(choices, button);
        });
        add(body, choices);
      }
      add(berths, add(el('div', 'berth'), lamp('brass'), body));
    });
    add(open, berths);
  }
  add(frag, open);

  const done = section(`Answered · ${state.decisions.resolved.length}`);
  add(done, table(['Question', 'Your answer', 'Repo', 'When'], state.decisions.resolved, (d) => add(el('tr'),
    cell('cell-title', el('span', null, d.question)),
    cell(null, el('span', null, d.answer)),
    cell('mono nowrap', el('span', null, d.repo)),
    cell('mono nowrap', el('span', null, d.at)))));
  add(frag, done);
  return frag;
}

function viewBacklog(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('Backlog', 'What the crew is on, what is next, and what has landed.'));
  const groups = [
    ['In flight', state.backlog.in_flight],
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
        cell('mono nowrap', el('span', null, item.repo)),
        cell(null, el('span', item.blocked_by ? '' : 'mono mono-mute', item.blocked_by || '—')))));
    }
    add(frag, node);
  }
  return frag;
}

function viewRepos(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('Repos', 'What the dockmaster manages, how work lands, and what it has learned about each one.'));
  state.repos.forEach((repo) => add(frag, repoBlock(repo)));
  return frag;
}

// One repo is one entity, not a one-row table: a key/value block reads calmer
// and does not repeat a header per repo.
function repoBlock(repo) {
  const [syncLamp, syncLabel] = lookup(SYNC, repo.sync);
  const node = el('section', 'repo');
  const header = el('div', 'repo-head');
  add(header, el('span', 'repo-name', repo.name), stateCell(syncLamp, syncLabel));
  add(node, header);

  const facts = el('dl', 'facts');
  [
    ['Merging', AUTHORITY[repo.authority] || repo.authority, false],
    ['Branch', repo.branch, true],
    ['Tests', repo.test_cmd || 'none registered', true],
    ['Local copies', `${repo.copies} · ${repo.disk}`, true],
    ['Remote', repo.remote, true],
  ].forEach(([term, value, isMono]) => {
    add(facts, el('dt', 'eyebrow', term), el('dd', isMono ? 'mono' : null, value));
  });
  add(node, facts);

  if (repo.notes && repo.notes.length) {
    add(node, el('span', 'eyebrow', 'What the dockmaster remembers'));
    const list = el('ul', 'note-list');
    repo.notes.forEach((n) => add(list, el('li', null, n)));
    add(node, list);
  }
  return node;
}

function viewReviews(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('Reviews', 'Every review page the crew has produced. They stay openable after the work lands.'));
  if (state.reviews.length === 0) {
    add(frag, empty('No review pages yet.', 'One appears here each time a change is ready for you.'));
    return frag;
  }
  add(frag, table(['What', 'Repo', 'State', 'Rendered', ''], state.reviews, (r) => {
    const open = el('a', null, 'Open');
    open.href = r.href;
    const awaiting = r.state === 'awaiting';
    return add(el('tr'),
      cell('cell-title', el('span', null, r.title)),
      cell('mono nowrap', el('span', null, r.repo)),
      cell('nowrap', stateCell(awaiting ? 'brass' : 'neutral', awaiting ? 'Waiting for you' : 'You reviewed it')),
      cell('mono nowrap', el('span', null, r.at)),
      cell('nowrap', open));
  }));
  return frag;
}

function viewHealth(state) {
  const frag = document.createDocumentFragment();
  add(frag, head('Health', 'Whether the dockmaster can do its job, and what it would like to tidy up.'));

  const hero = el('div', 'hero');
  add(hero, el('span', 'hero-figure', state.health.verdict), el('span', 'hero-label', 'to take on work'));
  add(frag, hero);

  const tools = section('Tools');
  add(tools, table(['Tool', 'State', 'Detail'], state.health.checks, (c) => {
    const [kind, label] = lookup(CHECK_STATUS, c.status);
    return add(el('tr'),
      cell('cell-title', el('span', null, c.name)),
      cell('nowrap', stateCell(kind, label)),
      cell('mono', el('span', null, c.note)));
  }));
  add(frag, tools);

  const housekeeping = section('Worth tidying');
  add(housekeeping, table(['What', 'How many', 'Detail'], state.health.cleanup.concat(state.health.sizing), (c) => add(el('tr'),
    cell('cell-title', el('span', null, c.label)),
    cell('mono num nowrap', el('span', null, c.count)),
    cell(null, el('span', null, c.note)))));
  add(frag, housekeeping);
  return frag;
}

const VIEWS = [
  { id: 'needs', label: 'Needs you', group: 0, urgent: true, render: viewNeedsYou, count: (s) => s.needs_you.length },
  { id: 'work', label: 'Work', group: 1, render: viewWork, count: (s) => s.work.filter((w) => w.state !== 'done' && w.state !== 'dropped').length },
  { id: 'prs', label: 'Pull requests', group: 1, render: viewPullRequests, count: (s) => s.prs.length },
  { id: 'decisions', label: 'Decisions', group: 1, render: viewDecisions, count: (s) => s.decisions.open.length },
  { id: 'backlog', label: 'Backlog', group: 1, render: viewBacklog, count: (s) => s.backlog.in_flight.length + s.backlog.queued.length },
  { id: 'repos', label: 'Repos', group: 2, render: viewRepos, count: (s) => s.repos.length },
  { id: 'reviews', label: 'Reviews', group: 2, render: viewReviews, count: (s) => s.reviews.filter((r) => r.state === 'awaiting').length },
  { id: 'health', label: 'Health', group: 2, render: viewHealth, count: () => null },
];

// --- shell -------------------------------------------------------------------

const shell = {
  state: null,
  current: location.hash.replace('#', '') || 'needs',
};

function renderRail() {
  const rail = document.getElementById('rail');
  rail.textContent = '';
  let group = null;
  let container = null;
  for (const view of VIEWS) {
    if (view.group !== group) {
      group = view.group;
      container = add(rail, el('div', 'rail-group'));
    }
    const button = el('button', 'rail-item');
    button.type = 'button';
    add(button, el('span', 'rail-label', view.label));
    const n = view.count(shell.state);
    if (n !== null) add(button, el('span', `rail-count${view.urgent && n > 0 ? ' is-urgent' : ''}`, n));
    if (view.id === shell.current) button.setAttribute('aria-current', 'page');
    button.addEventListener('click', () => show(view.id));
    add(container, button);
  }
}

function renderPulse() {
  const s = shell.state;
  const pulse = document.getElementById('pulse');
  pulse.textContent = '';
  const urgent = s.needs_you.length;
  add(pulse, lamp(urgent > 0 ? 'brass' : 'starboard'));
  add(pulse, el('span', null, urgent > 0 ? pluralise(urgent, 'thing needs you', 'things need you') : 'all clear'));
  const at = new Date(s.generated_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  [
    pluralise(s.fleet.in_flight, 'change in flight', 'changes in flight'),
    pluralise(s.fleet.open_prs, 'open pull request', 'open pull requests'),
    pluralise(s.fleet.repos, 'repo', 'repos'),
    `as of ${at}`,
  ].forEach((part) => {
    add(pulse, el('span', 'sep', '·'), el('span', null, part));
  });
}

function show(id, keepScroll) {
  const view = VIEWS.find((v) => v.id === id) || VIEWS[0];
  shell.current = view.id;
  if (location.hash !== `#${view.id}`) history.replaceState(null, '', `#${view.id}`);
  const main = document.getElementById('view');
  const top = main.scrollTop;
  main.textContent = '';
  add(main, view.render(shell.state));
  // A background refresh must not throw the operator back to the top of a list.
  if (keepScroll) main.scrollTop = top;
  else window.scrollTo(0, 0);
  renderRail();
}

function showFailure(message) {
  const main = document.getElementById('view');
  main.textContent = '';
  const box = el('div', 'failure');
  add(box,
    el('p', 'failure-head', 'The console could not read the fleet.'),
    el('p', 'failure-body', message),
    el('p', 'failure-body', 'Nothing here is a statement about your work - it is this page failing to load it.'));
  add(main, box);
}

async function loadState(keepScroll) {
  const response = await fetch('/api/state');
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || `the server answered ${response.status}`);
  shell.state = body;
  renderPulse();
  show(shell.current, keepScroll);
}

// The console is a window on live work, so it re-reads on its own. The server
// caches the collection, so an open page costs one cheap request per interval.
const REFRESH_MS = 30000;
function refreshForever() {
  setInterval(() => {
    loadState(true).catch((err) => renderPendingError(err.message));
  }, REFRESH_MS);
}

// --- conversation ------------------------------------------------------------

function renderMessage(message) {
  const node = el('div', `msg msg-${message.from}`);
  const header = el('div', 'msg-head');
  add(header,
    el('span', 'msg-from', message.from === 'operator' ? 'You' : 'Dockmaster'),
    el('span', 'msg-at', new Date(message.at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })));
  add(node, header, el('p', 'msg-text', message.text));
  return node;
}

function renderPending(count) {
  const row = document.getElementById('chat-pending');
  row.hidden = count === 0;
  document.getElementById('chat-pending-text').textContent =
    count === 0 ? '' : `${pluralise(count, 'message', 'messages')} waiting for the dockmaster.`;
}

async function pumpChat() {
  const log = document.getElementById('chat-log');
  let since = 0;
  let backoff = 1000;
  for (;;) {
    try {
      const response = await fetch(`/api/chat?since=${since}&wait=1`);
      const body = await response.json();
      if (!response.ok) throw new Error(body.error || `the server answered ${response.status}`);
      const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
      body.messages.forEach((m) => add(log, renderMessage(m)));
      if (body.messages.length && atBottom) log.scrollTop = log.scrollHeight;
      since = body.total;
      renderPending(body.pending);
      backoff = 1000;
    } catch (err) {
      // Losing the server is a state the operator must see, not a silent stall.
      renderPendingError(err.message);
      await new Promise((resolve) => setTimeout(resolve, backoff));
      backoff = Math.min(backoff * 2, 15000);
    }
  }
}

function renderPendingError(message) {
  const row = document.getElementById('chat-pending');
  row.hidden = false;
  document.getElementById('chat-pending-text').textContent = `Not connected: ${message}. Retrying.`;
}

function compose(text) {
  const input = document.getElementById('chat-input');
  input.value = text;
  if (window.matchMedia('(max-width: 75rem)').matches) setChatOpen(true);
  input.focus();
}

async function sendMessage(event) {
  event.preventDefault();
  const input = document.getElementById('chat-input');
  const text = input.value.trim();
  if (!text) return;
  input.value = '';
  const response = await fetch('/api/chat', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ text }),
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    input.value = text;
    renderPendingError(body.error || `the server answered ${response.status}`);
  }
}

// --- chrome ------------------------------------------------------------------

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  document.getElementById('theme-toggle').textContent = theme === 'dark' ? 'Light' : 'Dark';
  localStorage.setItem('dm-console-theme', theme);
}

function setChatOpen(open) {
  document.getElementById('chat').classList.toggle('is-open', open);
  document.getElementById('chat-toggle').setAttribute('aria-expanded', String(open));
  document.getElementById('scrim').hidden = !open;
}

function wire() {
  applyTheme(localStorage.getItem('dm-console-theme')
    || (window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'));
  document.getElementById('theme-toggle').addEventListener('click', () => {
    applyTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark');
  });
  document.getElementById('chat-toggle').addEventListener('click', () => setChatOpen(true));
  document.getElementById('chat-close').addEventListener('click', () => setChatOpen(false));
  document.getElementById('scrim').addEventListener('click', () => setChatOpen(false));
  document.getElementById('chat-form').addEventListener('submit', sendMessage);
  document.getElementById('chat-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(e); }
  });
  window.addEventListener('hashchange', () => show(location.hash.replace('#', '') || 'needs'));
}

wire();
loadState(false).catch((err) => showFailure(err.message));
refreshForever();
pumpChat();
