#!/usr/bin/env node

const fs = require('fs')
const path = require('path')

const ROOT = process.env.DM_PARITY_ROOT
  ? path.resolve(process.env.DM_PARITY_ROOT)
  : path.join(__dirname, '..')
const MANIFEST = readJson('config/runtime-capabilities.json')
const RUNTIMES = {
  claude: '.claude/skills',
  codex: '.agents/skills',
}
const CAPABILITY_ASSERTIONS = {
  'guidance-and-triggers': ['AGENTS.md', /load the skill at its trigger/],
  'skill-discovery': ['tests/check-codex-skill-discovery.js', /structured skills block/],
  'task-dispatch': ['.agents/skills/task-lifecycle/SKILL.md', /status queued[\s\S]*thread_name[\s\S]*agent_id[\s\S]*move <id> inflight/],
  'worktree-isolation': ['bin/dm-worktree.sh', /unlanded work/],
  'nested-secondmate': ['bin/dm-secondmate.sh', /AMBIGUOUS-LAUNCH/],
  'followup-and-steering': ['.agents/skills/supervision/SKILL.md', /send_message[\s\S]*followup_task/],
  'background-supervision': ['.agents/skills/supervision/SKILL.md', /wait_agent[\s\S]*native wake path/],
  recovery: ['.agents/skills/stuck-worker/SKILL.md', /Multiple exact-name matches are ambiguous/],
  'bounded-ci-wait': ['bin/dm-pr.sh', /await-checks/],
  'scheduled-fleet-sweep': ['.agents/skills/supervision/SKILL.md', /scheduled task[\s\S]*dm-pr\.sh sweep/],
  'change-review': ['.agents/skills/change-review/SKILL.md', /waiter_agent_id[\s\S]*waiter_state=terminal/],
  'pr-gates': ['config/pr-pipeline.rigorous.json', /"verify"[\s\S]*"security"/],
  'post-pr-review': ['.agents/skills/post-pr-review/SKILL.md', /review comment|review feedback/],
  'github-tooling': ['bin/dm-pr.sh', /gh api/],
  'browser-tooling': ['AGENTS.md', /chrome-devtools-axi/],
  'lavish-tooling': ['bin/dm-lavish.sh', /lavish-axi/],
  'credential-handoff': ['.agents/skills/credential-handoff/SKILL.md', /reference[\s\S]*never the value/i],
  'memory-routing': ['bin/dm-memory.sh', /--dockmaster-only/],
  diagnostics: ['.agents/skills/diagnostic-reasoning/SKILL.md', /evidence[\s\S]*implementation/i],
  'merge-conflicts': ['.agents/skills/merge-conflict/SKILL.md', /rebase/],
  rollback: ['.agents/skills/rollback/SKILL.md', /revert/],
  'testing-policy': ['bin/dm-test.sh', /soft skip|no test command/i],
  'fleet-campaigns': ['.agents/skills/fleet-change/SKILL.md', /bounded waves[\s\S]*`inflight`/],
  'deterministic-workflow': ['workflows/pr-pipeline.js', /verify-findings[\s\S]*security/],
  'merge-safety': ['bin/dm-lib.sh', /dm_merge_gate/],
  'right-sizing': ['.agents/skills/task-lifecycle/SKILL.md', /at most three[\s\S]*reserving three/],
  'plugins-and-fallbacks': ['README.md', /Every GitHub call the toolbelt makes runs\s+on plain `gh`/i],
  'project-safety-config': ['.codex/config.toml', /dm-command-guard\.sh/],
}

function fail(message) {
  throw new Error(message)
}

function read(relativePath) {
  return fs.readFileSync(path.join(ROOT, relativePath), 'utf8')
}

function readJson(relativePath) {
  return JSON.parse(read(relativePath))
}

function sorted(values) {
  return [...values].sort()
}

function sameList(actual, expected, label) {
  const left = JSON.stringify(sorted(actual))
  const right = JSON.stringify(sorted(expected))
  if (left !== right) fail(`${label}: ${left} != ${right}`)
}

function skillNames(root) {
  const absolute = path.join(ROOT, root)
  return fs.readdirSync(absolute)
    .filter((name) => fs.statSync(path.join(absolute, name)).isDirectory())
    .filter((name) => fs.existsSync(path.join(absolute, name, 'SKILL.md')))
}

function frontmatterName(skillPath) {
  const match = read(skillPath).match(/^---\n[\s\S]*?^name:\s*["']?([^\n"']+)/m)
  if (!match) fail(`${skillPath}: missing frontmatter name`)
  return match[1].trim()
}

function checkSkillSets() {
  for (const [runtime, root] of Object.entries(RUNTIMES)) {
    const names = skillNames(root)
    sameList(names, MANIFEST.skills, `${runtime} skill set`)
    for (const name of names) {
      const skillPath = `${root}/${name}/SKILL.md`
      if (frontmatterName(skillPath) !== name) fail(`${skillPath}: name must equal directory`)
    }
  }
  console.log(`ok   exact ${MANIFEST.skills.length}-skill runtime parity`)
}

function checkTriggers() {
  const triggers = new Set()
  for (const match of read('AGENTS.md').matchAll(/^- \*\*([a-z][a-z-]+)\*\* —/gm)) {
    triggers.add(match[1])
  }
  sameList(triggers, MANIFEST.skills, 'AGENTS.md trigger set')
  console.log('ok   AGENTS.md trigger parity')
}

function checkSeparation() {
  const specific = new Set(MANIFEST.runtime_specific_skills)
  const claudeTerms = /\b(?:SendMessage|TaskList|Monitor|ScheduleWakeup|CronCreate)\b|\bAgent\b|`Workflow`|Workflow tool|Claude Code|subagent_type|isolation:/
  const codexTerms = /\b(?:spawn_agent|followup_task|send_message|wait_agent|interrupt_agent|list_agents|fork_turns)\b/
  for (const name of MANIFEST.skills) {
    const claude = read(`${RUNTIMES.claude}/${name}/SKILL.md`)
    const codex = read(`${RUNTIMES.codex}/${name}/SKILL.md`)
    if (claudeTerms.test(codex)) fail(`${name}: Claude primitive leaked into Codex adapter`)
    if (codexTerms.test(claude)) fail(`${name}: Codex primitive leaked into Claude adapter`)
    if (!specific.has(name) && claude !== codex) fail(`${name}: neutral adapters drifted`)
  }
  console.log('ok   runtime vocabulary separation and neutral-byte parity')
}

function checkCodexThreadNames() {
  const lifecycle = read('.agents/skills/task-lifecycle/SKILL.md')
  const requirements = [
    [/bin\/dm-thread-name\.sh <id>/, 'deterministic thread-name helper'],
    [/spawn_agent\(task_name=<thread_name>/, 'separate sanitized task_name'],
    [/agent_id <returned-agent-id>/, 'returned runtime identity persistence'],
    [/never substitute[\s\S]{0,80}durable id or thread label/, 'identity separation'],
  ]
  for (const [pattern, label] of requirements) {
    if (!pattern.test(lifecycle)) fail(`Codex task dispatch missing ${label}`)
  }
  if (/spawn_agent\(task_name=<id>/.test(lifecycle)) fail('Codex dispatch reuses durable id as task_name')
  console.log('ok   Codex durable task and runtime thread identities remain separate')
}

function checkCodexRigorousFallbacks() {
  const workflow = read('.agents/skills/pr-workflow/SKILL.md')
  const requirements = [
    [/fresh no-fork general verifier/, 'native verification fallback'],
    [/real\s+browser[\s\S]{0,160}CLI\/API/, 'browser and non-browser verification paths'],
    [/missing browser\/runtime\/capability is `FAIL`/, 'verification fail-closed contract'],
    [/fresh no-fork general reviewer/, 'native security fallback'],
    [/auth\/authz[\s\S]{0,180}injection[\s\S]{0,180}secret exposure/, 'focused security lenses'],
    [/compatible host[\s\S]{0,320}`args`[\s\S]{0,80}`agent`[\s\S]{0,80}`parallel`/, 'compatible-host runner boundary'],
  ]
  for (const [pattern, label] of requirements) {
    if (!pattern.test(workflow)) fail(`Codex rigorous workflow missing ${label}`)
  }
  if (/verify skill|security-review|Workflow tool|\bAgent\b/.test(workflow)) {
    fail('Codex rigorous workflow contains unavailable runtime vocabulary')
  }
  console.log('ok   Codex rigorous gates have executable fail-closed fallbacks')
}

function checkCodexLavishWake() {
  const review = read('.agents/skills/change-review/SKILL.md')
  const supervision = read('.agents/skills/supervision/SKILL.md')
  const requirements = [
    [review, /spawn_agent\([\s\S]*fork_turns="none"\)/, 'no-fork waiter dispatch'],
    [review, /bin\/dm-lavish\.sh poll <id>/, 'synchronous Lavish poll'],
    [review, /waiter must not return while the command is still live/, 'waiter session ownership'],
    [review, /completion is delivered to the parent mailbox/, 'parent mailbox completion'],
    [review, /Never[\s\S]{0,80}terminal session as a parent wake source/, 'raw-session prohibition'],
    [review, /followup_task[\s\S]{0,80}instead of consuming another thread/, 'waiter reuse'],
    [supervision, /exit does not\nproduce a parent-mailbox wake/, 'terminal non-notification'],
    [supervision, /wait_agent[\s\S]{0,80}native wake path/, 'native mailbox wait'],
  ]
  for (const [content, pattern, label] of requirements) {
    if (!pattern.test(content)) fail(`Codex Lavish wake contract missing ${label}`)
  }
  if (/collect feedback with a yielded command session/.test(review)) {
    fail('Codex change review still treats a yielded command as the approval wake')
  }
  console.log('ok   Codex Lavish wait has a notification-producing parent wake')
}

function checkFleetOwnershipOrder() {
  const runtimes = [
    ['Claude', '.claude/skills/fleet-change/SKILL.md', 'Agent(prompt=<brief>'],
    ['Codex', '.agents/skills/fleet-change/SKILL.md', 'spawn_agent(task_name=<thread_name>'],
  ]
  for (const [runtime, file, spawnText] of runtimes) {
    const content = read(file)
    const positions = [
      content.indexOf('--status queued'),
      content.indexOf(spawnText),
      content.indexOf('dm-task.sh set <child-id> agent_id <returned-agent-id>'),
      content.indexOf('dm-backlog.sh move <child-id> inflight'),
    ]
    if (positions.some((position) => position < 0)) fail(`${runtime} fleet ownership sequence is incomplete`)
    if (!positions.every((position, index) => index === 0 || position > positions[index - 1])) {
      fail(`${runtime} fleet ownership sequence is out of order`)
    }
    if (/--campaign <id> --status inflight/.test(content)) fail(`${runtime} fleet skill still claims ownership before spawn`)
  }
  console.log('ok   fleet children stay queued until runtime ownership persists')
}

function checkCapabilities() {
  const docs = read('docs/runtime-capabilities.md')
  const ids = new Set()
  for (const item of MANIFEST.capabilities) {
    if (!item.id || ids.has(item.id)) fail(`invalid or duplicate capability id: ${item.id}`)
    ids.add(item.id)
    if (!item.claude || !item.codex || !item.requirement || !item.verification) fail(`${item.id}: incomplete mapping`)
    if (!['direct', 'contract', 'manual'].includes(item.verification)) fail(`${item.id}: invalid verification label`)
    if (!docs.includes(`\`${item.id}\``)) fail(`${item.id}: absent from markdown matrix`)
    if (!Array.isArray(item.evidence) || item.evidence.length < 2) fail(`${item.id}: weak evidence list`)
    for (const evidence of item.evidence) {
      if (!fs.existsSync(path.join(ROOT, evidence))) fail(`${item.id}: missing evidence ${evidence}`)
    }
    const assertion = CAPABILITY_ASSERTIONS[item.id]
    if (!assertion) fail(`${item.id}: no capability-specific executable assertion`)
    const [assertionFile, pattern] = assertion
    if (!pattern.test(read(assertionFile))) fail(`${item.id}: assertion failed in ${assertionFile}`)
  }
  sameList(Object.keys(CAPABILITY_ASSERTIONS), [...ids], 'capability assertion coverage')
  const counts = MANIFEST.capabilities.reduce((all, item) => {
    all[item.verification] = (all[item.verification] || 0) + 1
    return all
  }, {})
  if (counts.direct !== 13 || counts.contract !== 9 || counts.manual !== 6) {
    fail(`verification class drift: ${JSON.stringify(counts)}`)
  }
  console.log(`ok   ${ids.size}-capability matrix: direct=${counts.direct || 0} contract=${counts.contract || 0} manual=${counts.manual || 0}`)
}

function checkCodexConfig() {
  const config = read('.codex/config.toml')
  const maxDepth = Number(config.match(/^max_depth\s*=\s*(\d+)/m)?.[1])
  const maxThreads = Number(config.match(/^max_threads\s*=\s*(\d+)/m)?.[1])
  const docBytes = Number(config.match(/^project_doc_max_bytes\s*=\s*(\d+)/m)?.[1])
  const agentsBytes = Buffer.byteLength(read('AGENTS.md'))
  if (maxDepth < 2 || maxDepth > 3) fail(`Codex max_depth must support exactly bounded nesting: ${maxDepth}`)
  if (maxThreads < 2 || maxThreads > 6) fail(`Codex max_threads must be bounded at 2..6: ${maxThreads}`)
  if (!config.includes('multi_agent = true')) fail('Codex multi_agent must be explicit')
  if (!config.includes('[[hooks.PreToolUse]]') || !config.includes('dm-command-guard.sh')) {
    fail('Codex project config must install the destructive-command PreToolUse guard')
  }
  if (agentsBytes > docBytes) fail(`AGENTS.md ${agentsBytes} exceeds Codex cap ${docBytes}`)
  console.log(`ok   Codex config depth=${maxDepth} threads=${maxThreads} AGENTS=${agentsBytes}/${docBytes}B`)
}

function main() {
  checkSkillSets()
  checkTriggers()
  checkSeparation()
  checkCodexThreadNames()
  checkCodexRigorousFallbacks()
  checkCodexLavishWake()
  checkFleetOwnershipOrder()
  checkCapabilities()
  checkCodexConfig()
  console.log('\nruntime parity checks passed')
}

main()
