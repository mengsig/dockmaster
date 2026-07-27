#!/usr/bin/env node
// tests/check-console-queue.js - the console's message queue, pinned.
//
// The queue's whole promise is that nothing the operator sends is missed and
// nothing gets stuck. That promise rests on three renames, and every one of them
// has a failure mode worth a test:
//
//   1. inbox -> claiming    the claim. Atomic, so two pollers cannot both win a
//                           message, and per-message, so a partial drain is fine.
//   2. claiming -> claimed   the acknowledgement, made only after the text is out
//                           of stdout. A poller that dies before that has not
//                           delivered anything, and the message is still owed.
//   3. claiming -> inbox     the recovery of a claim whose poller is gone. Without
//                           it, a poll killed in the wrong millisecond took a
//                           message off the queue permanently and silently.
//
// It also pins the delivery FORM: one read drains everything queued, oldest
// first, bounded, and a message big enough to fill a pipe arrives whole - an
// exit() before stdout flushed used to truncate it, and the claim was gone.
//
// Node stdlib, a temp home, no server, no network, no shell.

const { spawn, spawnSync } = require('child_process')
const fs = require('fs')
const os = require('os')
const path = require('path')

const ROOT = process.env.DM_CHECK_ROOT ? path.resolve(process.env.DM_CHECK_ROOT) : path.join(__dirname, '..')
const chat = require(path.join(ROOT, 'ui', 'chat.js'))
const POLL = path.join(ROOT, 'ui', 'poll.js')

let checks = 0
function ok(condition, message) {
  checks += 1
  if (!condition) throw new Error(message)
}
const equal = (actual, expected, message) =>
  ok(actual === expected, `${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)

// --- a home, and the three directories the queue lives in --------------------

function makeHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-console-queue-'))
  fs.mkdirSync(path.join(home, 'state'), { recursive: true })
  chat.ensureDirs(home)
  return home
}

const dirOf = (home, which) => path.join(home, 'state', 'ui', which)
const names = (home, which) => fs.readdirSync(dirOf(home, which)).filter((n) => n.endsWith('.json')).sort()
const count = (home, which) => names(home, which).length

// Poll an observable condition until it holds, rather than assume a fixed
// delay was enough. A slow CI runner needs longer than a fast dev box to even
// start claiming; a fixed sleep either wastes time or (as here) isn't enough.
//
// `describe` is called only at the ceiling, so the failure reports the state
// that actually held rather than a sentence written before the run.
async function waitUntil(condition, { intervalMs = 50, ceilingMs = 15000, describe } = {}) {
  const deadline = Date.now() + ceilingMs
  for (;;) {
    if (condition()) return
    if (Date.now() >= deadline) throw new Error(describe ? describe() : 'condition never became true')
    await new Promise((resolve) => setTimeout(resolve, intervalMs))
  }
}

// Drain the way poll.js does, acknowledging each message as delivered.
function drain(home, limit) {
  const delivered = []
  for (let i = 0; i < (limit || 100); i += 1) {
    const claim = chat.claimOldest(home)
    if (!claim) break
    delivered.push(claim.message.text)
    claim.acknowledge()
  }
  return delivered
}

function runPoll(home, timeoutSeconds) {
  return spawnSync(process.execPath, [POLL], {
    env: Object.assign({}, process.env, {
      DM_HOME: home,
      DM_UI_POLL_TIMEOUT: String(timeoutSeconds === undefined ? 2 : timeoutSeconds),
    }),
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
    timeout: 30000,
  })
}

// --- 1. what is queued, and in what order ------------------------------------

function checkOnlyOperatorMessagesAreQueued() {
  const home = makeHome()
  try {
    chat.append(home, 'dockmaster', 'the dockmaster speaks')
    equal(count(home, 'inbox'), 0, 'a reply is not queued for delivery - nothing polls for one')
    chat.append(home, 'operator', 'ship it')
    equal(count(home, 'inbox'), 1, 'an operator message is queued')
    equal(chat.read(home).messages.length, 2, 'both sides are in the transcript')
    equal(chat.pendingCount(home), 1, 'one message is owed an answer')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// Filename order IS queue order, and a burst of messages from the page lands
// inside the same millisecond. Without a tiebreaker the order within that
// millisecond came from Math.random(). The clock is pinned so the burst is
// GUARANTEED to collide rather than left to how fast the disk happens to be.
function checkOrderSurvivesABurst() {
  const home = makeHome()
  const realNow = Date.now
  try {
    Date.now = () => 1700000000000
    const sent = []
    for (let i = 0; i < 40; i += 1) {
      sent.push(`message ${i}`)
      chat.append(home, 'operator', `message ${i}`)
    }
    Date.now = realNow
    const millisecond = new Set(names(home, 'inbox').map((n) => n.split('-')[0]))
    equal(millisecond.size, 1, 'the whole burst shares one millisecond, so only the tiebreaker can order it')
    equal(drain(home).join('|'), sent.join('|'), 'the queue delivers a burst in the order it was sent')
  } finally {
    Date.now = realNow
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// --- 2. one read takes everything waiting ------------------------------------

function checkOneReadDrainsTheQueue() {
  const home = makeHome()
  try {
    const sent = ['alpha', 'bravo', 'charlie']
    for (const text of sent) chat.append(home, 'operator', text)
    const run = runPoll(home)
    equal(run.status, 0, `one poll delivers a backlog (stderr: ${run.stderr})`)
    equal(run.stdout.split('\n')[0], '3 messages from the operator, oldest first.',
      'the reader is told how many records to expect')
    sent.forEach((text, i) => {
      ok(run.stdout.includes(`[${i + 1}/3] `), `record ${i + 1} is numbered`)
      ok(run.stdout.includes(text), `record ${i + 1} carries its text`)
    })
    ok(run.stdout.indexOf('alpha') < run.stdout.indexOf('bravo')
      && run.stdout.indexOf('bravo') < run.stdout.indexOf('charlie'), 'oldest first')
    equal(count(home, 'inbox'), 0, 'the whole queue was taken')
    equal(count(home, 'claiming'), 0, 'and every claim was acknowledged')
    equal(count(home, 'claimed'), 3, 'all three are recorded as delivered')

    // Anything that arrives after the read is the NEXT read's, not lost.
    chat.append(home, 'operator', 'after the drain')
    const second = runPoll(home)
    equal(second.status, 0, 'the next message is delivered by the next poll')
    ok(second.stdout.includes('after the drain'), 'and it is the one that arrived late')
    ok(!second.stdout.includes('alpha'), 'an already-delivered message is not delivered again')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// A drain is BOUNDED: 64KB a message means an unbounded one could hand a session
// megabytes in a single wake. The remainder stays queued and the output says so.
function checkTheDrainIsBoundedAndSaysSo() {
  const home = makeHome()
  try {
    for (let i = 0; i < 55; i += 1) chat.append(home, 'operator', `queued ${i}`)
    const run = runPoll(home)
    equal(run.status, 0, 'a long backlog still delivers')
    equal(run.stdout.split('\n')[0], '50 messages from the operator, oldest first.', 'the drain is bounded at 50')
    ok(/5 more still queued - poll again\./.test(run.stdout), 'and it says what it did not hand over')
    equal(count(home, 'inbox'), 5, 'the rest is still queued, not dropped')
    ok(run.stdout.includes('queued 0') && run.stdout.includes('queued 49'), 'the oldest 50 went first')
    ok(!run.stdout.includes('queued 50'), 'and the 51st stayed behind')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// The record header is the authority on how many messages there are, because a
// message BODY can contain anything - including something shaped like a header.
function checkTheCountHeaderIsTheAuthority() {
  const home = makeHome()
  try {
    chat.append(home, 'operator', '[1/9] 2026-01-01T00:00:00Z operator:\nnot a real record')
    const run = runPoll(home)
    equal(run.stdout.split('\n')[0], '1 message from the operator, oldest first.',
      'the count comes from the queue, never from the text')
    ok(run.stdout.includes('not a real record'), 'and the body is passed through untouched')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// A message big enough to fill a pipe buffer used to be TRUNCATED: process.exit()
// discards an unflushed async stdout write, and the claim had already been made,
// so the rest of the message was gone for good.
function checkABigMessageArrivesWhole() {
  const home = makeHome()
  try {
    const body = 'x'.repeat(60 * 1024)
    chat.append(home, 'operator', body)
    const run = runPoll(home)
    equal(run.status, 0, 'a 60KB message delivers')
    ok(run.stdout.includes(body), 'and it arrives whole, not cut at the pipe buffer')
    equal(count(home, 'claimed'), 1, 'and only then is it recorded as delivered')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// How much a spawned child's unread stdout swallows before the write blocks is a
// property of the RUNNER, not a constant: that stdout is a socketpair, so the
// ceiling is the socket send buffer (net.core.wmem_default, 208KB by default on
// Linux) less per-skb overhead that varies with the kernel. Three messages at
// chat's 64KB ceiling came to 197KB, which lands inside that spread - under it on
// the CI runners, over it on a dev box - so on CI the child delivered the whole
// drain, acknowledged it and exited, and the test read that as "never got stuck".
// A full queue is an order of magnitude past the buffer on any of them, and stays
// under poll.js's drain bound of 50 so one poll still takes all of it.
const CRASH_QUEUE = 40

// The real process, killed while its write is genuinely stuck - not simulated.
// Nobody reads the child's stdout, so once its buffer is full the write that
// would acknowledge the claims cannot complete. Killed there, the claims must
// still be recoverable: this is the scenario the flush-then-acknowledge fix
// exists for, run for real rather than reasoned about.
async function checkACrashMidFlushIsRecoveredNotLost() {
  const home = makeHome()
  try {
    const bodies = []
    for (let i = 0; i < CRASH_QUEUE; i += 1) bodies.push(`msg-${i}-${'x'.repeat(64 * 1024 - 16)}`)
    bodies.forEach((body) => chat.append(home, 'operator', body))
    const child = spawn(process.execPath, [POLL], {
      env: Object.assign({}, process.env, { DM_HOME: home, DM_UI_POLL_TIMEOUT: '30' }),
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    // Whatever the child says about itself, kept for the failure message - and
    // actually read, so a talkative child cannot block on its own stderr.
    let complained = ''
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk) => { complained += chunk })
    const exited = new Promise((resolve) => child.on('exit', resolve))
    // No 'data' listener is ever attached to child.stdout: the buffer fills and
    // stays full, so the write callback that would call acknowledge() never
    // fires. How long the child takes to even start claiming varies with
    // runner speed, so poll for the stuck state rather than assume a fixed
    // delay was enough - a slow CI runner just needs more of the ceiling.
    await waitUntil(() => count(home, 'claiming') === CRASH_QUEUE && count(home, 'claimed') === 0, {
      // The premise can fail two ways that need opposite fixes, and only the
      // state at the ceiling tells them apart: a child that never ran (nothing
      // claimed, an exit code, something on stderr), or one whose stdout took
      // the whole drain and acknowledged it (nothing left to kill mid-write).
      describe: () => `the child never reached the stuck-writing state: inbox=${count(home, 'inbox')}`
        + ` claiming=${count(home, 'claiming')} claimed=${count(home, 'claimed')}`
        + ` exit=${child.exitCode} signal=${child.signalCode}`
        + (count(home, 'claimed') > 0
          ? `; it delivered instead of blocking, so a ${CRASH_QUEUE}-message drain no longer`
            + " outruns this runner's stdout buffer"
          : '')
        + (complained ? `; child stderr: ${complained}` : '; the child said nothing on stderr'),
    })
    equal(count(home, 'claiming'), CRASH_QUEUE, 'the whole queue is claimed and stuck writing out')
    equal(count(home, 'claimed'), 0, 'and none is acknowledged yet')

    child.kill('SIGKILL')
    await exited
    equal(count(home, 'claimed'), 0, 'nothing was acknowledged before the crash')
    equal(chat.pendingCount(home), CRASH_QUEUE, 'every message is still owed')
    equal(drain(home).join('|'), bodies.join('|'), 'and the next poll delivers all of them, in order')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

function checkATimeoutWithNothingQueued() {
  const home = makeHome()
  try {
    const run = runPoll(home, 1)
    equal(run.status, 3, 'an empty queue times out with 3, not 0')
    equal(run.stdout, '', 'and prints nothing')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// --- 3. a poller that dies mid-claim loses nothing ---------------------------

// The claim is a rename, so it is off the inbox the instant it is taken. If the
// poller then dies before writing it out, nothing else knew the message existed.
// A pid that has never run is the same state as one that has exited.
function checkAnAbandonedClaimIsQueuedAgain() {
  const home = makeHome()
  try {
    chat.append(home, 'operator', 'taken by a poller that died')
    const name = names(home, 'inbox')[0]
    const dead = 0x7fffffff // no such process, and never will be
    fs.renameSync(path.join(dirOf(home, 'inbox'), name), path.join(dirOf(home, 'claiming'), `${dead}-${name}`))
    equal(count(home, 'inbox'), 0, 'the claim really did take it off the inbox')

    // The page must not report this as picked up: it is still owed.
    equal(chat.pendingCount(home), 1, 'an abandoned claim still counts as waiting for the dockmaster')
    equal(chat.abandonedClaims(dirOf(home, '')).length, 1, 'and it is reported as abandoned, by name')

    const delivered = drain(home)
    equal(delivered.join('|'), 'taken by a poller that died', 'the next poll delivers it after all')
    equal(count(home, 'claiming'), 0, 'and the claim is settled')
    equal(chat.pendingCount(home), 0, 'nothing is owed any more')
    equal(drain(home).length, 0, 'and it is not delivered a second time')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// The mirror image, and the one that matters more: a claim held by a poller that
// is ALIVE is being delivered right now. Taking it away would duplicate it.
async function checkALiveClaimIsLeftAlone() {
  const home = makeHome()
  try {
    chat.append(home, 'operator', 'in flight')
    const name = names(home, 'inbox')[0]
    // A real process, alive for the length of this check, that is not this one.
    const holder = spawn(process.execPath, ['-e', 'setTimeout(function () {}, 30000)'], { stdio: 'ignore' })
    const exited = new Promise((resolve) => holder.on('exit', resolve))
    fs.renameSync(path.join(dirOf(home, 'inbox'), name),
      path.join(dirOf(home, 'claiming'), `${holder.pid}-${name}`))
    equal(chat.pendingCount(home), 0, 'a message being delivered is not still waiting')
    equal(drain(home).length, 0, 'another poller must not take a claim out from under a live one')
    equal(count(home, 'claiming'), 1, 'and it is left exactly where it was')

    // Once that poller is gone the same claim becomes recoverable. Awaiting the
    // exit event is what proves the pid is really gone: until this process reaps
    // the child it is a zombie, and a zombie still answers a liveness signal.
    holder.kill('SIGKILL')
    await exited
    equal(chat.pendingCount(home), 1, 'a claim whose poller has exited is owed again')
    equal(drain(home).join('|'), 'in flight', 'and it is delivered')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// Liveness LIES once a pid is recycled onto an unrelated process. A claim only
// exists for as long as one write to stdout takes, so an old one is abandoned
// whatever its pid now points at - otherwise that message is stuck forever.
function checkAStaleClaimIsRecoveredWhateverItsPidSaysNow() {
  const home = makeHome()
  try {
    chat.append(home, 'operator', 'claimed under a recycled pid')
    const name = names(home, 'inbox')[0]
    // This process is certainly alive, and is not the one skipped as "our own".
    const alive = process.ppid
    const claim = path.join(dirOf(home, 'claiming'), `${alive}-${name}`)
    fs.renameSync(path.join(dirOf(home, 'inbox'), name), claim)
    equal(chat.pendingCount(home), 0, 'a fresh claim under a live pid is in flight')

    const old = new Date(Date.now() - chat.STALE_CLAIM_MS - 60000)
    fs.utimesSync(claim, old, old)
    equal(chat.pendingCount(home), 1, 'an old claim is owed again however alive its pid looks')
    equal(drain(home).join('|'), 'claimed under a recycled pid', 'and it is delivered')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// rename() carries the ORIGINAL file's mtime across. If claiming did not
// restamp it, a message that had simply sat in the inbox a while looked like a
// claim that had sat unacknowledged a while - stolen back and re-delivered to
// a second poller the instant the first one took it.
//
// Claimed in THIS process, abandonedClaims() would skip it as "our own pid"
// regardless of the restamp - the skip that exists for the claim actively being
// delivered right now would silently cover for a missing fix. So a separate,
// live process does the claiming; its pid is foreign, and only the restamp
// keeps it from reading as an abandoned, stealable claim.
async function checkAFreshClaimOnAnOldMessageIsNotStolenBack() {
  const home = makeHome()
  let child
  try {
    chat.append(home, 'operator', 'old message, fresh claim')
    const name = names(home, 'inbox')[0]
    const old = new Date(Date.now() - chat.STALE_CLAIM_MS - 60000)
    fs.utimesSync(path.join(dirOf(home, 'inbox'), name), old, old)

    const script = `
      const chat = require(${JSON.stringify(path.join(ROOT, 'ui', 'chat.js'))})
      const claim = chat.claimOldest(${JSON.stringify(home)})
      if (!claim) { process.stdout.write('no-claim\\n'); process.exit(1) }
      process.stdout.write('claimed\\n')
      setInterval(() => {}, 1000)
    `
    child = spawn(process.execPath, ['-e', script], { stdio: ['ignore', 'pipe', 'inherit'] })
    const said = await new Promise((resolve, reject) => {
      let buf = ''
      child.stdout.on('data', (chunk) => {
        buf += chunk
        if (buf.includes('\n')) resolve(buf.split('\n')[0])
      })
      child.on('exit', (code) => reject(new Error(`the claiming process exited early (code ${code})`)))
    })
    equal(said, 'claimed', 'a separate, live process claims the old message')

    equal(chat.pendingCount(home), 0,
      'a fresh claim on an old message is not owed again, even under a pid that is not this process')
    equal(chat.claimOldest(home), null, 'and this process cannot take it either')
  } finally {
    if (child) child.kill('SIGKILL')
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// Two pollers, one message. Only one rename off a given name can succeed, so the
// loser must move on to the next message rather than fail or duplicate.
function checkTwoPollersCannotBothWinAMessage() {
  const home = makeHome()
  try {
    chat.append(home, 'operator', 'only once')
    const first = chat.claimOldest(home)
    ok(first !== null, 'the first poller wins it')
    // The second poller sees an empty inbox and a claim it must not touch.
    equal(chat.claimOldest(home), null, 'the second poller finds nothing to take')
    first.acknowledge()
    equal(count(home, 'claimed'), 1, 'the message is delivered exactly once')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// --- 4. an unreadable entry is set aside, never retried forever ---------------

// A 0-byte file is what a crashed writeFileSync leaves; the second is valid JSON
// of the wrong shape. Neither may be retried - a claim that keeps coming back is
// a queue that never drains - and neither may end the poll.
function checkAnUnreadableEntryIsSetAsideOnce() {
  const home = makeHome()
  try {
    fs.writeFileSync(path.join(dirOf(home, 'inbox'), '1000000000000-000001-0-torn.json'), '')
    fs.writeFileSync(path.join(dirOf(home, 'inbox'), '1000000000001-000001-0-shape.json'),
      '{"at":"2026-01-01T00:00:00Z"}\n')
    chat.append(home, 'operator', 'past the torn ones')

    const run = runPoll(home)
    equal(run.status, 0, 'the poll survives both')
    ok(run.stdout.includes('past the torn ones'), 'and delivers the real message behind them')
    equal(run.stdout.split('\n')[0], '1 message from the operator, oldest first.',
      'an unreadable entry is not counted as a message')
    equal(count(home, 'inbox'), 0, 'neither is left to retry')
    equal(count(home, 'claiming'), 0, 'and neither is left looking like a live claim')
    equal(names(home, 'claimed').filter((n) => /torn|shape/.test(n)).length, 2,
      'both are kept in claimed/ for inspection')
    equal(chat.pendingCount(home), 0, 'and nothing is reported as still waiting')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// A file in claiming/ that this module did not write is not guessed at: putting
// it on the inbox would deliver whatever it happens to be.
function checkAnUnrecognisedClaimIsLeftAlone() {
  const home = makeHome()
  try {
    fs.writeFileSync(path.join(dirOf(home, 'claiming'), 'not-a-claim.json'), '{"from":"operator","text":"x"}')
    equal(chat.pendingCount(home), 0, 'an unrecognised file in claiming/ is not counted as a message')
    equal(drain(home).length, 0, 'and it is never delivered')
    equal(count(home, 'claiming'), 1, 'it is left where it is, for a human to look at')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// --- 5. refusals at the boundary ---------------------------------------------

function checkTheQueueRefusesWhatItCannotStore() {
  const home = makeHome()
  try {
    const refuses = (fn, why) => {
      let threw = false
      try { fn() } catch (err) { threw = true }
      ok(threw, why)
    }
    refuses(() => chat.append(home, 'operator', '   '), 'an empty message is refused')
    refuses(() => chat.append(home, 'operator', 'x'.repeat(64 * 1024 + 1)), 'an oversized message is refused')
    refuses(() => chat.append(home, 'nobody', 'hello'), 'an unknown sender is refused')
    refuses(() => chat.append(home, 'operator', null), 'a non-string message is refused')
    refuses(() => chat.append('', 'operator', 'hello'), 'an empty home is refused')
    equal(count(home, 'inbox'), 0, 'not one refused message was queued')
    equal(chat.read(home).messages.length, 0, 'and none reached the transcript')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
}

// --- run ---------------------------------------------------------------------

async function main() {
  const cases = [
    ['only operator messages are queued', checkOnlyOperatorMessagesAreQueued],
    ['queue order survives a same-millisecond burst', checkOrderSurvivesABurst],
    ['one read drains the whole queue, oldest first', checkOneReadDrainsTheQueue],
    ['the drain is bounded and says what it left', checkTheDrainIsBoundedAndSaysSo],
    ['the record count comes from the queue, not the text', checkTheCountHeaderIsTheAuthority],
    ['a message big enough to fill a pipe arrives whole', checkABigMessageArrivesWhole],
    ['a real crash mid-flush is recovered, not lost', checkACrashMidFlushIsRecoveredNotLost],
    ['an empty queue times out with 3', checkATimeoutWithNothingQueued],
    ['a claim abandoned by a dead poller is queued again', checkAnAbandonedClaimIsQueuedAgain],
    ['a claim held by a live poller is left alone', checkALiveClaimIsLeftAlone],
    ['a stale claim is recovered whatever its pid says now', checkAStaleClaimIsRecoveredWhateverItsPidSaysNow],
    ['a fresh claim on an old message is not stolen back', checkAFreshClaimOnAnOldMessageIsNotStolenBack],
    ['two pollers cannot both win one message', checkTwoPollersCannotBothWinAMessage],
    ['an unreadable entry is set aside exactly once', checkAnUnreadableEntryIsSetAsideOnce],
    ['an unrecognised claim is left alone', checkAnUnrecognisedClaimIsLeftAlone],
    ['the queue refuses what it cannot store', checkTheQueueRefusesWhatItCannotStore],
  ]
  for (const [label, run] of cases) {
    await run()
    console.log(`ok   ${label}`)
  }
  console.log(`\nconsole queue checks passed (${checks} assertions)`)
}

main().catch((err) => { console.error(`\nFAIL ${err.message}`); process.exit(1) })
