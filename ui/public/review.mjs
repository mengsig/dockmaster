/* review.mjs - the small script beside a console-served review page.
 *
 * The archived artifact renders in the iframe next to this; that document is
 * still served through reviewCsp() and cannot reach the network by any means
 * (see server.js). This script is the only thing on the OUTER page allowed to
 * reach the API, and it follows the same enqueue-only contract as console.mjs:
 * Approve and Request changes only ever put an ordinary message on the queue.
 */
'use strict';

import { el, add, askControl, APPROVE_REQUEST, REVISION_REQUEST } from './dom.mjs';
import { postMessage } from './api.mjs';

// The server embeds this as data, never as prose - a task record that could
// not be read is `{ ok: false }`, not a title and repo this page invented.
function readData() {
  const node = document.getElementById('review-data');
  try {
    return JSON.parse(node.textContent);
  } catch (err) {
    return { ok: false, title: '', repo: '' };
  }
}

function render() {
  const panel = document.getElementById('review-panel');
  const data = readData();
  if (!data.ok) {
    add(panel, el('p', 'review-missing',
      'The task behind this review could not be found, so this page cannot '
      + 'safely name it in a request. Message the dockmaster directly in the console.'));
    return;
  }
  add(panel, el('p', 'review-panel-head', `${data.title} — ${data.repo}`));
  add(panel, askControl({
    kind: 'approve',
    label: 'Approve',
    confirm: 'Ask the dockmaster to approve this change and carry it through to landing.',
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
