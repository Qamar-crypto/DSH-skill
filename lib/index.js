// Host half of dsh-plugin-mimo-delegate.
//
// It owns one settings namespace ("mimo-delegate") with a single `enabled`
// boolean, and reconciles the on-disk state whenever that value changes.
//
// The reconciliation itself is NOT reimplemented here on purpose: the tested
// implementation lives in Set-Delegation.ps1 (parks the skill outside the
// skills root + rewrites the marker block in ~/.dsh/AGENTS.md). Having one
// implementation means the plugin UI and the CLI switch can never disagree.
import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import Schema from '@deepseek-ai/schemastery'

const NS = 'mimo-delegate'
const inject = ['settings']
const DEFAULT_TOGGLE_SCRIPT = 'D:\\Deepseek Harness\\_mimo_bridge\\Set-Delegation.ps1'
const POWERSHELL = 'powershell'

const Config = Schema.object({
  enabled: Schema.boolean().default(true).description(
    'Delegate grunt work to the local MiMo Desktop app (moves the mimo-delegate skill in/out and rewrites the AGENTS.md rule block).',
  ),
  toggleScript: Schema.string().default(DEFAULT_TOGGLE_SCRIPT).description(
    'Absolute path of Set-Delegation.ps1, the one implementation that parks the skill and rewrites the rule block.',
  ),
})

function runToggle(script, enabled) {
  return new Promise((resolve) => {
    const target = typeof script === 'string' && script.trim() ? script : DEFAULT_TOGGLE_SCRIPT
    // Set-Delegation.ps1 takes -Action on|off, NOT -On/-Off switches. Passing
    // the wrong form makes PowerShell refuse the argument and the switch
    // silently does nothing.
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', target, '-Action', enabled ? 'on' : 'off']
    execFile(POWERSHELL, args, { windowsHide: true, timeout: 60_000 }, (error, stdout, stderr) => {
      if (error) return resolve({ ok: false, detail: String(stderr || error.message || error).trim() })
      resolve({ ok: true, detail: String(stdout || '').trim() })
    })
  })
}

/** Pull the namespace section out of whatever the settings service hands us. */
function sectionOf(value) {
  if (!value || typeof value !== 'object') return undefined
  const own = value[NS]
  if (own && typeof own === 'object') return own
  if (typeof value.enabled === 'boolean') return value
  return undefined
}

const SKILL_LIVE = join(homedir(), '.dsh', 'skills', 'mimo-delegate', 'SKILL.md')
const SKILL_PARKED = join(homedir(), '.dsh', 'skills-disabled', 'mimo-delegate', 'SKILL.md')

/** true = delegation on, false = parked (off), null = cannot tell. */
function readDiskState() {
  try {
    if (existsSync(SKILL_LIVE)) return true
    if (existsSync(SKILL_PARKED)) return false
  } catch {}
  return null
}

function apply(ctx, config) {
  const log = (msg) => {
    try { ctx.logger?.info?.(`[mimo-delegate] ${msg}`) } catch {}
  }
  const warn = (msg) => {
    try { ctx.logger?.warn?.(`[mimo-delegate] ${msg}`) } catch {}
  }

  // A plugin MUST NOT throw out of apply(): a bundle-level failure aborts the
  // whole DSH boot and drops the app into its recovery screen. This happened
  // once - ctx.settings.watch did not exist in this deployment - so everything
  // below probes for capabilities and degrades instead of throwing.
  try {
    if (!ctx || !ctx.settings || typeof ctx.settings.register !== 'function') {
      warn('settings service unavailable; plugin stays idle')
      return
    }

    const scope = ctx.settings.register(NS, Config, { base: config })
    const readSection = () => {
      try { return sectionOf(scope && typeof scope.get === 'function' ? scope.get() : undefined) } catch { return undefined }
    }

    // The change feed is not the same shape in every deployment: probe for it
    // in order, then fall back to polling. Never assume one API exists.
    const observe = (cb) => {
      try {
        if (typeof ctx.settings.watch === 'function') return ctx.settings.watch(cb)
        if (scope && typeof scope.watch === 'function') return scope.watch(cb)
        if (scope && typeof scope.subscribe === 'function') return scope.subscribe(cb)
      } catch (error) {
        warn(`change feed unavailable (${error && error.message ? error.message : error}); polling instead`)
      }
      const timer = setInterval(() => cb(readSection()), 3000)
      return () => clearInterval(timer)
    }

    const sync = async (source) => {
      const section = sectionOf(source) || readSection()
      if (!section || typeof section.enabled !== 'boolean') return
      const result = await runToggle(section.toggleScript, section.enabled)
      if (result.ok) log(`delegation ${section.enabled ? 'ON' : 'OFF'}`)
      else warn(`toggle failed: ${result.detail}`)
    }

    // At load, ADOPT the on-disk state instead of forcing the schema default.
    // Forcing it meant: the user turns delegation off with Set-Delegation.ps1,
    // DSH restarts, the plugin writes `on` back and silently overrides them.
    // The disk is the truth - the toggle script parks the skill when it is off.
    const resolved = readSection()
    const diskState = readDiskState()
    if (diskState === null) {
      sync(resolved || { enabled: true })
    } else if (resolved && resolved.enabled !== diskState && typeof scope.update === 'function') {
      try {
        scope.update({ enabled: diskState })
        log(`adopted on-disk state: ${diskState ? 'ON' : 'OFF'}`)
      } catch (error) {
        warn(`could not adopt on-disk state: ${error && error.message ? error.message : error}`)
      }
    }
    ctx.effect(
      () => observe((next) => { sync(next) }),
      'mimo-delegate: reconcile on settings change',
    )
  } catch (error) {
    warn(`apply failed, plugin stays idle: ${error && error.message ? error.message : error}`)
  }
}

export { apply, inject, NS, Config }
