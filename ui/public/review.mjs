/* review.mjs - the small script beside a console-served review page.
 *
 * The archived artifact renders in the iframe next to this. It cannot reach the
 * network - measured in a browser, not assumed - but reviewCsp() is only half of
 * why, so do not read that policy alone as the guarantee:
 *   fetch / XHR            connect-src 'none'          (reviewCsp)
 *   img, style, font, script  scoped to /review/       (reviewCsp)
 *   form submit            form-action 'none'          (reviewCsp)
 *   top.location, window.open  sandbox="allow-scripts" with neither
 *                          allow-top-navigation nor allow-popups
 *   NAVIGATING ITS OWN FRAME - the one channel no CSP directive on the artifact
 *                          governs - frame-src 'self' on the SHELL, which is
 *                          enforced on every later navigation of that frame,
 *                          and frame-ancestors 'none' on every console response,
 *                          which stops it framing the API even same-origin.
 * The last line is why reviewShellCsp()'s frame-src must stay exactly 'self'.
 *
 * This script is the only thing on the OUTER page allowed to reach the API, and
 * it follows the same enqueue-only contract as console.mjs: Approve and Request
 * changes only ever put an ordinary message on the queue.
 */
'use strict';

import { el, add, askControl, storedTheme, APPROVE_REQUEST, REVISION_REQUEST } from './dom.mjs';
import { postMessage } from './api.mjs';

// The server embeds this as data, never as prose - a task record that could
// not be read is `{ ok: false }`, not a title and repo this page invented.
// That is a NORMAL, worded outcome, not one of the two failures below: a
// missing node is the template itself broken, and a parse error is a corrupt
// or truncated block - both are bugs in this page, distinguished here so the
// console's log says which.
function readData() {
  const node = document.getElementById('review-data');
  if (!node) {
    console.error('review: the review-data block is missing from the page');
    return { ok: false, title: '', repo: '', awaiting: false };
  }
  try {
    return JSON.parse(node.textContent);
  } catch (err) {
    console.error(`review: the review-data block could not be parsed: ${err.message}`);
    return { ok: false, title: '', repo: '', awaiting: false };
  }
}

function render() {
  // The server serves this document with the console's own default theme; the
  // operator's actual choice lives in their browser, so it is applied here.
  document.documentElement.dataset.theme = storedTheme();

  const panel = document.getElementById('review-panel');
  const data = readData();
  if (!data.ok) {
    add(panel, el('p', 'review-missing',
      'The task behind this review could not be found, so this page cannot '
      + 'safely name it in a request. Message the dockmaster directly in the console.'));
    return;
  }
  add(panel, el('p', 'review-panel-head', `${data.title} — ${data.repo}`));
  // The same invariant the fleet page's cards hold (views.mjs approveControl):
  // these two requests exist only while the work is actually awaiting review.
  // The review archive keeps an artifact after the work lands or is dropped, and
  // its rows link here, so this page is reachable for work there is nothing left
  // to decide about - approving that would put a meaningless instruction on the
  // dockmaster's queue. The server decides the state (server.js reviewShellHtml);
  // this page only obeys it.
  if (!data.awaiting) {
    add(panel, el('p', 'review-missing',
      'This work is no longer waiting on your review, so there is nothing to '
      + 'approve or send back here. The page is kept for the record.'));
    return;
  }
  add(panel, askControl({
    kind: 'approve',
    label: 'Approve',
    confirm: "Ask the dockmaster to approve this change. Landing still follows the repo's own merge authority.",
    request: APPROVE_REQUEST(data.title, data.repo),
    ask: postMessage,
  }));
  add(panel, askControl({
    kind: 'changes',
    label: 'Request changes',
    confirm: 'Send the dockmaster your notes on what needs to change.',
    notes: true,
    placeholder: 'What needs to change?',
    buildRequest: (notes) => REVISION_REQUEST(data.title, data.repo, notes),
    ask: postMessage,
  }));
}

render();
