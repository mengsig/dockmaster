// server.js - the console's local HTTP server. Node stdlib only, no build step,
// no network egress: everything it serves lives in this directory.
//
// Bound to 127.0.0.1 and nothing else. The Host header is checked too, so a
// hostile page in the operator's browser cannot reach it by re-resolving a
// domain to 127.0.0.1 (DNS rebinding); the CSP header pins every asset to this
// origin, which is also what keeps the page honest about working offline.
//
// Reading is not the whole threat. A message POSTed here becomes an operator
// INSTRUCTION the dockmaster acts on, so the write path takes its own
// cross-site refusals - see writeRefusal(). Loopback is not an authenticator.
//
// Started by bin/dm-ui.sh; run it directly only for debugging.

'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const chat = require('./chat');
const state = require('./state');
const live = require('./live');

const PUBLIC_DIR = path.join(__dirname, 'public');
// Allowlist, not a path resolver: traversal is unrepresentable rather than filtered.
const ROUTES = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/console.css': ['console.css', 'text/css; charset=utf-8'],
  '/console.mjs': ['console.mjs', 'text/javascript; charset=utf-8'],
  '/views.mjs': ['views.mjs', 'text/javascript; charset=utf-8'],
  '/dom.mjs': ['dom.mjs', 'text/javascript; charset=utf-8'],
  '/api.mjs': ['api.mjs', 'text/javascript; charset=utf-8'],
  '/review.mjs': ['review.mjs', 'text/javascript; charset=utf-8'],
  '/favicon.svg': ['favicon.svg', 'image/svg+xml'],
};
const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
  + "connect-src 'self'; base-uri 'none'; form-action 'none'";
const MAX_BODY_BYTES = 64 * 1024;
const LONG_POLL_MS = 25000;
// A review page ships beside its screenshots. One path segment, no slashes and
// no leading dot, so `..` and dotfiles are unrepresentable rather than filtered.
const ASSET_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const ASSET_TYPES = {
  html: 'text/html; charset=utf-8', css: 'text/css; charset=utf-8',
  js: 'text/javascript; charset=utf-8', png: 'image/png', jpg: 'image/jpeg',
  jpeg: 'image/jpeg', gif: 'image/gif', svg: 'image/svg+xml', webp: 'image/webp',
};

function config() {
  const port = Number(process.env.DM_UI_PORT || 4877);
  const dmHome = process.env.DM_HOME;
  const bin = process.env.DM_BIN || '';
  const source = process.env.DM_UI_SOURCE || 'live';
  if (!Number.isInteger(port) || port < 1024 || port > 65535) {
    throw new RangeError(`console: DM_UI_PORT must be 1024-65535, got '${process.env.DM_UI_PORT}'`);
  }
  if (!dmHome || !fs.existsSync(dmHome)) {
    throw new Error(`console: DM_HOME is unset or missing ('${dmHome}') - start via bin/dm-ui.sh`);
  }
  // Refusing here rather than at the first request: a console that boots and
  // only reveals it cannot read the fleet on page load is the failure mode this
  // whole seam exists to prevent.
  if (source === 'live' && !fs.existsSync(path.join(bin, 'dm-task.sh'))) {
    throw new Error(`console: the live source needs the toolbelt; DM_BIN='${bin}' has no dm-task.sh`);
  }
  return { port, dmHome, bin, source };
}

function send(res, status, type, body, extra) {
  res.writeHead(status, Object.assign({
    'content-type': type,
    'content-length': Buffer.byteLength(body),
    'content-security-policy': CSP,
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    'cache-control': 'no-store',
  }, extra || {}));
  res.end(body);
}

const sendJson = (res, status, value) => send(res, status, 'application/json; charset=utf-8', JSON.stringify(value));

// A local tool that fails must say so in the surface the operator is looking at,
// never render a blank panel that reads as "all clear".
//
// `detail` is the raw reason - a script name, its argv, its stderr, a path. It
// goes to this process's log ONLY. `message` is what the caller is willing to
// show, and for a /review/ navigation the browser renders it as the page.
function fail(res, status, message, detail) {
  process.stderr.write(`console: ${message}${detail ? ` — ${detail}` : ''}\n`);
  sendJson(res, status, { error: message });
}

// A /review/ address is a same-tab NAVIGATION: there is no page script to word
// a failure, so the browser renders whatever comes back as the body. It gets a
// worded page rather than a JSON blob.
function failReview(res, status, message, detail) {
  process.stderr.write(`console: review: ${message}${detail ? ` — ${detail}` : ''}\n`);
  const body = `<!doctype html><html lang="en"><head><meta charset="utf-8">`
    + `<meta name="viewport" content="width=device-width,initial-scale=1">`
    + `<meta name="color-scheme" content="dark light"><title>dockmaster</title>`
    + `<style>body{margin:0;display:grid;place-items:center;min-height:100vh;`
    + `background:#0a1014;color:#e6edf1;font:16px/1.6 system-ui,sans-serif}`
    + `div{max-width:32rem;padding:2rem;border-left:2px solid #c8a15c}`
    + `p{margin:.5rem 0;color:#93a6b1}b{color:#e6edf1;font-weight:600}`
    + `@media(prefers-color-scheme:light){body{background:#fff;color:#0a1014}p{color:#46585f}b{color:#0a1014}}`
    + `</style></head><body><div><p><b>This review page could not be opened.</b></p>`
    + `<p>${escapeHtml(message)}</p>`
    + `<p>Ask the dockmaster to look into it.</p></div></body></html>`;
  send(res, status, 'text/html; charset=utf-8', body);
}

const escapeHtml = (text) => String(text).replace(/[&<>"']/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const localHosts = (port) => [`127.0.0.1:${port}`, `localhost:${port}`, `[::1]:${port}`];

function hostIsLocal(req, port) {
  return localHosts(port).includes(req.headers.host || '');
}

// A review page is HTML this distro's crewmates wrote, with its styles and
// scripts inline, so it needs 'unsafe-inline' to render at all. Every subresource
// it may load is then scoped to /review/ ITSELF - not `'self'`, which is the
// whole origin and would let an inline script fire GET /api/state?refresh=1 in a
// loop through an <img>, a <link rel=stylesheet> or an @font-face. That request
// drives a fleet-wide sweep which writes and takes the task lock, and the
// cross-site refusal cannot stop it because a review page IS same-origin.
// connect-src 'none' and form-action 'none' hold the artifact to that, but a CSP
// is a per-document restriction the artifact's own inline script obeys - it is
// defense-in-depth, not the isolation boundary. The boundary is the sandbox
// attribute on the iframe this CSP is served into (see reviewShellHtml): without
// it, same-origin framing hands the artifact window.parent and it could call
// parent.fetch, or simply click the wrapper's own buttons, regardless of what
// this CSP says.
function reviewCsp(port) {
  const own = localHosts(port).map((host) => `http://${host}/review/`).join(' ');
  return `default-src 'none'; script-src ${own} 'unsafe-inline'; style-src ${own} 'unsafe-inline'; `
    + `img-src ${own} data:; font-src ${own} data:; `
    + "connect-src 'none'; base-uri 'none'; form-action 'none'";
}

// The wrapper this console puts AROUND an archived artifact, at the same
// /review/<id>/ address the raw artifact used to answer at directly. It is OUR
// OWN markup - server-templated, nothing the artifact or the request supplies
// reaches it unescaped - so it is trusted the same way index.html is, not the
// way the artifact is: 'self' scripts and a same-origin fetch, so the notes box
// can enqueue a message. The artifact keeps rendering inside an iframe, at the
// SAME asset address the non-index branch of serveReview already answers,
// still behind the unchanged, unforgiving reviewCsp() above. What actually keeps
// this shell safe from the artifact is `sandbox="allow-scripts"` on that iframe
// (reviewShellHtml, below): no allow-same-origin means the artifact renders into
// an opaque origin, so it can script itself but gets no window.parent and no DOM
// access into this document - it cannot reach this shell's Approve/Send buttons
// or its connect-src 'self' fetch. The CSP above is defense-in-depth on the
// artifact's own document; the sandbox is the isolation guarantee.
function reviewShellCsp() {
  return "default-src 'none'; script-src 'self'; style-src 'self'; frame-src 'self'; "
    + "connect-src 'self'; base-uri 'none'; form-action 'none'";
}

// reviewShellHtml(basename, info) - `info` is `{ title, repo }` when the task
// record behind this review could still be read, or `null` when it could not
// (archived, discarded, or the read itself failed) - carried into the page as
// data, never as prose, so review.mjs decides how to say it exactly once.
function reviewShellHtml(basename, info) {
  const data = JSON.stringify({
    ok: Boolean(info),
    title: info ? info.title : '',
    repo: info ? info.repo : '',
  }).replace(/</g, '\\u003c');
  // `basename` is a real file `reviewDir` already resolved, not request input -
  // encoded and escaped anyway, on the same principle as every other href this
  // page writes: composed, never trusted verbatim.
  const iframeSrc = escapeHtml(encodeURIComponent(basename));
  return `<!doctype html><html lang="en" data-theme="dark"><head><meta charset="utf-8">`
    + `<meta name="viewport" content="width=device-width,initial-scale=1">`
    + `<meta name="color-scheme" content="dark light"><title>dockmaster — review</title>`
    + `<link rel="stylesheet" href="/console.css"></head>`
    + `<body class="review-shell">`
    + `<script type="application/json" id="review-data">${data}</script>`
    + `<div class="review-frame"><iframe src="${iframeSrc}" title="The change" `
    + `sandbox="allow-scripts"></iframe></div>`
    + `<div class="review-panel" id="review-panel"></div>`
    + `<script type="module" src="/review.mjs"></script>`
    + `</body></html>`;
}

// A header value is only ever echoed back bounded: it is attacker-controlled,
// and it also lands in this process's log.
const shown = (value) => String(value).slice(0, 40).replace(/[^\x20-\x7e]/g, '?');

// crossSiteRefusal(req, port) -> {status, message}, or null to allow.
//
// The Host check above defeats DNS rebinding, which is a cross-origin READ
// attack. It does nothing about a cross-site request that CHANGES something: a
// hostile page can aim one straight at this literal loopback URL, and the
// browser sets the Host header itself, so it arrives looking local.
//
//   Sec-Fetch-Site  the browser sets it and page script cannot forge it (it is
//                   a forbidden header name); anything but same-origin/none is
//                   another site asking. Note a page on another PORT of
//                   127.0.0.1 sends `same-site`, which is not same-origin and
//                   is refused here - that is the case a real attack uses.
//   Origin          present on every browser POST; it must be one of ours.
//
// A non-browser client (curl, the tests) sends neither and is allowed - it is
// already running as the operator by the time it can reach this port.
function crossSiteRefusal(req, port) {
  const site = req.headers['sec-fetch-site'];
  if (site !== undefined && site !== 'same-origin' && site !== 'none') {
    return { status: 403, message: `refused a request from another site (sec-fetch-site: ${shown(site)})` };
  }
  const origin = req.headers.origin;
  if (origin !== undefined && !localHosts(port).some((h) => origin === `http://${h}`)) {
    return { status: 403, message: 'refused a request from another origin' };
  }
  return null;
}

// A posted message becomes an operator INSTRUCTION the dockmaster acts on, so
// the write path adds a third, independent refusal on top of the two above:
// application/json is NOT a CORS-simple content type, so a cross-origin attempt
// must preflight first and the preflight gets no CORS headers back. That is
// what stops the text/plain fetch and the HTML form - the two shapes that need
// no preflight at all and so are never blocked by the browser.
function writeRefusal(req, port) {
  const refusal = crossSiteRefusal(req, port);
  if (refusal) return refusal;
  const type = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
  if (type !== 'application/json') {
    return { status: 415, message: `this takes application/json, not '${shown(type) || 'nothing'}'` };
  }
  return null;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new RangeError(`request body exceeds ${MAX_BODY_BYTES} bytes`));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function serveStatic(res, route) {
  const [file, type] = ROUTES[route];
  send(res, 200, type, fs.readFileSync(path.join(PUBLIC_DIR, file)));
}

// GET /review/<id>/[<asset>] - an archived review page, and the screenshots
// beside it. The directory comes from dm-lavish.sh; the URL only selects.
//
// The TRAILING SLASH is load-bearing: a review page references its screenshots
// relatively, and at /review/<id> those resolve to /review/<name>.png - one
// segment up, where they are not. The bare form redirects rather than 404s, so
// a link written either way still works.
async function serveReview(res, cfg, pathname) {
  let parts;
  try {
    parts = pathname.split('/').slice(2).map(decodeURIComponent);
  } catch (err) {
    // A malformed percent-escape is bad input, not a server fault.
    return failReview(res, 400, 'That address is not a review page.', err.message);
  }
  const id = parts[0];
  if (!id) return failReview(res, 400, 'That address is not a review page.', pathname);
  if (parts.length === 1) {
    res.writeHead(302, { location: `/review/${encodeURIComponent(id)}/`, 'content-length': 0, 'cache-control': 'no-store' });
    return res.end();
  }
  // One trailing empty segment is the directory itself. Anything else names an
  // asset, and EVERY segment of it must be a plain name - so `..` and dotfiles
  // stay unrepresentable at any depth rather than being filtered out. A review
  // page ships its screenshots in subdirectories, so depth is not optional.
  const rest = parts.slice(1);
  const isIndex = rest.length === 1 && rest[0] === '';
  if (!isIndex && !rest.every((segment) => ASSET_NAME.test(segment))) {
    return failReview(res, 400, 'That address is not a review page.', pathname);
  }
  const found = await live.reviewDir(cfg.bin, id);
  if (!found) return failReview(res, 404, 'There is no review page for that work.');

  if (isIndex) {
    // A wrapper this console builds itself, not the archived artifact: it
    // renders the artifact in an iframe (still served, unchanged, by the
    // branch below) and adds the notes box - see reviewShellCsp() for why that
    // split is what keeps the artifact's own isolation intact.
    let info = null;
    try {
      info = await live.taskInfo(cfg.bin, id);
      if (!info.title && !info.repo) info = null; // the task record is gone
    } catch (err) {
      process.stderr.write(`console: review: could not read the task record for this review: ${err.message}\n`);
    }
    const basename = path.basename(found.file);
    return send(res, 200, 'text/html; charset=utf-8', reviewShellHtml(basename, info),
      { 'content-security-policy': reviewShellCsp() });
  }

  const file = path.join(found.dir, ...rest);
  let body;
  try {
    body = fs.readFileSync(file);
  } catch (err) {
    // Every arm is worded. The old fallback printed err.message, which carries
    // the errno and the absolute path of the review directory - reachable by
    // appending a segment to any real file (ENOTDIR).
    return failReview(res, 404, 'That file is not part of this review page.', err.message);
  }
  const type = ASSET_TYPES[String(file).split('.').pop().toLowerCase()] || 'application/octet-stream';
  send(res, 200, type, body, { 'content-security-policy': reviewCsp(cfg.port) });
}

// settle(watchers, waiter, force) - answer one waiter and retire it, containing
// any failure. Both callers that matter run OUTSIDE a request handler (a
// filesystem watch and a timer), where a throw is unhandled and exits the
// process - one torn line in the transcript used to be enough to do that.
function settle(watchers, waiter, force) {
  try {
    if (!waiter.answer(force)) return false;
  } catch (err) {
    if (waiter.res.headersSent || waiter.res.writableEnded) {
      process.stderr.write(`console: chat: ${err.message} (the page had already gone)\n`);
    } else {
      fail(waiter.res, 500, `chat: ${err.message}`);
    }
  }
  clearTimeout(waiter.timer);
  watchers.delete(waiter);
  return true;
}

// GET /api/chat?since=N - returns messages after index N. With wait=1 it holds
// the request open until something changes (or LONG_POLL_MS), so the page stays
// live without a busy loop.
function serveChat(res, cfg, url, watchers) {
  const since = Number(url.searchParams.get('since') || 0);
  if (!Number.isInteger(since) || since < 0) {
    return fail(res, 400, `chat: 'since' must be a non-negative integer`);
  }
  // What the CALLER believes is still waiting for the dockmaster. Reading the
  // count here instead was a race the operator could see: the count moves twice
  // while a drain runs, the page is answered on the first change, and by the time
  // it re-parks the second has already happened - so the waiter saw nothing to
  // report and the page sat on a number that was two picks-up out of date.
  // Comparing against the caller's own view cannot miss a change it has not seen.
  const claimed = url.searchParams.get('pending');
  if (claimed !== null && !/^[0-9]+$/.test(claimed)) {
    return fail(res, 400, `chat: 'pending' must be a non-negative integer`);
  }
  const waiter = {
    res,
    timer: null,
    // A message being PICKED UP adds nothing to the transcript, so holding out
    // for a new message alone left "1 message waiting for the dockmaster" on
    // screen for the whole poll window after it had already been answered.
    // A caller that sends no view of its own gets the old behaviour: hold out
    // until the count moves from where it is right now.
    pending: claimed === null ? chat.pendingCount(cfg.dmHome) : Number(claimed),
    // force=true answers whatever there is; otherwise it holds out for a change.
    // `unreadable` crosses so the page can say what it lost.
    answer(force) {
      const { messages, unreadable } = chat.read(cfg.dmHome);
      const pending = chat.pendingCount(cfg.dmHome);
      if (!force && messages.length <= since && pending === this.pending) return false;
      sendJson(res, 200, {
        total: messages.length,
        unreadable,
        pending,
        messages: messages.slice(since),
      });
      return true;
    },
  };

  if (settle(watchers, waiter, url.searchParams.get('wait') !== '1')) return;
  watchers.add(waiter);
  waiter.timer = setTimeout(() => settle(watchers, waiter, true), LONG_POLL_MS);
  res.on('close', () => { clearTimeout(waiter.timer); watchers.delete(waiter); });
}

function wake(watchers) {
  for (const waiter of Array.from(watchers)) settle(watchers, waiter, false);
}

async function postChat(req, res, cfg, watchers) {
  let body;
  try {
    body = await readBody(req);
  } catch (err) {
    return fail(res, err instanceof RangeError ? 413 : 400, `chat: ${err.message}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch (err) {
    return fail(res, 400, `chat: request body is not JSON: ${err.message}`);
  }
  let message;
  try {
    // chat.append's errors already name their own subject; re-prefixing here is
    // what produced "chat: chat: refusing an empty message".
    message = chat.append(cfg.dmHome, 'operator', parsed && parsed.text);
  } catch (err) {
    return fail(res, 400, err.message);
  }
  sendJson(res, 201, message);
  wake(watchers);
}

function handle(req, res, cfg, watchers) {
  if (!hostIsLocal(req, cfg.port)) return fail(res, 403, `refused a request for host '${req.headers.host}'`);
  const url = new URL(req.url, `http://127.0.0.1:${cfg.port}`);

  if (req.method === 'GET' && Object.prototype.hasOwnProperty.call(ROUTES, url.pathname)) {
    return serveStatic(res, url.pathname);
  }
  if (req.method === 'GET' && url.pathname === '/api/state') {
    // THE WHOLE ROUTE, not just `refresh=1`. Either form runs the collection
    // whenever its cache tier has lapsed (20s local, 150s sweep), and that
    // collection RECORDS each PR's state through dm_meta_set, which takes the
    // same lock live crew work uses. So an <img src="/api/state"> on a hostile
    // page contends for that lock every 20s and drives a full GitHub sweep
    // every 150s, forever - no forced refresh and no legacy browser needed.
    // A state-changing GET is still a state-changing request.
    const refusal = crossSiteRefusal(req, cfg.port);
    if (refusal) return fail(res, refusal.status, refusal.message);
    // A failed collection is reported as a failure, never as an empty fleet.
    // The page words the failure from `source`; the raw reason is already on
    // stderr, because a script name and its stderr are not for the operator.
    return state.collect(cfg.source, cfg.bin, url.searchParams.get('refresh') === '1')
      .then((doc) => sendJson(res, 200, doc))
      .catch((err) => {
        process.stderr.write(`console: /api/state: ${err.message}\n`);
        sendJson(res, 503, { error: err.message, source: err.source || '' });
      });
  }
  if (req.method === 'GET' && url.pathname.startsWith('/review/')) {
    return serveReview(res, cfg, url.pathname)
      .catch((err) => failReview(res, 500, 'The review archive could not be read.', err.message));
  }
  // Opening the annotatable session runs a dm-* script, the same class of
  // action the fleet sweep behind /api/state already is, so it takes the same
  // cross-site refusal.
  //
  // `redirect=1` is what the page's link actually uses: the browser's own
  // navigation of a real <a target=_blank>, landing here from the click's own
  // user activation, then 302-ing on to wherever the session turned out to be
  // - the session url, or the raw /review/<id>/ page when there is none. A
  // window opened after an awaited fetch has NO such activation and can be
  // silently popup-blocked; a redirect from the click itself cannot be. The
  // plain JSON form (no `redirect`) stays for tests and any other local tool.
  if (req.method === 'GET' && url.pathname === '/api/review-open') {
    const refusal = crossSiteRefusal(req, cfg.port);
    if (refusal) return fail(res, refusal.status, refusal.message);
    const id = url.searchParams.get('id') || '';
    const redirect = url.searchParams.get('redirect') === '1';
    const fallback = `/review/${encodeURIComponent(id)}/`;
    const goTo = (location) => {
      res.writeHead(302, { location, 'content-length': 0, 'cache-control': 'no-store' });
      res.end();
    };
    if (!id) return redirect ? fail(res, 400, 'missing id') : sendJson(res, 200, { url: null });
    return live.openReviewSession(cfg.bin, id)
      .then((result) => (redirect ? goTo(result.url || fallback) : sendJson(res, 200, result)))
      .catch((err) => {
        process.stderr.write(`console: /api/review-open: ${err.message}\n`);
        return redirect ? goTo(fallback) : sendJson(res, 200, { url: null });
      });
  }
  if (req.method === 'GET' && url.pathname === '/api/chat') return serveChat(res, cfg, url, watchers);
  if (req.method === 'POST' && url.pathname === '/api/chat') {
    const refusal = writeRefusal(req, cfg.port);
    if (refusal) return fail(res, refusal.status, refusal.message);
    return postChat(req, res, cfg, watchers).catch((err) => fail(res, 500, `chat: ${err.message}`));
  }
  return fail(res, 404, `no route for ${req.method} ${url.pathname}`);
}

function main() {
  const cfg = config();
  chat.ensureDirs(cfg.dmHome);
  const watchers = new Set();

  const server = http.createServer((req, res) => {
    try {
      handle(req, res, cfg, watchers);
    } catch (err) {
      fail(res, 500, err.message);
    }
  });

  // A reply posted by `dm-ui.sh say` lands in the file, not through this
  // process - watch it so an open page shows the answer without a refresh.
  const transcript = path.join(chat.uiDir(cfg.dmHome), 'chat.jsonl');
  fs.watchFile(transcript, { interval: 400 }, () => wake(watchers));

  // The inbox changes without the transcript changing: a poll PICKING UP a
  // message is exactly that. Watch it too, or the page keeps saying a message is
  // waiting until the long poll times out. The 25s timeout stays the correctness
  // path - fs.watch drops events on some filesystems - so a failed watch here
  // degrades the latency, not the answer.
  const inbox = path.join(chat.uiDir(cfg.dmHome), 'inbox');
  const inboxWatcher = fs.watch(inbox, () => wake(watchers));
  inboxWatcher.on('error', (err) => {
    process.stderr.write(`console: chat: the inbox watch failed (${err.message}); the page now learns of a pick-up on its next poll\n`);
    inboxWatcher.close();
  });

  server.listen(cfg.port, '127.0.0.1', () => {
    process.stdout.write(`http://127.0.0.1:${cfg.port}/ (${cfg.source})\n`);
  });
  server.on('error', (err) => {
    // Name the usual cause: an orphaned console still holding the port reads as
    // a bare EADDRINUSE, which says nothing about what to do next.
    const why = err.code === 'EADDRINUSE'
      ? `something is already listening there - stop it with 'bin/dm-ui.sh stop', or set DM_UI_PORT`
      : err.message;
    process.stderr.write(`console: cannot listen on 127.0.0.1:${cfg.port}: ${why}\n`);
    process.exit(1);
  });
}

main();
