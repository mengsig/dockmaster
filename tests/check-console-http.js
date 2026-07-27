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

const { spawn, spawnSync } = require('child_process')
const fs = require('fs')
const http = require('http')
const net = require('net')
const os = require('os')
const path = require('path')

const ROOT = process.env.DM_CHECK_ROOT ? path.resolve(process.env.DM_CHECK_ROOT) : path.join(__dirname, '..')
const chat = require(path.join(ROOT, 'ui', 'chat.js'))
const live = require(path.join(ROOT, 'ui', 'live.js'))
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

  // Reading the fleet RECORDS what it reads: the collection behind either form
  // of /api/state writes each PR's state and takes the task lock. So BOTH are
  // state-changing GETs. The un-forced one is the dangerous one - it needs no
  // query string and no legacy browser, just <img src="/api/state"> on a timer.
  const reads = [
    ['/api/state?refresh=1', { 'sec-fetch-site': 'cross-site' }, 'a forced refresh'],
    ['/api/state', { 'sec-fetch-site': 'cross-site', 'sec-fetch-dest': 'image' }, 'an <img src> read'],
    ['/api/state', { 'sec-fetch-site': 'same-site' }, 'a read from another port of 127.0.0.1'],
    ['/api/state', { origin: 'https://evil.example' }, 'a read carrying a hostile Origin'],
    // Opening a review session runs a dm-* script the same way /api/state does,
    // so a hostile page must not be able to fire it either.
    ['/api/review-open?id=x', { 'sec-fetch-site': 'cross-site' }, 'a cross-site session open'],
  ]
  for (const [urlPath, headers, what] of reads) {
    const res = await request(port, 'GET', urlPath, headers)
    equal(res.status, 403, `${what} must be refused`)
  }
  // The page's own read, and a local tool's, still work.
  equal((await request(port, 'GET', '/api/state', { 'sec-fetch-site': 'same-origin' })).status, 200,
    'the console page may read the fleet')
  equal((await request(port, 'GET', '/api/state')).status, 200,
    'a local client with no browser headers may read the fleet')
  console.log(`ok   ${attempts.length} cross-site write shapes and ${reads.length} cross-site reads refused`)
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

// A message being PICKED UP adds nothing to the transcript, so a long poll that
// only holds out for a new message left "1 message waiting for the dockmaster" on
// screen for the whole 25s window after it had already been answered. The count
// is live state, and the page has to learn when it changes.
async function checkPickingUpAMessageRefreshesTheCount(port, home) {
  await request(port, 'POST', '/api/chat',
    { 'content-type': 'application/json' }, JSON.stringify({ text: 'waiting to be picked up' }))
  const before = json(await request(port, 'GET', '/api/chat?since=0'))
  ok(before.pending > 0, 'the message is queued for the dockmaster')

  const waiting = request(port, 'GET', `/api/chat?since=${before.total}&wait=1`)
  await sleep(200)
  // Exactly what `dm-ui.sh poll` does: claim, deliver, acknowledge.
  const claim = chat.claimOldest(home)
  ok(claim !== null, 'the poll claims it')
  claim.acknowledge()

  const answered = await waiting
  equal(answered.status, 200, 'the parked poll is answered')
  const body = json(answered)
  equal(body.messages.length, 0, 'with no new message - nothing was said')
  equal(body.pending, before.pending - 1, 'and a count the page can trust')

  // The race the page could actually see: the count moves while the page is
  // BETWEEN polls, so a waiter that reads the count as it parks has nothing to
  // report and the page holds a stale number for the whole 25s window. The page
  // sends what it is showing, so a wait against an out-of-date view is answered
  // at once rather than held.
  await request(port, 'POST', '/api/chat',
    { 'content-type': 'application/json' }, JSON.stringify({ text: 'queued while the page was not looking' }))
  const now = json(await request(port, 'GET', '/api/chat?since=0'))
  const stale = json(await request(port, 'GET',
    `/api/chat?since=${now.total}&pending=${now.pending + 7}&wait=1`))
  equal(stale.pending, now.pending, 'a wait against a stale count is answered immediately, with the real one')

  const bad = await request(port, 'GET', '/api/chat?since=0&pending=-2')
  equal(bad.status, 400, 'a nonsense count is refused, not guessed at')
  console.log('ok   the waiting count is never stale: a pick-up wakes the page, a stale view is corrected at once')
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

// Nothing served under /review/ may show a script name, an errno or a path -
// whether it is a worded failure or a page that rendered fine. Shared so the
// success case below is held to the exact same bar as the failure cases here.
const INTERNAL_LEAK = /dm-[a-z]+\.sh|--json|exit \d|ENOENT|ENOTDIR|EACCES|\/tmp\/|jq/

// A /review/ address is a same-tab navigation: whatever comes back IS the page.
// There is no script layer to word a failure, so the failure has to arrive
// already worded - not as the script name, argv and stderr behind it.
async function checkReviewFailuresAreWorded(port, home) {
  const internal = INTERNAL_LEAK
  const cases = [
    [`/review/nothing-here/`, 404, 'an unknown review page'],
    [`/review/%zz/`, 400, 'a malformed address'],
    [`/review/demo-review/change.html/deeper.png`, 404, 'a segment appended to a real file (ENOTDIR)'],
  ]
  for (const [urlPath, status, what] of cases) {
    const res = await request(port, 'GET', urlPath)
    equal(res.status, status, `${what} -> ${status}`)
    ok(/^text\/html/.test(res.headers['content-type'] || ''),
      `${what} renders as a page, not a JSON blob in the tab`)
    ok(!internal.test(res.text), `${what} shows no script name, errno or path: ${res.text.slice(0, 160)}`)
    ok(!res.text.includes(home), `${what} does not print the state directory`)
  }
  console.log(`ok   ${cases.length} review-page failures render worded, with nothing internal in the body`)
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

  // The archived artifact itself - the console's own WRAPPER around it, at the
  // index address, is a separate document and is checked in the next test.
  // This one must be exactly as isolated as it always was.
  const page = await request(port, 'GET', `/review/${id}/change.html`)
  equal(page.status, 200, 'the archived artifact is served')
  const csp = page.headers['content-security-policy']
  ok(csp.includes("connect-src 'none'"), 'an archived review may not reach the network')
  // A review page is SAME-ORIGIN, so the cross-site refusal cannot stop it
  // firing GET /api/state through an <img>, a <link rel=stylesheet> or an
  // @font-face. Every fetch directive is scoped to /review/ instead of 'self'.
  for (const directive of ['script-src', 'style-src', 'img-src', 'font-src']) {
    const clause = csp.split(';').map((c) => c.trim()).find((c) => c.startsWith(`${directive} `))
    ok(clause !== undefined, `${directive} is declared`)
    ok(!/'self'/.test(clause), `${directive} is not the whole origin - that would reach /api/`)
    ok(clause.includes(`http://127.0.0.1:${port}/review/`), `${directive} is scoped to the review archive`)
  }
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

// The index address used to BE the archived artifact; the console now serves
// its own wrapper there instead, so "Open the review page" works with no
// lavish session server running. The artifact keeps rendering - now inside an
// iframe at the asset address pinned above - and the wrapper is the only part
// of the response allowed to reach the API, because it is the console's own
// markup, not the artifact's.
async function checkReviewShellWrapsTheArtifactAndCanEnqueue(port, home) {
  const id = 'demo-review-shell'
  const dir = path.join(home, 'data', id, 'lavish')
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(path.join(dir, 'change.html'), '<p>the change</p>')
  const created = spawnSync(path.join(ROOT, 'bin', 'dm-task.sh'),
    ['new', id, '--kind', 'ship', '--repo', 'dockmaster', '--title', 'A demo change under review'],
    { env: Object.assign({}, process.env, { DM_HOME: home }), encoding: 'utf8' })
  equal(created.status, 0, `the task fixture behind the review is created: ${created.stderr}`)

  const shell = await request(port, 'GET', `/review/${id}/`)
  equal(shell.status, 200, 'the console serves its own wrapper at the review address')
  const shellCsp = shell.headers['content-security-policy']
  ok(shellCsp.includes("script-src 'self'"), 'the wrapper may run its own script')
  ok(shellCsp.includes("connect-src 'self'"), 'and reach the API - unlike the artifact it wraps')
  ok(!/unsafe-inline/.test(shellCsp), 'and needs no inline script or style to do either')

  // The task record crosses as DATA, not prose - review.mjs is what decides how
  // to say it, and only ever from this shape.
  ok(shell.text.includes('"ok":true'), 'the task record behind this review was found')
  ok(shell.text.includes('"title":"A demo change under review"'), 'its title crosses as data')
  ok(shell.text.includes('"repo":"dockmaster"'), 'and its repo crosses as data')
  ok(shell.text.includes('<iframe'), 'the artifact renders inside the wrapper, not standing alone')
  ok(shell.text.includes('change.html'), 'pointed at the real artifact file')
  // The isolation guarantee is this sandbox, not the CSP below: no
  // allow-same-origin means the artifact renders into an opaque origin and gets
  // no window.parent, so its inline scripts cannot reach this wrapper's
  // connect-src 'self' fetch or click its own Approve/Send buttons.
  ok(/<iframe[^>]*\bsandbox="allow-scripts"/.test(shell.text),
    'the artifact iframe is sandboxed, with no allow-same-origin')
  ok(!INTERNAL_LEAK.test(shell.text), 'the wrapper shows no script name, path or internal detail')
  ok(!shell.text.includes(home), 'and does not print the state directory')

  // The artifact the wrapper embeds is unaffected: same address, same CSP. This
  // is the artifact's OWN defense-in-depth, not the isolation guarantee - that
  // is the sandbox attribute asserted above.
  const nested = await request(port, 'GET', `/review/${id}/change.html`)
  equal(nested.status, 200, 'the artifact the wrapper embeds is still served on its own')
  ok(nested.headers['content-security-policy'].includes("connect-src 'none'"),
    "the artifact's own CSP still blocks it from reaching the network directly")

  // An artifact whose task record is gone (archived, discarded) still renders -
  // it just cannot safely name the work, so it says so as data rather than
  // inventing a title.
  const orphanId = 'demo-review-orphan'
  const orphanDir = path.join(home, 'data', orphanId, 'lavish')
  fs.mkdirSync(orphanDir, { recursive: true })
  fs.writeFileSync(path.join(orphanDir, 'change.html'), '<p>orphaned</p>')
  const orphan = await request(port, 'GET', `/review/${orphanId}/`)
  equal(orphan.status, 200, 'a review still renders when its task record cannot be found')
  ok(orphan.text.includes('"ok":false'), 'and says so as data instead of inventing a title')

  console.log('ok   the console wraps an archived artifact in its own shell, and the artifact stays isolated')
}

// The two static files the wrapper's own script needs: the notes-box logic and
// the shared postMessage() the composer also uses.
// The task title crosses into the wrapper as JSON inside a literal
// <script type="application/json"> block (reviewShellHtml). A title containing
// `</script>` could otherwise close that tag early and inject markup/script
// into the wrapper document - reviewShellHtml escapes `<` to `<` for
// exactly this reason. This pins it against a REAL hostile title, through the
// real server, not just the escaping helper in isolation.
async function checkHostileTitleCannotBreakOutOfTheDataBlock(port, home) {
  const id = 'demo-review-hostile-title'
  const dir = path.join(home, 'data', id, 'lavish')
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(path.join(dir, 'change.html'), '<p>the change</p>')
  const hostileTitle = '</script><script>alert(1)</script>'
  const created = spawnSync(path.join(ROOT, 'bin', 'dm-task.sh'),
    ['new', id, '--kind', 'ship', '--repo', 'dockmaster', '--title', hostileTitle],
    { env: Object.assign({}, process.env, { DM_HOME: home }), encoding: 'utf8' })
  equal(created.status, 0, `the task fixture behind the hostile-title review is created: ${created.stderr}`)

  const shell = await request(port, 'GET', `/review/${id}/`)
  equal(shell.status, 200, 'the wrapper still renders for a hostile title')
  const dataBlock = shell.text.match(/<script type="application\/json" id="review-data">([^]*?)<\/script>/)
  ok(dataBlock, 'the data block is present and still ends where a script tag ends')
  ok(!dataBlock[1].includes('</script'), 'no raw </script inside the data block, escaped or otherwise')
  ok(!dataBlock[1].includes('<'), 'no raw < of any kind inside the JSON string')
  ok(dataBlock[1].includes('\\u003c'), 'the hostile `<` crosses escaped as \\u003c instead')
  console.log('ok   a hostile task title cannot break out of the review data block')
}

async function checkReviewScriptsAreServed(port) {
  const script = await request(port, 'GET', '/review.mjs')
  equal(script.status, 200, 'the review page script is served')
  equal(script.headers['content-type'], 'text/javascript; charset=utf-8', 'as a module script')
  const api = await request(port, 'GET', '/api.mjs')
  equal(api.status, 200, 'the shared postMessage helper is served too')
  equal(api.headers['content-type'], 'text/javascript; charset=utf-8', 'as a module script')
  console.log('ok   the review page\'s own script and the shared postMessage helper are served')
}

// --- 4. opening a review tries the lavish session, degrading honestly -------

// Against the REAL dm-lavish.sh, no artifact behind the id: `open` refuses
// before it ever touches lavish-axi, which is exactly the shape a real "no
// session for this one" answer takes. The route must turn that into a plain
// { url: null }, never a 500 - the page's fallback is what handles it.
async function checkReviewOpenDegradesForAnUnknownId(port) {
  const res = await request(port, 'GET', '/api/review-open?id=not-a-real-review')
  equal(res.status, 200, 'an id with no artifact still answers 200')
  equal(json(res).url, null, 'and says there is no session to open')

  const missing = await request(port, 'GET', '/api/review-open')
  equal(missing.status, 200, 'no id at all is handled the same way, not a 500')
  equal(json(missing).url, null, 'and answers the same shape')
  console.log('ok   opening a review with no session behind it degrades to { url: null }, not a crash')
}

// What the page's Open link actually hits. It is a real navigation, so the
// answer has to be a redirect the browser can follow on its own - the operator
// lands on the review either way, and never on a JSON body. `{ url: null }`
// would be the bug here: the tab has already opened by the time this answers.
async function checkTheOpenLinkRedirectsRatherThanAnswering(port) {
  const res = await request(port, 'GET', '/api/review-open?id=not-a-real-review&redirect=1')
  equal(res.status, 302, 'the link is answered with a redirect, not a document')
  equal(res.headers.location, '/review/not-a-real-review/',
    'and with no session to send it to, it falls back to the raw review page')
  equal(res.text, '', 'a redirect carries no body for the browser to render')

  // A link the page built without an id is a bug in the page, and saying so is
  // how it gets found - a 302 to /review// would send the operator nowhere.
  const missing = await request(port, 'GET', '/api/review-open?redirect=1')
  equal(missing.status, 400, 'a redirect asked for with no id is refused outright')
  console.log('ok   the review Open link is answered with a redirect, and degrades to the raw page')
}

// The route only WORDS what dm-lavish.sh said; the parsing itself is pinned
// directly against a stand-in for it, so this does not depend on lavish-axi
// being installed or spend a real session opening one.
async function checkReviewOpenParsesTheRealScriptsShape() {
  const stubBin = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-lavish-stub-'))
  const argvFile = path.join(stubBin, 'argv')
  try {
    fs.writeFileSync(path.join(stubBin, 'dm-lavish.sh'), '#!/usr/bin/env bash\n'
      + `printf '%s\\n' "$*" > ${JSON.stringify(argvFile)}\n`
      + 'printf \'session:\\n  file: /x/change.html\\n  url: "http://127.0.0.1:4387/session/abc123"\\n  status: opened\\n\'\n')
    fs.chmodSync(path.join(stubBin, 'dm-lavish.sh'), 0o755)
    const opened = await live.openReviewSession(stubBin, 'whatever')
    equal(opened.url, 'http://127.0.0.1:4387/session/abc123', 'the session url is parsed off the real output shape')

    // This call runs on the SERVER. The operator's browser is what must show
    // the session; a tab opened here would land in whatever display the server
    // process has, which is nobody's screen on a remote box and a stray window
    // on a local one.
    equal(fs.readFileSync(argvFile, 'utf8').trim(), 'open whatever --no-open',
      'the console asks for the session without lavish-axi opening a browser itself')

    // dm-lavish.sh's own degrade when lavish-axi is missing: exits 0, says
    // nothing shaped like a session.
    fs.writeFileSync(path.join(stubBin, 'dm-lavish.sh'), '#!/usr/bin/env bash\n'
      + 'echo "lavish-axi not installed; the interactive review surface is unavailable." >&2\n')
    const noTool = await live.openReviewSession(stubBin, 'whatever')
    equal(noTool.url, null, 'no session line on stdout is unavailable, not a throw')

    // A hard refusal (no artifact): exits nonzero.
    fs.writeFileSync(path.join(stubBin, 'dm-lavish.sh'), '#!/usr/bin/env bash\n'
      + 'echo "no artifact" >&2\nexit 1\n')
    const failed = await live.openReviewSession(stubBin, 'whatever')
    equal(failed.url, null, 'a nonzero exit degrades the same way, never throws')
  } finally {
    fs.rmSync(stubBin, { recursive: true, force: true })
  }
  console.log('ok   opening a review parses the real script\'s session line and degrades on anything else')
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
    await checkPickingUpAMessageRefreshesTheCount(port, home)
    await checkATornTranscriptLineDoesNotKillIt(port, home)
    await checkBadRequestsAreRefusedNotCrashed(port)
    await checkReviewAssetsAtAnyDepth(port, home)
    await checkReviewShellWrapsTheArtifactAndCanEnqueue(port, home)
    await checkHostileTitleCannotBreakOutOfTheDataBlock(port, home)
    await checkReviewScriptsAreServed(port)
    await checkReviewFailuresAreWorded(port, home)
    await checkReviewOpenDegradesForAnUnknownId(port)
    await checkTheOpenLinkRedirectsRatherThanAnswering(port)
    await checkReviewOpenParsesTheRealScriptsShape()

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
