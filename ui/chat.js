// chat.js - the durable operator <-> dockmaster message queue behind the console.
//
// Four files/directories, one owner (this module). Nothing else reads or writes them.
//
//   state/ui/chat.jsonl   append-only transcript, one JSON object per line.
//                         Both sides append; the page renders it.
//   state/ui/inbox/       one file per operator message the dockmaster has not
//                         picked up yet.
//   state/ui/claiming/    a message a poller has taken off the inbox but has NOT
//                         yet delivered. Named `<pid>-<inbox name>`, so an entry
//                         whose poller died is recognisable and is put back.
//   state/ui/claimed/     terminal: delivered, or set aside as unreadable. Kept
//                         for inspection; never re-delivered.
//
// DELIVERY IS THREE RENAMES, and every one of them is atomic:
//
//   inbox -> claiming     the claim. Only one rename off a given name can win,
//                         so two concurrent pollers cannot both take a message.
//   claiming -> claimed   the acknowledgement, made only AFTER the message is
//                         out of the poller's stdout. Until then the message is
//                         still owed, so a poller killed mid-delivery loses
//                         nothing: the next poll finds the abandoned claim and
//                         queues it again. The residual risk is the mirror
//                         image - killed between the flush and the rename means
//                         one duplicate delivery - and that is the direction to
//                         err in, because a duplicate is visible and a drop is
//                         not.
//   claiming -> inbox     the recovery, for a claim whose poller is gone.
//
// The transcript is the display truth; the inbox is the delivery truth. An
// operator message writes the transcript first, then the inbox, so a FAILED
// inbox write is reported to the operator as "not sent" - which is true, and a
// resend delivers exactly once. A hard kill between those two adjacent
// synchronous writes leaves a message shown but never delivered; both writes are
// synchronous and adjacent to keep that window as small as a two-file queue can.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const MAX_TEXT_BYTES = 64 * 1024;
const SENDERS = ['operator', 'dockmaster'];

// A claim lives for as long as one write to stdout takes. One this old belongs to
// a poller whose pid has been recycled onto something else, so liveness lies -
// this is the backstop that keeps such a message from being stuck forever.
const STALE_CLAIM_MS = 10 * 60 * 1000;

// Queue order is the FILENAME order, and two messages can land in the same
// millisecond. This counter breaks that tie for messages from one process (the
// server posts every message the page sends), which is the case that has an
// order worth preserving.
let sequence = 0;

function uiDir(dmHome) {
  if (typeof dmHome !== 'string' || dmHome.length === 0) {
    throw new TypeError('chat: dmHome must be a non-empty path');
  }
  return path.join(dmHome, 'state', 'ui');
}

function ensureDirs(dmHome) {
  const dir = uiDir(dmHome);
  for (const name of ['inbox', 'claiming', 'claimed']) {
    fs.mkdirSync(path.join(dir, name), { recursive: true });
  }
  return dir;
}

// append(dmHome, from, text) -> the stored message.
// An operator message is also queued for delivery; a dockmaster reply is not
// (the page pulls it, nothing polls for it).
function append(dmHome, from, text) {
  if (!SENDERS.includes(from)) throw new TypeError(`chat: unknown sender '${from}'`);
  if (typeof text !== 'string') throw new TypeError('chat: text must be a string');
  const body = text.trim();
  if (body.length === 0) throw new RangeError('chat: refusing an empty message');
  if (Buffer.byteLength(body, 'utf8') > MAX_TEXT_BYTES) {
    throw new RangeError(`chat: message exceeds ${MAX_TEXT_BYTES} bytes`);
  }

  const dir = ensureDirs(dmHome);
  const message = { at: new Date().toISOString(), from, text: body };
  const line = JSON.stringify(message) + '\n';
  fs.appendFileSync(path.join(dir, 'chat.jsonl'), line, 'utf8');

  if (from === 'operator') {
    sequence += 1;
    // Widened past what any single process realistically sends: padStart never
    // truncates, so once `sequence` outgrew the pad width, a same-millisecond
    // tie between a 6-digit and a 7-digit sequence sorted by string length
    // first ("999999" > "1000000" as text) rather than by count.
    const seq = String(sequence).padStart(9, '0');
    const name = `${Date.now()}-${seq}-${process.pid}-${Math.random().toString(36).slice(2, 8)}.json`;
    fs.writeFileSync(path.join(dir, 'inbox', name), line, 'utf8');
  }
  return message;
}

// read(dmHome) -> { messages, unreadable }, oldest first.
//
// A line that will not parse is COUNTED, never silently dropped and never
// fatal. Two processes append to this file, so one torn write is a real
// possibility - and it must not take the conversation, or the server, down with
// it. The count crosses to the page, which says how much it could not read;
// dropping a line without saying so is the outcome this avoids.
function read(dmHome) {
  const file = path.join(uiDir(dmHome), 'chat.jsonl');
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return { messages: [], unreadable: 0 };
    throw err;
  }
  const messages = [];
  let unreadable = 0;
  for (const line of raw.split('\n')) {
    if (line.trim().length === 0) continue;
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch (err) {
      unreadable += 1;
      process.stderr.write(`console: chat: a line of ${file} is not valid JSON: ${err.message}\n`);
      continue;
    }
    if (parsed === null || typeof parsed !== 'object' || typeof parsed.text !== 'string'
      || !SENDERS.includes(parsed.from)) {
      unreadable += 1;
      process.stderr.write(`console: chat: a line of ${file} is not a message\n`);
      continue;
    }
    messages.push(parsed);
  }
  return { messages, unreadable };
}

function jsonNames(dir) {
  try {
    return fs.readdirSync(dir).filter((n) => n.endsWith('.json')).sort();
  } catch (err) {
    if (err.code === 'ENOENT') return [];
    throw err;
  }
}

const inboxNames = (dmHome) => jsonNames(path.join(uiDir(dmHome), 'inbox'));

// A pid we are not allowed to signal is alive under another user; only ESRCH -
// no such process - means the poller that took this claim is gone.
function pollerAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === 'EPERM';
  }
}

// A claim entry is `<pid>-<the inbox name it came from>`. Anything else in
// claiming/ was not written by this module and is left alone rather than guessed
// at: putting an unrecognised file into the inbox would deliver whatever it is.
function parseClaim(entry) {
  const dash = entry.indexOf('-');
  if (dash <= 0) return null;
  const pid = Number(entry.slice(0, dash));
  const name = entry.slice(dash + 1);
  if (!Number.isInteger(pid) || pid <= 0 || !name.endsWith('.json')) return null;
  return { pid, name };
}

function claimIsStale(file) {
  let stat;
  try {
    stat = fs.statSync(file);
  } catch (err) {
    // Gone means another poller already recovered or acknowledged it.
    if (err.code === 'ENOENT') return false;
    throw err;
  }
  return Date.now() - stat.mtimeMs > STALE_CLAIM_MS;
}

// abandonedClaims(dir) -> [{ entry, name }] for every claim whose poller will
// never deliver it. READ-ONLY: the page's pending count uses this too, and a GET
// must not move the queue around.
function abandonedClaims(dir) {
  const claiming = path.join(dir, 'claiming');
  const abandoned = [];
  for (const entry of jsonNames(claiming)) {
    const claim = parseClaim(entry);
    if (!claim) continue;
    // Our own claim is the one being delivered right now.
    if (claim.pid === process.pid) continue;
    if (pollerAlive(claim.pid) && !claimIsStale(path.join(claiming, entry))) continue;
    abandoned.push({ entry, name: claim.name });
  }
  return abandoned;
}

// What the dockmaster still owes an answer to: the inbox, plus every message a
// dead poller took and never delivered. Leaving the second group out was the
// reassuring half of the count - the page said nothing was waiting while a
// message sat undeliverable in claiming/.
function pendingCount(dmHome) {
  const dir = uiDir(dmHome);
  return inboxNames(dmHome).length + abandonedClaims(dir).length;
}

// Put every abandoned claim back on the inbox. The rename IS the handover, so
// two pollers recovering at once cannot both take the same message.
function recoverAbandoned(dir) {
  for (const { entry, name } of abandonedClaims(dir)) {
    try {
      fs.renameSync(path.join(dir, 'claiming', entry), path.join(dir, 'inbox', name));
    } catch (err) {
      if (err.code === 'ENOENT') continue; // another poller got there first
      throw err;
    }
    process.stderr.write('console: chat: a poller stopped before delivering a message; it is queued again\n');
  }
}

// claimOldest(dmHome) -> { message, acknowledge } for the oldest undelivered
// operator message, or null. The caller MUST call acknowledge() only once the
// message has actually left its stdout; until then the claim is recoverable.
//
// An entry that will not parse is SET ASIDE, not thrown: the rename has already
// taken it out of the inbox, so it cannot be retried and cannot loop - and
// throwing here killed the poller, which is the dockmaster's whole wake
// mechanism. It is reported loudly and the next message is delivered.
function claimOldest(dmHome) {
  const dir = ensureDirs(dmHome);
  recoverAbandoned(dir);
  for (const name of inboxNames(dmHome)) {
    const from = path.join(dir, 'inbox', name);
    const claim = path.join(dir, 'claiming', `${process.pid}-${name}`);
    const settled = path.join(dir, 'claimed', name);
    try {
      fs.renameSync(from, claim);
    } catch (err) {
      if (err.code === 'ENOENT') continue; // another poller took it; try the next
      throw err;
    }
    // rename() carries the inbox mtime across, not the claim time - the stale
    // rule measures how long THIS CLAIM has sat unacknowledged, so it must be
    // stamped now or an old message is stolen back the instant it is claimed.
    const now = new Date();
    fs.utimesSync(claim, now, now);
    const message = readClaimed(claim);
    if (message) return { message, acknowledge: () => fs.renameSync(claim, settled) };
    fs.renameSync(claim, settled);
    process.stderr.write(`console: chat: ${settled} is not a readable operator message; it was set aside\n`);
  }
  return null;
}

function readClaimed(file) {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    if (err instanceof SyntaxError) return null;
    throw err;
  }
  if (parsed === null || typeof parsed !== 'object') return null;
  if (typeof parsed.text !== 'string' || parsed.from !== 'operator') return null;
  return parsed;
}

module.exports = {
  uiDir, ensureDirs, append, read, pendingCount, claimOldest, abandonedClaims, STALE_CLAIM_MS,
};
