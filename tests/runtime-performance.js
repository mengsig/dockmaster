#!/usr/bin/env node

const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { spawnSync } = require('child_process')

const ROOT = process.env.DM_PARITY_ROOT
  ? path.resolve(process.env.DM_PARITY_ROOT)
  : path.join(__dirname, '..')
const BASELINE = json('config/runtime-performance-baseline.json')

function read(relativePath) {
  return fs.readFileSync(path.join(ROOT, relativePath), 'utf8')
}

function json(relativePath) {
  return JSON.parse(read(relativePath))
}

function bytes(relativePath) {
  return fs.statSync(path.join(ROOT, relativePath)).size
}

function sha256(relativePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(path.join(ROOT, relativePath))).digest('hex')
}

function skillMetrics(root) {
  let total = 0
  let descriptions = 0
  const absolute = path.join(ROOT, root)
  for (const name of fs.readdirSync(absolute).sort()) {
    const skillPath = path.join(absolute, name, 'SKILL.md')
    if (!fs.existsSync(skillPath)) continue
    const body = fs.readFileSync(skillPath, 'utf8')
    const description = body.match(/^description:\s*(.+)$/m)?.[1] || ''
    total += Buffer.byteLength(body)
    descriptions += Buffer.byteLength(`${name}: ${description}\n`)
  }
  return { total, descriptions }
}

function medianStartup(command) {
  const samples = []
  for (let i = 0; i < 5; i++) {
    const start = process.hrtime.bigint()
    const run = spawnSync(command, ['--version'], { encoding: 'utf8', timeout: 3000 })
    if (run.error?.code === 'ENOENT') return null
    if (run.error || run.status !== 0) {
      console.error(`warn ${command} startup sample unavailable: ${run.error?.code || run.status}`)
      return null
    }
    samples.push(Number(process.hrtime.bigint() - start) / 1e6)
  }
  samples.sort((a, b) => a - b)
  return Number(samples[2].toFixed(1))
}

function assertGuardrails(metrics) {
  const limits = BASELINE.limits
  if (metrics.shared.agents > BASELINE.shared_agents_bytes + limits.shared_agents_growth_bytes) {
    throw new Error(`shared AGENTS.md grew beyond ${limits.shared_agents_growth_bytes}B allowance`)
  }
  if (metrics.claude.settings !== BASELINE.claude_settings_bytes) {
    throw new Error('Codex support changed Claude always-loaded settings')
  }
  if (metrics.claude.skills.total !== BASELINE.claude_skill_bytes) {
    throw new Error('Codex support changed Claude skill bodies')
  }
  if (metrics.claude.skills.descriptions !== BASELINE.claude_skill_description_bytes) {
    throw new Error('Codex support changed Claude skill discovery descriptions')
  }
  for (const [file, expected] of Object.entries(BASELINE.claude_files_sha256)) {
    if (metrics.claude.files_sha256[file] !== expected) {
      throw new Error(`Claude runtime file changed: ${file}`)
    }
  }
  const actualFiles = Object.keys(metrics.claude.files_sha256).sort()
  const expectedFiles = Object.keys(BASELINE.claude_files_sha256).sort()
  if (JSON.stringify(actualFiles) !== JSON.stringify(expectedFiles)) {
    throw new Error('Claude runtime file hash inventory changed')
  }
  for (const [runtime, skill] of Object.entries({ claude: metrics.claude.skills, codex: metrics.codex.skills })) {
    if (skill.descriptions > limits.skill_description_bytes_per_runtime) {
      throw new Error(`${runtime} descriptions exceed ${limits.skill_description_bytes_per_runtime}B`)
    }
  }
  if (metrics.shared.agents > limits.codex_project_doc_bytes) throw new Error('AGENTS.md exceeds Codex project cap')
}

function collect() {
  const sampleStartup = process.env.DM_RUNTIME_STARTUP_SAMPLE === '1'
  const claudeFiles = Object.keys(BASELINE.claude_files_sha256)
  return {
    baseline_commit: BASELINE.base_commit,
    shared: {
      agents: bytes('AGENTS.md'),
      agents_growth: bytes('AGENTS.md') - BASELINE.shared_agents_bytes,
      approximate_tokens: Math.ceil(bytes('AGENTS.md') / 4),
    },
    claude: {
      settings: bytes('.claude/settings.json'),
      skills: skillMetrics('.claude/skills'),
      files_sha256: Object.fromEntries(claudeFiles.map((file) => [file, sha256(file)])),
      cli_startup_median_ms: sampleStartup ? medianStartup('claude') : null,
    },
    codex: {
      config: bytes('.codex/config.toml'),
      rules: bytes('.codex/rules/dockmaster.rules'),
      skills: skillMetrics('.agents/skills'),
      cli_startup_median_ms: sampleStartup ? medianStartup('codex') : null,
    },
    startup_sampling: sampleStartup ? 'bounded diagnostic' : 'disabled (set DM_RUNTIME_STARTUP_SAMPLE=1)',
  }
}

const metrics = collect()
assertGuardrails(metrics)
console.log(JSON.stringify(metrics, null, 2))
console.error('runtime performance guardrails passed')
