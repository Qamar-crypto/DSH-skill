// Host half of dsh-plugin-mimo-delegate.
//
// It owns one settings namespace ("mimo-delegate") with a single `enabled`
// boolean, and reconciles the on-disk state whenever that value changes.
//
// The reconciliation itself is NOT reimplemented here on purpose: the tested
// implementation lives in Set-Delegation.ps1 (parks the skill outside the
// skills root + rewrites the marker block in ~/.dsh/AGENTS.md). Having one
// implementation means the plugin UI and the CLI switch can never disagree.
//
// Additionally this host half exposes two async bridge operations:
//   newproject  -> MimoDesktop.ps1 newproject -Dir "<abs folder>"
//   newtask     -> MimoDesktop.ps1 newtask -Dir "<abs folder>" -MessageFile <tmp utf8>
// Both use execFile with an argument array (never a concatenated string), so
// paths with spaces survive. UI automation behind these actions takes 5-20s
// and briefly steals keyboard/mouse focus: they MUST stay async and MUST NOT
// throw out of apply() (a throw drops DSH into its recovery screen).
import { execFile } from 'node:child_process'
import { existsSync, writeFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { homedir, tmpdir } from 'node:os'
import Schema from '@deepseek-ai/schemastery'

const NS = 'mimo-delegate'
const inject = ['settings']
const DEFAULT_TOGGLE_SCRIPT = 'D:\\Deepseek Harness\\_mimo_bridge\\Set-Delegation.ps1'
const DEFAULT_MIMO_DESKTOP = 'D:\\Deepseek Harness\\_mimo_bridge\\MimoDesktop.ps1'
const DEFAULT_PROJECT_DIR = 'D:\\Deepseek Harness'
const DEFAULT_TASK_TEXT = '只回一行：ok'
const POWERSHELL = 'powershell'

const Config = Schema.object({
  enabled: Schema.boolean().default(true).description(
    'Delegate grunt work to the local MiMo Desktop app (moves the mimo-delegate skill in/out and rewrites the AGENTS.md rule block).',
  ),
  toggleScript: Schema.string().default(DEFAULT_TOGGLE_SCRIPT).description(
    'Absolute path of Set-Delegation.ps1, the one implementation that parks the skill and rewrites the rule block.',
  ),
  projectDir: Schema.string().default(DEFAULT_PROJECT_DIR).description(
    'Absolute folder used by MiMo newproject / newtask bridge actions.',
  ),
  taskText: Schema.string().default(DEFAULT_TASK_TEXT).description(
    'Default task text submitted by the MiMo newtask action.',
  ),
  op: Schema.string().default('').description(
    'Pending bridge op: newproject | newtask | empty.',
  ),
  opStatus: Schema.string().default('').description(
    'Bridge op status: running | done | error | empty.',
  ),
  opResult: Schema.string().default('').description('Human-readable result of the last bridge op.'),
  opSessionId: Schema.string().default('').description('MiMo sessionId returned by newtask, if any.'),
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

/** Best-effort JSON extraction from bridge stdout; never throws. */
function parseBridgeStdout(stdout) {
  const text = String(stdout == null ? '' : stdout)
  const trimmed = text.trim()
  if (!trimmed) return { data: null, raw: text }
  try {
    return { data: JSON.parse(trimmed), raw: text }
  } catch {}
  const s = trimmed.indexOf('{')
  const e = trimmed.lastIndexOf('}')
  if (s >= 0 && e > s) {
    try {
      return { data: JSON.parse(trimmed.slice(s, e + 1)), raw: text }
    } catch {}
  }
  return { data: null, raw: text }
}

/**
 * Invoke MimoDesktop.ps1 with an argument array.
 * action: newproject | newtask
 * Returns Promise<{ok:boolean, data?:object, error?:string, raw?:string}>
 */
function runBridgeAction(action, opts) {
  return new Promise((resolve) => {
    let tmpFile = null
    try {
      const dir = opts && opts.dir != null ? String(opts.dir) : ''
      const message = opts && opts.message != null ? String(opts.message) : ''
      if (!dir || !dir.trim()) {
        resolve({ ok: false, error: 'project folder is empty' })
        return
      }
      const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', DEFAULT_MIMO_DESKTOP]
      if (action === 'newproject') {
        args.push('newproject', '-Dir', dir)
      } else if (action === 'newtask') {
        if (!message || !message.trim()) {
          resolve({ ok: false, error: 'task message is empty' })
          return
        }
        // -MessageFile keeps multi-line / spaced task text intact through PS 5.1.
        tmpFile = join(tmpdir(), `mimo-delegate-task-${Date.now()}-${process.pid}.txt`)
        writeFileSync(tmpFile, message, 'utf8')
        args.push('newtask', '-Dir', dir, '-MessageFile', tmpFile)
      } else {
        resolve({ ok: false, error: `unknown bridge action: ${action}` })
        return
      }

      const cleanup = () => {
        try {
          if (tmpFile) rmSync(tmpFile, { force: true })
        } catch {}
      }

      execFile(POWERSHELL, args, { windowsHide: true, timeout: 120_000 }, (error, stdout, stderr) => {
        cleanup()
        const parsed = parseBridgeStdout(stdout)
        const rawText = String(parsed.raw || stdout || stderr || (error && error.message) || '').trim()
        if (error) {
          resolve({ ok: false, error: rawText || String(error.message || error), raw: parsed.raw })
          return
        }
        if (!parsed.data) {
          resolve({ ok: false, error: rawText || 'bridge returned no JSON', raw: parsed.raw })
          return
        }
        if (parsed.data.ok === false) {
          resolve({
            ok: false,
            error: String(parsed.data.error || parsed.data.message || parsed.data.reason || 'bridge reported failure'),
            data: parsed.data,
            raw: parsed.raw,
          })
          return
        }
        resolve({ ok: true, data: parsed.data, raw: parsed.raw })
      })
    } catch (error) {
      try {
        if (tmpFile) rmSync(tmpFile, { force: true })
      } catch {}
      resolve({ ok: false, error: String((error && error.message) || error) })
    }
  })
}

function formatBridgeSuccess(action, data) {
  try {
    if (data && data.sessionId) return String(data.sessionId)
    if (data && data.ok !== undefined && data.dir) return `ok dir=${data.dir}`
    if (data && data.ok) return 'ok'
    return JSON.stringify(data)
  } catch {
    return action === 'newtask' ? 'ok' : 'ok'
  }
}

/** Pull the namespace section out of whatever the settings service hands us. */
function sectionOf(value) {
  if (!value || typeof value !== 'object') return undefined
  const own = value[NS]
  if (own && typeof own === 'object') return own
  if (typeof value.enabled === 'boolean') return own || value
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

  // Expose direct async entry points when the host context allows it.
  // Callers always get a resolved {ok, ...} object; never a throw.
  const bridgeApi = {
    newProject: (dir) => {
      try {
        return runBridgeAction('newproject', { dir })
      } catch (error) {
        return Promise.resolve({ ok: false, error: String((error && error.message) || error) })
      }
    },
    newTask: (dir, message) => {
      try {
        return runBridgeAction('newtask', { dir, message })
      } catch (error) {
        return Promise.resolve({ ok: false, error: String((error && error.message) || error) })
      }
    },
  }
  try { if (ctx) ctx.mimoDelegate = bridgeApi } catch {}
  try { if (ctx && typeof ctx.provide === 'function') ctx.provide(NS, bridgeApi) } catch {}

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
    const writeSection = (patch) => {
      try {
        if (scope && typeof scope.update === 'function') {
          scope.update(patch)
          return true
        }
      } catch (error) {
        warn(`scope.update failed: ${error && error.message ? error.message : error}`)
      }
      return false
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

    // Settings-driven bridge ops (used by the web client when it cannot reach
    // a direct method). Guarded so a watch callback can never throw.
    let bridgeBusy = false
    const runPendingBridgeOp = async (section) => {
      try {
        if (!section || section.opStatus !== 'running') return
        const kind = section.op
        if (kind !== 'newproject' && kind !== 'newtask') return
        if (bridgeBusy) return
        bridgeBusy = true
        const result = await runBridgeAction(kind, {
          dir: section.projectDir,
          message: section.taskText,
        })
        const payload = {
          opStatus: result.ok ? 'done' : 'error',
          opResult: result.ok
            ? formatBridgeSuccess(kind, result.data)
            : String(result.error || 'bridge failed'),
          opSessionId:
            result.ok && result.data && result.data.sessionId
              ? String(result.data.sessionId)
              : '',
        }
        if (!writeSection(payload)) {
          warn(`bridge op finished but could not write settings: ${payload.opResult}`)
        } else if (result.ok) {
          log(`bridge ${kind} ok: ${payload.opResult}`)
        } else {
          warn(`bridge ${kind} failed: ${payload.opResult}`)
        }
      } catch (error) {
        warn(`bridge op crashed: ${error && error.message ? error.message : error}`)
        writeSection({ opStatus: 'error', opResult: String((error && error.message) || error), opSessionId: '' })
      } finally {
        bridgeBusy = false
      }
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
      () => observe((next) => {
        try { sync(next) } catch (error) {
          warn(`toggle sync crashed: ${error && error.message ? error.message : error}`)
        }
        try { runPendingBridgeOp(next || readSection()) } catch (error) {
          warn(`bridge observe crashed: ${error && error.message ? error.message : error}`)
        }
      }),
      'mimo-delegate: reconcile on settings change',
    )
  } catch (error) {
    warn(`apply failed, plugin stays idle: ${error && error.message ? error.message : error}`)
  }
}

export { apply, inject, NS, Config }
