// listeners.js - the review listeners the console owns.
//
// Opening a review in the console arms ONE `dm-lavish.sh poll <id>` child for
// that review; closing it stops that child. Everything the poll prints is
// enqueued as an ordinary operator message on the same lossless queue the
// composer uses, so annotations reach the dockmaster without a terminal.
//
// Four ways a listener ends, and all four are handled here, because a leaked
// poller is invisible - it costs a process and a lavish session nobody can see:
//
//   the page said stop      the ordinary close
//   the page went away      no keepalive for KEEPALIVE_TIMEOUT_MS -> reaped.
//                           A refresh, a killed tab and a closed laptop all
//                           look like this and none of them can say goodbye.
//   the poll exited         lavish ended the session from its own side; the
//                           entry is dropped so the page stops claiming a live
//                           listener, and NOTHING re-arms it (a keepalive only
//                           renews, so a poll that exits instantly - lavish-axi
//                           not installed - cannot become a respawn loop).
//   the console exited      stopAll() on the way out, kill by captured pid.
//
// Every kill is `child.kill()` on a child THIS module spawned. Never a pkill,
// never a name - a sibling session's poller is identical from the outside.

'use strict';

const { spawn } = require('node:child_process');
const path = require('node:path');

const chat = require('./chat');

// Two minutes, not one: a browser throttles a hidden tab's timers to about one
// firing a minute, so a 60s deadline reaps the review of anyone who switched
// windows. The page checks in every 15s while visible.
const KEEPALIVE_TIMEOUT_MS = 120 * 1000;
const SWEEP_MS = 5 * 1000;
// Feedback arrives as a block of lines, not one message per line. Collect until
// the poll has been quiet this long, then enqueue the block as one message.
const QUIET_MS = 250;
// The queue itself refuses past 64KB; cut before that so a huge annotation is
// delivered truncated (and says so) rather than refused whole.
const MAX_FEEDBACK_BYTES = 16 * 1024;

// createListeners(options) -> the console's listener registry.
//
// options.spawn / .timeoutMs / .sweepMs exist for tests: a null timeoutMs
// DISABLES the reaper, which is how the leak test proves it is the reaper that
// catches a page that went away rather than something else.
function createListeners(options) {
  const opts = options || {};
  if (typeof opts.dmHome !== 'string' || opts.dmHome.length === 0) {
    throw new TypeError('listeners: dmHome must be a non-empty path');
  }
  if (typeof opts.bin !== 'string' || opts.bin.length === 0) {
    throw new TypeError('listeners: bin must be a non-empty path');
  }
  const dmHome = opts.dmHome;
  const bin = opts.bin;
  const spawnChild = opts.spawn || spawn;
  const timeoutMs = opts.timeoutMs === undefined ? KEEPALIVE_TIMEOUT_MS : opts.timeoutMs;
  if (timeoutMs !== null && !(Number.isFinite(timeoutMs) && timeoutMs > 0)) {
    throw new RangeError('listeners: timeoutMs must be a positive number, or null to disable the reaper');
  }
  const sweepMs = opts.sweepMs || SWEEP_MS;
  // Snapshot the environment ONCE, here: every poller this registry spawns runs
  // in the same world, decided at creation rather than at whatever moment a
  // click happened to land.
  const childEnv = Object.assign({}, process.env, { DM_HOME: dmHome });

  // key -> entry. The key is the review's own address (`/review/<id>/`), which
  // is what the page holds; `id` is what the toolbelt takes.
  const armed = new Map();
  const log = (line) => process.stderr.write(`console: review listener: ${line}\n`);

  // What the operator reads in the transcript. Named the way every other
  // console request is - by title and repo, never a task id.
  function heading(entry) {
    if (!entry.title && !entry.repo) return 'Feedback from a review page';
    return `Feedback on the review of "${entry.title || 'this change'}" (${entry.repo || 'unknown repo'})`;
  }

  function enqueue(entry, text) {
    let body = text.trim();
    if (body.length === 0) return;
    if (Buffer.byteLength(body, 'utf8') > MAX_FEEDBACK_BYTES) {
      body = `${Buffer.from(body, 'utf8').slice(0, MAX_FEEDBACK_BYTES).toString('utf8')}\n[…the rest was too long to carry]`;
    }
    try {
      chat.append(dmHome, 'operator', `${heading(entry)}:\n${body}`);
    } catch (err) {
      // The feedback is already spoken; losing it silently would be the one
      // outcome this whole path exists to prevent, so it is said out loud.
      log(`could not queue feedback for the dockmaster: ${err.message}`);
    }
  }

  function flush(entry) {
    if (entry.flushTimer) {
      clearTimeout(entry.flushTimer);
      entry.flushTimer = null;
    }
    const pending = entry.buffer;
    entry.buffer = '';
    if (pending) enqueue(entry, pending);
  }

  function collect(entry, chunk) {
    entry.buffer += chunk;
    if (Buffer.byteLength(entry.buffer, 'utf8') >= MAX_FEEDBACK_BYTES) return flush(entry);
    if (entry.flushTimer) clearTimeout(entry.flushTimer);
    entry.flushTimer = setTimeout(() => flush(entry), QUIET_MS);
    if (entry.flushTimer.unref) entry.flushTimer.unref();
  }

  // Kill the child by the pid captured at spawn, and only that one.
  function stopEntry(entry, why) {
    armed.delete(entry.key);
    flush(entry);
    entry.stopping = true;
    try {
      entry.child.kill('SIGTERM');
    } catch (err) {
      log(`could not stop the poller for a review (${err.message})`);
    }
    log(`stopped (${why})`);
  }

  function arm(key, id, info) {
    if (typeof key !== 'string' || key.length === 0) throw new TypeError('listeners: key must be a non-empty string');
    if (typeof id !== 'string' || id.length === 0) throw new TypeError('listeners: id must be a non-empty string');
    const existing = armed.get(key);
    // Re-opening the same review renews the one listener. Two children on one
    // file would double every annotation into the queue.
    if (existing) {
      existing.seenAt = Date.now();
      return 'listening';
    }
    const child = spawnChild(path.join(bin, 'dm-lavish.sh'), ['poll', id], {
      cwd: dmHome,
      env: childEnv,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (!child || typeof child.kill !== 'function' || !child.stdout) {
      throw new Error('listeners: the poller could not be started');
    }
    const entry = {
      key,
      id,
      child,
      pid: child.pid,
      seenAt: Date.now(),
      buffer: '',
      flushTimer: null,
      stopping: false,
      title: (info && info.title) || '',
      repo: (info && info.repo) || '',
    };
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => collect(entry, chunk));
    if (child.stderr) {
      child.stderr.setEncoding('utf8');
      // The tool's own words are for this log, never for the operator's queue.
      child.stderr.on('data', (chunk) => log(`poller said: ${String(chunk).trim()}`));
    }
    child.on('error', (err) => {
      armed.delete(key);
      log(`the poller failed to run (${err.message})`);
    });
    child.on('exit', (code, signal) => {
      flush(entry);
      // Only OUR entry: a stop already removed it, and a later re-arm must not
      // be deleted by the old child's exit.
      if (armed.get(key) === entry) armed.delete(key);
      if (!entry.stopping) log(`the review session ended from its own side (exit ${code}${signal ? ` ${signal}` : ''})`);
    });
    armed.set(key, entry);
    log(`armed for a review (pid ${entry.pid})`);
    return 'listening';
  }

  function keepalive(key) {
    const entry = armed.get(key);
    if (!entry) return 'ended';
    entry.seenAt = Date.now();
    return 'listening';
  }

  function stop(key) {
    const entry = armed.get(key);
    if (!entry) return 'ended';
    stopEntry(entry, 'the review was closed');
    return 'stopped';
  }

  // A page that went away without saying so. This is the whole robustness
  // story for a refresh, a killed tab and a crashed browser.
  function sweep(now) {
    if (timeoutMs === null) return 0;
    const at = now === undefined ? Date.now() : now;
    let reaped = 0;
    for (const entry of Array.from(armed.values())) {
      if (at - entry.seenAt <= timeoutMs) continue;
      stopEntry(entry, 'the review page stopped checking in');
      reaped += 1;
    }
    return reaped;
  }

  function stopAll() {
    for (const entry of Array.from(armed.values())) stopEntry(entry, 'the console is shutting down');
  }

  const timer = setInterval(() => sweep(), sweepMs);
  // The sweep must never be the reason this process stays alive.
  if (timer.unref) timer.unref();

  return {
    arm,
    keepalive,
    stop,
    sweep,
    stopAll,
    // What the page draws its indicator from: the reviews with a live listener.
    live: () => Array.from(armed.keys()),
    isLive: (key) => armed.has(key),
    close() { clearInterval(timer); stopAll(); },
  };
}

module.exports = { createListeners, KEEPALIVE_TIMEOUT_MS, QUIET_MS, MAX_FEEDBACK_BYTES };
