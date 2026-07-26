/* console.mjs - the shell: which panel is showing, keeping it current, and
 * carrying the conversation with the dockmaster.
 *
 * The panels themselves are in views.mjs and every word is in dom.mjs. This file
 * owns the wiring and nothing about how the fleet is worded.
 */
'use strict';

import { el, add, lamp, plural, clockTime, word, SOURCE_WORD } from './dom.mjs';
import { VIEWS } from './views.mjs';

const shell = {
  state: null,
  current: location.hash.replace('#', '') || 'needs',
  refreshing: false,
  readAt: 0,
};

// --- chrome ------------------------------------------------------------------

const byId = (id) => document.getElementById(id);

function renderRail() {
  const rail = byId('rail');
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

// A demo fleet the operator cannot tell from their own is the worst thing this
// page can be. It says so on screen, and in the tab title for a window left open.
function renderSource(source) {
  const demo = source === 'fixture';
  byId('demo-bar').hidden = !demo;
  document.title = demo ? 'dockmaster — demo fleet' : 'dockmaster';
}

function show(id, keepScroll) {
  const view = VIEWS.find((v) => v.id === id) || VIEWS[0];
  shell.current = view.id;
  if (location.hash !== `#${view.id}`) history.replaceState(null, '', `#${view.id}`);
  const main = byId('view');
  const top = main.scrollTop;
  main.textContent = '';
  add(main, view.render(shell.state, { compose }));
  // A background refresh must not throw the operator back to the top of a list.
  main.scrollTop = keepScroll ? top : 0;
  renderRail();
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
  renderPulse();
  show(shell.current, keepScroll);
}

async function refreshNow() {
  if (shell.refreshing) return;
  shell.refreshing = true;
  const button = byId('refresh');
  button.classList.add('is-busy');
  button.disabled = true;
  try {
    await loadState(true, true);
  } catch (err) {
    if (shell.state) setStale(err);
    else showFailure(err);
  } finally {
    shell.refreshing = false;
    button.classList.remove('is-busy');
    button.disabled = false;
  }
}

// --- conversation ------------------------------------------------------------

function renderMessage(message, animate) {
  const node = el('div', `msg msg-${message.from}${animate ? ' is-new' : ''}`);
  const header = el('div', 'msg-head');
  add(header,
    el('span', 'msg-from', message.from === 'operator' ? 'You' : 'Dockmaster'),
    el('span', 'msg-at', clockTime(message.at)));
  add(node, header, el('p', 'msg-text', message.text));
  return node;
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
}

function renderPendingError(message) {
  const row = byId('chat-pending');
  row.hidden = false;
  byId('chat-pending-text').textContent = `Not connected: ${message}. Retrying.`;
}

// A refused send is NOT transient - the message is back in the composer waiting
// on the operator - so it gets a row the poll loop never touches.
function setSendError(message) {
  const row = byId('chat-error');
  row.hidden = !message;
  row.textContent = message || '';
}

// One long-poll, forever: the request stays open until a message lands, so the
// page is live without a busy loop. `since` survives an error, so a reconnect
// never replays what is already on screen.
async function pumpChat() {
  const log = byId('chat-log');
  const messages = byId('chat-messages');
  let since = 0;
  let first = true;
  let backoff = 1000;
  for (;;) {
    try {
      // The FIRST read does not wait: an empty transcript would otherwise hold
      // the request open and leave the panel blank for the whole poll window.
      const response = await fetch(`/api/chat?since=${since}${first ? '' : '&wait=1'}`);
      const body = await response.json();
      // The server's message names files and scripts; the status does not.
      if (!response.ok) throw new Error(`the console answered ${response.status}`);
      if (body.messages.length) {
        byId('chat-empty').hidden = true;
        const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 60;
        body.messages.forEach((m) => add(messages, renderMessage(m, !first)));
        if (atBottom || first) log.scrollTop = log.scrollHeight;
      }
      since = body.total;
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

async function sendMessage(event) {
  event.preventDefault();
  const input = byId('chat-input');
  const text = input.value.trim();
  if (!text) return;
  input.value = '';
  growComposer();
  // The message goes back into the composer on any failure, so nothing the
  // operator typed is lost to a refusal or a dropped connection.
  const restore = (reason) => {
    input.value = text;
    growComposer();
    setSendError(`Not sent: ${reason}`);
  };
  let response;
  try {
    response = await fetch('/api/chat', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ text }),
    });
  } catch (err) {
    return restore(`the console could not be reached (${err.message}).`);
  }
  // An unmapped status falls back to the number, which is honest and is not
  // internal vocabulary - never to the server's own sentence.
  if (!response.ok) {
    return restore(SEND_REFUSAL[response.status] || `the console answered ${response.status}.`);
  }
  setSendError('');
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
  window.addEventListener('hashchange', () => show(location.hash.replace('#', '') || 'needs'));
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
setInterval(() => { if (shell.state && !document.hidden) show(shell.current, true); }, 60000);
