// chat.js - the durable operator <-> dockmaster message queue behind the console.
//
// Two files, one owner (this module). Nothing else reads or writes them.
//
//   state/ui/chat.jsonl   append-only transcript, one JSON object per line.
//                         Both sides append; the page renders it.
//   state/ui/inbox/       one file per operator message the dockmaster has not
//                         picked up yet. `dm-ui.sh poll` claims the oldest by
//                         RENAMING it into claimed/ - a rename is atomic, so a
//                         killed poll loses nothing and a re-poll finds it.
//
// The transcript is the display truth; the inbox is the delivery truth. They are
// written in that order, so a crash can duplicate a delivery, never drop one.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const MAX_TEXT_BYTES = 64 * 1024;
const SENDERS = ['operator', 'dockmaster'];

function uiDir(dmHome) {
  if (typeof dmHome !== 'string' || dmHome.length === 0) {
    throw new TypeError('chat: dmHome must be a non-empty path');
  }
  return path.join(dmHome, 'state', 'ui');
}

function ensureDirs(dmHome) {
  const dir = uiDir(dmHome);
  fs.mkdirSync(path.join(dir, 'inbox'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'claimed'), { recursive: true });
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
    const name = `${Date.now()}-${process.pid}-${Math.random().toString(36).slice(2, 8)}.json`;
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

function inboxNames(dmHome) {
  try {
    return fs.readdirSync(path.join(uiDir(dmHome), 'inbox')).filter((n) => n.endsWith('.json')).sort();
  } catch (err) {
    if (err.code === 'ENOENT') return [];
    throw err;
  }
}

function pendingCount(dmHome) {
  return inboxNames(dmHome).length;
}

// claimOldest(dmHome) -> the oldest undelivered operator message, or null.
// The rename IS the claim: two concurrent pollers cannot both win it, because
// only one rename off a given name succeeds.
function claimOldest(dmHome) {
  const dir = ensureDirs(dmHome);
  for (const name of inboxNames(dmHome)) {
    const from = path.join(dir, 'inbox', name);
    const to = path.join(dir, 'claimed', name);
    try {
      fs.renameSync(from, to);
    } catch (err) {
      if (err.code === 'ENOENT') continue; // another poller took it; try the next
      throw err;
    }
    const message = JSON.parse(fs.readFileSync(to, 'utf8'));
    if (typeof message.text !== 'string' || message.from !== 'operator') {
      throw new Error(`chat: claimed message ${name} is not an operator message`);
    }
    return message;
  }
  return null;
}

module.exports = { uiDir, ensureDirs, append, read, pendingCount, claimOldest };
