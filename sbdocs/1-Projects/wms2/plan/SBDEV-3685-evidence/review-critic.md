---
ticket: "SBDEV-3685"
kind: review
reviews: baseline-sampling.md
created: 2026-10-13
reviewer: critic lane (review-3685)
verdict: REVISE
---

# Review — `baseline-sampling.md` (SBDEV-3685)

**Verdict: REVISE.** The attribution of the stockunit/unitload **seq scans** to the three screens holds up. I tried to
break it with stricter windows and a permutation control, and it survived. The **recommendation** does not hold up. It
goes from "who causes the seq scans" to "the crons are no longer the load case". The sampler's own data contradicts
that, and so does a counter the file never read: since 2026-09-25, unitload has had **96.0 billion index tuple fetches
against 8.3 billion seq-scan tuples**. The #1 sampled statement is the release-job prefetch. That prefetch is the
whole-warehouse version, because SBDEV-3678 PR-A was reverted out of `main`.

Counts: **High 1 · Medium 3 · Low 5.**

Reproduction: I copied a1/a2/a3 to scratch and ran them with `python3 -I` against the raw TSV. They print exactly the
file's totals (631/542 increments, 622.5 M/258.4 M tuples, attribution 295/162/81/5 + 118 unattributed). My own
scripts were `b1.py` (window sensitivity, permutation, second-of-minute) and `b2.py` (leader-vs-worker recount), in the
session scratchpad. The PRD queries were catalog/count queries and EXPLAIN without ANALYZE.

---

## HIGH

### H1 — "the crons are no longer the load case" is contradicted by the file's own sampler and by `idx_tup_fetch`

Evidence:
- **Sample share.** The release prefetch `Unitload where storagelocation_id in (…)` has 1,686 of 2,668 samples (63 %).
  The four "screen" classes have 199 + 119 + 77 + 31 = 426 samples together. A tick-sampler measures active time, so
  this one cron statement holds about **4× the DB active time of all the screens combined**. It was active in 13.4 % of
  all ticks, in 414 of ~484 minutes, with up to 16 samples in a single minute. The file reads that as "frequent but not
  the scan source", which is true, and then drops it from the load picture, which does not follow.
- **What PRD actually runs.** `origin/main` carries `07afea75 Hold SBDEV-3678 out of SiteBoss OWL v2.0.151 (revert #473)`.
  PRD's `ReleaseOrderJobService` (`origin/main` :266) therefore still prefetches **every** fix assignment
  (`for (Object[] fixArr : itemDataFixAssignmentMap.values())`) **once per order**. The map holds the whole warehouse
  (`OrderReleaseJob.java:353-364` on main). The file read the release code at `origin/develop` = `a4fd6490`, which has
  PR-A, so it reasoned about code PRD does not run.
- **What the prefetch returns on PRD today.** I reproduced the prefetch's location set on PRD (FLA assigned locations ∪
  the current location of each FLA's assigned UL). It has **1,555 ids, including Nirwana (`location.id = 0`)**, because
  3 fix assignments have their assigned UL sitting in Nirwana. `count(*)` of unit loads on those locations is **372,786**.
  EXPLAIN on a list containing id 0 gives `Index Scan on unitload [Rows: 371331]`. So each held-order evaluation ships
  ~370 k unit-load rows to the JVM. 382 of the 1,686 samples (23 %) are in wait `Client:ClientWrite`, meaning the
  backend was blocked pushing a large result to the client.
- **The counter the file did not read.** `pg_stat_user_tables` on PRD at 2026-10-13T19:40Z, with stats reset at
  2026-09-25T02:24Z (the same base as the ticket's 13.1 B / 5.8 B figures):

  | table | seq_tup_read | idx_tup_fetch |
  |---|---|---|
  | stockunit | 19.2 B | 1.4 B |
  | unitload | 8.3 B | **96.0 B** |

  In a 15 s delta (19:40:17→19:40:32), unitload `idx_tup_fetch` rose by **+1,129,412** while `seq_tup_read` rose by 0.
  Unit-load tuples read through an index are 11.6× its seq-scan reads, and 3.5× the seq reads of **both** tables
  combined. The ticket's sentence "dominant read volume … is seq scans" is false for unitload, and the evidence file
  inherits it.
- **Rough tie-in (inference, MEDIUM confidence).** The median sampled elapsed time is 0.29 s, so the mean duration is
  about 0.6 s. That is a catch probability of about 0.26 per execution, which implies about 6,500 executions in 8 h
  (~13/min). At ~372 k rows each, that is about 4.8 M unit-load fetches/min, the same order as the measured
  1.13 M/15 s (≈4.5 M/min) and the 18-day average of ≈3.6 M/min. This is not proof of attribution (the monitor's nested
  loops also fetch by index), but it is the leading candidate, and the file does not mention it.

Why it matters: Nam would read "cron findings … are no longer the load case" and deprioritise the one fix (PR-A) that
removes the #1 statement in the sample. That fix is already written and is only being held out of a release.

Fix:
1. Scope every load claim to "**seq-scan** volume on stockunit/unitload". Delete or rewrite "they are no longer the
   load case".
2. Add a Finding 0 or Finding 4: the release prefetch on PRD is the whole-warehouse version (PR-A reverted on main,
   `07afea75`). Its list includes Nirwana, it returns ~372 k rows per call, and it holds 63 % of active-statement
   samples. Record the `idx_tup_fetch` numbers above as the second read-volume axis.
3. In "What this does to the ticket", rank **re-landing SBDEV-3678 PR-A** next to the screen fixes. Add the
   `idx_tup_fetch` delta per minute as a before/after metric, since the ticket's gate metric (seq scans) cannot see this
   statement at all.
4. Extend the sampler, or a one-off, to also log `idx_tup_fetch`, so that unit-load index volume can be lined up the
   same way the seq scans were.

---

## MEDIUM

### M1 — "IN (171 params)" is a truncation artefact. The "does not seq scan" claim is one shipped fix-UL away from false

Evidence: all 1,686 samples have **exactly** 171 `$n` placeholders, and **all 1,686 are cut off** (the text does not end
in `)`). That is the sampler's `left(…, 1500)` (`sampler.sh` SQL), not the list length. On PRD the list is about 1,555
ids (see H1). The file's explanation, "`index_unitload_storagelocation_id` exists, so the 0.3 s comes from somewhere
else", is wrong. The 0.3 s is the index scan returning ~370 k rows plus ClientWrite.

Plan-flip check (EXPLAIN, estimate only):
- list contains Nirwana (0), as today: `Index Scan on unitload [Rows: 371331]`
- list contains **Shipped (51611)** + Nirwana: **`Seq Scan on unitload [Rows: 865156]`**

Shipped enters the list as soon as any fix assignment's `assignedunitload_id` points at a shipped UL. Nirwana is already
in it through 3 FLAs, so stale assignments demonstrably happen. From then on it would be a full unitload seq scan
**per held order per tick**, on PRD's un-narrowed prefetch.

Fix: replace "(171 params)" with "(≥171 params; text truncated at 1,500 chars; ~1,555 on PRD)". Replace the "0.3 s comes
from somewhere else" sentence with the row-count and ClientWrite evidence. Add the plan-flip finding as a risk, and
either propose filtering Shipped/Nirwana ids out of `allLocationIds` (one line, any tier) or note that PR-A removes it.

### M2 — "Executions" and "samples" count parallel workers as separate statements

Evidence: parallel workers show up in `pg_stat_activity` with the leader's query text and an **empty** `client_addr`.
`a3.py` keys runs on `(class, pid)`, so each worker pid becomes an "execution". Recounted on leaders only (rows with
`client_addr` non-empty):

| class | samples (file) | leader samples | executions (file) | executions, leaders only |
|---|---|---|---|---|
| Replenishment Monitor | 199 | 110 | 145 | **56** |
| Stock-unit search | 28 (31 by class) | 8 | 31 | **8** |
| stockrecord_view | 77 | 23 | 42 | **8** |
| Location report | 119 | 119 | 86 | 86 |

The conclusion survives, and becomes more consistent: 295 stockunit increments / 56 monitor runs ≈ **5.3
increments/run**, which matches EXPLAIN's serial scan (1) + parallel scan (leader + 4 workers = 5). But the published
numbers are wrong by up to 5×, and Blind spot 5 says it catches the pooled-connection case without mentioning this one.

Fix: filter `client_addr <> ''` (or record `backend_type` / `leader_pid` in the sampler; PG 14 has `leader_pid`) before
counting samples, durations and executions. Republish the table.

### M3 — Blind spot 1 misdescribes the unattributed increments, and investigation traffic is mixed into "app" traffic

Evidence:
- The file says the 118/62 unattributed increments "may be … a 50 ms full scan of a small table". The counters are
  **only** stockunit and unitload, so no small table can appear in them. The unattributed events are full-table reads.
  Examples: `18:38:20 +4 / 1,970,209 tuples`, `18:38:27 +4 / 1,970,211`, `18:38:33 +4 / 1,970,213`, and
  `18:38:49 +4 / 1,970,218` each read the whole stockunit table once as a 4-participant parallel scan. They fall in
  **three or four bursts**: 13:31–13:34, 17:44–17:47, 18:38–18:39, plus singles at 13:51, 14:19, 14:54, 15:14 and
  17:33. These are fast (<2 s) parallel full scans, repeated every ~6 s, which looks like a person or a tool, not a cron.
- **Cron-signature check (asked for in the brief).** The unattributed stockunit increments by 5-second bucket of the
  minute are 12/24/15/6/15/9/5/3/4/13/1/11. Unitload: 5/5/0/1/12/7/1/6/0/1/10/14. They do not cluster at a fixed second,
  and the bursts do not recur every minute. **No cron signature.** That supports the file's conclusion, but the file
  did not run this check.
- **Same role, same IP as the app.** The sample contains `/* crystaldba */` statements, i.e. our own DB-MCP probes, at
  17:34:32, 18:03:54–57, 18:05:03–05, 18:25:23–29 and 18:31:47. They run as `wh01_om1_v2_app` from `172.18.0.1`, exactly
  like the app. "every one from role `wh01_om1_v2_app`" is true but says nothing about origin. Ad-hoc investigation
  queries that ran during the window are indistinguishable from app traffic unless they carry the comment.

Fix: rewrite Blind spot 1 as "unattributed = fast full parallel scans in N bursts at <times>; no second-of-minute
clustering (table); origin unknown, possibly ad-hoc/MCP sessions". Ask the other active sessions whether they ran
stockunit queries at 13:31–13:34, 17:44–17:47 and 18:38. For the next run, add `application_name` and `backend_type`
to the sampler, and exclude `crystaldba`-tagged rows.

---

## LOW

### L1 — The ×23 lift is a ceiling, not a magnitude. Publish the controls that actually support the attribution

The monitor and the location report have **identical** lifts (×22.9 / ×25.2) because both hit 100 %, and lift is then
just 1/base. Also, `a2.py` computes lift with window **i-1..i+2**, while the attribution (`a3.py`) uses **i-3..i+2**.
The file names only the second.

My checks (stockunit / unitload share of increments with a candidate in the window):

| window | tick coverage | attributed |
|---|---|---|
| i-3..i+2 (file) | 5.6 % | 81.3 % / 88.6 % |
| i-1..i+1 | 3.5 % | 79.7 % / 86.5 % |
| i..i (same tick only) | 1.8 % | **74.5 % / 82.5 %** |

Null distributions, 500 draws each, stockunit:
- circular shift of the candidate timeline: median 5.4 %, p99 13.2 %, max 14.6 %
- local shift of ±20 s–5 min, which preserves hour-of-day co-burstiness: median 8.7 %, p99 18.1 %, max 18.2 %

The long 3.8 s monitor statement does **not** inflate the result. Even the same-tick window attributes 74.5 % against a
null maximum of 18 %.

Fix: replace the lift column with "attributed share at windows (-3..+2, 0..0) vs permutation null". Name both windows.

### L2 — Parallel-scan explanation: correct, but state it as full-table equivalents

Verified: `max_parallel_workers_per_gather = 4` on PRD. The raw events show 4 increments = 1,970,2xx tuples (one full
stockunit read), or one read split across ticks (+3 / ~1.12 M then +1 / ~0.8 M). So 631 increments ≈ 622.5 M / 1.97 M ≈
**316 full stockunit reads**, and unitload ≈ 258.4 M / 0.88 M ≈ **293 full reads**. "Half a table per increment" is
true on average, but it invites the misreading "631 half-table scans". Fix: add the full-table-equivalent count and
one example event.

### L3 — The "no flat per-minute floor" argument excludes only an *unconditional* cron scan

The 19h count of 15/h rules out a cron that seq scans every minute (that would be ≥60/h). It does not rule out a
conditional one, such as a scan only when there is work. The things that rule that out are the low lift of every
cron-shaped statement (release IN ×1.0, 6b ×1.4) and the absence of second-of-minute clustering (M3). Fix: cite
those two as the evidence and say the floor argument is necessary but not sufficient.

### L4 — Completeness words without a stated method, or with a narrower method than the wording

- "every one from role `wh01_om1_v2_app`": true (Counter over all 2,668 rows), but it includes MCP traffic (M3).
- "In every tick where the monitor or the location report was seen, a scan increment fell in the window (100%)":
  verified by `a2.py` (su = ul = 1.00). OK.
- "every search reads both tables": method is one EXPLAIN of one keyword shape. Say "the EXPLAINed form".
- "Every scan in Finding 2 reads about 2 M rows": Finding 2 includes `stockrecord_view`, whose EXPLAIN was not shown.
  Scope it to the monitor and the location report.
- "Neither UI polls it on a timer (grep for `setInterval` …: only auth, alerts, heartbeat and the picking timer)": I
  re-checked on `origin/develop` (web-ui `9e31726`, mobile `36368b6`). Callers: `store/dashboard/replenishMonitor.js:33`
  and mobile `pages/replenish.vue:233,253`. The mobile `sendHeartbeat` (`:186`) calls `replenish/heartbeatClaim`, not
  the monitor. Correct for develop, but PRD's UIs run `main`, which was not checked. The grep also misses recursive
  `setTimeout` polling. The web-ui monitor fires on every `/dashboard` mount (`pages/dashboard/index.vue:20,65,77` →
  `replenishViewTable.vue:240`), which is close to "every time someone opens the dashboard". That is worth saying when
  you argue it is user-driven. Fix: name the ref, and add `setTimeout` to the grep.
- "no flat per-minute floor": see L3.

### L4b — (folded into L4) Source reads at `origin/develop` while PRD runs `main`

This matters materially for the release job (H1). For the monitor SQL, Blind spot 3 already flags it. Fix: in the
header, say which findings were checked against `origin/main`.

### L5 — Characterisation of the ticket

"The ticket's premise is that **both crons' per-minute work** drives load." The ticket actually says "On prd the root
cause of the load is **unmeasured**", and gates the build on a `pg_stat_statements` baseline on wineco **and
c1wh-shipitez** (acceptance criterion 1). The file is honest that it is a substitute for gate (a). But its last bullet
("no longer the load case") reads as if it settles the gate. It covers one tenant, one holiday day, and one metric
(seq scans). Fix: say the gate stays closed, the shipitez half is untouched, and this is input to the re-plan, not a
replacement for it.

---

## What survives

- The three screens (Replenishment Monitor, Warehouse Location report, stock-unit keyword search) account for ~75–89 %
  of the stockunit/unitload **seq-scan** increments in this window. The result is robust to window choice and well above
  a permutation null.
- The release prefetch is **not** a seq-scan source in this window (lift ×1.0 / ×0.9), but see M1 for the latent flip.
- Finding 3 (99.3 % of the scanned rows are in Shipped/Nirwana) and the location/index pre-filter idea stand.
  `index_unitload_storagelocation_id` and `index_stockunit_unitload_id` both exist on PRD.

## Open questions (unscored)

- Is the 96 B unitload `idx_tup_fetch` mostly the release prefetch, or the monitor's nested loops? A 10-minute
  `idx_tup_fetch` delta sampled alongside the release statement (no other instrument needed) would settle it.
- Who produced the 13:31–13:34, 17:44–17:47 and 18:38 full stockunit scans? Ask the active sessions (lane-oms,
  lane-wms, review-3736, main) whether they ran probes then.
- How many held orders per tick does PRD evaluate? This is the multiplier on the ~372 k-row prefetch.

---

## Re-review (round 2) — delta only

**Verdict: ACCEPT-WITH-RESERVATIONS.** It becomes ACCEPT once N1 is fixed. All nine round-1 findings landed. The
rewrite introduced **one new false claim of Medium severity (N1)**. Ranked recommendation #2, followed literally, would
make the release job throw. There are three new Low findings.

New counts: **High 0 · Medium 1 · Low 3.**

### Round-1 fixes: did each one land?

| finding | landed? | note |
|---|---|---|
| H1 | yes | Two-axis table, Finding 1 on `origin/main`, the `07afea75` revert, and "no longer the load case" removed. |
| M1 | yes | Truncation, ~1,555 ids, the plan flip to `Seq Scan … 865156`. |
| M2 | mostly | Samples and executions are now leaders-only. The "median s" column is not (see N3). |
| M3 | yes | Full-table bursts, the second-of-minute buckets, and crystaldba overlap. |
| L1 | yes | Both windows named, the window table, the permutation null, and lift described as a ceiling. |
| L2 | yes | 316 / 293 full-table equivalents, with an example event. |
| L3 | yes | Three-legged case, and "item 3 alone would not exclude a conditional one". |
| L4 | yes | The `setTimeout` gap is stated, the `/dashboard` mount is named, and the scope is "for the EXPLAINed keyword shape". |
| L5 | yes | "Does not satisfy gate (a)", and the shipitez half is named. |

### N1 (MEDIUM): recommendation #2, "Exclude Shipped/Nirwana from the prefetch's `allLocationIds`", would throw

Evidence: on `origin/main`, `allLocationIds` feeds **two** maps.
1. `locationMap`, built from `locationRepository.findAllById(allLocationIds)`. It is read at `ReleaseOrderJobService:482`
   as `locationMapFinal.get(unitload.getStoragelocationId())`, which is the assigned UL's **current** location, and `:483`
   throws `EntityNotFoundException("Location", …)` when that lookup misses.
2. `unitloadsByLocationMap`, built from `findByStoragelocationIdIn(allLocationIds)`. It is read **only** at `:501`,
   `getOrDefault(assignedLocation.getId(), …)`, so it is keyed by the FLA's **assigned** location.

Today, Nirwana (id 0) enters `allLocationIds` only as a UL's current location (3 FLAs, assigned to `11-D06`, `45-B01`,
`11-C09`). Removing it from `allLocationIds` removes it from `locationMap`. The release job would then throw at `:483` for
any order of those items, instead of putting the position on hold as 57 at `:489`. That is a behaviour change on exactly
the stale-FLA case the plan-flip risk is about. "About one line, any tier" is also wrong: tier is `wms-triage`'s call, and
this change touches release-job hold logic.

Fix: rewrite #2 as "Pass only the FLA **assigned**-location ids to `findByStoragelocationIdIn`, because that map is only
read by assigned location (`:501`). Keep `allLocationIds` for `locationMap`." That is the invariant rather than a
name-based instance, and it removes Nirwana/Shipped from the 372 k-row query without touching the `:482` lookup. Drop
"any tier", or say "tier per `wms-triage`".

### N2 (LOW): "Re-land PR-A … a release decision (devops), not new code" omits why it was held, and overstates its reach

- The `07afea75` message says: "Held: its live multi-unit-load confirm on a dev handheld and high-load validation are not
  recorded." Re-landing is gated on that validation, not on a release decision alone. Fix: append "gated on the
  validation recorded as missing in `07afea75` (handheld multi-UL confirm, high-load)".
- "It removes the whole-warehouse prefetch … leading candidate for the 96 B" is true for the whole-warehouse **width**.
  But PR-A on develop still adds each assigned UL's current location to `allLocationIds` (develop :293-295). Nirwana
  therefore re-enters for any order of those 3 items. Today they have **0 open orders** (PRD: all their orders are state
  700/800), so the claim holds today, but not by construction. Fix: add "the Nirwana/Shipped plan-flip risk remains on
  develop until N1's fix lands".

### N3 (LOW): "leaders only" table carries all-row medians, and "≈4×" mixes bases

Leader-only medians recomputed from the TSV: monitor **2.11 s** (the file says 3.77), `stockrecord_view` **2.94 s** (the
file says 1.93). Location report 0.83 and search 0.08 are unchanged. In Finding 1, "about 4× … all the screens" uses
all-row counts (1,686 / 426). Against the new leaders-only table it is 1,686 / 260 ≈ **6.5×**. Fix: recompute the median
column on leaders, and say which base the ratio uses.

### N4 (LOW): recommendation #3's "~75–89% of the seq-scan volume" is the four-class, increment share

#3 covers the monitor and the location report only. Their share, from `b3.py` with window i-3..i+2, where any other
co-present class is also allowed:

| table | share of increments | share of tuples (`seq_tup_read`) |
|---|---|---|
| stockunit | 69.7% | **84.2%** |
| unitload | 81.9% | **91.1%** |

"Volume" means tuples, so the defensible figure is 84–91% of the seq-scan tuples. Fix: replace the figure and name the
base.

No other new claim failed a check. The `/dashboard` caller chain, the 0.65/min figure, "~370 k Nirwana unit loads per
call", the window table and the permutation numbers are all reproduced or taken verbatim from round 1.
