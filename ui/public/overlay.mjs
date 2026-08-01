/* overlay.mjs - a review, opened inside the console (#219).
 *
 * What renders in the frame is the ARCHIVED ARTIFACT itself, at the same
 * /review/<id>/<file> address the standalone review page frames, under the same
 * sandbox="allow-scripts" - an opaque origin, cross-origin to this document, so
 * it reaches none of the console's DOM, fetch or controls. The console's own
 * chrome (what this is, whether anyone is listening, Approve / Request changes)
 * sits OUTSIDE that frame, on markup this file builds. The artifact is never
 * edited, wrapped or appended to.
 *
 * The lifecycle is the point. Opening a review arms one listener on the server;
 * closing it stops that listener; while it is open this page checks in, so a
 * refresh or a killed tab is reaped rather than leaking a poller forever. The
 * page is the only thing that knows the review is still on screen, so saying so
 * is its job.
 */
'use strict';

import { el, add, lamp, askControl, APPROVE_REQUEST, REVISION_REQUEST } from './dom.mjs';
import { postMessage } from './api.mjs';

// Comfortably inside the server's own timeout (listeners.js), so an ordinary
// slow answer or a tab throttled in the background does not read as gone.
const KEEPALIVE_MS = 15000;

const open = {
  review: null, // the review href currently on screen, or null
  node: null,
  timer: null,
};

// Which reviews the server says have a live listener. The panels draw their
// indicator off this; `onChange` is how the shell learns to redraw.
let liveSet = new Set();
let onChange = () => {};

export const isListening = (href) => liveSet.has(href);

// Redraws the panels only when the set actually MOVED: a keepalive answers every
// 15 seconds and rebuilding the page on each one would be motion that means
// nothing.
function setLive(list) {
  const next = new Set(Array.isArray(list) ? list : []);
  let moved = next.size !== liveSet.size;
  if (!moved) for (const href of next) if (!liveSet.has(href)) moved = true;
  liveSet = next;
  if (moved) onChange();
}

// tell(action, href) - the one place the console talks to the listener. It
// REJECTS on a refusal or an unreachable console; every caller words it.
async function tell(action, href) {
  const response = await fetch('/api/review-listen', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ review: href, action }),
  });
  if (!response.ok) throw new Error(`the console answered ${response.status}`);
  const body = await response.json();
  setLive(body.live);
  return body.state;
}

async function readListeners() {
  try {
    const response = await fetch('/api/review-listeners');
    if (!response.ok) return;
    setLive((await response.json()).live);
  } catch (err) {
    // Not knowing whether a listener is armed is a missing indicator, not a
    // broken console: the page says nothing rather than claiming either way.
    console.warn(`console: could not read which reviews are being listened to (${err.message})`);
  }
}

function setIndicator(node, state) {
  node.textContent = '';
  if (state === 'listening') {
    add(node, lamp('starboard'), el('span', null, 'Listening — your notes reach the dockmaster'));
    return;
  }
  if (state === 'unreachable') {
    add(node, lamp('brass'), el('span', null, 'Not listening — the console could not be reached'));
    return;
  }
  add(node, lamp('neutral'), el('span', null, 'Not listening — notes here stay on the page'));
}

function buildOverlay(href, info) {
  const root = el('div', 'review-overlay');
  root.setAttribute('role', 'dialog');
  root.setAttribute('aria-modal', 'true');
  root.setAttribute('aria-label', 'The review');

  const head = el('div', 'review-overlay-head');
  const known = info.known !== false;
  add(head, el('p', 'review-overlay-what',
    known ? `${info.title} — ${info.repo}` : 'A review page kept after the work it belonged to'));
  const indicator = el('p', 'review-overlay-listening');
  setIndicator(indicator, 'off');
  add(head, indicator);

  const close = el('button', 'btn btn-quiet review-overlay-close');
  close.type = 'button';
  close.textContent = 'Close';
  close.addEventListener('click', () => { closeReview(); });
  add(head, close);
  add(root, head);

  const frame = el('iframe', 'review-overlay-frame');
  frame.setAttribute('title', 'The change');
  // No allow-same-origin: the artifact renders in an opaque origin and cannot
  // reach this document. Do not widen this - it, and frame-src 'self' on the
  // console's own policy, are the isolation, not the artifact's own CSP.
  frame.setAttribute('sandbox', 'allow-scripts');
  frame.src = info.src;
  add(root, frame);

  // Approve and Request changes exist only while the work is ACTUALLY awaiting
  // review - the same invariant the fleet cards and the standalone review page
  // hold. The server decides it; this only obeys.
  const foot = el('div', 'review-overlay-foot');
  if (info.awaiting) {
    add(foot, askControl({
      kind: 'approve',
      label: 'Approve',
      confirm: "Ask the dockmaster to approve this change. Landing still follows the repo's own merge authority.",
      request: APPROVE_REQUEST(info.title, info.repo),
      ask: postMessage,
    }));
    add(foot, askControl({
      kind: 'changes',
      label: 'Request changes',
      confirm: 'Send the dockmaster your notes on what needs to change.',
      notes: true,
      placeholder: 'What needs to change?',
      buildRequest: (notes) => REVISION_REQUEST(info.title, info.repo, notes),
      ask: postMessage,
    }));
  } else {
    add(foot, el('p', 'review-overlay-note',
      known ? 'This work is no longer waiting on your review. The page is kept for the record.'
        : 'The work behind this review could not be found, so nothing can be asked about it from here.'));
  }
  add(root, foot);
  return { root, indicator };
}

// openReview(href) - show that review in the console and arm its listener.
// REJECTS with an already-worded reason when the review cannot be read; the
// listener failing to arm is not that - the review still opens, saying nobody
// is listening.
export async function openReview(href) {
  if (typeof href !== 'string' || href.length === 0) throw new TypeError('openReview needs a review address');
  // Re-opening the review already on screen is not a second anything: no second
  // frame, and no second listener on the same file.
  if (open.review === href) return 'listening';
  if (open.review) await closeReview();

  let info;
  try {
    const response = await fetch(`/api/review-info?review=${encodeURIComponent(href)}`);
    if (!response.ok) throw new Error(`the console answered ${response.status}`);
    info = await response.json();
  } catch (err) {
    throw new Error(`That review could not be opened (${err.message}).`);
  }

  const built = buildOverlay(href, info);
  open.review = href;
  open.node = built.root;
  document.body.appendChild(built.root);
  document.body.classList.add('has-review-open');

  let state = 'unreachable';
  try {
    state = await tell('start', href);
  } catch (err) {
    console.warn(`console: the review listener could not be armed (${err.message})`);
  }
  // The overlay may already have been closed while the request was in flight.
  if (open.review !== href) return state;
  setIndicator(built.indicator, state === 'listening' ? 'listening' : state);
  open.timer = setInterval(() => {
    tell('keepalive', href)
      .then((current) => { if (open.review === href) setIndicator(built.indicator, current); })
      .catch(() => { if (open.review === href) setIndicator(built.indicator, 'unreachable'); });
  }, KEEPALIVE_MS);
  onChange();
  return state;
}

// closeReview() - take the review off screen and stop its listener. Safe to
// call when nothing is open.
export async function closeReview() {
  const href = open.review;
  if (!href) return;
  if (open.timer) clearInterval(open.timer);
  open.timer = null;
  if (open.node && open.node.parentNode) open.node.parentNode.removeChild(open.node);
  open.node = null;
  open.review = null;
  document.body.classList.remove('has-review-open');
  try {
    await tell('stop', href);
  } catch (err) {
    // The server's own keepalive timeout is the backstop for exactly this: a
    // stop that never arrived is reaped anyway, so it is logged, not shouted.
    console.warn(`console: the review listener could not be stopped (${err.message}); it times out on its own`);
  }
  onChange();
}

// initReviews(redraw) - wire the two things only the document can tell us: the
// operator dismissing the overlay, and this page going away.
export function initReviews(redraw) {
  if (typeof redraw !== 'function') throw new TypeError('initReviews needs a redraw callback');
  onChange = redraw;
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && open.review) closeReview();
  });
  // A refresh, a closed tab, a navigation away. `keepalive` is what lets the
  // request outlive the page; JSON because that is the only content type this
  // origin's write path accepts, which rules sendBeacon out (it cannot set one
  // that would not have to preflight). Best-effort by design - the server's
  // keepalive timeout is what actually guarantees no poller is leaked.
  window.addEventListener('pagehide', () => {
    if (!open.review) return;
    try {
      fetch('/api/review-listen', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ review: open.review, action: 'stop' }),
        keepalive: true,
      });
    } catch (err) {
      // Nothing to report to: the page is going away. The timeout covers it.
    }
  });
  return readListeners();
}
