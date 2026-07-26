#!/usr/bin/env node
// tests/check-console-http.js - the console server's refusals, over real HTTP.
//
// check-console.js pins what the DOCUMENT may claim. This pins what the SERVER
// accepts, which is a different question and the one with a security answer: a
// message posted to /api/chat is handed to the dockmaster as an operator
// instruction, so a cross-site page must not be able to post one. Loopback is
// not an authenticator - the browser sets Host itself, and a text/plain POST is
// a CORS-simple request that needs no preflight to be sent cross-origin.
//
// It also pins that the process SURVIVES bad input: a torn transcript line used
// to raise an uncaught exception out of a filesystem-watch callback, where no
// request handler could catch it, and exit.
//
// Node stdlib, the committed fixture, a temp home, an ephemeral port. No
// network, no shell.

const { spawn } = require('child_process')
const fs = require('fs')
const http = require('http')
const net = require('net')
const os = require('os')
const path = require('path')

const ROOT = process.env.DM_CHECK_ROOT ? path.resolve(process.env.DM_CHECK_ROOT) : path.join(__dirname, '..')
const BOOT_TIMEOUT_MS = 15000
const BOOT_ATTEMPTS = 3

let checks = 0
function ok(condition, message) {
  checks += 1
  if (!condition) throw new Error(message)
}
const equal = (actual, expected, message) =>
  ok(actual === expected, `${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)

// A port nothing holds right now. Bind-then-release, so the number comes from
// the kernel rather than a guess that collides on a busy CI box.
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
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// --- the server under test ---------------------------------------------------

function launch(home, port) {
  const child = spawn(process.execPath, [path.join(ROOT, 'ui', 'server.js')], {
    env: Object.assign({}, process.env, {
      DM_HOME: home, DM_BIN: path.join(ROOT, 'bin'), DM_UI_PORT: String(port), DM_UI_SOURCE: 'fixture',
    }),
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const said = { out: '', err: '' }
  child.stdout.setEncoding('utf8')
  child.stderr.setEncoding('utf8')
  child.stdout.on('data', (chunk) => { said.out += chunk })
  child.stderr.on('data', (chunk) => { said.err += chunk })
  return { child, said }
}

// Losing the race for a just-released port is the one flake this can have, so
// it is retried on a fresh port rather than left to fail intermittently.
async function boot(home) {
  let last = ''
  for (let attempt = 0; attempt < BOOT_ATTEMPTS; attempt += 1) {
    const port = await freePort()
    const { child, said } = launch(home, port)
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

const transcript = (home) => path.join(home, 'state', 'ui', 'chat.jsonl')
function messageCount(home) {
  if (!fs.existsSync(transcript(home))) return 0
  return fs.readFileSync(transcript(home), 'utf8').split('\n').filter((l) => l.trim()).length
}
const inboxCount = (home) => fs.readdirSync(path.join(home, 'state', 'ui', 'inbox')).length

// --- 1. a cross-site page cannot put words in the operator's mouth -----------

// Every shape a hostile page can actually produce. `text/plain` is the one that
// matters: it is a CORS-SIMPLE content type, so the browser sends it
// cross-origin with no preflight at all, and the Host header it sets itself
// passes any check that only asks whether the request looks local.
async function checkCrossSiteWritesAreRefused(port, home) {
  const before = messageCount(home)
  const attempts = [
    ['a text/plain POST - simple, so nothing preflights it',
      { 'content-type': 'text/plain;charset=UTF-8' }, 415],
    ['a text/plain POST carrying a hostile Origin',
      { 'content-type': 'text/plain;charset=UTF-8', origin: 'https://evil.example' }, 403],
    ['an HTML form post',
      { 'content-type': 'application/x-www-form-urlencoded', 'sec-fetch-site': 'cross-site' }, 403],
    ['a multipart form post',
      { 'content-type': 'multipart/form-data; boundary=x', 'sec-fetch-site': 'cross-site' }, 403],
    ['a JSON fetch declaring itself cross-site',
      { 'content-type': 'application/json', 'sec-fetch-site': 'cross-site' }, 403],
    ['a JSON fetch from same-site but another origin',
      { 'content-type': 'application/json', 'sec-fetch-site': 'same-site' }, 403],
    ['a JSON fetch from another local origin',
      { 'content-type': 'application/json', origin: 'http://127.0.0.1:1' }, 403],
    ['a JSON fetch from a lookalike host',
      { 'content-type': 'application/json', origin: 'https://127.0.0.1.evil.example' }, 403],
    ['a POST declaring no content type at all', {}, 415],
  ]
  for (const [what, headers, status] of attempts) {
    const res = await request(port, 'POST', '/api/chat', headers, JSON.stringify({ text: `attack: ${what}` }))
    equal(res.status, status, `${what} must be refused`)
    ok(!res.headers['access-control-allow-origin'], `${what} must not be answered with CORS headers`)
  }
  equal(messageCount(home), before, 'not one refused write reached the transcript')
  equal(inboxCount(home), 0, 'not one refused write was queued as an operator instruction')

  // Refusing the preflight is what makes the content-type requirement bite for
  // a scripted cross-origin JSON post: the browser never sends the real one.
  const preflight = await request(port, 'OPTIONS', '/api/chat',
    { origin: 'https://evil.example', 'access-control-request-method': 'POST' })
  ok(!preflight.headers['access-control-allow-origin'], 'a cross-origin preflight is not granted')

  // A forced refresh drives a fleet-wide PR sweep that records what it finds
  // and takes the task lock. It is a GET, so an <img src> reaches it - and must
  // not, or a hostile page can run the sweep in a loop.
  const forced = await request(port, 'GET', '/api/state?refresh=1', { 'sec-fetch-site': 'cross-site' })
  equal(forced.status, 403, 'a cross-site forced refresh is refused')
  const plain = await request(port, 'GET', '/api/state', { 'sec-fetch-site': 'cross-site' })
  equal(plain.status, 200, 'an ordinary cached read is still served')
  console.log(`ok   ${attempts.length} cross-site write shapes refused, none reached the queue`)
}

async function checkThePageItselfStillWorks(port, home) {
  const before = messageCount(home)
  // Exactly what the page sends: same-origin, JSON, with an Origin of its own.
  const sent = await request(port, 'POST', '/api/chat',
    { 'content-type': 'application/json', origin: `http://127.0.0.1:${port}`, 'sec-fetch-site': 'same-origin' },
    JSON.stringify({ text: 'from the console itself' }))
  equal(sent.status, 201, 'the console page may post')
  equal(json(sent).from, 'operator', 'and it posts as the operator')

  // A local tool sends neither browser header and is still allowed: it is
  // already running as the operator by the time it can reach this port.
  const local = await request(port, 'POST', '/api/chat',
    { 'content-type': 'application/json' }, JSON.stringify({ text: 'from a local tool' }))
  equal(local.status, 201, 'a local client with no browser headers may post')

  equal(messageCount(home), before + 2, 'both accepted messages landed in the transcript')
  equal(inboxCount(home), 2, 'both were queued for the dockmaster')

  const read = json(await request(port, 'GET', '/api/chat?since=0'))
  equal(read.total, before + 2, 'the transcript reads back what was written')
  equal(read.pending, 2, 'the page is told how many are unpicked-up')
  console.log('ok   the page and a local tool can still post; both land exactly once')
}

// --- 2. bad input does not take the server down ------------------------------

// Two processes append to the transcript, so a torn line is a real possibility.
// It used to raise an uncaught exception out of a watchFile callback - with no
// request in flight to catch it - and exit the process.
async function checkATornTranscriptLineDoesNotKillIt(port, home) {
  const since = messageCount(home)
  const waiting = request(port, 'GET', `/api/chat?since=${since}&wait=1`)
  await sleep(200)
  fs.appendFileSync(transcript(home), 'this is not json\n')
  fs.appendFileSync(transcript(home), '{"at":"2026-01-01T00:00:00Z"}\n')
  await sleep(700)

  const after = await request(port, 'GET', '/api/chat?since=0')
  equal(after.status, 200, 'the conversation still reads after a torn line')
  const body = json(after)
  equal(body.unreadable, 2, 'the page is told exactly how many lines could not be read')
  equal(body.messages.length, since, 'every readable message still renders')

  // The long-poll that was open across it must not be left hanging either.
  const posted = await request(port, 'POST', '/api/chat',
    { 'content-type': 'application/json' }, JSON.stringify({ text: 'wake the waiter' }))
  equal(posted.status, 201, 'a message still posts')
  const woken = await waiting
  equal(woken.status, 200, 'the waiter held across the torn line was answered')
  ok(json(woken).messages.length > 0, 'and it was answered with the new message')
  console.log('ok   a torn transcript line is counted, not fatal, and the waiter still wakes')
}

async function checkBadRequestsAreRefusedNotCrashed(port) {
  const cases = [
    ['GET', '/api/chat?since=-1', 400, 'a negative cursor'],
    ['GET', '/api/chat?since=nope', 400, 'a non-numeric cursor'],
    ['GET', '/review/%zz/', 400, 'a malformed percent-escape is bad input, not a 500'],
    ['GET', '/review/nothing-here/', 404, 'an unknown review page'],
    ['GET', '/nope', 404, 'an unknown route'],
    ['POST', '/nope', 404, 'an unknown write route'],
  ]
  for (const [method, urlPath, status, what] of cases) {
    const res = await request(port, method, urlPath, { 'content-type': 'application/json' })
    equal(res.status, status, `${what} -> ${status}`)
  }
  const empty = await request(port, 'POST', '/api/chat',
    { 'content-type': 'application/json' }, JSON.stringify({ text: '   ' }))
  equal(empty.status, 400, 'an empty message is refused')
  ok(!/chat: chat:/.test(json(empty).error), 'a refusal is not double-prefixed')

  const foreign = await request(port, 'GET', '/', { host: 'evil.example' })
  equal(foreign.status, 403, 'a request naming another host is refused (DNS rebinding)')
  console.log(`ok   ${cases.length + 2} bad requests refused with a status, not a crash`)
}

// --- 3. a review page can serve the screenshots it ships with ----------------

// A review page references its assets relatively and puts them in
// subdirectories. Rejecting anything past two path segments served the HTML
// with every screenshot beside it 400ing.
async function checkReviewAssetsAtAnyDepth(port, home) {
  const id = 'demo-review'
  const dir = path.join(home, 'data', id, 'lavish')
  fs.mkdirSync(path.join(dir, 'shots', 'run-1'), { recursive: true })
  fs.writeFileSync(path.join(dir, 'change.html'), '<p>the change</p>')
  fs.writeFileSync(path.join(dir, 'shots', 'top.png'), 'top')
  fs.writeFileSync(path.join(dir, 'shots', 'run-1', 'deep.png'), 'deep')

  const page = await request(port, 'GET', `/review/${id}/`)
  equal(page.status, 200, 'the review page itself is served')
  ok(page.headers['content-security-policy'].includes("connect-src 'none'"),
    'an archived review may reach neither this server nor the network')
  const bare = await request(port, 'GET', `/review/${id}`)
  equal(bare.status, 302, 'the form without a trailing slash redirects to the one assets resolve from')

  const shallow = await request(port, 'GET', `/review/${id}/shots/top.png`)
  equal(shallow.status, 200, 'a screenshot one directory down is served')
  equal(shallow.text, 'top', 'and it is the right file')
  const deep = await request(port, 'GET', `/review/${id}/shots/run-1/deep.png`)
  equal(deep.status, 200, 'a screenshot two directories down is served')
  equal(deep.headers['content-type'], 'image/png', 'with the type its extension implies')

  // Depth is allowed; escaping is not. The URL parser normalises some of these
  // away before the route sees them, so the assertion is that nothing outside
  // the review directory is ever reachable - not one fixed status code.
  for (const [attack, status, why] of [
    [`/review/${id}/..%2f..%2fchange.html`, 400, 'encoded slashes cannot compose a path'],
    [`/review/${id}/%2e%2e%2fchange.html`, 400, 'an encoded traversal is not a name'],
    [`/review/${id}/.git/config`, 400, 'a dotfile is not a name'],
    [`/review/${id}/shots//top.png`, 400, 'an empty segment is not a name'],
    [`/review/${id}/shots/../top.png`, 404, 'a traversal that normalises away lands nowhere'],
  ]) {
    const res = await request(port, 'GET', attack)
    equal(res.status, status, `${why}: ${attack}`)
  }
  console.log('ok   a review page serves nested assets, and no path escapes its directory')
}

// --- run ---------------------------------------------------------------------

async function main() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-console-http-'))
  fs.mkdirSync(path.join(home, 'state'), { recursive: true })
  fs.mkdirSync(path.join(home, 'data'), { recursive: true })
  const server = await boot(home)
  const { port } = server
  try {
    await checkCrossSiteWritesAreRefused(port, home)
    await checkThePageItselfStillWorks(port, home)
    await checkATornTranscriptLineDoesNotKillIt(port, home)
    await checkBadRequestsAreRefusedNotCrashed(port)
    await checkReviewAssetsAtAnyDepth(port, home)

    // Every case above ran against ONE process. Had any of them killed it the
    // later ones would have failed; this states the property outright.
    equal(server.child.exitCode, null, 'the server survived every case above')
    equal((await request(port, 'GET', '/')).status, 200, 'and is still serving the page')
  } finally {
    server.child.kill('SIGKILL')
    fs.rmSync(home, { recursive: true, force: true })
  }
  console.log(`\nconsole HTTP checks passed (${checks} assertions)`)
}

main().catch((err) => { console.error(`\nFAIL ${err.message}`); process.exit(1) })
