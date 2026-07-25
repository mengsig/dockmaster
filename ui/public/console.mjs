/* console.mjs - the shell: which panel is showing, keeping it current, and
 * carrying the conversation with the dockmaster.
 *
 * The panels themselves are in views.mjs and every word is in dom.mjs. This file
 * owns the wiring and nothing about how the fleet is worded.
 */
'use strict';

import { el, add, lamp, plural, clockTime } from './dom.mjs';
import { VIEWS } from './views.mjs';

const shell = { state: null, current: location.hash.replace('#', '') || 'needs', refreshing: false };

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

function renderPulse() {
  const s = shell.state;
  const pulse = byId('pulse');
  pulse.textContent = '';
  const urgent = s.needs_you.length;
  add(pulse, lamp(urgent > 0 ? 'brass' : 'starboard'));
  add(pulse, el('span', null, urgent > 0 ? plural(urgent, 'thing needs you', 'things need you') : 'all clear'));
  const parts = [
    plural(s.fleet.in_flight, 'change under way', 'changes under way'),
    plural(s.fleet.open_prs, 'open pull request', 'open pull requests'),
    `as of ${clockTime(s.generated_at)}`,
  ];
  // Losing a source is never silent: it is stated beside the counts it affects.
  if (s.degraded.length) parts.push(`${plural(s.degraded.length, 'source', 'sources')} unreadable`);
  for (const part of parts) add(pulse, el('span', 'sep', '·'), el('span', null, part));
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

function showFailure(message) {
  const main = byId('view');
  main.textContent = '';
  const box = el('div', 'failure');
  add(box,
    el('p', 'failure-head', 'The console could not read the fleet.'),
    el('p', 'failure-body', message),
    el('p', 'failure-body',
      'Nothing here is a statement about your work — it is this page failing to load it.'));
  add(main, box);
}

// --- keeping it current ------------------------------------------------------

// The page re-reads on its own; the server holds each collection so an open tab
// costs one cheap request per interval. The PR sweep is on a much longer cache
// than local state, and `Refresh` is what forces both.
const REFRESH_MS = 30000;

async function loadState(keepScroll, force) {
  const response = await fetch(`/api/state${force ? '?refresh=1' : ''}`);
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || `the server answered ${response.status}`);
  shell.state = body;
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
    showFailure(err.message);
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

function renderPending(count) {
  const row = byId('chat-pending');
  row.hidden = count === 0;
  byId('chat-pending-text').textContent = count === 0
    ? ''
    : `${plural(count, 'message', 'messages')} waiting for the dockmaster to pick up.`;
}

function renderPendingError(message) {
  const row = byId('chat-pending');
  row.hidden = false;
  byId('chat-pending-text').textContent = `Not connected: ${message}. Retrying.`;
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
      if (!response.ok) throw new Error(body.error || `the server answered ${response.status}`);
      if (body.messages.length) {
        byId('chat-empty').hidden = true;
        const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 60;
        body.messages.forEach((m) => add(messages, renderMessage(m, !first)));
        if (atBottom || first) log.scrollTop = log.scrollHeight;
      }
      since = body.total;
      first = false;
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

function compose(text) {
  const input = byId('chat-input');
  input.value = text;
  if (window.matchMedia('(max-width: 78rem)').matches) setChatOpen(true);
  input.focus();
  growComposer();
}

async function sendMessage(event) {
  event.preventDefault();
  const input = byId('chat-input');
  const text = input.value.trim();
  if (!text) return;
  input.value = '';
  growComposer();
  const response = await fetch('/api/chat', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ text }),
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    input.value = text;
    growComposer();
    renderPendingError(body.error || `the server answered ${response.status}`);
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
  byId('chat-input').addEventListener('input', growComposer);
  byId('chat-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(e); }
  });
  window.addEventListener('hashchange', () => show(location.hash.replace('#', '') || 'needs'));
}

wire();
loadState(false, false).catch((err) => showFailure(err.message));
setInterval(() => {
  loadState(true, false).catch((err) => renderPendingError(err.message));
}, REFRESH_MS);
pumpChat();

// Relative ages ("3d ago", "quiet 6h") are computed at render time, so a page
// left open all afternoon would keep showing this morning's numbers without a
// re-render. Cheap, and it keeps the one thing that silently rots honest.
setInterval(() => { if (shell.state) show(shell.current, true); }, 60000);
