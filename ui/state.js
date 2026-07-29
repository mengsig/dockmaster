// state.js - the one document the console renders, and the only place that
// decides where it comes from.
//
// THE SEAM. The page knows this shape and nothing else. `live` fills it by
// shelling out to the dm-* scripts (ui/live.js), which own every on-disk format;
// `fixture` fills the same shape from a committed demo fleet, so the design can
// be worked on without a fleet. Nothing in ui/ ever opens state/repos.json,
// state/tasks/*.meta or state/backlog.json - a second parser is a second thing
// to keep in sync, and it would drift.
//
// Document shape (every field required unless marked optional):
//   generated_at  when the LOCAL half was collected, not when it was served -
//                 the two halves are cached separately and a served document is
//                 up to a TTL old
//   prs_read_at   when the sweep last read GitHub ('' if it never did)
//   source        "fixture" | "live"  - the page STATES which; a demo fleet the
//                 operator cannot tell from their own is the point of failure
//   degraded[]    { source, panel, subject } - what could NOT be read, as tokens
//                 the page words, named on the panel that lost it
//   fleet         { repos, in_flight, open_prs, needs_you }   headline counts
//   needs_you[]   { lamp, kind, ... }  the operator's queue; `kind` selects how
//                 the page words it, so no prose crosses this seam
//   work[]        { title, repo, kind, state, since, last_signal_at,
//                   quiet_after_hours, blocker, review_href, track }
//   track         { mode, stages[{key,state,evidence}], gates[] } | null
//   prs[]         { title, repo, url, checks, review, state, authority,
//                   opened_at, cached, error }
//   repos[]       { name, authority, mode, branch, remote, test_cmd, tangled,
//                   tangle_note, notes[], notes_hidden }
//   backlog       { in_flight[], queued[], done[] }
//   decisions     { open[], resolved[] }
//   reviews[]     { title, repo, state, at, href, session_href } - `href` is the
//                 console's own review page (the primary destination);
//                 `session_href` reaches the annotatable lavish session, which
//                 may not exist and says so
//   health        { verdict, checks[], cleanup[] }
//
// A stage `state` is done | active | ahead | unknown. `ahead` means the work has
// not reached it; `unknown` means it could not be determined. They are NOT the
// same claim and the page must never render them alike.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const live = require('./live');

const FIXTURE = path.join(__dirname, 'fixtures', 'console.json');

const REQUIRED_KEYS = [
  'source', 'generated_at', 'prs_read_at',
  'fleet', 'needs_you', 'work', 'prs', 'repos', 'backlog', 'decisions', 'reviews', 'health', 'degraded',
];
const SOURCES = ['fixture', 'live'];

// Collecting live state runs the toolbelt; the local half walks every task and
// the PR half costs a GitHub round trip per open PR. So each is a SNAPSHOT with
// its own life: cheap local state refreshes often, the sweep rarely, and every
// open tab shares one collection instead of each triggering its own.
const LOCAL_TTL_MS = 20000;
const PR_TTL_MS = 150000;

// Validate at the boundary: a half-shaped document must fail here, loudly, not
// render as an empty console - "nothing needs you" is the one lie that matters.
function assertShape(doc, origin) {
  if (doc === null || typeof doc !== 'object') {
    throw new TypeError(`${origin}: console state must be an object`);
  }
  for (const key of REQUIRED_KEYS) {
    if (!(key in doc)) throw new Error(`${origin}: console state is missing '${key}'`);
  }
  for (const key of ['needs_you', 'work', 'prs', 'repos', 'reviews', 'degraded']) {
    if (!Array.isArray(doc[key])) throw new TypeError(`${origin}: '${key}' must be an array`);
  }
  // The page has to be able to say which fleet this is; an unset or unknown
  // source would render a demo fleet indistinguishable from the operator's own.
  if (!SOURCES.includes(doc.source)) {
    throw new Error(`${origin}: source must be one of ${SOURCES.join('|')}, got '${doc.source}'`);
  }
  const counted = doc.needs_you.length;
  if (doc.fleet.needs_you !== counted) {
    throw new Error(`${origin}: fleet.needs_you says ${doc.fleet.needs_you}, the list holds ${counted}`);
  }
  return doc;
}

const ISO_STAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;

// The demo fleet must not age. Every stamp in the fixture is written against its
// own `anchor`, and the whole document is shifted onto now on load - otherwise a
// year from now the design work happens against "started 400d ago" everywhere.
function reanchor(value, shiftMs) {
  if (typeof value === 'string') {
    return ISO_STAMP.test(value) ? new Date(Date.parse(value) + shiftMs).toISOString() : value;
  }
  if (Array.isArray(value)) return value.map((item) => reanchor(item, shiftMs));
  if (value && typeof value === 'object') {
    for (const key of Object.keys(value)) value[key] = reanchor(value[key], shiftMs);
  }
  return value;
}

function fromFixture() {
  const raw = fs.readFileSync(FIXTURE, 'utf8');
  const parsed = JSON.parse(raw);
  const anchor = Date.parse(parsed.anchor || '');
  if (Number.isNaN(anchor)) throw new Error(`${FIXTURE}: needs an 'anchor' ISO timestamp to age from`);
  const doc = reanchor(parsed, Date.now() - anchor);
  // Stamped here, not read from the file: the demo fleet cannot declare itself
  // live, whatever the committed JSON says.
  doc.source = 'fixture';
  doc.generated_at = new Date().toISOString();
  doc.prs_read_at = doc.generated_at;
  return assertShape(doc, FIXTURE);
}

// One tier of the live cache. A FAILED collection is never stored, so the next
// request retries it rather than serving an error for the whole TTL.
function makeTier(ttl, collect) {
  return { ttl, collect, at: 0, value: null, inflight: null };
}

const tiers = {
  local: makeTier(LOCAL_TTL_MS, live.collectLocal),
  prs: makeTier(PR_TTL_MS, live.collectPullRequests),
};

function fresh(tier, bin, force) {
  const now = Date.now();
  if (!force && tier.value && now - tier.at < tier.ttl) return Promise.resolve(tier.value);
  // Ten open tabs, or a refresh landing mid-collection, join the walk already
  // running instead of starting a second one.
  if (tier.inflight) return tier.inflight;
  tier.inflight = tier.collect(bin)
    .then((value) => {
      tier.value = value;
      tier.at = Date.now();
      return value;
    })
    .finally(() => { tier.inflight = null; });
  return tier.inflight;
}

// collect(source, bin, force) -> Promise of the console document.
// An unknown source THROWS. It must never fall through to the fixture and
// present a demo fleet as the operator's own.
async function collect(source, bin, force) {
  if (source === 'fixture') return fromFixture();
  if (source !== 'live') throw new TypeError(`console: unknown source '${source}'`);
  if (typeof bin !== 'string' || bin.length === 0) {
    throw new Error('console: the live source needs the toolbelt path (DM_BIN) - start via bin/dm-ui.sh');
  }
  // The local half is load-bearing, so its failure fails the request. The sweep
  // is not: losing GitHub degrades the pull-request and needs-you panels, which
  // say so, rather than emptying the whole console. `rows: null` IS that signal.
  const [local, sweep] = await Promise.all([
    fresh(tiers.local, bin, force),
    fresh(tiers.prs, bin, force).then((sweep_) => sweep_, (err) => {
      process.stderr.write(`console: pull_requests: ${err.message}\n`);
      return { rows: null, at: '' };
    }),
  ]);
  return assertShape(live.buildDocument(local, sweep), 'live');
}

module.exports = { collect, assertShape, FIXTURE, LOCAL_TTL_MS, PR_TTL_MS };
