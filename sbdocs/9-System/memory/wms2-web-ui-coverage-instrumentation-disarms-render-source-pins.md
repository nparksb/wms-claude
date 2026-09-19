---
name: wms2-web-ui-coverage-instrumentation-disarms-render-source-pins
description: "wms2-web-ui's jest.config.js sets collectCoverage:true, so istanbul rewrites comp.render and EVERY test asserting on String(comp.render) reads instrumented source and matches nothing — it is why SBDEV-2967-C's gating pin has been red on develop since it landed"
metadata: 
  node_type: memory
  type: reference
  originSessionId: afc23d06-1cfd-4b37-a864-1f84ddec40e3
  modified: 2026-08-26T18:05:23.890Z
---

Measured 2026-08-26 on `origin/develop` @ `ebe69bc` while baselining for SBDEV-3012's UI half.

**FIXED 2026-08-26 — PR #85 (`c3f8e6e`). `develop`'s Jest lane is now 711 tests / 0 failed / 2 red
suites** (the `labelPrinting` module-resolution pair, 0 failing tests). Keep reading: the mechanism is
the reusable part, and the fix has three tolerance axes, not one.

**`v2/wms2-web-ui/jest.config.js` has `collectCoverage: true` with `collectCoverageFrom` covering
`components/**/*.vue` — there since the initial 2024 check-in.** The instrumenting transform
**RE-GENERATES AND PRETTY-PRINTS** the render function. ⚠️ **The operative damage is WHITESPACE, not
coverage counters** — I first wrote "istanbul rewrites comp.render", which is true but misleads about
what breaks:

```
uninstrumented:  _c('v-btn',{staticClass:"…",attrs:{"disabled":!_vm.actionAvailability.x}
instrumented:    _c('v-btn', {\n  staticClass: "…",\n  attrs: {\n    "disabled": !_vm…
```

So **whitespace-sensitive STRUCTURAL patterns match nothing, while BARE IDENTIFIER counts survive
untouched.** That split is diagnostic: if identifier-based helpers pass and a structural one returns 0
for every key, the source shape changed — the product is fine.

This was not theoretical — it was why 2 of the 3 red suites on develop were red:

| Run | `actionControlsDisabled.spec.js` |
|---|---|
| `jest <file>` (coverage on, the default) | **2 failed** — all 8 `:disabled` bindings reported ABSENT |
| `jest <file> --coverage=false` | **9 passed / 9** |

The product was fine throughout — `stockUnitsTable.vue` still carries all 8
`:disabled="!actionAvailability.X"` bindings on the `v-btn`s. **The pin was blind, not the gating.**
That pin is SBDEV-2967-C's, deliberately engineered with a tempered gap and exact per-key counts so it
could not be fooled by a `toContain`, and it was **born un-runnable in the only lane that runs
everything**. Reported on SBDEV-2967 with the fix.

**Only STRUCTURAL pins are affected.** Measured, not assumed: `lockConfirmation.spec.js` and
`deleteConfirmationComment.spec.js` still read `comp.render` and are sound, because every match they
make is a bare identifier or string literal — three mutants confirm they still bite. They now carry a
warning not to add a structural pattern there.

**The fix — compile the raw `<template>` yourself.** `vue-template-compiler` is already a dependency
and is never instrumented:

```js
const fs = require('fs'), path = require('path'), compiler = require('vue-template-compiler')
const compiledTemplate = (relPath) => {
  const src = fs.readFileSync(path.resolve(__dirname, '../..', relPath), 'utf8')
  return compiler.compile(compiler.parseComponent(src).template.content).render
}
```

⚠️ **Its output uses BARE identifiers** — `"disabled":!actionAvailability.x` — **not** the `_vm.`-prefixed
form `String(comp.render)` gives. Existing regexes need `_vm\.` dropped (or made optional). Verified
end to end: 8/8 bindings found, and the resulting pin passes **with coverage on**. Working reference
lives in `test/components/admin/groupDeleteImpact.spec.js` (PR #84).

Bonus: `parseComponent().template.content` excludes the `<script>` block, so a javadoc mentioning the
identifier cannot satisfy the pin — unlike a raw file grep. But **matching the identifier alone still
is not enough**: bound to `:title` or wrapped in `v-if="false"` it never reaches the operator. Require
a text node — `_v(_s(impactWarning))`.

**Current baseline: `origin/develop` @ `e3cd2e1` = 738 tests / 0 failed / 2 red suites** (measured on
the merged commit in a clean tree, 2026-08-26). The 2 red suites are `labelPrinting/zplPreview` and
`labelPrinting/labelCsvUpload` — module-resolution failures with **0 failing tests**.

⚠️ **Compare TEST counts, in a NAMED LANE.** A suite count alone is ambiguous, because the two lanes
disagree about which suites are red: with coverage on it was 3 red suites / 2 failing tests, with
`--coverage=false` 2 red suites / 0 failing tests. Supersedes
[[wms2-web-ui-develop-preexisting-suite-failures]].

Related: [[verify-script-traps]],
[[mutation-harness-traps]].

**THE FIX NEEDS THREE TOLERANCE AXES, not just whitespace.** Review caught two more, either of which
would have re-broken it:

1. `\s*` at every join — the pretty-printing above.
2. `(?:_[gb]\(\s*)*` — a `v-on`/`v-bind` **activator** compiles its data object inside wrapper calls:
   `_c('v-btn',_g(_b({attrs:{…}},'v-btn',attrs,false),on)`. **Already used in five components**
   (`outboundParcelReport.vue:148`, both cycleCount screens, `openRequest.vue`). Converting a
   `<span :title>` wrapper to a real Vuetify tooltip would otherwise zero all 8 counts.
3. `!\s*` — space after the negation. Keep it a SINGLE `!` so `!!` (inverted polarity) stays a kill.

**Two further traps worth carrying forward:**
- **A positional pin needs the PAIR.** `titleCount` counted `actionHint('key')` anywhere, so moving a
  `:title` off the wrapping `<span>` onto the button kept it green — and position is load-bearing,
  because a native `title` on a **disabled** control is unreliable (pointer events suppressed in
  several browsers), which is why the template wraps rather than titles.
- **Never assert a shape check against the real template.** `expect(disabledOnButton(real) > 0)` goes
  red on a genuine deletion too, so a block meant to say "harness fault" blames the harness for a real
  regression. Use an inline fixture the product cannot influence.

Also: `compiler.compile('')` returns a zero-binding `_c("div")` stub with `errors: []`, and
`parseComponent(src).template` is `null` with no `<template>` block — both grade as "every binding is
missing". Throw named errors for each.