# dsh-plugin-mimo-delegate

A [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) plugin that puts the
**local MiMo Desktop delegation pipeline** behind a switch you can actually see and click:

- a compact button in the **left sidebar footer**, directly above *上下文洞察 (Context insight)*;
- a **settings card** under **设置 → 插件 → 插件配置**, showing what the pipeline is, where its
  pieces live, its live state, and the same switch.

Flipping the switch on/off runs one already-tested script, `Set-Delegation.ps1`, which parks the
`mimo-delegate` skill outside the skills root and rewrites the rule block in `~/.dsh/AGENTS.md`.
The plugin deliberately does **not** reimplement that logic — one implementation means the UI and
the command line can never disagree.

## Requirements

- Windows, with DSH Desktop installed.
- The MiMo delegation pipeline itself: the `mimo-delegate` skill plus
  `_mimo_bridge\Set-Delegation.ps1`. If those live somewhere else, change the `toggleScript`
  setting on the plugin's settings card (or in `~/.dsh/settings.yaml`).

## Install

**Via the plugin market** (recommended): open **插件市场 → 发现**, search for `mimo-delegate`,
install, then restart DSH Desktop. Market installs are managed, so the plugin also shows up under
**已安装** where you can disable or uninstall it.

**Manually**: copy this package into your profile's `node_modules` and list it in
`package.json → dsh.profile.bundles`:

```powershell
$profile = "$env:USERPROFILE\.dsh\profiles\desktop"
$target  = "$profile\node_modules\dsh-plugin-mimo-delegate"
Copy-Item <this repo> $target -Recurse -Force
# then add "dsh-plugin-mimo-delegate" to dsh.profile.bundles in $profile\package.json
# and restart DSH Desktop
```

## Safety

A plugin that throws inside `apply()` aborts the entire DSH boot and drops the app into its
recovery screen. An earlier revision of this plugin did exactly that (it assumed
`ctx.settings.watch` existed). Two things now make that class of failure impossible:

1. **`apply()` cannot throw.** Everything runs inside a `try/catch`; a wrong assumption degrades
   into a logged warning.
2. **No API is assumed.** The change feed is probed in order
   (`ctx.settings.watch` → `scope.watch` → `scope.subscribe`) and falls back to polling.

`preflight.mjs` proves it: it stages a copy of this package inside the profile's `node_modules`
(**deliberately not listed in `dsh.profile.bundles`, so DSH can never load it**), imports the host
half, and calls `apply()` with six different `ctx` shapes.

```powershell
npm run preflight     # or: node preflight.mjs
npm run check         # syntax + preflight
```

Expected tail:

```
ok    register + get, NO watch anywhere  <-- the shape that once killed DSH boot
...
PREFLIGHT PASS
```

## Development notes

- `lib/index.js` — host half (plain Cordis plugin, ESM, no build step).
- `lib/client.js` — browser half, a hand-written lazy-CJS factory registered on
  `window.__ModuleLoader__`. No bundler is required; it only `require`s `react` and
  `react/jsx-runtime`.
- `cordis.patch.yml` — the bundle patch that inserts the host row.

## License

MIT
