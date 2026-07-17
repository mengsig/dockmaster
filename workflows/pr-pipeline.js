export const meta = {
  name: 'pr-pipeline',
  description: 'Run a repo PR pipeline (default two-pass, or the rigorous dimension-parallel + adversarial tier): tests, review, fix-loop, verify, open PR',
  phases: [
    { title: 'Tests' },
    { title: 'Review' },
    { title: 'Verify' },
    { title: 'Fix' },
    { title: 'PR' },
  ],
}

// OPTIONAL, opt-in runner for the modular PR pipeline described in
// .claude/skills/pr-workflow/SKILL.md. It is NOT the default executor and NOT
// wired to anything: nothing auto-discovers it, no bin/ script invokes it. The
// manhandler's default path is to drive the gates with ordinary Agent calls
// following the pr-workflow skill. Run this only via the Workflow tool, and only
// when the operator has opted into hands-off multi-agent orchestration. A live
// rigorous run is a manhandler/operator action — this file has been verified for
// structural/syntactic conformance (`node --check`) only, never executed here.
//
// args = {
//   taskId, repo, worktree, branch,          // task context
//   base, defaultBranch,                     // diff base; base wins, else defaultBranch
//   testCmd,                                 // repo test command ("" = soft skip)
//   binDir,                                  // absolute path to this distro's bin/
//   gates,                                   // ordered gate list (from config); optional
//   tier,                                    // 'default' | 'fast' | 'rigorous'; picks the built-in
//                                            //   gate list when args.gates is not passed
//   securitySurface,                         // caller-declared security surface (optional security gate)
//   noRuntimeSurface,                        // true when the diff is docs/config-only (skips the verify gate)
//   title, issue, type, prTitle             // PR metadata
// }

const t = args || {}
if (!t.taskId || !t.worktree || !t.binDir) {
  throw new Error('pr-pipeline requires args.taskId, args.worktree, and args.binDir')
}
// Runs AFTER lavish approval and the operator choosing the PR path. The default
// tier is two review passes (coldstart, merge-gate), each followed by fix + tests,
// then PR. The rigorous tier fans the cold review out by dimension, adversarially
// verifies each finding before spending a fix round, and adds a behavioral verify
// gate — see config/pr-pipeline.rigorous.json and the pr-workflow skill.
//
// The diff base is what every review compares against. `origin/HEAD` is NOT a
// safe default: a freshly created worktree/clone often has no local origin/HEAD
// ref, so the diff would fail. Require an explicit base — the caller's resolved
// base ref, or the repo's resolved default branch (e.g. "main"/"origin/main").
const base = t.base || t.defaultBranch
if (!base) {
  throw new Error('pr-pipeline requires args.base or args.defaultBranch (origin/HEAD is unreliable in a fresh worktree)')
}

// Built-in gate lists, one per tier, used only as a fallback when the caller
// passes no explicit gates. They mirror the gates and ORDER of the shipped
// config/pr-pipeline.<tier>.json files but omit config-only annotations
// (per-gate `effort` and `note`); real runs pass args.gates from the config,
// which drives behavior.
const FAST_GATES = [
  { gate: 'review', pass: 'coldstart' }, { gate: 'fix', max_rounds: 2 }, { gate: 'tests' },
  { gate: 'pr' },
]
const DEFAULT_GATES = [
  { gate: 'review', pass: 'coldstart' }, { gate: 'fix', max_rounds: 2 }, { gate: 'tests' },
  { gate: 'review', pass: 'merge-gate' }, { gate: 'fix', max_rounds: 2 }, { gate: 'tests' },
  { gate: 'security', optional: true },
  { gate: 'pr' },
]
// await-checks is deliberately NOT here: waiting for CI belongs to the
// operator-mediated merge tail that runs AFTER the PR opens, not to any pre-pr
// gate (this runner opens the PR at `pr` and never merges).
const RIGOROUS_GATES = [
  { gate: 'review', pass: 'coldstart', dimensions: ['correctness', 'security', 'concurrency', 'portability', 'tests'] },
  { gate: 'verify-findings', voters: 3 },
  { gate: 'fix', max_rounds: 2 },
  { gate: 'tests' },
  { gate: 'verify', optional: true },
  { gate: 'security', method: 'auto' },
  { gate: 'pr' },
]
const gates = (t.gates && t.gates.length)
  ? t.gates
  : (t.tier === 'rigorous' ? RIGOROUS_GATES : t.tier === 'fast' ? FAST_GATES : DEFAULT_GATES)

const TEST_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: { passed: { type: 'boolean' }, summary: { type: 'string' } },
  required: ['passed', 'summary'],
}
const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          severity: { type: 'string' }, file: { type: 'string' }, summary: { type: 'string' },
        },
        required: ['severity', 'summary'],
      },
    },
  },
  required: ['findings'],
}
// One skeptic's verdict on a single finding: refuted=true means the finding is
// wrong / already handled / not real in this diff, with a cited rationale.
const REFUTE_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: { refuted: { type: 'boolean' }, rationale: { type: 'string' } },
  required: ['refuted', 'rationale'],
}

async function runTests(label) {
  if (!t.testCmd) {
    log(`tests: no test command registered for ${t.repo} — soft skip (not a pass)`)
    return { passed: true, summary: 'no test command registered (soft skip)' }
  }
  return agent(
    `In the git worktree at ${t.worktree}, run the repository's test command exactly:\n\n    ${t.testCmd}\n\n` +
    `Report whether it passed (zero exit) and a one-line summary of the result. Do not change any files.`,
    { label: `tests:${label}`, phase: 'Tests', schema: TEST_SCHEMA },
  )
}

// A generalist cold review (default/fast tiers) or, when `dimensions` is given
// (rigorous tier), one fresh reviewer per lens fanned out with parallel() and
// their findings merged. Each reviewer reads only the diff — never a prior
// summary — so the passes stay independent.
async function review(pass, effort, dimensions) {
  const which = pass || 'review'
  if (dimensions && dimensions.length) {
    // parallel() takes an array of THUNKS (() => Promise), not already-invoked
    // promises — each thunk is invoked by the runtime to fan the work out.
    const results = await parallel(dimensions.map((dim) => () => agent(
      `Cold, independent review of ONLY the ${dim} dimension of this change. In ${t.worktree}, read the diff of this branch against its base:\n\n` +
      `    git -C ${t.worktree} diff ${base}...HEAD\n\n` +
      `and the changed files. Do not trust any prior summary or earlier review. Report concrete, real ${dim} findings only, ranked by severity. ` +
      `Return an empty findings array if the change is sound on this dimension.`,
      { label: `review:${which}:${dim}`, phase: 'Review', effort: effort || 'high', schema: REVIEW_SCHEMA },
    )))
    const findings = []
    // Label each finding by position: results[i] is the reviewer for dimensions[i].
    // This assumes parallel() preserves input order; the labels are cosmetic only.
    for (let i = 0; i < results.length; i++) {
      for (const f of results[i].findings) findings.push({ ...f, dimension: dimensions[i] })
    }
    return { findings }
  }
  return agent(
    `Cold, independent ${which} review. In ${t.worktree}, read the diff of this branch against its base:\n\n` +
    `    git -C ${t.worktree} diff ${base}...HEAD\n\n` +
    `and the changed files. Do not trust any prior summary or earlier review. Report concrete, real findings ` +
    `(correctness, safety, then quality) ranked by severity. Return an empty findings array if the change is sound.`,
    { label: `review:${which}`, phase: 'Review', effort: effort || 'high', schema: REVIEW_SCHEMA },
  )
}

// Adversarial finding-verification (rigorous tier): each finding is independently
// checked by `voters` skeptics, each prompted to REFUTE it. A finding survives
// only if it is NOT refuted by a majority — this filters plausible-but-wrong
// findings before they cost a fix round. A tie does not make a majority.
async function verifyFindings(findings, voters) {
  const survivors = []
  for (const f of findings) {
    const desc = `[${f.severity}] ${f.file || ''} ${f.summary}${f.dimension ? ` (dimension: ${f.dimension})` : ''}`
    // parallel() takes thunks (() => Promise); Array.from's factory returns one
    // per skeptic, each of which the runtime invokes to run the votes in parallel.
    const votes = await parallel(Array.from({ length: voters }, () => () => agent(
      `You are a skeptical verifier. A prior reviewer raised this finding against the diff ${base}...HEAD in ${t.worktree}:\n\n` +
      `    ${desc}\n\n` +
      `Read the actual diff and the changed files and try to REFUTE it. Set refuted=true ONLY if the finding is wrong, already ` +
      `handled, or not a real problem in this diff, and cite the code that shows so. Set refuted=false if it is a genuine issue. ` +
      `Do not change any files.`,
      { label: 'verify-findings', phase: 'Review', effort: 'high', schema: REFUTE_SCHEMA },
    )))
    const refuted = votes.filter((v) => v.refuted).length
    if (2 * refuted <= voters) {
      survivors.push(f)
    } else {
      log(`verify-findings: dropped refuted finding (${refuted}/${voters} skeptics) — ${desc}`)
    }
  }
  return survivors
}

async function applyFixes(findings) {
  const list = findings.map((f, i) => `${i + 1}. [${f.severity}] ${f.file || ''} ${f.summary}`).join('\n')
  return agent(
    `In the git worktree at ${t.worktree}, on branch ${t.branch}, address these review findings and commit the fixes ` +
    `(no agent co-author, no "generated by" text):\n\n${list}\n\n` +
    `Only fix what is listed; keep the change focused. Report what you changed.`,
    { label: 'fix', phase: 'Fix' },
  )
}

async function openPR() {
  const title = t.prTitle || t.title || `${t.type || 'change'}: ${t.taskId}`
  return agent(
    `Open the PR for task ${t.taskId}. First write a short, plain, human PR description to a temp file — ` +
    `imperative summary, brief context only if not obvious, key changes as bullets, and a final ` +
    `"Risk: ... Verified: ..." line. No machine-authored phrasing, no agent attribution` +
    `${t.issue && t.issue !== 'x' ? `, and include "Closes #${t.issue}"` : ''}. ` +
    `Then run:\n\n    ${t.binDir}/mh-pr.sh open ${t.taskId} --title ${JSON.stringify(title)} --body-file <that file>\n\n` +
    `Report the resulting PR URL.`,
    { label: 'pr', phase: 'PR' },
  )
}

let lastReview = null
let currentPass = 'review'
let currentEffort            // effort of the active review pass, reused when a fix gate re-reviews
let currentDimensions        // dimensions of the active review pass, reused when a fix gate re-reviews
for (const g of gates) {
  if (g.gate === 'tests') {
    const r = await runTests('gate')
    if (!r.passed) return { ok: false, stage: 'tests', detail: r.summary }
  } else if (g.gate === 'review') {
    currentPass = g.pass || 'review'
    currentEffort = g.effort
    currentDimensions = g.dimensions
    lastReview = await review(currentPass, currentEffort, currentDimensions)
    log(`${currentPass} review: ${lastReview.findings.length} finding(s)`)
  } else if (g.gate === 'verify-findings') {
    // Rigorous only. Filter the last review's findings adversarially before the
    // fix gate spends rounds on them.
    if (lastReview) {
      const voters = g.voters || 3
      const before = lastReview.findings.length
      lastReview = { findings: await verifyFindings(lastReview.findings, voters) }
      log(`verify-findings: ${lastReview.findings.length}/${before} finding(s) survived ${voters} skeptics each`)
    }
  } else if (g.gate === 'fix') {
    const max = g.max_rounds || 2
    let round = 0
    // Apply fixes and re-review until findings clear or the cap is hit. Tests are
    // NOT run here: the dedicated `tests` gate that follows validates the tree, so
    // tests run once per stage (never doubled) and still at least once even when a
    // review found nothing to fix.
    while (lastReview && lastReview.findings.length && round < max) {
      round++
      await applyFixes(lastReview.findings)
      // Intentional asymmetry: the adversarial skeptic filter (verify-findings)
      // runs once, before the first fix round. This in-loop re-review is NOT
      // re-filtered through skeptics, so a false positive here can only
      // false-BLOCK (hold the PR for another round / fail the fix gate), never
      // false-merge. That fails safe, which is the direction we want.
      lastReview = await review(currentPass, currentEffort, currentDimensions)
    }
    if (lastReview && lastReview.findings.length) {
      return { ok: false, stage: 'fix', detail: `unresolved ${currentPass} findings after ${max} rounds`, findings: lastReview.findings }
    }
  } else if (g.gate === 'verify') {
    // Rigorous behavioral gate: drive the changed behavior end to end, not just
    // the test suite. Skippable only when the diff has no runtime surface.
    if (g.optional && t.noRuntimeSurface) { log('verify: diff has no runtime surface (docs/config-only) — behavioral gate skipped'); continue }
    const v = await agent(
      `Behavioral verification of task ${t.taskId}. In ${t.worktree}, use the verify skill to drive the behavior the diff ${base}...HEAD ` +
      `changes end to end: exercise the actual affected flow and observe it, not just that tests pass. Report what you exercised and ` +
      `whether it behaved correctly. Do not change any files.`,
      { label: 'verify', phase: 'Verify', effort: g.effort || 'high', schema: TEST_SCHEMA },
    )
    if (!v.passed) return { ok: false, stage: 'verify', detail: v.summary }
  } else if (g.gate === 'security') {
    if (g.method === 'auto') {
      // Auto-triggered: scan the diff, escalate to a full review only on a hit,
      // and otherwise skip explicitly — never a silent forget.
      await agent(
        `Security gate for task ${t.taskId}. In ${t.worktree}, run the security-surface scan exactly:\n\n` +
        `    ${t.binDir}/mh-pr.sh security-scan ${t.taskId}\n\n` +
        `If it reports signals present (exit 0), perform a security-review of the diff ${base}...HEAD (auth, input handling, secrets, ` +
        `crypto, external I/O) and report concrete issues only. If it reports no signals (non-zero exit), state explicitly that a ` +
        `security review was skipped because the diff has no security surface. Do not change any files.`,
        { label: 'security', phase: 'Review', effort: g.effort || 'high' })
      continue
    }
    // optional; skipped here unless a security surface is declared by the caller
    if (g.optional && !t.securitySurface) { log('security: no declared surface — skipped'); continue }
    await agent(
      `Security review of the diff ${base}...HEAD in ${t.worktree}: auth, input handling, secrets, crypto, external I/O. ` +
      `Report concrete issues only.`, { label: 'security', phase: 'Review', effort: g.effort || 'high' })
  } else if (g.gate === 'await-checks') {
    // Compatibility no-op: no shipped tier lists await-checks anymore (the CI-wait
    // moved to the operator-mediated merge tail, which this runner never reaches —
    // it opens the PR at the terminal `pr` gate and returns without merging). A
    // custom config that still carries this gate is deferred here rather than
    // faking a pass or waiting on a PR that does not exist yet.
    log('await-checks: deferred to the operator-mediated merge gate after the PR opens (the runner never merges)')
  } else if (g.gate === 'pr') {
    const out = await openPR()
    // Surface the configured merge method so the operator-mediated merge gate can
    // honor it (bin/mh-pr.sh merge --method <method>); this runner never merges.
    return { ok: true, stage: 'pr', pr: out, method: g.method || 'squash' }
  } else {
    log(`unknown gate '${g.gate}' — skipped`)
  }
}
return { ok: true, stage: 'complete' }
