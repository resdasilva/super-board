#!/usr/bin/env bash
# Offline workflow contract: intake decisions and the ui surface reviewers.
set -euo pipefail
cd "$(dirname "$0")"
node - ../workflows/super-board-wave.js <<'JS'
const fs = require('fs')
const source = fs.readFileSync(process.argv[2], 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = (async () => {}).constructor
async function run(cards, intakeFor, surfaceVerdict = 'pass', tier) {
  const calls = []
  const prompts = {}
  const models = {}
  const agent = async (prompt, options) => {
    calls.push(options.label)
    prompts[options.label] = prompt
    models[options.label] = options.model
    if (options.label.startsWith('preflight:')) {
      return { verdicts: cards.filter(c => c.status === 'Ready').map(c => ({ number: c.number, verdict: 'proceed', detail: 'clear' })) }
    }
    if (options.label.startsWith('classify:')) {
      const n = Number(options.label.split('#')[1])
      return { kind: 'feature', complexity: 'low', status: 'ok', ...(intakeFor[n] || {}) }
    }
    if (options.label.startsWith('ux:') || options.label.startsWith('ui:')) {
      return { verdict: surfaceVerdict, findings: surfaceVerdict === 'changes'
        ? [{ severity: 'blocking', where: 'src/App.tsx:10', issue: 'save button unreachable by keyboard' }] : [], detail: 'checked' }
    }
    return { status: 'advanced', column: 'Done', detail: 'result' }
  }
  const pipeline = async (items, ...stages) => {
    const results = []
    for (const item of items) {
      let result = await stages[0](item)
      for (const stage of stages.slice(1)) result = await stage(result, item)
      results.push(result)
    }
    return results
  }
  const output = await new AsyncFunction('args', 'agent', 'pipeline', 'log', source)(
    { configPath: 'fixture.json', cards, ...(tier ? { tier } : {}) }, agent, pipeline, () => {})
  return { calls, prompts, models, output }
}
const assert = (ok, msg) => { if (!ok) throw Error(msg) }
const card = (number, extra = {}) => ({ number, title: 'Task', status: 'Ready', ...extra })
;(async () => {
  let n = 0
  // 1. reject: no build, card reported dropped at Done.
  let r = await run([card(1)], { 1: { decision: 'reject', column: 'Done', detail: 'out of scope' } })
  assert(!r.calls.includes('build:#1'), 'rejected card must not build: ' + r.calls)
  assert(r.output.cards[0].finalStatus === 'dropped' && r.output.cards[0].column === 'Done', 'reject summary: ' + JSON.stringify(r.output.cards[0]))
  n++
  // 2. needs-info: no build, card reported blocked.
  r = await run([card(2)], { 2: { decision: 'needs-info', column: 'Blocked', detail: 'which page?' } })
  assert(!r.calls.includes('build:#2'), 'needs-info card must not build')
  assert(r.output.cards[0].finalStatus === 'blocked' && r.output.cards[0].column === 'Blocked', 'needs-info summary')
  n++
  // 3. accept without surfaces: build → qa → review, no surface reviewers; intake prompt + stronger model.
  r = await run([card(3)], { 3: { decision: 'accept', surfaces: [] } })
  assert(['build:#3', 'qa:#3', 'review:#3'].every(l => r.calls.includes(l)), 'accepted card runs all lanes')
  assert(!r.calls.some(l => /^u[ix]:/.test(l)), 'no surface review without ui')
  assert(r.prompts['classify:#3'].includes('references/intake.md'), 'classify prompt must run intake')
  assert(r.models['classify:#3'] === 'sonnet', 'intake model on medium tier is sonnet')
  n++
  // 4. ui surface: ux + ui run before review, and their findings reach the Reviewer.
  r = await run([card(4)], { 4: { decision: 'accept', surfaces: ['ui'] } }, 'changes')
  const iRev = r.calls.indexOf('review:#4')
  assert(r.calls.indexOf('ux:#4') > -1 && r.calls.indexOf('ui:#4') > -1, 'surface reviewers run on ui cards')
  assert(r.calls.indexOf('ux:#4') < iRev && r.calls.indexOf('ui:#4') < iRev, 'surface review precedes Review')
  assert(r.prompts['review:#4'].includes('save button unreachable by keyboard'), 'findings reach the Reviewer')
  n++
  // 5. a later wave: card already in Review with the surface:ui label still gets surface review.
  r = await run([card(5, { status: 'Review', labels: ['feature', 'surface:ui'] })], {})
  assert(r.calls.includes('ux:#5') && r.calls.includes('review:#5'), 'label-driven surface review')
  n++
  // 6. qa-labelled cards skip intake; legacy classify output (no decision) still builds.
  r = await run([card(6, { labels: ['qa'] }), card(7)], {})
  assert(!r.prompts['classify:#6'].includes('references/intake.md'), 'qa cards skip intake')
  assert(r.models['classify:#6'] === 'haiku', 'qa card keeps the cheap router')
  assert(r.calls.includes('build:#7'), 'missing decision defaults to accept')
  n++
  // 7. a halted surface reviewer stops the card before Review.
  r = await run([card(8)], { 8: { decision: 'accept', surfaces: ['ui'] } }, 'halted')
  assert(!r.calls.includes('review:#8') && r.output.halted, 'halted surface review must halt')
  n++
  console.log(`PASS: test-wave-intake.sh (${n} scenarios)`)
})().catch(e => { console.error(e); process.exit(1) })
JS
