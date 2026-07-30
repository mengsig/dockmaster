#!/usr/bin/env node
// tests/check-console-listeners.js - the review listeners the console owns (#219).
//
// A leaked poller is the failure this pins: it is invisible, it holds a lavish
// session nobody can see, and nothing on screen would say so. Every way one can
// be left behind gets a case - the page saying stop, the page going away without
// saying anything, the poll ending from lavish's own side, and the console
// exiting - plus the two that would double or lose the operator's words: a
// second listener on one file, and feedback that never reaches the queue.
//
// lavish-axi is optional and absent on CI, so it is STUBBED on PATH: the real
// bin/dm-lavish.sh runs, and what it execs is a script this file writes. The
// "not installed at all" degrade gets its own case rather than a skip.
//
// Node stdlib, a temp home, an ephemeral port. No network.

const { spawn, spawnSync } = require('child_process')
const fs = require('fs')
const http = require('http')
const net = require('net')
const os = require('os')
const path = require('path')

const ROOT = process.env.DM_CHECK_ROOT ? path.resolve(process.env.DM_CHECK_ROOT) : path.join(__dirname, '..')
const BIN = path.join(ROOT, 'bin')
const { createListeners } = require(path.join(ROOT, 'ui', 'listeners.js'))
const BOOT_TIMEOUT_MS = 15000
const BOOT_ATTEMPTS = 3
const SETTLE_MS = 5000

let checks = 0
function ok(condition, message) {
  checks += 1
  if (!condition) throw new Error(message)
}
const equal = (actual, expected, message) =>
  ok(actual === expected, `${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// Waits for a condition rather than for a duration: a fixed sleep is either a
// flake or wasted wall clock, and here it would be both.
async function until(what, condition) {
  const started = Date.now()
  while (Date.now() - started < SETTLE_MS) {
    const value = await condition()
    if (value) return value
    await sleep(25)
  }
  throw new Error(`timed out waiting for ${what}`)
}

// ESRCH - no such process - is the only answer that means the poller is gone.
// EPERM means it is alive under another user, which is still alive.
// Not an `ok()`: this is polled in a loop, and counting it would make the
// suite's own assertion total depend on timing.
function alive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) throw new Error(`no pid was captured (${pid})`)
  try {
    process.kill(pid, 0)
    return true
  } catch (err) {
    return err.code === 'EPERM'
  }
}

function freePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer()
    probe.on('error', reject)
    probe.listen(0, '127.0.0.1', () => {
      const { port } = probe.address()
      probe.close(() => resolve(port))
    })
  })
}

function request(port, method, urlPath, headers, body) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path: urlPath, headers: headers || {} }, (res) => {
      let text = ''
      res.setEncoding('utf8')
      res.on('data', (chunk) => { text += chunk })
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text }))
    })
    req.on('error', reject)
    if (body !== undefined) req.write(body)
    req.end()
  })
}

const json = (res) => JSON.parse(res.text)
const postJson = (port, urlPath, value) => request(port, 'POST', urlPath,
  { 'content-type': 'application/json' }, JSON.stringify(value))

// --- the world under test ----------------------------------------------------

// A stub `lavish-axi` on PATH, so the REAL bin/dm-lavish.sh is what runs.
//   talk    prints feedback, then holds the session open
//   quit    prints and exits - lavish ending the session from its own side
//   silent  holds the session open and says nothing
//
// `exec sleep` so the pid dm-lavish.sh exec'd stays the pid that is holding on:
// a SIGTERM must reach the thing that is actually running.
function stubLavish(dir, mode, log) {
  fs.mkdirSync(dir, { recursive: true })
  const file = path.join(dir, 'lavish-axi')
  fs.writeFileSync(file, '#!/usr/bin/env bash\n'
    + `printf '%s %s\\n' "$$" "$*" >> ${JSON.stringify(log)}\n`
    + (mode === 'talk' ? "printf 'Rename the button.\\nAnd add a test.\\n'\n" : '')
    + (mode === 'quit' ? "printf 'the session ended\\n'\nexit 0\n" : 'exec sleep 60\n'))
  fs.chmodSync(file, 0o755)
  return dir
}

function withPath(dir, fn) {
  const previous = process.env.PATH
  process.env.PATH = `${dir}${path.delimiter}${previous}`
  try {
    return fn()
  } finally {
    process.env.PATH = previous
  }
}

function makeHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-console-listen-'))
  fs.mkdirSync(path.join(home, 'state'), { recursive: true })
  fs.mkdirSync(path.join(home, 'data'), { recursive: true })
  return home
}

// A review with an artifact and a task record behind it, exactly as the console
// finds one: dm-lavish.sh lists it because the file is there.
function makeReview(home, id, title) {
  const dir = path.join(home, 'data', id, 'lavish')
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(path.join(dir, 'change.html'), '<p>the change</p>')
  if (title) {
    const created = spawnSync(path.join(BIN, 'dm-task.sh'),
      ['new', id, '--kind', 'ship', '--repo', 'dockmaster', '--title', title],
      { env: Object.assign({}, process.env, { DM_HOME: home }), encoding: 'utf8' })
    equal(created.status, 0, `the task behind '${id}' is created: ${created.stderr}`)
  }
  return `/review/${id}/`
}

const transcript = (home) => path.join(home, 'state', 'ui', 'chat.jsonl')
function messages(home) {
  if (!fs.existsSync(transcript(home))) return []
  return fs.readFileSync(transcript(home), 'utf8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l))
}
const inboxCount = (home) => {
  const dir = path.join(home, 'state', 'ui', 'inbox')
  return fs.existsSync(dir) ? fs.readdirSync(dir).length : 0
}
const pidsFrom = (log) => (fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean) : [])

// --- 1. one review, one listener, and its feedback reaches the queue ---------

async function checkOpeningArmsExactlyOneListenerAndRelaysFeedback() {
  const home = makeHome()
  const log = path.join(home, 'poll.log')
  const href = makeReview(home, 'demo-listen-talk', 'A change to annotate')
  const listeners = withPath(stubLavish(path.join(home, 'stub'), 'talk', log),
    () => createListeners({ dmHome: home, bin: BIN }))
  try {
    equal(listeners.arm(href, 'demo-listen-talk', { title: 'A change to annotate', repo: 'dockmaster' }),
      'listening', 'opening a review arms a listener')
    const pid = await until('the poller to be running', () => {
      const rows = pidsFrom(log)
      return rows.length === 1 ? Number(rows[0].split(' ')[0]) : null
    })
    ok(alive(pid), 'the poller is a real process')
    ok(pidsFrom(log)[0].includes('poll '), 'and it was asked to poll, with the artifact')

    // Feedback arrives on the SAME queue a typed message uses - transcript for
    // the page, inbox for delivery - so nothing else has to be built to carry it.
    const said = await until('the feedback to reach the queue',
      () => messages(home).find((m) => m.text.includes('Rename the button.')))
    equal(said.from, 'operator', 'the operator is who said it')
    ok(said.text.includes('And add a test.'),
      `the whole block arrives as one message, not one per line: ${JSON.stringify(said.text)}`)
    ok(said.text.includes('A change to annotate') && said.text.includes('dockmaster'),
      'and it names the work the way the operator sees it')
    ok(!said.text.includes('demo-listen-talk'), 'never by task id')
    equal(inboxCount(home), 1, 'exactly one message is queued for delivery')

    // Re-opening the same review must not double every annotation.
    equal(listeners.arm(href, 'demo-listen-talk', null), 'listening', 're-opening renews the listener')
    equal(listeners.live().length, 1, 'and there is still exactly one')
    await sleep(200)
    equal(pidsFrom(log).length, 1, 'no second poller was ever started')

    equal(listeners.stop(href), 'stopped', 'closing the review stops it')
    equal(listeners.live().length, 0, 'and nothing is listening after that')
    await until('the poller to be gone', () => !alive(pid))
  } finally {
    listeners.close()
    fs.rmSync(home, { recursive: true, force: true })
  }
  console.log('ok   opening a review arms one listener, its feedback reaches the queue, closing stops it')
}

// --- 2. the page that went away without saying so ----------------------------

// A refresh, a killed tab, a closed laptop: no stop ever arrives. The keepalive
// timeout is the ONLY thing that catches this, so the same scenario is run twice
// - once with the reaper on and once with it disabled - and the second run must
// leak. A test that passes with the mechanism removed proves nothing.
async function checkAPageThatVanishesIsReaped() {
  const run = async (timeoutMs) => {
    const home = makeHome()
    const log = path.join(home, 'poll.log')
    const href = makeReview(home, 'demo-listen-gone', 'A change nobody closed')
    const listeners = withPath(stubLavish(path.join(home, 'stub'), 'silent', log),
      () => createListeners({ dmHome: home, bin: BIN, timeoutMs, sweepMs: 60000 }))
    try {
      listeners.arm(href, 'demo-listen-gone', null)
      const pid = await until('the poller to be running', () => {
        const rows = pidsFrom(log)
        return rows.length === 1 ? Number(rows[0].split(' ')[0]) : null
      })
      // An hour later, with no keepalive in between.
      const reaped = listeners.sweep(Date.now() + 3600 * 1000)
      const left = listeners.live().length
      if (timeoutMs !== null) await until('the reaped poller to be gone', () => !alive(pid))
      return { reaped, left, stillAlive: alive(pid), pid }
    } finally {
      listeners.close()
      fs.rmSync(home, { recursive: true, force: true })
    }
  }

  const guarded = await run(200)
  equal(guarded.reaped, 1, 'a review page that stopped checking in has its listener reaped')
  equal(guarded.left, 0, 'and it is no longer counted as live')
  equal(guarded.stillAlive, false, 'the poller process is actually gone, not just forgotten')

  // The mutation: same scenario, reaper disabled. It MUST leak, or the case
  // above was passing on something other than the reaper.
  const unguarded = await run(null)
  equal(unguarded.reaped, 0, 'with the timeout disabled nothing is reaped')
  equal(unguarded.left, 1, 'and the listener is still counted as live')
  equal(unguarded.stillAlive, true, 'the poller leaks - which is what the timeout exists to stop')

  // A page that IS checking in must not be reaped out from under the operator.
  const home = makeHome()
  const href = makeReview(home, 'demo-listen-open', 'A change being read')
  const listeners = withPath(stubLavish(path.join(home, 'stub'), 'silent', path.join(home, 'poll.log')),
    () => createListeners({ dmHome: home, bin: BIN, timeoutMs: 1000, sweepMs: 60000 }))
  try {
    listeners.arm(href, 'demo-listen-open', null)
    await sleep(50)
    equal(listeners.keepalive(href), 'listening', 'a page that is still open says so')
    equal(listeners.sweep(Date.now() + 500), 0, 'and is not reaped while it keeps checking in')
    equal(listeners.live().length, 1, 'its listener is still armed')
  } finally {
    listeners.close()
    fs.rmSync(home, { recursive: true, force: true })
  }
  console.log('ok   a review page that vanishes is reaped, one that checks in is not, and without the timeout it leaks')
}

// --- 3. the poll ending from lavish's own side -------------------------------

async function checkAPollThatEndsOnItsOwnCleansUp() {
  const home = makeHome()
  const log = path.join(home, 'poll.log')
  const href = makeReview(home, 'demo-listen-quit', 'A change whose session ended')
  const listeners = withPath(stubLavish(path.join(home, 'stub'), 'quit', log),
    () => createListeners({ dmHome: home, bin: BIN }))
  try {
    listeners.arm(href, 'demo-listen-quit', { title: 'A change whose session ended', repo: 'dockmaster' })
    await until('the listener to clear itself', () => listeners.live().length === 0)
    ok(!listeners.isLive(href), 'the console stops claiming a listener the moment the poll exits')
    // What it printed on its way out is still the operator's words.
    await until('its last words to reach the queue',
      () => messages(home).some((m) => m.text.includes('the session ended')))

    // A keepalive from a page that is still open must NOT respawn it: with
    // lavish-axi missing the poll exits at once, and a respawn would be an
    // endless spawn loop for as long as the review is on screen.
    equal(listeners.keepalive(href), 'ended', 'a keepalive on an ended session says so')
    await sleep(150)
    equal(pidsFrom(log).length, 1, 'and starts nothing - one poller was spawned, ever')
    equal(listeners.live().length, 0, 'nothing is armed')
  } finally {
    listeners.close()
    fs.rmSync(home, { recursive: true, force: true })
  }
  console.log('ok   a poll that ends on its own clears the console\'s state, and a keepalive never respawns it')
}

// --- 4. lavish-axi absent entirely -------------------------------------------

// The tool is optional. dm-lavish.sh degrades (says so on stderr, exits 0), so
// the listener ends immediately - honestly, with nothing claimed and nothing
// invented on the operator's queue.
async function checkAMissingLavishIsAnHonestNonStart() {
  const home = makeHome()
  const href = makeReview(home, 'demo-listen-notool', 'A change with no review tool')
  const empty = path.join(home, 'empty-bin')
  fs.mkdirSync(empty, { recursive: true })
  const previous = process.env.PATH
  // A PATH with no lavish-axi on it at all; /usr/bin is still needed for bash.
  process.env.PATH = `${empty}${path.delimiter}/usr/bin${path.delimiter}/bin`
  let listeners
  try {
    listeners = createListeners({ dmHome: home, bin: BIN })
    listeners.arm(href, 'demo-listen-notool', null)
    await until('the listener to end', () => listeners.live().length === 0)
    equal(messages(home).length, 0, 'the tool\'s own words never became an operator message')
  } finally {
    process.env.PATH = previous
    if (listeners) listeners.close()
    fs.rmSync(home, { recursive: true, force: true })
  }
  console.log('ok   with lavish-axi absent the listener ends at once and invents nothing')
}

// --- 5. over HTTP, including the console exiting -----------------------------

function launch(home, port, extraPath) {
  const env = Object.assign({}, process.env, {
    DM_HOME: home, DM_BIN: BIN, DM_UI_PORT: String(port), DM_UI_SOURCE: 'live',
  })
  if (extraPath) env.PATH = `${extraPath}${path.delimiter}${process.env.PATH}`
  const child = spawn(process.execPath, [path.join(ROOT, 'ui', 'server.js')], {
    env, stdio: ['ignore', 'pipe', 'pipe'],
  })
  const said = { out: '', err: '' }
  child.stdout.setEncoding('utf8')
  child.stderr.setEncoding('utf8')
  child.stdout.on('data', (chunk) => { said.out += chunk })
  child.stderr.on('data', (chunk) => { said.err += chunk })
  return { child, said }
}

async function boot(home, extraPath) {
  let last = ''
  for (let attempt = 0; attempt < BOOT_ATTEMPTS; attempt += 1) {
    const port = await freePort()
    const { child, said } = launch(home, port, extraPath)
    const started = Date.now()
    while (Date.now() - started < BOOT_TIMEOUT_MS) {
      if (said.out.includes(`http://127.0.0.1:${port}/`)) return { child, port, said }
      if (child.exitCode !== null) break
      await sleep(50)
    }
    last = said.err || said.out || 'no output'
    child.kill('SIGKILL')
  }
  throw new Error(`console server would not start in ${BOOT_ATTEMPTS} attempts: ${last}`)
}

async function checkTheHttpLifecycle() {
  const home = makeHome()
  const log = path.join(home, 'poll.log')
  const href = makeReview(home, 'demo-listen-http', 'A change reviewed in the page')
  const stub = stubLavish(path.join(home, 'stub'), 'silent', log)
  const server = await boot(home, stub)
  const { port } = server
  try {
    // What the page needs to render the review INSIDE the console: the
    // artifact's own address, and the work it belongs to.
    const info = json(await request(port, 'GET', `/api/review-info?review=${encodeURIComponent(href)}`))
    equal(info.src, `${href}change.html`, 'the console is told which file to frame')
    equal(info.title, 'A change reviewed in the page', 'and what the work is')
    equal(info.repo, 'dockmaster', 'and its repo')
    equal(info.awaiting, false, 'work that has not reached review offers nothing to approve')

    // Nothing is listening until a review is opened.
    equal(json(await request(port, 'GET', '/api/review-listeners')).live.length, 0,
      'a console with no review open is listening to nothing')

    const started = json(await postJson(port, '/api/review-listen', { review: href, action: 'start' }))
    equal(started.state, 'listening', 'opening the review arms a listener')
    equal(started.live.join(','), href, 'and the page is told which review is being listened to')
    const pid = await until('the poller to be running', () => {
      const rows = pidsFrom(log)
      return rows.length === 1 ? Number(rows[0].split(' ')[0]) : null
    })

    const again = json(await postJson(port, '/api/review-listen', { review: href, action: 'start' }))
    equal(again.live.length, 1, 're-opening the same review does not arm a second listener')
    equal(json(await postJson(port, '/api/review-listen', { review: href, action: 'keepalive' })).state,
      'listening', 'the open page checks in')
    equal(json(await request(port, 'GET', '/api/review-listeners')).live.join(','), href,
      'and any tab can read which reviews are live')

    const stopped = json(await postJson(port, '/api/review-listen', { review: href, action: 'stop' }))
    equal(stopped.state, 'stopped', 'closing the review stops the listener')
    equal(stopped.live.length, 0, 'and nothing is live')
    await until('the poller to be gone', () => !alive(pid))

    // Refusals. A bad address is bad input, never a 500 and never a path.
    for (const [body, status, what] of [
      [{ review: '/review/demo-listen-http/../../etc/', action: 'start' }, 400, 'a traversal-shaped address'],
      [{ review: '/etc/passwd', action: 'start' }, 400, 'an address that is not a review'],
      [{ review: href, action: 'burn-it-down' }, 400, 'an action that does not exist'],
      [{ review: '/review/nothing-here/', action: 'start' }, 404, 'a review that does not exist'],
    ]) {
      const res = await postJson(port, '/api/review-listen', body)
      equal(res.status, status, `${what} -> ${status}`)
      ok(!/dm-[a-z]+\.sh|ENOENT|\/tmp\//.test(res.text), `${what} leaks nothing internal: ${res.text}`)
    }

    // Arming a listener spawns a process, so it takes the same refusals a posted
    // message does: a hostile page must not be able to start one.
    const crossSite = await request(port, 'POST', '/api/review-listen',
      { 'content-type': 'application/json', 'sec-fetch-site': 'cross-site' },
      JSON.stringify({ review: href, action: 'start' }))
    equal(crossSite.status, 403, 'a cross-site page cannot arm a listener')
    const formPost = await request(port, 'POST', '/api/review-listen',
      { 'content-type': 'text/plain;charset=UTF-8' }, JSON.stringify({ review: href, action: 'start' }))
    equal(formPost.status, 415, 'nor one shaped to need no preflight')
    equal(json(await request(port, 'GET', '/api/review-listeners')).live.length, 0,
      'and neither refusal armed anything')

    // The console page may frame the review it serves - and only this origin.
    const page = await request(port, 'GET', '/')
    const frameSrc = page.headers['content-security-policy'].split(';').map((c) => c.trim())
      .find((c) => c.startsWith('frame-src'))
    equal(frameSrc, "frame-src 'self'", 'the console may frame a review page, from this origin alone')
    ok(page.headers['content-security-policy'].includes("frame-ancestors 'none'"),
      'while nothing may frame the console itself')
    equal((await request(port, 'GET', '/overlay.mjs')).status, 200, 'the page that opens a review is served')

    equal(server.child.exitCode, null, 'the console survived every refusal above')
  } finally {
    server.child.kill('SIGKILL')
    fs.rmSync(home, { recursive: true, force: true })
  }
  console.log('ok   the review listener arms, dedupes, stops and refuses over real HTTP')
}

// A poller outliving the console is unreachable: nothing knows its pid any more
// and the page that would stop it is gone.
async function checkTheConsoleTakesItsPollersWithIt() {
  const home = makeHome()
  const log = path.join(home, 'poll.log')
  const href = makeReview(home, 'demo-listen-exit', 'A change open when the console stopped')
  const stub = stubLavish(path.join(home, 'stub'), 'silent', log)
  const server = await boot(home, stub)
  try {
    equal(json(await postJson(server.port, '/api/review-listen', { review: href, action: 'start' })).state,
      'listening', 'a review is open with a listener armed')
    const pid = await until('the poller to be running', () => {
      const rows = pidsFrom(log)
      return rows.length === 1 ? Number(rows[0].split(' ')[0]) : null
    })
    ok(alive(pid), 'the poller is running')
    server.child.kill('SIGTERM')
    await until('the console to stop', () => server.child.exitCode !== null || server.child.signalCode !== null)
    await until('the poller to be gone with it', () => !alive(pid))
  } finally {
    server.child.kill('SIGKILL')
    fs.rmSync(home, { recursive: true, force: true })
  }
  console.log('ok   a console shutting down takes its review pollers with it')
}

// --- run ---------------------------------------------------------------------

async function main() {
  await checkOpeningArmsExactlyOneListenerAndRelaysFeedback()
  await checkAPageThatVanishesIsReaped()
  await checkAPollThatEndsOnItsOwnCleansUp()
  await checkAMissingLavishIsAnHonestNonStart()
  await checkTheHttpLifecycle()
  await checkTheConsoleTakesItsPollersWithIt()
  console.log(`\nconsole review-listener checks passed (${checks} assertions)`)
}

main().catch((err) => { console.error(`\nFAIL ${err.message}`); process.exit(1) })
