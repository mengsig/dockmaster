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

function checkCapabilities() {
  const docs = read('docs/runtime-capabilities.md')
  const ids = new Set()
  for (const item of MANIFEST.capabilities) {
    if (!item.id || ids.has(item.id)) fail(`invalid or duplicate capability id: ${item.id}`)
    ids.add(item.id)
    if (!item.claude || !item.codex || !item.requirement) fail(`${item.id}: incomplete mapping`)
    if (!docs.includes(`\`${item.id}\``)) fail(`${item.id}: absent from markdown matrix`)
    if (!Array.isArray(item.evidence) || item.evidence.length < 2) fail(`${item.id}: weak evidence list`)
    for (const evidence of item.evidence) {
      if (!fs.existsSync(path.join(ROOT, evidence))) fail(`${item.id}: missing evidence ${evidence}`)
    }
  }
  console.log(`ok   ${ids.size}-capability matrix and evidence paths`)
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
  checkCapabilities()
  checkCodexConfig()
  console.log('\nruntime parity checks passed')
}

main()
