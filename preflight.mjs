// Pre-flight for this plugin's host half.
//
// Why it stages a copy into the profile before importing: the plugin's own
// imports (@deepseek-ai/schemastery) only resolve from inside the profile's
// node_modules, so importing it from a source checkout proves nothing.
//
// The staged copy is deliberately NOT listed in dsh.profile.bundles, so DSH
// itself can never load it. This is a rehearsal, not an install.
//
// What it proves: apply() never throws out of itself for ANY ctx shape a
// deployment might have. An earlier revision assumed ctx.settings.watch existed,
// threw, and that single throw aborted the whole DSH boot into its recovery
// screen. Run this before shipping any change to lib/index.js.
import { cpSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { fileURLToPath } from 'node:url'

const repoRoot = fileURLToPath(new URL('.', import.meta.url))
const profile = join(homedir(), '.dsh', 'profiles', 'desktop')
const stage = join(profile, 'node_modules', '__mimo_delegate_preflight__')

function makeCtx(opts = {}) {
  const {
    withSettings = true,
    withRegister = true,
    withServiceWatch = false,
    withScopeWatch = false,
    withScopeSubscribe = false,
    withGet = true,
  } = opts
  const logs = []
  const ctx = {
    logger: {
      info: (m) => logs.push(['info', m]),
      warn: (m) => logs.push(['warn', m]),
    },
    effect: (fn) => {
      try { return fn() } catch (error) {
        logs.push(['effect-throw', String((error && error.message) || error)])
      }
    },
  }
  if (withSettings) {
    ctx.settings = {}
    if (withRegister) {
      const scope = {}
      if (withGet) scope.get = () => ({ enabled: true, toggleScript: 'C:\\nonexistent\\toggle.ps1' })
      if (withScopeWatch) scope.watch = () => () => {}
      if (withScopeSubscribe) scope.subscribe = () => () => {}
      ctx.settings.register = () => scope
    }
    if (withServiceWatch) ctx.settings.watch = () => () => {}
  }
  return { ctx, logs }
}

const cases = [
  ['no ctx.settings at all', { withSettings: false }],
  ['settings without register()', { withRegister: false }],
  ['register + get, NO watch anywhere  <-- the shape that once killed DSH boot', {}],
  ['service-level watch present', { withServiceWatch: true }],
  ['scope-level watch present', { withScopeWatch: true }],
  ['scope-level subscribe present', { withScopeSubscribe: true }],
  ['register but scope.get missing', { withGet: false }],
]

const lines = []
let failed = 0
try {
  rmSync(stage, { recursive: true, force: true })
  cpSync(repoRoot, stage, { recursive: true })
  console.log(`staged for module resolution: ${stage}`)
  const mod = await import(new URL(`file:///${stage.replace(/\\/g, '/')}/lib/index.js`).href)
  console.log(`exports: ${Object.keys(mod).join(', ')}`)

  for (const [name, opts] of cases) {
    const { ctx, logs } = makeCtx(opts)
    try {
      await mod.apply(ctx, { enabled: true })
      if (logs.some(([kind]) => kind === 'effect-throw')) {
        failed++
        lines.push(`FAIL  ${name}  (effect callback threw)`)
      } else {
        lines.push(`ok    ${name}`)
      }
    } catch (error) {
      failed++
      lines.push(`FAIL  ${name}  apply threw -> ${(error && error.message) || error}`)
    }
    if ((opts.withSettings === false || opts.withRegister === false) && !logs.some(([kind]) => kind === 'warn')) {
      failed++
      lines.push(`      expected a warn line for: ${name}`)
    }
  }
} finally {
  rmSync(stage, { recursive: true, force: true })
}

console.log(lines.join('\n'))
console.log(failed === 0 ? 'PREFLIGHT PASS' : `PREFLIGHT FAIL (${failed} case(s))`)
process.exit(failed === 0 ? 0 : 1)
