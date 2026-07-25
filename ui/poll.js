// poll.js - block until the operator says something, print it, exit.
//
// This is what a dockmaster session waits on: it costs nothing while idle and
// wakes the session the moment a message lands, the same shape as
// `lavish-axi poll`. Claiming is a rename, so a killed or timed-out poll loses
// nothing - re-run it and the queued message is still there.
//
// Exit: 0 printed a message, 3 timed out with nothing queued.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const chat = require('./chat');

const IDLE_RECHECK_MS = 1000;

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

  const take = () => {
    const message = chat.claimOldest(cfg.dmHome);
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
