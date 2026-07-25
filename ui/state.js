// state.js - the one document the console renders, and the only place that
// decides where it comes from.
//
// THE SEAM. The page knows this shape and nothing else. Today the shape is
// filled from a committed fixture; the live source fills the SAME shape by
// shelling out to the dm-* scripts, which own every on-disk format. Nothing in
// ui/ ever opens state/repos.json, state/tasks/*.meta or state/backlog.json -
// a second parser is a second thing to keep in sync, and it would drift.
//
// Document shape (every field required unless marked optional):
//   generated_at  ISO timestamp
//   source        "fixture" | "live"
//   fleet         { repos, in_flight, open_prs, needs_you }   headline counts
//   needs_you[]   { lamp, state, headline, detail, repo, age, action? }
//   prs[]         { repo, title, number, url, checks, checks_detail, reviews,
//                   merge, blocker?, age }
//   work[]        { title, repo, kind, state, since, blocker?, review? }
//   repos[]       { name, authority, mode, branch, remote, test_cmd, sync,
//                   copies, disk, notes[] }
//   backlog       { in_flight[], queued[], done[] }
//   decisions     { open[], resolved[] }
//   reviews[]     { title, repo, state, at, href }
//   health        { verdict, checks[], cleanup[], sizing[] }
//
// `lamp` is one of port|brass|starboard|neutral and is ALWAYS accompanied by a
// text state - the page never carries meaning in color alone.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const FIXTURE = path.join(__dirname, 'fixtures', 'console.json');

const REQUIRED_KEYS = [
  'fleet', 'needs_you', 'prs', 'work', 'repos', 'backlog', 'decisions', 'reviews', 'health',
];

// Validate at the boundary: a half-shaped document must fail here, loudly, not
// render as an empty console - "nothing needs you" is the one lie that matters.
function assertShape(doc, origin) {
  if (doc === null || typeof doc !== 'object') {
    throw new TypeError(`${origin}: console state must be an object`);
  }
  for (const key of REQUIRED_KEYS) {
    if (!(key in doc)) throw new Error(`${origin}: console state is missing '${key}'`);
  }
  for (const key of ['needs_you', 'prs', 'work', 'repos', 'reviews']) {
    if (!Array.isArray(doc[key])) throw new TypeError(`${origin}: '${key}' must be an array`);
  }
  const counted = doc.needs_you.length;
  if (doc.fleet.needs_you !== counted) {
    throw new Error(`${origin}: fleet.needs_you says ${doc.fleet.needs_you}, the list holds ${counted}`);
  }
  return doc;
}

function fromFixture() {
  const raw = fs.readFileSync(FIXTURE, 'utf8');
  const doc = assertShape(JSON.parse(raw), FIXTURE);
  doc.source = 'fixture';
  doc.generated_at = new Date().toISOString();
  return doc;
}

// Collecting live state means running the dm-* scripts, and the PR sweep alone
// costs seconds and network. So the document is a SNAPSHOT with a short life:
// every open page shares one collection instead of each triggering its own.
// A failure is never cached - the next request retries it.
const CACHE_TTL_MS = 20000;
let snapshot = null;

// collect(source) -> the console document.
// "live" is stage two: it fills this same shape from dm-status/dm-pr/dm-repo/
// dm-task/dm-backlog output. Until it exists, asking for it must fail rather
// than quietly serve the fixture and call it the fleet.
function collect(source) {
  const now = Date.now();
  if (snapshot && snapshot.source === source && now - snapshot.at < CACHE_TTL_MS) {
    return snapshot.doc;
  }
  if (source !== 'fixture' && source !== 'live') {
    throw new TypeError(`console: unknown source '${source}'`);
  }
  if (source === 'live') {
    throw new Error('console: the live source is not wired yet (DM_UI_SOURCE=fixture)');
  }
  snapshot = { at: now, source, doc: fromFixture() };
  return snapshot.doc;
}

module.exports = { collect, assertShape, FIXTURE, CACHE_TTL_MS };
