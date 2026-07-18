#!/usr/bin/env node
// tests/check-gate-drift.js - catches drift between workflows/pr-pipeline.js's
// built-in per-tier gate lists (FAST_GATES/DEFAULT_GATES/RIGOROUS_GATES, used
// only as a fallback when a caller passes no explicit args.gates) and the
// shipped config/pr-pipeline.<tier>.json files they are documented to mirror.
//
// workflows/pr-pipeline.js itself is never executed here (it expects an
// `args`/`agent`/`parallel`/`log` runtime injected by the Workflow tool, and is
// only checked with `node --check`), so this script does not run it. It reads
// its source text, extracts each built-in constant's array literal, and
// compares its gate-NAME sequence to the corresponding JSON file's — ignoring
// config-only fields (effort, note, max_rounds, ...) that don't affect which
// gates run or in what order.
//
// Run: node tests/check-gate-drift.js   (exit 0 = no drift)

const fs = require('fs')
const path = require('path')

const ROOT = path.join(__dirname, '..')
const RUNNER_PATH = path.join(ROOT, 'workflows', 'pr-pipeline.js')
const TIERS = [
  ['FAST_GATES', 'pr-pipeline.fast.json'],
  ['DEFAULT_GATES', 'pr-pipeline.default.json'],
  ['RIGOROUS_GATES', 'pr-pipeline.rigorous.json'],
]

// Extracts the array-literal source text bound to `const <name> = [ ... ]`,
// via bracket-depth counting that skips characters inside quoted strings (so a
// `[`/`]` inside a gate-name or note string can never miscount the depth).
function extractArrayLiteral(source, constName) {
  const marker = `const ${constName} = [`
  const start = source.indexOf(marker)
  if (start === -1) throw new Error(`could not find "${marker}" in ${RUNNER_PATH}`)
  const openBracket = start + marker.length - 1
  let depth = 0
  let inString = null // active quote char, or null when outside a string
  for (let i = openBracket; i < source.length; i++) {
    const ch = source[i]
    if (inString) {
      if (ch === '\\') { i++; continue } // skip escaped char, incl. an escaped quote
      if (ch === inString) inString = null
      continue
    }
    if (ch === '"' || ch === "'" || ch === '`') { inString = ch; continue }
    if (ch === '[') depth++
    else if (ch === ']') {
      depth--
      if (depth === 0) return source.slice(openBracket, i + 1)
    }
  }
  throw new Error(`unbalanced brackets extracting ${constName} from ${RUNNER_PATH}`)
}

// The extracted text is a literal array of plain object literals (strings,
// booleans, numbers, nested string arrays) with no references to runner
// variables — safe to evaluate in isolation via the Function constructor.
function evalArrayLiteral(literalSource, constName) {
  try {
    return new Function(`return (${literalSource})`)()
  } catch (err) {
    throw new Error(`failed to evaluate extracted ${constName} literal: ${err.message}`)
  }
}

function gateNames(gates) {
  return gates.map((g) => g.gate)
}

function main() {
  const runnerSource = fs.readFileSync(RUNNER_PATH, 'utf8')
  let failed = false

  for (const [constName, configFile] of TIERS) {
    const configPath = path.join(ROOT, 'config', configFile)
    const builtIn = evalArrayLiteral(extractArrayLiteral(runnerSource, constName), constName)
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'))

    const builtInNames = gateNames(builtIn)
    const configNames = gateNames(config.gates)
    const same = builtInNames.length === configNames.length
      && builtInNames.every((name, i) => name === configNames[i])

    if (same) {
      console.log(`ok   ${constName} matches ${configFile}: [${configNames.join(', ')}]`)
    } else {
      failed = true
      console.error(`FAIL ${constName} vs ${configFile}:`)
      console.error(`     runner: [${builtInNames.join(', ')}]`)
      console.error(`     config: [${configNames.join(', ')}]`)
    }
  }

  if (failed) {
    console.error('\ngate-list drift: update the built-in constant in workflows/pr-pipeline.js or the config JSON so they match.')
    process.exit(1)
  }
  console.log('\nno gate-list drift')
}

main()
