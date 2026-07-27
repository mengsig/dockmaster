// poll.js - block until the operator says something, print EVERYTHING queued, exit.
//
// This is what a dockmaster session waits on: it costs nothing while idle and
// wakes the session the moment a message lands, the same shape as
// `lavish-axi poll`. One read drains the whole queue, oldest first, so a session
// that was away does not have to poll once per backlogged message.
//
// Claiming is one atomic rename PER MESSAGE and the claim is acknowledged only
// once the bytes are out of stdout, so a killed or timed-out poll loses nothing -
// mid-drain included. Re-run it and everything still owed is delivered again.
//
// Exit: 0 printed at least one message, 3 timed out with nothing queued, 1 could
// not read the inbox at all or could not write what it claimed. A single
// unreadable queue entry is set aside and reported; it never ends the poll,
// because nothing restarts one.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const chat = require('./chat');

// A reader that closes early (the operator's shell piping this into `head`, a
// killed terminal) can turn the write into an EPIPE reported as a stream
// 'error' event rather than through write()'s own callback. Unhandled, that is
// an uncaught exception - the one thing here worse than losing a message is
// crashing before the failure is even reported. Nothing to do about it beyond
// what an ordinary write error already does: leave the claim unacknowledged.
process.stdout.on('error', (err) => {
  // Whatever closed stdout - a killed terminal - very often took stderr with
  // it, and a throw from THIS write is an uncaught exception raised inside the
  // handler that exists to prevent one. There is nowhere left to report to at
  // that point; the nonzero exit is the whole signal.
  try {
    process.stderr.write(`console: poll: stdout failed (${err.message}); nothing was acknowledged\n`);
  } catch (ignored) { /* stderr is gone too */ }
  process.exitCode = 1;
});

const IDLE_RECHECK_MS = 1000;
// A poll that cannot read its inbox at all is broken, not busy. It says so and
// exits rather than spinning silently while the dockmaster waits on it.
const MAX_CONSECUTIVE_FAILURES = 5;
// A message is up to 64KB, so an unbounded drain could hand the session megabytes
// in one wake. Past this the rest STAYS QUEUED and the output says so.
const MAX_DRAIN = 50;

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

// Every record carries its own index, count and stamp, so a reader can tell how
// many messages it was handed and where each one starts - and can see when the
// output was cut short rather than assuming it has everything.
function render(messages, remaining) {
  const n = messages.length;
  let out = `${n} ${n === 1 ? 'message' : 'messages'} from the operator, oldest first.\n`;
  messages.forEach((message, i) => {
    out += `\n[${i + 1}/${n}] ${message.at} operator:\n${message.text}\n`;
  });
  if (remaining > 0) out += `\n${remaining} more still queued - poll again.\n`;
  return out;
}

// The watch, the recheck and the timeout, held so a delivery can stop all three:
// nothing may claim another message while the ones in hand are being written out.
let watcher = null;
let ticker = null;
let deadline = null;

function stopWaiting() {
  if (watcher) { watcher.close(); watcher = null; }
  if (ticker) { clearInterval(ticker); ticker = null; }
  if (deadline) { clearTimeout(deadline); deadline = null; }
}

// emit(dmHome, claims) - write the claimed messages out, then acknowledge them.
//
// NOT process.exit(): stdout is an asynchronous stream when it is a pipe on
// macOS, and exit() discards whatever has not flushed. The claims are already
// made, so a truncated write with an immediate exit is how a message gets both
// taken off the queue and lost. Acknowledging inside the write callback means an
// unwritten message stays claimable, and the process ends on its own once
// nothing is left to do.
function emit(dmHome, claims) {
  stopWaiting();
  const text = render(claims.map((claim) => claim.message), chat.pendingCount(dmHome));
  process.stdout.write(text, (err) => {
    if (err) {
      process.stderr.write(`console: poll: could not write the operator's message out: ${err.message}\n`);
      // Every claim is still unacknowledged, so the next poll delivers them.
      process.exitCode = 1;
      return;
    }
    for (const claim of claims) {
      try {
        claim.acknowledge();
      } catch (ackErr) {
        // The message WAS delivered; only the record of that failed. Say so -
        // the recovery path will offer it again, which is a duplicate, not a loss.
        process.stderr.write(`console: poll: delivered a message but could not record it (${ackErr.message}); it may be delivered a second time\n`);
      }
    }
  });
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
  // -> true once it has delivered, so the first call does not go on to arm a wait
  // this poll has already finished.
  const take = () => {
    const claims = [];
    let failure = null;
    try {
      while (claims.length < MAX_DRAIN) {
        const claim = chat.claimOldest(cfg.dmHome);
        if (!claim) break;
        claims.push(claim);
      }
    } catch (err) {
      failure = err;
      process.stderr.write(`console: poll: could not read the inbox: ${err.message}\n`);
    }
    // Deliver what is already in hand even when the drain then failed. A claim
    // held past here is invisible to this poller - it is its own - so it would
    // sit undelivered until the process exits.
    if (claims.length > 0) {
      failures = 0;
      emit(cfg.dmHome, claims);
      return true;
    }
    if (!failure) { failures = 0; return false; }
    failures += 1;
    if (failures < MAX_CONSECUTIVE_FAILURES) return false;
    process.stderr.write(`console: poll: giving up after ${failures} failures in a row\n`);
    process.exit(1);
  };
  if (take()) return;

  // fs.watch is the fast path; the interval is the correctness path (watch is
  // unreliable on some filesystems and drops events under load). The watcher's
  // own error event is contained for the same reason `take` is: unhandled, it
  // ends the poll, and the interval can carry on alone.
  watcher = fs.watch(inbox, take);
  watcher.on('error', (err) => {
    process.stderr.write(`console: poll: the inbox watch failed (${err.message}); still rechecking every ${IDLE_RECHECK_MS}ms\n`);
    if (watcher) { watcher.close(); watcher = null; }
  });
  ticker = setInterval(take, IDLE_RECHECK_MS);
  if (cfg.timeoutMs > 0) {
    deadline = setTimeout(() => {
      stopWaiting();
      process.exit(3);
    }, cfg.timeoutMs);
  }
}

main();
