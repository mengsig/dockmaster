// server.js - the console's local HTTP server. Node stdlib only, no build step,
// no network egress: everything it serves lives in this directory.
//
// Bound to 127.0.0.1 and nothing else. The Host header is checked too, so a
// hostile page in the operator's browser cannot reach it by re-resolving a
// domain to 127.0.0.1 (DNS rebinding); the CSP header pins every asset to this
// origin, which is also what keeps the page honest about working offline.
//
// Started by bin/dm-ui.sh; run it directly only for debugging.

'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const chat = require('./chat');
const state = require('./state');

const PUBLIC_DIR = path.join(__dirname, 'public');
// Allowlist, not a path resolver: traversal is unrepresentable rather than filtered.
const ROUTES = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/console.css': ['console.css', 'text/css; charset=utf-8'],
  '/console.js': ['console.js', 'text/javascript; charset=utf-8'],
  '/favicon.svg': ['favicon.svg', 'image/svg+xml'],
};
const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
  + "connect-src 'self'; base-uri 'none'; form-action 'none'";
const MAX_BODY_BYTES = 64 * 1024;
const LONG_POLL_MS = 25000;

function config() {
  const port = Number(process.env.DM_UI_PORT || 4877);
  const dmHome = process.env.DM_HOME;
  if (!Number.isInteger(port) || port < 1024 || port > 65535) {
    throw new RangeError(`console: DM_UI_PORT must be 1024-65535, got '${process.env.DM_UI_PORT}'`);
  }
  if (!dmHome || !fs.existsSync(dmHome)) {
    throw new Error(`console: DM_HOME is unset or missing ('${dmHome}') - start via bin/dm-ui.sh`);
  }
  return { port, dmHome, source: process.env.DM_UI_SOURCE || 'fixture' };
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
function fail(res, status, message) {
  process.stderr.write(`console: ${message}\n`);
  sendJson(res, status, { error: message });
}

function hostIsLocal(req, port) {
  const host = req.headers.host || '';
  return host === `127.0.0.1:${port}` || host === `localhost:${port}` || host === `[::1]:${port}`;
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

// GET /api/chat?since=N - returns messages after index N. With wait=1 it holds
// the request open until one arrives (or LONG_POLL_MS), so the page stays live
// without a busy loop.
function serveChat(res, cfg, url, watchers) {
  const since = Number(url.searchParams.get('since') || 0);
  if (!Number.isInteger(since) || since < 0) {
    return fail(res, 400, `chat: 'since' must be a non-negative integer`);
  }
  const reply = () => {
    const messages = chat.read(cfg.dmHome);
    if (messages.length <= since && url.searchParams.get('wait') === '1') return false;
    sendJson(res, 200, {
      total: messages.length,
      pending: chat.pendingCount(cfg.dmHome),
      messages: messages.slice(since),
    });
    return true;
  };
  if (reply()) return;

  const waiter = { reply, timer: null };
  watchers.add(waiter);
  waiter.timer = setTimeout(() => {
    watchers.delete(waiter);
    sendJson(res, 200, { total: chat.read(cfg.dmHome).length, pending: chat.pendingCount(cfg.dmHome), messages: [] });
  }, LONG_POLL_MS);
  res.on('close', () => { clearTimeout(waiter.timer); watchers.delete(waiter); });
}

function wake(watchers) {
  for (const waiter of Array.from(watchers)) {
    if (waiter.reply()) { clearTimeout(waiter.timer); watchers.delete(waiter); }
  }
}

async function postChat(req, res, cfg, watchers) {
  const body = await readBody(req);
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch (err) {
    return fail(res, 400, `chat: request body is not JSON: ${err.message}`);
  }
  let message;
  try {
    message = chat.append(cfg.dmHome, 'operator', parsed && parsed.text);
  } catch (err) {
    return fail(res, 400, `chat: ${err.message}`);
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
    return sendJson(res, 200, state.collect(cfg.source));
  }
  if (req.method === 'GET' && url.pathname === '/api/chat') return serveChat(res, cfg, url, watchers);
  if (req.method === 'POST' && url.pathname === '/api/chat') {
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

  server.listen(cfg.port, '127.0.0.1', () => {
    process.stdout.write(`http://127.0.0.1:${cfg.port}/ (${cfg.source})\n`);
  });
  server.on('error', (err) => {
    process.stderr.write(`console: cannot listen on 127.0.0.1:${cfg.port}: ${err.message}\n`);
    process.exit(1);
  });
}

main();
