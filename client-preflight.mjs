// Client-half rehearsal for dsh-plugin-mimo-delegate.
//
// The host half has preflight.mjs. The browser half had only a syntax check,
// which cannot catch a factory that throws while it loads - and a client module
// that throws at load is exactly the kind of thing that takes the web shell
// down. This runs the real lib/client.js with mocked react and a mocked
// window.__ModuleLoader__, then invokes the factory and inspects what it returns.
//
// The react mock is deliberately permissive (a self-returning callable proxy):
// the point is to prove the module loads and registers, not to render.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const clientPath = fileURLToPath(new URL('./lib/client.js', import.meta.url))

function makeAny() {
  const fn = function () { return makeAny() }
  return new Proxy(fn, {
    get: () => makeAny(),
    apply: () => makeAny(),
    construct: () => makeAny(),
    has: () => true,
  })
}

// --- browser-ish globals the module might touch while loading -------------
// Node 24 exposes `navigator` as a getter-only global, so these are passed as
// function parameters instead of being assigned onto globalThis.
const styleEl = { dataset: {}, textContent: '', setAttribute() {}, appendChild() {} }
const documentMock = {
  querySelector: () => null,
  createElement: () => styleEl,
  head: { appendChild() {} },
  body: { appendChild() {} },
}
const navigatorMock = { language: 'zh-CN', languages: ['zh-CN'] }

// --- capture the module registration --------------------------------------
let registration = null
globalThis.window = {
  __ModuleLoader__: {
    load(spec) { registration = spec },
  },
}

const source = readFileSync(clientPath, 'utf8')
const lines = []
let failed = 0

try {
  // The file is a plain script that calls window.__ModuleLoader__.load(...).
  new Function('window', 'require', 'document', 'navigator', source)(
    globalThis.window,
    (name) => {
      if (name === 'react' || name === 'react/jsx-runtime' || name === 'react-dom') return makeAny()
      throw new Error(`unexpected require("${name}")`)
    },
    documentMock,
    navigatorMock,
  )
  lines.push('ok    script evaluated (no load-time throw)')
} catch (error) {
  failed++
  lines.push(`FAIL  script threw while loading: ${(error && error.message) || error}`)
}

if (!registration) {
  failed++
  lines.push('FAIL  window.__ModuleLoader__.load was never called')
} else {
  lines.push(`ok    registered as id="${registration.id}"`)
  if (typeof registration.factory !== 'function') {
    failed++
    lines.push('FAIL  registration has no factory function')
  } else {
    let mod = null
    try {
      mod = registration.factory((name) => {
        if (name === 'react' || name === 'react/jsx-runtime' || name === 'react-dom') return makeAny()
        throw new Error(`unexpected require("${name}")`)
      })
      lines.push('ok    factory returned without throwing')
    } catch (error) {
      failed++
      lines.push(`FAIL  factory threw: ${(error && error.message) || error}`)
    }
    if (mod) {
      const keys = Object.keys(mod)
      lines.push(`ok    exports: ${keys.join(', ') || '(none)'}`)
      // The client module contract is the Cordis plugin shape, matching how a
      // working third-party client half declares itself.
      if (typeof mod.apply !== 'function') {
        failed++
        lines.push('FAIL  client module has no apply(), so it cannot register slots')
      }
      if (typeof mod.name !== 'string' || !mod.name) {
        failed++
        lines.push('FAIL  client module has no name')
      }
      if (!Array.isArray(mod.inject)) {
        failed++
        lines.push('FAIL  client module has no inject array')
      } else {
        lines.push(`ok    inject: [${mod.inject.join(', ')}]`)
      }
    }
  }
}

console.log(lines.join('\n'))
console.log(failed === 0 ? 'CLIENT PREFLIGHT PASS' : `CLIENT PREFLIGHT FAIL (${failed})`)
process.exit(failed === 0 ? 0 : 1)
