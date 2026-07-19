#!/usr/bin/env node

const fs = require('fs')
const path = require('path')

function fail(message) {
  throw new Error(message)
}

function description(skillFile) {
  const content = fs.readFileSync(skillFile, 'utf8')
  const match = content.match(/^---\n[\s\S]*?^description:\s*(.+)$/m)
  if (!match) fail(`${skillFile}: missing frontmatter description`)
  return match[1].trim().replace(/^['"]|['"]$/g, '')
}

function skillBlock(prompt) {
  const strings = []
  const visit = (value) => {
    if (typeof value === 'string') strings.push(value)
    else if (Array.isArray(value)) value.forEach(visit)
    else if (value && typeof value === 'object') Object.values(value).forEach(visit)
  }
  visit(prompt)
  const blocks = strings.filter((value) =>
    value.includes('<skills_instructions>') && value.includes('### Available skills'))
  if (blocks.length !== 1) fail(`expected one structured skills block, found ${blocks.length}`)
  return blocks[0]
}

function validatePrompt(prompt, root) {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'config/runtime-capabilities.json')))
  const block = skillBlock(prompt)
  for (const name of manifest.skills) {
    const skillFile = path.join(root, '.agents', 'skills', name, 'SKILL.md')
    const expected = `- ${name}: ${description(skillFile)} (file: ${skillFile})`
    if (!block.includes(expected)) fail(`${name}: missing exact skill description or locator`)
  }
}

function replaceStrings(value, transform) {
  if (typeof value === 'string') return transform(value)
  if (Array.isArray(value)) return value.map((item) => replaceStrings(item, transform))
  if (!value || typeof value !== 'object') return value
  return Object.fromEntries(Object.entries(value).map(([key, item]) =>
    [key, replaceStrings(item, transform)]))
}

function expectFailure(prompt, root, label) {
  try {
    validatePrompt(prompt, root)
  } catch {
    return
  }
  fail(`negative mutation passed: ${label}`)
}

const [promptFile, rootArg] = process.argv.slice(2)
if (!promptFile || !rootArg) fail('usage: check-codex-skill-discovery.js <prompt.json> <root>')
const root = path.resolve(rootArg)
const prompt = JSON.parse(fs.readFileSync(path.resolve(promptFile), 'utf8'))
validatePrompt(prompt, root)
expectFailure(replaceStrings(prompt, (value) =>
  value.includes('<skills_instructions>') ? 'skills block removed' : value), root, 'removed skills block')
const firstSkill = JSON.parse(fs.readFileSync(path.join(root, 'config/runtime-capabilities.json'))).skills[0]
const locator = `.agents/skills/${firstSkill}/SKILL.md`
expectFailure(replaceStrings(prompt, (value) => value.replace(locator, '.agents/skills/missing/SKILL.md')),
  root, 'removed exact locator')
console.log('ok   structured Codex skill descriptions and locators; negative mutations rejected')
