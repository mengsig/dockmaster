/* api.mjs - the one way anything on this origin talks to the dockmaster: an
 * ordinary POST to /api/chat. The console's own composer, every enqueue
 * control on its panels, and the notes box on a console-served review page
 * all share this, so there is exactly one place that knows the wire format
 * and exactly one place that words a refusal.
 */
'use strict';

// Why a message was refused, worded here. The server's own text names files and
// scripts, so the status is what crosses - 403/415 mean the request did not
// come from a page this origin trusts, which the operator cannot cause and
// cannot fix by rewording anything.
const SEND_REFUSAL = {
  400: 'the console would not accept it. If it is very long, try a shorter one.',
  413: 'it is too long to send.',
  403: 'the console refused it — that request did not come from this page.',
  415: 'the console refused it — that request did not come from this page.',
  500: 'the console could not store it. Ask the dockmaster to look into it.',
};

// postMessage(text) -> Promise<void>, enqueuing an ordinary operator message.
// Rejects with an already-worded reason; never with the server's own text.
export async function postMessage(text) {
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
  if (!response.ok) {
    throw new Error(SEND_REFUSAL[response.status] || `the console answered ${response.status}.`);
  }
}
