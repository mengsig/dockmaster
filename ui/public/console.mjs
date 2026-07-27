/* console.mjs - the shell: which panel is showing, keeping it current, and
 * carrying the conversation with the dockmaster.
 *
 * The panels themselves are in views.mjs and every word is in dom.mjs. This file
 * owns the wiring and nothing about how the fleet is worded.
 *
 * Two things a control on this page may do, and no third: change what the page
 * SHOWS (a filter, a fold, the theme - kept here, in the browser), or ENQUEUE a
 * request as an ordinary operator message, which the dockmaster then carries out
 * under its usual gates. Nothing here acts on the fleet.
 */
'use strict';

import { el, add, lamp, plural, clockTime, word, SOURCE_WORD } from './dom.mjs';
import { VIEWS, needsWords } from './views.mjs';

const shell = {
  state: null,
  current: location.hash.replace('#', '') || 'needs',
  refreshing: false,
  readAt: 0,
  // The conversation, held here rather than inside the poll loop: the Updates
  // panel reads the same messages as a feed, and one store means the two can
  // never disagree about what was said.
  chat: { messages: [], since: 0, pending: 0 },
};

// --- what the operator chose to see ------------------------------------------

// Filters and folds are the operator's view of the page, not state about the
// fleet, so they live in the browser and survive a reload. A corrupt blob must
// not take the page down with it - it is discarded and the defaults stand.
const UI_KEY = 'dm-console-view';
const ui = { filter: 'all', folds: {} };

function loadUi() {
  let raw;
  try {
    raw = localStorage.getItem(UI_KEY);
  } catch (err) {
    return; // storage refused (private browsing); the defaults are fine
  }
  if (!raw) return;
  try {
    const saved = JSON.parse(raw);
    if (saved && typeof saved === 'object') {
      if (typeof saved.filter === 'string') ui.filter = saved.filter;
      if (saved.folds && typeof saved.folds === 'object') ui.folds = saved.folds;
    }
  } catch (err) {
    console.warn('console: the saved view settings could not be read; using the defaults');
  }
}

function saveUi() {
  try {
    localStorage.setItem(UI_KEY, JSON.stringify(ui));
  } catch (err) {
    // Not being able to remember a fold is not worth interrupting anyone over.
  }
}

// --- chrome ------------------------------------------------------------------

const byId = (id) => document.getElementById(id);

// The rail is redrawn on every read, so a count that MOVED is flashed once -
// otherwise a number quietly changing in the corner of the eye is the same as no
// notification at all. Keyed by view id, kept across redraws.
const railCounts = new Map();

function renderRail() {
  const rail = byId('rail');
  rail.textContent = '';
  let group = null;
  let container = null;
  for (const view of VIEWS) {
    if (view.group !== group) {
      group = view.group;
      container = add(rail, el('div', 'rail-group'));
      add(container, el('span', 'rail-group-label eyebrow', group));
    }
    const button = el('button', 'rail-item');
    button.type = 'button';
    add(button, el('span', 'rail-label', view.label));
    const n = view.count(shell.state);
    if (n !== null) {
      const moved = railCounts.has(view.id) && railCounts.get(view.id) !== n;
      const badge = el('span', `rail-count${view.urgent && n > 0 ? ' is-urgent' : ''}${moved ? ' is-bumped' : ''}`, n);
      add(button, badge);
      railCounts.set(view.id, n);
    }
    if (view.id === shell.current) button.setAttribute('aria-current', 'page');
    button.addEventListener('click', () => show(view.id));
    add(container, button);
  }
}

// The one-line summary. "all clear" is a claim about EVERYTHING, so it may only
// be made when everything was actually read - the same rule the Needs-you panel
// follows, in the line the operator glances at first.
function renderPulse() {
  const s = shell.state;
  const pulse = byId('pulse');
  pulse.textContent = '';
  const urgent = s.needs_you.length;
  const partial = s.degraded.length > 0;
  let headline = 'all clear';
  if (urgent > 0) headline = plural(urgent, 'thing needs you', 'things need you');
  else if (partial) headline = 'nothing else needs you';
  add(pulse, lamp(urgent > 0 || partial ? 'brass' : 'starboard'));
  add(pulse, el('span', null, headline));
  const parts = [
    plural(s.fleet.in_flight, 'change under way', 'changes under way'),
    // A count over a source that was never read is not a count. "0 open pull
    // requests" beside "2 things could not be read" is still the reassuring lie.
    s.degraded.some((d) => d.panel === 'prs')
      ? 'pull requests not read'
      : plural(s.fleet.open_prs, 'open pull request', 'open pull requests'),
    `as of ${clockTime(s.generated_at)}`,
  ];
  // Losing a source is never silent: it is stated beside the counts it affects.
  if (partial) parts.push(`${plural(s.degraded.length, 'thing', 'things')} could not be read`);
  for (const part of parts) add(pulse, el('span', 'sep', '·'), el('span', null, part));
}

// The beacon: what is at the top of the operator's queue, above every panel.
// Worded by views.mjs, so it says exactly what the Needs-you row for the same
// item says. Empty is not "hidden because we do not know" - the queue is
// assembled from sources that name themselves when they fail, and the pulse and
// the panel both carry that.
function renderBeacon() {
  const bar = byId('beacon');
  const s = shell.state;
  const items = s ? s.needs_you : [];
  if (items.length === 0) { bar.hidden = true; bar.textContent = ''; return; }
  bar.textContent = '';
  bar.hidden = false;
  const first = needsWords(items[0]);
  add(bar,
    add(el('div', 'beacon-lamp'), lamp('brass')),
    add(el('div', 'beacon-body'),
      el('p', 'beacon-head', first.head),
      el('p', 'beacon-note', items.length === 1
        ? 'This is stopped until you act.'
        : `${plural(items.length - 1, 'other thing is', 'other things are')} waiting too.`)),
    add(el('div', 'beacon-figure'), el('span', null, items.length)));
  const go = el('button', 'btn btn-beacon', items.length === 1 ? 'Take me to it' : 'Show me all of it');
  go.type = 'button';
  go.addEventListener('click', () => show('needs'));
  add(bar, go);
}

// A demo fleet the operator cannot tell from their own is the worst thing this
// page can be. It says so on screen, and in the tab title for a window left open.
function renderSource(source) {
  const demo = source === 'fixture';
  byId('demo-bar').hidden = !demo;
  document.title = demo ? 'dockmaster — demo fleet' : 'dockmaster';
}

// Everything a panel is allowed to do that is not drawing itself. Rebuilt per
// render, because the filter and the fold state it closes over are read, not
// watched.
function panelContext() {
  return {
    compose,
    ask: postMessage,
    openReview,
    filter: ui.filter,
    setFilter(id) {
      ui.filter = id;
      saveUi();
      show(shell.current, true, false);
    },
    fold(key, openByDefault) {
      return Object.prototype.hasOwnProperty.call(ui.folds, key) ? ui.folds[key] : openByDefault;
    },
    setFold(key, open) {
      ui.folds[key] = open;
      saveUi();
    },
    setFolds(keys, open) {
      for (const key of keys) ui.folds[key] = open;
      saveUi();
      show(shell.current, true, false);
    },
    // Only what the dockmaster said, newest first: the Updates panel is the
    // conversation read as a log, off the same store.
    updates: shell.chat.messages.filter((m) => m.from === 'dockmaster').slice().reverse(),
  };
}

// show(id, keepScroll, animate) - draw a panel.
//
// `animate` is off for a background redraw: the entrance runs on a NAVIGATION,
// where it explains that the content changed. Replaying it every 30 seconds under
// a reader who did not ask for anything is the definition of gratuitous.
function show(id, keepScroll, animate) {
  const view = VIEWS.find((v) => v.id === id) || VIEWS[0];
  shell.current = view.id;
  if (location.hash !== `#${view.id}`) history.replaceState(null, '', `#${view.id}`);
  // A panel jump before the first read has landed records WHERE to go and stops:
  // no panel can draw a fleet that has not been read yet, and the load in flight
  // renders this one when it arrives.
  if (!shell.state) return;
  const main = byId('view');
  const top = main.scrollTop;
  main.textContent = '';
  main.classList.toggle('is-entering', animate !== false);
  add(main, view.render(shell.state, panelContext()));
  // A background refresh must not throw the operator back to the top of a list.
  main.scrollTop = keepScroll ? top : 0;
  renderRail();
}

// A confirm strip is mid-decision: the panel showing it must not be replaced out
// from under the operator, and the pulse above it must not claim a freshness the
// frozen panel does not have either - "as of just now" beside a strip quoting a
// request from a minute ago is the page telling two different times at once.
const hasOpenConfirm = () => Boolean(byId('view').querySelector('.ask-confirm'));

function redraw() {
  if (hasOpenConfirm()) return;
  show(shell.current, true, false);
}

// The failure is worded HERE from the source token the server sent; the script
// that failed, its arguments and its stderr stay in the console's own log.
function failureReason(err) {
  if (err.source) return `Could not read ${word(SOURCE_WORD, err.source)}.`;
  if (err.offline) return 'The page could not reach the console.';
  return 'The reason is in the console’s log; ask the dockmaster to look.';
}

function showFailure(err) {
  const main = byId('view');
  main.textContent = '';
  const box = el('div', 'failure');
  add(box,
    el('p', 'failure-head', 'The console could not read the fleet.'),
    el('p', 'failure-body', failureReason(err)),
    el('p', 'failure-body',
      'Nothing here is a statement about your work — it is this page failing to load it.'));
  add(main, box);
}

// --- keeping it current ------------------------------------------------------

// The page re-reads on its own; the server holds each collection so an open tab
// costs one cheap request per interval. The PR sweep is on a much longer cache
// than local state, and `Refresh` is what forces both.
const REFRESH_MS = 30000;

// A re-read that FAILED is announced in its own banner, not in the chat row: the
// chat poll writes that row every few seconds and would erase the warning while
// the page went on showing stale numbers as if they were current.
function setStale(err) {
  const bar = byId('stale');
  if (!err) { bar.hidden = true; return; }
  const at = shell.state ? clockTime(shell.state.generated_at) : '';
  bar.hidden = false;
  byId('stale-text').textContent = shell.state
    ? `Not re-read. ${failureReason(err)} Still showing ${at}.`
    : `Not read. ${failureReason(err)}`;
}

async function loadState(keepScroll, force) {
  let response;
  try {
    response = await fetch(`/api/state${force ? '?refresh=1' : ''}`);
  } catch (err) {
    throw Object.assign(new Error(err.message), { offline: true });
  }
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    // `source` is a token this page words. The server's own `error` string is
    // written for the log - it names scripts and paths - so it is never shown.
    throw Object.assign(new Error(`the console answered ${response.status}`),
      { source: body.source || '' });
  }
  shell.state = body;
  shell.readAt = Date.now();
  setStale(null);
  renderSource(body.source);
  // A confirm strip freezes the panel (see redraw()); the pulse's "as of" and the
  // beacon must freeze with it, or the bar above claims data fresher than what
  // the operator is actually looking at.
  if (!hasOpenConfirm()) { renderPulse(); renderBeacon(); }
  if (keepScroll) redraw();
  else show(shell.current, false, true);
}

async function refreshNow() {
  if (shell.refreshing) return;
  shell.refreshing = true;
  const button = byId('refresh');
  // The watch line under the top bar runs while this is out: re-reading the
  // fleet takes seconds, and a control that looks like nothing happened is worse
  // than a slow one.
  document.body.classList.add('is-refreshing');
  button.disabled = true;
  try {
    await loadState(true, true);
  } catch (err) {
    if (shell.state) setStale(err);
    else showFailure(err);
  } finally {
    shell.refreshing = false;
    document.body.classList.remove('is-refreshing');
    button.disabled = false;
  }
}

// --- conversation ------------------------------------------------------------

// A dockmaster status line is one short line. It gets a feed row - a stamp and
// the text - because twenty of those read as a log while twenty full messages
// read as noise. Anything longer keeps its header and its own measure.
const TERSE_MAX_CHARS = 140;
const isTerse = (message) => message.from === 'dockmaster'
  && message.text.indexOf('\n') === -1 && message.text.length <= TERSE_MAX_CHARS;

function renderMessage(message, animate) {
  const terse = isTerse(message);
  const node = el('div', `msg msg-${message.from}${terse ? ' msg-terse' : ''}${animate ? ' is-new' : ''}`);
  if (terse) {
    add(node, el('span', 'msg-at', clockTime(message.at)), el('p', 'msg-text', message.text));
    return node;
  }
  const header = el('div', 'msg-head');
  add(header,
    el('span', 'msg-from', message.from === 'operator' ? 'You' : 'Dockmaster'),
    el('span', 'msg-at', clockTime(message.at)));
  add(node, header, el('p', 'msg-text', message.text));
  return node;
}

// How many messages stay in the open log. The rest folds into the archive above
// it - still there, still readable, no longer a wall to scroll past.
const LOG_OPEN = 40;

// A tab left open for days must not grow this without bound: it is a
// convenience feed of what happened in THIS tab, not the record of the
// conversation - the transcript on disk is that. Oldest drop first once it's
// past this, same as the DOM log below.
const MESSAGES_KEPT = 2000;

function compactLog() {
  const messages = byId('chat-messages');
  const body = byId('chat-archive-body');
  while (messages.children.length > LOG_OPEN) body.appendChild(messages.firstChild);
  byId('chat-archive').hidden = body.children.length === 0;
  byId('chat-archive-count').textContent = String(body.children.length);
}

// The pending row is the LIVE state of the conversation - how many messages are
// unpicked-up, or that the connection is down. Both are transient and correctly
// overwritten by the next poll.
function renderPending(count, unreadable) {
  const row = byId('chat-pending');
  const parts = [];
  if (count > 0) parts.push(`${plural(count, 'message', 'messages')} waiting for the dockmaster to pick up.`);
  if (unreadable > 0) parts.push(`${plural(unreadable, 'earlier line', 'earlier lines')} of this conversation could not be read.`);
  row.hidden = parts.length === 0;
  byId('chat-pending-text').textContent = parts.join(' ');
  // With the conversation closed on a narrow deck, the toggle is the only place
  // this can be said at all.
  byId('chat-toggle').textContent = count > 0 ? `Chat · ${count}` : 'Chat';
}

function renderPendingError(message) {
  const row = byId('chat-pending');
  row.hidden = false;
  byId('chat-pending-text').textContent = `Not connected: ${message}. Retrying.`;
  // The last known count is no longer a claim this page can stand behind - left
  // up, it reads as still live. Drop it rather than show a number that might
  // already be wrong.
  byId('chat-toggle').textContent = 'Chat';
}

// A refused send is NOT transient - the message is back in the composer waiting
// on the operator - so it gets a row the poll loop never touches.
function setSendError(message) {
  const row = byId('chat-error');
  row.hidden = !message;
  row.textContent = message || '';
}

// One long-poll, forever: the request stays open until something changes, so the
// page is live without a busy loop. `since` survives an error, so a reconnect
// never replays what is already on screen.
async function pumpChat() {
  const log = byId('chat-log');
  const messages = byId('chat-messages');
  let first = true;
  let backoff = 1000;
  for (;;) {
    try {
      // The FIRST read does not wait: an empty transcript would otherwise hold
      // the request open and leave the panel blank for the whole poll window.
      //
      // `pending` is what THIS page currently shows. Sending it is what makes the
      // waiting count race-free: the server answers the moment reality differs
      // from what is on screen, rather than from whatever it happened to read
      // when the request arrived.
      const response = await fetch(`/api/chat?since=${shell.chat.since}`
        + `&pending=${shell.chat.pending}${first ? '' : '&wait=1'}`);
      const body = await response.json();
      // The server's message names files and scripts; the status does not.
      if (!response.ok) throw new Error(`the console answered ${response.status}`);
      const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 60;
      if (body.messages.length) {
        byId('chat-empty').hidden = true;
        body.messages.forEach((m) => {
          shell.chat.messages.push(m);
          add(messages, renderMessage(m, !first));
        });
        if (shell.chat.messages.length > MESSAGES_KEPT) {
          shell.chat.messages.splice(0, shell.chat.messages.length - MESSAGES_KEPT);
        }
        // Compacting moves nodes off the top, which shifts what a reader scrolled
        // up is looking at. So it waits until they are back at the bottom.
        if (atBottom || first) {
          compactLog();
          log.scrollTop = log.scrollHeight;
        }
        // The Updates panel is this same store read as a feed.
        if (shell.state && shell.current === 'updates') redraw();
      }
      shell.chat.since = body.total;
      shell.chat.pending = body.pending;
      first = false;
      renderPending(body.pending, body.unreadable || 0);
      backoff = 1000;
    } catch (err) {
      // Losing the server is a state the operator must see, not a silent stall.
      renderPendingError(err.message);
      await new Promise((resolve) => setTimeout(resolve, backoff));
      backoff = Math.min(backoff * 2, 15000);
    }
  }
}

function compose(text) {
  const input = byId('chat-input');
  input.value = text;
  if (window.matchMedia('(max-width: 78rem)').matches) setChatOpen(true);
  input.focus();
  growComposer();
}

// Why a message was refused, worded here. The server's own text names files and
// scripts, so the status is what crosses - 403/415 mean the request did not
// come from this page at all, which the operator cannot cause and cannot fix.
const SEND_REFUSAL = {
  400: 'the console would not accept it. If it is very long, try a shorter one.',
  413: 'it is too long to send.',
  403: 'the console refused it — that request did not come from this page.',
  415: 'the console refused it — that request did not come from this page.',
  500: 'the console could not store it. Ask the dockmaster to look into it.',
};

// The ONE way anything leaves this page: as an operator message on the same queue
// the composer uses. A cleanup or trash control goes through here too, so nothing
// on the page has a shorter path to the dockmaster than a typed sentence does.
// Rejects with an already-worded reason.
async function postMessage(text) {
  let response;
  try {
    response = await fetch('/api/chat', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ text }),
    });
  } catch (err) {
    throw new Error(`the console could not be reached (${err.message}).`);
  }
  // An unmapped status falls back to the number, which is honest and is not
  // internal vocabulary - never to the server's own sentence.
  if (!response.ok) {
    throw new Error(SEND_REFUSAL[response.status] || `the console answered ${response.status}.`);
  }
}

// openReview(href) -> { url } for the lavish session behind this review, or
// { url: null } on ANY failure - offline, a non-JSON answer, the server's own
// degrade. This never rejects: the control it feeds always has something to do
// (open the returned url, or fall back to `href`), never an error to handle.
async function openReview(href) {
  const id = href.replace(/^\/review\//, '').replace(/\/+$/, '');
  try {
    const response = await fetch(`/api/review-open?id=${encodeURIComponent(id)}`);
    if (!response.ok) return { url: null };
    const body = await response.json();
    return { url: typeof body.url === 'string' ? body.url : null };
  } catch (err) {
    return { url: null };
  }
}

async function sendMessage(event) {
  event.preventDefault();
  const input = byId('chat-input');
  const text = input.value.trim();
  if (!text) return;
  input.value = '';
  growComposer();
  try {
    await postMessage(text);
    setSendError('');
  } catch (err) {
    // The message goes back into the composer on any failure, so nothing the
    // operator typed is lost to a refusal or a dropped connection.
    input.value = text;
    growComposer();
    setSendError(`Not sent: ${err.message}`);
  }
}

// The composer grows with the message instead of making the operator write a
// paragraph through a three-line slot.
const COMPOSER_MAX_PX = 260;
function growComposer() {
  const input = byId('chat-input');
  input.style.height = 'auto';
  input.style.height = `${Math.min(input.scrollHeight, COMPOSER_MAX_PX)}px`;
}

// --- theme and layout --------------------------------------------------------

function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  byId('theme-toggle').textContent = theme === 'dark' ? 'Light' : 'Dark';
  localStorage.setItem('dm-console-theme', theme);
}

function setChatOpen(open) {
  byId('chat').classList.toggle('is-open', open);
  byId('chat-toggle').setAttribute('aria-expanded', String(open));
  byId('scrim').hidden = !open;
}

// Focus gives the conversation the whole deck. It is a layout class on <body>,
// never a transform on a container: a transformed ancestor would capture any
// position:fixed descendant and re-anchor it away from the viewport.
function setFocus(on) {
  document.body.classList.toggle('is-focused', on);
  const button = byId('focus-toggle');
  button.setAttribute('aria-pressed', String(on));
  button.textContent = on ? 'Show the fleet' : 'Focus the chat';
  localStorage.setItem('dm-console-focus', on ? '1' : '0');
}

function wire() {
  loadUi();
  // Shown until the first read proves otherwise, so an empty conversation reads
  // as an invitation rather than a blank panel.
  byId('chat-empty').hidden = false;
  applyTheme(localStorage.getItem('dm-console-theme')
    || (window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'));
  setFocus(localStorage.getItem('dm-console-focus') === '1');
  byId('theme-toggle').addEventListener('click', () => {
    applyTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark');
  });
  byId('focus-toggle').addEventListener('click', () => {
    setFocus(!document.body.classList.contains('is-focused'));
  });
  byId('refresh').addEventListener('click', refreshNow);
  byId('chat-toggle').addEventListener('click', () => setChatOpen(true));
  byId('chat-close').addEventListener('click', () => setChatOpen(false));
  byId('scrim').addEventListener('click', () => setChatOpen(false));
  byId('chat-form').addEventListener('submit', sendMessage);
  byId('chat-input').addEventListener('input', () => { setSendError(''); growComposer(); });
  byId('chat-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(e); }
  });
  window.addEventListener('hashchange', () => {
    const id = location.hash.replace('#', '') || 'needs';
    if (id !== shell.current) show(id, false, true);
  });
}

// A background read is never silent about failing, but it must not blow away a
// page that is already rendered - it marks it stale instead.
function reload() {
  loadState(true, false).catch((err) => {
    if (shell.state) setStale(err);
    else showFailure(err);
  });
}

wire();
loadState(false, false).catch((err) => showFailure(err));

// Re-reading the fleet runs the toolbelt and sweeps every open pull request -
// which WRITES what it learns and takes the same lock the crew does. A tab left
// open behind another window must not drive that all day, so a hidden page does
// not refresh; it catches up the moment it is looked at again.
setInterval(() => { if (!document.hidden) reload(); }, REFRESH_MS);
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && Date.now() - shell.readAt >= REFRESH_MS) reload();
});
pumpChat();

// Relative ages ("3d ago", "quiet 6h") are computed at render time, so a page
// left open all afternoon would keep showing this morning's numbers without a
// re-render. Cheap, and it keeps the one thing that silently rots honest.
setInterval(() => { if (shell.state && !document.hidden) redraw(); }, 60000);
