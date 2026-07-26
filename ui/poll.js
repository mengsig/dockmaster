// poll.js - block until the operator says something, print it, exit.
//
// This is what a dockmaster session waits on: it costs nothing while idle and
// wakes the session the moment a message lands, the same shape as
// `lavish-axi poll`. Claiming is a rename, so a killed or timed-out poll loses
// nothing - re-run it and the queued message is still there.
//
// Exit: 0 printed a message, 3 timed out with nothing queued, 1 could not read
// the inbox at all. A single unreadable queue entry is set aside and reported;
// it never ends the poll, because nothing restarts one.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const chat = require('./chat');

const IDLE_RECHECK_MS = 1000;
// A poll that cannot read its inbox at all is broken, not busy. It says so and
// exits rather than spinning silently while the dockmaster waits on it.
const MAX_CONSECUTIVE_FAILURES = 5;

function config() {
  const dmHome = process.env.DM_HOME;
  if (!dmHome || !fs.existsSync(dmHome)) {
    throw new Error(`console: DM_HOME is unset or missing ('${dmHome}') - run via bin/dm-ui.sh`);
  }
  const raw = process.env.DM_UI_POLL_TIMEOUT || '0';
  const timeout = Number(raw);
  if (!Number.isFinite(timeout) || timeout < 0) {
    throw new RangeError(`console: poll timeout must be >= 0 seconds, got '${raw}'`);
  }
  return { dmHome, timeoutMs: timeout * 1000 };
}

function emit(message) {
  process.stdout.write(`${message.at} operator:\n${message.text}\n`);
  process.exit(0);
}

function main() {
  const cfg = config();
  const inbox = path.join(chat.ensureDirs(cfg.dmHome), 'inbox');

  // `take` is registered on a filesystem watch and a timer, both OUTSIDE any
  // caller that could catch: a throw there is an unhandled exception and exits
  // the process. That killed the dockmaster's wake mechanism outright - the
  // message survived in the inbox, as promised, but nothing was left listening
  // for it and nothing re-runs the poll. So every failure is contained, and
  // only a persistent one ends the poll, with a reason.
  let failures = 0;
  const take = () => {
    let message;
    try {
      message = chat.claimOldest(cfg.dmHome);
    } catch (err) {
      failures += 1;
      process.stderr.write(`console: poll: could not read the inbox: ${err.message}\n`);
      if (failures < MAX_CONSECUTIVE_FAILURES) return;
      process.stderr.write(`console: poll: giving up after ${failures} failures in a row\n`);
      process.exit(1);
    }
    failures = 0;
    if (message) emit(message);
  };
  take();

  // fs.watch is the fast path; the interval is the correctness path (watch is
  // unreliable on some filesystems and drops events under load).
  const watcher = fs.watch(inbox, take);
  const ticker = setInterval(take, IDLE_RECHECK_MS);
  if (cfg.timeoutMs > 0) {
    setTimeout(() => {
      watcher.close();
      clearInterval(ticker);
      process.exit(3);
    }, cfg.timeoutMs);
  }
}

main();
