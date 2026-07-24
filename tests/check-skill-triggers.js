#!/usr/bin/env node

const fs = require('fs')
const path = require('path')

const ROOT = process.env.DM_CHECK_ROOT
  ? path.resolve(process.env.DM_CHECK_ROOT)
  : path.join(__dirname, '..')
const SKILL_ROOT = '.claude/skills'

function fail(message) {
  throw new Error(message)
}

function read(relativePath) {
  return fs.readFileSync(path.join(ROOT, relativePath), 'utf8')
}

function sorted(values) {
  return [...values].sort()
}

function sameList(actual, expected, label) {
  const left = JSON.stringify(sorted(actual))
  const right = JSON.stringify(sorted(expected))
  if (left !== right) fail(`${label}: ${left} != ${right}`)
}

function skillNames() {
  const absolute = path.join(ROOT, SKILL_ROOT)
  const names = fs.readdirSync(absolute)
    .filter((name) => fs.statSync(path.join(absolute, name)).isDirectory())
    .filter((name) => fs.existsSync(path.join(absolute, name, 'SKILL.md')))
  if (!names.length) fail(`${SKILL_ROOT}: no skills discovered`)
  return names
}

function frontmatterName(skillPath) {
  const match = read(skillPath).match(/^---\n[\s\S]*?^name:\s*["']?([^\n"']+)/m)
  if (!match) fail(`${skillPath}: missing frontmatter name`)
  return match[1].trim()
}

// A skill is only reachable if its frontmatter name matches the directory the
// runtime discovers it under.
function checkSkillNames(skills) {
  for (const name of skills) {
    const skillPath = `${SKILL_ROOT}/${name}/SKILL.md`
    if (frontmatterName(skillPath) !== name) fail(`${skillPath}: name must equal directory`)
  }
  console.log(`ok   ${skills.length} skills named after their directory`)
}

// Every skill needs a trigger bullet, and every trigger bullet needs a skill:
// an untriggered skill is never loaded, a triggerless bullet points nowhere.
function checkTriggers(skills) {
  const triggers = new Set()
  for (const match of read('AGENTS.md').matchAll(/^- \*\*([a-z][a-z-]+)\*\* —/gm)) {
    triggers.add(match[1])
  }
  sameList(triggers, skills, 'AGENTS.md trigger set')
  console.log('ok   AGENTS.md trigger parity')
}

// A fleet child must stay queued until its spawned agent id is persisted;
// claiming inflight before that loses the owner if the spawn fails.
function checkFleetOwnershipOrder() {
  const file = `${SKILL_ROOT}/fleet-change/SKILL.md`
  const content = read(file)
  const positions = [
    content.indexOf('--status queued'),
    content.indexOf('Agent(prompt=<brief>'),
    content.indexOf('dm-task.sh set <child-id> agent_id <returned-agent-id>'),
    content.indexOf('dm-backlog.sh move <child-id> inflight'),
  ]
  if (positions.some((position) => position < 0)) fail(`${file}: ownership sequence is incomplete`)
  if (!positions.every((position, index) => index === 0 || position > positions[index - 1])) {
    fail(`${file}: ownership sequence is out of order`)
  }
  if (/--campaign <id> --status inflight/.test(content)) fail(`${file}: claims ownership before spawn`)
  console.log('ok   fleet children stay queued until agent ownership persists')
}

function main() {
  const skills = skillNames()
  checkSkillNames(skills)
  checkTriggers(skills)
  checkFleetOwnershipOrder()
  console.log('\nskill trigger checks passed')
}

main()
