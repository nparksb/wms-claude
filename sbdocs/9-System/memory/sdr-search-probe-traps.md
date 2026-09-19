---
name: sdr-search-probe-traps
description: SDR exports EVERY query method not just @RestResource ones; and a 200 from a search whose query matched nothing proves nothing
metadata: 
  node_type: memory
  type: reference
  originSessionId: fecb1e71-8804-476e-9c3b-a14f61108d35
  modified: 2026-09-17T20:24:06.213Z
---

Two traps that between them made a whole ticket (SBDEV-3417) wrong on its first filing.

**1. Spring Data REST exports every declared query method, annotated or not.** `@RestResource` only
*customises* the path/rel; it does not decide export. Counting annotated methods gave **56**; the
runtime surface is **228 searches across 36 repositories**. Enumerate it, never grep it:

```
GET /v3/                 -> _links = the exported repositories (36)
GET /v3/<rel>/search     -> _links = that repo's exported searches
```

Same shape as [[annotation-census-by-grep-is-wrong-by-default]]: use the runtime, reconcile with a
second instrument. For return types use `javap -p` on `target/classes` — a source regex mis-parses
generics, and the return type is what the classification hinges on.

**2. A `200` from a search whose query matched nothing is not a passing verdict.** It is the
empty-result case, and it is indistinguishable from "this route works". Measured: the *same* route
flips purely on data —

```
/v3/client/search/getTransactionSummary?clientCode=ZZZZ -> 200   (0 rows)
/v3/client/search/getTransactionSummary?clientCode=ARW  -> 500   (real rows)
```

So a sweep that probes with synthetic non-matching values (`ZZZZ`, `id=1`) reports most of the
surface healthy **and is wrong**. Before calling a route good, confirm from the response body that
`_embedded.<rel>` is non-empty — an empty array means the probe was vacuous. This is
[[a-zero-scan-needs-a-positive-control]] wearing a different hat: the vacuous probe agrees with
whatever you hoped.

**3. Corollary — badly-typed parameters return 500, not 400.** Passing a string where an `int` is
expected produces an indistinguishable `{"status":500}`. That inflated the same ticket's broken
count from 17 to 41. Type probe values from the real Java signature, and re-probe every 500 before
believing it.

**4. BOTH caller-sweep instruments mis-report, in three ways — run both and read every hit.**
*Bare method name* over-reports: `exportStorageLocations` -> `POST /report/…`,
`getStockUnitInfoForReplenishment` -> `/replenishOrder/…/{id}`, `getSystemByGroupname` ->
`/system/searchSystemByGroupname/…`, all *controller* routes. The `/search/<name>` *URL shape* fails
twice over: it **under**-reports a URL built from a variable (the SBDEV-3183 `LockOverview*`
near-miss), and it **over**-reports because (a) a controller can mount `/search/` itself
(`/v3/unitLoad/search/findByItemForReplenish` is `UnitLoadController` — note the capital L) and
(b) **it matches comments and prose**, not just live calls (`store/index.js` documenting a URL that
was removed counted as a caller). Resolve every hit by reading the call site. Over-counting callers
is the safe direction — it withdraws fewer routes, never more.
Complements [[absence-of-a-path-is-not-absence-of-the-guarantee]], which is the opposite error.

**5. `Page` is NOT exempt from the render defect, and a raw return hides from any static rail.**
`Page extends Slice extends Streamable extends Iterable`, so a paged result reaches an *overload* of
`entitiesToResources` and the same per-element `PersistentEntityResourceAssembler.wrap()`. Anything
claiming the paged branch differs is wrong — read `RepresentationModelAssemblers` before believing it.
Separately, **26 repository methods declared a raw `Page`** (raw `Page findByKeyword(…)` is this repo's
keyword-search idiom): `getGenericReturnType()` then returns a `Class`, not a `ParameterizedType`, so
an element-type rail skips them **silently**. SBDEV-3417 parameterised all 26 and made the rail *fail*
on anything it cannot grade. When a rail's predicate reads a generic type, enumerate the raw case
first — and grep for `Page`, not just `List`.
